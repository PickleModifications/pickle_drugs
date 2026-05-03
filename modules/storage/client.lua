-- Renders every storage locker in the world. Subscribes to storage
-- updates from the server, manages a single solid prop per locker plus an
-- ox_target zone with one "Open Storage" action. Bucket gating mirrors
-- grow/client.lua: lockers in a teleport-house only render when the
-- player is bucketed into that house, lockers in MLO houses always render.

local LockerState = {}      -- id → { row, prop, targetZoneId }
local PendingLockers = {}   -- id → row (waiting for housing data)
local OpenLocker = nil      -- locker id whose NUI panel is open
local CurrentSnapshot = nil -- last server snapshot for the open locker

local function targetAvailable() return GetResourceState("ox_target") == "started" end

--- Thin wrapper over PickleEntity.SafeSpawnProp for parity with grow/client.
local function spawnProp(model, coords, heading)
    return PickleEntity.SafeSpawnProp(model, coords, heading)
end

local function despawn(id)
    local s = LockerState[id]
    if not s then return end
    if s.prop and DoesEntityExist(s.prop) then DeleteEntity(s.prop) end
    if s.targetZoneId and targetAvailable() then
        exports.ox_target:removeZone(s.targetZoneId)
    end
    LockerState[id] = nil
end

local function shouldRender(row)
    if not Housing then return false end
    if not row.house_id or row.house_id == "" then return false end
    local h = Housing.GetHouse(row.house_id)
    if not h then return false end
    if h.kind == "mlo" then return true end
    return Housing.GetCurrentBucketHouseId() == row.house_id
end

local function attachTarget(row)
    if not targetAvailable() then return nil end
    local kindCfg = Config.Storage and Config.Storage.types and Config.Storage.types[row.kind]
    local model = kindCfg and kindCfg.model
    local zoneName = "pickle_drugs:storage_" .. row.id
    local sizeZ = 2.0
    local sizeX = math.max(0.6, (row.cell_w or 1) * 0.5)
    local sizeY = math.max(0.6, (row.cell_h or 1) * 0.5)
    local zx, zy, zz = row.coords_x, row.coords_y, row.coords_z
    if model and Housing and Housing.AdjustSpawnCoords then
        zx, zy, zz = Housing.AdjustSpawnCoords(model, zx, zy, zz, row.coords_w or 0.0)
    end
    exports.ox_target:addBoxZone({
        coords = vec3(zx, zy, zz + sizeZ * 0.5),
        size   = vec3(sizeX, sizeY, sizeZ),
        rotation = row.coords_w or 0.0,
        debug  = Config.Debug,
        name   = zoneName,
        options = {
            {
                name  = zoneName .. ":open",
                label = "Open Storage",
                icon  = "fa-solid fa-box-archive",
                distance = 2.5,
                onSelect = function()
                    Storage.OpenLocker(row.id)
                end,
            },
            {
                name  = zoneName .. ":move",
                label = "Move Locker",
                icon  = "fa-solid fa-arrows-up-down-left-right",
                distance = 2.5,
                canInteract = function()
                    return Housing and Housing.GetHouse and Housing.GetHouse(row.house_id) ~= nil
                end,
                onSelect = function()
                    Storage.MoveLocker(row.id)
                end,
            },
            {
                name  = zoneName .. ":remove",
                label = "Remove Locker",
                icon  = "fa-solid fa-trash",
                distance = 2.5,
                onSelect = function()
                    TriggerServerEvent("pickle_drugs:deleteHouseStorage", row.id)
                end,
            },
        },
    })
    return zoneName
end

local function render(row)
    PendingLockers[row.id] = nil
    local existing = LockerState[row.id]
    if existing then
        local sameModel = existing.row.kind == row.kind
        local samePose  = math.abs(existing.row.coords_x - row.coords_x) < 0.01
            and math.abs(existing.row.coords_y - row.coords_y) < 0.01
            and math.abs(existing.row.coords_z - row.coords_z) < 0.01
            and math.abs((existing.row.coords_w or 0) - (row.coords_w or 0)) < 0.01
        if sameModel and samePose then
            existing.row = row
            return
        end
        despawn(row.id)
    end

    local kindCfg = Config.Storage and Config.Storage.types and Config.Storage.types[row.kind]
    if not kindCfg or not kindCfg.model then return end

    local prop = spawnProp(kindCfg.model,
        { x = row.coords_x, y = row.coords_y, z = row.coords_z },
        row.coords_w or 0.0)
    if not prop then return end
    -- Belt-and-suspenders: force the new prop visible. CreateObject
    -- defaults to visible, but a follow-up render after a hide / move
    -- should never leave a freshly-spawned entity in any other state.
    SetEntityVisible(prop, true, false)
    LockerState[row.id] = {
        row    = row,
        prop   = prop,
        targetZoneId = attachTarget(row),
    }
end

local function applyOrDefer(row)
    if not row or not row.id then return end
    if not shouldRender(row) then
        PendingLockers[row.id] = row
        despawn(row.id)
        return
    end
    render(row)
end

local function reevaluateAll()
    for _, row in pairs(PendingLockers) do
        if shouldRender(row) then applyOrDefer(row) end
    end
    for id, s in pairs(LockerState) do
        if s.row and not shouldRender(s.row) then
            PendingLockers[id] = s.row
            despawn(id)
        end
    end
end

RegisterNetEvent("pickle_drugs:storageUpdate", function(row) applyOrDefer(row) end)
RegisterNetEvent("pickle_drugs:storageRemoved", function(id)
    PendingLockers[id] = nil
    despawn(id)
end)
-- enteredHouse / leftHouse / houseUpdate / interiorUpdate are dispatched
-- to all kinds via PickleEntity.ReevaluateAll in core/client.lua; we register
-- the kind below so the renderer participates without subscribing
-- separately and risking handler order drift.

-- ─── NUI panel ────────────────────────────────────────────────────────────

local closePanel  -- forward declared; defined below Storage.OpenLocker

function Storage.OpenLocker(id)
    if OpenLocker then return end
    local snap = lib.callback.await("pickle_drugs:openStorage", false, id)
    if not snap then
        lib.notify({ title = "Storage", description = "Can't open this locker.", type = "error" })
        return
    end
    if snap.busy then
        lib.notify({ title = "Storage", description = "Someone else is using this locker.", type = "error" })
        return
    end
    OpenLocker = id
    CurrentSnapshot = snap
    SetNuiFocus(true, true)
    SendNUIMessage({ action = "openStoragePanel", data = snap })

    -- The NUI panel listens for the Escape keydown directly and fires
    -- `storageClose` — far more reliable than IsDisabledControlJustReleased
    -- under NUI focus, which routes input to the browser instead of the
    -- gameplay control system. We still bounce pause-menu activation in a
    -- Lua thread so the GTA pause menu can't appear underneath the panel.
    CreateThread(function()
        while OpenLocker == id do
            Wait(0)
            if IsPauseMenuActive() then
                SetFrontendActive(false)
                ActivateFrontendMenu(`FE_MENU_VERSION_EMPTY_NO_BACKGROUND`, true, -1)
            end
        end
    end)
end

closePanel = function()
    if not OpenLocker then return end
    local id = OpenLocker
    OpenLocker = nil
    CurrentSnapshot = nil
    SetNuiFocus(false, false)
    SendNUIMessage({ action = "closeStoragePanel" })
    TriggerServerEvent("pickle_drugs:closeStorage", id)
end

RegisterNetEvent("pickle_drugs:storageContents", function(snap)
    if not OpenLocker or not snap or snap.id ~= OpenLocker then return end
    CurrentSnapshot = snap
    SendNUIMessage({ action = "storageContents", data = snap })
end)

RegisterNetEvent("pickle_drugs:storageForceClose", function(id)
    if OpenLocker ~= id then return end
    closePanel()
end)

RegisterNUICallback("storageClose", function(_, cb)
    closePanel()
    cb({ ok = true })
end)

RegisterNUICallback("storageTransfer", function(data, cb)
    cb({ ok = true })
    if not OpenLocker or not data then return end
    TriggerServerEvent("pickle_drugs:storageTransfer", {
        lockerId  = OpenLocker,
        direction = data.direction,
        fromSlot  = data.fromSlot,
        toSlot    = data.toSlot,
        count     = data.count,
    })
end)

-- ─── Move flow (reuses Housing.StartPlacement) ────────────────────────────

function Storage.MoveLocker(lockerId)
    local s = LockerState[lockerId]
    if not s or not s.row then return end
    local row = s.row
    local houseId = row.house_id
    local h = Housing and Housing.GetHouse and Housing.GetHouse(houseId)
    local interior = h and Housing.GetInterior and Housing.GetInterior(h.interior_id)
    if not interior or not interior.zones or #interior.zones == 0 then return end

    local kindCfg = Config.Storage and Config.Storage.types and Config.Storage.types[row.kind]
    if not kindCfg then return end

    -- Build collision list: every plot + every other locker in the house.
    local existing = {}
    local detail = lib.callback.await("pickle_drugs:getHouseDetail", false, houseId) or {}
    for _, p in ipairs(detail.entities or {}) do existing[#existing + 1] = p end
    local lockers = lib.callback.await("pickle_drugs:listStorage", false) or {}
    for _, l in ipairs(lockers) do
        if l.house_id == houseId and l.id ~= lockerId then
            existing[#existing + 1] = {
                id = l.id, zone_id = l.zone_id,
                cell_x = l.cell_x, cell_y = l.cell_y,
                cell_w = l.cell_w, cell_h = l.cell_h,
            }
        end
    end

    -- Hide live prop during placement.
    if s.prop and DoesEntityExist(s.prop) then SetEntityVisible(s.prop, false, false) end

    -- Recover an initial rotIndex relative to the source zone heading.
    local sourceZone
    for _, z in ipairs(interior.zones) do
        if z.id == row.zone_id then sourceZone = z break end
    end
    local initialRotIndex = Housing.RotIndexFromHeading(sourceZone, row.coords_w)

    Housing.StartPlacement({
        houseId = houseId,
        zones   = interior.zones,
        model   = kindCfg.model,
        existing = existing,
        initialRotIndex = initialRotIndex,
        onConfirm = function(res)
            -- Restore the old prop's visibility *before* the storageUpdate
            -- broadcast lands. If render's same-pose short-circuit ever
            -- mis-fires (snapped placement happens to land within the
            -- 0.01m comparison threshold of the old position) we'd leave
            -- a permanently invisible prop behind otherwise — which is
            -- exactly the "stays hidden until script restart" symptom.
            local cur = LockerState[lockerId]
            if cur and cur.prop and DoesEntityExist(cur.prop) then
                SetEntityVisible(cur.prop, true, false)
            end
            TriggerServerEvent("pickle_drugs:moveHouseStorage",
                lockerId, res.zoneId,
                res.cx, res.cy, res.sizeX, res.sizeY, res.rotIndex)
        end,
        onCancel = function()
            local cur = LockerState[lockerId]
            if cur and cur.prop and DoesEntityExist(cur.prop) then
                SetEntityVisible(cur.prop, true, false)
            end
        end,
    })
end

-- ─── Boot ─────────────────────────────────────────────────────────────────

CreateThread(function()
    -- Fetch + apply as soon as ox_lib is ready. The pre-fetch model wait
    -- and the 1.5s pad were defensive padding from before the heal loop
    -- existed — SafeSpawnProp now waits per-model up to 4s on its own,
    -- and the heal cycle catches any spawn that still failed first time.
    while not lib do Wait(0) end
    local rows = lib.callback.await("pickle_drugs:listStorage", false) or {}
    for _, row in ipairs(rows) do applyOrDefer(row) end
end)

AddEventHandler("onResourceStop", function(rn)
    if rn ~= GetCurrentResourceName() then return end
    for id in pairs(LockerState) do despawn(id) end
end)

PickleEntity.RegisterKind("storage", {
    reevaluate = function() reevaluateAll() end,
    heal = function()
        -- Drain pending lockers whose render gate may now be open.
        for _, row in pairs(PendingLockers) do
            if shouldRender(row) then applyOrDefer(row) end
        end
        -- Re-spawn any locker whose prop has gone missing (failed model
        -- load on first attempt, prop deleted externally, etc). Collect
        -- first so we don't mutate LockerState mid-iteration.
        local broken = {}
        for id, s in pairs(LockerState) do
            if s.row and (not s.prop or not DoesEntityExist(s.prop)) then
                broken[#broken + 1] = { id = id, row = s.row }
            end
        end
        for _, b in ipairs(broken) do
            despawn(b.id)
            applyOrDefer(b.row)
        end
    end,
})
