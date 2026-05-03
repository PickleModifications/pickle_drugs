-- Authoritative storage state. Lockers belong to a house + zone, like
-- plots, and share the unified `pickle_drugs_entities` table — storage
-- rows have kind='storage'. Subtype (small/medium/large) and the
-- slot→item map both live in the row's `metadata` JSON column.
-- Transfers round-trip through the Inventory bridge so the player's
-- inventory is the source of truth for their items.

Storage = Storage or {}

local Lockers = {}      -- id → row (in-memory cache; SQL is source of truth)
local Openers = {}      -- lockerId → src (single-opener lock)
local PlayerLocker = {} -- src → lockerId

-- Forward declaration. `snapshot` is defined further down (it depends on
-- helpers introduced later in the file) but `Storage.AddToLocker` —
-- called by the worker scheduler — needs to push a fresh snapshot to
-- any open viewer when it deposits. Without this declaration the
-- earlier reference resolves to a global nil and crashes the moment a
-- player happens to be viewing the locker as a worker delivers.
local snapshot

local function now() return os.time() * 1000 end

local function notify(src, msg, type_)
    if not src or src == 0 then return end
    TriggerClientEvent("ox_lib:notify", src,
        { title = "Storage", description = msg, type = type_ or "inform" })
end

local function adminCheck(src)
    if not Admin or not Admin.IsAdmin then return src == 0 end
    return Admin.IsAdmin(src)
end

-- ─── Row helpers ──────────────────────────────────────────────────────────

local function decodeJson(raw)
    if type(raw) == "table" then return raw end
    if type(raw) ~= "string" or raw == "" then return {} end
    local ok, v = pcall(json.decode, raw)
    if ok and type(v) == "table" then return v end
    return {}
end

--- Reads a unified-entities row of kind='storage'. The locker subtype
--- (small/medium/large) and items map both live in the metadata JSON;
--- placement fields share columns with plot rows.
local function rowFromDb(row)
    local meta = decodeJson(row.metadata)
    return {
        id        = row.id,
        kind      = meta.subType or row.kind, -- prefer metadata.subType
        house_id  = row.house_id,
        zone_id   = row.zone_id or "",
        cell_x    = tonumber(row.cell_x) or 0,
        cell_y    = tonumber(row.cell_y) or 0,
        cell_w    = tonumber(row.cell_w) or 1,
        cell_h    = tonumber(row.cell_h) or 1,
        coords_x  = tonumber(row.coords_x) or 0,
        coords_y  = tonumber(row.coords_y) or 0,
        coords_z  = tonumber(row.coords_z) or 0,
        coords_w  = tonumber(row.coords_w) or 0,
        items     = decodeJson(meta.items),
        updated_at = tonumber(row.updated_at) or 0,
    }
end

local function encodeMetadata(l)
    return json.encode({
        subType = l.kind,
        items   = l.items or {},
    })
end

--- Trims the locker row down to the placement-relevant fields the housing
--- collision check needs. Items are stripped — Housing.BuildOccupancy
--- only reads cell_*.
local function placementShape(l)
    return {
        id     = l.id,
        zone_id = l.zone_id,
        cell_x = l.cell_x, cell_y = l.cell_y,
        cell_w = l.cell_w, cell_h = l.cell_h,
    }
end

local function loadAll()
    local rows = MySQL.query.await(
        "SELECT * FROM pickle_drugs_entities WHERE kind='storage'") or {}
    for _, row in ipairs(rows) do
        Lockers[row.id] = rowFromDb(row)
    end
    debugPrint(("storage: loaded %d locker(s)"):format(#rows))
end

local function persistMeta(l)
    l.updated_at = now()
    MySQL.update.await([[
        UPDATE pickle_drugs_entities SET
            house_id=?, zone_id=?,
            cell_x=?, cell_y=?, cell_w=?, cell_h=?,
            coords_x=?, coords_y=?, coords_z=?, coords_w=?,
            metadata=?, updated_at=?
        WHERE id=?
    ]], {
        l.house_id, l.zone_id,
        l.cell_x, l.cell_y, l.cell_w, l.cell_h,
        l.coords_x, l.coords_y, l.coords_z, l.coords_w,
        encodeMetadata(l), l.updated_at, l.id,
    })
end

local function persistItems(l)
    l.updated_at = now()
    MySQL.update.await(
        "UPDATE pickle_drugs_entities SET metadata=?, updated_at=? WHERE id=?",
        { encodeMetadata(l), l.updated_at, l.id }
    )
end

local function publicRow(l)
    return {
        id        = l.id,
        kind      = l.kind,
        house_id  = l.house_id,
        zone_id   = l.zone_id,
        cell_x    = l.cell_x, cell_y = l.cell_y,
        cell_w    = l.cell_w, cell_h = l.cell_h,
        coords_x  = l.coords_x, coords_y = l.coords_y,
        coords_z  = l.coords_z, coords_w = l.coords_w,
        slots     = Storage.SlotsFor(l.kind),
    }
end

-- ─── Public reads (used by housing manage panel / grow collision) ────────

function Storage.GetLocker(id) return Lockers[id] end

function Storage.LockersForHouse(houseId)
    local out = {}
    for _, l in pairs(Lockers) do
        if l.house_id == houseId then out[#out + 1] = l end
    end
    return out
end

--- Placement-shape rows for collision against grow plots.
function Storage.PlacementRowsForHouse(houseId)
    local out = {}
    for _, l in pairs(Lockers) do
        if l.house_id == houseId then out[#out + 1] = placementShape(l) end
    end
    return out
end

--- Worker-facing write path. Adds `count` of `item` (with optional
--- metadata) to the locker, merging into an existing same-item stack
--- when one is present and otherwise dropping into the first free slot.
--- Returns `accepted, leftover` so the caller (typically Employees) can
--- keep what didn't fit. Force-closes the panel for any opener so they
--- see the new contents on next open.
function Storage.AddToLocker(lockerId, item, count, metadata)
    local total = tonumber(count) or 0
    local l = Lockers[lockerId]
    if not l or not item or total <= 0 then return 0, total end
    local cap = Storage.SlotsFor(l.kind)
    if cap == 0 then return 0, total end

    -- Stable string-keyed slot accessors (storage rows persist as JSON
    -- objects; numeric and string keys would otherwise both be written).
    local function getSlot(slot) return l.items[tostring(slot)] or l.items[slot] end
    local function setSlot(slot, v)
        l.items[slot] = nil
        l.items[tostring(slot)] = v
    end

    local remaining = total
    -- 1. Merge into any existing same-item stack. v1 ignores metadata
    -- equality — workers always carry an anonymous harvested stack.
    for i = 1, cap do
        local s = getSlot(i)
        if s and s.name == item then
            s.count = (tonumber(s.count) or 0) + remaining
            setSlot(i, s)
            remaining = 0
            break
        end
    end
    -- 2. Drop the remainder into the first free slot.
    if remaining > 0 then
        for i = 1, cap do
            if not getSlot(i) then
                setSlot(i, { name = item, count = remaining, metadata = metadata })
                remaining = 0
                break
            end
        end
    end

    persistItems(l)
    if Openers[lockerId] then
        TriggerClientEvent("pickle_drugs:storageContents",
            Openers[lockerId], snapshot(Openers[lockerId], l))
    end
    return total - remaining, remaining
end

--- World-space coords of the locker's footprint centre. Used by the
--- worker scheduler to walk to a deposit target.
function Storage.LockerCoords(lockerId)
    local l = Lockers[lockerId]
    if not l then return nil end
    return { x = l.coords_x, y = l.coords_y, z = l.coords_z, w = l.coords_w }
end

function Storage.OnHouseDeleted(houseId)
    for id, l in pairs(Lockers) do
        if l.house_id == houseId then
            Lockers[id] = nil
            MySQL.update.await("DELETE FROM pickle_drugs_entities WHERE id=?", { id })
            TriggerClientEvent("pickle_drugs:storageRemoved", -1, id)
        end
    end
end

local function broadcast(l)
    TriggerClientEvent("pickle_drugs:storageUpdate", -1, publicRow(l))
end

-- ─── Place / Move / Delete ────────────────────────────────────────────────

local function generateId(kind)
    local base = ("stg_%s_%d"):format(kind, now())
    if not Lockers[base] then return base end
    return ("%s_%d"):format(base, math.random(1000, 9999))
end

--- Builds the combined occupancy list for a house: every plot + every
--- locker except the one being moved (excludeId may be nil).
local function combinedExisting(houseId, excludeId)
    local out = {}
    if Grow and Grow.PlotsForHouse then
        for _, p in ipairs(Grow.PlotsForHouse(houseId)) do
            out[#out + 1] = p
        end
    end
    for _, l in ipairs(Storage.PlacementRowsForHouse(houseId)) do
        if l.id ~= excludeId then out[#out + 1] = l end
    end
    return out
end

Storage.CombinedExisting = combinedExisting

RegisterNetEvent("pickle_drugs:createHouseStorage",
function(houseId, zoneId, kind, cx, cy, sizeX, sizeY, rotIndex)
    local src = source
    if not Storage.TypeFor(kind) then
        notify(src, "Unknown storage type", "error") return
    end
    if type(houseId) ~= "string" or houseId == ""
        or type(zoneId) ~= "string" or zoneId == "" then
        notify(src, "Pick a property first", "error") return
    end
    cx = tonumber(cx); cy = tonumber(cy)
    sizeX = tonumber(sizeX); sizeY = tonumber(sizeY)
    rotIndex = (tonumber(rotIndex) or 0) % 4
    if not cx or not cy or not sizeX or not sizeY then return end

    if not Housing or not Housing.ValidatePlacement then
        notify(src, "Housing system not ready", "error") return
    end
    if not Housing.GetHouse(houseId) then
        notify(src, "Property no longer exists", "error") return
    end
    local existing = combinedExisting(houseId, nil)
    local ok, reason, world, fw, fh = Housing.ValidatePlacement(
        src, houseId, zoneId, cx, cy, sizeX, sizeY, rotIndex, existing
    )
    if not ok then
        notify(src, ("Can't place there (%s)"):format(reason or "?"), "error")
        return
    end

    -- world.w is the final placement heading; ValidatePlacement applies
    -- the rotIndex offset for us.
    local id = generateId(kind)
    local l = {
        id = id, kind = kind,
        house_id = houseId, zone_id = zoneId,
        cell_x = cx, cell_y = cy, cell_w = fw, cell_h = fh,
        coords_x = world.x, coords_y = world.y, coords_z = world.z, coords_w = world.w,
        items = {},
        updated_at = now(),
    }
    Lockers[id] = l
    MySQL.insert.await([[
        INSERT INTO pickle_drugs_entities
            (id, kind, drug, stage, soil_added_at, stage_started_at, water_until, cut_buds,
             coords_x, coords_y, coords_z, coords_w,
             house_id, zone_id, cell_x, cell_y, cell_w, cell_h,
             metadata, updated_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    ]], {
        id, "storage", "", 0, 0, 0, 0, "[]",
        world.x, world.y, world.z, world.w,
        houseId, zoneId, cx, cy, fw, fh,
        encodeMetadata(l), l.updated_at,
    })
    broadcast(l)
    notify(src, "Locker placed", "success")
end)

RegisterNetEvent("pickle_drugs:moveHouseStorage",
function(lockerId, zoneId, cx, cy, sizeX, sizeY, rotIndex)
    local src = source
    local l = Lockers[lockerId]
    if not l or not l.house_id then return end
    if type(zoneId) ~= "string" then return end
    cx = tonumber(cx); cy = tonumber(cy)
    sizeX = tonumber(sizeX); sizeY = tonumber(sizeY)
    rotIndex = (tonumber(rotIndex) or 0) % 4
    if not cx or not cy or not sizeX or not sizeY then return end

    -- Force-close any open viewers so contents can't be mutated mid-move.
    if Openers[lockerId] then
        local opener = Openers[lockerId]
        Openers[lockerId] = nil
        PlayerLocker[opener] = nil
        TriggerClientEvent("pickle_drugs:storageForceClose", opener, lockerId)
    end

    if not Housing or not Housing.ValidatePlacement then
        notify(src, "Housing system not ready", "error") return
    end
    local existing = combinedExisting(l.house_id, lockerId)
    local ok, reason, world, fw, fh = Housing.ValidatePlacement(
        src, l.house_id, zoneId, cx, cy, sizeX, sizeY, rotIndex, existing
    )
    if not ok then
        notify(src, ("Can't place there (%s)"):format(reason or "?"), "error")
        return
    end
    l.zone_id = zoneId
    l.cell_x, l.cell_y = cx, cy
    l.cell_w, l.cell_h = fw, fh
    l.coords_x, l.coords_y, l.coords_z, l.coords_w = world.x, world.y, world.z, world.w
    persistMeta(l)
    broadcast(l)
    notify(src, "Locker moved", "success")
end)

RegisterNetEvent("pickle_drugs:deleteHouseStorage", function(lockerId)
    local src = source
    local l = Lockers[lockerId]
    if not l or not l.house_id then return end
    local h = Housing and Housing.GetHouse and Housing.GetHouse(l.house_id) or nil
    if not h then return end
    local allowed = adminCheck(src)
        or (Housing.IsHouseOwner and Housing.IsHouseOwner(src, h))
        or (Housing.PlayerCanAccess and Housing.PlayerCanAccess(src, h))
    if not allowed then return end

    -- Spill contents back to the player so items aren't silently nuked.
    if Inventory and Inventory.AddItem and l.items then
        for _, it in pairs(l.items) do
            if it and it.name and (tonumber(it.count) or 0) > 0 then
                Inventory.AddItem(src, it.name, tonumber(it.count) or 0, it.metadata)
            end
        end
    end

    if Openers[lockerId] then
        local opener = Openers[lockerId]
        Openers[lockerId] = nil
        PlayerLocker[opener] = nil
        TriggerClientEvent("pickle_drugs:storageForceClose", opener, lockerId)
    end
    Lockers[lockerId] = nil
    MySQL.update.await("DELETE FROM pickle_drugs_entities WHERE id=?", { lockerId })
    TriggerClientEvent("pickle_drugs:storageRemoved", -1, lockerId)
    if Grow and Grow.OnLockerDeleted then Grow.OnLockerDeleted(lockerId) end
    notify(src, "Locker removed", "success")
end)

-- ─── Open / Close / Transfer ──────────────────────────────────────────────

local function ensureCanAccess(src, l)
    local h = Housing and Housing.GetHouse and Housing.GetHouse(l.house_id)
    if not h then return false end
    if adminCheck(src) then return true end
    if Housing.PlayerCanAccess and Housing.PlayerCanAccess(src, h) then return true end
    return false
end

snapshot = function(src, l)
    local items = {}
    for slot, it in pairs(l.items or {}) do
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
        id     = l.id,
        kind   = l.kind,
        label  = (Storage.TypeFor(l.kind) or {}).label or l.kind,
        slots  = Storage.SlotsFor(l.kind),
        items  = items,
        player = player,
        imagesPath = imagesPath,
    }
end

--- Strip the `dealer:` prefix from an id and return (true, slotId) when
--- it's a dealer storage virtual locker. Otherwise returns (false, id).
local function asDealerId(id)
    if type(id) == "string" and id:sub(1, 7) == "dealer:" then
        return true, id:sub(8)
    end
    return false, id
end

lib.callback.register("pickle_drugs:openStorage", function(src, lockerId)
    local isDealer, slotId = asDealerId(lockerId)
    if isDealer then
        if not (Dealers and Dealers.OpenAsLocker) then return nil end
        return Dealers.OpenAsLocker(src, slotId)
    end
    local l = Lockers[lockerId]
    if not l then return nil end
    if not ensureCanAccess(src, l) then return nil end
    if Openers[lockerId] and Openers[lockerId] ~= src then
        return { busy = true }
    end
    Openers[lockerId] = src
    PlayerLocker[src] = lockerId
    return snapshot(src, l)
end)

RegisterNetEvent("pickle_drugs:closeStorage", function(lockerId)
    local src = source
    local isDealer, slotId = asDealerId(lockerId)
    if isDealer then
        if Dealers and Dealers.CloseAsLocker then Dealers.CloseAsLocker(src, slotId) end
        return
    end
    if Openers[lockerId] == src then
        Openers[lockerId] = nil
        PlayerLocker[src] = nil
    end
end)

local function pushSnapshot(src, l)
    TriggerClientEvent("pickle_drugs:storageContents", src, snapshot(src, l))
end

--- Transfers happen as whole stacks (v1). The client sends:
---     direction = "deposit"  → move player slot N into locker slot M
---     direction = "withdraw" → move locker slot M into the player inventory
---     direction = "rearrange"→ move locker slot M into locker slot M2
--- All routes go through the Inventory bridge so the player's add/remove
--- is authoritative.
RegisterNetEvent("pickle_drugs:storageTransfer", function(payload)
    local src = source
    if type(payload) ~= "table" then return end
    local lockerId = payload.lockerId
    local isDealer, slotId = asDealerId(lockerId)
    if isDealer then
        if Dealers and Dealers.HandleTransfer then
            Dealers.HandleTransfer(src, slotId, payload)
        end
        return
    end
    local l = Lockers[lockerId]
    if not l or Openers[lockerId] ~= src then return end
    if not ensureCanAccess(src, l) then return end

    local dir = payload.direction
    local fromSlot = tonumber(payload.fromSlot)
    local toSlot   = tonumber(payload.toSlot)
    local reqCount = tonumber(payload.count)

    -- Deep-equal compare for item metadata. Two stacks merge only when
    -- both name and metadata match — different metadata = different stack.
    -- nil and an empty table are treated as equivalent so a worker-deposited
    -- stack (metadata = nil) can merge with a player-deposited one
    -- (ox_inventory returns metadata = {} for plain items).
    local function isEmptyMeta(t)
        if t == nil then return true end
        if type(t) ~= "table" then return false end
        return next(t) == nil
    end
    local function metaEq(a, b)
        if isEmptyMeta(a) and isEmptyMeta(b) then return true end
        if a == b then return true end
        local ta, tb = type(a), type(b)
        if ta ~= tb then return false end
        if ta ~= "table" then return false end
        return json.encode(a) == json.encode(b)
    end

    -- Slots persist as JSON object keys, which always round-trip as
    -- strings. Use string keys exclusively in-memory so json.encode
    -- doesn't see both 1 and "1" pointing to the same stack.
    local function getSlot(slot)
        local k = tostring(slot)
        return l.items[k] or l.items[slot]
    end
    local function setSlot(slot, value)
        l.items[slot] = nil
        l.items[tostring(slot)] = value
    end

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

        local cap = Storage.SlotsFor(l.kind)
        if cap == 0 then return end

        -- Resolve target slot:
        --  1. Explicit toSlot, if empty or holds a same-item stack — merge.
        --  2. Otherwise, find first free.
        local target = toSlot
        local merge = false
        if target and target >= 1 and target <= cap then
            local existing = getSlot(target)
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
            for i = 1, cap do
                if not getSlot(i) then target = i break end
            end
        end
        if not target then
            notify(src, "Locker is full", "error")
            pushSnapshot(src, l)
            return
        end

        local removed = Inventory.RemoveItem(src, source_.name, count, source_.metadata)
        if removed == false then
            notify(src, "Couldn't take that item", "error")
            return
        end
        if merge then
            local existing = getSlot(target)
            existing.count = (tonumber(existing.count) or 0) + count
            setSlot(target, existing)
        else
            setSlot(target, {
                name     = source_.name,
                count    = count,
                metadata = source_.metadata,
            })
        end
        persistItems(l)
        pushSnapshot(src, l)

    elseif dir == "withdraw" then
        if not fromSlot then return end
        local it = getSlot(fromSlot)
        if not it or not it.name then return end
        local stack = tonumber(it.count) or 0
        if stack <= 0 then
            setSlot(fromSlot, nil)
            persistItems(l)
            pushSnapshot(src, l)
            return
        end
        local count = math.max(1, math.min(stack, math.floor(reqCount or stack)))
        local added = Inventory.AddItem(src, it.name, count, it.metadata)
        if added == false then
            notify(src, "Inventory full", "error")
            return
        end
        if count >= stack then
            setSlot(fromSlot, nil)
        else
            it.count = stack - count
            setSlot(fromSlot, it)
        end
        persistItems(l)
        pushSnapshot(src, l)

    elseif dir == "rearrange" then
        if not fromSlot or not toSlot or fromSlot == toSlot then return end
        local cap = Storage.SlotsFor(l.kind)
        if toSlot < 1 or toSlot > cap then return end
        local a = getSlot(fromSlot)
        if not a then return end
        local b = getSlot(toSlot)
        local stack = tonumber(a.count) or 0
        -- Partial split / merge: when the client sends a count smaller than
        -- the source stack we move only that many. A partial drop onto a
        -- different-item slot is a no-op (can't swap part of a stack).
        local count = tonumber(reqCount)
        if not count or count >= stack then count = stack end
        if count < 1 then return end
        local sameItem = b and b.name == a.name and metaEq(b.metadata, a.metadata)

        if count < stack then
            if b and not sameItem then
                -- Different item under the cursor — can't accept a partial.
                pushSnapshot(src, l)
                return
            end
            local newB = sameItem and b or { name = a.name, count = 0, metadata = a.metadata }
            newB.count = (tonumber(newB.count) or 0) + count
            setSlot(toSlot, newB)
            a.count = stack - count
            setSlot(fromSlot, a)
        else
            -- Full-stack move: same-item → merge, else swap.
            if sameItem then
                b.count = (tonumber(b.count) or 0) + count
                setSlot(toSlot, b)
                setSlot(fromSlot, nil)
            else
                setSlot(fromSlot, b)
                setSlot(toSlot, a)
            end
        end
        persistItems(l)
        pushSnapshot(src, l)
    end
end)

-- ─── Snapshot to joiners ──────────────────────────────────────────────────

lib.callback.register("pickle_drugs:listStorage", function()
    local out = {}
    for _, l in pairs(Lockers) do out[#out + 1] = publicRow(l) end
    return out
end)

AddEventHandler("playerJoining", function()
    local src = source
    SetTimeout(2500, function()
        for _, l in pairs(Lockers) do
            TriggerClientEvent("pickle_drugs:storageUpdate", src, publicRow(l))
        end
    end)
end)

AddEventHandler("playerDropped", function()
    local src = source
    local lid = PlayerLocker[src]
    if lid and Openers[lid] == src then Openers[lid] = nil end
    PlayerLocker[src] = nil
end)

-- ─── Boot ─────────────────────────────────────────────────────────────────
-- The unified `pickle_drugs_entities` table is owned (created/migrated)
-- by modules/grow/server.lua. We just wait for grow to finish its boot
-- migration, then load our subset of rows.

CreateThread(function()
    if not (MySQL and MySQL.ready) then return end
    MySQL.ready(function()
        local deadline = GetGameTimer() + 8000
        while not (Grow and Grow.IsReady) and GetGameTimer() < deadline do
            Wait(50)
        end
        local ok, err = pcall(function() loadAll() end)
        if not ok then
            print(("[pickle_drugs] storage: DB error: %s"):format(tostring(err)))
        end
        for _, l in pairs(Lockers) do
            TriggerClientEvent("pickle_drugs:storageUpdate", -1, publicRow(l))
        end
        Storage.IsReady = true
        local n = 0; for _ in pairs(Lockers) do n = n + 1 end
        print(("[pickle_drugs] storage: ready with %d locker(s)"):format(n))
    end)
end)
