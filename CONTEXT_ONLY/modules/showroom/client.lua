local ShowroomState = nil
local ShowroomInput = { lookX = 0.0, lookY = 0.0, dragging = false, zoom = 0.0 }
local ShowroomCamThread = nil

--- Spawn a frozen display vehicle at the showroom position
---@param model string
---@param coords vector4
---@return number|nil entity
---@return vector3|nil center
---@return number|nil radius
function SpawnShowroomVehicle(model, coords, properties)
    local modelHash = type(model) == "string" and joaat(model) or model
    RequestModel(modelHash)
    local timeout = GetGameTimer() + 10000
    while not HasModelLoaded(modelHash) and GetGameTimer() < timeout do Wait(0) end
    if not HasModelLoaded(modelHash) then return nil end

    local veh = CreateVeh(modelHash, vector3(coords.x, coords.y, coords.z), coords.w or 0.0, false)
    if not veh or not DoesEntityExist(veh) then return nil end

    FreezeEntityPosition(veh, true)
    SetEntityInvincible(veh, true)
    SetVehicleDoorsLocked(veh, 2)
    SetVehicleOnGroundProperly(veh)
    SetModelAsNoLongerNeeded(modelHash)

    -- Pre-owned units: apply captured properties so the showroom shows the actual unit
    if properties then
        if type(properties) == "string" then properties = json.decode(properties) end
        if type(properties) == "table" then
            properties.plate = nil
            local ok, err = pcall(lib.setVehicleProperties, veh, properties)
            debugPrint(('[pickle_dealerships] Showroom applied props ok=%s err=%s keys=%d'):format(tostring(ok), tostring(err), (function() local n=0 for _ in pairs(properties) do n=n+1 end return n end)()))
        end
    end

    -- Calculate camera orbit parameters from vehicle dimensions
    local dimMin, dimMax = GetModelDimensions(modelHash)
    local vehPos = GetEntityCoords(veh)
    local vehHeight = dimMax.z - dimMin.z
    local vehSize = math.max(dimMax.y - dimMin.y, dimMax.x - dimMin.x, vehHeight)
    local centerZ = vehPos.z + (dimMin.z + dimMax.z) * 0.5
    local center = vector3(vehPos.x, vehPos.y, centerZ)
    local radius = math.max(4.0, vehSize * 1.2)

    return veh, center, radius
end

--- Swap the currently displayed showroom vehicle
---@param model string
---@param properties table|nil
local function SwapShowroomVehicle(model, properties)
    if not ShowroomState then return false end

    -- Load new model before deleting old one for a clean swap
    local modelHash = type(model) == "string" and joaat(model) or model
    RequestModel(modelHash)
    local timeout = GetGameTimer() + 10000
    while not HasModelLoaded(modelHash) and GetGameTimer() < timeout do Wait(0) end
    if not HasModelLoaded(modelHash) then return false end

    -- Delete old vehicle
    if ShowroomState.vehicle and DoesEntityExist(ShowroomState.vehicle) then
        DeleteEntity(ShowroomState.vehicle)
    end

    -- Spawn new one
    local veh, center, radius = SpawnShowroomVehicle(model, ShowroomState.spawnCoords, properties)
    if not veh then return false end

    ShowroomState.vehicle = veh
    ShowroomState.currentModel = model
    ShowroomState.targetCenter = center
    ShowroomState.orbitRadius = radius
    ShowroomState.defaultRadius = radius

    -- Update camera to look at new vehicle
    local s = ShowroomState
    local camX = s.targetCenter.x + s.orbitRadius * math.cos(s.orbitAngle)
    local camY = s.targetCenter.y + s.orbitRadius * math.sin(s.orbitAngle)
    local camZ = s.targetCenter.z + s.orbitRadius * math.sin(s.orbitPitch) * 0.5
    SetCamCoord(s.cam, camX, camY, camZ)
    PointCamAtCoord(s.cam, s.targetCenter.x, s.targetCenter.y, s.targetCenter.z)

    return true
end

--- Start the orbit camera thread
local function StartShowroomCamThread()
    if ShowroomCamThread then return end
    ShowroomCamThread = true

    ShowroomInput = { lookX = 0.0, lookY = 0.0, dragging = false, zoom = 0.0 }

    CreateThread(function()
        local orbitSensitivity = 0.005
        local zoomSpeed = 0.5
        local minRadius = 2.5
        local maxRadius = 15.0
        local smoothing = 0.15 -- lower = smoother but laggier

        -- Smoothed values that lerp toward the target
        local smoothAngle = ShowroomState.orbitAngle
        local smoothPitch = ShowroomState.orbitPitch
        local smoothRadius = ShowroomState.orbitRadius

        while ShowroomState and ShowroomCamThread do
            local s = ShowroomState
            if not s or not s.cam then break end

            local inp = ShowroomInput

            -- Accumulate raw input into target values
            if inp.lookX ~= 0.0 or inp.lookY ~= 0.0 then
                s.orbitAngle = s.orbitAngle - inp.lookX * orbitSensitivity
                -- Inverted vertical: dragging down tips the camera down.
                s.orbitPitch = math.max(-0.8, math.min(0.8, s.orbitPitch + inp.lookY * orbitSensitivity))
                inp.lookX = 0.0
                inp.lookY = 0.0
            end

            if inp.zoom ~= 0.0 then
                -- Use the vehicle's default radius + margin as max so we can always zoom back out fully
                local effectiveMax = math.max(maxRadius, (s.defaultRadius or maxRadius) * 1.3)
                s.orbitRadius = math.max(minRadius, math.min(effectiveMax, s.orbitRadius - inp.zoom * zoomSpeed))
                inp.zoom = 0.0
            end

            -- Lerp smoothed values toward targets
            smoothAngle = smoothAngle + (s.orbitAngle - smoothAngle) * smoothing
            smoothPitch = smoothPitch + (s.orbitPitch - smoothPitch) * smoothing
            smoothRadius = smoothRadius + (s.orbitRadius - smoothRadius) * smoothing

            -- Update camera position every frame
            local camX = s.targetCenter.x + smoothRadius * math.cos(smoothAngle)
            local camY = s.targetCenter.y + smoothRadius * math.sin(smoothAngle)
            local camZ = s.targetCenter.z + smoothRadius * math.sin(smoothPitch) * 0.5

            -- Clamp camera Z to showroom floor level (spawn coords Z + small offset)
            local minZ = s.spawnCoords.z + 0.3
            if camZ < minZ then camZ = minZ end

            SetCamCoord(s.cam, camX, camY, camZ)
            PointCamAtCoord(s.cam, s.targetCenter.x, s.targetCenter.y, s.targetCenter.z)

            Wait(0)
        end

        ShowroomCamThread = nil
    end)
end

--- Clean up the showroom and restore player state
--- If skipFadeIn is true, the screen stays faded out (caller handles fade-in)
function CleanupShowroom(skipFadeIn)
    if not ShowroomState then return end

    local locationKey = ShowroomState.locationKey
    local affectedSpot = ShowroomState.pickerSpotId or ShowroomState.spotViewSpotId
    local lightweight = ShowroomState.lightweight == true

    ShowroomCamThread = nil
    CloseNui()

    if lightweight then
        -- Spot-view / non-destructive mode: we never hid the ped, never
        -- spawned a preview vehicle, and never deleted the physical display
        -- car. Fade through for a smooth camera handoff but skip the ped
        -- restore and refresh (the display car was never touched).
        DoScreenFadeOut(500)
        while not IsScreenFadedOut() do Wait(0) end

        RenderScriptCams(false, false, 0, true, true)
        if ShowroomState.cam then
            DestroyCam(ShowroomState.cam, false)
        end
        ClearFocus()
        ShowroomState = nil

        if not skipFadeIn then
            DoScreenFadeIn(500)
            while not IsScreenFadedIn() do Wait(0) end
        end
        return
    end

    DoScreenFadeOut(500)
    while not IsScreenFadedOut() do Wait(0) end

    if ShowroomState.vehicle and DoesEntityExist(ShowroomState.vehicle) then
        DeleteEntity(ShowroomState.vehicle)
    end

    RenderScriptCams(false, false, 0, true, true)
    if ShowroomState.cam then
        DestroyCam(ShowroomState.cam, false)
    end
    -- Hand streaming back to the player. StartShowroom shifted focus to the
    -- showroom position so interiors would load around the camera even if
    -- the player isn't physically near the lot.
    ClearFocus()

    -- Restore player
    local ped = PlayerPedId()
    -- Place the ped 1u below the saved Z so physics pushes them up onto the
    -- actual ground as collision streams in, instead of spawning slightly in
    -- the air and visibly dropping on fade-in.
    SetEntityCoords(ped, ShowroomState.savedCoords.x, ShowroomState.savedCoords.y, ShowroomState.savedCoords.z - 1.0, false, false, false, false)
    SetEntityHeading(ped, ShowroomState.savedHeading)
    FreezeEntityPosition(ped, false)
    SetEntityVisible(ped, true, false)

    DisplayRadar(true)
    DisplayHud(true)

    ShowroomState = nil

    if not skipFadeIn then
        DoScreenFadeIn(500)
        while not IsScreenFadedIn() do Wait(0) end
    end

    -- Picker: targeted refresh of the affected spot. Regular full-showroom
    -- exit: full refresh in case a purchase changed stock.
    if affectedSpot then
        TriggerEvent('pickle_dealerships:refreshDisplay', locationKey, { affectedSpot })
    else
        TriggerEvent('pickle_dealerships:refreshDisplay', locationKey)
    end
end

--- Main entry point: opens the immersive showroom
---@param locationKey string
---@param dealershipData table
function StartShowroom(locationKey, dealershipData)
    if ShowroomState then return end

    local cfg = DealershipConfigs[locationKey]
    if not cfg or not cfg.interactionPoints or not cfg.interactionPoints.showroom then
        ShowNotification(_L("something_went_wrong"))
        return
    end

    local showroomCoords = cfg.interactionPoints.showroom
    local spawnCoords = vector4(showroomCoords.x, showroomCoords.y, showroomCoords.z, showroomCoords.w or 0.0)

    local ped = PlayerPedId()
    local savedCoords = GetEntityCoords(ped)
    local savedHeading = GetEntityHeading(ped)

    -- Fade out
    DoScreenFadeOut(500)
    while not IsScreenFadedOut() do Wait(0) end

    -- Freeze the player in place (kept visible — the player stays on-screen
    -- during every interaction).
    FreezeEntityPosition(ped, true)
    DisplayRadar(false)
    DisplayHud(false)

    -- Create orbit camera pointing at showroom position (no vehicle yet)
    -- 45° orbit offset relative to the showroom heading so the camera opens
    -- at a consistent three-quarter angle regardless of how the showroom
    -- point is rotated in-world.
    local initAngle = math.rad(45 + (spawnCoords.w or 0.0))
    local defaultRadius = 6.0
    local center = vector3(spawnCoords.x, spawnCoords.y, spawnCoords.z + 0.5)
    local camX = center.x + defaultRadius * math.cos(initAngle)
    local camY = center.y + defaultRadius * math.sin(initAngle)
    -- camZ matches the orbit thread's formula (center.z + radius * sin(pitch) * 0.5) so
    -- the camera opens at the configured max-top pitch without a visible snap.
    local camZ = center.z + defaultRadius * math.sin(0.8) * 0.5
    -- Shift the streaming focus to the showroom centre so interiors and
    -- scenery around it load even when the player's physical ped is far
    -- away (e.g. dealership tucked inside a shell). Mirrors the admin
    -- photo-booth flow; cleared on CleanupShowroom.
    SetFocusArea(center.x, center.y, center.z, 0.0, 0.0, 0.0)
    local cam = CreateCam("DEFAULT_SCRIPTED_CAMERA", true)
    SetCamCoord(cam, camX, camY, camZ)
    PointCamAtCoord(cam, center.x, center.y, center.z)
    SetCamActive(cam, true)
    RenderScriptCams(true, false, 0, true, true)

    ShowroomState = {
        vehicle = nil,
        cam = cam,
        locationKey = locationKey,
        spawnCoords = spawnCoords,
        savedCoords = savedCoords,
        savedHeading = savedHeading,
        currentModel = nil,
        orbitAngle = initAngle,
        orbitPitch = 0.8, -- start camera at max top pitch so it opens looking down at the car
        orbitRadius = defaultRadius,
        targetCenter = center,
    }

    StartShowroomCamThread()

    -- Open NUI before fade so it's ready when screen appears
    OpenNui('showroom', {
        dealershipId = dealershipData.id,
        dealershipName = dealershipData.name,
        role = 'customer',
        tier = dealershipData.tier,
        location = locationKey,
    })

    DoScreenFadeIn(500)
end

--- Public helper: returns the spot id the picker is currently previewing, or nil.
--- Other modules (stock/client.lua) use this to suppress the display-spot
--- re-render that fires when setDisplaySpot broadcasts — otherwise the new
--- vehicle spawns behind the camera while the player is still in the menu.
function GetActivePickerSpotId()
    return ShowroomState and ShowroomState.pickerSpotId or nil
end

--- Customer-facing spot view: centers the camera on the spot's own coords and
--- opens the showroom seeded with the specific stock item on that spot. No
--- sidebar (single-vehicle view); the normal purchase / finance flow is still
--- available through the bottom action bar.
RegisterNetEvent('pickle_dealerships:openSpotView', function(locationKey, spotId, spotCoords, stockId)
    if ShowroomState then return end
    if not locationKey or not spotCoords or not spotCoords.x then return end

    local dealershipData = lib.callback.await('pickle_dealerships:getDealershipData', false, locationKey)
    if not dealershipData then return end

    -- Spot view is non-destructive: the vehicle the player is looking at is
    -- already spawned in the world, so we only layer an orbit camera + NUI on
    -- top. No ped hide, no preview-vehicle swap, no pocket instance — just
    -- frame the car that's physically sitting on the spot. Fade in/out still
    -- happens so the transition feels consistent with the rest of the system.
    local spawnCoords = vector4(spotCoords.x, spotCoords.y, spotCoords.z, spotCoords.w or 0.0)

    DoScreenFadeOut(500)
    while not IsScreenFadedOut() do Wait(0) end

    -- 45° orbit offset relative to the showroom heading so the camera opens
    -- at a consistent three-quarter angle regardless of how the showroom
    -- point is rotated in-world.
    local initAngle = math.rad(45 + (spawnCoords.w or 0.0))
    local defaultRadius = 6.0
    local center = vector3(spawnCoords.x, spawnCoords.y, spawnCoords.z + 0.5)
    -- Stream the spot's surroundings even if the player is outside the
    -- interior; cleared on CleanupShowroom.
    SetFocusArea(center.x, center.y, center.z, 0.0, 0.0, 0.0)
    local cam = CreateCam("DEFAULT_SCRIPTED_CAMERA", true)
    SetCamCoord(cam, center.x + defaultRadius * math.cos(initAngle), center.y + defaultRadius * math.sin(initAngle), center.z + defaultRadius * math.sin(0.8) * 0.5)
    PointCamAtCoord(cam, center.x, center.y, center.z)
    SetCamActive(cam, true)
    RenderScriptCams(true, false, 0, true, true)

    local role = lib.callback.await('pickle_dealerships:getPlayerRole', false, locationKey) or 'customer'

    ShowroomState = {
        vehicle = nil,
        cam = cam,
        locationKey = locationKey,
        spawnCoords = spawnCoords,
        currentModel = nil,
        orbitAngle = initAngle,
        orbitPitch = 0.8, -- start camera at max top pitch so it opens looking down at the car
        orbitRadius = defaultRadius,
        targetCenter = center,
        spotViewStockId = stockId,
        spotViewSpotId = spotId,
        lightweight = true, -- marker so CleanupShowroom knows to skip fade/ped restore
    }

    StartShowroomCamThread()

    OpenNui('showroom', {
        dealershipId = dealershipData.id,
        dealershipName = dealershipData.name,
        role = role,
        tier = dealershipData.tier,
        location = locationKey,
        spotViewStockId = stockId,
    })

    DoScreenFadeIn(500)
end)

--- Walk-up display-spot picker: reuses the showroom camera/UI but centers on
--- the spot's own coords so the owner can preview each vehicle exactly where
--- it'll sit. Confirming writes the stock→spot assignment via setDisplaySpot.
RegisterNetEvent('pickle_dealerships:openSpotPicker', function(locationKey, spotId, spotCoords)
    if ShowroomState then return end
    if not locationKey or not spotId or not spotCoords or not spotCoords.x then return end

    local dealershipData = lib.callback.await('pickle_dealerships:getDealershipData', false, locationKey)
    if not dealershipData then return end

    local spawnCoords = vector4(spotCoords.x, spotCoords.y, spotCoords.z, spotCoords.w or 0.0)

    local ped = PlayerPedId()
    local savedCoords = GetEntityCoords(ped)
    local savedHeading = GetEntityHeading(ped)

    DoScreenFadeOut(500)
    while not IsScreenFadedOut() do Wait(0) end

    FreezeEntityPosition(ped, true)
    DisplayRadar(false)
    DisplayHud(false)

    -- 45° orbit offset relative to the showroom heading so the camera opens
    -- at a consistent three-quarter angle regardless of how the showroom
    -- point is rotated in-world.
    local initAngle = math.rad(45 + (spawnCoords.w or 0.0))
    local defaultRadius = 6.0
    local center = vector3(spawnCoords.x, spawnCoords.y, spawnCoords.z + 0.5)
    local camX = center.x + defaultRadius * math.cos(initAngle)
    local camY = center.y + defaultRadius * math.sin(initAngle)
    -- camZ matches the orbit thread's formula (center.z + radius * sin(pitch) * 0.5) so
    -- the camera opens at the configured max-top pitch without a visible snap.
    local camZ = center.z + defaultRadius * math.sin(0.8) * 0.5
    -- Stream the spot's surroundings (interior or not) around the camera.
    SetFocusArea(center.x, center.y, center.z, 0.0, 0.0, 0.0)
    local cam = CreateCam("DEFAULT_SCRIPTED_CAMERA", true)
    SetCamCoord(cam, camX, camY, camZ)
    PointCamAtCoord(cam, center.x, center.y, center.z)
    SetCamActive(cam, true)
    RenderScriptCams(true, false, 0, true, true)

    ShowroomState = {
        vehicle = nil,
        cam = cam,
        locationKey = locationKey,
        spawnCoords = spawnCoords,
        savedCoords = savedCoords,
        savedHeading = savedHeading,
        currentModel = nil,
        orbitAngle = initAngle,
        orbitPitch = 0.8, -- start camera at max top pitch so it opens looking down at the car
        orbitRadius = defaultRadius,
        targetCenter = center,
        pickerSpotId = spotId, -- flag so the NUI renders the Place Here button
    }

    -- Hide whatever is currently rendered at this spot (if any) so the showroom
    -- camera isn't pointed at two cars stacked on each other. stock/client.lua
    -- listens for this event and surgically deletes the display vehicle without
    -- touching the DB. CleanupShowroom will restore or replace it on close.
    TriggerEvent('pickle_dealerships:spotPickerOpened', locationKey, spotId)

    StartShowroomCamThread()

    OpenNui('showroom', {
        dealershipId = dealershipData.id,
        dealershipName = dealershipData.name,
        role = 'admin',
        tier = dealershipData.tier,
        location = locationKey,
        pickerSpotId = spotId,
    })

    DoScreenFadeIn(500)
end)

-- ─── NUI Callbacks ──────────────────────────────────────────────────────────

RegisterNUICallback("showroomSwapVehicle", function(data, cb)
    if not ShowroomState then cb({ success = false }) return end
    -- Properties can be passed directly (auctions) or fetched via stockId (pre-owned stock)
    local properties = nil
    if data.properties then
        properties = data.properties
        if type(properties) == "string" then properties = json.decode(properties) end
    elseif data.stockId then
        local details = lib.callback.await("pickle_dealerships:getVehicleDetails", false, { stockId = data.stockId })
        if details and details.isUsed then properties = details.properties end
    end
    local ok = SwapShowroomVehicle(data.model, properties)
    cb({ success = ok })
end)

RegisterNUICallback("showroomOrbitInput", function(data, cb)
    if ShowroomState then
        if data.lookX then ShowroomInput.lookX = ShowroomInput.lookX + (tonumber(data.lookX) or 0.0) end
        if data.lookY then ShowroomInput.lookY = ShowroomInput.lookY + (tonumber(data.lookY) or 0.0) end
        if data.dragging ~= nil then ShowroomInput.dragging = data.dragging end
        if data.zoom then ShowroomInput.zoom = ShowroomInput.zoom + (tonumber(data.zoom) or 0.0) end
    end
    cb({})
end)

RegisterNUICallback("showroomClearVehicle", function(_, cb)
    if ShowroomState and ShowroomState.vehicle and DoesEntityExist(ShowroomState.vehicle) then
        DeleteEntity(ShowroomState.vehicle)
        ShowroomState.vehicle = nil
        ShowroomState.currentModel = nil
    end
    cb({})
end)

RegisterNUICallback("showroomSetColor", function(data, cb)
    if not ShowroomState or not ShowroomState.vehicle or not DoesEntityExist(ShowroomState.vehicle) then
        cb({})
        return
    end
    local veh = ShowroomState.vehicle
    if data.primaryR and data.primaryG and data.primaryB then
        SetVehicleCustomPrimaryColour(veh, data.primaryR, data.primaryG, data.primaryB)
    end
    if data.secondaryR and data.secondaryG and data.secondaryB then
        SetVehicleCustomSecondaryColour(veh, data.secondaryR, data.secondaryG, data.secondaryB)
    end
    cb({})
end)

RegisterNUICallback("showroomPurchase", function(data, cb)
    if not ShowroomState then cb({ success = false }) return end

    -- Save colors before cleanup clears state
    local color = data.color
    local secColor = data.secondaryColor
    if color and type(color) == "string" then color = json.decode(color) end
    if secColor and type(secColor) == "string" then secColor = json.decode(secColor) end

    -- Fetch details so we know if pre-owned (carries captured properties)
    local details = lib.callback.await("pickle_dealerships:getVehicleDetails", false, { stockId = data.stockId })

    -- Run the server-side purchase
    local result = lib.callback.await("pickle_dealerships:purchaseVehicle", false, {
        dealershipId = data.dealershipId,
        stockId = data.stockId,
        paymentMethod = data.paymentMethod or "cash",
        couponCode = data.couponCode,
    })

    if not result or not result.success then
        ShowNotification(result and result.message or _L("showroom_purchase_failed"))
        cb(result or { success = false })
        return
    end

    -- Clean up showroom but keep screen faded out
    local location = data.location
    CleanupShowroom(true)

    -- Spawn the purchased vehicle and warp player in while screen is still black
    local cfg = DealershipConfigs[location]
    local spawnPoint = cfg and cfg.spawnPoint
    if spawnPoint then
        local props = nil
        if details and details.isUsed then
            props = details.properties
            if result.plate and type(props) == "table" then props.plate = result.plate end
        end
        SpawnPurchasedVehicle(result.model, spawnPoint, color, secColor, props, result.plate)
    end

    -- Now fade in with player already in the vehicle
    DoScreenFadeIn(500)

    ShowNotification(_L("showroom_purchase_success", result.label or result.model))
    cb(result)
end)

-- Finance a vehicle: create loan, exit showroom, spawn vehicle
RegisterNUICallback("showroomFinance", function(data, cb)
    if not ShowroomState then cb({ success = false }) return end

    local result = lib.callback.await("pickle_dealerships:createFinancing", false, {
        dealershipId = data.dealershipId,
        stockId = data.stockId,
        downPayment = data.downPayment,
        installments = data.installments,
        paymentMethod = data.paymentMethod,
    })

    if not result or not result.success then
        ShowNotification(result and result.message or _L("showroom_financing_failed"))
        cb(result or { success = false })
        return
    end

    local location = data.location
    CleanupShowroom(true)

    local cfg = DealershipConfigs[location]
    local spawnPoint = cfg and cfg.spawnPoint
    if spawnPoint then
        local props = nil
        if result.isUsed and result.properties then
            props = result.properties
            if type(props) == "string" then props = json.decode(props) end
            if type(props) == "table" and result.plate then props.plate = result.plate end
        end
        SpawnPurchasedVehicle(result.model, spawnPoint, nil, nil, props, result.plate)
    end

    DoScreenFadeIn(500)
    ShowNotification(_L("showroom_financed",
        result.label, GetCurrencyString(result.downPayment),
        result.totalInstallments, GetCurrencyString(result.installmentAmount)
    ))
    cb(result)
end)

RegisterNUICallback("showroomClose", function(_, cb)
    CleanupShowroom()
    cb({})
end)

-- Claim an auction vehicle: close showroom, teleport to dealership spawn, spawn vehicle, warp in
RegisterNUICallback("showroomClaimAuction", function(data, cb)
    local ok, result = lib.callback.await("pickle_dealerships:claimAuctionVehicle", false, {
        auctionId = tonumber(data.auctionId),
        toGarage = data.toGarage == true,
    })
    if not ok then
        ShowNotification(result or _L("auction_claim_failed"))
        cb({ success = false })
        return
    end

    -- Send to garage — no spawn needed, stay in showroom
    if data.toGarage then
        ShowNotification(_L("showroom_sent_to_garage", result.label or "vehicle"))
        cb({ success = true, toGarage = true })
        return
    end

    -- Claim vehicle — exit showroom, spawn at dealership
    local locationKey = result.dealershipLocation
    local targetCfg = locationKey and DealershipConfigs[locationKey] or nil

    CleanupShowroom(true) -- keep screen faded out

    if targetCfg and targetCfg.spawnPoint then
        local sp = targetCfg.spawnPoint
        local ped = PlayerPedId()
        SetEntityCoords(ped, sp.x, sp.y, sp.z, false, false, false, true)
        RequestCollisionAtCoord(sp.x, sp.y, sp.z)
        Wait(500)

        local props = result.properties
        if type(props) == "string" then props = json.decode(props) end
        SpawnPurchasedVehicle(result.model, sp, nil, nil, props, result.plate)
        ShowNotification(_L("showroom_claimed", result.label or result.model))
    else
        ShowNotification(_L("showroom_claimed_no_spawn"))
    end

    DoScreenFadeIn(500)
    cb({ success = true })
end)


-- Cleanup on resource stop
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    if ShowroomState then
        if ShowroomState.vehicle and DoesEntityExist(ShowroomState.vehicle) then
            DeleteEntity(ShowroomState.vehicle)
        end
        if ShowroomState.cam then
            RenderScriptCams(false, false, 0, true, true)
            DestroyCam(ShowroomState.cam, false)
        end
        ShowroomState = nil
    end
end)
