-- Schedule-1-style cutting scene. Drug-agnostic: the plot's drug config
-- (Config.Drugs[drug].cutting + .stages[3].buds) drives every parameter.
-- Reuses the world entities spawned by modules/grow/client (plant + buds);
-- this module only owns the camera, scissors prop, and the falling carrier
-- objects spawned per cut.

local CuttingState = nil

--- Returns the framing pose for the cutting scene. Used both by the
--- standalone OpenCuttingScene and by the unified plant scene's camera
--- director (which tweens our cam from the menu pose to this pose before
--- handing control to the cutting flow).
function GetCuttingCamPreset(spot, drugCfg)
    local cam = drugCfg.cutting.camera or {}
    local harvest   = Grow.HarvestStage(drugCfg)
    local plantHash = joaat(drugCfg.stages[harvest].model)
    local budHash   = joaat(drugCfg.stages[harvest].buds.model)

    local pMin, pMax = GetModelDimensions(plantHash)
    local bMin, bMax = GetModelDimensions(budHash)
    local minZ = math.min(pMin.z, bMin.z)
    local maxZ = math.max(pMax.z, bMax.z)
    local size = math.max(
        math.max(pMax.x - pMin.x, pMax.y - pMin.y),
        math.max(bMax.x - bMin.x, bMax.y - bMin.y),
        maxZ - minZ
    )

    local center  = vector3(spot.coords.x, spot.coords.y, spot.coords.z)
    local heading = spot.coords.w or 0.0
    local aimZ = center.z + (minZ + maxZ) * 0.5
    local fov = cam.fov or 35.0
    local distance = (size * 0.5) / math.tan(math.rad(fov) * 0.5) * (cam.distanceMul or 1.0)

    local rad = math.rad(heading)
    local camX = center.x + math.sin(rad) * distance
    local camY = center.y - math.cos(rad) * distance
    local camZ = aimZ + (cam.heightOffset or 0.0)

    return {
        coords = vector3(camX, camY, camZ),
        point  = vector3(center.x, center.y, aimZ),
        fov    = fov,
    }
end

local function CreateCuttingCam(center, heading, drugCfg)
    local pose = GetCuttingCamPreset({ coords = vector4(center.x, center.y, center.z, heading) }, drugCfg)
    local camera = CreateCam("DEFAULT_SCRIPTED_CAMERA", true)
    SetCamCoord(camera, pose.coords.x, pose.coords.y, pose.coords.z)
    PointCamAtCoord(camera, pose.point.x, pose.point.y, pose.point.z)
    SetCamFov(camera, pose.fov)
    SetCamActive(camera, true)
    RenderScriptCams(true, false, 0, true, true)
    return camera
end

-- Apple model used as an invisible raycast proxy for each attached bud.
-- Attached entities don't participate in shape tests in FiveM, so we mirror
-- each bud's world position with an unattached collidable apple. The proxy
-- is what the click ray actually hits; we map its entity id back to a bud
-- slot index. Refreshed on rotate and right before each click test.
local PROXY_MODEL = "sf_prop_sf_apple_01a"

local function SpawnBudProxies()
    if not CuttingState then return end
    local plot = GetPlotState(CuttingState.plotId)
    if not plot then return end
    local drugCfg = CuttingState.drugCfg
    local hash = LoadModel(PROXY_MODEL)
    if not hash then return end

    CuttingState.budProxies = CuttingState.budProxies or {}
    for _, idx in ipairs(Grow.RemainingBudIndexes(plot, drugCfg)) do
        local bud = GetPlotBudEntity(CuttingState.plotId, idx)
        if bud and DoesEntityExist(bud) and not CuttingState.budProxies[idx] then
            local bc = GetEntityCoords(bud)
            local proxy = CreateObject(hash, bc.x, bc.y, bc.z, false, false, false)
            if proxy and DoesEntityExist(proxy) then
                SetEntityCollision(proxy, true, false)
                FreezeEntityPosition(proxy, true)
                SetEntityVisible(proxy, Config.Debug == true, false)
                CuttingState.budProxies[idx] = proxy
            end
        end
    end
    SetModelAsNoLongerNeeded(hash)
end

local function RefreshBudProxies()
    if not CuttingState or not CuttingState.budProxies then return end
    for idx, proxy in pairs(CuttingState.budProxies) do
        local bud = GetPlotBudEntity(CuttingState.plotId, idx)
        if bud and DoesEntityExist(bud) and proxy and DoesEntityExist(proxy) then
            local bc = GetEntityCoords(bud)
            SetEntityCoordsNoOffset(proxy, bc.x, bc.y, bc.z + 0.05, false, false, false)
        end
    end
end

--- Spawns a free scissors prop. The cutting thread positions it each frame
--- at the cursor's projected world location (mirrors the pitcher in the
--- watering scene), so no animation or bone attach is needed.
local function SpawnFloatingScissors(drugCfg)
    local cut = drugCfg.cutting
    if not cut or not cut.tool then return nil end
    local hash = LoadModel(cut.tool)
    if not hash then return nil end
    local tool = CreateObject(hash, 0.0, 0.0, 0.0, false, false, false)
    SetEntityCollision(tool, false, false)
    FreezeEntityPosition(tool, true)
    SetModelAsNoLongerNeeded(hash)
    return tool
end

--- Tears the cutting view down. Fades the screen, restores ped + HUD, and
--- shows the world plots again. `skipFade` is passed by onResourceStop so
--- teardown completes synchronously — async waits would race the resource
--- being killed and leak entities / leave the screen black on next start.
local function CleanupCuttingView(skipFade)
    if not CuttingState then return end
    if CuttingState.tearingDown then return end
    CuttingState.tearingDown = true

    local embedded = CuttingState.embedded
    local onClose  = CuttingState.onClose
    local fadeMs = (CuttingState.drugCfg and CuttingState.drugCfg.cutting and CuttingState.drugCfg.cutting.fadeMs) or 400
    if not skipFade and not embedded then
        DoScreenFadeOut(fadeMs)
        while not IsScreenFadedOut() do Wait(0) end
    end

    if not embedded then
        RenderScriptCams(false, false, 0, true, true)
        if CuttingState.cam then DestroyCam(CuttingState.cam, false) end
    end

    local toDelete = {}
    for _, fb in ipairs(CuttingState.fallingBuds or {}) do toDelete[#toDelete + 1] = fb end
    for _, c in pairs(CuttingState.fallingCarriers or {}) do toDelete[#toDelete + 1] = c end
    for _, p in pairs(CuttingState.budProxies or {}) do toDelete[#toDelete + 1] = p end
    if CuttingState.tool then toDelete[#toDelete + 1] = CuttingState.tool end
    for _, ent in ipairs(toDelete) do
        if ent and DoesEntityExist(ent) then DeleteEntity(ent) end
    end

    if not embedded then
        SetNuiFocus(false, false)
        SendNUIMessage({ action = "closeCutting" })
        TriggerEvent("pickle_drugs:showPlots")

        local ped = PlayerPedId()
        ClearPedTasks(ped)
        FreezeEntityPosition(ped, false)
        SetEntityVisible(ped, true, false)
        DisplayRadar(true)
        DisplayHud(true)
        ClearFocus()

        if not skipFade then
            DoScreenFadeIn(fadeMs)
        end
    end
    CuttingState = nil
    if onClose then onClose() end
end

function CancelCuttingScene()
    if CuttingState then CleanupCuttingView(true) end
end

--- Each-frame loop: keeps gameplay controls disabled, and positions the
--- floating scissors prop at the cursor's projected world location. Math
--- mirrors modules/watering/client.lua — camera-forward + screen-space
--- offsets at a fixed depth so the prop hangs in front of the camera.
local function RunCuttingThread()
    CreateThread(function()
        local depth = 1.1 -- metres in front of the camera
        while CuttingState do
            DisableAllControlActions(0)

            local tool = CuttingState.tool
            if tool and DoesEntityExist(tool) and CuttingState.cam then
                local cx, cy = CuttingState.cursorX or 0.5, CuttingState.cursorY or 0.5
                local camCoord = GetCamCoord(CuttingState.cam)
                local camRot   = GetCamRot(CuttingState.cam, 2)
                local rx, _, rz = math.rad(camRot.x), math.rad(camRot.y), math.rad(camRot.z)

                -- Forward / right / up for the scripted camera.
                local fx = -math.sin(rz) * math.cos(rx)
                local fy =  math.cos(rz) * math.cos(rx)
                local fz =  math.sin(rx)
                local rXx =  math.cos(rz)
                local rXy =  math.sin(rz)
                local rXz =  0.0
                local upX = rXy * fz - rXz * fy
                local upY = rXz * fx - rXx * fz
                local upZ = rXx * fy - rXy * fx

                local fovRad = math.rad(CuttingState.drugCfg.cutting.camera.fov or 35.0)
                local screenH = math.tan(fovRad * 0.5) * depth
                local aspect = GetAspectRatio(false) or 1.777
                local screenW = screenH * aspect
                local sx = (cx - 0.5) * 2.0 * screenW
                local sy = (cy - 0.5) * 2.0 * screenH

                local px = camCoord.x + fx * depth + rXx * sx - upX * sy
                local py = camCoord.y + fy * depth + rXy * sx - upY * sy
                local pz = camCoord.z + fz * depth + rXz * sx - upZ * sy

                SetEntityCoordsNoOffset(tool, px, py, pz, false, false, false)
                -- Face the scissors toward the camera with a slight downward
                -- bias so the blades read as "ready to snip" from the player's view.
                SetEntityRotation(tool, lerp(5.0, -65.0, CuttingState.cursorY), 0.0, (math.deg(math.atan(fy, fx)) - 90.0) + lerp(-90.0, 90.0, CuttingState.cursorX), 2, true)
            end

            Wait(0)
        end
    end)
end

--- Public entry. Called from interactions_client when the player picks
--- "Harvest" on a stage-3 plot.
---@param plotId string
function OpenCuttingScene(plotId, opts)
    if CuttingState then return end
    opts = opts or {}
    local embedded = opts.embedded == true

    local plot   = GetPlotState(plotId)
    local spot   = GetPlotSpot(plotId)
    if not plot or not spot then return end

    local drugCfg = Config.Drugs[plot.drug]
    if not drugCfg or not drugCfg.cutting then return end
    if plot.stage ~= Grow.HarvestStage(drugCfg) then return end

    local center  = vector3(spot.coords.x, spot.coords.y, spot.coords.z)
    local heading = spot.coords.w or 0.0
    local fadeMs  = drugCfg.cutting.fadeMs or 400

    if not embedded then
        DoScreenFadeOut(fadeMs)
        while not IsScreenFadedOut() do Wait(0) end

        local ped = PlayerPedId()
        FreezeEntityPosition(ped, true)
        SetEntityVisible(ped, false, false)
        DisplayRadar(false)
        DisplayHud(false)
        SetFocusArea(center.x, center.y, center.z, 0.0, 0.0, 0.0)
    end

    local cam  = embedded and opts.cam or CreateCuttingCam(center, heading, drugCfg)
    local tool = SpawnFloatingScissors(drugCfg)

    CuttingState = {
        plotId          = plotId,
        spot            = spot,
        drugCfg         = drugCfg,
        cam             = cam,
        tool            = tool,
        plantHeading    = heading,
        fallingBuds     = {},
        fallingCarriers = {},
        cursorX         = 0.5,
        cursorY         = 0.5,
        embedded        = embedded,
        onClose         = opts.onClose,
    }

    SpawnBudProxies()

    if not embedded then
        SetNuiFocus(true, true)
        SendNUIMessage({ action = "openCutting", data = { plantHeading = heading } })
        DoScreenFadeIn(fadeMs)
    end
    RunCuttingThread()
end

-- ─── NUI callbacks ──────────────────────────────────────────────────────────

RegisterNUICallback("close", function(_, cb)
    CleanupCuttingView()
    cb({ ok = true })
end)

--- Cursor stream from the NUI. The cutting thread reads cursorX/Y each
--- frame to position the floating scissors.
local _cuttingInputCount = 0
RegisterNUICallback("cuttingInput", function(data, cb)
    if not CuttingState then cb({ ok = false }) return end
    if data.cursorX then CuttingState.cursorX = tonumber(data.cursorX) or 0.5 end
    if data.cursorY then CuttingState.cursorY = tonumber(data.cursorY) or 0.5 end
    _cuttingInputCount = _cuttingInputCount + 1
    if _cuttingInputCount % 60 == 1 then
        debugPrint(("cuttingInput recv x=%.3f y=%.3f tool=%s"):format(
            CuttingState.cursorX, CuttingState.cursorY, tostring(CuttingState.tool)))
    end
    cb({ ok = true })
end)

RegisterNUICallback("rotate", function(data, cb)
    if not CuttingState then cb({ ok = false }) return end
    local plant = GetPlotPlantEntity(CuttingState.plotId)
    if not plant or not DoesEntityExist(plant) then cb({ ok = false }) return end
    local delta = tonumber(data and data.delta) or 0.0
    CuttingState.plantHeading = (CuttingState.plantHeading + delta) % 360.0
    SetEntityHeading(plant, CuttingState.plantHeading)
    -- Buds are attached, so they swing with the plant — proxies aren't,
    -- so they need a manual sync to stay collocated for raycasts.
    RefreshBudProxies()
    cb({ ok = true, heading = CuttingState.plantHeading })
end)

--- Hit-tests the cursor against every remaining bud (looked up from the
--- world plot via grow/client). On hit, takes ownership of the bud entity
--- from grow/client, attaches it to an invisible apple carrier so it falls
--- with real physics, fires the server cutBud event, and schedules deletion.
RegisterNUICallback("clickAt", function(data, cb)
    if not CuttingState then cb({ ok = false, hit = false }) return end
    local plot = GetPlotState(CuttingState.plotId)
    if not plot then cb({ ok = false, hit = false }) return end

    local cx = tonumber(data and data.x) or -1
    local cy = tonumber(data and data.y) or -1
    if cx < 0 or cy < 0 then cb({ ok = false, hit = false }) return end

    local drugCfg = CuttingState.drugCfg
    local s3 = drugCfg.stages[Grow.HarvestStage(drugCfg)]
    if not s3 or not s3.buds then cb({ ok = true, hit = false }) return end

    -- Build a camera-space ray through the cursor. Math mirrors the
    -- per-frame scissors-positioning code: forward + right*sxOff - up*syOff
    -- gives a point on the cursor's view ray; subtract camCoord to get the
    -- direction.
    local camCoord = GetCamCoord(CuttingState.cam)
    local camRot   = GetCamRot(CuttingState.cam, 2)
    local rx, _, rz = math.rad(camRot.x), math.rad(camRot.y), math.rad(camRot.z)
    local fx = -math.sin(rz) * math.cos(rx)
    local fy =  math.cos(rz) * math.cos(rx)
    local fz =  math.sin(rx)
    local rXx, rXy, rXz = math.cos(rz), math.sin(rz), 0.0
    local upX = rXy * fz - rXz * fy
    local upY = rXz * fx - rXx * fz
    local upZ = rXx * fy - rXy * fx

    local depth   = 1.0
    local fovRad  = math.rad((drugCfg.cutting.camera and drugCfg.cutting.camera.fov) or 35.0)
    local screenH = math.tan(fovRad * 0.5) * depth
    local aspect  = GetAspectRatio(false) or 1.777
    local screenW = screenH * aspect
    local sxOff = (cx - 0.5) * 2.0 * screenW
    local syOff = (cy - 0.5) * 2.0 * screenH

    local pxw = camCoord.x + fx * depth + rXx * sxOff - upX * syOff
    local pyw = camCoord.y + fy * depth + rXy * sxOff - upY * syOff
    local pzw = camCoord.z + fz * depth + rXz * sxOff - upZ * syOff
    local ddx, ddy, ddz = pxw - camCoord.x, pyw - camCoord.y, pzw - camCoord.z
    local dlen = math.sqrt(ddx * ddx + ddy * ddy + ddz * ddz)
    if dlen <= 0 then cb({ ok = true, hit = false }) return end
    ddx, ddy, ddz = ddx / dlen, ddy / dlen, ddz / dlen

    -- Make sure any newly-grown buds have proxies and existing ones are at
    -- their bud's current world coords (in case the plant rotated since
    -- last refresh). Then index proxies by entity for O(1) hit lookup.
    SpawnBudProxies()
    RefreshBudProxies()
    local budByEntity = {}
    for idx, proxy in pairs(CuttingState.budProxies or {}) do
        if proxy and DoesEntityExist(proxy) then budByEntity[proxy] = idx end
    end

    -- Entities the ray should pass through: the floating scissors prop and
    -- any in-flight cut buds + their invisible apple carriers.
    local skipEntities = {}
    if CuttingState.tool then skipEntities[CuttingState.tool] = true end
    for _, fb in ipairs(CuttingState.fallingBuds or {}) do skipEntities[fb] = true end
    for _, fc in pairs(CuttingState.fallingCarriers or {}) do skipEntities[fc] = true end

    local range = 6.0
    local fX, fY, fZ = camCoord.x, camCoord.y, camCoord.z
    local bestIdx
    for _ = 1, 6 do
        local tX, tY, tZ = camCoord.x + ddx * range, camCoord.y + ddy * range, camCoord.z + ddz * range
        local handle = StartShapeTestRay(fX, fY, fZ, tX, tY, tZ, 1 | 8 | 16, PlayerPedId(), 4)
        local _, hit, endCoords, _, entity = GetShapeTestResult(handle)
        if hit ~= 1 then break end
        if budByEntity[entity] then bestIdx = budByEntity[entity] break end
        if not skipEntities[entity] then break end
        -- Step past the unwanted hit and re-cast.
        fX = endCoords.x + ddx * 0.02
        fY = endCoords.y + ddy * 0.02
        fZ = endCoords.z + ddz * 0.02
    end
    if not bestIdx then cb({ ok = true, hit = false }) return end

    -- Take ownership of the bud entity from grow/client so it doesn't get
    -- despawned by the next plot update mid-fall.
    local bud = TakePlotBudEntity(CuttingState.plotId, bestIdx)
    if not bud or not DoesEntityExist(bud) then cb({ ok = true, hit = false }) return end

    -- Bud is going away — drop its raycast proxy so subsequent clicks can't
    -- hit-test against thin air.
    if CuttingState.budProxies and CuttingState.budProxies[bestIdx] then
        local p = CuttingState.budProxies[bestIdx]
        if p and DoesEntityExist(p) then DeleteEntity(p) end
        CuttingState.budProxies[bestIdx] = nil
    end

    CuttingState.fallingBuds[#CuttingState.fallingBuds + 1] = bud

    -- The custom bud YDR's bounds aren't accepted by the simulator (falls
    -- through everything). We attach it to an invisible vanilla apple — its
    -- bounds work — so the bud rides the apple's fall.
    local bc = GetEntityCoords(bud)
    local br = GetEntityRotation(bud, 2)
    DetachEntity(bud, true, true)
    FreezeEntityPosition(bud, false)
    SetEntityCollision(bud, false, false)

    local carrierHash = LoadModel(drugCfg.cutting.fallCarrier or "sf_prop_sf_apple_01a")
    if carrierHash then
        local carrier = CreateObject(carrierHash, bc.x, bc.y, bc.z, false, false, true)
        if carrier and DoesEntityExist(carrier) then
            SetEntityRotation(carrier, br.x, br.y, br.z, 2, true)
            SetEntityVisible(carrier, false, false)
            SetEntityCollision(carrier, true, true)
            SetEntityHasGravity(carrier, true)
            ActivatePhysics(carrier)
            AttachEntityToEntity(bud, carrier, 0,
                0.0, 0.0, 0.0,
                0.0, 0.0, 0.0,
                false, false, false, false, 2, true)
            CuttingState.fallingCarriers[bud] = carrier
        end
        SetModelAsNoLongerNeeded(carrierHash)
    end

    TriggerServerEvent("pickle_drugs:cutBud", CuttingState.plotId, bestIdx)
    local remaining = #Grow.RemainingBudIndexes(plot, drugCfg) - 1 -- minus the one we just cut
    cb({ ok = true, hit = true, remaining = remaining })

    local lastBud = remaining <= 0
    SetTimeout(drugCfg.cutting.fallMs or 2000, function()
        if not CuttingState then return end
        for i, fb in ipairs(CuttingState.fallingBuds) do
            if fb == bud then table.remove(CuttingState.fallingBuds, i) break end
        end
        local carrier = CuttingState.fallingCarriers and CuttingState.fallingCarriers[bud] or nil
        if carrier and DoesEntityExist(carrier) then DeleteEntity(carrier) end
        if CuttingState.fallingCarriers then CuttingState.fallingCarriers[bud] = nil end
        if DoesEntityExist(bud) then DeleteEntity(bud) end
        if lastBud then CleanupCuttingView() end
    end)
end)

AddEventHandler("onResourceStop", function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    -- Synchronous: skip fade so teardown finishes before the resource dies.
    CleanupCuttingView(true)
end)
