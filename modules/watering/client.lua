-- Cursor-driven watering scene. The pitcher follows the NUI cursor in
-- screen space (raycast → world-position pulled back along camera-forward
-- so it renders in front of the camera, not behind whatever surface it
-- raycast against). A/D rotate the pitcher's pitch; past Config pourAngleDeg
-- the pitcher pours: water particles emit at the spout, the attached liquid
-- prop's local Z lerps down, and pours "land" on the plot when the spout
-- raycasts down into the soil — bumping the server-side water_count.

local WaterState = nil

--- Spawn the pitcher + an attached liquid prop. Both are kinematic — the
--- pitcher is moved each frame by SetEntityCoordsNoOffset, the liquid
--- shifts via SetAttachedEntityOffset-equivalent (re-attach with new local
--- offsets on each level change).
local function SpawnPitcher(drugCfg, anchor)
    local pitcherHash = LoadModel(drugCfg.watering.pitcher)
    if not pitcherHash then return nil end
    local pitcher = CreateObject(pitcherHash, anchor.x, anchor.y, anchor.z, false, false, false)
    SetEntityCollision(pitcher, false, false)
    FreezeEntityPosition(pitcher, true)
    SetModelAsNoLongerNeeded(pitcherHash)

    local liquidEnt
    if drugCfg.watering.liquid then
        local liquidHash = LoadModel(drugCfg.watering.liquid)
        if liquidHash then
            liquidEnt = CreateObject(liquidHash, anchor.x, anchor.y, anchor.z, false, false, false)
            SetEntityCollision(liquidEnt, false, false)
            -- Identity attach: the liquid YDR is authored with offsets baked
            -- in so 100% sits at the rim. We slide it down on Z as the level
            -- drops (re-attach with a new offset).
            AttachEntityToEntity(liquidEnt, pitcher, 0,
                0.0, 0.0, drugCfg.watering.liquidMaxZ or 0.0,
                0.0, 0.0, 0.0,
                false, false, false, false, 2, true)
            SetModelAsNoLongerNeeded(liquidHash)
        end
    end

    return pitcher, liquidEnt
end

--- Re-attaches the liquid with a new Z offset. Cheaper than animating since
--- the liquid is just a hollow shape sliding inside the pitcher.
local function SetLiquidLevel(pitcher, liquid, drugCfg, level01)
    if not liquid or not DoesEntityExist(liquid) then return end
    local hi = drugCfg.watering.liquidMaxZ or 0.0
    local lo = drugCfg.watering.liquidMinZ or -0.18
    local z  = lo + (hi - lo) * math.max(0.0, math.min(1.0, level01))
    AttachEntityToEntity(liquid, pitcher, 0,
        0.0, 0.0, z,
        0.0, 0.0, 0.0,
        false, false, false, false, 2, true)
end

--- Camera framed on the plot, slightly tighter than the cutting view so
--- the soil reads clearly. Reuses the cutting camera knobs but with a
--- watering-specific distance multiplier.
local function CreateWateringCam(center, heading, drugCfg)
    local cfg = drugCfg.watering
    local potHash = joaat("pickle_pot_01")
    local pMin, pMax = GetModelDimensions(potHash)
    local size = math.max(pMax.x - pMin.x, pMax.y - pMin.y, pMax.z - pMin.z, 0.6)
    local fov  = 38.0
    local aimZ = center.z + (pMin.z + pMax.z) * 0.5 + 0.4
    local distance = (size * 0.5) / math.tan(math.rad(fov) * 0.5) * (cfg.cameraDistMul or 1.4)

    local rad = math.rad(heading)
    local camX = center.x + math.sin(rad) * distance
    local camY = center.y - math.cos(rad) * distance
    local camZ = aimZ + 0.6

    local cam = CreateCam("DEFAULT_SCRIPTED_CAMERA", true)
    SetCamCoord(cam, camX, camY, camZ)
    PointCamAtCoord(cam, center.x, center.y, aimZ)
    SetCamFov(cam, fov)
    SetCamActive(cam, true)
    RenderScriptCams(true, false, 0, true, true)
    return cam
end

local function CleanupWateringScene(skipFade)
    if not WaterState then return end
    if WaterState.tearingDown then return end
    WaterState.tearingDown = true

    local fadeMs = 400
    if not skipFade then
        DoScreenFadeOut(fadeMs)
        while not IsScreenFadedOut() do Wait(0) end
    end

    if WaterState.ptfx then
        StopParticleFxLooped(WaterState.ptfx, false)
        WaterState.ptfx = nil
    end
    RenderScriptCams(false, false, 0, true, true)
    if WaterState.cam then DestroyCam(WaterState.cam, false) end
    if WaterState.liquid and DoesEntityExist(WaterState.liquid) then DeleteEntity(WaterState.liquid) end
    if WaterState.pitcher and DoesEntityExist(WaterState.pitcher) then DeleteEntity(WaterState.pitcher) end

    SetNuiFocus(false, false)
    SendNUIMessage({ action = "closeWatering" })
    TriggerEvent("pickle_drugs:showPlots")

    local ped = PlayerPedId()
    FreezeEntityPosition(ped, false)
    SetEntityVisible(ped, true, false)
    DisplayRadar(true)
    DisplayHud(true)
    ClearFocus()

    if not skipFade then
        DoScreenFadeIn(fadeMs)
    end
    WaterState = nil
end

--- Each frame: read NUI cursor, raycast through it to a world position,
--- pull back along camera-forward so the pitcher hangs in front of the
--- camera, set pitcher pose, run pour logic.
local function RunWateringThread()
    CreateThread(function()
        local pourAngle = WaterState.drugCfg.watering.pourAngleDeg or 65.0
        -- Derive pour rate from the configured "seconds per full pitcher"
        -- so a 4-second value drains 100% in exactly 4 seconds of pouring.
        local pourSeconds = WaterState.drugCfg.watering.secondsPerFullPitcher or 4.0
        local pourPerSec = (pourSeconds > 0) and (1.0 / pourSeconds) or 0.25
        local pourPerPlot = WaterState.drugCfg.watering.pourPerPlot or 0.20
        local fxDict = WaterState.drugCfg.watering.partFx and WaterState.drugCfg.watering.partFx.dict
        local fxName = WaterState.drugCfg.watering.partFx and WaterState.drugCfg.watering.partFx.name

        if fxDict then
            RequestNamedPtfxAsset(fxDict)
            local deadline = GetGameTimer() + 2000
            while not HasNamedPtfxAssetLoaded(fxDict) and GetGameTimer() < deadline do Wait(0) end
        end

        local lastTime = GetGameTimer()
        local pourPitch = 0.0           -- A/D adjusts this; 0 = upright
        local pouredOnPlot = 0.0        -- accumulator toward one server pour

        while WaterState do
            DisableAllControlActions(0)
            local nowMs = GetGameTimer()
            local dt = (nowMs - lastTime) / 1000.0
            lastTime = nowMs

            -- Cursor → world ray
            local cx, cy = WaterState.cursorX or 0.5, WaterState.cursorY or 0.5
            local camCoord = GetCamCoord(WaterState.cam)
            local camRot   = GetCamRot(WaterState.cam, 2)
            -- Build a camera-forward vector from the cam rotation; project
            -- a fixed distance ahead, offset horizontally by cursor delta
            -- from screen centre. This avoids needing a real raycast and
            -- keeps the pitcher always reachable without colliding.
            local rx, ry, rz = math.rad(camRot.x), math.rad(camRot.y), math.rad(camRot.z)
            local fx = -math.sin(rz) * math.cos(rx)
            local fy =  math.cos(rz) * math.cos(rx)
            local fz =  math.sin(rx)
            -- Camera-right = world up cross forward.
            local rXx =  math.cos(rz)
            local rXy =  math.sin(rz)
            local rXz =  0.0
            -- Camera-up = right cross forward. Doing forward × right flips
            -- the sign and inverts the Y axis (cursor up → pitcher down).
            local upX = rXy * fz - rXz * fy
            local upY = rXz * fx - rXx * fz
            local upZ = rXx * fy - rXy * fx

            local depth = 1.2 -- metres in front of the camera
            -- 0..1 cursor → -1..1 in screen-space units; scale by depth*tan(fov/2)
            local fovRad = math.rad(38.0)
            local screenH = math.tan(fovRad * 0.5) * depth
            local aspect = GetAspectRatio(false) or 1.777
            local screenW = screenH * aspect
            local sx = (cx - 0.5) * 2.0 * screenW
            local sy = (cy - 0.5) * 2.0 * screenH

            local px = camCoord.x + fx * depth + rXx * sx - upX * sy
            local py = camCoord.y + fy * depth + rXy * sx - upY * sy
            local pz = camCoord.z + fz * depth + rXz * sx - upZ * sy

            SetEntityCoordsNoOffset(WaterState.pitcher, px, py, pz, false, false, false)
            -- A/D adjust pitch.
            local rotateSpeed = 90.0 -- deg/sec
            if WaterState.held and WaterState.held["KeyA"] then
                pourPitch = math.max(-110.0, pourPitch - rotateSpeed * dt)
            end
            if WaterState.held and WaterState.held["KeyD"] then
                pourPitch = math.min( 110.0, pourPitch + rotateSpeed * dt)
            end
            -- Pose the pitcher: keep it facing the camera (heading), apply
            -- the pour pitch on roll so it tilts sideways visibly.
            SetEntityRotation(WaterState.pitcher, 0.0, pourPitch, math.deg(math.atan(fy, fx)) - 90.0, 2, true)

            local pouring = math.abs(pourPitch) >= pourAngle and WaterState.level > 0.0
            if pouring then
                if not WaterState.ptfx and fxDict and HasNamedPtfxAssetLoaded(fxDict) then
                    UseParticleFxAssetNextCall(fxDict)
                    WaterState.ptfx = StartParticleFxLoopedOnEntity(
                        fxName, WaterState.pitcher,
                        0.0, 0.0, 0.05, -- spout offset
                        0.0, 0.0, 0.0,
                        1.0, false, false, false
                    )
                end

                -- Drain pitcher.
                WaterState.level = math.max(0.0, WaterState.level - pourPerSec * dt)
                SetLiquidLevel(WaterState.pitcher, WaterState.liquid, WaterState.drugCfg, WaterState.level)

                -- Does the pour stream actually land in the pot? Raycast
                -- straight down from the pitcher to the spot's coords and
                -- accept any hit close to the plot centre.
                local plotCenter = WaterState.plotCenter
                local horizDist = math.sqrt((px - plotCenter.x)^2 + (py - plotCenter.y)^2)
                if horizDist < 0.45 and pz > plotCenter.z then
                    pouredOnPlot = pouredOnPlot + pourPerSec * dt
                    if pouredOnPlot >= pourPerPlot then
                        pouredOnPlot = 0.0
                        TriggerServerEvent("pickle_drugs:water", WaterState.plotId)
                        SendNUIMessage({ action = "wateringPour", data = { plotId = WaterState.plotId } })
                    end
                end
            else
                if WaterState.ptfx then
                    StopParticleFxLooped(WaterState.ptfx, false)
                    WaterState.ptfx = nil
                end
            end

            -- Push level update to NUI (UI shows water % in the corner).
            SendNUIMessage({ action = "wateringLevel", data = { level = WaterState.level } })

            Wait(0)
        end
    end)
end

--- Public entry. Called by interactions_client when "Water" is selected.
---@param plotId string
function OpenWateringScene(plotId)
    if WaterState then return end
    local plot = GetPlotState(plotId)
    local spot = GetPlotSpot(plotId)
    if not plot or not spot then return end
    local drugCfg = Config.Drugs[plot.drug]
    if not drugCfg or not drugCfg.watering then return end

    -- Optional gate: pitcher item required.
    if drugCfg.pitcherItem and Inventory and Inventory.GetItemCount then
        if Inventory.GetItemCount and Inventory.GetItemCount(drugCfg.pitcherItem) < 1 then
            return
        end
    end

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
    -- Plots stay visible during watering — the player needs to see the pot
    -- they're pouring into. The camera frames just this plot anyway.

    local cam = CreateWateringCam(center, heading, drugCfg)
    local pitcher, liquid = SpawnPitcher(drugCfg, vector3(center.x, center.y, center.z + 1.5))

    WaterState = {
        plotId    = plotId,
        spot      = spot,
        drugCfg   = drugCfg,
        cam       = cam,
        pitcher   = pitcher,
        liquid    = liquid,
        level     = 1.0,
        held      = {},
        cursorX   = 0.5,
        cursorY   = 0.5,
        plotCenter = center,
    }

    SetLiquidLevel(pitcher, liquid, drugCfg, 1.0)

    SetNuiFocus(true, true)
    SendNUIMessage({ action = "openWatering", data = { plotId = plotId, level = 1.0 } })

    DoScreenFadeIn(fadeMs)
    RunWateringThread()
end

-- ─── NUI callbacks ──────────────────────────────────────────────────────────

RegisterNUICallback("wateringClose", function(_, cb)
    CleanupWateringScene()
    cb({ ok = true })
end)

RegisterNUICallback("wateringInput", function(data, cb)
    if not WaterState then cb({ ok = false }) return end
    if data.cursorX and data.cursorY then
        WaterState.cursorX = tonumber(data.cursorX)
        WaterState.cursorY = tonumber(data.cursorY)
    end
    if data.heldKeys then
        WaterState.held = {}
        for _, k in ipairs(data.heldKeys) do WaterState.held[k] = true end
    end
    cb({ ok = true })
end)

AddEventHandler("onResourceStop", function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    -- Synchronous: skip fade so teardown finishes before the resource dies.
    CleanupWateringScene(true)
end)
