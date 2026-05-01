-- Interactive soiling scene. Mirrors modules/planting and modules/watering
-- structurally: scripted camera frames the pot, the cursor drives the bag's
-- world position, A/D adjust pitch.
--
--   "rip"   — pickle_soil_bag_01 (full) and pickle_soil_ripbag_01 (ripped)
--             spawn at the same anchor; ripped is attached inside the full
--             bag at identity. While LMB held, accumulate cursor travel —
--             the full bag's alpha fades 255→0 as ripProgress goes 0→1.
--             At 1.0 the full bag is deleted, leaving only the ripped bag.
--   "pour"  — drag the ripped bag with the cursor; A/D pitch. Past
--             pourAngleDeg with the bag horizontally over the pot, a
--             scene-local pickle_soil_01 entity rises from soilStartZ up
--             toward planting.rubbleSoilZ as fill goes 0→1. At 1.0 we fire
--             pickle_drugs:addSoil and tear down.

local SoilState = nil

local CAMERA_FOV         = 38.0
local PLANT_BAG_REST_Z   = 0.5

-- ─── Camera + helpers (mirrored from planting/watering) ────────────────────

local function CreateSoilingCam(center, heading, drugCfg)
    local potHash = joaat("pickle_pot_01")
    local pMin, pMax = GetModelDimensions(potHash)
    local fov = CAMERA_FOV

    local sceneBotZ = center.z + pMin.z
    local sceneTopZ = center.z + PLANT_BAG_REST_Z + 0.18
    local sceneH    = sceneTopZ - sceneBotZ
    local sceneW    = math.max(pMax.x - pMin.x, pMax.y - pMin.y, 0.4)

    local aimZ = (sceneTopZ + sceneBotZ) * 0.5
    local aspect = GetAspectRatio(false) or 1.777
    local fitH = (sceneH * 0.5) / math.tan(math.rad(fov) * 0.5)
    local fitW = (sceneW * 0.5) / math.tan(math.rad(fov) * 0.5) / aspect
    local distance = math.max(fitH, fitW)
        * ((drugCfg.soiling and drugCfg.soiling.cameraDistMul) or 1.4)

    local rad = math.rad(heading)
    local camX = center.x + math.sin(rad) * distance
    local camY = center.y - math.cos(rad) * distance
    local camZ = aimZ + 1.0

    local cam = CreateCam("DEFAULT_SCRIPTED_CAMERA", true)
    SetCamCoord(cam, camX, camY, camZ)
    PointCamAtCoord(cam, center.x, center.y, aimZ)
    SetCamFov(cam, fov)
    SetCamActive(cam, true)
    RenderScriptCams(true, false, 0, true, true)
    return cam
end

local function CursorToWorldPoint(cx, cy, depth, fovDeg)
    local camCoord = GetCamCoord(SoilState.cam)
    local camRot   = GetCamRot(SoilState.cam, 2)
    local rx, _, rz = math.rad(camRot.x), math.rad(camRot.y), math.rad(camRot.z)
    local fx = -math.sin(rz) * math.cos(rx)
    local fy =  math.cos(rz) * math.cos(rx)
    local fz =  math.sin(rx)
    local rXx, rXy, rXz = math.cos(rz), math.sin(rz), 0.0
    local upX = rXy * fz - rXz * fy
    local upY = rXz * fx - rXx * fz
    local upZ = rXx * fy - rXy * fx

    local fovRad = math.rad(fovDeg or CAMERA_FOV)
    local screenH = math.tan(fovRad * 0.5) * depth
    local aspect  = GetAspectRatio(false) or 1.777
    local screenW = screenH * aspect
    local sx = (cx - 0.5) * 2.0 * screenW
    local sy = (cy - 0.5) * 2.0 * screenH

    local px = camCoord.x + fx * depth + rXx * sx - upX * sy
    local py = camCoord.y + fy * depth + rXy * sx - upY * sy
    local pz = camCoord.z + fz * depth + rXz * sx - upZ * sy
    return camCoord, vector3(px, py, pz), vector3(fx, fy, fz)
end

local function CursorToBagPos(cx, cy, fovDeg)
    local anchor   = SoilState.restAnchor
    local camCoord = GetCamCoord(SoilState.cam)
    local camRot   = GetCamRot(SoilState.cam, 2)
    local rz       = math.rad(camRot.z)
    local rXx, rXy = math.cos(rz), math.sin(rz)

    local dx, dy = anchor.x - camCoord.x, anchor.y - camCoord.y
    local depth  = math.max(0.5, math.sqrt(dx * dx + dy * dy))

    local fovRad  = math.rad(fovDeg or CAMERA_FOV)
    local screenH = math.tan(fovRad * 0.5) * depth
    local aspect  = GetAspectRatio(false) or 1.777
    local screenW = screenH * aspect
    local sx = (cx - 0.5) * 2.0 * screenW
    local sy = (cy - 0.5) * 2.0 * screenH

    return vector3(
        anchor.x + rXx * sx,
        anchor.y + rXy * sx,
        anchor.z - sy)
end

local function RebaseAnchorToCurrent(cx, cy, fovDeg, ent)
    if not ent or not DoesEntityExist(ent) then return end
    local p = GetEntityCoords(ent)
    local camCoord = GetCamCoord(SoilState.cam)
    local camRot   = GetCamRot(SoilState.cam, 2)
    local rz       = math.rad(camRot.z)
    local rXx, rXy = math.cos(rz), math.sin(rz)

    local dx, dy = p.x - camCoord.x, p.y - camCoord.y
    local depth  = math.max(0.5, math.sqrt(dx * dx + dy * dy))

    local fovRad  = math.rad(fovDeg or CAMERA_FOV)
    local screenH = math.tan(fovRad * 0.5) * depth
    local aspect  = GetAspectRatio(false) or 1.777
    local screenW = screenH * aspect
    local sx = (cx - 0.5) * 2.0 * screenW
    local sy = (cy - 0.5) * 2.0 * screenH

    SoilState.restAnchor = vector3(
        p.x - rXx * sx,
        p.y - rXy * sx,
        p.z + sy)
end

local function CursorHitsEntity(cx, cy, fovDeg, targetEntity)
    if not targetEntity or not DoesEntityExist(targetEntity) then return false end
    local camCoord, point = CursorToWorldPoint(cx, cy, 1.0, fovDeg)
    local dx, dy, dz = point.x - camCoord.x, point.y - camCoord.y, point.z - camCoord.z
    local dlen = math.sqrt(dx * dx + dy * dy + dz * dz)
    if dlen <= 0 then return false end
    dx, dy, dz = dx / dlen, dy / dlen, dz / dlen
    local range = 8.0
    local handle = StartShapeTestRay(
        camCoord.x, camCoord.y, camCoord.z,
        camCoord.x + dx * range, camCoord.y + dy * range, camCoord.z + dz * range,
        1 | 8 | 16, PlayerPedId(), 4)
    local _, hit, _, _, entity = GetShapeTestResult(handle)
    return hit == 1 and entity == targetEntity
end

-- ─── Bag + soil prop spawning ──────────────────────────────────────────────

local function SpawnBagPair(drugCfg, anchor)
    local fullModel = drugCfg.soilBag and drugCfg.soilBag.full
    local rippedModel = drugCfg.soilBag and drugCfg.soilBag.ripped
    if not fullModel or not rippedModel then return nil, nil end
    local fullHash = LoadModel(fullModel)
    local rippedHash = LoadModel(rippedModel)
    if not fullHash or not rippedHash then return nil, nil end

    local full = CreateObject(fullHash, anchor.x, anchor.y, anchor.z, false, false, false)
    SetEntityCollision(full, true, false)
    FreezeEntityPosition(full, true)

    -- Ripped bag attached at identity, sitting visually inside the full
    -- bag. As the full bag's alpha drops, the ripped one is revealed
    -- underneath. Collision is fully disabled (and ride-through enabled)
    -- so the cursor raycast only hits the full bag during the rip phase
    -- — otherwise the ripbag's identical world position can shadow it.
    local ripped = CreateObject(rippedHash, anchor.x, anchor.y, anchor.z, false, false, false)
    SetEntityCollision(ripped, false, false)
    SetEntityCompletelyDisableCollision(ripped, false, false)
    AttachEntityToEntity(ripped, full, 0,
        0.0, 0.0, 0.0,
        0.0, 0.0, 0.0,
        false, false, false, false, 2, true)

    SetModelAsNoLongerNeeded(fullHash)
    SetModelAsNoLongerNeeded(rippedHash)
    return full, ripped
end

local function SpawnSceneSoil(center, startZ)
    local hash = LoadModel("pickle_soil_01")
    if not hash then return nil end
    local ent = CreateObjectNoOffset(hash, center.x, center.y, center.z + startZ, false, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not ent or not DoesEntityExist(ent) then return nil end
    SetEntityCollision(ent, false, false)
    FreezeEntityPosition(ent, true)
    return ent
end

local function CleanupSoilingScene(skipFade)
    if not SoilState then return end
    if SoilState.tearingDown then return end
    SoilState.tearingDown = true

    local fadeMs = 400
    if not skipFade then
        DoScreenFadeOut(fadeMs)
        while not IsScreenFadedOut() do Wait(0) end
    end

    RenderScriptCams(false, false, 0, true, true)
    if SoilState.cam then DestroyCam(SoilState.cam, false) end

    local toDelete = {}
    if SoilState.fullBag    then toDelete[#toDelete + 1] = SoilState.fullBag end
    if SoilState.rippedBag  then toDelete[#toDelete + 1] = SoilState.rippedBag end
    if SoilState.sceneSoil  then toDelete[#toDelete + 1] = SoilState.sceneSoil end
    for _, ent in ipairs(toDelete) do
        if ent and DoesEntityExist(ent) then DeleteEntity(ent) end
    end

    if SetPlotSoilVisible then SetPlotSoilVisible(SoilState.plotId, true) end

    SetNuiFocus(false, false)
    SendNUIMessage({ action = "closeSoiling" })

    local ped = PlayerPedId()
    FreezeEntityPosition(ped, false)
    SetEntityVisible(ped, true, false)
    DisplayRadar(true)
    DisplayHud(true)
    ClearFocus()

    if not skipFade then DoScreenFadeIn(fadeMs) end
    SoilState = nil
end

local function FinishScene()
    if not SoilState or SoilState.phase == "done" then return end
    SoilState.phase = "done"
    TriggerServerEvent("pickle_drugs:addSoil", SoilState.plotId)
    -- Brief hold so the filled soil reads on screen before fade.
    SetTimeout(250, function() CleanupSoilingScene() end)
end

-- ─── Main thread ───────────────────────────────────────────────────────────

local function RunSoilingThread()
    CreateThread(function()
        local cfg = SoilState.drugCfg.soiling
        local plantingCfg = SoilState.drugCfg.planting or {}
        local rotateSpeed = 90.0    -- deg/sec
        local pourAngle = cfg.pourAngleDeg or 60.0
        local fillPerSec = (cfg.secondsPerFullBag and cfg.secondsPerFullBag > 0)
            and (1.0 / cfg.secondsPerFullBag) or 0.33
        local soilStartZ = cfg.soilStartZ or -0.35
        local soilEndZ   = plantingCfg.rubbleSoilZ or 0.0
        local maxPitch   = 110.0

        local lastTime = GetGameTimer()
        local pitch = 0.0

        while SoilState do
            DisableAllControlActions(0)
            local nowMs = GetGameTimer()
            local dt = (nowMs - lastTime) / 1000.0
            lastTime = nowMs

            local cx, cy = SoilState.cursorX or 0.5, SoilState.cursorY or 0.5

            -- ── RIP PHASE ────────────────────────────────────────────────
            -- Track the cursor's swept horizontal range while LMB is held.
            -- Progress is the fraction of the bag's screen-space width that
            -- the cursor has covered — so a drag matching the bag's visible
            -- size tears it, regardless of camera framing or where on the
            -- screen the player started dragging.
            if SoilState.phase == "rip" then
                if SoilState.grabbed and SoilState.fullBag and DoesEntityExist(SoilState.fullBag) then
                    -- Only accumulate the rip sweep while the cursor is
                    -- vertically over the bag (small padding so the edge
                    -- isn't punishing). Horizontal range is still free —
                    -- the player drags across the bag, not anywhere on
                    -- screen.
                    local pad = 0.04
                    local overBag =
                        cy >= (SoilState.bagScreenTop or 0) - pad and
                        cy <= (SoilState.bagScreenBottom or 1) + pad
                    if overBag then
                        SoilState.ripSweepMin = math.min(SoilState.ripSweepMin or cx, cx)
                        SoilState.ripSweepMax = math.max(SoilState.ripSweepMax or cx, cx)
                    end
                    local swept = (SoilState.ripSweepMax or cx) - (SoilState.ripSweepMin or cx)
                    local bagWidth = math.max(0.05,
                        (SoilState.bagScreenRight or 0.6) - (SoilState.bagScreenLeft or 0.4))
                    local p = math.min(1.0, swept / bagWidth)
                    local alpha = math.floor(255 * (1.0 - p))
                    SetEntityAlpha(SoilState.fullBag, alpha, false)
                    if p >= 1.0 then
                        -- Hand the ripped bag off to the pour phase: detach
                        -- from the (about-to-be-deleted) full bag, freeze it
                        -- in place, and re-enable collision so the cursor
                        -- raycast can hit it for grab-to-drag.
                        if SoilState.rippedBag and DoesEntityExist(SoilState.rippedBag) then
                            DetachEntity(SoilState.rippedBag, true, true)
                            FreezeEntityPosition(SoilState.rippedBag, true)
                            SetEntityCompletelyDisableCollision(SoilState.rippedBag, true, false)
                            SetEntityCollision(SoilState.rippedBag, true, false)
                        end
                        DeleteEntity(SoilState.fullBag)
                        SoilState.fullBag = nil
                        SoilState.phase = "pour"
                        SoilState.grabbed = false
                    end
                end

            -- ── POUR PHASE ───────────────────────────────────────────────
            elseif SoilState.phase == "pour" then
                if SoilState.grabbed and SoilState.rippedBag and DoesEntityExist(SoilState.rippedBag) then
                    local world = CursorToBagPos(cx, cy, CAMERA_FOV)
                    local _, _, fwd = CursorToWorldPoint(cx, cy, 1.0, CAMERA_FOV)
                    if SoilState.held and SoilState.held["KeyA"] then
                        pitch = math.min( maxPitch, pitch + rotateSpeed * dt)
                    end
                    if SoilState.held and SoilState.held["KeyD"] then
                        pitch = math.max(-maxPitch, pitch - rotateSpeed * dt)
                    end
                    SetEntityCoordsNoOffset(SoilState.rippedBag, world.x, world.y, world.z, false, false, false)
                    -- +180 yaw matches the rip-phase orientation so the
                    -- bag's "front" stays facing the camera while pouring.
                    SetEntityRotation(SoilState.rippedBag,
                        0.0, pitch,
                        math.deg(math.atan(fwd.y, fwd.x)) - 90.0 + 180.0,
                        2, true)
                end

                local bagPos = SoilState.rippedBag and DoesEntityExist(SoilState.rippedBag)
                    and GetEntityCoords(SoilState.rippedBag) or nil
                local plotCenter = SoilState.plotCenter
                local horizDist = bagPos and math.sqrt(
                    (bagPos.x - plotCenter.x)^2 + (bagPos.y - plotCenter.y)^2) or 999.0
                local landingInPot = bagPos
                    and horizDist < 0.45
                    and bagPos.z > plotCenter.z

                local pouring = math.abs(pitch) >= pourAngle and landingInPot

                if pouring then
                    SoilState.fill = math.min(1.0, (SoilState.fill or 0.0) + fillPerSec * dt)
                    if SoilState.sceneSoil and DoesEntityExist(SoilState.sceneSoil) then
                        local z = plotCenter.z + soilStartZ + (soilEndZ - soilStartZ) * SoilState.fill
                        SetEntityCoordsNoOffset(SoilState.sceneSoil,
                            plotCenter.x, plotCenter.y, z, false, false, false)
                    end
                    if SoilState.fill >= 1.0 then
                        FinishScene()
                    end
                end

                SendNUIMessage({ action = "soilingFill", data = { fill = SoilState.fill or 0.0, pitch = pitch } })
            end

            Wait(0)
        end
    end)
end

-- ─── Public entry ──────────────────────────────────────────────────────────

function OpenSoilingScene(plotId)
    if SoilState then return end
    local plot = GetPlotState(plotId)
    local spot = GetPlotSpot(plotId)
    if not plot or not spot then return end
    local drugCfg = Config.Drugs[plot.drug]
    if not drugCfg or not drugCfg.soiling or not drugCfg.soilBag then return end
    if (plot.soil_added_at or 0) ~= 0 then return end

    local center = vector3(spot.coords.x, spot.coords.y, spot.coords.z)
    local heading = spot.coords.w or 0.0
    local fadeMs = 400

    DoScreenFadeOut(fadeMs)
    while not IsScreenFadedOut() do Wait(0) end

    local ped = PlayerPedId()
    FreezeEntityPosition(ped, true)
    SetEntityVisible(ped, false, false)
    DisplayRadar(false)
    DisplayHud(false)
    SetFocusArea(center.x, center.y, center.z, 0.0, 0.0, 0.0)

    local cam = CreateSoilingCam(center, heading, drugCfg)
    local restCoords = vector3(center.x, center.y, center.z + PLANT_BAG_REST_Z)
    local fullBag, rippedBag = SpawnBagPair(drugCfg, restCoords)

    if fullBag then
        SetEntityCoordsNoOffset(fullBag, restCoords.x, restCoords.y, restCoords.z, false, false, false)
        -- Bag models are authored facing away from the camera; flip 180°
        -- on yaw so the front of the bag reads to the player.
        SetEntityRotation(fullBag, 0.0, 0.0, heading + 180.0, 2, true)
    end

    -- Compute the bag's screen-space horizontal span by projecting the four
    -- corners of its model AABB and taking min/max screen X. The rip
    -- threshold is anchored to this span — a drag that covers the bag's
    -- visible width tears it, regardless of how zoomed/framed the camera is.
    local bagScreenLeft, bagScreenRight = 0.4, 0.6
    local bagScreenTop, bagScreenBottom = 0.4, 0.6
    if fullBag then
        local pMin, pMax = GetModelDimensions(joaat(drugCfg.soilBag.full))
        local minX, maxX = math.huge, -math.huge
        local minY, maxY = math.huge, -math.huge
        for _, lx in ipairs({ pMin.x, pMax.x }) do
            for _, ly in ipairs({ pMin.y, pMax.y }) do
                for _, lz in ipairs({ pMin.z, pMax.z }) do
                    local w = GetOffsetFromEntityInWorldCoords(fullBag, lx, ly, lz)
                    local on, sx, sy = World3dToScreen2d(w.x, w.y, w.z)
                    if on then
                        if sx < minX then minX = sx end
                        if sx > maxX then maxX = sx end
                        if sy < minY then minY = sy end
                        if sy > maxY then maxY = sy end
                    end
                end
            end
        end
        if minX < maxX then bagScreenLeft, bagScreenRight = minX, maxX end
        if minY < maxY then bagScreenTop,  bagScreenBottom = minY, maxY end
    end

    -- Hide the persistent world soil — it shouldn't be visible yet anyway
    -- (soil_added_at == 0), but call it for symmetry with the planting
    -- scene's rubble hide.
    if SetPlotSoilVisible then SetPlotSoilVisible(plotId, false) end

    -- Scene-local soil that animates Z during the pour. It starts below the
    -- pot rim and rises to its resting position as fill goes 0→1.
    local sceneSoil = SpawnSceneSoil(center,
        (drugCfg.soiling.soilStartZ or -0.35))

    SoilState = {
        plotId       = plotId,
        spot         = spot,
        drugCfg      = drugCfg,
        cam          = cam,
        fullBag      = fullBag,
        rippedBag    = rippedBag,
        sceneSoil    = sceneSoil,
        phase        = "rip",
        ripProgress  = 0.0,
        fill         = 0.0,
        grabbed      = false,
        cursorX      = 0.5,
        cursorY      = 0.5,
        held         = {},
        plotCenter   = center,
        restAnchor   = restCoords,
        bagScreenLeft   = bagScreenLeft,
        bagScreenRight  = bagScreenRight,
        bagScreenTop    = bagScreenTop,
        bagScreenBottom = bagScreenBottom,
        ripSweepMin     = nil,
        ripSweepMax     = nil,
    }

    SetNuiFocus(true, true)
    SendNUIMessage({ action = "openSoiling", data = { plotId = plotId } })

    DoScreenFadeIn(fadeMs)
    RunSoilingThread()
end

-- ─── NUI callbacks ─────────────────────────────────────────────────────────

RegisterNUICallback("soilingClose", function(_, cb)
    CleanupSoilingScene()
    cb({ ok = true })
end)

RegisterNUICallback("soilingInput", function(data, cb)
    if not SoilState then cb({ ok = false }) return end
    if data.cursorX and data.cursorY then
        SoilState.cursorX = tonumber(data.cursorX)
        SoilState.cursorY = tonumber(data.cursorY)
    end
    if data.heldKeys then
        SoilState.held = {}
        for _, k in ipairs(data.heldKeys) do SoilState.held[k] = true end
    end
    cb({ ok = true })
end)

--- Mouse press / release routed by phase:
---   pressed=true  + rip   phase + ray on full bag   → grab (start ripping)
---   pressed=true  + pour  phase + ray on ripped bag → grab (start dragging)
---   pressed=false                                   → release grab
RegisterNUICallback("soilingClick", function(data, cb)
    if not SoilState then cb({ ok = false }) return end
    local pressed = data and data.pressed
    local cx = tonumber(data and data.x) or 0.5
    local cy = tonumber(data and data.y) or 0.5

    if not pressed then
        SoilState.grabbed = false
        cb({ ok = true })
        return
    end

    if SoilState.phase == "rip" then
        -- Rip on any LMB drag — no hit-test against the bag. The cursor
        -- doesn't need to be over the prop; horizontal travel while LMB
        -- is held is what tears the bag.
        SoilState.grabbed = true
        cb({ ok = true, hit = true })
        return
    elseif SoilState.phase == "pour" then
        if CursorHitsEntity(cx, cy, CAMERA_FOV, SoilState.rippedBag) then
            RebaseAnchorToCurrent(cx, cy, CAMERA_FOV, SoilState.rippedBag)
            SoilState.grabbed = true
            cb({ ok = true, hit = true })
            return
        end
    end

    cb({ ok = true, hit = false })
end)

AddEventHandler("onResourceStop", function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    CleanupSoilingScene(true)
end)
