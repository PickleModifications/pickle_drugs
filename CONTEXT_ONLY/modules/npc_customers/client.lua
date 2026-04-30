local activeNPCs = {}
local npcSpawnTimer = 0
local currentNPCInteraction = nil
local isOnDuty = false
local currentDealershipId = nil
local currentLocationKey = nil
local currentDealershipName = nil
-- Kept as a module-local so the spawn loop and refresh event read the same
-- (mutable) reference. Updating this swaps in freshly-added NPC spawn points
-- without tearing down the running session.
local currentDealershipConfig = nil
local npcCam = nil

-- NPC Showroom state
local NPCShowroomState = nil
local NPCShowroomInput = { lookX = 0.0, lookY = 0.0, dragging = false, zoom = 0.0 }
local NPCShowroomCamThread = nil

--- Create a camera focused on the NPC for greeting
local function StartNPCCamera(npcPed)
    if npcCam then DestroyCam(npcCam, false) end

    local playerPed = PlayerPedId()
    local npcCoords = GetEntityCoords(npcPed)
    local playerCoords = GetEntityCoords(playerPed)

    local midX = (npcCoords.x + playerCoords.x) / 2
    local midY = (npcCoords.y + playerCoords.y) / 2
    local dx = npcCoords.x - playerCoords.x
    local dy = npcCoords.y - playerCoords.y
    local dist = math.sqrt(dx * dx + dy * dy)
    local perpX = -dy / dist * 0.8
    local perpY = dx / dist * 0.8

    npcCam = CreateCam("DEFAULT_SCRIPTED_CAMERA", true)
    SetCamCoord(npcCam, midX + perpX, midY + perpY, npcCoords.z + 0.5)
    PointCamAtCoord(npcCam, npcCoords.x, npcCoords.y, npcCoords.z + 0.3)
    SetCamActive(npcCam, true)
    RenderScriptCams(true, true, 800, true, true)
end

local function StopNPCCamera()
    if npcCam then
        RenderScriptCams(false, true, 800, true, true)
        DestroyCam(npcCam, false)
        npcCam = nil
    end
end

--- Start orbit camera thread for NPC showroom
local function StartNPCShowroomCamThread()
    if NPCShowroomCamThread then return end
    NPCShowroomCamThread = true
    NPCShowroomInput = { lookX = 0.0, lookY = 0.0, dragging = false, zoom = 0.0 }

    CreateThread(function()
        local orbitSensitivity = 0.005
        local zoomSpeed = 0.5
        local minRadius = 2.5
        local maxRadius = 15.0
        local smoothing = 0.15

        local smoothAngle = NPCShowroomState and NPCShowroomState.orbitAngle or 0
        local smoothPitch = NPCShowroomState and NPCShowroomState.orbitPitch or 0
        local smoothRadius = NPCShowroomState and NPCShowroomState.orbitRadius or 6

        while NPCShowroomState and NPCShowroomCamThread do
            local s = NPCShowroomState
            if not s or not s.cam then break end

            local inp = NPCShowroomInput
            if inp.lookX ~= 0.0 or inp.lookY ~= 0.0 then
                s.orbitAngle = s.orbitAngle - inp.lookX * orbitSensitivity
                -- Inverted vertical: dragging down tips the camera down.
                s.orbitPitch = math.max(-0.8, math.min(0.8, s.orbitPitch + inp.lookY * orbitSensitivity))
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
            local minZ = s.spawnCoords.z + 0.3
            if camZ < minZ then camZ = minZ end

            SetCamCoord(s.cam, camX, camY, camZ)
            PointCamAtCoord(s.cam, s.targetCenter.x, s.targetCenter.y, s.targetCenter.z)
            Wait(0)
        end
        NPCShowroomCamThread = nil
    end)
end

--- Stand the NPC next to the selected vehicle's driver door, facing the
--- showroom heading. For vehicles that don't expose a driver door bone
--- (boats, planes, some props-on-wheels), fall back to offsetting from the
--- vehicle origin by half of the largest horizontal model dimension so the
--- NPC ends up next to the hull instead of inside it.
---
--- Only the X/Y of the door anchor is used; Z always comes from the showroom
--- ground plane so the ped doesn't end up floating at door-handle height on
--- tall vehicles. An extra 1.0m of outward clearance keeps them from clipping
--- into the vehicle body.
local NPC_DOOR_CLEARANCE = 1.0

local function PositionNpcByVehicle(npcPed, vehicle, groundZ, faceHeading)
    if not npcPed or not DoesEntityExist(npcPed) then return end
    if not vehicle or not DoesEntityExist(vehicle) then return end

    -- Vehicle center (for pushing outward from the hull by a consistent 1m
    -- regardless of whether we resolved a bone or fell back to the model box).
    local vehCoords = GetEntityCoords(vehicle)

    local anchorX, anchorY
    local boneIndex = GetEntityBoneIndexByName(vehicle, 'door_dside_f')
    if boneIndex and boneIndex ~= -1 then
        local bonePos = GetWorldPositionOfEntityBone(vehicle, boneIndex)
        anchorX, anchorY = bonePos.x, bonePos.y
    else
        local dimMin, dimMax = GetModelDimensions(GetEntityModel(vehicle))
        local halfX = (dimMax.x - dimMin.x) * 0.5
        local halfY = (dimMax.y - dimMin.y) * 0.5
        local largest = math.max(halfX, halfY)
        -- Offset to the vehicle's driver side in its own local frame so the
        -- result rotates with the vehicle's heading.
        local fallback = GetOffsetFromEntityInWorldCoords(vehicle, -largest, 0.0, 0.0)
        anchorX, anchorY = fallback.x, fallback.y
    end

    -- Push the anchor outward from the vehicle center by NPC_DOOR_CLEARANCE
    -- along the ground plane so the ped stands ~1m clear of the body/door.
    local dx = anchorX - vehCoords.x
    local dy = anchorY - vehCoords.y
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist > 0.0001 then
        local nx = dx / dist
        local ny = dy / dist
        anchorX = anchorX + nx * NPC_DOOR_CLEARANCE
        anchorY = anchorY + ny * NPC_DOOR_CLEARANCE
    end

    -- Also pull them back 1m in the vehicle's local -Y so they stand alongside
    -- the door rather than level with the hood — the driver-door bone sits
    -- forward of the vehicle center, and the outward push above carries some
    -- of that forward bias into the final position.
    local back = GetOffsetFromEntityInWorldCoords(vehicle, 0.0, -NPC_DOOR_CLEARANCE, 0.0)
    anchorX = anchorX + (back.x - vehCoords.x)
    anchorY = anchorY + (back.y - vehCoords.y)

    FreezeEntityPosition(npcPed, false)
    SetEntityCoords(npcPed, anchorX, anchorY, groundZ or vehCoords.z, false, false, false, false)
    SetEntityHeading(npcPed, faceHeading or 0.0)
    FreezeEntityPosition(npcPed, true)
end

--- Clean up the NPC showroom state
local function CleanupNPCShowroom(skipFadeIn)
    if not NPCShowroomState then return end

    NPCShowroomCamThread = nil
    CloseNui()

    DoScreenFadeOut(500)
    while not IsScreenFadedOut() do Wait(0) end

    -- Delete display vehicle
    if NPCShowroomState.vehicle and DoesEntityExist(NPCShowroomState.vehicle) then
        DeleteEntity(NPCShowroomState.vehicle)
    end

    -- Destroy camera
    RenderScriptCams(false, false, 0, true, true)
    if NPCShowroomState.cam then
        DestroyCam(NPCShowroomState.cam, false)
    end
    -- Release the streaming focus pinned on the showroom at open time.
    ClearFocus()

    -- Restore player
    local ped = PlayerPedId()
    SetEntityCoords(ped, NPCShowroomState.savedPlayerCoords.x, NPCShowroomState.savedPlayerCoords.y, NPCShowroomState.savedPlayerCoords.z, false, false, false, false)
    SetEntityHeading(ped, NPCShowroomState.savedPlayerHeading)
    FreezeEntityPosition(ped, false)
    SetEntityVisible(ped, true, false)

    -- Restore NPC position and start them walking away so they're moving when screen fades in
    local npcPed = NPCShowroomState.npcEntity
    if npcPed and DoesEntityExist(npcPed) then
        FreezeEntityPosition(npcPed, false)
        SetBlockingOfNonTemporaryEvents(npcPed, false)
        SetEntityCoords(npcPed, NPCShowroomState.savedNPCCoords.x, NPCShowroomState.savedNPCCoords.y, NPCShowroomState.savedNPCCoords.z, false, false, false, false)
        ClearPedTasks(npcPed)
        TaskWanderStandard(npcPed, 10.0, 10)
    end

    DisplayRadar(true)
    DisplayHud(true)

    NPCShowroomState = nil

    if not skipFadeIn then
        DoScreenFadeIn(500)
        while not IsScreenFadedIn() do Wait(0) end
    end
end

--- Clean up a single NPC
local function CleanupNPC(npcData)
    if npcData.interaction then
        DeleteInteraction(npcData.interaction)
    end
    if npcData.entity and DoesEntityExist(npcData.entity) then
        DeleteEntity(npcData.entity)
    end
end

--- Clean up all active NPCs
function CleanupAllNPCs()
    for i = #activeNPCs, 1, -1 do
        CleanupNPC(activeNPCs[i])
        table.remove(activeNPCs, i)
    end
    StopNPCCamera()
    if NPCShowroomState then CleanupNPCShowroom() end
    DisplayRadar(true)
    DisplayHud(true)
    currentNPCInteraction = nil
end

--- Dismiss the current NPC interaction target
local function DismissNPC(npcData)
    if not npcData or not npcData.entity or not DoesEntityExist(npcData.entity) then return end

    local ped = npcData.entity
    ClearPedTasks(ped)
    TaskWanderStandard(ped, 10.0, 10)

    if npcData.interaction then
        DeleteInteraction(npcData.interaction)
        npcData.interaction = nil
    end

    SetTimeout(10000, function()
        if DoesEntityExist(ped) then DeleteEntity(ped) end
        for i = #activeNPCs, 1, -1 do
            if activeNPCs[i].entity == ped then
                table.remove(activeNPCs, i)
                break
            end
        end
    end)
end

local function FindNPCByEntity(entity)
    for _, npc in ipairs(activeNPCs) do
        if npc.entity == entity then return npc end
    end
    return nil
end

--- Spawn an NPC customer at the dealership. Reads the spawn-point list off
--- `currentDealershipConfig` (module-local) so that newly added points picked
--- up mid-session take effect without the spawn loop having to be restarted.
local function SpawnNPCCustomer(dealershipId)
    local dealershipConfig = currentDealershipConfig
    if not dealershipConfig then return end
    local profile = lib.callback.await("pickle_dealerships:generateNPCCustomer", false, dealershipId)
    if not profile then return end

    local spawnPoints = dealershipConfig.npcSpawnPoints
    if not spawnPoints or #spawnPoints == 0 then return end

    -- Find spawn points not already occupied by an active NPC
    -- Check both by tracked index AND by proximity (in case of edge cases)
    local occupiedPoints = {}
    for _, npc in ipairs(activeNPCs) do
        if npc.spawnPointIndex then
            occupiedPoints[npc.spawnPointIndex] = true
        end
        -- Also block by proximity to any living NPC
        if npc.entity and DoesEntityExist(npc.entity) then
            local npcCoords = GetEntityCoords(npc.entity)
            for i = 1, #spawnPoints do
                local sp = spawnPoints[i]
                if #(npcCoords - vector3(sp.x, sp.y, sp.z)) < 5.0 then
                    occupiedPoints[i] = true
                end
            end
        end
    end

    local availableIndices = {}
    for i = 1, #spawnPoints do
        if not occupiedPoints[i] then
            availableIndices[#availableIndices + 1] = i
        end
    end

    if #availableIndices == 0 then return end -- all spawn points occupied

    local chosenIndex = availableIndices[math.random(#availableIndices)]
    local spawnPoint = spawnPoints[chosenIndex]

    local model = profile.pedModel
    if not IsModelInCdimage(GetHashKey(model)) then
        model = "a_m_y_business_01"
    end

    -- Offset the actual spawn 2.0m behind the configured point (along the reverse
    -- of the point's heading) so the NPC materialises off to the side and then
    -- walks IN to the intended stand spot. Spawning exactly on the target point
    -- makes the ped shuffle/rotate to avoid clipping and looks like the classic
    -- "walk around in circles" bug.
    local headingDeg = spawnPoint.w or 0.0
    local headingRad = math.rad(headingDeg)
    local fwdX = -math.sin(headingRad)
    local fwdY =  math.cos(headingRad)
    local SPAWN_OFFSET = 2.0
    local spawnX = spawnPoint.x - fwdX * SPAWN_OFFSET
    local spawnY = spawnPoint.y - fwdY * SPAWN_OFFSET
    local spawnZ = spawnPoint.z

    local ped = CreateNPC(model, spawnX, spawnY, spawnZ, headingDeg)
    if not ped then return end

    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedFleeAttributes(ped, 0, false)
    SetPedCombatAttributes(ped, 46, true)
    FreezeEntityPosition(ped, false)

    -- Walk the NPC to the configured stand point first (the "destination" for
    -- this spawn). If the dealership also defines a wider waiting area we use
    -- that; otherwise we use the stand point itself.
    local waitingAreas = dealershipConfig.npcWaitingArea
    local dest = waitingAreas and #waitingAreas > 0
        and waitingAreas[math.random(#waitingAreas)]
        or spawnPoint
    TaskGoStraightToCoord(ped, dest.x, dest.y, dest.z, 1.0, -1, headingDeg, 0.5)

    local pedCoords = GetEntityCoords(ped)
    local interactionId = CreateInteraction({
        label = _L("interact_assist_customer"),
        icon = Config.TargetIcons.npc_customer,
        coords = vector3(pedCoords.x, pedCoords.y, pedCoords.z),
        distance = 2.5,
        targetPed = ped,
    }, function()
        if currentNPCInteraction then
            ShowNotification(_L("npc_already_assisting"))
            return
        end

        local npcData = FindNPCByEntity(ped)
        if not npcData then return end

        currentNPCInteraction = {
            npcEntity    = ped,
            profile      = npcData.profile,
            dealershipId = dealershipId,
            npcData      = npcData,
        }

        ClearPedTasks(ped)
        TaskTurnPedToFaceEntity(ped, PlayerPedId(), 2000)
        npcData.assisted = true

        Wait(500)
        StartNPCCamera(ped)
        DisplayRadar(false)
        DisplayHud(false)

        local typePref = npcData.profile.typePreference or "default"
        local greetingPool = Config.NPCCustomers.greetings and (Config.NPCCustomers.greetings[typePref] or Config.NPCCustomers.greetings["default"])
        local greeting = greetingPool and greetingPool[math.random(#greetingPool)] or "Hi, I'm looking for a vehicle."
        currentNPCInteraction.greeting = greeting

        SendNUIMessage({
            type = "openNPCNegotiation",
            profile = npcData.profile,
            greeting = greeting,
            accentColor = Config.UI and Config.UI.accentColor or "#e11d48",
        })
        SetNuiFocus(true, true)
    end)

    local npcData = {
        entity          = ped,
        profile         = profile,
        interaction     = interactionId,
        spawnTime       = GetGameTimer(),
        assisted        = false,
        dealershipId    = dealershipId,
        spawnPointIndex = chosenIndex,
    }
    table.insert(activeNPCs, npcData)

    CreateThread(function()
        local waitTime = profile.patienceTime * 1000
        local startTime = GetGameTimer()
        while DoesEntityExist(ped) and not npcData.assisted do
            Wait(1000)
            if GetGameTimer() - startTime >= waitTime then
                DismissNPC(npcData)
                return
            end
        end
    end)
end

--- NPC spawning thread
local function StartNPCSpawnLoop(dealershipId)
    CreateThread(function()
        while isOnDuty and currentDealershipId == dealershipId do
            local spawnInterval = Config.NPCCustomers.spawnInterval or {}
            local minInterval = (spawnInterval.min or 60) * 1000
            local maxInterval = (spawnInterval.max or 180) * 1000
            Wait(math.random(minInterval, maxInterval))

            if not isOnDuty or currentDealershipId ~= dealershipId then break end

            local maxConcurrent = Config.NPCCustomers.maxConcurrent or 3
            if #activeNPCs < maxConcurrent then
                SpawnNPCCustomer(dealershipId)
            end
        end
    end)
end

RegisterNetEvent("pickle_dealerships:npc:startDuty", function(dealershipId, dealershipConfig)
    -- Already on duty at the same dealership? Treat this as a config refresh
    -- (e.g. admin placed a new spawn point). Swap the config and try an
    -- immediate spawn if the shop currently has none — previously there may
    -- have been no valid spawn point so nothing could land.
    if isOnDuty and currentDealershipId == dealershipId then
        currentDealershipConfig = dealershipConfig
        currentLocationKey = dealershipConfig.location
        currentDealershipName = dealershipConfig.dealershipName or currentDealershipName
        local maxConcurrent = Config.NPCCustomers.maxConcurrent or 3
        if #activeNPCs < maxConcurrent then
            SpawnNPCCustomer(dealershipId)
        end
        return
    end

    isOnDuty = true
    currentDealershipId = dealershipId
    currentLocationKey = dealershipConfig.location
    currentDealershipName = dealershipConfig.dealershipName or 'Dealership'
    currentDealershipConfig = dealershipConfig
    StartNPCSpawnLoop(dealershipId)
end)

-- Stock arrived / display changed at this dealership. If we're on duty here
-- and there are no active NPCs, try an immediate spawn — previously the loop
-- may have skipped spawns because the shop had no eligible stock, and we
-- don't want the employee to wait a full interval to see customers show up
-- again now that inventory is available.
RegisterNetEvent('pickle_dealerships:refreshDisplay', function(locationKey)
    if not isOnDuty or not currentDealershipId then return end
    if locationKey and locationKey ~= currentLocationKey then return end
    local maxConcurrent = Config.NPCCustomers.maxConcurrent or 3
    if #activeNPCs < maxConcurrent then
        SpawnNPCCustomer(currentDealershipId)
    end
end)

RegisterNetEvent("pickle_dealerships:npc:stopDuty", function()
    isOnDuty = false
    currentDealershipId = nil
    currentLocationKey = nil
    currentDealershipName = nil
    currentDealershipConfig = nil
    CleanupAllNPCs()
end)

-- ─── NUI Callbacks ──────────────────────────────────────────────────────────

--- Transition from greeting to showroom mode
RegisterNUICallback("npcStartShowroom", function(_, cb)
    if not currentNPCInteraction then return cb({ success = false }) end

    local locationKey = currentLocationKey
    if not locationKey then return cb({ success = false, message = "No location." }) end

    local cfg = DealershipConfigs[locationKey]
    local showroomCoords = cfg and cfg.interactionPoints and cfg.interactionPoints.showroom
    local spawnCoords = showroomCoords and vector4(showroomCoords.x, showroomCoords.y, showroomCoords.z, showroomCoords.w or 0.0)
        or (cfg and cfg.spawnPoint)

    if not spawnCoords then return cb({ success = false, message = "No showroom position." }) end

    -- Close greeting NUI
    SendNUIMessage({ type = "closeNPCNegotiation" })
    SetNuiFocus(false, false)

    local npcPed = currentNPCInteraction.npcEntity
    local playerPed = PlayerPedId()

    -- Save positions
    local savedPlayerCoords = GetEntityCoords(playerPed)
    savedPlayerCoords = vector3(savedPlayerCoords.x, savedPlayerCoords.y, savedPlayerCoords.z - 1.0)
    local savedPlayerHeading = GetEntityHeading(playerPed)
    local savedNPCCoords = GetEntityCoords(npcPed)
    savedNPCCoords = vector3(savedNPCCoords.x, savedNPCCoords.y, savedNPCCoords.z - 1.0)

    -- Fade out
    DoScreenFadeOut(500)
    while not IsScreenFadedOut() do Wait(0) end

    StopNPCCamera()

    -- Freeze the player in place so the orbit cam has a stable anchor; the
    -- player model stays visible during every interaction on purpose.
    FreezeEntityPosition(playerPed, true)

    -- Pre-vehicle placement: sit the NPC at the showroom heading next to the
    -- spawn point. Once a vehicle is spawned/swapped, PositionNpcByVehicle
    -- moves them to the driver door (or model-offset fallback).
    local preVehOffset = vector3(spawnCoords.x + 2.0, spawnCoords.y + 1.0, spawnCoords.z)
    SetEntityCoords(npcPed, preVehOffset.x, preVehOffset.y, preVehOffset.z, false, false, false, false)
    FreezeEntityPosition(npcPed, true)
    SetEntityHeading(npcPed, spawnCoords.w or 0.0)

    -- Create orbit camera at showroom position (no vehicle yet)
    -- 45° orbit offset relative to the showroom heading so the camera opens
    -- at a consistent three-quarter angle regardless of how the showroom
    -- point is rotated in-world.
    local initAngle = math.rad(45 + (spawnCoords.w or 0.0))
    local defaultRadius = 6.0
    local center = vector3(spawnCoords.x, spawnCoords.y, spawnCoords.z + 0.5)
    local camX = center.x + defaultRadius * math.cos(initAngle)
    local camY = center.y + defaultRadius * math.sin(initAngle)
    -- Stream the showroom surroundings around the camera, not the player —
    -- lets the NPC showroom work when the lot is inside an interior shell
    -- and the player hasn't physically entered it. Cleared on cleanup.
    SetFocusArea(center.x, center.y, center.z, 0.0, 0.0, 0.0)
    local cam = CreateCam("DEFAULT_SCRIPTED_CAMERA", true)
    SetCamCoord(cam, camX, camY, center.z + defaultRadius * math.sin(0.8) * 0.5)
    PointCamAtCoord(cam, center.x, center.y, center.z)
    SetCamActive(cam, true)
    RenderScriptCams(true, false, 0, true, true)

    NPCShowroomState = {
        vehicle = nil,
        cam = cam,
        spawnCoords = spawnCoords,
        savedPlayerCoords = savedPlayerCoords,
        savedPlayerHeading = savedPlayerHeading,
        savedNPCCoords = savedNPCCoords,
        npcEntity = npcPed,
        currentModel = nil,
        orbitAngle = initAngle,
        orbitPitch = 0.8, -- start camera at max top pitch so it opens looking down at the car
        orbitRadius = defaultRadius,
        defaultRadius = defaultRadius,
        targetCenter = center,
        locationKey = locationKey,
    }

    StartNPCShowroomCamThread()

    -- Open NPC showroom NUI
    SendNUIMessage({
        type = "openNPCShowroom",
        profile = currentNPCInteraction.profile,
        greeting = currentNPCInteraction.greeting or "",
        dealershipId = currentNPCInteraction.dealershipId,
        location = locationKey,
        dealershipName = currentDealershipName,
        accentColor = Config.UI and Config.UI.accentColor or "#e11d48",
    })
    SetNuiFocus(true, true)

    DoScreenFadeIn(500)

    cb({ success = true })
end)

--- Swap vehicle in NPC showroom
RegisterNUICallback("npcShowroomSwapVehicle", function(data, cb)
    if not NPCShowroomState then cb({ success = false }) return end

    local model = data.model
    if model == NPCShowroomState.currentModel then return cb({ success = true }) end

    -- Load new model before deleting old
    local modelHash = type(model) == "string" and joaat(model) or model
    RequestModel(modelHash)
    local timeout = GetGameTimer() + 10000
    while not HasModelLoaded(modelHash) and GetGameTimer() < timeout do Wait(0) end
    if not HasModelLoaded(modelHash) then return cb({ success = false }) end

    -- Delete old vehicle
    if NPCShowroomState.vehicle and DoesEntityExist(NPCShowroomState.vehicle) then
        DeleteEntity(NPCShowroomState.vehicle)
    end

    -- Spawn new one using the global SpawnShowroomVehicle
    local veh, center, radius = SpawnShowroomVehicle(model, NPCShowroomState.spawnCoords)
    if not veh then return cb({ success = false }) end

    NPCShowroomState.vehicle = veh
    NPCShowroomState.currentModel = model
    NPCShowroomState.targetCenter = center
    NPCShowroomState.orbitRadius = radius
    NPCShowroomState.defaultRadius = radius

    -- Move the NPC to stand next to the newly-spawned vehicle's driver door
    -- (or offset for door-less models). Z is pinned to the showroom ground
    -- plane so the ped doesn't float at door-handle height on tall vehicles;
    -- heading faces the showroom.
    local sc = NPCShowroomState.spawnCoords
    PositionNpcByVehicle(
        NPCShowroomState.npcEntity,
        veh,
        sc and sc.z or nil,
        sc and sc.w or 0.0
    )

    cb({ success = true })
end)

--- Orbit camera input for NPC showroom
RegisterNUICallback("npcShowroomOrbitInput", function(data, cb)
    if NPCShowroomState then
        if data.lookX then NPCShowroomInput.lookX = NPCShowroomInput.lookX + (tonumber(data.lookX) or 0.0) end
        if data.lookY then NPCShowroomInput.lookY = NPCShowroomInput.lookY + (tonumber(data.lookY) or 0.0) end
        if data.dragging ~= nil then NPCShowroomInput.dragging = data.dragging end
        if data.zoom then NPCShowroomInput.zoom = NPCShowroomInput.zoom + (tonumber(data.zoom) or 0.0) end
    end
    cb({})
end)

--- Present vehicle to NPC (evaluation)
RegisterNUICallback("presentVehicle", function(data, cb)
    if not currentNPCInteraction then
        return cb({ success = false, message = "No active NPC interaction." })
    end

    local result = lib.callback.await("pickle_dealerships:evaluateVehicleMatch", false, {
        npcProfile = currentNPCInteraction.profile,
        stockItem  = data.stockItem,
    })

    if result then
        cb({ success = true, quality = result.quality, score = result.score, dialogue = result.dialogue, openingOffer = result.openingOffer })
    else
        cb({ success = false, message = "Failed to evaluate vehicle." })
    end
end)

--- Evaluate a price offer from the player
RegisterNUICallback("npcEvaluateOffer", function(data, cb)
    if not currentNPCInteraction then
        return cb({ success = false, message = "No active NPC interaction." })
    end

    local result = lib.callback.await("pickle_dealerships:evaluateOffer", false, {
        npcProfile    = currentNPCInteraction.profile,
        offerPrice    = data.offerPrice,
        currentStress = data.currentStress,
        stockId       = data.stockId,
    })

    if result then
        -- Animate NPC based on result
        local ped = NPCShowroomState and NPCShowroomState.npcEntity or currentNPCInteraction.npcEntity
        if ped and DoesEntityExist(ped) then
            if result.accepted then
                TaskPlayAnim(ped, "gestures@m@standing@casual", "gesture_you_welcome", 8.0, -8.0, 2000, 49, 0, false, false, false)
            elseif result.walkaway then
                TaskPlayAnim(ped, "gestures@m@standing@casual", "gesture_hand_down", 8.0, -8.0, 2000, 49, 0, false, false, false)
            elseif result.stress >= 70 then
                TaskPlayAnim(ped, "gestures@m@standing@casual", "gesture_shrug_hard", 8.0, -8.0, 2000, 49, 0, false, false, false)
            end
        end

        cb({
            success       = true,
            accepted      = result.accepted,
            walkaway      = result.walkaway,
            stress        = result.stress,
            stressIncrease = result.stressIncrease,
            dialogue      = result.dialogue,
        })
    else
        cb({ success = false, message = "Evaluation failed." })
    end
end)

--- Complete the NPC sale with drive-off
RegisterNUICallback("completeNPCSale", function(data, cb)
    if not currentNPCInteraction then
        return cb({ success = false, message = "No active NPC interaction." })
    end

    local result = lib.callback.await("pickle_dealerships:completeNPCSale", false, {
        dealershipId = currentNPCInteraction.dealershipId,
        stockId      = data.stockId,
        saleAmount   = data.saleAmount,
        npcProfile   = currentNPCInteraction.profile,
    })

    if result and result.success then
        ShowNotification(result.message)

        local vehicleModel = data.vehicleModel
        local npcPed = NPCShowroomState and NPCShowroomState.npcEntity or currentNPCInteraction.npcEntity
        local locationKey = NPCShowroomState and NPCShowroomState.locationKey or currentLocationKey

        -- Clean up showroom, keep screen faded
        if NPCShowroomState then
            CleanupNPCShowroom(true)
        else
            StopNPCCamera()
            DoScreenFadeOut(500)
            while not IsScreenFadedOut() do Wait(0) end
        end

        SendNUIMessage({ type = "closeNPCShowroom" })
        SetNuiFocus(false, false)

        -- Spawn a driveable vehicle at the dealership spawn point
        local cfg = DealershipConfigs[locationKey]
        local spawnPoint = cfg and cfg.spawnPoint
        local driveVeh = nil

        if spawnPoint and vehicleModel then
            local modelHash = joaat(vehicleModel)
            RequestModel(modelHash)
            while not HasModelLoaded(modelHash) do Wait(0) end
            driveVeh = CreateVeh(modelHash, spawnPoint.x, spawnPoint.y, spawnPoint.z, spawnPoint.w or 0.0, false, false)
            SetVehicleOnGroundProperly(driveVeh)
            SetModelAsNoLongerNeeded(modelHash)
        end

        -- Position NPC near vehicle and prepare for driving
        if npcPed and DoesEntityExist(npcPed) then
            FreezeEntityPosition(npcPed, false)
            SetBlockingOfNonTemporaryEvents(npcPed, false)
            ClearPedTasks(npcPed)
            if spawnPoint then
                SetEntityCoords(npcPed, spawnPoint.x + 1.5, spawnPoint.y, spawnPoint.z, false, false, false, false)
            end
        end

        DisplayRadar(true)
        DisplayHud(true)

        -- Start NPC walking/driving task BEFORE fade-in so they're already moving when screen appears
        local vehClass = driveVeh and GetVehicleClass(driveVeh) or -1
        local isAircraft = vehClass == 15 or vehClass == 16

        if driveVeh and npcPed and DoesEntityExist(npcPed) and DoesEntityExist(driveVeh) then
            if isAircraft then
                -- Aircraft: warp directly into pilot seat
                TaskWarpPedIntoVehicle(npcPed, driveVeh, -1)
                SetVehicleEngineOn(driveVeh, true, true, false)
            else
                -- Ground vehicle: start walking toward the vehicle now
                TaskEnterVehicle(npcPed, driveVeh, 5000, -1, 2.0, 1, 0)
            end
        end

        -- Fade in — NPC is already walking/in pilot seat
        DoScreenFadeIn(500)
        while not IsScreenFadedIn() do Wait(0) end

        -- Remove NPC's interaction target and mark as leaving (keeps spawn point blocked)
        if currentNPCInteraction and currentNPCInteraction.npcData then
            if currentNPCInteraction.npcData.interaction then
                DeleteInteraction(currentNPCInteraction.npcData.interaction)
                currentNPCInteraction.npcData.interaction = nil
            end
            currentNPCInteraction.npcData.leaving = true
        end

        -- Capture npcData reference and clear interaction state NOW so player can assist others
        local leavingNpcData = currentNPCInteraction and currentNPCInteraction.npcData
        currentNPCInteraction = nil
        cb({ success = true, saleAmount = result.saleAmount, commission = result.commission })

        -- Continue drive-off sequence in a separate thread (non-blocking)
        if driveVeh and npcPed and DoesEntityExist(npcPed) and DoesEntityExist(driveVeh) then
            CreateThread(function()
                if isAircraft then
                    Wait(500)
                    if not DoesEntityExist(driveVeh) or not DoesEntityExist(npcPed) then return end
                    local vehCoords = GetEntityCoords(driveVeh)
                    if vehClass == 15 then
                        TaskHeliMission(npcPed, driveVeh, 0, 0, vehCoords.x + 300.0, vehCoords.y + 300.0, vehCoords.z + 100.0, 4, 40.0, 10.0, -1.0, 0, 0, -1.0, 0)
                    else
                        local heading = GetEntityHeading(driveVeh)
                        local rad = math.rad(heading)
                        SetEntityVelocity(driveVeh, -math.sin(rad) * 50.0, math.cos(rad) * 50.0, 10.0)
                    end
                else
                    -- Poll until the NPC is actually seated, then drive off immediately.
                    -- Previously this was a fixed 6s wait — if they got in faster
                    -- they'd sit idle in the driver seat for the remainder.
                    local deadline = GetGameTimer() + 10000
                    while GetGameTimer() < deadline do
                        if not DoesEntityExist(driveVeh) or not DoesEntityExist(npcPed) then return end
                        if GetPedInVehicleSeat(driveVeh, -1) == npcPed then break end
                        Wait(100)
                    end
                    -- Small settle delay so the enter-vehicle anim finishes cleanly
                    -- before we hand the ped a drive task — otherwise you can see
                    -- them pulling away mid-close-door.
                    Wait(1000)
                    if DoesEntityExist(driveVeh) and DoesEntityExist(npcPed) then
                        SetVehicleEngineOn(driveVeh, true, true, false)
                        TaskVehicleDriveWander(npcPed, driveVeh, 20.0, 786603)
                    end
                end
            end)

            -- Cleanup after NPC leaves — removes from activeNPCs to free up spawn point
            SetTimeout(isAircraft and 20000 or 30000, function()
                if DoesEntityExist(driveVeh) then DeleteEntity(driveVeh) end
                if DoesEntityExist(npcPed) then DeleteEntity(npcPed) end
                if leavingNpcData then
                    for i = #activeNPCs, 1, -1 do
                        if activeNPCs[i] == leavingNpcData then
                            table.remove(activeNPCs, i)
                            break
                        end
                    end
                end
            end)
        end
    else
        cb({ success = false, message = result and result.message or "Sale failed." })
    end
end)

--- Dismiss the NPC and close interaction
RegisterNUICallback("dismissNPC", function(_, cb)
    -- Clean up NPC showroom if active
    if NPCShowroomState then
        CleanupNPCShowroom()
    else
        StopNPCCamera()
    end

    SendNUIMessage({ type = "closeNPCNegotiation" })
    SendNUIMessage({ type = "closeNPCShowroom" })
    SetNuiFocus(false, false)
    DisplayRadar(true)
    DisplayHud(true)

    if currentNPCInteraction then
        DismissNPC(currentNPCInteraction.npcData)
        currentNPCInteraction = nil
    end

    cb({ success = true })
end)

--- Cleanup on resource stop
AddEventHandler("onResourceStop", function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    CleanupAllNPCs()
    if NPCShowroomState then
        if NPCShowroomState.vehicle and DoesEntityExist(NPCShowroomState.vehicle) then
            DeleteEntity(NPCShowroomState.vehicle)
        end
        if NPCShowroomState.cam then
            RenderScriptCams(false, false, 0, true, true)
            DestroyCam(NPCShowroomState.cam, false)
        end
        NPCShowroomState = nil
    end
end)
