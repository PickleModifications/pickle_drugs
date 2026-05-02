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

function GetWateringCamPreset(spot, drugCfg)
    local cfg = drugCfg.watering
    local potHash = joaat("pickle_pot_01")
    local pMin, pMax = GetModelDimensions(potHash)
    local size = math.max(pMax.x - pMin.x, pMax.y - pMin.y, pMax.z - pMin.z, 0.6)
    local fov  = 38.0
    local center  = vector3(spot.coords.x, spot.coords.y, spot.coords.z)
    local heading = spot.coords.w or 0.0
    local aimZ = center.z + (pMin.z + pMax.z) * 0.5 + 0.4
    local distance = (size * 0.5) / math.tan(math.rad(fov) * 0.5) * (cfg.cameraDistMul or 1.4)

    local rad = math.rad(heading)
    local camX = center.x + math.sin(rad) * distance
    local camY = center.y - math.cos(rad) * distance
    local camZ = aimZ + 0.6

    return {
        coords = vector3(camX, camY, camZ),
        point  = vector3(center.x, center.y, aimZ),
        fov    = fov,
    }
end

local function CreateWateringCam(center, heading, drugCfg)
    local pose = GetWateringCamPreset({ coords = vector4(center.x, center.y, center.z, heading) }, drugCfg)
    local cam = CreateCam("DEFAULT_SCRIPTED_CAMERA", true)
    SetCamCoord(cam, pose.coords.x, pose.coords.y, pose.coords.z)
    PointCamAtCoord(cam, pose.point.x, pose.point.y, pose.point.z)
    SetCamFov(cam, pose.fov)
    SetCamActive(cam, true)
    RenderScriptCams(true, false, 0, true, true)
    return cam
end

local function CleanupWateringScene(skipFade)
    if not WaterState then return end
    if WaterState.tearingDown then return end
    WaterState.tearingDown = true

    local embedded = WaterState.embedded
    local onClose  = WaterState.onClose

    if WaterState.pouredOnPlot and WaterState.pouredOnPlot > 0.0 then
        TriggerServerEvent("pickle_drugs:water", WaterState.plotId, WaterState.pouredOnPlot)
        WaterState.pouredOnPlot = 0.0
    end

    local fadeMs = 400
    if not skipFade and not embedded then
        DoScreenFadeOut(fadeMs)
        while not IsScreenFadedOut() do Wait(0) end
    end

    if WaterState.ptfx then
        StopParticleFxLooped(WaterState.ptfx, false)
        WaterState.ptfx = nil
    end
    if WaterState.potPtfx then
        StopParticleFxLooped(WaterState.potPtfx, false)
        WaterState.potPtfx = nil
    end
    if not embedded then
        RenderScriptCams(false, false, 0, true, true)
        if WaterState.cam then DestroyCam(WaterState.cam, false) end
    end
    if WaterState.liquid and DoesEntityExist(WaterState.liquid) then DeleteEntity(WaterState.liquid) end
    if WaterState.pitcher and DoesEntityExist(WaterState.pitcher) then DeleteEntity(WaterState.pitcher) end

    if not embedded then
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
    end
    WaterState = nil
    if onClose then onClose() end
end

function CancelWateringScene()
    if WaterState then CleanupWateringScene(true) end
end

--- Maps NUI cursor X/Y onto the pitcher's world position with no
--- depth-to-camera component — same pattern as the planting capsule
--- drag. Cursor X slides the pitcher along the ground-horizontal axis
--- (camera-right with Z=0); cursor Y moves it purely along world Z.
--- The distance from the camera to the pitcher anchor is therefore
--- constant regardless of where the cursor is on screen.
local function CursorToPitcherPos(cx, cy, fovDeg)
    local anchor   = WaterState.restAnchor
    local camCoord = GetCamCoord(WaterState.cam)
    local camRot   = GetCamRot(WaterState.cam, 2)
    local rz       = math.rad(camRot.z)
    local rXx, rXy = math.cos(rz), math.sin(rz)

    local dx, dy = anchor.x - camCoord.x, anchor.y - camCoord.y
    local depth  = math.max(0.5, math.sqrt(dx * dx + dy * dy))

    local fovRad  = math.rad(fovDeg or 38.0)
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

--- Forward heading (camera→anchor) for posing the pitcher to face camera.
local function CamForwardYawDeg()
    local cam = GetCamCoord(WaterState.cam)
    local a   = WaterState.restAnchor
    return math.deg(math.atan(a.y - cam.y, a.x - cam.x)) - 90.0
end

local function StartPotFx(potEnt)
    local fxDict = WaterState.drugCfg.watering.potFx and WaterState.drugCfg.watering.potFx.dict
    local fxName = WaterState.drugCfg.watering.potFx and WaterState.drugCfg.watering.potFx.name
    if not fxDict or not fxName or not potEnt or WaterState.potPtfx then return end
    if not HasNamedPtfxAssetLoaded(fxDict) then return end
    UseParticleFxAssetNextCall(fxDict)
    -- Emit at the pot's soil surface so the splash/fill reads on top of
    -- the soil rather than under it. The Z offset is configurable.
    local zOff = WaterState.drugCfg.watering.potFxZ or 0.25
    WaterState.potPtfx = StartParticleFxLoopedOnEntity(
        fxName, potEnt,
        0.0, 0.0, zOff,
        0.0, 0.0, 0.0,
        1.0, false, false, false
    )
end

local function StopPotFx()
    if WaterState.potPtfx then
        StopParticleFxLooped(WaterState.potPtfx, false)
        WaterState.potPtfx = nil
    end
end

--- Each frame: read NUI cursor, drive the pitcher pose, run pour logic.
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
        local potFxDict = WaterState.drugCfg.watering.potFx and WaterState.drugCfg.watering.potFx.dict

        if fxDict then
            RequestNamedPtfxAsset(fxDict)
            local deadline = GetGameTimer() + 2000
            while not HasNamedPtfxAssetLoaded(fxDict) and GetGameTimer() < deadline do Wait(0) end
        end
        if potFxDict and potFxDict ~= fxDict then
            RequestNamedPtfxAsset(potFxDict)
            local deadline = GetGameTimer() + 2000
            while not HasNamedPtfxAssetLoaded(potFxDict) and GetGameTimer() < deadline do Wait(0) end
        end

        local lastTime = GetGameTimer()
        local pourPitch = 0.0           -- A/D adjusts this; 0 = upright
        WaterState.pouredOnPlot = 0.0   -- accumulator toward one server pour
        local lastPlantWaterPushMs = 0

        while WaterState do
            DisableAllControlActions(0)
            local nowMs = GetGameTimer()
            local dt = (nowMs - lastTime) / 1000.0
            lastTime = nowMs

            local cx, cy = WaterState.cursorX or 0.5, WaterState.cursorY or 0.5
            local world = CursorToPitcherPos(cx, cy, 38.0)
            SetEntityCoordsNoOffset(WaterState.pitcher, world.x, world.y, world.z, false, false, false)

            local rotateSpeed = 90.0 -- deg/sec
            if WaterState.held and WaterState.held["KeyA"] then
                pourPitch = math.max(-110.0, pourPitch - rotateSpeed * dt)
            end
            if WaterState.held and WaterState.held["KeyD"] then
                pourPitch = math.min( 110.0, pourPitch + rotateSpeed * dt)
            end
            SetEntityRotation(WaterState.pitcher, 0.0, pourPitch, CamForwardYawDeg(), 2, true)

            local pouring = math.abs(pourPitch) >= pourAngle and WaterState.level > 0.0
            local plotCenter = WaterState.plotCenter
            local horizDist  = math.sqrt((world.x - plotCenter.x)^2 + (world.y - plotCenter.y)^2)
            local landingInPot = horizDist < 0.45 and world.z > plotCenter.z

            if pouring then
                if not WaterState.ptfx and fxDict and HasNamedPtfxAssetLoaded(fxDict) then
                    UseParticleFxAssetNextCall(fxDict)
                    WaterState.ptfx = StartParticleFxLoopedOnEntity(
                        fxName, WaterState.pitcher,
                        0.0, 0.0, 0.05,
                        0.0, 0.0, 0.0,
                        1.0, false, false, false
                    )
                end

                WaterState.level = math.max(0.0, WaterState.level - pourPerSec * dt)
                SetLiquidLevel(WaterState.pitcher, WaterState.liquid, WaterState.drugCfg, WaterState.level)

                if landingInPot then
                    StartPotFx(WaterState.potEntity)
                    local inc = pourPerSec * dt
                    WaterState.pouredOnPlot = (WaterState.pouredOnPlot or 0) + inc
                    -- pourPerPlot is in pitcher-fraction terms, but the
                    -- server adds `cap * pourPerPlot` ms — so 1 pitcher
                    -- fraction == 1 plant capacity fraction here.
                    if WaterState.hasPlant then
                        WaterState.plantLevelAdded = (WaterState.plantLevelAdded or 0) + inc
                    end
                    if WaterState.pouredOnPlot >= pourPerPlot then
                        TriggerServerEvent("pickle_drugs:water", WaterState.plotId, pourPerPlot)
                        SendNUIMessage({ action = "wateringPour", data = { plotId = WaterState.plotId } })
                        WaterState.pouredOnPlot = WaterState.pouredOnPlot - pourPerPlot
                    end
                else
                    StopPotFx()
                end
            else
                if WaterState.ptfx then
                    StopParticleFxLooped(WaterState.ptfx, false)
                    WaterState.ptfx = nil
                end
                StopPotFx()
            end

            -- Pitcher level: per-frame, since it's purely local.
            SendNUIMessage({ action = "wateringLevel", data = { level = WaterState.level } })

            -- Plant water bar: drive entirely off the local accumulator
            -- seeded at scene open. Mixing the server-confirmed level
            -- with `pouredOnPlot` caused the bar to jitter around the
            -- pour-confirmation echo (server tick lags client by a few
            -- frames, and the accumulator resets just before the echo
            -- arrives — so the visible level briefly drops back to the
            -- old value). Local-only state is monotonic and matches the
            -- player's input directly. The server still gets its pour
            -- events for persistence; we just ignore the server's level
            -- for the duration of this scene.
            if nowMs - lastPlantWaterPushMs > 33 then
                lastPlantWaterPushMs = nowMs
                if WaterState.hasPlant then
                    local localLevel = math.max(
                        0.0,
                        math.min(1.0, (WaterState.plantLevelStart or 0)
                            + (WaterState.plantLevelAdded or 0))
                    )
                    SendNUIMessage({
                        action = "wateringPlantLevel",
                        data   = { level = localLevel, show = true },
                    })
                else
                    SendNUIMessage({
                        action = "wateringPlantLevel",
                        data   = { level = 0, show = false },
                    })
                end
            end

            Wait(0)
        end
    end)
end

--- Public entry. Called by interactions_client when "Water" is selected.
---@param plotId string
function OpenWateringScene(plotId, opts)
    if WaterState then return end
    opts = opts or {}
    local embedded = opts.embedded == true

    local plot = GetPlotState(plotId)
    local spot = GetPlotSpot(plotId)
    if not plot or not spot then return end
    local drugCfg = Config.Drugs[plot.drug]
    if not drugCfg or not drugCfg.watering then return end

    -- Pre-flight item check now lives in plant_scene/client.lua's
    -- StartAction, gated on a server-side count callback; this scene
    -- assumes the caller has already verified the player holds the
    -- watering pitcher.

    local center = vector3(spot.coords.x, spot.coords.y, spot.coords.z)
    local heading = spot.coords.w or 0.0
    local fadeMs = 400

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

    local cam = embedded and opts.cam or CreateWateringCam(center, heading, drugCfg)
    local pitcher, liquid = SpawnPitcher(drugCfg, vector3(center.x, center.y, center.z + 1.5))

    -- Pitcher's anchor when cursor is centred — just above the pot rim
    -- with enough clearance for a tilt to pour without clipping. Matches
    -- the planting capsule rest height so the framing reads the same.
    local restAnchor = vector3(center.x, center.y, center.z + 0.5)

    -- Snapshot the plant's water level once so the watering UI can
    -- drive its bar from a local accumulator. Anything the server does
    -- with water during the scene is ignored for display purposes —
    -- the bar only reflects what the player has poured.
    local epochMs    = GetCloudTimeAsInt() * 1000
    local harvest    = Grow.HarvestStage(drugCfg)
    local hasPlant   = (plot.stage or 0) >= 1 and (plot.stage or 0) <= harvest - 1
    local startLevel = hasPlant and Grow.WaterLevel(plot, drugCfg, epochMs) or 0.0

    WaterState = {
        plotId           = plotId,
        spot             = spot,
        drugCfg          = drugCfg,
        cam              = cam,
        pitcher          = pitcher,
        liquid           = liquid,
        level            = 1.0,
        held             = {},
        cursorX          = 0.5,
        cursorY          = 0.5,
        plotCenter       = center,
        restAnchor       = restAnchor,
        potEntity        = GetPlotPotEntity and GetPlotPotEntity(plotId) or nil,
        hasPlant         = hasPlant,
        plantLevelStart  = startLevel,
        plantLevelAdded  = 0.0,
        embedded         = embedded,
        onClose          = opts.onClose,
    }

    SetLiquidLevel(pitcher, liquid, drugCfg, 1.0)

    if not embedded then
        SetNuiFocus(true, true)
        SendNUIMessage({ action = "openWatering", data = { plotId = plotId, level = 1.0 } })
        DoScreenFadeIn(fadeMs)
    else
        SendNUIMessage({ action = "wateringLevel", data = { level = 1.0 } })
    end
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
