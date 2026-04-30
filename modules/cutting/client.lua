-- Schedule-1-style cutting scene. Drug-agnostic: the plot's drug config
-- (Config.Drugs[drug].cutting + .stages[3].buds) drives every parameter.
-- Reuses the world entities spawned by modules/grow/client (plant + buds);
-- this module only owns the camera, scissors prop, and the falling carrier
-- objects spawned per cut.

local CuttingState = nil

--- Builds the camera framed around the union of the plant + bud bounding
--- boxes so the bud (which sits above the plant's bbox) is in shot.
local function CreateCuttingCam(center, heading, drugCfg)
    local cam = drugCfg.cutting.camera or {}
    local plantHash = joaat(drugCfg.stages[3].model)
    local budHash   = joaat(drugCfg.stages[3].buds.model)

    local pMin, pMax = GetModelDimensions(plantHash)
    local bMin, bMax = GetModelDimensions(budHash)
    local minZ = math.min(pMin.z, bMin.z)
    local maxZ = math.max(pMax.z, bMax.z)
    local size = math.max(
        math.max(pMax.x - pMin.x, pMax.y - pMin.y),
        math.max(bMax.x - bMin.x, bMax.y - bMin.y),
        maxZ - minZ
    )

    local aimZ = center.z + (minZ + maxZ) * 0.5
    local fov = cam.fov or 35.0
    local distance = (size * 0.5) / math.tan(math.rad(fov) * 0.5) * (cam.distanceMul or 1.0)

    local rad = math.rad(heading)
    local camX = center.x + math.sin(rad) * distance
    local camY = center.y - math.cos(rad) * distance
    local camZ = aimZ + (cam.heightOffset or 0.0)

    local camera = CreateCam("DEFAULT_SCRIPTED_CAMERA", true)
    SetCamCoord(camera, camX, camY, camZ)
    PointCamAtCoord(camera, center.x, center.y, aimZ)
    SetCamFov(camera, fov)
    SetCamActive(camera, true)
    RenderScriptCams(true, false, 0, true, true)
    return camera
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

    local fadeMs = (CuttingState.drugCfg and CuttingState.drugCfg.cutting and CuttingState.drugCfg.cutting.fadeMs) or 400
    if not skipFade then
        DoScreenFadeOut(fadeMs)
        while not IsScreenFadedOut() do Wait(0) end
    end

    RenderScriptCams(false, false, 0, true, true)
    if CuttingState.cam then DestroyCam(CuttingState.cam, false) end

    local toDelete = {}
    for _, fb in ipairs(CuttingState.fallingBuds or {}) do toDelete[#toDelete + 1] = fb end
    for _, c in pairs(CuttingState.fallingCarriers or {}) do toDelete[#toDelete + 1] = c end
    if CuttingState.tool then toDelete[#toDelete + 1] = CuttingState.tool end
    for _, ent in ipairs(toDelete) do
        if ent and DoesEntityExist(ent) then DeleteEntity(ent) end
    end

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
    CuttingState = nil
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
                SetEntityRotation(tool, lerp(-15.0, 15.0, CuttingState.cursorY), 0.0, math.deg(math.atan(fy, fx)) - 90.0, 2, true)
            end

            Wait(0)
        end
    end)
end

--- Public entry. Called from interactions_client when the player picks
--- "Harvest" on a stage-3 plot.
---@param plotId string
function OpenCuttingScene(plotId)
    if CuttingState then return end

    local plot   = GetPlotState(plotId)
    local spot   = GetPlotSpot(plotId)
    if not plot or not spot or plot.stage ~= 3 then return end

    local drugCfg = Config.Drugs[plot.drug]
    if not drugCfg or not drugCfg.cutting then return end

    local center  = vector3(spot.coords.x, spot.coords.y, spot.coords.z)
    local heading = spot.coords.w or 0.0
    local fadeMs  = drugCfg.cutting.fadeMs or 400

    DoScreenFadeOut(fadeMs)
    while not IsScreenFadedOut() do Wait(0) end

    local ped = PlayerPedId()
    FreezeEntityPosition(ped, true)
    SetEntityVisible(ped, false, false)
    DisplayRadar(false)
    DisplayHud(false)
    SetFocusArea(center.x, center.y, center.z, 0.0, 0.0, 0.0)

    local cam  = CreateCuttingCam(center, heading, drugCfg)
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
    }

    SetNuiFocus(true, true)
    SendNUIMessage({ action = "openCutting", data = { plantHeading = heading } })

    DoScreenFadeIn(fadeMs)
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
    local s3 = drugCfg.stages[3]
    if not s3 or not s3.buds then cb({ ok = true, hit = false }) return end
    local radius = s3.buds.hitRadius or 0.06

    -- Find the closest live bud entity within the cursor's radius.
    local bestIdx, bestDist
    for _, idx in ipairs(Grow.RemainingBudIndexes(plot, drugCfg)) do
        local bud = GetPlotBudEntity(CuttingState.plotId, idx)
        if bud and DoesEntityExist(bud) then
            local bc = GetEntityCoords(bud)
            local onScreen, sx, sy = World3dToScreen2d(bc.x, bc.y, bc.z)
            if onScreen then
                local dx, dy = sx - cx, sy - cy
                local dist = math.sqrt(dx * dx + dy * dy)
                if dist <= radius and (not bestDist or dist < bestDist) then
                    bestIdx, bestDist = idx, dist
                end
            end
        end
    end
    if not bestIdx then cb({ ok = true, hit = false }) return end

    -- Take ownership of the bud entity from grow/client so it doesn't get
    -- despawned by the next plot update mid-fall.
    local bud = TakePlotBudEntity(CuttingState.plotId, bestIdx)
    if not bud or not DoesEntityExist(bud) then cb({ ok = true, hit = false }) return end

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
