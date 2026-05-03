-- Unified "Interact with Plant" scene controller.
--
-- Owns one scripted camera, an NUI overlay (status panel + collapsible
-- taskbar of available actions), and dispatches each picked action by
-- tweening the cam to that action's framing and opening the existing
-- soiling / planting / watering / cutting scene in *embedded* mode (no
-- fade, no ped/hud toggle, no own camera — it borrows ours).
--
-- The scene stays alive across multiple sub-actions; on each cleanup we
-- tween back to the menu pose and reopen the menu UI.

local Scene = nil
-- Scene = {
--   plotId, spot, plot, drugCfg,
--   cam,
--   currentPose = { coords, point, fov },
--   tween       = { startMs, durMs, from, to, onDone } | nil,
--   activeAction = "menu" | "soiling" | "planting" | "watering" | "cutting",
--   activeCancel = function | nil, -- forces the active sub-scene to tear down
--   tearingDown,
-- }

local TWEEN_MS = 600

-- ─── Math helpers ──────────────────────────────────────────────────────────

local function lerp(a, b, t) return a + (b - a) * t end

local function lerpVec(a, b, t)
    return vector3(lerp(a.x, b.x, t), lerp(a.y, b.y, t), lerp(a.z, b.z, t))
end

local function easeInOut(t)
    if t <= 0 then return 0 end
    if t >= 1 then return 1 end
    if t < 0.5 then return 2.0 * t * t end
    local x = -2.0 * t + 2.0
    return 1.0 - 0.5 * x * x
end

-- ─── Camera presets ────────────────────────────────────────────────────────

local function MenuPreset(spot)
    local center  = vector3(spot.coords.x, spot.coords.y, spot.coords.z)
    local heading = spot.coords.w or 0.0
    local rad     = math.rad(heading)
    local cam     = (Config.PlantScene and Config.PlantScene.menuCam) or {}
    local distance = cam.distance or 2.6
    return {
        coords = vector3(
            center.x + math.sin(rad) * distance,
            center.y - math.cos(rad) * distance,
            center.z + (cam.camZ or 1.45)),
        point = vector3(center.x, center.y, center.z + (cam.lookZ or 0.75)),
        fov   = cam.fov or 40.0,
    }
end

local function PresetForAction(action)
    if not Scene then return nil end
    local spot    = Scene.spot
    local drugCfg = Scene.drugCfg
    if action == "menu"     then return MenuPreset(spot) end
    if action == "soiling"  and GetSoilingCamPreset  then return GetSoilingCamPreset(spot, drugCfg) end
    if action == "planting" and GetPlantingCamPreset then return GetPlantingCamPreset(spot, drugCfg) end
    if action == "watering" and GetWateringCamPreset then return GetWateringCamPreset(spot, drugCfg) end
    if action == "cutting"  and GetCuttingCamPreset  then return GetCuttingCamPreset(spot, drugCfg) end
    return MenuPreset(spot)
end

local function ApplyPose(cam, pose)
    SetCamCoord(cam, pose.coords.x, pose.coords.y, pose.coords.z)
    PointCamAtCoord(cam, pose.point.x, pose.point.y, pose.point.z)
    SetCamFov(cam, pose.fov)
end

local function StartTween(toPose, durMs, onDone)
    if not Scene or not Scene.cam or not toPose then
        if onDone then onDone() end
        return
    end
    Scene.tween = {
        startMs = GetGameTimer(),
        durMs   = durMs or TWEEN_MS,
        from    = Scene.currentPose or toPose,
        to      = toPose,
        onDone  = onDone,
    }
end

-- ─── Status / actions snapshots ────────────────────────────────────────────

local function StageDurationMs(drugCfg, stage)
    local mul = (Config and Config.GrowTimeMultiplier) or 1.0
    local harvest = Grow.HarvestStage(drugCfg)
    local growingCount = harvest - 1
    if drugCfg.totalGrowMs and drugCfg.totalGrowMs > 0 and growingCount > 0
        and stage >= 1 and stage <= harvest - 1 then
        return (drugCfg.totalGrowMs / growingCount) * mul
    end
    return 0
end

local function ComputeGrowProgress(plot, drugCfg)
    local harvest = Grow.HarvestStage(drugCfg)
    if (plot.stage_started_at or 0) == 0 then return 0.0 end
    local probe = {
        stage            = plot.stage,
        stage_started_at = plot.stage_started_at,
        water_until      = plot.water_until,
    }
    local now = GetCloudTimeAsInt() * 1000
    Grow.ResolveStage(probe, drugCfg, now)
    if probe.stage >= harvest then return 1.0 end
    local total = 0
    for s = 1, harvest - 1 do total = total + StageDurationMs(drugCfg, s) end
    if total <= 0 then return 1.0 end
    local elapsed = 0
    for s = 1, probe.stage - 1 do elapsed = elapsed + StageDurationMs(drugCfg, s) end
    local effectiveNow = math.min(now, probe.water_until or 0)
    local sinceStage = effectiveNow - (probe.stage_started_at or 0)
    local cap = StageDurationMs(drugCfg, probe.stage)
    elapsed = elapsed + math.max(0, math.min(sinceStage, cap))
    return math.max(0.0, math.min(1.0, elapsed / total))
end

local function ComputeStatusKey(plot, drugCfg)
    if (plot.soil_added_at or 0) == 0 then return "needs_soil" end
    if (plot.stage_started_at or 0) == 0 then return "ready_plant" end
    local harvest = Grow.HarvestStage(drugCfg)
    if plot.stage == harvest then
        if #Grow.RemainingBudIndexes(plot, drugCfg) > 0 then return "ready_harvest" end
        return "growing"
    end
    local now = GetCloudTimeAsInt() * 1000
    if (plot.water_until or 0) <= now then return "needs_water" end
    return "growing"
end

local function ComputeEtaMs(plot, drugCfg)
    if (plot.stage_started_at or 0) == 0 then return nil end
    local harvest = Grow.HarvestStage(drugCfg)
    if plot.stage >= harvest then return 0 end
    local now = GetCloudTimeAsInt() * 1000
    local water = plot.water_until or 0
    if water <= now then return nil end
    local stageDur = StageDurationMs(drugCfg, plot.stage)
    if stageDur <= 0 then return 0 end
    local elapsed = math.max(0, now - (plot.stage_started_at or 0))
    local left = stageDur - elapsed
    if left < 0 then left = 0 end
    if water - now < left then left = water - now end
    return left
end

--- Item the player needs to perform `action` on `drugCfg`. The plant
--- scene doesn't know what each sub-flow consumes; this is the single
--- source of truth so ComputeActions / StartAction / RefreshItemCounts
--- all agree. Returns nil if the action has no item gate.
local function RequiredItem(action, drugCfg)
    if action == "soiling" then
        local n = Config.Items and Config.Items.soilBag
        if n then return { name = n, count = 1, label = "bag of soil" } end
    elseif action == "planting" then
        local n = drugCfg and drugCfg.seedItem
        if n then return { name = n, count = 1, label = "seed" } end
    elseif action == "watering" then
        local n = Config.Items and Config.Items.wateringCan
        if n then return { name = n, count = 1, label = "watering pitcher" } end
    elseif action == "cutting" then
        local n = Config.Items and Config.Items.scissors
        if n then return { name = n, count = 1, label = "trimming scissors" } end
    end
    return nil
end

--- Returns true if `Scene.itemCounts` shows enough of `action`'s item.
--- Treats a missing entry as "not yet fetched" → optimistic true so the
--- buttons aren't briefly greyed-out on scene open before the first
--- callback returns.
local function PlayerHasItemFor(action, drugCfg)
    local need = RequiredItem(action, drugCfg)
    if not need then return true, nil end
    if not Scene then return true, need end
    local counts = Scene.itemCounts
    if not counts or counts[need.name] == nil then return true, need end
    return counts[need.name] >= need.count, need
end

local function ComputeActions(plot, drugCfg)
    local harvest = Grow.HarvestStage(drugCfg)
    local now = GetCloudTimeAsInt() * 1000

    local needsSoil    = (plot.soil_added_at or 0) == 0
    local needsSeed    = not needsSoil and (plot.stage_started_at or 0) == 0
    local growing      = (plot.stage_started_at or 0) > 0 and plot.stage < harvest
    local atHarvest    = plot.stage == harvest
    local hasBuds      = atHarvest and #Grow.RemainingBudIndexes(plot, drugCfg) > 0
    local waterFull    = Grow.WaterLevel(plot, drugCfg, now) >= 0.999

    local function reason(text) return text end

    -- "Need <label>" overrides every other reason: a player who hasn't
    -- got the item should see *that* first, since fixing it (going to
    -- pick up the consumable) is the actionable step.
    local function gate(action, baseAvailable, baseReason)
        if not baseAvailable then return baseAvailable, baseReason end
        local ok, need = PlayerHasItemFor(action, drugCfg)
        if not ok and need then
            return false, reason("Need " .. need.label)
        end
        return baseAvailable, baseReason
    end

    local ps = Config.PlantScene or {}
    local soilingOk,  soilingReason  = gate("soiling",
        needsSoil and ps.soiling ~= nil,
        (not needsSoil) and reason("Already soiled") or nil)
    local plantingOk, plantingReason = gate("planting",
        needsSeed and ps.planting ~= nil,
        needsSoil and reason("Needs soil first")
            or (not needsSeed) and reason("Already planted")
            or nil)
    local wateringOk, wateringReason = gate("watering",
        (growing or (atHarvest and not waterFull)) and not waterFull and (growing or atHarvest) and ps.watering ~= nil,
        (not (growing or atHarvest)) and reason("No plant yet")
            or waterFull and reason("Reservoir full")
            or nil)
    local cuttingOk,  cuttingReason  = gate("cutting",
        hasBuds and ps.cutting ~= nil,
        (not atHarvest) and reason("Not ready to harvest")
            or (atHarvest and not hasBuds) and reason("All buds cut")
            or nil)

    return {
        {
            id = "soiling",
            label = "Add Soil",
            icon = "mound",
            available = soilingOk,
            reason = soilingReason,
        },
        {
            id = "planting",
            label = "Plant Seed",
            icon = "sprout",
            available = plantingOk,
            reason = plantingReason,
        },
        {
            id = "watering",
            label = "Water Plant",
            icon = "droplet",
            available = wateringOk,
            reason = wateringReason,
        },
        {
            id = "cutting",
            label = "Harvest",
            icon = "scissors",
            available = cuttingOk,
            reason = cuttingReason,
        },
        -- "settings = true" tells the NUI plant console to bucket these
        -- under a single Gear "Settings" button instead of rendering them
        -- inline, so the main row stays focused on grow actions.
        {
            id = "move",
            label = "Move",
            icon = "move",
            available = true,
            reason = nil,
            settings = true,
        },
        {
            id = "output",
            label = "Destination",
            icon = "package",
            available = true,
            reason = nil,
            settings = true,
        },
        {
            id = "remove",
            label = "Remove",
            icon = "trash",
            available = true,
            reason = nil,
            settings = true,
        },
    }
end

local function PushSnapshot()
    if not Scene then return end
    local plot = GetPlotState(Scene.plotId)
    if not plot then return end
    Scene.plot = plot
    local drugCfg = Scene.drugCfg
    local now = GetCloudTimeAsInt() * 1000
    local harvest = Grow.HarvestStage(drugCfg)
    local statusKey = ComputeStatusKey(plot, drugCfg)
    local growProgress = ComputeGrowProgress(plot, drugCfg)
    local waterProgress = Grow.WaterLevel(plot, drugCfg, now)
    local showWater = plot.stage >= 1 and plot.stage <= harvest - 1
    local budsLeft = #Grow.RemainingBudIndexes(plot, drugCfg)

    SendNUIMessage({
        action = "plantSceneStatus",
        data = {
            drug          = drugCfg.label or plot.drug,
            statusKey     = statusKey,
            stage         = plot.stage,
            stageMax      = harvest,
            growProgress  = growProgress,
            waterProgress = waterProgress,
            showWater     = showWater,
            budsLeft      = budsLeft,
            etaMs         = ComputeEtaMs(plot, drugCfg),
            activeAction  = Scene.activeAction,
            actions       = ComputeActions(plot, drugCfg),
        },
    })
end

--- Async refresh of Scene.itemCounts for every action that has an item
--- gate. Fire-and-forget — the next PushSnapshot picks up the new
--- counts. Server is the authority; this is purely UX.
local function RefreshItemCounts()
    if not Scene then return end
    local drugCfg = Scene.drugCfg
    local needed, seen = {}, {}
    for _, action in ipairs({ "soiling", "planting", "watering", "cutting" }) do
        local need = RequiredItem(action, drugCfg)
        if need and not seen[need.name] then
            seen[need.name] = true
            needed[#needed + 1] = need.name
        end
    end
    if #needed == 0 then
        Scene.itemCounts = {}
        return
    end
    CreateThread(function()
        local counts = lib.callback.await("pickle_drugs:getItemCounts", false, needed)
        if not Scene then return end
        Scene.itemCounts = counts or {}
        PushSnapshot()
    end)
end

-- ─── Threads ───────────────────────────────────────────────────────────────

local function StartCamThread()
    CreateThread(function()
        local lastMs = GetGameTimer()
        while Scene do
            local nowMs = GetGameTimer()
            local dt = (nowMs - lastMs) / 1000.0
            lastMs = nowMs

            if Scene.tween then
                local t = (nowMs - Scene.tween.startMs) / Scene.tween.durMs
                if t >= 1 then
                    ApplyPose(Scene.cam, Scene.tween.to)
                    Scene.currentPose = Scene.tween.to
                    local cb = Scene.tween.onDone
                    Scene.tween = nil
                    if cb then cb() end
                else
                    local e = easeInOut(t)
                    local from, to = Scene.tween.from, Scene.tween.to
                    local pose = {
                        coords = lerpVec(from.coords, to.coords, e),
                        point  = lerpVec(from.point,  to.point,  e),
                        fov    = lerp(from.fov, to.fov, e),
                    }
                    ApplyPose(Scene.cam, pose)
                    Scene.currentPose = pose
                end
            end

            Wait(0)
        end
    end)
end

local function StartStatusThread()
    CreateThread(function()
        while Scene do
            PushSnapshot()
            Wait(250)
        end
    end)
end

-- ─── Action dispatch ───────────────────────────────────────────────────────

local function ReturnToMenu()
    if not Scene then return end
    Scene.activeAction = "menu"
    Scene.activeCancel = nil
    -- A sub-scene just closed — the server may have consumed soil /
    -- seed / harvest scissors etc. Re-pull counts so the menu reflects
    -- the new state without a manual refresh.
    RefreshItemCounts()
    PushSnapshot()
    StartTween(MenuPreset(Scene.spot), TWEEN_MS, function()
        PushSnapshot()
    end)
end

-- Forward-declared as a global so other modules (housing's MovePlot) can
-- invoke it. StartAction's "move" / "remove" branches use it too; their
-- closures resolve it as an upvalue / global at call time.
ClosePlantScene = nil

local function StartAction(action)
    if not Scene or Scene.activeAction ~= "menu" then return end
    if Scene.tween then return end

    -- Move/Remove are management actions, not in-scene mini-flows: they
    -- close the plant scene first, then defer to housing (move) or fire
    -- the player-facing delete (remove). Server validates authorisation.
    if action == "move" then
        local hid = Scene.plot and Scene.plot.house_id
        local plotId = Scene.plotId
        if hid then
            ClosePlantScene()
            TriggerEvent("pickle_drugs:movePlotInScene", plotId, hid)
        end
        return
    end
    if action == "remove" then
        local plotId = Scene.plotId
        ClosePlantScene()
        TriggerServerEvent("pickle_drugs:deleteHousePlot", plotId)
        return
    end
    if action == "output" then
        -- Output destination uses the same in-world picker style as the
        -- worker plot assigner — close the scene first, then defer to
        -- housing for the locker pick. Server validates ownership when
        -- it receives the eventual setPlotOutput.
        local hid = Scene.plot and Scene.plot.house_id
        local plotId = Scene.plotId
        local currentOutput = Scene.plot and Scene.plot.output_locker_id or nil
        if hid then
            ClosePlantScene()
            TriggerEvent("pickle_drugs:openOutputPickerInScene", plotId, hid, currentOutput)
        end
        return
    end

    local preset = PresetForAction(action)
    if not preset then return end

    local plot = GetPlotState(Scene.plotId)
    if not plot then return end
    local actions = ComputeActions(plot, Scene.drugCfg)
    local available, denyReason = false, nil
    for _, a in ipairs(actions) do
        if a.id == action then
            available = a.available
            denyReason = a.reason
            break
        end
    end
    if not available then
        -- Show why — most often "Need <item>". If state-only (e.g.
        -- "Already soiled") we still surface it so the click isn't
        -- silently swallowed.
        if denyReason then
            lib.notify({ title = "Plant", description = denyReason, type = "error" })
        end
        return
    end

    -- Re-check the item gate against the latest cached counts: a slow
    -- callback might have left ComputeActions optimistic. The server is
    -- still authoritative, but we can save a wasted scene tween.
    local hasItem, need = PlayerHasItemFor(action, Scene.drugCfg)
    if not hasItem and need then
        lib.notify({ title = "Plant", description = "Need " .. need.label, type = "error" })
        RefreshItemCounts()
        return
    end

    -- Flip the active action immediately so the NUI taskbar highlights the
    -- chosen button on click. The actual scene props/input only spin up
    -- once the camera tween finishes.
    Scene.activeAction = action
    PushSnapshot()

    StartTween(preset, TWEEN_MS, function()
        if not Scene or Scene.activeAction ~= action then return end
        local opts = {
            embedded = true,
            cam      = Scene.cam,
            onClose  = function()
                if not Scene then return end
                ReturnToMenu()
            end,
        }
        if action == "soiling"  and OpenSoilingScene  then OpenSoilingScene(Scene.plotId, opts);  Scene.activeCancel = CancelSoilingScene end
        if action == "planting" and OpenPlantingScene then OpenPlantingScene(Scene.plotId, opts); Scene.activeCancel = CancelPlantingScene end
        if action == "watering" and OpenWateringScene then OpenWateringScene(Scene.plotId, opts); Scene.activeCancel = CancelWateringScene end
        if action == "cutting"  and OpenCuttingScene  then OpenCuttingScene(Scene.plotId, opts);  Scene.activeCancel = CancelCuttingScene end
    end)
end

local function CancelActiveAction()
    if not Scene then return end
    if Scene.activeAction == "menu" then return end
    local fn = Scene.activeCancel
    Scene.activeCancel = nil
    if fn then fn() end -- the embedded cleanup invokes our onClose → ReturnToMenu
end

-- ─── Open / close ──────────────────────────────────────────────────────────

function OpenPlantScene(plotId)
    if Scene then return end
    local plot = GetPlotState(plotId)
    local spot = GetPlotSpot(plotId)
    if not plot or not spot then return end
    local drugCfg = Config.Drugs[plot.drug]
    if not drugCfg then return end

    DoScreenFadeOut(400)
    while not IsScreenFadedOut() do Wait(0) end

    local ped = PlayerPedId()
    FreezeEntityPosition(ped, true)
    SetEntityVisible(ped, false, false)
    DisplayRadar(false)
    DisplayHud(false)
    SetFocusArea(spot.coords.x, spot.coords.y, spot.coords.z, 0.0, 0.0, 0.0)

    local cam = CreateCam("DEFAULT_SCRIPTED_CAMERA", true)
    SetCamActive(cam, true)
    RenderScriptCams(true, false, 0, true, true)

    Scene = {
        plotId       = plotId,
        spot         = spot,
        plot         = plot,
        drugCfg      = drugCfg,
        cam          = cam,
        activeAction = "menu",
    }

    local pose = MenuPreset(spot)
    ApplyPose(cam, pose)
    Scene.currentPose = pose

    SetNuiFocus(true, true)
    SendNUIMessage({
        action = "openPlantScene",
        data   = { plotId = plotId, drug = drugCfg.label or plot.drug },
    })
    PushSnapshot()
    RefreshItemCounts()
    DoScreenFadeIn(400)

    StartCamThread()
    StartStatusThread()
end

ClosePlantScene = function(skipFade)
    if not Scene then return end
    if Scene.tearingDown then return end
    Scene.tearingDown = true

    if Scene.activeCancel then
        local fn = Scene.activeCancel
        Scene.activeCancel = nil
        fn()
    end

    if not skipFade then
        DoScreenFadeOut(400)
        while not IsScreenFadedOut() do Wait(0) end
    end

    RenderScriptCams(false, false, 0, true, true)
    if Scene.cam then DestroyCam(Scene.cam, false) end

    SetNuiFocus(false, false)
    SendNUIMessage({ action = "closePlantScene" })

    local ped = PlayerPedId()
    FreezeEntityPosition(ped, false)
    SetEntityVisible(ped, true, false)
    DisplayRadar(true)
    DisplayHud(true)
    ClearFocus()

    if not skipFade then DoScreenFadeIn(400) end
    Scene = nil
end

-- ─── NUI callbacks ─────────────────────────────────────────────────────────

RegisterNUICallback("plantSceneSelect", function(data, cb)
    if data and type(data.action) == "string" then
        StartAction(data.action)
    end
    cb({ ok = true })
end)

RegisterNUICallback("plantSceneCancelAction", function(_, cb)
    CancelActiveAction()
    cb({ ok = true })
end)

RegisterNUICallback("plantSceneClose", function(_, cb)
    if Scene and Scene.activeAction == "menu" then
        ClosePlantScene()
    end
    cb({ ok = true })
end)

-- ─── Public API ────────────────────────────────────────────────────────────

function IsPlantSceneActive()
    return Scene ~= nil
end

function GetPlantSceneActiveAction()
    return Scene and Scene.activeAction or nil
end

AddEventHandler("onResourceStop", function(rn)
    if rn ~= GetCurrentResourceName() then return end
    ClosePlantScene(true)
end)
