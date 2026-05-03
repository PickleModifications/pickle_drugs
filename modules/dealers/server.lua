-- Dealers server. Hireable NPCs that auto-handle customer offers in the
-- zones they're assigned to. Architecture mirrors employees + dealing
-- customers:
--   * Admin defines a "dealer slot" (model, name, zone access) via the
--     /drugs → Dealing tab. Slots persist in pickle_drugs_dealers.
--   * Player hires an unhired slot (their cid stamps `hired_by`). One
--     hire per slot; dismissal clears `hired_by` and the slot is
--     available again. Inventory carries with the slot for now (set to
--     wipe-on-dismiss only if it surfaces as an exploit later).
--   * Hired dealer auto-takes customer offers in any zone it covers
--     when it has stock of the drug. The dealing scheduler calls
--     Dealers.TryAutoFulfil(cust, zone, drug) before pushing the
--     offer to the player's phone.
--   * `/dealerphone` style summon: player asks the dealer to come
--     meet them. Server spawns the ped near the player; client walks
--     it to the player. ox_target on the dealer ped lets the player
--     hand items into the dealer's inventory.

Dealers = Dealers or {}

local Slots         = {}    -- id → row
local SlotByCid     = {}    -- cid → array of slot ids hired
local ActiveDeals   = {}    -- dealId → { dealerId, customerId, zoneId, dealPoint }
                            -- (autonomous deals being worked by a dealer)
local DealerOpeners = {}    -- slotId → src that has the dealer's locker UI open

local function dealerSlotsCap()
    return (Config and Config.Dealing and tonumber(Config.Dealing.dealerInventorySlots)) or 25
end

-- ─── Slot-keyed inventory helpers (mirrors locker storage) ────────────────
-- Inventory shape: { ["1"] = { name, count, metadata }, ["2"] = ..., ... }.

local function slotGet(s, k) return s.inventory[tostring(k)] or s.inventory[k] end
local function slotSet(s, k, v)
    s.inventory[k] = nil
    s.inventory[tostring(k)] = v
end

local function metaEq(a, b)
    if a == b then return true end
    local ta, tb = type(a), type(b)
    if ta ~= tb then return false end
    if ta ~= "table" then return false end
    return json.encode(a) == json.encode(b)
end

local function dealerCountItem(s, name)
    if not name then return 0 end
    local total = 0
    for _, it in pairs(s.inventory or {}) do
        if it and it.name == name then total = total + (tonumber(it.count) or 0) end
    end
    return total
end

--- Add `count` of `name` to the dealer's inventory. Merges into the
--- first existing same-item stack (ignoring metadata diffs the way the
--- worker-deposit path does), then drops any remainder into the first
--- free slot up to `dealerSlotsCap`. Returns added/remaining counts.
local function dealerAddItem(s, name, count, metadata)
    local cap = dealerSlotsCap()
    local remaining = count
    -- 1. Same-item merge.
    for i = 1, cap do
        local cur = slotGet(s, i)
        if cur and cur.name == name then
            cur.count = (tonumber(cur.count) or 0) + remaining
            slotSet(s, i, cur)
            remaining = 0
            break
        end
    end
    -- 2. First free slot for the remainder.
    if remaining > 0 then
        for i = 1, cap do
            if not slotGet(s, i) then
                slotSet(s, i, { name = name, count = remaining, metadata = metadata })
                remaining = 0
                break
            end
        end
    end
    return count - remaining, remaining
end

--- Drain `count` of `name` from the dealer's inventory. Returns true if
--- the full count was satisfied; otherwise leaves the inventory mutated
--- by however much it could pull and returns false.
local function dealerRemoveItem(s, name, count)
    local cap = dealerSlotsCap()
    local need = count
    for i = 1, cap do
        if need <= 0 then break end
        local cur = slotGet(s, i)
        if cur and cur.name == name then
            local have = tonumber(cur.count) or 0
            local take = math.min(have, need)
            cur.count = have - take
            need = need - take
            if cur.count <= 0 then slotSet(s, i, nil) else slotSet(s, i, cur) end
        end
    end
    return need <= 0
end

local function now() return os.time() * 1000 end

local function notify(src, msg, type_)
    if not src or src == 0 then return end
    TriggerClientEvent("ox_lib:notify", src, {
        title = "Dealers", description = msg, type = type_ or "inform",
    })
end

local function adminCheck(src)
    if not Admin or not Admin.IsAdmin then return src == 0 end
    return Admin.IsAdmin(src)
end

local function jsonDecodeArray(s)
    if type(s) ~= "string" or s == "" then
        return type(s) == "table" and s or {}
    end
    local ok, v = pcall(json.decode, s)
    return (ok and type(v) == "table") and v or {}
end

local function jsonDecodeObject(s)
    if type(s) ~= "string" or s == "" then
        return type(s) == "table" and s or {}
    end
    local ok, v = pcall(json.decode, s)
    return (ok and type(v) == "table") and v or {}
end

local function genId(prefix)
    return ("%s_%d_%d"):format(prefix, now(), math.random(1000, 9999))
end

local function rebuildOwnerIndex()
    SlotByCid = {}
    for id, s in pairs(Slots) do
        if s.hired_by and s.hired_by ~= "" then
            SlotByCid[s.hired_by] = SlotByCid[s.hired_by] or {}
            SlotByCid[s.hired_by][#SlotByCid[s.hired_by] + 1] = id
        end
    end
end

local function rowToSlot(row)
    return {
        id            = row.id,
        first_name    = row.first_name or "Dealer",
        last_name     = row.last_name or "",
        model         = row.model or "g_m_y_lost_01",
        zones         = jsonDecodeArray(row.zones),
        hired_by      = (type(row.hired_by) == "string" and row.hired_by ~= "") and row.hired_by or nil,
        hired_by_name = (type(row.hired_by_name) == "string" and row.hired_by_name ~= "") and row.hired_by_name or nil,
        inventory     = jsonDecodeObject(row.inventory),
        cut_pct       = tonumber(row.cut_pct) or (Config.Dealing and Config.Dealing.dealerCutPct) or 0.10,
        updated_at    = tonumber(row.updated_at) or 0,
    }
end

-- ─── DB ───────────────────────────────────────────────────────────────────

local function persistSlot(s)
    s.updated_at = now()
    MySQL.update.await([[
        INSERT INTO pickle_drugs_dealers
            (id, first_name, last_name, model, zones, hired_by, hired_by_name,
             inventory, cut_pct, updated_at)
        VALUES (?,?,?,?,?,?,?,?,?,?)
        ON DUPLICATE KEY UPDATE
            first_name=VALUES(first_name), last_name=VALUES(last_name),
            model=VALUES(model), zones=VALUES(zones),
            hired_by=VALUES(hired_by), hired_by_name=VALUES(hired_by_name),
            inventory=VALUES(inventory), cut_pct=VALUES(cut_pct),
            updated_at=VALUES(updated_at)
    ]], {
        s.id, s.first_name, s.last_name, s.model,
        json.encode(s.zones or {}),
        s.hired_by, s.hired_by_name,
        json.encode(s.inventory or {}),
        s.cut_pct or 0.10,
        s.updated_at,
    })
end

local function loadAll()
    local rows = MySQL.query.await("SELECT * FROM pickle_drugs_dealers") or {}
    for _, r in ipairs(rows) do Slots[r.id] = rowToSlot(r) end
    rebuildOwnerIndex()
end

-- ─── Broadcasts ───────────────────────────────────────────────────────────

local function broadcastSlot(s)
    -- Public slot info — no inventory leakage to non-owners.
    local public = {
        id         = s.id,
        first_name = s.first_name,
        last_name  = s.last_name,
        model      = s.model,
        zones      = s.zones,
        hired      = s.hired_by ~= nil,
        cut_pct    = s.cut_pct,
    }
    TriggerClientEvent("pickle_drugs:dealerSlotUpdate", -1, public)
end

local function broadcastSlotRemoved(id)
    TriggerClientEvent("pickle_drugs:dealerSlotRemoved", -1, id)
end

--- Aggregate dealer's slot inventory into a flat { item: count } map.
--- Used by the phone Messages UI which doesn't care about per-slot
--- positioning, only "what does this dealer carry, and how much".
local function aggregateInventory(s)
    local agg = {}
    for _, it in pairs(s.inventory or {}) do
        if it and it.name then
            agg[it.name] = (agg[it.name] or 0) + (tonumber(it.count) or 0)
        end
    end
    return agg
end

--- Push the full slot (inventory aggregate included) to its owner only.
local function pushOwnerSnapshot(s)
    if not s or not s.hired_by then return end
    if not (Framework and Framework.GetCitizenId) then return end
    for _, src in ipairs(GetPlayers()) do
        local sid = tonumber(src)
        if sid and Framework.GetCitizenId(sid) == s.hired_by then
            TriggerClientEvent("pickle_drugs:dealerOwnerUpdate", sid, {
                id         = s.id,
                first_name = s.first_name,
                last_name  = s.last_name,
                model      = s.model,
                zones      = s.zones,
                hired      = true,
                inventory  = aggregateInventory(s),
                cut_pct    = s.cut_pct,
            })
            break
        end
    end
end

-- ─── Admin CRUD ───────────────────────────────────────────────────────────

RegisterNetEvent("pickle_drugs:saveDealer", function(payload)
    local src = source
    if not adminCheck(src) then return end
    if type(payload) ~= "table" then return end
    local id = (type(payload.id) == "string" and payload.id ~= "") and payload.id or genId("dr")
    local s = Slots[id] or { id = id, zones = {}, inventory = {}, cut_pct = 0.10 }
    s.first_name = tostring(payload.first_name or s.first_name or "Dealer")
    s.last_name  = tostring(payload.last_name  or s.last_name  or "")
    s.model      = tostring(payload.model      or s.model      or "g_m_y_lost_01")
    if type(payload.zones) == "table" then
        local cleaned = {}
        for _, zid in ipairs(payload.zones) do
            if type(zid) == "string" and Dealing.GetZone and Dealing.GetZone(zid) then
                cleaned[#cleaned + 1] = zid
            end
        end
        s.zones = cleaned
    end
    if type(payload.cut_pct) == "number" then
        s.cut_pct = math.max(0.0, math.min(1.0, payload.cut_pct))
    end
    Slots[id] = s
    persistSlot(s)
    rebuildOwnerIndex()
    broadcastSlot(s)
    pushOwnerSnapshot(s)
    TriggerClientEvent("pickle_drugs:dealerSlotSaved", src, {
        tempId  = (type(payload.id) == "string" and payload.id) or "",
        savedId = id,
    })
end)

RegisterNetEvent("pickle_drugs:deleteDealer", function(id)
    local src = source
    if not adminCheck(src) then return end
    if not id or not Slots[id] then return end
    Slots[id] = nil
    rebuildOwnerIndex()
    MySQL.update.await("DELETE FROM pickle_drugs_dealers WHERE id=?", { id })
    broadcastSlotRemoved(id)
end)

-- ─── Hire / dismiss ───────────────────────────────────────────────────────

local function getCid(src)
    return Framework and Framework.GetCitizenId and Framework.GetCitizenId(src) or nil
end

local function getCharName(src)
    return GetPlayerName(src) or "Player"
end

RegisterNetEvent("pickle_drugs:hireDealer", function(slotId)
    local src = source
    local s = Slots[slotId]
    if not s then return end
    if s.hired_by then
        notify(src, "Already hired by someone else", "error")
        return
    end
    local cid = getCid(src)
    if not cid then notify(src, "Couldn't read your character", "error") return end
    s.hired_by = cid
    s.hired_by_name = getCharName(src)
    persistSlot(s)
    rebuildOwnerIndex()
    broadcastSlot(s)
    pushOwnerSnapshot(s)
    notify(src, ("Hired %s %s"):format(s.first_name, s.last_name), "success")
end)

RegisterNetEvent("pickle_drugs:dismissDealer", function(slotId)
    local src = source
    local s = Slots[slotId]
    if not s then return end
    local cid = getCid(src)
    if not cid then return end
    if s.hired_by ~= cid and not adminCheck(src) then return end
    s.hired_by = nil
    s.hired_by_name = nil
    persistSlot(s)
    rebuildOwnerIndex()
    broadcastSlot(s)
    -- Tell the now-ex-owner the slot is no longer theirs.
    TriggerClientEvent("pickle_drugs:dealerOwnerRemoved", src, slotId)
    notify(src, ("Dismissed %s %s"):format(s.first_name, s.last_name), "inform")
end)

-- ─── Storage adapter ──────────────────────────────────────────────────────
-- Dealers are exposed to the existing storage UI via a "dealer:" prefix
-- on the locker id. Storage server hooks (openStorage / closeStorage /
-- storageTransfer) detect the prefix and call into these adapter
-- functions, so the player gets the same StoragePanel UX as a real
-- locker — split / combine / rearrange / deposit / withdraw all work.

--- Build a storage-shaped snapshot of the dealer for the StoragePanel.
local function dealerSnapshot(src, s)
    local items = {}
    for slot, it in pairs(s.inventory or {}) do
        items[tostring(slot)] = {
            name     = it.name,
            count    = it.count,
            metadata = it.metadata,
        }
    end
    local player = (Inventory and Inventory.GetPlayerItems
        and Inventory.GetPlayerItems(src)) or {}
    local imagesPath = (Inventory and Inventory.ImagesPath)
        or (Config.Inventory and Config.Inventory.imagesPath)
        or ""
    return {
        id     = "dealer:" .. s.id,
        kind   = "dealer",
        label  = ("%s %s"):format(s.first_name or "Dealer", s.last_name or ""),
        slots  = dealerSlotsCap(),
        items  = items,
        player = player,
        imagesPath = imagesPath,
    }
end

local function pushDealerSnapshot(src, s)
    TriggerClientEvent("pickle_drugs:storageContents", src, dealerSnapshot(src, s))
end

--- Open the dealer as a storage panel. Owner-only. Returns the
--- snapshot the StoragePanel expects, or nil/{busy=true} on failure.
function Dealers.OpenAsLocker(src, slotId)
    local s = Slots[slotId]
    if not s then return nil end
    local cid = getCid(src)
    if not cid or s.hired_by ~= cid then return nil end
    if DealerOpeners[slotId] and DealerOpeners[slotId] ~= src then
        return { busy = true }
    end
    DealerOpeners[slotId] = src
    return dealerSnapshot(src, s)
end

function Dealers.CloseAsLocker(src, slotId)
    if DealerOpeners[slotId] == src then
        DealerOpeners[slotId] = nil
        -- Fire the exit-anim event on the dismissing player's client.
        -- Their client owns the dealer ped (summon is local-only) so the
        -- anim/walk-away sequence must run there.
        TriggerClientEvent("pickle_drugs:dealerExitAnim", src, slotId)
    end
end

--- Mirror of Storage's storageTransfer logic, scoped to the dealer's
--- slot inventory. Same semantics: deposit/withdraw/rearrange with
--- partial counts, same-item merge, oriented-box restrictions.
function Dealers.HandleTransfer(src, slotId, payload)
    local s = Slots[slotId]
    if not s then return end
    if DealerOpeners[slotId] ~= src then return end
    local cid = getCid(src)
    if not cid or s.hired_by ~= cid then return end
    if type(payload) ~= "table" then return end

    local dir      = payload.direction
    local fromSlot = tonumber(payload.fromSlot)
    local toSlot   = tonumber(payload.toSlot)
    local reqCount = tonumber(payload.count)
    local cap      = dealerSlotsCap()

    if dir == "deposit" then
        if not fromSlot then return end
        local pItems = (Inventory and Inventory.GetPlayerItems
            and Inventory.GetPlayerItems(src)) or {}
        local source_ = nil
        for _, it in ipairs(pItems) do
            if tonumber(it.slot) == fromSlot then source_ = it; break end
        end
        if not source_ or not source_.name or (tonumber(source_.count) or 0) <= 0 then
            return
        end
        local maxCount = tonumber(source_.count) or 0
        local count = math.max(1, math.min(maxCount, math.floor(reqCount or maxCount)))

        -- Resolve target: explicit toSlot (empty or same-item merge), else first free.
        local target = toSlot
        local merge = false
        if target and target >= 1 and target <= cap then
            local existing = slotGet(s, target)
            if not existing then
                -- empty: drop here
            elseif existing.name == source_.name and metaEq(existing.metadata, source_.metadata) then
                merge = true
            else
                target = nil
            end
        else
            target = nil
        end
        if not target then
            for i = 1, cap do if not slotGet(s, i) then target = i break end end
        end
        if not target then
            notify(src, "Dealer's bag is full", "error")
            pushDealerSnapshot(src, s)
            return
        end

        if not Inventory.RemoveItem(src, source_.name, count, source_.metadata) then
            notify(src, "Couldn't take that item", "error") return
        end
        if merge then
            local existing = slotGet(s, target)
            existing.count = (tonumber(existing.count) or 0) + count
            slotSet(s, target, existing)
        else
            slotSet(s, target, {
                name     = source_.name,
                count    = count,
                metadata = source_.metadata,
            })
        end
        persistSlot(s)
        pushDealerSnapshot(src, s)
        pushOwnerSnapshot(s)

    elseif dir == "withdraw" then
        if not fromSlot then return end
        local it = slotGet(s, fromSlot)
        if not it or not it.name then return end
        local stack = tonumber(it.count) or 0
        if stack <= 0 then
            slotSet(s, fromSlot, nil)
            persistSlot(s); pushDealerSnapshot(src, s); pushOwnerSnapshot(s)
            return
        end
        local count = math.max(1, math.min(stack, math.floor(reqCount or stack)))
        if Inventory.AddItem(src, it.name, count, it.metadata) == false then
            notify(src, "Inventory full", "error") return
        end
        if count >= stack then
            slotSet(s, fromSlot, nil)
        else
            it.count = stack - count
            slotSet(s, fromSlot, it)
        end
        persistSlot(s)
        pushDealerSnapshot(src, s)
        pushOwnerSnapshot(s)

    elseif dir == "rearrange" then
        if not fromSlot or not toSlot or fromSlot == toSlot then return end
        if toSlot < 1 or toSlot > cap then return end
        local a = slotGet(s, fromSlot)
        if not a then return end
        local b = slotGet(s, toSlot)
        local stack = tonumber(a.count) or 0
        local count = tonumber(reqCount)
        if not count or count >= stack then count = stack end
        if count < 1 then return end
        local sameItem = b and b.name == a.name and metaEq(b.metadata, a.metadata)

        if count < stack then
            if b and not sameItem then
                pushDealerSnapshot(src, s) return
            end
            local newB = sameItem and b or { name = a.name, count = 0, metadata = a.metadata }
            newB.count = (tonumber(newB.count) or 0) + count
            slotSet(s, toSlot, newB)
            a.count = stack - count
            slotSet(s, fromSlot, a)
        else
            if sameItem then
                b.count = (tonumber(b.count) or 0) + count
                slotSet(s, toSlot, b)
                slotSet(s, fromSlot, nil)
            else
                slotSet(s, fromSlot, b)
                slotSet(s, toSlot, a)
            end
        end
        persistSlot(s)
        pushDealerSnapshot(src, s)
        pushOwnerSnapshot(s)
    end
end

-- ─── Summon ───────────────────────────────────────────────────────────────
-- Player asks the dealer to meet them. We push a single client event with
-- the dealer's identity + the player's coords; the player's client spawns
-- the ped near them and walks it over. Keeping ped lifecycle on the
-- summoning player's client means there's no global ped to despawn when
-- they wander away.

RegisterNetEvent("pickle_drugs:dealerSummon", function(slotId)
    local src = source
    local s = Slots[slotId]
    if not s then
        notify(src, "Couldn't find that dealer", "error") return
    end
    local cid = getCid(src)
    if not cid then
        notify(src, "No character id — can't route the summon", "error") return
    end
    if s.hired_by ~= cid then
        notify(src, "You haven't hired that dealer", "error") return
    end
    local ped = GetPlayerPed(src)
    if not ped or not DoesEntityExist(ped) then return end

    -- Pick a random deal point from a random of the dealer's covered
    -- zones — the dealer meets you at the same kind of customer drop
    -- point the offer scheduler uses.
    local elig = {}
    if Dealing and Dealing.GetZone then
        for _, zid in ipairs(s.zones or {}) do
            local z = Dealing.GetZone(zid)
            if z then elig[#elig + 1] = z end
        end
    end
    if #elig == 0 then
        notify(src, "Dealer has no zones assigned — set zones via /drugs first", "error")
        return
    end
    local zone = elig[math.random(1, #elig)]
    local n = (type(zone.deal_points) == "table" and #zone.deal_points) or 0
    local pt = Dealing.PickDealPoint(zone, n > 0 and math.random(1, n) or 1)
    if not pt then
        notify(src, ("Zone '%s' has no deal points"):format(zone.label or zone.id), "error")
        return
    end

    TriggerClientEvent("pickle_drugs:dealerSpawnNearMe", src, {
        slot      = {
            id         = s.id,
            first_name = s.first_name,
            last_name  = s.last_name,
            model      = s.model,
        },
        zone_label = zone.label or "the meet",
        pt         = pt,
    })
    notify(src, ("Meet %s at %s"):format(s.first_name, zone.label or "the drop"), "success")
end)

RegisterNetEvent("pickle_drugs:dealerDismissed", function(slotId)
    -- No-op marker event so the client can confirm dismissal locally —
    -- nothing to do server-side beyond what dismissDealer already did.
    local _ = slotId
end)

-- ─── Auto-take customer offers ────────────────────────────────────────────

--- Called by dealing/server.lua scheduler before sending an offer to a
--- player's phone. If a hired dealer owned by `cid` covers `zoneId` AND
--- has stock of `harvestItem`, this returns true and dispatches the
--- autonomous deal. The dealer ped gets broadcast as a customer-spawn
--- analogue (visible on every client) and walks to the customer ped to
--- complete the deal automatically.
---
--- Returns: ok (boolean), dealerSlotId (string|nil), reason (string|nil)
function Dealers.TryAutoFulfil(cid, zoneId, drug, harvestItem, qty, unitPrice)
    if not cid then return false end
    local ids = SlotByCid[cid]
    if not ids or #ids == 0 then return false end
    for _, sid in ipairs(ids) do
        local s = Slots[sid]
        if s and s.zones then
            local covers = false
            for _, zid in ipairs(s.zones) do if zid == zoneId then covers = true break end end
            if covers and dealerCountItem(s, harvestItem) >= qty then
                return true, sid
            end
        end
    end
    return false
end

--- Returns (slotId, stockCount) for the first hired dealer of `cid`
--- that covers `zoneId` and carries any stock of `harvestItem`. Used
--- by the dealing scheduler to pick the routing path BEFORE quantity
--- is known — it caps the random qty by the dealer's stock so the
--- subsequent SettleAutoDeal can't fail mid-flight.
function Dealers.GetCoveringSlotForItem(cid, zoneId, harvestItem)
    if not cid then return nil, 0 end
    local ids = SlotByCid[cid]
    if not ids or #ids == 0 then return nil, 0 end
    for _, sid in ipairs(ids) do
        local s = Slots[sid]
        if s and s.zones then
            local covers = false
            for _, zid in ipairs(s.zones) do if zid == zoneId then covers = true break end end
            if covers then
                local stock = dealerCountItem(s, harvestItem)
                if stock > 0 then return sid, stock end
            end
        end
    end
    return nil, 0
end

--- Sum of `harvestItem` across every hired dealer for this cid. Used
--- by `pickSaleableDrug` so a drug whose stock lives entirely on the
--- dealer (player has 0 on hand) still becomes a saleable option.
function Dealers.TotalStockForCid(cid, harvestItem)
    if not cid then return 0 end
    local ids = SlotByCid[cid]
    if not ids or #ids == 0 then return 0 end
    local total = 0
    for _, sid in ipairs(ids) do
        local s = Slots[sid]
        if s then total = total + dealerCountItem(s, harvestItem) end
    end
    return total
end

--- Called by the dealing module when an autonomous deal completes (the
--- dealer's ped reached the customer ped and finished the exchange).
--- Decrements stock, credits the owner cash (minus dealer cut), and
--- pushes a fresh snapshot back to the owner.
function Dealers.SettleAutoDeal(slotId, cid, harvestItem, qty, unitPrice)
    local s = Slots[slotId]
    if not s then return false end
    if dealerCountItem(s, harvestItem) < qty then return false end
    if not dealerRemoveItem(s, harvestItem, qty) then return false end

    local total = qty * unitPrice
    local cut   = math.floor(total * (s.cut_pct or 0.10))
    local owed  = total - cut
    -- Credit the owner. Find their src; if offline, they miss this deal
    -- (matches existing dealing semantics — payouts are immediate to
    -- whoever's online).
    if Framework and Framework.AddMoney then
        for _, src in ipairs(GetPlayers()) do
            local sid = tonumber(src)
            if sid and Framework.GetCitizenId(sid) == cid then
                Framework.AddMoney(sid, owed, "cash")
                notify(sid, ("%s closed a deal · +$%d (cut $%d)"):format(
                    s.first_name, owed, cut), "success")
                break
            end
        end
    end
    persistSlot(s)
    pushOwnerSnapshot(s)
    return true
end

-- ─── Callbacks ────────────────────────────────────────────────────────────

lib.callback.register("pickle_drugs:listDealers", function(src)
    -- Public slot list (no inventory). Owner inventory is pushed
    -- separately via dealerOwnerUpdate.
    local out = {}
    for _, s in pairs(Slots) do
        out[#out + 1] = {
            id         = s.id,
            first_name = s.first_name,
            last_name  = s.last_name,
            model      = s.model,
            zones      = s.zones,
            hired      = s.hired_by ~= nil,
            cut_pct    = s.cut_pct,
        }
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end)

lib.callback.register("pickle_drugs:listMyDealers", function(src)
    local cid = getCid(src)
    if not cid then return {} end
    local out = {}
    local ids = SlotByCid[cid] or {}
    for _, sid in ipairs(ids) do
        local s = Slots[sid]
        if s then
            out[#out + 1] = {
                id         = s.id,
                first_name = s.first_name,
                last_name  = s.last_name,
                model      = s.model,
                zones      = s.zones,
                inventory  = aggregateInventory(s),
                cut_pct    = s.cut_pct,
            }
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end)

-- ─── Player joining: rehydrate ────────────────────────────────────────────

AddEventHandler("playerJoining", function()
    local src = source
    SetTimeout(2000, function()
        if not GetPlayerName(src) then return end
        for _, s in pairs(Slots) do
            TriggerClientEvent("pickle_drugs:dealerSlotUpdate", src, {
                id         = s.id,
                first_name = s.first_name,
                last_name  = s.last_name,
                model      = s.model,
                zones      = s.zones,
                hired      = s.hired_by ~= nil,
                cut_pct    = s.cut_pct,
            })
        end
        local cid = getCid(src)
        if not cid then return end
        for _, sid in ipairs(SlotByCid[cid] or {}) do
            pushOwnerSnapshot(Slots[sid])
        end
    end)
end)

-- ─── Boot ────────────────────────────────────────────────────────────────

CreateThread(function()
    if not (MySQL and MySQL.ready) then return end
    MySQL.ready(function()
        local ok, err = pcall(function()
            MySQL.query.await([[
                CREATE TABLE IF NOT EXISTS pickle_drugs_dealers (
                    id            VARCHAR(64) PRIMARY KEY,
                    first_name    VARCHAR(32) NOT NULL,
                    last_name     VARCHAR(32) NOT NULL,
                    model         VARCHAR(64) NOT NULL,
                    zones         TEXT        NOT NULL,
                    hired_by      VARCHAR(64) NULL,
                    hired_by_name VARCHAR(64) NULL,
                    inventory     TEXT        NOT NULL,
                    cut_pct       DOUBLE      NOT NULL DEFAULT 0.10,
                    updated_at    BIGINT      NOT NULL DEFAULT 0,
                    INDEX (hired_by)
                )
            ]])
            loadAll()
        end)
        if not ok then
            print(("[pickle_drugs] dealers: DB error: %s"):format(tostring(err)))
        end
        local n = 0
        for _ in pairs(Slots) do n = n + 1 end
        print(("[pickle_drugs] dealers: ready · %d slot(s)"):format(n))

        for _, s in pairs(Slots) do
            TriggerClientEvent("pickle_drugs:dealerSlotUpdate", -1, {
                id = s.id, first_name = s.first_name, last_name = s.last_name,
                model = s.model, zones = s.zones, hired = s.hired_by ~= nil,
                cut_pct = s.cut_pct,
            })
        end
    end)
end)

-- ─── Public API ──────────────────────────────────────────────────────────

function Dealers.GetSlot(id) return Slots[id] end
function Dealers.SlotsForCid(cid) return SlotByCid[cid] or {} end
