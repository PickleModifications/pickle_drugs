-- Housing server. Authoritative for:
--   * Interior templates (pickle_drugs_house_interiors).
--   * World buildings (pickle_drugs_houses) including ownership, lease,
--     residents, and routing-bucket assignment.
--   * The lease ticker (rent due → eviction).
--   * Placement validation (called by modules/grow when a player or admin
--     creates a plot inside a zone).
--
-- Cross-module exports live on the global `Housing` table so other modules
-- (grow, employees) can call into us without depending on file load order.
-- All file-top globals are populated at parse time; runtime reads of
-- Housing.* should happen inside MySQL.ready / event handlers.

Housing = Housing or {}

local Interiors = {}    -- id → row (parsed)
local Houses    = {}    -- id → row (parsed; bucket included)
local PlayersInBucket = {} -- src → bucket (so we can clear on disconnect)

local function now() return os.time() * 1000 end

-- ─── JSON helpers ─────────────────────────────────────────────────────────

local function decode(s, fallback)
    if type(s) == "table" then return s end
    if type(s) ~= "string" or s == "" then return fallback end
    local ok, v = pcall(json.decode, s)
    if ok and v ~= nil then return v end
    return fallback
end

local function encode(v)
    return json.encode(v or {})
end

-- ─── Notification ─────────────────────────────────────────────────────────

local function notify(src, msg, type_)
    if not src or src == 0 then return end
    TriggerClientEvent("ox_lib:notify", src,
        { title = "Housing", description = msg, type = type_ or "inform" })
end

-- ─── Admin gate ───────────────────────────────────────────────────────────

local function adminCheck(src)
    if not Admin or not Admin.IsAdmin then return src == 0 end
    return Admin.IsAdmin(src)
end

-- ─── Player identity probe (citizenid) ────────────────────────────────────
-- Resolves a stable per-player identifier through the active framework.
-- Returns a string or nil. The bridge layer doesn't expose this today, so
-- we probe inline rather than dragging in another bridge directory.

local function getCitizenId(src)
    if not src or src == 0 then return nil end

    -- QBox first (it presents a qb-like core too, so order matters).
    if GetResourceState("qbx_core") == "started" then
        local ok, p = pcall(function() return exports.qbx_core:GetPlayer(src) end)
        if ok and p and p.PlayerData and p.PlayerData.citizenid then
            return p.PlayerData.citizenid
        end
    end

    if GetResourceState("qb-core") == "started" then
        local ok, core = pcall(function() return exports["qb-core"]:GetCoreObject() end)
        if ok and core then
            local p = core.Functions.GetPlayer(src)
            if p and p.PlayerData and p.PlayerData.citizenid then
                return p.PlayerData.citizenid
            end
        end
    end

    if GetResourceState("es_extended") == "started" then
        local ok, ESX = pcall(function() return exports["es_extended"]:getSharedObject() end)
        if ok and ESX then
            local xp = ESX.GetPlayerFromId(src)
            if xp and xp.identifier then return xp.identifier end
        end
    end

    -- Fallback: license. Better than nothing for standalone dev servers.
    for _, id in ipairs(GetPlayerIdentifiers(src) or {}) do
        if id:sub(1, 8) == "license:" then return id end
    end
    return nil
end

Housing.GetCitizenId = getCitizenId

-- ─── Money probe ─────────────────────────────────────────────────────────
-- Returns ok, balance.

local function getMoney(src)
    local cfg = (Config.Housing and Config.Housing.money) or {}
    if cfg.mode == "cash" and Inventory and Inventory.GetItemCount then
        return true, Inventory.GetItemCount(src, cfg.cashItem or "cash")
    end
    -- framework
    if GetResourceState("qbx_core") == "started" then
        local ok, p = pcall(function() return exports.qbx_core:GetPlayer(src) end)
        if ok and p and p.Functions and p.Functions.GetMoney then
            return true, p.Functions.GetMoney(cfg.moneyType or "cash") or 0
        end
    end
    if GetResourceState("qb-core") == "started" then
        local ok, core = pcall(function() return exports["qb-core"]:GetCoreObject() end)
        if ok and core then
            local p = core.Functions.GetPlayer(src)
            if p and p.Functions and p.Functions.GetMoney then
                return true, p.Functions.GetMoney(cfg.moneyType or "cash") or 0
            end
        end
    end
    if GetResourceState("es_extended") == "started" then
        local ok, ESX = pcall(function() return exports["es_extended"]:getSharedObject() end)
        if ok and ESX then
            local xp = ESX.GetPlayerFromId(src)
            if xp then
                if (cfg.moneyType or "cash") == "cash" then
                    return true, xp.getMoney() or 0
                end
                local acc = xp.getAccount and xp.getAccount(cfg.moneyType or "bank")
                if acc then return true, acc.money or 0 end
            end
        end
    end
    return false, 0
end

local function chargeMoney(src, amount)
    if amount <= 0 then return true end
    local cfg = (Config.Housing and Config.Housing.money) or {}
    if cfg.mode == "cash" and Inventory and Inventory.RemoveItem then
        return Inventory.RemoveItem(src, cfg.cashItem or "cash", amount) and true or false
    end
    if GetResourceState("qbx_core") == "started" then
        local ok, p = pcall(function() return exports.qbx_core:GetPlayer(src) end)
        if ok and p and p.Functions and p.Functions.RemoveMoney then
            return p.Functions.RemoveMoney(cfg.moneyType or "cash", amount, "pickle_drugs:housing") and true or false
        end
    end
    if GetResourceState("qb-core") == "started" then
        local ok, core = pcall(function() return exports["qb-core"]:GetCoreObject() end)
        if ok and core then
            local p = core.Functions.GetPlayer(src)
            if p and p.Functions and p.Functions.RemoveMoney then
                return p.Functions.RemoveMoney(cfg.moneyType or "cash", amount, "pickle_drugs:housing") and true or false
            end
        end
    end
    if GetResourceState("es_extended") == "started" then
        local ok, ESX = pcall(function() return exports["es_extended"]:getSharedObject() end)
        if ok and ESX then
            local xp = ESX.GetPlayerFromId(src)
            if xp then
                if (cfg.moneyType or "cash") == "cash" then
                    xp.removeMoney(amount); return true
                end
                xp.removeAccountMoney(cfg.moneyType or "bank", amount); return true
            end
        end
    end
    return false
end

-- ─── Row (de)serialisation ────────────────────────────────────────────────

local function interiorFromRow(row)
    return {
        id            = row.id,
        label         = row.label or row.id,
        kind          = row.kind or "teleport",
        door_x        = tonumber(row.door_x) or 0,
        door_y        = tonumber(row.door_y) or 0,
        door_z        = tonumber(row.door_z) or 0,
        door_w        = tonumber(row.door_w) or 0,
        exit_x        = tonumber(row.exit_x) or 0,
        exit_y        = tonumber(row.exit_y) or 0,
        exit_z        = tonumber(row.exit_z) or 0,
        exit_w        = tonumber(row.exit_w) or 0,
        idle_x        = tonumber(row.idle_x) or 0,
        idle_y        = tonumber(row.idle_y) or 0,
        idle_z        = tonumber(row.idle_z) or 0,
        idle_w        = tonumber(row.idle_w) or 0,
        mgmt_x        = tonumber(row.mgmt_x) or 0,
        mgmt_y        = tonumber(row.mgmt_y) or 0,
        mgmt_z        = tonumber(row.mgmt_z) or 0,
        mgmt_w        = tonumber(row.mgmt_w) or 0,
        zones         = decode(row.zones, {}),
        mlo_polygon   = decode(row.mlo_polygon, nil),
        updated_at    = tonumber(row.updated_at) or 0,
    }
end

local function houseFromRow(row)
    local h = {
        id              = row.id,
        label           = row.label or row.id,
        interior_id     = row.interior_id,
        door_world_x    = tonumber(row.door_world_x) or 0,
        door_world_y    = tonumber(row.door_world_y) or 0,
        door_world_z    = tonumber(row.door_world_z) or 0,
        door_world_w    = tonumber(row.door_world_w) or 0,
        sale_enabled    = tonumber(row.sale_enabled) == 1,
        sale_price      = tonumber(row.sale_price) or 0,
        rent_enabled    = tonumber(row.rent_enabled) == 1,
        rent_price      = tonumber(row.rent_price) or 0,
        rent_cycle_ms   = tonumber(row.rent_cycle_ms) or 0,
        owner_citizenid = row.owner_citizenid,
        tenure          = row.tenure or "none",
        rent_due_at     = tonumber(row.rent_due_at) or 0,
        residents       = decode(row.residents, {}),
        bucket          = tonumber(row.bucket) or 0,
        updated_at      = tonumber(row.updated_at) or 0,
    }
    h.kind = (Interiors[h.interior_id] and Interiors[h.interior_id].kind) or "teleport"
    if h.bucket == 0 and h.kind ~= "mlo" then
        h.bucket = Housing.BucketFor(h)
    end
    return h
end

-- ─── Public read accessors ────────────────────────────────────────────────

function Housing.GetInterior(id) return Interiors[id] end
function Housing.GetAllInteriors() return Interiors end
function Housing.GetHouse(id) return Houses[id] end
function Housing.GetAllHouses() return Houses end

function Housing.HouseInteriorOf(houseId)
    local h = Houses[houseId]
    if not h then return nil end
    return Interiors[h.interior_id]
end

function Housing.PlayerCanAccess(src, house)
    if not src or not house then return false end
    if house.tenure == "none" then return false end
    local cid = getCitizenId(src)
    if not cid then return false end
    if house.owner_citizenid == cid then return true end
    for _, r in ipairs(house.residents or {}) do
        if r == cid then return true end
    end
    return false
end

function Housing.IsHouseOwner(src, house)
    if not src or not house then return false end
    local cid = getCitizenId(src)
    return cid and house.owner_citizenid == cid or false
end

-- ─── Persistence ──────────────────────────────────────────────────────────

local function persistInterior(i)
    i.updated_at = now()
    MySQL.update.await([[
        UPDATE pickle_drugs_house_interiors SET
            label=?, kind=?,
            door_x=?, door_y=?, door_z=?, door_w=?,
            exit_x=?, exit_y=?, exit_z=?, exit_w=?,
            idle_x=?, idle_y=?, idle_z=?, idle_w=?,
            mgmt_x=?, mgmt_y=?, mgmt_z=?, mgmt_w=?,
            zones=?, mlo_polygon=?, updated_at=?
        WHERE id=?
    ]], {
        i.label, i.kind,
        i.door_x, i.door_y, i.door_z, i.door_w,
        i.exit_x, i.exit_y, i.exit_z, i.exit_w,
        i.idle_x, i.idle_y, i.idle_z, i.idle_w,
        i.mgmt_x, i.mgmt_y, i.mgmt_z, i.mgmt_w,
        encode(i.zones), i.mlo_polygon and encode(i.mlo_polygon) or nil,
        i.updated_at, i.id,
    })
end

local function persistHouse(h)
    h.updated_at = now()
    MySQL.update.await([[
        UPDATE pickle_drugs_houses SET
            label=?, interior_id=?,
            door_world_x=?, door_world_y=?, door_world_z=?, door_world_w=?,
            sale_enabled=?, sale_price=?,
            rent_enabled=?, rent_price=?, rent_cycle_ms=?,
            owner_citizenid=?, tenure=?, rent_due_at=?,
            residents=?, bucket=?, updated_at=?
        WHERE id=?
    ]], {
        h.label, h.interior_id,
        h.door_world_x, h.door_world_y, h.door_world_z, h.door_world_w,
        h.sale_enabled and 1 or 0, h.sale_price,
        h.rent_enabled and 1 or 0, h.rent_price, h.rent_cycle_ms,
        h.owner_citizenid, h.tenure, h.rent_due_at,
        encode(h.residents or {}), h.bucket, h.updated_at, h.id,
    })
end

local function broadcastHouse(h)
    TriggerClientEvent("pickle_drugs:houseUpdate", -1, h)
end

local function broadcastInterior(i)
    TriggerClientEvent("pickle_drugs:interiorUpdate", -1, i)
end

-- ─── ID generation ────────────────────────────────────────────────────────

local function genId(prefix, table_)
    local id = ("%s_%d"):format(prefix, now())
    if not table_[id] then return id end
    return ("%s_%d"):format(id, math.random(1000, 9999))
end

-- ─── Eviction & lease ─────────────────────────────────────────────────────

--- Boots every player whose current routing bucket matches `bucket` back
--- to bucket 0 and teleports them to the interior's exit (if any).
local function bootBucket(bucket, exitTo)
    if not bucket or bucket == 0 then return end
    for _, src in ipairs(GetPlayers()) do
        local s = tonumber(src)
        if s and PlayersInBucket[s] == bucket then
            SetPlayerRoutingBucket(s, 0)
            PlayersInBucket[s] = 0
            if exitTo then
                TriggerClientEvent("pickle_drugs:teleportTo", s, exitTo, true)
            end
            notify(s, "Lease lapsed — you've been moved out.", "warning")
        end
    end
end

local function lapseLease(h)
    if h.tenure == "none" then return end
    local interior = Interiors[h.interior_id]
    h.tenure = "none"
    h.owner_citizenid = nil
    h.residents = {}
    h.rent_due_at = 0
    persistHouse(h)
    broadcastHouse(h)
    -- Boot everyone in this house's bucket out.
    if interior and interior.kind == "teleport" then
        bootBucket(h.bucket, {
            x = interior.exit_x, y = interior.exit_y,
            z = interior.exit_z, w = interior.exit_w,
        })
    end
    -- Tell modules/grow to mark the entities frozen so the world prop
    -- renderer can grey them out and ox_target rejects interactions.
    if Grow and Grow.OnHouseLeaseLapsed then
        Grow.OnHouseLeaseLapsed(h.id)
    end
    -- Tell employees to release peds bound to this house.
    if Employees and Employees.OnHouseLeaseLapsed then
        Employees.OnHouseLeaseLapsed(h.id)
    end
end

Housing.LapseLease = lapseLease

-- ─── Placement validation (called from grow/server.lua) ───────────────────

--- Returns ok, reason, world {x,y,z,w}. Performs:
---   1. Authorization (player is owner/resident).
---   2. Zone exists in the interior.
---   3. Footprint computed from supplied bbox sizes.
---   4. Collision against currently-placed plots in this zone.
---@param src     integer
---@param houseId string
---@param zoneId  string
---@param cx      integer
---@param cy      integer
---@param sizeX   number   model bbox X (metres)
---@param sizeY   number   model bbox Y (metres)
---@param existing table   list of placed entities { id, zone_id, cell_x, cell_y, cell_w, cell_h }
---@return boolean ok
---@return string|nil reason
---@return table|nil  world      { x, y, z, w }
---@return integer|nil w
---@return integer|nil h
--- Validates a placement and returns the final world pose. `rotIndex` is
--- the 0..3 quarter-turn the player selected — `world.w` is returned with
--- `Housing.WorldHeading(zone, rotIndex)` already applied, so callers
--- never have to (and never can forget to) re-add `rotIndex * 90`.
---@param rotIndex integer|nil  0..3, defaults to 0 for back-compat
function Housing.ValidatePlacement(src, houseId, zoneId, cx, cy, sizeX, sizeY, rotIndex, existing)
    local h = Houses[houseId]
    if not h then return false, "no_house" end
    if not Housing.PlayerCanAccess(src, h) and not adminCheck(src) then
        return false, "not_resident"
    end
    local interior = Interiors[h.interior_id]
    if not interior then return false, "no_interior" end
    local zone
    for _, z in ipairs(interior.zones or {}) do
        if z.id == zoneId then zone = z break end
    end
    if not zone then return false, "no_zone" end

    local fw, fh = Housing.FootprintFromSize(sizeX, sizeY, zone)
    local occ = Housing.BuildOccupancy(zone, existing or {})
    local ok, reason = Housing.CanPlaceAt(zone, cx, cy, fw, fh, occ)
    if not ok then return false, reason end
    local world = Housing.CellToWorld(zone, cx + (fw - 1) / 2, cy + (fh - 1) / 2)
    world.w = Housing.WorldHeading(zone, rotIndex or 0)
    return true, nil, world, fw, fh
end

-- ─── Bucket plumbing ──────────────────────────────────────────────────────

local function teleportInto(src, h)
    local interior = Interiors[h.interior_id]
    if not interior then return end
    if interior.kind == "mlo" then
        -- No teleport, no bucket. Still notify the player to refresh access.
        TriggerClientEvent("pickle_drugs:enteredHouse", src, h.id)
        return
    end
    SetPlayerRoutingBucket(src, h.bucket)
    PlayersInBucket[src] = h.bucket
    TriggerClientEvent("pickle_drugs:teleportTo", src, {
        x = interior.door_x, y = interior.door_y,
        z = interior.door_z, w = interior.door_w,
    }, true)
    TriggerClientEvent("pickle_drugs:enteredHouse", src, h.id)
end

local function teleportOut(src, h)
    local interior = Interiors[h.interior_id]
    if not interior then return end
    if interior.kind == "mlo" then
        TriggerClientEvent("pickle_drugs:leftHouse", src, h.id)
        return
    end
    SetPlayerRoutingBucket(src, 0)
    PlayersInBucket[src] = 0
    TriggerClientEvent("pickle_drugs:teleportTo", src, {
        x = interior.exit_x, y = interior.exit_y,
        z = interior.exit_z, w = interior.exit_w,
    }, true)
    TriggerClientEvent("pickle_drugs:leftHouse", src, h.id)
end

-- ─── Player-facing events ────────────────────────────────────────────────

RegisterNetEvent("pickle_drugs:enterHouse", function(houseId)
    local src = source
    local h = Houses[houseId]
    if not h then return end
    if not Housing.PlayerCanAccess(src, h) and not adminCheck(src) then
        notify(src, "You don't have access here.", "error")
        return
    end
    teleportInto(src, h)
end)

RegisterNetEvent("pickle_drugs:exitHouse", function(houseId)
    local src = source
    local h = Houses[houseId]
    if not h then return end
    teleportOut(src, h)
end)

RegisterNetEvent("pickle_drugs:purchaseHouse", function(houseId, mode)
    local src = source
    local h = Houses[houseId]
    if not h then return end
    if h.tenure ~= "none" then
        notify(src, "Property is unavailable.", "error") return
    end
    local cid = getCitizenId(src)
    if not cid then notify(src, "Identity unknown.", "error") return end

    local price
    if mode == "buy" then
        if not h.sale_enabled then notify(src, "Not for sale.", "error") return end
        price = h.sale_price
    elseif mode == "rent" then
        if not h.rent_enabled then notify(src, "Not for rent.", "error") return end
        price = h.rent_price
    else
        return
    end

    local ok, balance = getMoney(src)
    if ok and balance < price then
        notify(src, ("Need $%d (have $%d)"):format(price, balance), "error") return
    end
    if not chargeMoney(src, price) then
        notify(src, "Payment failed.", "error") return
    end

    h.owner_citizenid = cid
    h.residents = {}
    if mode == "buy" then
        h.tenure = "owned"
        h.rent_due_at = 0
    else
        h.tenure = "rented"
        h.rent_due_at = now() + (h.rent_cycle_ms or 0)
    end
    persistHouse(h)
    broadcastHouse(h)
    notify(src, mode == "buy" and "Property purchased." or "Lease signed.", "success")
end)

RegisterNetEvent("pickle_drugs:payRent", function(houseId)
    local src = source
    local h = Houses[houseId]
    if not h or h.tenure ~= "rented" then return end
    if not Housing.IsHouseOwner(src, h) then return end
    local price = h.rent_price or 0
    local ok, balance = getMoney(src)
    if ok and balance < price then
        notify(src, ("Need $%d (have $%d)"):format(price, balance), "error") return
    end
    if not chargeMoney(src, price) then
        notify(src, "Payment failed.", "error") return
    end
    -- Add a cycle from whichever is greater (now or current due) so the
    -- player can pay early without losing time.
    local base = math.max(now(), h.rent_due_at or 0)
    h.rent_due_at = base + (h.rent_cycle_ms or 0)
    persistHouse(h)
    broadcastHouse(h)
    notify(src, "Rent paid.", "success")
end)

RegisterNetEvent("pickle_drugs:cancelLease", function(houseId)
    local src = source
    local h = Houses[houseId]
    if not h or h.tenure == "none" then return end
    if not Housing.IsHouseOwner(src, h) then return end
    lapseLease(h)
    notify(src, "Lease cancelled.", "warning")
end)

RegisterNetEvent("pickle_drugs:setResidents", function(houseId, residents)
    local src = source
    local h = Houses[houseId]
    if not h or not Housing.IsHouseOwner(src, h) then return end
    if type(residents) ~= "table" then return end
    local clean = {}
    local seen = {}
    for _, r in ipairs(residents) do
        if type(r) == "string" and r ~= "" and not seen[r] and r ~= h.owner_citizenid then
            clean[#clean + 1] = r
            seen[r] = true
        end
        if #clean >= 16 then break end
    end
    h.residents = clean
    persistHouse(h)
    broadcastHouse(h)
    notify(src, "Resident list updated.", "success")
end)

-- ─── Admin CRUD: interiors ────────────────────────────────────────────────

RegisterNetEvent("pickle_drugs:saveInterior", function(payload)
    local src = source
    if not adminCheck(src) then return end
    if type(payload) ~= "table" then return end
    -- Empty strings count as "no id" (see saveHouse for the rationale).
    local id = (type(payload.id) == "string" and payload.id ~= "") and payload.id or nil
    -- The templates list is teleport-only. MLO interiors are property-owned
    -- shadow rows created via saveHouse — refuse mlo here so a malformed
    -- payload can't drop one into the templates pool.
    if id and id:sub(1, 5) == "_mlo_" then
        notify(src, "Shadow MLO interiors are managed via Properties.", "error") return
    end

    local existing = id and Interiors[id]
    if not existing then
        id = id or genId("int", Interiors)
    end

    local function num(v) return tonumber(v) or 0 end
    local row = {
        id          = id,
        label       = tostring(payload.label or id),
        kind        = "teleport",
        door_x      = num(payload.door_x), door_y = num(payload.door_y),
        door_z      = num(payload.door_z), door_w = num(payload.door_w),
        exit_x      = num(payload.exit_x), exit_y = num(payload.exit_y),
        exit_z      = num(payload.exit_z), exit_w = num(payload.exit_w),
        idle_x      = num(payload.idle_x), idle_y = num(payload.idle_y),
        idle_z      = num(payload.idle_z), idle_w = num(payload.idle_w),
        mgmt_x      = num(payload.mgmt_x), mgmt_y = num(payload.mgmt_y),
        mgmt_z      = num(payload.mgmt_z), mgmt_w = num(payload.mgmt_w),
        zones       = type(payload.zones) == "table" and payload.zones or {},
        mlo_polygon = nil,
        updated_at  = now(),
    }

    -- Sanitize zones.
    local cleanZones = {}
    for _, z in ipairs(row.zones) do
        local zone = {
            id     = tostring(z.id or ("zone_" .. (#cleanZones + 1))),
            label  = tostring(z.label or ""),
            origin = {
                x = num(z.origin and z.origin.x),
                y = num(z.origin and z.origin.y),
                z = num(z.origin and z.origin.z),
                w = num(z.origin and z.origin.w),
            },
            xCells = math.max(1, math.floor(num(z.xCells))),
            yCells = math.max(1, math.floor(num(z.yCells))),
            cell   = tonumber(z.cell) or Config.Housing.gridCellSize or 0.5,
            zTolerance = tonumber(z.zTolerance) or Config.Housing.defaultZTolerance or 0.6,
        }
        cleanZones[#cleanZones + 1] = zone
    end
    row.zones = cleanZones

    -- Reject any save where two zones share a grid cell. The admin UI
    -- already paints overlap red live, but this is the authoritative gate.
    local occ = {}
    for _, z in ipairs(cleanZones) do
        local cx0 = math.floor((z.origin.x - z.xCells * z.cell / 2) / z.cell + 1e-4)
        local cy0 = math.floor((z.origin.y - z.yCells * z.cell / 2) / z.cell + 1e-4)
        for ix = 0, z.xCells - 1 do
            for iy = 0, z.yCells - 1 do
                local key = (cx0 + ix) .. ":" .. (cy0 + iy)
                if occ[key] then
                    TriggerClientEvent("ox_lib:notify", src, {
                        type = "error",
                        title = "Interior",
                        description = ("Zones '%s' and '%s' overlap"):format(occ[key], z.id),
                    })
                    return
                end
                occ[key] = z.id
            end
        end
    end

    if existing then
        for k, v in pairs(row) do existing[k] = v end
        persistInterior(existing)
        broadcastInterior(existing)
    else
        Interiors[id] = row
        MySQL.insert.await([[
            INSERT INTO pickle_drugs_house_interiors
                (id, label, kind,
                 door_x, door_y, door_z, door_w,
                 exit_x, exit_y, exit_z, exit_w,
                 idle_x, idle_y, idle_z, idle_w,
                 mgmt_x, mgmt_y, mgmt_z, mgmt_w,
                 zones, mlo_polygon, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ]], {
            row.id, row.label, row.kind,
            row.door_x, row.door_y, row.door_z, row.door_w,
            row.exit_x, row.exit_y, row.exit_z, row.exit_w,
            row.idle_x, row.idle_y, row.idle_z, row.idle_w,
            row.mgmt_x, row.mgmt_y, row.mgmt_z, row.mgmt_w,
            encode(row.zones), row.mlo_polygon and encode(row.mlo_polygon) or nil,
            row.updated_at,
        })
        broadcastInterior(row)
    end
    -- Echo the assigned id back to the saver so the React editor can
    -- adopt it on the first save of a brand-new draft.
    TriggerClientEvent("pickle_drugs:interiorSaved", src, {
        tempId = (type(payload.id) == "string" and payload.id) or "",
        savedId = id,
    })
    notify(src, "Interior saved", "success")
end)

RegisterNetEvent("pickle_drugs:deleteInterior", function(id)
    local src = source
    if not adminCheck(src) then return end
    if not Interiors[id] then return end
    -- Refuse if any house still binds to it.
    for _, h in pairs(Houses) do
        if h.interior_id == id then
            notify(src, "Interior is in use by a house.", "error") return
        end
    end
    Interiors[id] = nil
    MySQL.update.await("DELETE FROM pickle_drugs_house_interiors WHERE id=?", { id })
    TriggerClientEvent("pickle_drugs:interiorRemoved", -1, id)
    notify(src, "Interior deleted", "success")
end)

-- ─── Admin CRUD: houses ───────────────────────────────────────────────────

--- Sanitize an MLO inline payload from the Property editor into an Interior
--- row. Server-authoritative: ignores any client-supplied id and uses the
--- shadow id derived from the parent house.
local function buildShadowMloInterior(houseId, payload, mlo)
    local function num(v) return tonumber(v) or 0 end
    local zones = {}
    for _, z in ipairs(type(mlo.zones) == "table" and mlo.zones or {}) do
        zones[#zones + 1] = {
            id     = tostring(z.id or ("zone_" .. (#zones + 1))),
            label  = tostring(z.label or ""),
            origin = {
                x = num(z.origin and z.origin.x), y = num(z.origin and z.origin.y),
                z = num(z.origin and z.origin.z), w = num(z.origin and z.origin.w),
            },
            xCells = math.max(1, math.floor(num(z.xCells))),
            yCells = math.max(1, math.floor(num(z.yCells))),
            cell   = tonumber(z.cell) or Config.Housing.gridCellSize or 0.5,
            zTolerance = tonumber(z.zTolerance) or Config.Housing.defaultZTolerance or 0.6,
        }
    end
    return {
        id          = "_mlo_" .. houseId,
        label       = tostring(mlo.label or payload.label or houseId),
        kind        = "mlo",
        door_x = 0, door_y = 0, door_z = 0, door_w = 0,
        exit_x = 0, exit_y = 0, exit_z = 0, exit_w = 0,
        idle_x      = num(mlo.idle_x), idle_y = num(mlo.idle_y),
        idle_z      = num(mlo.idle_z), idle_w = num(mlo.idle_w),
        mgmt_x      = num(mlo.mgmt_x), mgmt_y = num(mlo.mgmt_y),
        mgmt_z      = num(mlo.mgmt_z), mgmt_w = num(mlo.mgmt_w),
        zones       = zones,
        mlo_polygon = mlo.mlo_polygon and {
            points = mlo.mlo_polygon.points or {},
            minZ   = tonumber(mlo.mlo_polygon.minZ),
            maxZ   = tonumber(mlo.mlo_polygon.maxZ),
        } or nil,
        updated_at  = now(),
    }
end

RegisterNetEvent("pickle_drugs:saveHouse", function(payload)
    local src = source
    if not adminCheck(src) then return end
    if type(payload) ~= "table" then return end

    -- Empty strings count as "no id" — the React editor seeds drafts
    -- with id="" and the auto-save fires it to the server before the
    -- admin types anything. Without this normalisation the row would
    -- be persisted under id="" and every subsequent edit would update
    -- the same broken row.
    local id = (type(payload.id) == "string" and payload.id ~= "") and payload.id or nil
    local existing = id and Houses[id]
    if not existing then id = id or genId("hse", Houses) end

    -- Resolve the interior link. Two paths:
    --   * teleport: payload.interior_id must reference an existing
    --     teleport-kind interior in the templates table.
    --   * mlo: payload.mlo carries the inline interior config; we
    --     create/update a "_mlo_<houseId>" shadow interior and link it.
    local kind = payload.kind == "mlo" and "mlo" or "teleport"
    if kind == "teleport" then
        if not payload.interior_id or not Interiors[payload.interior_id]
           or Interiors[payload.interior_id].kind ~= "teleport"
        then
            notify(src, "Pick an interior template first.", "error") return
        end
    else
        if type(payload.mlo) ~= "table" then
            notify(src, "MLO config missing.", "error") return
        end
        local shadow = buildShadowMloInterior(id, payload, payload.mlo)
        local prior = Interiors[shadow.id]
        Interiors[shadow.id] = shadow
        if prior then
            persistInterior(shadow)
        else
            MySQL.insert.await([[
                INSERT INTO pickle_drugs_house_interiors
                    (id, label, kind,
                     door_x, door_y, door_z, door_w,
                     exit_x, exit_y, exit_z, exit_w,
                     idle_x, idle_y, idle_z, idle_w,
                     mgmt_x, mgmt_y, mgmt_z, mgmt_w,
                     zones, mlo_polygon, updated_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ]], {
                shadow.id, shadow.label, shadow.kind,
                shadow.door_x, shadow.door_y, shadow.door_z, shadow.door_w,
                shadow.exit_x, shadow.exit_y, shadow.exit_z, shadow.exit_w,
                shadow.idle_x, shadow.idle_y, shadow.idle_z, shadow.idle_w,
                shadow.mgmt_x, shadow.mgmt_y, shadow.mgmt_z, shadow.mgmt_w,
                encode(shadow.zones), shadow.mlo_polygon and encode(shadow.mlo_polygon) or nil,
                shadow.updated_at,
            })
        end
        broadcastInterior(shadow)
        payload.interior_id = shadow.id
    end

    local function num(v) return tonumber(v) or 0 end
    local row = {
        id              = id,
        label           = tostring(payload.label or id),
        interior_id     = payload.interior_id,
        door_world_x    = num(payload.door_world_x),
        door_world_y    = num(payload.door_world_y),
        door_world_z    = num(payload.door_world_z),
        door_world_w    = num(payload.door_world_w),
        sale_enabled    = payload.sale_enabled and true or false,
        sale_price      = math.max(0, num(payload.sale_price)),
        rent_enabled    = payload.rent_enabled and true or false,
        rent_price      = math.max(0, num(payload.rent_price)),
        rent_cycle_ms   = math.max(0, num(payload.rent_cycle_ms)),
        owner_citizenid = existing and existing.owner_citizenid or nil,
        tenure          = existing and existing.tenure or "none",
        rent_due_at     = existing and existing.rent_due_at or 0,
        residents       = existing and existing.residents or {},
        bucket          = existing and existing.bucket or 0,
        updated_at      = now(),
    }
    row.kind = Interiors[row.interior_id].kind
    if row.bucket == 0 and row.kind ~= "mlo" then
        row.bucket = Housing.BucketFor(row)
    end

    if existing then
        for k, v in pairs(row) do existing[k] = v end
        persistHouse(existing)
        broadcastHouse(existing)
    else
        Houses[id] = row
        MySQL.insert.await([[
            INSERT INTO pickle_drugs_houses
                (id, label, interior_id,
                 door_world_x, door_world_y, door_world_z, door_world_w,
                 sale_enabled, sale_price,
                 rent_enabled, rent_price, rent_cycle_ms,
                 owner_citizenid, tenure, rent_due_at,
                 residents, bucket, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ]], {
            row.id, row.label, row.interior_id,
            row.door_world_x, row.door_world_y, row.door_world_z, row.door_world_w,
            row.sale_enabled and 1 or 0, row.sale_price,
            row.rent_enabled and 1 or 0, row.rent_price, row.rent_cycle_ms,
            row.owner_citizenid, row.tenure, row.rent_due_at,
            encode(row.residents), row.bucket, row.updated_at,
        })
        broadcastHouse(row)
    end
    -- Tell the saver which id the row landed under so its auto-save loop
    -- doesn't keep re-creating ghost rows (the React draft starts with
    -- id="" for new houses; this lets it adopt the server-assigned id).
    TriggerClientEvent("pickle_drugs:houseSaved", src, {
        tempId = (type(payload.id) == "string" and payload.id) or "",
        savedId = id,
    })
    notify(src, "House saved", "success")
end)

RegisterNetEvent("pickle_drugs:deleteHouse", function(id)
    local src = source
    if not adminCheck(src) then return end
    local h = Houses[id]
    if not h then return end
    -- Boot anyone inside.
    if h.bucket and h.bucket ~= 0 then
        local interior = Interiors[h.interior_id]
        bootBucket(h.bucket, interior and {
            x = interior.exit_x, y = interior.exit_y,
            z = interior.exit_z, w = interior.exit_w,
        } or nil)
    end
    Houses[id] = nil
    MySQL.update.await("DELETE FROM pickle_drugs_houses WHERE id=?", { id })
    TriggerClientEvent("pickle_drugs:houseRemoved", -1, id)

    -- An MLO property owns its shadow interior; tear it down with the house
    -- so we don't leave orphans in the templates list / Interiors map.
    local shadowId = "_mlo_" .. id
    if Interiors[shadowId] then
        Interiors[shadowId] = nil
        MySQL.update.await("DELETE FROM pickle_drugs_house_interiors WHERE id=?", { shadowId })
        TriggerClientEvent("pickle_drugs:interiorRemoved", -1, shadowId)
    end

    if Grow and Grow.OnHouseDeleted then Grow.OnHouseDeleted(id) end
    if Storage and Storage.OnHouseDeleted then Storage.OnHouseDeleted(id) end
    notify(src, "House deleted", "success")
end)

-- ─── Callbacks ────────────────────────────────────────────────────────────

lib.callback.register("pickle_drugs:listHousing", function(src)
    local outI, outH = {}, {}
    for _, i in pairs(Interiors) do outI[#outI + 1] = i end
    for _, h in pairs(Houses)    do outH[#outH + 1] = h end
    table.sort(outI, function(a, b) return a.id < b.id end)
    table.sort(outH, function(a, b) return a.id < b.id end)
    return { interiors = outI, houses = outH }
end)

--- Per-player view of one house: includes the interior, current player's
--- citizenid (so the management panel can show whether they're owner /
--- resident), and the placed entities in each zone.
--- Returns the house id (if any) the player is currently bucketed into.
--- Used by the client on hot restart to re-link to its teleport house
--- without making the player walk back through the door.
lib.callback.register("pickle_drugs:getCurrentHouse", function(src)
    local bucket = PlayersInBucket[src]
    if not bucket or bucket == 0 then return nil end
    for _, h in pairs(Houses) do
        if h.bucket == bucket then return h.id end
    end
    return nil
end)

lib.callback.register("pickle_drugs:getHouseDetail", function(src, houseId)
    -- A panel opened seconds after a hot restart will arrive here before
    -- grow's MySQL.ready and the employees roster have finished loading,
    -- and the player would see an empty entities/workers list. Wait for
    -- those modules' ready flags (set by their own boot blocks) with a
    -- short ceiling so we don't block forever on a misconfigured server.
    local deadline = GetGameTimer() + 5000
    while (not (Grow and Grow.IsReady) or not (Employees and Employees.RosterReady))
        and GetGameTimer() < deadline
    do
        Wait(50)
    end
    local h = Houses[houseId]
    if not h then return nil end
    local interior = Interiors[h.interior_id]
    local entities = (Grow and Grow.PlotsForHouse) and Grow.PlotsForHouse(houseId) or {}
    local lockers = {}
    if Storage and Storage.LockersForHouse then
        for _, l in ipairs(Storage.LockersForHouse(houseId)) do
            lockers[#lockers + 1] = {
                id = l.id, kind = l.kind,
                house_id = l.house_id, zone_id = l.zone_id,
                cell_x = l.cell_x, cell_y = l.cell_y,
                cell_w = l.cell_w, cell_h = l.cell_h,
                coords_x = l.coords_x, coords_y = l.coords_y,
                coords_z = l.coords_z, coords_w = l.coords_w,
                slots  = (Storage.SlotsFor and Storage.SlotsFor(l.kind)) or 0,
            }
        end
    end
    return {
        house    = h,
        interior = interior,
        cid      = getCitizenId(src),
        canAccess = Housing.PlayerCanAccess(src, h),
        isOwner   = Housing.IsHouseOwner(src, h),
        -- Admins can hire/dismiss workers and place/move/remove entities
        -- regardless of ownership; the panel uses this to surface the
        -- relevant sections without forcing the admin to take ownership.
        isAdmin   = adminCheck(src),
        entities  = entities,
        lockers   = lockers,
    }
end)

-- ─── Boot ─────────────────────────────────────────────────────────────────

local function loadAll()
    local rows = MySQL.query.await("SELECT * FROM pickle_drugs_house_interiors") or {}
    for _, row in ipairs(rows) do Interiors[row.id] = interiorFromRow(row) end
    rows = MySQL.query.await("SELECT * FROM pickle_drugs_houses") or {}
    for _, row in ipairs(rows) do Houses[row.id] = houseFromRow(row) end
    print(("[pickle_drugs] housing: %d interior(s), %d house(s)"):format(
        (function() local n = 0; for _ in pairs(Interiors) do n = n + 1 end; return n end)(),
        (function() local n = 0; for _ in pairs(Houses) do n = n + 1 end; return n end)()
    ))
end

CreateThread(function()
    if not (MySQL and MySQL.ready) then return end
    MySQL.ready(function()
        local ok, err = pcall(function()
            MySQL.query.await([[
                CREATE TABLE IF NOT EXISTS pickle_drugs_house_interiors (
                    id           VARCHAR(64) PRIMARY KEY,
                    label        VARCHAR(64) NOT NULL,
                    kind         VARCHAR(16) NOT NULL DEFAULT 'teleport',
                    door_x       DOUBLE NOT NULL DEFAULT 0,
                    door_y       DOUBLE NOT NULL DEFAULT 0,
                    door_z       DOUBLE NOT NULL DEFAULT 0,
                    door_w       DOUBLE NOT NULL DEFAULT 0,
                    exit_x       DOUBLE NOT NULL DEFAULT 0,
                    exit_y       DOUBLE NOT NULL DEFAULT 0,
                    exit_z       DOUBLE NOT NULL DEFAULT 0,
                    exit_w       DOUBLE NOT NULL DEFAULT 0,
                    idle_x       DOUBLE NOT NULL DEFAULT 0,
                    idle_y       DOUBLE NOT NULL DEFAULT 0,
                    idle_z       DOUBLE NOT NULL DEFAULT 0,
                    idle_w       DOUBLE NOT NULL DEFAULT 0,
                    mgmt_x       DOUBLE NOT NULL DEFAULT 0,
                    mgmt_y       DOUBLE NOT NULL DEFAULT 0,
                    mgmt_z       DOUBLE NOT NULL DEFAULT 0,
                    mgmt_w       DOUBLE NOT NULL DEFAULT 0,
                    zones        TEXT NOT NULL,
                    mlo_polygon  TEXT NULL,
                    updated_at   BIGINT NOT NULL DEFAULT 0
                )
            ]])
            MySQL.query.await([[
                CREATE TABLE IF NOT EXISTS pickle_drugs_houses (
                    id              VARCHAR(64) PRIMARY KEY,
                    label           VARCHAR(64) NOT NULL,
                    interior_id     VARCHAR(64) NOT NULL,
                    door_world_x    DOUBLE NOT NULL DEFAULT 0,
                    door_world_y    DOUBLE NOT NULL DEFAULT 0,
                    door_world_z    DOUBLE NOT NULL DEFAULT 0,
                    door_world_w    DOUBLE NOT NULL DEFAULT 0,
                    sale_enabled    TINYINT(1) NOT NULL DEFAULT 0,
                    sale_price      INT NOT NULL DEFAULT 0,
                    rent_enabled    TINYINT(1) NOT NULL DEFAULT 0,
                    rent_price      INT NOT NULL DEFAULT 0,
                    rent_cycle_ms   BIGINT NOT NULL DEFAULT 0,
                    owner_citizenid VARCHAR(64) NULL,
                    tenure          VARCHAR(16) NOT NULL DEFAULT 'none',
                    rent_due_at     BIGINT NOT NULL DEFAULT 0,
                    residents       TEXT NOT NULL,
                    bucket          INT NOT NULL DEFAULT 0,
                    updated_at      BIGINT NOT NULL DEFAULT 0
                )
            ]])
            loadAll()
            -- One-shot data fix: an earlier saveHouse bug let drafts
            -- with id="" through, persisting a house under that key.
            -- Rename it and cascade the new id to every plot and
            -- employee that referenced it. Idempotent — once renamed,
            -- this branch never fires again.
            if Houses[""] then
                local newId = genId("hse", Houses)
                local broken = Houses[""]
                broken.id = newId
                Houses[newId] = broken
                Houses[""] = nil
                MySQL.update.await("UPDATE pickle_drugs_houses SET id=? WHERE id=''", { newId })
                MySQL.update.await("UPDATE pickle_drugs_entities SET house_id=? WHERE house_id=''", { newId })
                MySQL.update.await("UPDATE pickle_drugs_employees SET house_id=? WHERE house_id=''", { newId })
                print(("[pickle_drugs] housing: repaired empty-id house → %s (plots + employees cascaded)"):format(newId))
            end
            -- Persist any freshly-derived buckets (rows saved before the
            -- bucket column existed will have bucket=0).
            for _, h in pairs(Houses) do
                if h.bucket == 0 and h.kind ~= "mlo" then
                    h.bucket = Housing.BucketFor(h)
                    persistHouse(h)
                end
            end
        end)
        if not ok then
            print(("[pickle_drugs] housing: DB error: %s"):format(tostring(err)))
        end
        -- Push initial snapshot to everyone already connected.
        for _, i in pairs(Interiors) do TriggerClientEvent("pickle_drugs:interiorUpdate", -1, i) end
        for _, h in pairs(Houses)    do TriggerClientEvent("pickle_drugs:houseUpdate",    -1, h) end
    end)
end)

-- ─── Lease ticker ─────────────────────────────────────────────────────────

CreateThread(function()
    Wait(7000) -- after boot snapshot
    while true do
        local interval = (Config.Housing and Config.Housing.sweepIntervalMs) or 60000
        Wait(interval)
        local nowMs = now()
        local grace = (Config.Housing and Config.Housing.rentGracePeriodMs) or 0
        for _, h in pairs(Houses) do
            if h.tenure == "rented"
                and (h.rent_due_at or 0) > 0
                and (h.rent_due_at + grace) < nowMs
            then
                lapseLease(h)
            end
        end
    end
end)

-- ─── Snapshot push to joiners ─────────────────────────────────────────────

AddEventHandler("playerJoining", function()
    local src = source
    SetTimeout(2500, function()
        for _, i in pairs(Interiors) do TriggerClientEvent("pickle_drugs:interiorUpdate", src, i) end
        for _, h in pairs(Houses)    do TriggerClientEvent("pickle_drugs:houseUpdate",    src, h) end
    end)
end)

AddEventHandler("playerDropped", function()
    local src = source
    PlayersInBucket[src] = nil
end)
