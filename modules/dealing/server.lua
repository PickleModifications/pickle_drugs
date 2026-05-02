-- Dealing server. Owns the canonical Customer + Zone roster, persists them,
-- and runs the offer scheduler that pushes deal messages to players who
-- hold any saleable drug item. Handles negotiation, acceptance, expiry,
-- and the final hand-off (item consume + cash payout). Mirrors the
-- patterns used by employees + housing_admin so the admin UI plumbing is
-- familiar and the client-side ped lifecycle can be a thin port of
-- modules/employees/client.lua.

Dealing = Dealing or {}

local Zones        = {}      -- id → row
local Customers    = {}      -- id → row
local ActiveDeals  = {}      -- id → deal row
-- Per-player per-customer "do not disturb" timestamps. {citizenid} → {customerId → epochMs}
local Cooldowns    = {}
-- Per-player next-offer-eligible timestamp. {citizenid} → epochMs.
local PlayerNext   = {}

local function now() return os.time() * 1000 end

local function notify(src, msg, type_)
    if not src or src == 0 then return end
    TriggerClientEvent("ox_lib:notify", src, {
        title       = "Dealing",
        description = msg,
        type        = type_ or "inform",
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

local function genId(prefix)
    -- Mirrors employees' id pattern: prefix + ms timestamp + 4-digit
    -- random tail. Collision-safe enough for an admin tool.
    return ("%s_%d_%d"):format(prefix, now(), math.random(1000, 9999))
end

-- ─── Load / persist ───────────────────────────────────────────────────────

local function rowToZone(row)
    -- Shape kind ('circle' or 'polygon'). Old rows missing the column
    -- are treated as circles. Polygon zones store their vertices in the
    -- `points` JSON column; circle zones use center_x/center_y + radius.
    local kind = row.kind
    if kind ~= "polygon" then kind = "circle" end
    return {
        id           = row.id,
        label        = row.label or "Zone",
        kind         = kind,
        color        = (type(row.color) == "string" and row.color ~= "") and row.color or "#38bdf8",
        center_x     = tonumber(row.center_x) or 0,
        center_y     = tonumber(row.center_y) or 0,
        center_z     = tonumber(row.center_z) or 0,
        radius       = tonumber(row.radius) or 50,
        points       = jsonDecodeArray(row.points),
        risk_mult    = tonumber(row.risk_mult) or 1.0,
        deal_points  = jsonDecodeArray(row.deal_points),
        updated_at   = tonumber(row.updated_at) or 0,
    }
end

local function rowToCustomer(row)
    return {
        id            = row.id,
        first_name    = row.first_name or "Customer",
        last_name     = row.last_name or "",
        model         = row.model or "a_m_m_business_01",
        zones         = jsonDecodeArray(row.zones),
        idle_scenario = row.idle_scenario or "WORLD_HUMAN_SMOKING",
        updated_at    = tonumber(row.updated_at) or 0,
    }
end

local function rowToDeal(row)
    return {
        id            = row.id,
        customer_id   = row.customer_id,
        zone_id       = row.zone_id,
        deal_point    = tonumber(row.deal_point) or 1,
        citizenid     = row.citizenid,
        drug          = row.drug,
        qty           = tonumber(row.qty) or 0,
        unit_price    = tonumber(row.unit_price) or 0,
        original_qty  = tonumber(row.original_qty) or tonumber(row.qty) or 0,
        original_unit = tonumber(row.original_unit) or tonumber(row.unit_price) or 0,
        state         = row.state or "offered",
        accepted_at   = tonumber(row.accepted_at) or 0,
        expires_at    = tonumber(row.expires_at) or 0,
        created_at    = tonumber(row.created_at) or 0,
        countered_by  = row.countered_by, -- "player" | "customer" | nil
    }
end

local function loadAll()
    local zr = MySQL.query.await("SELECT * FROM pickle_drugs_dealing_zones") or {}
    for _, r in ipairs(zr) do Zones[r.id] = rowToZone(r) end
    local cr = MySQL.query.await("SELECT * FROM pickle_drugs_dealing_customers") or {}
    for _, r in ipairs(cr) do Customers[r.id] = rowToCustomer(r) end
    -- Hard-reset all in-progress deals on resource restart. Resuming
    -- mid-flight deals through a restart was confusing — the HUD would
    -- show entries the player hadn't really opted into and the
    -- customer ped re-spawn was racy. Treat a restart as a clean slate
    -- (the scheduler will offer fresh deals shortly after boot).
    local purged = MySQL.update.await(
        "DELETE FROM pickle_drugs_dealing_active"
    ) or 0
    if purged > 0 then
        print(("[pickle_drugs] dealing: purged %d in-flight deal(s) on boot"):format(purged))
    end
end

local function persistZone(z)
    z.updated_at = now()
    MySQL.update.await([[
        INSERT INTO pickle_drugs_dealing_zones
            (id, label, kind, color, center_x, center_y, center_z, radius, points,
             risk_mult, deal_points, updated_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
        ON DUPLICATE KEY UPDATE
            label=VALUES(label), kind=VALUES(kind), color=VALUES(color),
            center_x=VALUES(center_x), center_y=VALUES(center_y),
            center_z=VALUES(center_z), radius=VALUES(radius),
            points=VALUES(points), risk_mult=VALUES(risk_mult),
            deal_points=VALUES(deal_points), updated_at=VALUES(updated_at)
    ]], {
        z.id, z.label, z.kind or "circle", z.color or "#38bdf8",
        z.center_x, z.center_y, z.center_z, z.radius,
        json.encode(z.points or {}),
        z.risk_mult,
        json.encode(z.deal_points or {}), z.updated_at,
    })
end

local function persistCustomer(c)
    c.updated_at = now()
    MySQL.update.await([[
        INSERT INTO pickle_drugs_dealing_customers
            (id, first_name, last_name, model, zones, idle_scenario, updated_at)
        VALUES (?,?,?,?,?,?,?)
        ON DUPLICATE KEY UPDATE
            first_name=VALUES(first_name), last_name=VALUES(last_name),
            model=VALUES(model), zones=VALUES(zones),
            idle_scenario=VALUES(idle_scenario), updated_at=VALUES(updated_at)
    ]], {
        c.id, c.first_name, c.last_name, c.model,
        json.encode(c.zones or {}), c.idle_scenario, c.updated_at,
    })
end

local function persistDeal(d)
    MySQL.update.await([[
        INSERT INTO pickle_drugs_dealing_active
            (id, customer_id, zone_id, deal_point, citizenid, drug, qty, unit_price,
             original_qty, original_unit, state, accepted_at, expires_at, created_at, countered_by)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON DUPLICATE KEY UPDATE
            qty=VALUES(qty), unit_price=VALUES(unit_price), state=VALUES(state),
            accepted_at=VALUES(accepted_at), expires_at=VALUES(expires_at),
            countered_by=VALUES(countered_by)
    ]], {
        d.id, d.customer_id, d.zone_id, d.deal_point, d.citizenid, d.drug,
        d.qty, d.unit_price, d.original_qty, d.original_unit,
        d.state, d.accepted_at, d.expires_at, d.created_at, d.countered_by,
    })
end

local function deleteDealRow(id)
    MySQL.update.await("DELETE FROM pickle_drugs_dealing_active WHERE id=?", { id })
end

-- ─── Broadcasts ───────────────────────────────────────────────────────────

local function broadcastZone(z)
    TriggerClientEvent("pickle_drugs:dealingZoneUpdate", -1, z)
end
local function broadcastZoneRemoved(id)
    TriggerClientEvent("pickle_drugs:dealingZoneRemoved", -1, id)
end
local function broadcastCustomer(c)
    TriggerClientEvent("pickle_drugs:dealingCustomerUpdate", -1, c)
end
local function broadcastCustomerRemoved(id)
    TriggerClientEvent("pickle_drugs:dealingCustomerRemoved", -1, id)
end

--- Pushes a deal update only to the player who owns it. We need a numeric
--- player source for that, derived from citizenid via the framework.
local function srcForCitizenid(cid)
    if not cid then return nil end
    -- Cheap probe: walk all players, ask the framework for their cid.
    for _, src in ipairs(GetPlayers()) do
        local s = tonumber(src)
        if s and Framework and Framework.GetCitizenId then
            if Framework.GetCitizenId(s) == cid then return s end
        end
    end
    return nil
end

local function broadcastDealToOwner(d)
    local src = srcForCitizenid(d.citizenid)
    if not src then return end
    TriggerClientEvent("pickle_drugs:dealingActiveUpdate", src, d)
end

local function broadcastDealRemovedToOwner(d)
    local src = srcForCitizenid(d.citizenid)
    if not src then return end
    TriggerClientEvent("pickle_drugs:dealingActiveRemoved", src, d.id)
end

--- An accepted deal needs the customer ped to spawn for everyone in the
--- world (they're standing in bucket 0, public). Use the all-clients
--- channel for accept/complete/expire so other players see the ped too.
--- We include the owner's *server source* alongside their citizenid so
--- clients can determine "is this my deal?" without depending on the
--- framework's LocalPlayer.state.citizenid plumbing being populated.
local function broadcastCustomerSpawn(d)
    local zone = Zones[d.zone_id]
    local pt   = zone and Dealing.PickDealPoint(zone, d.deal_point) or nil
    local cust = Customers[d.customer_id]
    if not (zone and pt and cust) then return end
    local ownerSrc = srcForCitizenid(d.citizenid)
    TriggerClientEvent("pickle_drugs:dealingCustomerSpawn", -1, {
        deal_id    = d.id,
        customer   = cust,
        zone_id    = zone.id,
        pt         = pt,
        owner_cid  = d.citizenid,
        owner_src  = ownerSrc,
    })
end

local function broadcastCustomerDespawn(dealId)
    TriggerClientEvent("pickle_drugs:dealingCustomerDespawn", -1, dealId)
end

-- ─── Admin events ─────────────────────────────────────────────────────────

RegisterNetEvent("pickle_drugs:saveDealingZone", function(payload)
    local src = source
    if not adminCheck(src) then return end
    if type(payload) ~= "table" then return end
    local id = (type(payload.id) == "string" and payload.id ~= "") and payload.id or genId("dz")
    local z = Zones[id] or { id = id, deal_points = {}, points = {}, kind = "circle" }
    z.label       = tostring(payload.label or z.label or "Zone")
    if payload.kind == "polygon" or payload.kind == "circle" then
        z.kind = payload.kind
    end
    z.kind        = z.kind or "circle"
    -- Loose hex-color validation: must be #RRGGBB. Anything else
    -- falls back to whatever was previously stored (or the default).
    if type(payload.color) == "string" and payload.color:match("^#%x%x%x%x%x%x$") then
        z.color = payload.color
    end
    z.color       = z.color or "#38bdf8"
    z.center_x    = tonumber(payload.center_x) or z.center_x or 0
    z.center_y    = tonumber(payload.center_y) or z.center_y or 0
    z.center_z    = tonumber(payload.center_z) or z.center_z or 0
    z.radius      = math.max(5, tonumber(payload.radius) or z.radius or 50)
    z.risk_mult   = tonumber(payload.risk_mult) or z.risk_mult or 1.0
    -- Polygon vertices (only meaningful when kind == "polygon" but
    -- kept on the row regardless so toggling shape doesn't lose data).
    if type(payload.points) == "table" then
        local cleaned = {}
        for _, pt in ipairs(payload.points) do
            if type(pt) == "table" and pt.x and pt.y then
                cleaned[#cleaned + 1] = {
                    x = tonumber(pt.x), y = tonumber(pt.y),
                }
            end
        end
        z.points = cleaned
    end
    if type(payload.deal_points) == "table" then
        local cleaned = {}
        for _, pt in ipairs(payload.deal_points) do
            if type(pt) == "table" and pt.x and pt.y and pt.z then
                cleaned[#cleaned + 1] = {
                    x = tonumber(pt.x), y = tonumber(pt.y),
                    z = tonumber(pt.z), w = tonumber(pt.w) or 0.0,
                }
            end
        end
        z.deal_points = cleaned
    end
    Zones[id] = z
    persistZone(z)
    broadcastZone(z)
    -- Per-source ack so the editor can adopt the assigned id when the
    -- save was for a brand-new zone (payload.id was empty). Mirrors
    -- the `interiorSaved` flow in housing_admin.
    TriggerClientEvent("pickle_drugs:dealingZoneSaved", src, {
        tempId  = (type(payload.id) == "string" and payload.id) or "",
        savedId = id,
    })
end)

RegisterNetEvent("pickle_drugs:deleteDealingZone", function(id)
    local src = source
    if not adminCheck(src) then return end
    if not id or not Zones[id] then return end
    Zones[id] = nil
    -- Drop any customer references to this zone so the offer scheduler
    -- doesn't keep trying to use it.
    for _, c in pairs(Customers) do
        local kept = {}
        for _, zid in ipairs(c.zones or {}) do
            if zid ~= id then kept[#kept + 1] = zid end
        end
        if #kept ~= #(c.zones or {}) then
            c.zones = kept
            persistCustomer(c)
            broadcastCustomer(c)
        end
    end
    MySQL.update.await("DELETE FROM pickle_drugs_dealing_zones WHERE id=?", { id })
    broadcastZoneRemoved(id)
end)

RegisterNetEvent("pickle_drugs:saveDealingCustomer", function(payload)
    local src = source
    if not adminCheck(src) then return end
    if type(payload) ~= "table" then return end
    local id = (type(payload.id) == "string" and payload.id ~= "") and payload.id or genId("dc")
    local c = Customers[id] or { id = id, zones = {} }
    c.first_name    = tostring(payload.first_name or c.first_name or "Customer")
    c.last_name     = tostring(payload.last_name  or c.last_name  or "")
    c.model         = tostring(payload.model      or c.model      or "a_m_m_business_01")
    c.idle_scenario = tostring(payload.idle_scenario or c.idle_scenario or "WORLD_HUMAN_SMOKING")
    if type(payload.zones) == "table" then
        local cleaned = {}
        for _, zid in ipairs(payload.zones) do
            if type(zid) == "string" and Zones[zid] then cleaned[#cleaned + 1] = zid end
        end
        c.zones = cleaned
    end
    Customers[id] = c
    persistCustomer(c)
    broadcastCustomer(c)
end)

RegisterNetEvent("pickle_drugs:deleteDealingCustomer", function(id)
    local src = source
    if not adminCheck(src) then return end
    if not id or not Customers[id] then return end
    Customers[id] = nil
    -- Cancel any active deals for this customer.
    for did, d in pairs(ActiveDeals) do
        if d.customer_id == id then
            ActiveDeals[did] = nil
            deleteDealRow(did)
            broadcastDealRemovedToOwner(d)
            if d.state == "accepted" then broadcastCustomerDespawn(did) end
        end
    end
    MySQL.update.await("DELETE FROM pickle_drugs_dealing_customers WHERE id=?", { id })
    broadcastCustomerRemoved(id)
end)

-- ─── Callbacks ────────────────────────────────────────────────────────────

lib.callback.register("pickle_drugs:listDealing", function(_src)
    -- No admin gate — zone + customer metadata is read by the
    -- Messages app on every player's client to render an offer's
    -- "Meet me in <zone>" label. Nothing sensitive: just labels,
    -- colors, ped models, scenario names. The mutate paths
    -- (saveDealingZone / saveDealingCustomer / delete*) are still
    -- admin-gated.
    local zones, customers = {}, {}
    for _, z in pairs(Zones) do zones[#zones + 1] = z end
    for _, c in pairs(Customers) do customers[#customers + 1] = c end
    return { zones = zones, customers = customers }
end)

lib.callback.register("pickle_drugs:listMyDeals", function(src)
    if not Framework or not Framework.GetCitizenId then return {} end
    local cid = Framework.GetCitizenId(src)
    if not cid then return {} end
    local out = {}
    for _, d in pairs(ActiveDeals) do
        if d.citizenid == cid and d.state ~= "completed" and d.state ~= "failed" then
            out[#out + 1] = d
        end
    end
    table.sort(out, function(a, b) return (a.created_at or 0) > (b.created_at or 0) end)
    return out
end)

-- ─── Offer scheduler ──────────────────────────────────────────────────────

--- Drugs the player currently holds, returning { drug, qty } for the first
--- one with stock. We pick a drug per-offer rather than offering combinations.
local function pickSaleableDrug(src)
    if not (Inventory and Inventory.GetItemCount) then return nil end
    local options = {}
    for drug, cfg in pairs(Config.Drugs or {}) do
        local item = cfg.cutting and cfg.cutting.harvestItem
        if item and cfg.deal and cfg.deal.basePrice then
            local owned = Inventory.GetItemCount(src, item) or 0
            if owned > 0 then
                options[#options + 1] = { drug = drug, item = item, owned = owned, base = cfg.deal.basePrice }
            end
        end
    end
    if #options == 0 then return nil end
    return options[math.random(1, #options)]
end

--- True if this zone is usable as an offer target. Any zone with a
--- valid shape works — explicit deal_points are optional now (a zone
--- without them spawns the customer at the centre/centroid via
--- Dealing.PickDealPoint's synthetic-point fallback).
local function zoneUsable(z)
    if not z then return false end
    if type(z.deal_points) == "table" and #z.deal_points > 0 then return true end
    if z.kind == "polygon" then
        return type(z.points) == "table" and #z.points >= 3
    end
    return (tonumber(z.radius) or 0) > 0
end

--- Customer eligible for offering to (cid). Must (a) have ≥1 usable
--- zone, (b) not be on per-player cooldown.
local function pickCustomerForPlayer(cid)
    local nowMs = now()
    local pool = {}
    for _, c in pairs(Customers) do
        local hasZone = false
        for _, zid in ipairs(c.zones or {}) do
            if zoneUsable(Zones[zid]) then hasZone = true break end
        end
        if hasZone then
            local cd = (Cooldowns[cid] or {})[c.id] or 0
            if nowMs >= cd then pool[#pool + 1] = c end
        end
    end
    if #pool == 0 then return nil end
    return pool[math.random(1, #pool)]
end

--- Picks a (zone, dealPointIdx) pair for an eligible customer. Random
--- across all of the customer's usable zones. ptIdx is 1 when the zone
--- has no explicit deal_points (PickDealPoint falls back to synthetic
--- centre); otherwise a random valid index into deal_points.
local function pickZoneForCustomer(c)
    local elig = {}
    for _, zid in ipairs(c.zones or {}) do
        local z = Zones[zid]
        if zoneUsable(z) then elig[#elig + 1] = z end
    end
    if #elig == 0 then return nil end
    local z = elig[math.random(1, #elig)]
    local n = (type(z.deal_points) == "table" and #z.deal_points or 0)
    return z, n > 0 and math.random(1, n) or 1
end

--- Returns `ok, reason`. `reason` is a short human-readable string
--- describing why an offer couldn't be made — surfaced via the
--- /dealtest admin command and (when Config.Debug) via debugPrint
--- so the gap between "I have stock + customers" and "no offer landed"
--- is visible without speculation.
local function tryOfferToPlayer(src, cid)
    local sale = pickSaleableDrug(src)
    if not sale then
        return false, "player holds no saleable drug item (need a drug whose Config.Drugs[*].cutting.harvestItem is in inventory and Config.Drugs[*].deal.basePrice is set)"
    end
    local cust = pickCustomerForPlayer(cid)
    if not cust then
        local total, withZone, onCd, noZones = 0, 0, 0, 0
        local nowMs = now()
        for _, c in pairs(Customers) do
            total = total + 1
            if not c.zones or #c.zones == 0 then noZones = noZones + 1 end
            local ok = false
            for _, zid in ipairs(c.zones or {}) do
                if zoneUsable(Zones[zid]) then ok = true break end
            end
            if ok then
                withZone = withZone + 1
                local cd = (Cooldowns[cid] or {})[c.id] or 0
                if nowMs < cd then onCd = onCd + 1 end
            end
        end
        return false, ("no eligible customer (total=%d, with-usable-zone=%d, no-zones-assigned=%d, on-cooldown=%d)"):format(total, withZone, noZones, onCd)
    end
    local zone, ptIdx = pickZoneForCustomer(cust)
    if not zone then
        return false, ("customer '%s %s' has no usable zones"):format(cust.first_name, cust.last_name)
    end

    local maxQty = math.min(Config.Dealing.maxQty or 10, sale.owned)
    local qty = math.random(1, maxQty)
    local jitter = (Config.Dealing.priceJitter or 0.15)
    local mult = (zone.risk_mult or 1.0) * (1.0 + (math.random() * 2 - 1) * jitter)
    local unit = math.max(1, math.floor(sale.base * mult + 0.5))

    local deal = {
        id            = genId("dl"),
        customer_id   = cust.id,
        zone_id       = zone.id,
        deal_point    = ptIdx,
        citizenid     = cid,
        drug          = sale.drug,
        qty           = qty,
        unit_price    = unit,
        original_qty  = qty,
        original_unit = unit,
        state         = "offered",
        accepted_at   = 0,
        expires_at    = 0,
        created_at    = now(),
        countered_by  = nil,
    }
    ActiveDeals[deal.id] = deal
    persistDeal(deal)
    broadcastDealToOwner(deal)
    return true, ("offered %dx %s @ $%d each from %s %s"):format(qty, sale.drug, unit, cust.first_name, cust.last_name)
end

local SCHEDULER_RUNNING = false
local function startScheduler()
    if SCHEDULER_RUNNING then return end
    SCHEDULER_RUNNING = true
    CreateThread(function()
        -- Short warm-up so the scheduler runs once shortly after boot
        -- rather than waiting a full schedulerTickMs (30s) for the
        -- first attempt — players typically expect a deal to land
        -- within a minute of having stock + a configured roster.
        Wait(8000)
        while true do
            local nowMs = now()

            -- Expiry sweep first so an expired deal doesn't block a
            -- fresh offer from the same customer.
            for did, d in pairs(ActiveDeals) do
                if d.state == "accepted" and d.expires_at > 0 and nowMs > d.expires_at then
                    d.state = "failed"
                    persistDeal(d)
                    -- Cooldown so the same customer doesn't re-spam.
                    Cooldowns[d.citizenid] = Cooldowns[d.citizenid] or {}
                    Cooldowns[d.citizenid][d.customer_id] =
                        nowMs + (Config.Dealing.failureCooldownMs or 600000)
                    broadcastDealRemovedToOwner(d)
                    broadcastCustomerDespawn(did)
                    ActiveDeals[did] = nil
                    deleteDealRow(did)
                end
            end

            -- Offer scheduling.
            for _, src in ipairs(GetPlayers()) do
                local s = tonumber(src)
                local cid = s and Framework and Framework.GetCitizenId
                    and Framework.GetCitizenId(s) or nil
                if cid then
                    local nextOk = PlayerNext[cid] or 0
                    if nowMs >= nextOk then
                        local ok, reason = tryOfferToPlayer(s, cid)
                        if Config and Config.Debug then
                            debugPrint(("dealing: tick src=%d cid=%s → %s · %s"):format(
                                s, tostring(cid), ok and "offered" or "skipped", reason or "?"))
                        end
                        if ok then
                            -- Random spread so not every player gets
                            -- offered exactly on the same tick.
                            local base = Config.Dealing.offerIntervalMs or 240000
                            local spread = math.floor(base * 0.4)
                            PlayerNext[cid] = nowMs + base + math.random(-spread, spread)
                        else
                            -- No offer was possible (no stock, no eligible
                            -- customer, etc) — try again next tick.
                            PlayerNext[cid] = nowMs + (Config.Dealing.schedulerTickMs or 30000)
                        end
                    end
                end
            end
            Wait(Config.Dealing.schedulerTickMs or 30000)
        end
    end)
end

--- Admin diagnostic: forces an offer attempt for the calling player
--- (or the supplied source) right now, bypassing the per-player
--- cooldown. Reports the outcome in chat. Wired below to /dealtest.
local function diagnoseOffer(src)
    local s = tonumber(src)
    if not s then return "bad source" end
    local cid = Framework and Framework.GetCitizenId and Framework.GetCitizenId(s) or nil
    if not cid then
        return "Framework.GetCitizenId returned nil — your framework bridge isn't wired (try qb / qbx / esx; standalone falls back to a per-session id)"
    end
    -- Reset cooldown so the diagnostic isn't masked by an earlier
    -- successful offer.
    PlayerNext[cid] = 0
    if Cooldowns[cid] then Cooldowns[cid] = {} end
    local ok, reason = tryOfferToPlayer(s, cid)
    return ("%s · cid=%s · %s"):format(ok and "OK" or "SKIP", cid, reason or "?")
end

RegisterCommand("dealtest", function(source)
    if not adminCheck(source) then return end
    local out = diagnoseOffer(source)
    print(("[pickle_drugs] /dealtest · src=%s · %s"):format(tostring(source), out))
    notify(source, out, out:sub(1, 2) == "OK" and "success" or "error")
end, false)

-- ─── Player-driven flow: accept / counter / reject / complete ────────────

local function getDealForPlayer(src, dealId)
    if not dealId then return nil end
    local d = ActiveDeals[dealId]
    if not d then return nil end
    local cid = Framework and Framework.GetCitizenId and Framework.GetCitizenId(src) or nil
    if not cid or d.citizenid ~= cid then return nil end
    return d
end

RegisterNetEvent("pickle_drugs:dealingAccept", function(dealId)
    local src = source
    local d = getDealForPlayer(src, dealId)
    if not d then return end
    if d.state ~= "offered" and d.state ~= "negotiating" then return end
    d.state       = "accepted"
    d.accepted_at = now()
    d.expires_at  = d.accepted_at + (Config.Dealing.completeWindowMs or 360000)
    persistDeal(d)
    broadcastDealToOwner(d)
    broadcastCustomerSpawn(d)
end)

RegisterNetEvent("pickle_drugs:dealingReject", function(dealId)
    local src = source
    local d = getDealForPlayer(src, dealId)
    if not d then return end
    -- Brief cooldown so the player isn't immediately re-offered the
    -- same customer.
    Cooldowns[d.citizenid] = Cooldowns[d.citizenid] or {}
    Cooldowns[d.citizenid][d.customer_id] =
        now() + math.floor((Config.Dealing.cooldownMs or 300000) * 0.5)
    ActiveDeals[d.id] = nil
    deleteDealRow(d.id)
    broadcastDealRemovedToOwner(d)
end)

--- Player counters with a new (qty, unit_price). Customer's response is
--- deterministic from the threshold:
---   total ≥ 90% of original ask → accept (state stays offered → needs
---     a follow-up Accept tap from the player, or set straight to
---     accepted? we keep it as a fresh "accept-now" offer so the player
---     opts in)
---   total ≥ 75% of original     → customer counter once (split the
---     difference). Sets countered_by="customer".
---   below 75%                   → reject.
RegisterNetEvent("pickle_drugs:dealingCounter", function(dealId, qty, unitPrice)
    local src = source
    local d = getDealForPlayer(src, dealId)
    if not d then return end
    if d.state ~= "offered" and d.state ~= "negotiating" then return end
    qty = math.floor(tonumber(qty) or 0)
    unitPrice = math.floor(tonumber(unitPrice) or 0)
    if qty <= 0 or unitPrice <= 0 then return end
    -- Don't allow proposing more than the original qty — it's a
    -- negotiation, not a re-spec.
    if qty > (d.original_qty or 0) then qty = d.original_qty end

    local origTotal   = (d.original_qty or 1) * (d.original_unit or 1)
    local playerTotal = qty * unitPrice
    local ratio       = playerTotal / math.max(1, origTotal)
    local accThr      = Config.Dealing.acceptThreshold or 0.90
    local rejectThr   = accThr - 0.15

    if ratio >= accThr then
        -- Customer agrees to player's terms but the player still
        -- explicitly accepts to commit (UI shows "they agreed — Accept").
        d.qty          = qty
        d.unit_price   = unitPrice
        d.state        = "negotiating"
        d.countered_by = "customer_agreed"
    elseif ratio >= rejectThr then
        -- Counter once: midpoint between the player's ask and the
        -- original. Customer never counters twice; the next round either
        -- accepts the original or the player's last offer.
        local midUnit = math.max(1, math.floor((unitPrice + (d.original_unit or unitPrice)) / 2))
        d.qty          = qty
        d.unit_price   = midUnit
        d.state        = "negotiating"
        d.countered_by = "customer"
    else
        -- Walks away.
        Cooldowns[d.citizenid] = Cooldowns[d.citizenid] or {}
        Cooldowns[d.citizenid][d.customer_id] =
            now() + math.floor((Config.Dealing.cooldownMs or 300000) * 0.5)
        ActiveDeals[d.id] = nil
        deleteDealRow(d.id)
        broadcastDealRemovedToOwner(d)
        return
    end
    persistDeal(d)
    broadcastDealToOwner(d)
end)

--- Player completes the deal in-world. Triggered by ox_target on the
--- spawned customer ped. Validates physical proximity, item ownership,
--- and the deal's state, then performs the swap (item → cash) atomically.
RegisterNetEvent("pickle_drugs:dealingComplete", function(dealId)
    local src = source
    local d = getDealForPlayer(src, dealId)
    if not d or d.state ~= "accepted" then return end
    if now() > d.expires_at then return end -- expiry-sweep tick will clean it up

    local zone = Zones[d.zone_id]
    local pt   = zone and Dealing.PickDealPoint(zone, d.deal_point) or nil
    if not pt then return end

    local ped = GetPlayerPed(src)
    if not ped or not DoesEntityExist(ped) then return end
    local p = GetEntityCoords(ped)
    local dx, dy = p.x - pt.x, p.y - pt.y
    local distSq = dx * dx + dy * dy
    -- Must be within 4m of the deal point (loose enough for any reasonable
    -- ox_target setup, tight enough to prevent remote-completion exploits).
    if distSq > 16 then
        notify(src, "Step closer to the customer", "error") return
    end

    local drugCfg = Config.Drugs[d.drug]
    local item    = drugCfg and drugCfg.cutting and drugCfg.cutting.harvestItem
    if not item then return end
    if not (Inventory and Inventory.GetItemCount and Inventory.RemoveItem) then return end
    if (Inventory.GetItemCount(src, item) or 0) < d.qty then
        notify(src, ("Need %dx %s"):format(d.qty, item), "error")
        return
    end

    if not Inventory.RemoveItem(src, item, d.qty) then
        notify(src, "Couldn't take the items", "error") return
    end

    local total = Dealing.DealTotal(d)
    if Framework and Framework.AddMoney then
        Framework.AddMoney(src, total, "cash")
    end
    notify(src, ("Deal done · +$%d"):format(total), "success")

    -- Cooldown so the same customer doesn't immediately re-offer.
    Cooldowns[d.citizenid] = Cooldowns[d.citizenid] or {}
    Cooldowns[d.citizenid][d.customer_id] = now() + (Config.Dealing.cooldownMs or 300000)

    d.state = "completed"
    persistDeal(d)
    broadcastDealRemovedToOwner(d)
    -- Don't despawn immediately — the client plays a mutual exchange
    -- animation, then walks the customer away, then deletes the ped
    -- after a short linger. The owner_src is sent so the owner's
    -- client knows to drive its own ped through the matching anim.
    TriggerClientEvent("pickle_drugs:dealingCustomerComplete", -1, {
        deal_id   = d.id,
        owner_src = src,
    })
    ActiveDeals[d.id] = nil
    deleteDealRow(d.id)
end)

-- ─── Player joining: rehydrate ───────────────────────────────────────────

AddEventHandler("playerJoining", function()
    local src = source
    -- Frameworks load their player object slightly after `playerJoining`;
    -- give them a beat to settle, then push current zones/customers (so
    -- the admin tab + customer ped renderer see them) and any active deal
    -- this player owns.
    SetTimeout(2000, function()
        if not GetPlayerName(src) then return end
        for _, z in pairs(Zones) do
            TriggerClientEvent("pickle_drugs:dealingZoneUpdate", src, z)
        end
        for _, c in pairs(Customers) do
            TriggerClientEvent("pickle_drugs:dealingCustomerUpdate", src, c)
        end
        local cid = Framework and Framework.GetCitizenId and Framework.GetCitizenId(src) or nil
        if not cid then return end
        for _, d in pairs(ActiveDeals) do
            if d.citizenid == cid then
                TriggerClientEvent("pickle_drugs:dealingActiveUpdate", src, d)
                if d.state == "accepted" then broadcastCustomerSpawn(d) end
            end
        end
    end)
end)

-- ─── Boot ────────────────────────────────────────────────────────────────

CreateThread(function()
    if not (MySQL and MySQL.ready) then return end
    MySQL.ready(function()
        local ok, err = pcall(function()
            MySQL.query.await([[
                CREATE TABLE IF NOT EXISTS pickle_drugs_dealing_zones (
                    id           VARCHAR(64)  PRIMARY KEY,
                    label        VARCHAR(64)  NOT NULL,
                    kind         VARCHAR(16)  NOT NULL DEFAULT 'circle',
                    color        VARCHAR(8)   NOT NULL DEFAULT '#38bdf8',
                    center_x     DOUBLE       NOT NULL DEFAULT 0,
                    center_y     DOUBLE       NOT NULL DEFAULT 0,
                    center_z     DOUBLE       NOT NULL DEFAULT 0,
                    radius       DOUBLE       NOT NULL DEFAULT 50,
                    points       TEXT         NULL,
                    risk_mult    DOUBLE       NOT NULL DEFAULT 1.0,
                    deal_points  TEXT         NOT NULL,
                    updated_at   BIGINT       NOT NULL DEFAULT 0
                )
            ]])
            -- Migration: add `kind`, `points`, `color` to pre-existing tables.
            local zCols = MySQL.query.await(
                "SHOW COLUMNS FROM pickle_drugs_dealing_zones WHERE Field IN ('kind','points','color')"
            ) or {}
            local has = {}
            for _, c in ipairs(zCols) do has[c.Field] = true end
            if not has.kind then
                MySQL.query.await("ALTER TABLE pickle_drugs_dealing_zones ADD COLUMN kind VARCHAR(16) NOT NULL DEFAULT 'circle'")
            end
            if not has.points then
                MySQL.query.await("ALTER TABLE pickle_drugs_dealing_zones ADD COLUMN points TEXT NULL")
            end
            if not has.color then
                MySQL.query.await("ALTER TABLE pickle_drugs_dealing_zones ADD COLUMN color VARCHAR(8) NOT NULL DEFAULT '#38bdf8'")
            end
            MySQL.query.await([[
                CREATE TABLE IF NOT EXISTS pickle_drugs_dealing_customers (
                    id            VARCHAR(64)  PRIMARY KEY,
                    first_name    VARCHAR(32)  NOT NULL,
                    last_name     VARCHAR(32)  NOT NULL,
                    model         VARCHAR(64)  NOT NULL,
                    zones         TEXT         NOT NULL,
                    idle_scenario VARCHAR(64)  NOT NULL DEFAULT 'WORLD_HUMAN_SMOKING',
                    updated_at    BIGINT       NOT NULL DEFAULT 0
                )
            ]])
            MySQL.query.await([[
                CREATE TABLE IF NOT EXISTS pickle_drugs_dealing_active (
                    id            VARCHAR(64)  PRIMARY KEY,
                    customer_id   VARCHAR(64)  NOT NULL,
                    zone_id       VARCHAR(64)  NOT NULL,
                    deal_point    INT          NOT NULL DEFAULT 1,
                    citizenid     VARCHAR(64)  NOT NULL,
                    drug          VARCHAR(64)  NOT NULL,
                    qty           INT          NOT NULL DEFAULT 0,
                    unit_price    INT          NOT NULL DEFAULT 0,
                    original_qty  INT          NOT NULL DEFAULT 0,
                    original_unit INT          NOT NULL DEFAULT 0,
                    state         VARCHAR(16)  NOT NULL DEFAULT 'offered',
                    accepted_at   BIGINT       NOT NULL DEFAULT 0,
                    expires_at    BIGINT       NOT NULL DEFAULT 0,
                    created_at    BIGINT       NOT NULL DEFAULT 0,
                    countered_by  VARCHAR(32)  NULL,
                    INDEX (citizenid),
                    INDEX (state)
                )
            ]])
            loadAll()
        end)
        if not ok then
            print(("[pickle_drugs] dealing: DB error, starting empty: %s"):format(tostring(err)))
        end
        local zc, cc, dc = 0, 0, 0
        for _ in pairs(Zones) do zc = zc + 1 end
        for _ in pairs(Customers) do cc = cc + 1 end
        for _ in pairs(ActiveDeals) do dc = dc + 1 end
        -- Sanity: enumerate which drugs are saleable so a missing
        -- Config.Drugs[*].deal.basePrice isn't a silent dead-end.
        local saleable, unsaleable = {}, {}
        for drug, cfg in pairs(Config.Drugs or {}) do
            local item = cfg.cutting and cfg.cutting.harvestItem
            if item and cfg.deal and cfg.deal.basePrice then
                saleable[#saleable + 1] = ("%s (item=%s @ $%s)"):format(drug, item, tostring(cfg.deal.basePrice))
            else
                unsaleable[#unsaleable + 1] = drug
            end
        end
        print(("[pickle_drugs] dealing: ready · %d zones · %d customers · %d resumed deals"):format(zc, cc, dc))
        print("[pickle_drugs] dealing: saleable drugs · " ..
            (#saleable > 0 and table.concat(saleable, ", ") or "(none — set Config.Drugs[<drug>].deal.basePrice + a harvestItem)"))
        if #unsaleable > 0 then
            print("[pickle_drugs] dealing: drugs with no deal config · " .. table.concat(unsaleable, ", "))
        end
        if not (Inventory and Inventory.GetItemCount) then
            print("[pickle_drugs] dealing: WARNING — no inventory bridge; offers can't read player stock")
        end
        if not (Framework and Framework.GetCitizenId) then
            print("[pickle_drugs] dealing: WARNING — no framework bridge; offers can't be routed to a player")
        end

        -- Hot resource restart: already-connected players never get a
        -- `playerJoining` event, so push the zone + customer roster to
        -- every connected client now. Without this the admin sees an
        -- empty Dealing tab + DealsHud after a /restart even though
        -- the data is still in the DB.
        for _, z in pairs(Zones) do
            TriggerClientEvent("pickle_drugs:dealingZoneUpdate", -1, z)
        end
        for _, c in pairs(Customers) do
            TriggerClientEvent("pickle_drugs:dealingCustomerUpdate", -1, c)
        end
        -- (No accepted-deal resume after restart — see loadAll.)

        startScheduler()
    end)
end)

-- ─── Public API ──────────────────────────────────────────────────────────

function Dealing.GetZone(id)     return Zones[id] end
function Dealing.GetCustomer(id) return Customers[id] end
function Dealing.GetDeal(id)     return ActiveDeals[id] end
