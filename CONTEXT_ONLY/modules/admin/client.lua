--- Open admin panel via net event (triggered by server command)
RegisterNetEvent("pickle_dealerships:openAdminPanel", function()
    OpenNui('admin', {
        dealershipId = 0,
        dealershipName = 'Dealership Panel',
        role = 'admin',
        tier = 4,
    })
end)

--- Fetch online players for admin dropdown
RegisterNUICallback("adminGetOnlinePlayers", function(_, cb)
    local result = lib.callback.await("pickle_dealerships:adminGetOnlinePlayers", false)
    cb(result or {})
end)

--- Maps a GetVehicleClass integer (0-21) to the catalog's string class keys.
--- Only classes that make sense in a dealership context are included —
--- service / emergency / military / industrial etc. deliberately fall
--- through to nil so we don't accidentally seed a police cruiser as a
--- "sedan" in the catalog.
local VEHICLE_CLASS_BY_INT = {
    [0]  = "compact",
    [1]  = "sedan",
    [2]  = "suv",
    [3]  = "coupe",
    [4]  = "muscle",
    [5]  = "sports_classic",
    [6]  = "sports",
    [7]  = "super",
    [8]  = "motorcycle",
    [9]  = "offroad",
    [12] = "van",
    [13] = "cycle",
    [14] = "boat",
    [15] = "helicopter",
    [16] = "plane",
}

--- Spawns the vehicle model off-map, pulls its class via GetVehicleClass,
--- deletes it, and returns the class key. Used by the admin catalog form
--- to auto-fill the class dropdown after the admin types a model name.
--- Stays invisible/no-collide/frozen/non-networked so nothing gets
--- streamed to other players.
RegisterNUICallback("adminDetectVehicleClass", function(data, cb)
    local model = data and data.model and tostring(data.model):lower() or ""
    if model == "" then cb({ class = nil }) return end

    local hash = joaat(model)
    if not IsModelInCdimage(hash) or not IsModelAVehicle(hash) then
        cb({ class = nil }) return
    end

    RequestModel(hash)
    local deadline = GetGameTimer() + 3000
    while not HasModelLoaded(hash) and GetGameTimer() < deadline do Wait(0) end
    if not HasModelLoaded(hash) then
        cb({ class = nil }) return
    end

    -- Spawn as a local-only entity at a deep-underground coord so it's well
    -- outside any streaming range. isNetwork=false keeps it off the net
    -- session entirely.
    local veh = CreateVehicle(hash, 0.0, 0.0, -500.0, 0.0, false, false)
    if not veh or veh == 0 then
        SetModelAsNoLongerNeeded(hash)
        cb({ class = nil }) return
    end
    SetEntityVisible(veh, false, false)
    SetEntityCollision(veh, false, false)
    FreezeEntityPosition(veh, true)
    SetVehicleIsConsideredByPlayer(veh, false)

    local classInt = GetVehicleClass(veh)
    DeleteEntity(veh)
    SetModelAsNoLongerNeeded(hash)

    cb({ class = VEHICLE_CLASS_BY_INT[classInt] })
end)

--- Fetch all dealerships for admin view
RegisterNUICallback("adminGetAllDealerships", function(_, cb)
    local result = lib.callback.await("pickle_dealerships:adminGetAllDealerships", false)
    if result then
        cb({ success = true, dealerships = result })
    else
        ShowNotification(_L("admin_fetch_failed"))
        cb({ success = false, message = _L("admin_fetch_failed") })
    end
end)

--- Transfer ownership of a dealership
RegisterNUICallback("adminTransferOwnership", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:adminTransferOwnership", false, {
        dealershipId = data.dealershipId,
        newOwnerId   = data.newOwnerId,
    })
    if result and result.success then
        ShowNotification(result.message)
        cb({ success = true })
    else
        ShowNotification(result and result.message or _L("admin_transfer_failed"))
        cb({ success = false, message = result and result.message or _L("admin_transfer_failed") })
    end
end)

--- Set dealership balance
RegisterNUICallback("adminSetBalance", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:adminSetBalance", false, {
        dealershipId = data.dealershipId,
        amount       = data.amount,
    })
    if result and result.success then
        ShowNotification(result.message)
        cb({ success = true, newBalance = result.newBalance })
    else
        ShowNotification(result and result.message or _L("admin_balance_failed"))
        cb({ success = false, message = result and result.message or _L("admin_balance_failed") })
    end
end)

-- adminSetTier was removed in the tier-to-groups migration. Use
-- adminSetDealershipGroups to change which catalog groups feed a dealership.

--- Catalog group CRUD bridges. Each maps 1:1 to a server callback added in
--- modules/admin/server.lua; no client-side state needed.
RegisterNUICallback("adminGetGroups", function(_, cb)
    local rows = lib.callback.await("pickle_dealerships:adminGetGroups", false)
    cb(rows or {})
end)

RegisterNUICallback("adminCreateGroup", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:adminCreateGroup", false, data)
    if result and result.success then ShowNotification(result.message)
    else ShowNotification(result and result.message or _L("admin_group_create_failed")) end
    cb(result or { success = false })
end)

RegisterNUICallback("adminUpdateGroup", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:adminUpdateGroup", false, data)
    if result and result.success then ShowNotification(result.message)
    else ShowNotification(result and result.message or _L("admin_group_update_failed")) end
    cb(result or { success = false })
end)

RegisterNUICallback("adminDeleteGroup", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:adminDeleteGroup", false, data)
    if result and result.success then ShowNotification(result.message)
    else ShowNotification(result and result.message or _L("admin_group_delete_failed")) end
    cb(result or { success = false })
end)

RegisterNUICallback("adminSetVehicleGroups", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:adminSetVehicleGroups", false, data)
    cb(result or { success = false })
end)

RegisterNUICallback("adminSetDealershipGroups", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:adminSetDealershipGroups", false, data)
    if result and result.success then ShowNotification(result.message) end
    cb(result or { success = false })
end)

RegisterNUICallback("adminGetDealershipGroups", function(data, cb)
    local rows = lib.callback.await("pickle_dealerships:adminGetDealershipGroups", false, data)
    cb(rows or {})
end)

--- Stock a dealership from the full catalog at the admin-chosen quantity
RegisterNUICallback("adminStockAllFromCatalog", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:adminStockAllFromCatalog", false, {
        dealershipId = data.dealershipId,
        quantity     = data.quantity,
    })
    if result and result.success then
        ShowNotification(result.message)
        cb({ success = true, inserted = result.inserted })
    else
        ShowNotification(result and result.message or _L("admin_stockall_failed") or "Failed to stock from catalog.")
        cb({ success = false, message = result and result.message })
    end
end)

--- Reset dealership
RegisterNUICallback("adminResetDealership", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:adminResetDealership", false, {
        dealershipId = data.dealershipId,
    })
    if result and result.success then
        ShowNotification(result.message)
        cb({ success = true })
    else
        ShowNotification(result and result.message or _L("admin_reset_failed"))
        cb({ success = false, message = result and result.message or _L("admin_reset_failed") })
    end
end)

--- Toggle dealership mode (public / player-owned)
RegisterNUICallback("adminToggleMode", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:adminToggleMode", false, {
        dealershipId = data.dealershipId,
    })
    if result and result.success then
        ShowNotification(result.message)
        cb({ success = true, newMode = result.newMode })
    else
        ShowNotification(result and result.message or _L("admin_mode_failed"))
        cb({ success = false, message = result and result.message or _L("admin_mode_failed") })
    end
end)

--- Toggle seize mode
RegisterNUICallback("adminToggleSeize", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:adminToggleSeize", false, {
        dealershipId = data.dealershipId,
    })
    if result and result.success then
        ShowNotification(result.message)
        cb({ success = true, seizeEnabled = result.seizeEnabled })
    else
        ShowNotification(result and result.message or _L("admin_seize_failed"))
        cb({ success = false, message = result and result.message or _L("admin_seize_failed") })
    end
end)

--- Permanently delete a dealership (confirmation handled in NUI)
RegisterNUICallback("adminDeleteDealership", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:adminDeleteDealership", false, {
        dealershipId = data.dealershipId,
    })
    if result and result.success then
        ShowNotification(result.message)
        cb({ success = true })
    else
        ShowNotification(result and result.message or _L("admin_delete_failed"))
        cb({ success = false, message = result and result.message or _L("admin_delete_failed") })
    end
end)

--- Create a new dealership
RegisterNUICallback("adminCreateDealership", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:adminCreateDealership", false, {
        label            = data.label,
        mode             = data.mode,
        type             = data.type,
        tier             = data.tier,
        factionType      = data.factionType,
        factionName      = data.factionName,
        ownerIdentifier  = data.ownerIdentifier,
        coords           = data.coords,
        spawnPoint       = data.spawnPoint,
        deliveryPoint    = data.deliveryPoint,
        managementPoint  = data.managementPoint,
        salesPoint       = data.salesPoint,
        showroomPoint    = data.showroomPoint,
        displaySpots     = data.displaySpots,
        npcSpawnPoints   = data.npcSpawnPoints,
    })
    if result and result.success then
        ShowNotification(result.message)
        cb({ success = true, dealershipId = result.dealershipId })
    else
        ShowNotification(result and result.message or _L("admin_create_failed"))
        cb({ success = false, message = result and result.message or _L("admin_create_failed") })
    end
end)

--- DRAFT MODE for the create-dealership dialog. Closes the NUI, runs the appropriate
--- gizmo for the chosen field, then re-opens the admin panel with a `pendingDealership`
--- draft so the create dialog can repopulate with the previously entered values plus
--- the freshly placed coord. Mirrors the depot create flow exactly.
-- Ped model used to visualize the currently-being-placed NPC spawn point.
-- Kept generic so it reads as "some customer" regardless of dealership type.
local NPC_PLACEMENT_PED = `a_m_y_business_01`
-- Prop for display spots — the lab barrier flipped flat gives an admin the
-- footprint of a parked vehicle. The -1.26 Z offset must match the natural
-- ghost-spawn offset used by modules/stock/client.lua (SpawnGhostAt) so the
-- barrier sits at exactly the same height during placement, in the preview,
-- and in live dealerships. The barrier's origin is ~1.26m above its bottom
-- face once it's rotated flat, so this offset is what drops the visible
-- surface onto the ground.
local DISPLAY_SPOT_PROP = `xm_prop_lab_barrier02`
local DISPLAY_SPOT_OFFSET = vector3(0.0, 0.0, 0.0)
local DISPLAY_SPOT_ROTATION = vector3(90.0, 0.0, 0.0)
-- Generic car used for placing positions where a vehicle ultimately sits
-- (spawn point, showroom point). Admin sees the actual footprint/heading
-- rather than a tiny prop.
local VEHICLE_PLACEMENT_MODEL = `sultan`

--- Spawn a ghost vehicle in front of the player, hand it to the gizmo, and
--- clean up. Returns the gizmo result (or nil on model-load failure / cancel).
local function PlaceGhostVehicleGizmo(model, alpha)
    RequestModel(model)
    local deadline = GetGameTimer() + 5000
    while not HasModelLoaded(model) and GetGameTimer() < deadline do Wait(0) end
    if not HasModelLoaded(model) then return nil end
    local ped = PlayerPedId()
    local spawn = GetEntityCoords(ped) + GetEntityForwardVector(ped) * 6.0
    local veh = CreateVehicle(model, spawn.x, spawn.y, spawn.z, GetEntityHeading(ped), false, false)
    SetModelAsNoLongerNeeded(model)
    if not veh or not DoesEntityExist(veh) then return nil end
    SetEntityAsMissionEntity(veh, true, true)
    SetEntityInvincible(veh, true)
    SetEntityCollision(veh, false, false)
    SetEntityAlpha(veh, alpha or 160, false)
    local result = StartGizmoEditor({ entity = veh, enableCancel = true })
    if DoesEntityExist(veh) then DeleteEntity(veh) end
    return result
end

-- Previews for already-placed spots/NPCs during the create dialog. Spawned as
-- real entities (not markers) so the admin sees the actual prop/ped shapes
-- they'll live with. Collision is disabled on every preview so the gizmo's
-- raycast passes straight through to the ground beneath them.
local previewSpotEntities = {}
local previewNpcEntities = {}

local function ClearPreviewSpots()
    for _, ent in ipairs(previewSpotEntities) do
        if DoesEntityExist(ent) then DeleteEntity(ent) end
    end
    previewSpotEntities = {}
end

local function ClearPreviewNpcs()
    for _, ent in ipairs(previewNpcEntities) do
        if DoesEntityExist(ent) then DeleteEntity(ent) end
    end
    previewNpcEntities = {}
end

local function SpawnPreviewSpot(s)
    RequestModel(DISPLAY_SPOT_PROP)
    local deadline = GetGameTimer() + 2000
    while not HasModelLoaded(DISPLAY_SPOT_PROP) and GetGameTimer() < deadline do Wait(0) end
    if not HasModelLoaded(DISPLAY_SPOT_PROP) then return nil end
    local obj = CreateObject(
        DISPLAY_SPOT_PROP,
        s.x + DISPLAY_SPOT_OFFSET.x,
        s.y + DISPLAY_SPOT_OFFSET.y,
        s.z - 1.26,
        false, false, false
    )
    SetModelAsNoLongerNeeded(DISPLAY_SPOT_PROP)
    if not obj or not DoesEntityExist(obj) then return nil end
    SetEntityRotation(obj, DISPLAY_SPOT_ROTATION.x, DISPLAY_SPOT_ROTATION.y, (s.w or 0.0) + DISPLAY_SPOT_ROTATION.z, 2, true)
    FreezeEntityPosition(obj, true)
    SetEntityCollision(obj, false, false)
    SetEntityInvincible(obj, true)
    SetEntityAlpha(obj, 180, false)
    return obj
end

local function SpawnPreviewNpc(p)
    RequestModel(NPC_PLACEMENT_PED)
    local deadline = GetGameTimer() + 2000
    while not HasModelLoaded(NPC_PLACEMENT_PED) and GetGameTimer() < deadline do Wait(0) end
    if not HasModelLoaded(NPC_PLACEMENT_PED) then return nil end
    local ped = CreatePed(4, NPC_PLACEMENT_PED, p.x, p.y, p.z, p.w or 0.0, false, false)
    SetModelAsNoLongerNeeded(NPC_PLACEMENT_PED)
    if not ped or not DoesEntityExist(ped) then return nil end
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetEntityInvincible(ped, true)
    FreezeEntityPosition(ped, true)
    SetEntityCollision(ped, false, false)
    SetEntityAlpha(ped, 200, false)
    return ped
end

--- Refresh the create-flow preview entities to match the supplied draft. Kept
--- simple (tear down + respawn) because the lists are small and change only
--- when the admin adds/removes a point.
local function UpdateCreateFlowPreviews(draft)
    ClearPreviewSpots()
    ClearPreviewNpcs()
    if not draft then return end
    if type(draft.displaySpots) == "table" then
        for _, s in ipairs(draft.displaySpots) do
            if type(s) == "table" and s.x then
                local obj = SpawnPreviewSpot(s)
                if obj then previewSpotEntities[#previewSpotEntities + 1] = obj end
            end
        end
    end
    if type(draft.npcSpawnPoints) == "table" then
        for _, p in ipairs(draft.npcSpawnPoints) do
            if type(p) == "table" and p.x then
                local ped = SpawnPreviewNpc(p)
                if ped then previewNpcEntities[#previewNpcEntities + 1] = ped end
            end
        end
    end
end

local function EndCreateFlow()
    ClearPreviewSpots()
    ClearPreviewNpcs()
end

--- React fires this whenever the create dialog opens or the placed-points list
--- changes (add, remove). Lua respawns the preview entities to match.
RegisterNUICallback("adminUpdateCreateFlow", function(payload, cb)
    UpdateCreateFlowPreviews(payload and payload.draft)
    cb({ success = true })
end)

--- React fires this when the create dialog closes for any reason (cancel,
--- discard-confirmed, successful create, escape).
RegisterNUICallback("adminEndCreateFlow", function(_, cb)
    EndCreateFlow()
    cb({ success = true })
end)

RegisterNUICallback("adminPlaceDealershipPoint", function(payload, cb)
    CloseNui()

    local field = payload.field   -- 'coords' | 'spawnPoint' | 'deliveryPoint' | 'displaySpot' | 'npcSpawnPoint' | interaction points
    local draft = payload.draft or {}

    -- Make sure the marker render thread knows about whatever's already placed
    -- before we hand control to the gizmo (NUI closes here; the React side
    -- can't keep the flow in sync during this window).
    UpdateCreateFlowPreviews(draft)

    local result
    if field == "deliveryPoint" then
        -- Ghost tr2 trailer so the admin sees the exact footprint drivers drop into.
        result = PlaceGhostVehicleGizmo(`tr2`, 160)
    elseif field == "spawnPoint" or field == "showroomPoint" then
        -- Ghost sedan so the admin sees the footprint + heading of a parked car.
        result = PlaceGhostVehicleGizmo(VEHICLE_PLACEMENT_MODEL, 160)
    elseif field == "displaySpot" then
        result = StartGizmoEditor({
            model = DISPLAY_SPOT_PROP,
            enableCancel = true,
            deleteEntity = true,
            coordsOffset = DISPLAY_SPOT_OFFSET,
            rotationOffset = DISPLAY_SPOT_ROTATION,
        })
    elseif field == "npcSpawnPoint" then
        -- Ped-based placement so the admin sees exactly where the customer
        -- will appear and which direction they'll face.
        local playerPed = PlayerPedId()
        local spawn = GetEntityCoords(playerPed) + GetEntityForwardVector(playerPed) * 2.0
        RequestModel(NPC_PLACEMENT_PED)
        local t = GetGameTimer() + 5000
        while not HasModelLoaded(NPC_PLACEMENT_PED) and GetGameTimer() < t do Wait(0) end
        if HasModelLoaded(NPC_PLACEMENT_PED) then
            local previewPed = CreatePed(4, NPC_PLACEMENT_PED, spawn.x, spawn.y, spawn.z, GetEntityHeading(playerPed), false, false)
            SetModelAsNoLongerNeeded(NPC_PLACEMENT_PED)
            if previewPed and DoesEntityExist(previewPed) then
                SetEntityInvincible(previewPed, true)
                SetBlockingOfNonTemporaryEvents(previewPed, true)
                SetEntityCollision(previewPed, false, false)
                SetEntityAsMissionEntity(previewPed, true, true)
                result = StartGizmoEditor({ entity = previewPed, enableCancel = true })
                if DoesEntityExist(previewPed) then DeleteEntity(previewPed) end
            end
        end
    else
        result = StartGizmoEditor({
            model = `prop_tennis_ball`,
            enableCancel = true,
            deleteEntity = true,
        })
    end

    if result and result.position then
        local coord = {
            x = result.position.x,
            y = result.position.y,
            z = result.position.z,
            w = result.rotation and result.rotation.z or 0.0,
        }
        if field == "coords" then draft.coords = coord
        elseif field == "spawnPoint" then draft.spawnPoint = coord
        elseif field == "deliveryPoint" then draft.deliveryPoint = coord
        elseif field == "managementPoint" then draft.managementPoint = coord
        elseif field == "salesPoint" then draft.salesPoint = coord
        elseif field == "showroomPoint" then draft.showroomPoint = coord
        elseif field == "displaySpot" then
            draft.displaySpots = draft.displaySpots or {}
            draft.displaySpots[#draft.displaySpots + 1] = coord
        elseif field == "npcSpawnPoint" then
            draft.npcSpawnPoints = draft.npcSpawnPoints or {}
            draft.npcSpawnPoints[#draft.npcSpawnPoints + 1] = coord
        end
    end

    OpenNui('admin', {
        dealershipId = 0,
        dealershipName = 'Dealership Panel',
        role = 'admin',
        tier = 4,
        pendingDealership = draft,
    })
    cb({ success = result ~= nil and result.position ~= nil })
end)

--- Start gizmo placement for a dealership position
--- The NUI closes, player places with gizmo, result is saved to server, NUI re-opens
RegisterNUICallback("adminStartGizmo", function(data, cb)
    -- Close the NUI so the player can use the gizmo
    CloseNui()

    local isDisplaySpot = data.field == "displaySpot"
    local isDeliveryPoint = data.field == "deliveryPoint"
    local isNpcSpawn = data.field == "npcSpawnPoint"
    -- "showroomPoint" is only used by the create-flow draft; the existing-dealership
    -- positions tab sends the showroom as field="interactionPoint", pointType="showroom".
    -- Both paths need the ghost-car preview.
    local isVehiclePoint = data.field == "spawnPoint"
        or data.field == "showroomPoint"
        or (data.field == "interactionPoint" and data.pointType == "showroom")
    local result

    if isDeliveryPoint then
        -- Ghost tr2 trailer so the admin sees the exact footprint drivers drop into.
        result = PlaceGhostVehicleGizmo(`tr2`, 160)
    elseif isVehiclePoint then
        -- Ghost sedan so the admin sees the footprint + heading of a parked car.
        result = PlaceGhostVehicleGizmo(VEHICLE_PLACEMENT_MODEL, 160)
    elseif isNpcSpawn then
        -- Ped-based placement so the admin sees the customer and can aim the heading.
        local playerPed = PlayerPedId()
        local spawn = GetEntityCoords(playerPed) + GetEntityForwardVector(playerPed) * 2.0
        RequestModel(NPC_PLACEMENT_PED)
        local t = GetGameTimer() + 5000
        while not HasModelLoaded(NPC_PLACEMENT_PED) and GetGameTimer() < t do Wait(0) end
        if HasModelLoaded(NPC_PLACEMENT_PED) then
            local previewPed = CreatePed(4, NPC_PLACEMENT_PED, spawn.x, spawn.y, spawn.z, GetEntityHeading(playerPed), false, false)
            SetModelAsNoLongerNeeded(NPC_PLACEMENT_PED)
            if previewPed and DoesEntityExist(previewPed) then
                SetEntityInvincible(previewPed, true)
                SetBlockingOfNonTemporaryEvents(previewPed, true)
                SetEntityCollision(previewPed, false, false)
                SetEntityAsMissionEntity(previewPed, true, true)
                result = StartGizmoEditor({ entity = previewPed, enableCancel = true })
                if DoesEntityExist(previewPed) then DeleteEntity(previewPed) end
            end
        end
    else
        local model = isDisplaySpot and DISPLAY_SPOT_PROP or `prop_tennis_ball`
        result = StartGizmoEditor({
            model = model,
            enableCancel = true,
            deleteEntity = true,
            coordsOffset = isDisplaySpot and DISPLAY_SPOT_OFFSET or nil,
            rotationOffset = isDisplaySpot and DISPLAY_SPOT_ROTATION or nil,
        })
    end

    if result and result.position then
        local position = result.position
        local rotation = result.rotation

        -- Save position to the server
        local saveResult = lib.callback.await("pickle_dealerships:adminSavePosition", false, {
            dealershipId = data.dealershipId,
            field = data.field,
            pointType = data.pointType,
            value = {
                x = position.x,
                y = position.y,
                z = position.z,
                w = rotation and rotation.z or 0.0,
            },
        })

        -- Re-open admin panel on the positions tab
        OpenNui('admin', {
            dealershipId = 0,
            dealershipName = 'Dealership Panel',
            role = 'admin',
            tier = 4,
            positionsDealershipId = data.dealershipId,
            metadata = saveResult and saveResult.metadata or nil,
            scrollToSpots = data.field == "displaySpot",
        })

        cb(saveResult or { success = false })
    else
        -- Player cancelled — re-open UI
        OpenNui('admin', {
            dealershipId = 0,
            dealershipName = 'Dealership Panel',
            role = 'admin',
            tier = 4,
            positionsDealershipId = data.dealershipId,
        })

        cb({ success = false, message = _L("admin_placement_cancelled") })
    end
end)

RegisterNUICallback("adminRemovePosition", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:adminRemovePosition", false, data)
    if result and result.success then
        ShowNotification(result.message)
    else
        ShowNotification(result and result.message or _L("admin_position_failed"))
    end
    cb(result or { success = false })
end)

RegisterNUICallback("adminSetAccess", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:adminSetAccess", false, data)
    if result and result.success then
        ShowNotification(result.message)
    else
        ShowNotification(result and result.message or "Failed to update access.")
    end
    cb(result or { success = false })
end)

RegisterNUICallback("adminSetAltCurrencies", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:setAcceptedAltCurrencies", false, {
        dealershipId = data.dealershipId,
        accepted     = data.accepted,
        -- Forward the base cash/bank toggles so "donator-only" shops stick.
        -- Previously this wrapper dropped `base`, so the server only saw the
        -- alt-currency list and the defaults ({ cash = true, bank = true })
        -- re-applied on the next read.
        base         = data.base,
    })
    if result and result.success then
        ShowNotification(result.message)
    else
        ShowNotification(result and result.message or _L("alt_currencies_update_failed"))
    end
    cb(result or { success = false })
end)

RegisterNUICallback("adminSetFaction", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:adminSetFaction", false, data)
    if result and result.success then
        ShowNotification(result.message)
    else
        ShowNotification(result and result.message or _L("admin_job_failed"))
    end
    cb(result or { success = false })
end)

-- ─── Catalog Management NUI Callbacks ───────────────────────────────────────

RegisterNUICallback("adminGetCatalog", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:adminGetCatalog", false, {
        page = data.page or 1,
        pageSize = data.pageSize or 50,
        search = data.search or "",
        typeFilter = data.typeFilter or "all",
    })
    if result then
        cb({ success = true, items = result.items, total = result.total, page = result.page, pageSize = result.pageSize })
    else
        cb({ success = false, message = _L("admin_catalog_fetch_failed") })
    end
end)

RegisterNUICallback("adminAddCatalogVehicle", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:adminAddCatalogVehicle", false, data)
    if result and result.success then
        ShowNotification(result.message)
    else
        ShowNotification(result and result.message or _L("admin_catalog_add_failed"))
    end
    cb(result or { success = false })
end)

RegisterNUICallback("adminUpdateCatalogVehicle", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:adminUpdateCatalogVehicle", false, data)
    if result and result.success then
        ShowNotification(result.message)
    else
        ShowNotification(result and result.message or _L("admin_catalog_update_failed"))
    end
    cb(result or { success = false })
end)

RegisterNUICallback("adminRemoveCatalogVehicle", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:adminRemoveCatalogVehicle", false, data)
    if result and result.success then
        ShowNotification(result.message)
    else
        ShowNotification(result and result.message or _L("admin_catalog_remove_failed"))
    end
    cb(result or { success = false })
end)

-- ─── Photo Booth ────────────────────────────────────────────────────────────

local PhotoBoothState = nil

local PhotoBoothCamThread = nil
local PhotoBoothInput = {
    lookX = 0.0, lookY = 0.0, dragging = false, zoom = 0.0, panning = false,
}

RegisterNUICallback("photoBoothInput", function(data, cb)
    if data.lookX then PhotoBoothInput.lookX = PhotoBoothInput.lookX + (tonumber(data.lookX) or 0.0) end
    if data.lookY then PhotoBoothInput.lookY = PhotoBoothInput.lookY + (tonumber(data.lookY) or 0.0) end
    if data.dragging ~= nil then PhotoBoothInput.dragging = data.dragging end
    if data.panning ~= nil then PhotoBoothInput.panning = data.panning end
    if data.zoom then PhotoBoothInput.zoom = PhotoBoothInput.zoom + (tonumber(data.zoom) or 0.0) end
    cb({})
end)

--- Orbit camera thread (mirrors modules/showroom/client.lua, with Shift+drag to pan)
local function StartPhotoBoothCamThread()
    if PhotoBoothCamThread then return end
    PhotoBoothCamThread = true

    PhotoBoothInput = { lookX = 0.0, lookY = 0.0, dragging = false, zoom = 0.0, panning = false }

    CreateThread(function()
        local orbitSensitivity = 0.005
        local panSpeed = 0.015
        local zoomSpeed = 0.5
        local minRadius = 2.5
        local maxRadius = 15.0
        local smoothing = 0.15

        local smoothAngle = PhotoBoothState.orbitAngle
        local smoothPitch = PhotoBoothState.orbitPitch
        local smoothRadius = PhotoBoothState.orbitRadius

        while PhotoBoothState and PhotoBoothCamThread do
            local s = PhotoBoothState
            if not s or not s.cam then break end

            local inp = PhotoBoothInput

            if inp.lookX ~= 0.0 or inp.lookY ~= 0.0 then
                if inp.panning then
                    -- Shift+drag: slide the orbit target along the camera's right axis + world up/down
                    local rightX = -math.sin(s.orbitAngle)
                    local rightY = math.cos(s.orbitAngle)
                    s.targetCenter = vector3(
                        s.targetCenter.x - rightX * inp.lookX * panSpeed,
                        s.targetCenter.y - rightY * inp.lookX * panSpeed,
                        math.max(s.groundZ + 0.3, s.targetCenter.z + inp.lookY * panSpeed)
                    )
                else
                    -- Default drag: orbit
                    s.orbitAngle = s.orbitAngle - inp.lookX * orbitSensitivity
                    -- Inverted vertical: dragging down tips the camera down.
                    s.orbitPitch = math.max(-0.8, math.min(0.8, s.orbitPitch + inp.lookY * orbitSensitivity))
                end
                inp.lookX = 0.0
                inp.lookY = 0.0
            end

            if inp.zoom ~= 0.0 then
                local effectiveMax = math.max(maxRadius, (s.defaultRadius or maxRadius) * 1.3)
                s.orbitRadius = math.max(minRadius, math.min(effectiveMax, s.orbitRadius - inp.zoom * zoomSpeed))
                inp.zoom = 0.0
            end

            smoothAngle = smoothAngle + (s.orbitAngle - smoothAngle) * smoothing
            smoothPitch = smoothPitch + (s.orbitPitch - smoothPitch) * smoothing
            smoothRadius = smoothRadius + (s.orbitRadius - smoothRadius) * smoothing

            local camX = s.targetCenter.x + smoothRadius * math.cos(smoothAngle)
            local camY = s.targetCenter.y + smoothRadius * math.sin(smoothAngle)
            local camZ = s.targetCenter.z + smoothRadius * math.sin(smoothPitch) * 0.5

            local minZ = s.groundZ + 0.3
            if camZ < minZ then camZ = minZ end

            SetCamCoord(s.cam, camX, camY, camZ)
            PointCamAtCoord(s.cam, s.targetCenter.x, s.targetCenter.y, s.targetCenter.z)

            Wait(0)
        end

        PhotoBoothCamThread = nil
    end)
end

local function StopPhotoBoothCamThread()
    PhotoBoothCamThread = nil
end

local function CleanupPhotoBooth()
    if not PhotoBoothState then return end

    -- Stop camera thread
    StopPhotoBoothCamThread()

    -- Close NUI first so it's gone before fade
    CloseNui()

    -- Fade out
    DoScreenFadeOut(500)
    while not IsScreenFadedOut() do Wait(0) end

    -- Delete vehicle
    if DoesEntityExist(PhotoBoothState.vehicle) then
        DeleteEntity(PhotoBoothState.vehicle)
    end

    -- Destroy cameras
    RenderScriptCams(false, false, 0, true, true)
    if PhotoBoothState.cam then
        DestroyCam(PhotoBoothState.cam, false)
    end

    -- Restore weather/time via bridge
    RestorePhotoWeather()

    -- Restore routing bucket so the player shares world state with everyone else again
    lib.callback.await("pickle_dealerships:adminSetPhotoBucket", false, { bucket = 0 })

    -- Player never actually moved (SetFocusArea shifted streaming, not position),
    -- so there's nothing to teleport back. Just clear the focus override and
    -- unfreeze them.
    local ped = PlayerPedId()
    ClearFocus()
    FreezeEntityPosition(ped, false)

    -- Restore HUD
    DisplayRadar(true)
    DisplayHud(true)

    -- Clear weather override
    ClearWeatherTypePersist()
    ClearOverrideWeather()

    PhotoBoothState = nil

    -- Fade back in and reopen admin panel
    DoScreenFadeIn(500)
    while not IsScreenFadedIn() do Wait(0) end

    OpenNui('admin', {
        dealershipId = 0,
        dealershipName = 'Dealership Panel',
        role = 'admin',
        tier = 4,
        initialTab = 'catalog',
    })
end

RegisterNUICallback("adminStartPhotoCapture", function(data, cb)
    CloseNui()

    -- Fetch upload config from server before proceeding
    local uploadConfig = lib.callback.await("pickle_dealerships:adminGetUploadConfig", false)
    if not uploadConfig then
        ShowNotification(_L("admin_upload_not_configured"))
        cb({ success = false })
        return
    end

    cb({ success = true })

    local ped = PlayerPedId()

    -- Pick the right photo booth location based on vehicle class
    local vehicleClass = data.class or ''
    local location = nil
    local fallback = nil
    for _, loc in ipairs(Config.PhotoBooth.locations) do
        if not loc.classes or #loc.classes == 0 then
            fallback = loc
        else
            for _, cls in ipairs(loc.classes) do
                if cls == vehicleClass then
                    location = loc
                    break
                end
            end
        end
        if location then break end
    end
    location = location or fallback or Config.PhotoBooth.locations[1]
    local boothCoords = location.coords

    -- Fade out
    DoScreenFadeOut(500)
    while not IsScreenFadedOut() do Wait(0) end

    -- Move to isolated routing bucket so other clients don't see our spawned
    -- booth vehicle (and vice versa).
    lib.callback.await("pickle_dealerships:adminSetPhotoBucket", false, { bucket = Config.PhotoBooth.routingBucket })

    -- Player stays where they are; we shift the streaming focus to the booth
    -- coords so the game loads that area around the camera instead of around
    -- the player. This keeps the player off-screen during captures without
    -- having to hide or teleport them (per the "never hide the player" rule).
    FreezeEntityPosition(ped, true)
    SetFocusArea(boothCoords.x, boothCoords.y, boothCoords.z, 0.0, 0.0, 0.0)

    -- Request collision and wait for the booth area to stream in
    RequestCollisionAtCoord(boothCoords.x, boothCoords.y, boothCoords.z)
    NewLoadSceneStart(boothCoords.x, boothCoords.y, boothCoords.z, boothCoords.x, boothCoords.y, boothCoords.z, 50.0, 0)
    local loadTimeout = GetGameTimer() + 10000
    while not IsNewLoadSceneLoaded() and GetGameTimer() < loadTimeout do Wait(0) end
    NewLoadSceneStop()

    -- Load the vehicle model while the scene loads
    local modelHash = joaat(data.model)
    RequestModel(modelHash)
    while not HasModelLoaded(modelHash) do Wait(0) end

    -- Spawn vehicle now that collision is ready
    local vehHeading = boothCoords.w or 0.0
    local veh = CreateVehicle(modelHash, boothCoords.x, boothCoords.y, boothCoords.z, vehHeading, false, false)
    SetEntityHeading(veh, vehHeading)
    FreezeEntityPosition(veh, true)
    SetVehicleOnGroundProperly(veh)
    SetModelAsNoLongerNeeded(modelHash)

    -- Set consistent daytime weather via bridge (handles qb-weathersync, Renewed-Weathersync, cd_easytime, standalone)
    LockPhotoWeather()

    -- Hide HUD
    DisplayRadar(false)
    DisplayHud(false)

    -- Scale camera start position based on vehicle dimensions
    local dimMin, dimMax = GetModelDimensions(modelHash)
    local vehHeight = dimMax.z - dimMin.z
    local vehSize = math.max(dimMax.y - dimMin.y, dimMax.x - dimMin.x, vehHeight)
    local sizeScale = math.max(0.8, vehSize / 5.0)

    local camRadius = (location.camRadius or 6.0) * sizeScale

    -- Get actual vehicle position after ground placement, then find its vertical center
    local vehPos = GetEntityCoords(veh)
    local vehCenterZ = vehPos.z + (dimMin.z + dimMax.z) * 0.5
    local targetCenter = vector3(vehPos.x, vehPos.y, vehCenterZ)

    -- 45° orbit offset relative to the booth heading, matching the showroom
    -- cam convention so every camera view opens at the same relative angle
    -- regardless of how the booth or showroom is rotated in-world.
    local initAngle = math.rad(45 + (vehHeading or 0.0))
    local initPitch = 0.8 -- start camera at max top pitch so it opens looking down at the car
    local camX = targetCenter.x + camRadius * math.cos(initAngle)
    local camY = targetCenter.y + camRadius * math.sin(initAngle)
    local camZ = targetCenter.z + camRadius * math.sin(initPitch) * 0.5
    local cam = CreateCam("DEFAULT_SCRIPTED_CAMERA", true)
    SetCamCoord(cam, camX, camY, camZ)
    PointCamAtCoord(cam, targetCenter.x, targetCenter.y, targetCenter.z)
    SetCamActive(cam, true)
    RenderScriptCams(true, false, 0, true, true)

    -- Store state (includes orbit params used by the cam thread)
    PhotoBoothState = {
        vehicle = veh,
        cam = cam,
        center = boothCoords,
        groundZ = boothCoords.z - 2.0,
        catalogId = data.catalogId,
        model = data.model,
        label = data.label or data.model,
        vehicleClass = data.class,
        uploadConfig = uploadConfig,
        targetCenter = targetCenter,
        orbitAngle = initAngle,
        orbitPitch = initPitch,
        orbitRadius = camRadius,
        defaultRadius = camRadius,
    }

    -- Start noclip camera thread
    StartPhotoBoothCamThread()

    -- Fade in and open UI
    DoScreenFadeIn(500)
    while not IsScreenFadedIn() do Wait(0) end

    local nuiData = {
        dealershipId = 0,
        dealershipName = 'Photo Booth',
        role = 'admin',
        tier = 4,
        catalogId = data.catalogId,
        model = data.model,
        label = data.label or data.model,
        vehicleClass = data.class,
        uploadConfig = uploadConfig,
    }

    OpenNui('photoBooth', nuiData)
end)

RegisterNUICallback("photoBoothCapture", function(_, cb)
    if not PhotoBoothState then cb({ success = false }) return end

    -- Hide NUI for a clean screenshot
    CloseNui()
    Wait(200)

    CaptureScreenshot(function(screenshotData)
        -- Reopen the photo booth UI so the component is mounted
        OpenNui('photoBooth', {
            dealershipId = 0,
            dealershipName = 'Photo Booth',
            role = 'admin',
            tier = 4,
            catalogId = PhotoBoothState and PhotoBoothState.catalogId,
            model = PhotoBoothState and PhotoBoothState.model,
            label = PhotoBoothState and PhotoBoothState.label,
            vehicleClass = PhotoBoothState and PhotoBoothState.vehicleClass,
            uploadConfig = PhotoBoothState and PhotoBoothState.uploadConfig,
        })

        Wait(100)
        SendNUIMessage({ type = 'photoBoothCaptured', imageData = screenshotData })
    end)

    cb({ success = true })
end)

RegisterNUICallback("photoBoothSave", function(data, cb)
    if not PhotoBoothState then cb({ success = false }) return end

    if not data.imageData or data.imageData == "" then
        ShowNotification(_L("admin_no_image"))
        cb({ success = false })
        CleanupPhotoBooth()
        return
    end

    local result = lib.callback.await("pickle_dealerships:adminSaveCatalogImage", false, {
        catalogId = PhotoBoothState.catalogId,
        imageUrl = data.imageData,
    })

    if result and result.success then
        ShowNotification(result.message)
    else
        ShowNotification(result and result.message or _L("admin_image_failed"))
    end

    cb(result or { success = false })
    CleanupPhotoBooth()
end)

RegisterNUICallback("photoBoothCancel", function(_, cb)
    CleanupPhotoBooth()
    cb({ success = true })
end)
