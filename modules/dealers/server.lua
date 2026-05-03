-- Dealers server. Per-zone hireable NPC dealer slots — admin defines
-- a slot anchored to one zone (cut % only); each player gets their own
-- personalised view of every slot with a randomised, persistent name +
-- model so dealers feel unique to them rather than shared.
--
-- Storage layout:
--   * pickle_drugs_dealers           — admin slot row (id, zone_id, cut_pct).
--   * pickle_drugs_dealer_player     — per-(citizenid, slot_id) row holding
--                                      that player's first_name / last_name
--                                      / model / hired flag / inventory.
--                                      First time the player asks for a
--                                      slot we materialise the row with a
--                                      random pick from the pools below;
--                                      subsequent loads are stable.
--
-- The previous shared-instance hire model is gone: every player has their
-- own personalised hire/inventory state for every zone's slot.

Dealers = Dealers or {}

local AdminSlots   = {}    -- id → admin row { id, zone_id, cut_pct }
local PlayerSlots  = {}    -- cid → { slot_id → player row }
local DealerOpeners = {}   -- "cid|slotId" → src that has the dealer's locker UI open

-- ─── Random identity pools ───────────────────────────────────────────────
-- Kept inline rather than in Config to avoid bloat; admins who want to
-- reskin the pool can edit the lists here.

local FIRST_NAMES = {
    "Marcus","Eddie","Tony","Vince","Ray","Frankie","Mickey","Sal","Joey",
    "Dom","Rico","Carlos","Andre","Dwayne","Reggie","Tyrell","Jamal","Leo",
    "Wesley","Damon","Kyle","Brendan","Connor","Niko","Trev","Dre","Lex",
    "Lana","Maria","Nina","Trish","Vee","Kim","Dani","Rae","Marisol","Esme",
}
local LAST_NAMES = {
    "Hayes","Vasquez","Romero","Choi","Park","Adler","Boyd","Coleman",
    "Diaz","Doyle","Eames","Fischer","Galloway","Hicks","Iannelli","Jansen",
    "Kowalski","Lopez","Mason","Nash","Ortega","Patel","Quinn","Ross",
    "Santos","Torres","Underwood","Vargas","Walters","Xu","Young","Zane",
}
local MODEL_POOL = {
    "g_m_y_lost_01","g_m_y_lost_02","g_m_y_lost_03",
    "g_m_y_strpunk_01","g_m_y_strpunk_02",
    "g_m_y_ballaeast_01","g_m_y_ballaorig_01","g_m_y_ballasout_01",
    "a_m_y_hipster_01","a_m_y_hipster_02","a_m_y_skater_01",
    "a_m_m_business_01","a_m_y_business_01",
}

local function dealerSlotsCap()
    return (Config and Config.Dealing and tonumber(Config.Dealing.dealerInventorySlots)) or 25
end

local function defaultCutPct()
    return (Config and Config.Dealing and tonumber(Config.Dealing.dealerCutPct)) or 0.10
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

local function dealerAddItem(s, name, count, metadata)
    local cap = dealerSlotsCap()
    local remaining = count
    for i = 1, cap do
        local cur = slotGet(s, i)
        if cur and cur.name == name then
            cur.count = (tonumber(cur.count) or 0) + remaining
            slotSet(s, i, cur)
            remaining = 0
            break
        end
    end
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

local function getCid(src)
    return Framework and Framework.GetCitizenId and Framework.GetCitizenId(src) or nil
end

local function srcForCid(cid)
    if not cid then return nil end
    for _, src in ipairs(GetPlayers()) do
        local s = tonumber(src)
        if s and Framework and Framework.GetCitizenId then
            if Framework.GetCitizenId(s) == cid then return s end
        end
    end
    return nil
end

-- Deterministic-but-random pick from a pool, seeded by (cid, slotId, salt)
-- so the same player's view of the same slot stays consistent even if
-- the per-player row gets rebuilt from scratch.
local function stableHash(s)
    -- 32-bit FNV-1a — enough collision resistance for picking a name.
    local h = 2166136261
    for i = 1, #s do
        h = (h ~ string.byte(s, i)) * 16777619
        h = h % 4294967296
    end
    return h
end

local function pickFrom(pool, cid, slotId, salt)
    local h = stableHash((cid or "?") .. "|" .. (slotId or "?") .. "|" .. (salt or ""))
    return pool[(h % #pool) + 1]
end

-- ─── Row mappers ──────────────────────────────────────────────────────────

local function rowToAdminSlot(row)
    return {
        id         = row.id,
        zone_id    = row.zone_id or "",
        cut_pct    = tonumber(row.cut_pct) or defaultCutPct(),
        updated_at = tonumber(row.updated_at) or 0,
    }
end

local function rowToPlayerSlot(row)
    return {
        citizenid  = row.citizenid,
        slot_id    = row.slot_id,
        first_name = row.first_name or "Dealer",
        last_name  = row.last_name or "",
        model      = row.model or MODEL_POOL[1],
        hired      = tonumber(row.hired) == 1 or row.hired == true,
        inventory  = jsonDecodeObject(row.inventory),
        updated_at = tonumber(row.updated_at) or 0,
    }
end

-- ─── DB ───────────────────────────────────────────────────────────────────

local function persistAdminSlot(s)
    s.updated_at = now()
    MySQL.update.await([[
        INSERT INTO pickle_drugs_dealers (id, zone_id, cut_pct, updated_at)
        VALUES (?,?,?,?)
        ON DUPLICATE KEY UPDATE
            zone_id=VALUES(zone_id),
            cut_pct=VALUES(cut_pct),
            updated_at=VALUES(updated_at)
    ]], { s.id, s.zone_id, s.cut_pct, s.updated_at })
end

local function persistPlayerSlot(p)
    p.updated_at = now()
    MySQL.update.await([[
        INSERT INTO pickle_drugs_dealer_player
            (citizenid, slot_id, first_name, last_name, model, hired, inventory, updated_at)
        VALUES (?,?,?,?,?,?,?,?)
        ON DUPLICATE KEY UPDATE
            first_name=VALUES(first_name), last_name=VALUES(last_name),
            model=VALUES(model), hired=VALUES(hired),
            inventory=VALUES(inventory), updated_at=VALUES(updated_at)
    ]], {
        p.citizenid, p.slot_id, p.first_name, p.last_name, p.model,
        p.hired and 1 or 0,
        json.encode(p.inventory or {}),
        p.updated_at,
    })
end

local function deletePlayerRowsForSlot(slotId)
    MySQL.update.await(
        "DELETE FROM pickle_drugs_dealer_player WHERE slot_id=?", { slotId })
end

local function loadAdminSlots()
    local rows = MySQL.query.await("SELECT * FROM pickle_drugs_dealers") or {}
    for _, r in ipairs(rows) do AdminSlots[r.id] = rowToAdminSlot(r) end
end

-- Materialise the player's view of `slotId`. Loads from DB if it exists,
-- otherwise generates a random identity (deterministic per cid+slotId)
-- and persists. Returns the in-memory row.
local function ensurePlayerSlot(cid, slotId)
    if not cid or not slotId then return nil end
    PlayerSlots[cid] = PlayerSlots[cid] or {}
    if PlayerSlots[cid][slotId] then return PlayerSlots[cid][slotId] end

    local row = MySQL.single.await(
        "SELECT * FROM pickle_drugs_dealer_player WHERE citizenid=? AND slot_id=?",
        { cid, slotId })
    if row then
        PlayerSlots[cid][slotId] = rowToPlayerSlot(row)
        return PlayerSlots[cid][slotId]
    end

    local p = {
        citizenid  = cid,
        slot_id    = slotId,
        first_name = pickFrom(FIRST_NAMES, cid, slotId, "first"),
        last_name  = pickFrom(LAST_NAMES,  cid, slotId, "last"),
        model      = pickFrom(MODEL_POOL,  cid, slotId, "model"),
        hired      = false,
        inventory  = {},
        updated_at = now(),
    }
    PlayerSlots[cid][slotId] = p
    persistPlayerSlot(p)
    return p
end

-- ─── Public-shape builders ────────────────────────────────────────────────

local function publicSlotForPlayer(cid, slotId)
    local admin = AdminSlots[slotId]
    if not admin then return nil end
    local p = ensurePlayerSlot(cid, slotId)
    if not p then return nil end
    local agg = {}
    for _, it in pairs(p.inventory or {}) do
        if it and it.name then
            agg[it.name] = (agg[it.name] or 0) + (tonumber(it.count) or 0)
        end
    end
    return {
        id         = admin.id,
        zone_id    = admin.zone_id,
        cut_pct    = admin.cut_pct,
        first_name = p.first_name,
        last_name  = p.last_name,
        model      = p.model,
        hired      = p.hired,
        inventory  = agg,
    }
end

local function pushSlotToPlayer(cid, slotId)
    local src = srcForCid(cid)
    if not src then return end
    local v = publicSlotForPlayer(cid, slotId)
    if not v then return end
    TriggerClientEvent("pickle_drugs:dealerSlotUpdate", src, v)
end

local function pushAllSlotsToPlayer(src)
    local cid = getCid(src)
    if not cid then return end
    for slotId in pairs(AdminSlots) do
        local v = publicSlotForPlayer(cid, slotId)
        if v then
            TriggerClientEvent("pickle_drugs:dealerSlotUpdate", src, v)
        end
    end
end

local function broadcastAdminSlot(s)
    -- Admin tab payload — bare slot, no player identity. Sent to everyone
    -- but only the admin tab consumes it (others ignore).
    TriggerClientEvent("pickle_drugs:dealerAdminSlotUpdate", -1, {
        id = s.id, zone_id = s.zone_id, cut_pct = s.cut_pct,
    })
    -- Re-push the personalised view to every connected player so their
    -- phone reflects the (possibly new) cut / zone.
    for _, src in ipairs(GetPlayers()) do
        local sid = tonumber(src)
        local cid = sid and getCid(sid)
        if cid then
            local v = publicSlotForPlayer(cid, s.id)
            if v then TriggerClientEvent("pickle_drugs:dealerSlotUpdate", sid, v) end
        end
    end
end

local function broadcastSlotRemoved(id)
    TriggerClientEvent("pickle_drugs:dealerAdminSlotRemoved", -1, id)
    TriggerClientEvent("pickle_drugs:dealerSlotRemoved", -1, id)
end

-- ─── Admin CRUD ───────────────────────────────────────────────────────────

RegisterNetEvent("pickle_drugs:saveDealer", function(payload)
    local src = source
    if not adminCheck(src) then return end
    if type(payload) ~= "table" then return end
    local id = (type(payload.id) == "string" and payload.id ~= "") and payload.id or genId("dr")
    local s = AdminSlots[id] or { id = id, zone_id = "", cut_pct = defaultCutPct() }
    if type(payload.zone_id) == "string" and payload.zone_id ~= ""
        and Dealing and Dealing.GetZone and Dealing.GetZone(payload.zone_id)
    then
        s.zone_id = payload.zone_id
    end
    if type(payload.cut_pct) == "number" then
        s.cut_pct = math.max(0.0, math.min(1.0, payload.cut_pct))
    end
    if not s.zone_id or s.zone_id == "" then
        notify(src, "Dealer must belong to a zone", "error")
        return
    end
    AdminSlots[id] = s
    persistAdminSlot(s)
    broadcastAdminSlot(s)
    TriggerClientEvent("pickle_drugs:dealerSlotSaved", src, {
        tempId  = (type(payload.id) == "string" and payload.id) or "",
        savedId = id,
    })
end)

RegisterNetEvent("pickle_drugs:deleteDealer", function(id)
    local src = source
    if not adminCheck(src) then return end
    if not id or not AdminSlots[id] then return end
    AdminSlots[id] = nil
    -- Drop in-memory player views referencing the deleted slot.
    for cid, slots in pairs(PlayerSlots) do
        slots[id] = nil
        if next(slots) == nil then PlayerSlots[cid] = nil end
    end
    MySQL.update.await("DELETE FROM pickle_drugs_dealers WHERE id=?", { id })
    deletePlayerRowsForSlot(id)
    broadcastSlotRemoved(id)
end)

-- ─── Hire / dismiss ───────────────────────────────────────────────────────

RegisterNetEvent("pickle_drugs:hireDealer", function(slotId)
    local src = source
    if not AdminSlots[slotId] then return end
    local cid = getCid(src)
    if not cid then notify(src, "Couldn't read your character", "error") return end
    local p = ensurePlayerSlot(cid, slotId)
    if not p then return end
    if p.hired then
        notify(src, "Already hired", "inform")
        return
    end
    p.hired = true
    persistPlayerSlot(p)
    pushSlotToPlayer(cid, slotId)
    notify(src, ("Hired %s %s"):format(p.first_name, p.last_name), "success")
end)

RegisterNetEvent("pickle_drugs:dismissDealer", function(slotId)
    local src = source
    if not AdminSlots[slotId] then return end
    local cid = getCid(src)
    if not cid then return end
    local p = ensurePlayerSlot(cid, slotId)
    if not p or not p.hired then return end
    p.hired = false
    persistPlayerSlot(p)
    pushSlotToPlayer(cid, slotId)
    TriggerClientEvent("pickle_drugs:dealerOwnerRemoved", src, slotId)
    notify(src, ("Dismissed %s %s"):format(p.first_name, p.last_name), "inform")
end)

-- ─── Storage adapter ──────────────────────────────────────────────────────

local function dealerSnapshot(src, cid, slotId, p)
    local items = {}
    for slot, it in pairs(p.inventory or {}) do
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
        id     = "dealer:" .. slotId,
        kind   = "dealer",
        label  = ("%s %s"):format(p.first_name or "Dealer", p.last_name or ""),
        slots  = dealerSlotsCap(),
        items  = items,
        player = player,
        imagesPath = imagesPath,
    }
end

local function pushDealerSnapshot(src, cid, slotId, p)
    TriggerClientEvent("pickle_drugs:storageContents", src, dealerSnapshot(src, cid, slotId, p))
end

local function openerKey(cid, slotId) return (cid or "?") .. "|" .. (slotId or "?") end

function Dealers.OpenAsLocker(src, slotId)
    if not AdminSlots[slotId] then return nil end
    local cid = getCid(src)
    if not cid then return nil end
    local p = ensurePlayerSlot(cid, slotId)
    if not p or not p.hired then return nil end
    local k = openerKey(cid, slotId)
    if DealerOpeners[k] and DealerOpeners[k] ~= src then
        return { busy = true }
    end
    DealerOpeners[k] = src
    return dealerSnapshot(src, cid, slotId, p)
end

function Dealers.CloseAsLocker(src, slotId)
    local cid = getCid(src)
    if not cid then return end
    local k = openerKey(cid, slotId)
    if DealerOpeners[k] == src then
        DealerOpeners[k] = nil
        TriggerClientEvent("pickle_drugs:dealerExitAnim", src, slotId)
    end
end

function Dealers.HandleTransfer(src, slotId, payload)
    if not AdminSlots[slotId] then return end
    local cid = getCid(src)
    if not cid then return end
    local p = ensurePlayerSlot(cid, slotId)
    if not p or not p.hired then return end
    local k = openerKey(cid, slotId)
    if DealerOpeners[k] ~= src then return end
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

        local target = toSlot
        local merge = false
        if target and target >= 1 and target <= cap then
            local existing = slotGet(p, target)
            if not existing then
                -- empty
            elseif existing.name == source_.name and metaEq(existing.metadata, source_.metadata) then
                merge = true
            else
                target = nil
            end
        else
            target = nil
        end
        if not target then
            for i = 1, cap do if not slotGet(p, i) then target = i break end end
        end
        if not target then
            notify(src, "Dealer's bag is full", "error")
            pushDealerSnapshot(src, cid, slotId, p)
            return
        end

        if not Inventory.RemoveItem(src, source_.name, count, source_.metadata) then
            notify(src, "Couldn't take that item", "error") return
        end
        if merge then
            local existing = slotGet(p, target)
            existing.count = (tonumber(existing.count) or 0) + count
            slotSet(p, target, existing)
        else
            slotSet(p, target, {
                name     = source_.name,
                count    = count,
                metadata = source_.metadata,
            })
        end
        persistPlayerSlot(p)
        pushDealerSnapshot(src, cid, slotId, p)
        pushSlotToPlayer(cid, slotId)

    elseif dir == "withdraw" then
        if not fromSlot then return end
        local it = slotGet(p, fromSlot)
        if not it or not it.name then return end
        local stack = tonumber(it.count) or 0
        if stack <= 0 then
            slotSet(p, fromSlot, nil)
            persistPlayerSlot(p); pushDealerSnapshot(src, cid, slotId, p); pushSlotToPlayer(cid, slotId)
            return
        end
        local count = math.max(1, math.min(stack, math.floor(reqCount or stack)))
        if Inventory.AddItem(src, it.name, count, it.metadata) == false then
            notify(src, "Inventory full", "error") return
        end
        if count >= stack then
            slotSet(p, fromSlot, nil)
        else
            it.count = stack - count
            slotSet(p, fromSlot, it)
        end
        persistPlayerSlot(p)
        pushDealerSnapshot(src, cid, slotId, p)
        pushSlotToPlayer(cid, slotId)

    elseif dir == "rearrange" then
        if not fromSlot or not toSlot or fromSlot == toSlot then return end
        if toSlot < 1 or toSlot > cap then return end
        local a = slotGet(p, fromSlot)
        if not a then return end
        local b = slotGet(p, toSlot)
        local stack = tonumber(a.count) or 0
        local count = tonumber(reqCount)
        if not count or count >= stack then count = stack end
        if count < 1 then return end
        local sameItem = b and b.name == a.name and metaEq(b.metadata, a.metadata)

        if count < stack then
            if b and not sameItem then
                pushDealerSnapshot(src, cid, slotId, p) return
            end
            local newB = sameItem and b or { name = a.name, count = 0, metadata = a.metadata }
            newB.count = (tonumber(newB.count) or 0) + count
            slotSet(p, toSlot, newB)
            a.count = stack - count
            slotSet(p, fromSlot, a)
        else
            if sameItem then
                b.count = (tonumber(b.count) or 0) + count
                slotSet(p, toSlot, b)
                slotSet(p, fromSlot, nil)
            else
                slotSet(p, fromSlot, b)
                slotSet(p, toSlot, a)
            end
        end
        persistPlayerSlot(p)
        pushDealerSnapshot(src, cid, slotId, p)
        pushSlotToPlayer(cid, slotId)
    end
end

-- ─── Summon ───────────────────────────────────────────────────────────────

RegisterNetEvent("pickle_drugs:dealerSummon", function(slotId)
    local src = source
    local admin = AdminSlots[slotId]
    if not admin then
        notify(src, "Couldn't find that dealer", "error") return
    end
    local cid = getCid(src)
    if not cid then return end
    local p = ensurePlayerSlot(cid, slotId)
    if not p or not p.hired then
        notify(src, "You haven't hired that dealer", "error") return
    end
    local zone = Dealing and Dealing.GetZone and Dealing.GetZone(admin.zone_id) or nil
    if not zone then
        notify(src, "Dealer's zone is gone — re-create the slot", "error") return
    end
    local n = (type(zone.deal_points) == "table" and #zone.deal_points) or 0
    local pt = Dealing.PickDealPoint(zone, n > 0 and math.random(1, n) or 1)
    if not pt then
        notify(src, ("Zone '%s' has no deal points"):format(zone.label or zone.id), "error")
        return
    end

    TriggerClientEvent("pickle_drugs:dealerSpawnNearMe", src, {
        slot      = {
            id         = slotId,
            first_name = p.first_name,
            last_name  = p.last_name,
            model      = p.model,
        },
        zone_label = zone.label or "the meet",
        pt         = pt,
    })
    notify(src, ("Meet %s at %s"):format(p.first_name, zone.label or "the drop"), "success")
end)

RegisterNetEvent("pickle_drugs:dealerDismissed", function(slotId)
    local _ = slotId
end)

-- ─── Auto-take customer offers ────────────────────────────────────────────
--
-- All routing is now per-(cid, slotId). The dealing scheduler asks
-- "does this player have a hired dealer in zoneId carrying item?" and
-- gets back a slotId; at settle time it credits the player whose row
-- it is.

function Dealers.TotalStockForCid(cid, harvestItem)
    if not cid then return 0 end
    local slots = PlayerSlots[cid]
    if not slots then return 0 end
    local total = 0
    for _, p in pairs(slots) do
        if p.hired then total = total + dealerCountItem(p, harvestItem) end
    end
    return total
end

function Dealers.GetCoveringSlotForItem(cid, zoneId, harvestItem)
    if not cid then return nil, 0 end
    -- Walk every admin slot in the zone, see if the player has hired
    -- it (materialise on demand) and has stock.
    for slotId, admin in pairs(AdminSlots) do
        if admin.zone_id == zoneId then
            local p = ensurePlayerSlot(cid, slotId)
            if p and p.hired then
                local stock = dealerCountItem(p, harvestItem)
                if stock > 0 then return slotId, stock end
            end
        end
    end
    return nil, 0
end

function Dealers.SettleAutoDeal(slotId, cid, harvestItem, qty, unitPrice)
    local admin = AdminSlots[slotId]
    if not admin then return false end
    local p = ensurePlayerSlot(cid, slotId)
    if not p then return false end
    if dealerCountItem(p, harvestItem) < qty then return false end
    if not dealerRemoveItem(p, harvestItem, qty) then return false end

    local total = qty * unitPrice
    local cut   = math.floor(total * (admin.cut_pct or defaultCutPct()))
    local owed  = total - cut
    if Framework and Framework.AddMoney then
        local sid = srcForCid(cid)
        if sid then
            Framework.AddMoney(sid, owed, "cash")
            notify(sid, ("%s closed a deal · +$%d (cut $%d)"):format(
                p.first_name, owed, cut), "success")
        end
    end
    persistPlayerSlot(p)
    pushSlotToPlayer(cid, slotId)
    return true
end

-- ─── Callbacks ────────────────────────────────────────────────────────────

lib.callback.register("pickle_drugs:listDealersAdmin", function(_src)
    local out = {}
    for _, s in pairs(AdminSlots) do
        out[#out + 1] = { id = s.id, zone_id = s.zone_id, cut_pct = s.cut_pct }
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end)

lib.callback.register("pickle_drugs:listMyDealers", function(src)
    local cid = getCid(src)
    if not cid then return {} end
    local out = {}
    for slotId in pairs(AdminSlots) do
        local v = publicSlotForPlayer(cid, slotId)
        if v then out[#out + 1] = v end
    end
    table.sort(out, function(a, b)
        if a.zone_id ~= b.zone_id then return a.zone_id < b.zone_id end
        return a.id < b.id
    end)
    return out
end)

-- ─── Player joining: rehydrate ────────────────────────────────────────────

AddEventHandler("playerJoining", function()
    local src = source
    SetTimeout(2500, function()
        if not GetPlayerName(src) then return end
        pushAllSlotsToPlayer(src)
    end)
end)

-- ─── Boot ────────────────────────────────────────────────────────────────

CreateThread(function()
    if not (MySQL and MySQL.ready) then return end
    MySQL.ready(function()
        local ok, err = pcall(function()
            -- The dealers schema was redesigned (zone-anchored, cut-only;
            -- per-player identity moved into pickle_drugs_dealer_player).
            -- Drop the legacy table if it predates the new shape so the
            -- CREATE TABLE below can build the new layout. Detect by the
            -- absence of the new `zone_id` column.
            local cols = MySQL.query.await(
                "SHOW COLUMNS FROM pickle_drugs_dealers WHERE Field='zone_id'"
            ) or {}
            if #cols == 0 then
                local exists = MySQL.query.await(
                    "SHOW TABLES LIKE 'pickle_drugs_dealers'"
                ) or {}
                if #exists > 0 then
                    MySQL.query.await("DROP TABLE pickle_drugs_dealers")
                end
            end
            MySQL.query.await([[
                CREATE TABLE IF NOT EXISTS pickle_drugs_dealers (
                    id         VARCHAR(64) PRIMARY KEY,
                    zone_id    VARCHAR(64) NOT NULL,
                    cut_pct    DOUBLE      NOT NULL DEFAULT 0.10,
                    updated_at BIGINT      NOT NULL DEFAULT 0,
                    INDEX (zone_id)
                )
            ]])
            MySQL.query.await([[
                CREATE TABLE IF NOT EXISTS pickle_drugs_dealer_player (
                    citizenid  VARCHAR(64) NOT NULL,
                    slot_id    VARCHAR(64) NOT NULL,
                    first_name VARCHAR(32) NOT NULL,
                    last_name  VARCHAR(32) NOT NULL,
                    model      VARCHAR(64) NOT NULL,
                    hired      TINYINT(1)  NOT NULL DEFAULT 0,
                    inventory  TEXT        NOT NULL,
                    updated_at BIGINT      NOT NULL DEFAULT 0,
                    PRIMARY KEY (citizenid, slot_id),
                    INDEX (slot_id)
                )
            ]])
            loadAdminSlots()
        end)
        if not ok then
            print(("[pickle_drugs] dealers: DB error: %s"):format(tostring(err)))
        end
        local n = 0
        for _ in pairs(AdminSlots) do n = n + 1 end
        print(("[pickle_drugs] dealers: ready · %d slot(s)"):format(n))

        -- Push admin payload (for the open admin tab) and the personalised
        -- per-player view to every connected player on hot-restart.
        for _, s in pairs(AdminSlots) do
            TriggerClientEvent("pickle_drugs:dealerAdminSlotUpdate", -1, {
                id = s.id, zone_id = s.zone_id, cut_pct = s.cut_pct,
            })
        end
        for _, src in ipairs(GetPlayers()) do
            local sid = tonumber(src)
            if sid then pushAllSlotsToPlayer(sid) end
        end
    end)
end)

-- ─── Public API ──────────────────────────────────────────────────────────

function Dealers.GetAdminSlot(id)            return AdminSlots[id] end
function Dealers.GetPlayerSlot(cid, slotId)  return ensurePlayerSlot(cid, slotId) end
