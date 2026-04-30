-- Renders every plot in the world. Subscribes to plot updates from the
-- server, despawns the previous prop set for that plot, and respawns the
-- right combo for the resolved stage. Also exposes hide/show events the
-- cutting + watering scenes use to swap the world view for their own.

local PlotState = {}    -- plotId → { spot, plot, entities = { pot, soil, capsule={a,b,c}, plant, buds=[] } }
local PlotsHidden = false

-- Forward declaration: AttachTarget is defined further down (it depends on
-- BuildTargetOptions which depends on the public scene-open functions),
-- but ApplyPlotState calls it on first render so the ox_target zone is
-- bound to the plot exactly once. Subsequent diff-driven updates leave the
-- existing zone alone — coords never change and canInteract reads live
-- state, so re-attaching would be wasted work.
local AttachTarget

local function SpawnWorldProp(model, coords, heading)
    local hash = LoadModel(model)
    if not hash then return nil end
    local obj = CreateObject(hash, coords.x, coords.y, coords.z, false, false, false)
    if not obj or not DoesEntityExist(obj) then
        SetModelAsNoLongerNeeded(hash)
        return nil
    end
    SetEntityCoordsNoOffset(obj, coords.x, coords.y, coords.z, false, false, false)
    SetEntityHeading(obj, heading)
    FreezeEntityPosition(obj, true)
    SetEntityInvincible(obj, true)
    SetModelAsNoLongerNeeded(hash)
    return obj
end

--- Yields every entity tracked under PlotState[plotId].entities.
local function eachEntity(entities)
    return coroutine.wrap(function()
        if not entities then return end
        for k, v in pairs(entities) do
            if k == "buds" or k == "capsule" or k == "rubble" then
                for _, e in pairs(v) do coroutine.yield(e) end
            else
                coroutine.yield(v)
            end
        end
    end)
end

local function DespawnPlot(plotId)
    local s = PlotState[plotId]
    if not s then return end
    if s.entities then
        for ent in eachEntity(s.entities) do
            if ent and DoesEntityExist(ent) then DeleteEntity(ent) end
        end
        s.entities = nil
    end
    if s.targetZoneId and GetResourceState("ox_target") == "started" then
        exports.ox_target:removeZone(s.targetZoneId)
        s.targetZoneId = nil
    end
end

--- Sets visibility + collision on all of a plot's entities. Used by cutting
--- / watering scenes to hide the world copy while their camera scenes run.
local function SetPlotVisible(plotId, visible)
    local s = PlotState[plotId]
    if not s or not s.entities then return end
    for ent in eachEntity(s.entities) do
        if ent and DoesEntityExist(ent) then
            SetEntityVisible(ent, visible, false)
            SetEntityCollision(ent, visible, visible)
        end
    end
end

--- Ensures pot + soil exist. They never change across stages so we spawn
--- them once and leave them alone for the lifetime of the plot.
local function syncBaseProps(s, center, heading)
    if not s.entities.pot or not DoesEntityExist(s.entities.pot) then
        s.entities.pot = SpawnWorldProp("pickle_pot_01", center, heading)
    end
    if not s.entities.soil or not DoesEntityExist(s.entities.soil) then
        s.entities.soil = SpawnWorldProp("pickle_soil_01", center, heading)
    end
end

--- Adds/removes the capsule trio. With the interactive planting scene
--- enabled (drugCfg.planting set), capsule visuals are owned entirely by
--- modules/planting/client during the plant flow and are never drawn here
--- — the scene fires `pickle_drugs:plant` only after the seed has already
--- been "buried" client-side, so a static capsule on the soil afterwards
--- would be a duplicate.
local function syncCapsule(s, plot, drugCfg, center, heading)
    if drugCfg.planting then
        -- Drop any capsule entities lingering from a pre-planting-scene
        -- save and never spawn them.
        for _, e in pairs(s.entities.capsule) do
            if e and DoesEntityExist(e) then DeleteEntity(e) end
        end
        s.entities.capsule = {}
        return
    end

    local need = plot.stage == 1 and (plot.stage_started_at or 0) > 0 and drugCfg.capsule
    local have = s.entities.capsule.capsule and DoesEntityExist(s.entities.capsule.capsule)
    if need and not have then
        local c = drugCfg.capsule
        s.entities.capsule.capsule = SpawnWorldProp(c.capsule, center, heading)
        s.entities.capsule.cap     = SpawnWorldProp(c.cap, center, heading)
        s.entities.capsule.seed    = SpawnWorldProp(c.seed, center, heading)
    elseif not need and have then
        for _, e in pairs(s.entities.capsule) do
            if e and DoesEntityExist(e) then DeleteEntity(e) end
        end
        s.entities.capsule = {}
    end
end

--- Soil rubble pile. Spawned once the plot is planted (stage_started_at >
--- 0) and removed when the plot is reset back to "needs planting". The
--- layout mirrors the planting scene's converged ring — same count, same
--- angular spacing, same residual radius (5% of the spawn radius after
--- the planting animation closes to 95%) — so the persistent pile reads
--- identical to what the player just clicked into place.
local function syncRubble(s, plot, drugCfg, center, _heading)
    s.entities.rubble = s.entities.rubble or {}
    local cfg  = drugCfg.planting
    local need = cfg and cfg.rubble and (plot.stage_started_at or 0) > 0
    local count = (cfg and cfg.rubbleCount) or 4
    local zOff = (cfg and cfg.rubbleSoilZ) or 0.0

    if not need then
        for i, e in ipairs(s.entities.rubble) do
            if e and DoesEntityExist(e) then DeleteEntity(e) end
            s.entities.rubble[i] = nil
        end
        return
    end

    -- Same spawn-ring radius and convergence factor as the planting
    -- scene — residual radius is `(1 - K) * rubbleRadius`.
    local spawnRadius = cfg.rubbleRadius or 0.09
    local k           = cfg.rubbleConvergeK or 0.95
    local residual    = spawnRadius * (1.0 - k)

    -- Mirror modules/planting/client → SpawnRubbleRing exactly.
    local hash = LoadModel(cfg.rubble)
    if not hash then return end

    for i = 1, count do
        local theta = (i - 1) * (2.0 * math.pi / count)
        local x = center.x + math.cos(theta) * residual
        local y = center.y + math.sin(theta) * residual
        local z = center.z + zOff

        local cur = s.entities.rubble[i]
        if not cur or not DoesEntityExist(cur) then
            local ent = CreateObjectNoOffset(hash, x, y, z, false, false, false)
            if ent and DoesEntityExist(ent) then
                SetEntityCollision(ent, true, false)
                FreezeEntityPosition(ent, true)
                s.entities.rubble[i] = ent
            end
        end
    end
    -- Trim any extras if the configured count shrunk.
    for i = count + 1, #s.entities.rubble do
        local e = s.entities.rubble[i]
        if e and DoesEntityExist(e) then DeleteEntity(e) end
        s.entities.rubble[i] = nil
    end
end

--- Swaps the plant entity only when the target stage's model differs. Hash
--- comparison keeps stage-1→stage-2 transitions from no-op'ing the world
--- prop unnecessarily, but a same-stage update (e.g. water_count tick) is
--- a true no-op.
local function syncPlant(s, plot, drugCfg, center, heading)
    local stageCfg    = drugCfg.stages[plot.stage]
    local targetModel = (plot.stage >= 1 and stageCfg) and stageCfg.model or nil
    local targetHash  = targetModel and joaat(targetModel) or nil

    local current = s.entities.plant
    local currentHash
    if current and DoesEntityExist(current) then
        currentHash = GetEntityModel(current)
    end

    if currentHash == targetHash then return end

    if current and DoesEntityExist(current) then
        DeleteEntity(current)
        s.entities.plant = nil
    end
    if targetModel then
        s.entities.plant = SpawnWorldProp(targetModel, center, heading)
    end
end

--- Spawns missing buds, despawns cut ones. At stages other than 3 every
--- bud entity is removed. Each bud is attached to the current plant entity
--- — so a plant swap (handled in syncPlant) effectively orphans them and
--- this function rebuilds the set on the next call.
local function syncBuds(s, plot, drugCfg, center, heading)
    local harvest  = Grow.HarvestStage(drugCfg)
    local stage3   = plot.stage == harvest and drugCfg.stages[harvest] or nil
    local budsCfg  = stage3 and stage3.buds

    if not budsCfg or not s.entities.plant or not DoesEntityExist(s.entities.plant) then
        for i, e in pairs(s.entities.buds) do
            if e and DoesEntityExist(e) then DeleteEntity(e) end
            s.entities.buds[i] = nil
        end
        return
    end

    local cut = {}
    for _, idx in ipairs(plot.cut_buds or {}) do cut[idx] = true end

    -- Despawn buds that have just been cut (server broadcast, possibly from
    -- another client). The cutting scene's TakePlotBudEntity already nilled
    -- the entry locally, so this only fires for remote-initiated cuts.
    for i, e in pairs(s.entities.buds) do
        if cut[i] and e and DoesEntityExist(e) then
            DeleteEntity(e)
            s.entities.buds[i] = nil
        end
    end

    -- Spawn any bud slot that should be present but isn't.
    for i, off in ipairs(budsCfg.offsets) do
        if not cut[i] and (not s.entities.buds[i] or not DoesEntityExist(s.entities.buds[i])) then
            local bud = SpawnWorldProp(budsCfg.model, center, heading)
            if bud then
                SetEntityCollision(bud, false, false)
                AttachEntityToEntity(bud, s.entities.plant, 0,
                    off.x or 0.0, off.y or 0.0, off.z or 0.0,
                    0.0, 0.0, 0.0,
                    false, false, false, false, 2, true)
                s.entities.buds[i] = bud
            end
        end
    end
end

--- Diff-driven plot renderer. Replaces the old "despawn + respawn
--- everything on every plot:update" approach: each helper above only
--- touches its own slice of entities and only when the target state
--- differs from what's already in the world. ox_target attaches once via
--- AttachTarget on first render — coords never change, canInteract reads
--- live state, so no re-attach is needed on subsequent updates.
local function ApplyPlotState(spot, plot)
    PlotState[plot.id] = PlotState[plot.id] or {}
    local s = PlotState[plot.id]
    -- Always update the cached spot/plot first so anything that reads
    -- GetPlotState during a deferred apply gets the latest values.
    s.spot = spot
    s.plot = plot

    -- Re-entrancy guard: SpawnWorldProp yields inside LoadModel, so a
    -- concurrent caller (init thread + plotUpdate event) can race here
    -- and double-spawn pot/soil/plant. If a sync is already in flight,
    -- mark that another apply is pending and let the running one re-run.
    if s.applying then
        s.applyPending = true
        return
    end
    s.applying = true
    s.entities = s.entities or { buds = {}, capsule = {}, rubble = {} }

    local drugCfg = Config.Drugs[plot.drug]
    if not drugCfg then s.applying = false return end

    repeat
        s.applyPending = false
        local curSpot = s.spot
        local curPlot = s.plot
        local center  = vector3(curSpot.coords.x, curSpot.coords.y, curSpot.coords.z)
        local heading = curSpot.coords.w or 0.0

        syncBaseProps(s, center, heading)
        syncCapsule(s, curPlot, drugCfg, center, heading)
        syncPlant(s, curPlot, drugCfg, center, heading)
        syncBuds(s, curPlot, drugCfg, center, heading)
        syncRubble(s, curPlot, drugCfg, center, heading)

        if PlotsHidden then SetPlotVisible(curPlot.id, false) end

        if not s.targetZoneId then
            AttachTarget(curPlot.id)
        end
    until not s.applyPending

    s.applying = false
end

-- ─── Public API ─────────────────────────────────────────────────────────────

--- Returns the in-memory snapshot of a plot. Consumers (cutting, watering,
--- interactions) read this for the latest server-broadcast state.
function GetPlotState(plotId)
    local s = PlotState[plotId]
    return s and s.plot or nil
end

function GetPlotSpot(plotId)
    local s = PlotState[plotId]
    return s and s.spot or nil
end

function GetAllPlotIds()
    local ids = {}
    for id in pairs(PlotState) do ids[#ids + 1] = id end
    return ids
end

--- Returns the world entity for a stage-3 bud at slot index, if it's alive.
function GetPlotBudEntity(plotId, idx)
    local s = PlotState[plotId]
    return s and s.entities and s.entities.buds and s.entities.buds[idx] or nil
end

--- Releases a bud entity from the plot's tracking — caller takes ownership.
--- Used by the cutting scene so it can animate the fall + delete the bud
--- without grow/client also trying to despawn it on the next plot update.
function TakePlotBudEntity(plotId, idx)
    local s = PlotState[plotId]
    if not s or not s.entities or not s.entities.buds then return nil end
    local ent = s.entities.buds[idx]
    s.entities.buds[idx] = nil
    return ent
end

function GetPlotPlantEntity(plotId)
    local s = PlotState[plotId]
    return s and s.entities and s.entities.plant or nil
end

function GetPlotPotEntity(plotId)
    local s = PlotState[plotId]
    return s and s.entities and s.entities.pot or nil
end

--- Toggles visibility on the persistent rubble pile. The planting scene
--- uses this to hide it during the converging-clumps animation (the scene
--- renders its own four rubble props at the ring positions) and re-show it
--- once the scene tears down.
function SetPlotRubbleVisible(plotId, visible)
    local s = PlotState[plotId]
    if not s or not s.entities or not s.entities.rubble then return end
    for _, e in ipairs(s.entities.rubble) do
        if e and DoesEntityExist(e) then
            SetEntityVisible(e, visible, false)
        end
    end
end

-- Cutting / watering scenes use these to swap the world view for their own.
RegisterNetEvent("pickle_drugs:hidePlots", function()
    PlotsHidden = true
    for id in pairs(PlotState) do SetPlotVisible(id, false) end
end)

RegisterNetEvent("pickle_drugs:showPlots", function()
    PlotsHidden = false
    for id in pairs(PlotState) do SetPlotVisible(id, true) end
end)

-- ─── Sync ───────────────────────────────────────────────────────────────────

local function FindSpot(plotId)
    for _, spot in ipairs(Config.GrowSpots or {}) do
        if spot.id == plotId then return spot end
    end
end

RegisterNetEvent("pickle_drugs:plotUpdate", function(plot)
    if not plot or not plot.id then return end
    local spot = FindSpot(plot.id)
    if not spot then return end
    PlotState[plot.id] = PlotState[plot.id] or {}
    PlotState[plot.id].spot = spot
    PlotState[plot.id].plot = plot
    ApplyPlotState(spot, plot)
end)

--- Polls IsModelInCdimage for every model the configured drugs reference, up
--- to a deadline. The streamer registers our YDRs/YTYPs a moment after the
--- resource starts; spawning before that returns "model not in cdimage".
local function WaitForAllDrugModels()
    local seen = {}
    local function add(name) if name and not seen[name] then seen[name] = true end end

    -- Generic shared props every drug spawns.
    add("pickle_pot_01"); add("pickle_soil_01")

    -- Per-drug models.
    for _, drugCfg in pairs(Config.Drugs or {}) do
        if drugCfg.capsule then
            add(drugCfg.capsule.capsule); add(drugCfg.capsule.cap); add(drugCfg.capsule.seed)
        end
        if drugCfg.planting and drugCfg.planting.rubble then
            add(drugCfg.planting.rubble)
        end
        for _, stage in pairs(drugCfg.stages or {}) do
            add(stage.model)
            if stage.buds then add(stage.buds.model) end
        end
    end

    for name in pairs(seen) do
        local hash = joaat(name)
        local deadline = GetGameTimer() + 10000
        while not IsModelInCdimage(hash) and GetGameTimer() < deadline do
            Wait(100)
        end
        if not IsModelInCdimage(hash) then
            debugPrint(("grow: model %s never registered with streamer"):format(name))
        end
    end
end

--- Builds the ox_target options for a plot. Reads the live plot snapshot
--- on each canInteract so prompts hide/show automatically as the server
--- broadcasts state changes.
local function BuildTargetOptions(spot, drugCfg)
    local id = spot.id
    return {
        {
            name  = "pickle_drugs:plant_" .. id,
            label = "Plant seed",
            icon  = "fa-solid fa-seedling",
            canInteract = function()
                local plot = GetPlotState(id)
                return plot and (plot.stage_started_at or 0) == 0
            end,
            onSelect = function()
                if drugCfg.planting and OpenPlantingScene then
                    OpenPlantingScene(id)
                else
                    TriggerServerEvent("pickle_drugs:plant", id)
                end
            end,
        },
        {
            name  = "pickle_drugs:water_" .. id,
            label = "Water plant",
            icon  = "fa-solid fa-droplet",
            canInteract = function()
                local plot = GetPlotState(id)
                if not plot then return false end
                local harvest = Grow.HarvestStage(drugCfg)
                if plot.stage < 1 or plot.stage > harvest then return false end
                -- Allow watering whenever the reservoir isn't full. Topping
                -- up is up to the player; growth pauses if it runs dry.
                local now = GetCloudTimeAsInt() * 1000
                return Grow.WaterLevel(plot, drugCfg, now) < 0.999
            end,
            onSelect = function()
                OpenWateringScene(id)
            end,
        },
        {
            name  = "pickle_drugs:harvest_" .. id,
            label = "Harvest buds",
            icon  = "fa-solid fa-scissors",
            canInteract = function()
                local plot = GetPlotState(id)
                if not plot then return false end
                if plot.stage ~= Grow.HarvestStage(drugCfg) then return false end
                return #Grow.RemainingBudIndexes(plot, drugCfg) > 0
            end,
            onSelect = function()
                OpenCuttingScene(id)
            end,
        },
    }
end

--- Coordinate-based box zone at the plot's position. The zone id is stored
--- on PlotState so we can remove + re-add when the plot re-renders.
function AttachTarget(plotId)
    if GetResourceState("ox_target") ~= "started" then return end
    local s = PlotState[plotId]
    if not s or not s.spot then return end
    local drugCfg = Config.Drugs[s.spot.drug]
    if not drugCfg then return end

    if s.targetZoneId then
        exports.ox_target:removeZone(s.targetZoneId)
        s.targetZoneId = nil
    end

    s.targetZoneId = exports.ox_target:addBoxZone({
        coords   = vector3(s.spot.coords.x, s.spot.coords.y, s.spot.coords.z + 0.6),
        size     = vec3(1.2, 1.2, 1.6),
        rotation = s.spot.coords.w or 0.0,
        debug    = Config.Debug,
        options  = BuildTargetOptions(s.spot, drugCfg),
    })
end

CreateThread(function()
    -- Wait until ox_lib is ready and the streamer has every drug model
    -- registered, then pull the initial snapshot.
    while not lib do Wait(0) end
    WaitForAllDrugModels()
    local plots = lib.callback.await("pickle_drugs:getPlots", false) or {}
    for _, plot in ipairs(plots) do
        local spot = FindSpot(plot.id)
        if spot then
            -- Preserve any entity refs already set up by a prior plotUpdate
            -- broadcast — replacing the table here would leak the previously
            -- spawned pot/plant and cause `syncBaseProps` to spawn doubles.
            PlotState[plot.id] = PlotState[plot.id] or {}
            PlotState[plot.id].spot = spot
            PlotState[plot.id].plot = plot
            ApplyPlotState(spot, plot)
        end
    end
end)

--- Returns the duration (ms) of the given stage, honouring totalGrowMs
--- distribution and Config.GrowTimeMultiplier. Mirrors the logic in
--- Grow.ResolveStage.
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

--- 0..1 overall growth from "seed planted" to "fully grown". Sums each
--- completed stage's duration plus the current stage's elapsed fraction.
--- Time past `water_until` does not count — growth pauses when dry.
local function ComputeGrowProgress(plot, drugCfg)
    local harvest = Grow.HarvestStage(drugCfg)
    if (plot.stage_started_at or 0) == 0 then return 0.0 end

    -- Resolve speculatively on a local probe so the bar keeps moving
    -- across stage transitions without waiting for the server-side
    -- broadcast (which lags by the resolver poll interval).
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

--- Top-bar status enum used by the NUI to choose between bar/label modes:
---   "ready_plant"   → stage 0 unplanted (text only)
---   "needs_water"   → current stage's waterRequired not yet met (text only)
---   "ready_harvest" → stage 3 with buds remaining (text only)
---   "growing"       → otherwise (NUI shows the growProgress bar)
local function ComputeStatus(plot, drugCfg)
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

--- Floating status panel. Each ~100ms, pick the closest plot to the player;
--- if it's within range, project its world position to screen coords and
--- push the snapshot to the NUI which renders an absolute-positioned card.
CreateThread(function()
    local STATUS_RANGE_M = 15.0
    local lastVisible = false
    while true do
        -- 30Hz tick — fast enough that the projection delta between frames
        -- is a few pixels, which the NUI's CSS transition smooths out into
        -- continuous motion. Going to 60Hz / Wait(0) starts costing IPC
        -- bandwidth without a visible benefit.
        Wait(33)
        local ped = PlayerPedId()
        local pcoords = GetEntityCoords(ped)

        local closest, closestDist
        for _, s in pairs(PlotState) do
            if s.spot then
                local sc = s.spot.coords
                local d = #(pcoords - vector3(sc.x, sc.y, sc.z))
                if not closestDist or d < closestDist then
                    closest = s
                    closestDist = d
                end
            end
        end

        if closest and closestDist <= STATUS_RANGE_M and closest.plot then
            local plot    = closest.plot
            local drugCfg = Config.Drugs[plot.drug]
            local sc      = closest.spot.coords
            local onScreen, sx, sy = World3dToScreen2d(sc.x, sc.y, sc.z + 1.6)

            if onScreen and drugCfg then
                local nowMs    = GetCloudTimeAsInt() * 1000
                local budsLeft = #Grow.RemainingBudIndexes(plot, drugCfg)

                local growProgress  = ComputeGrowProgress(plot, drugCfg)
                local waterProgress = Grow.WaterLevel(plot, drugCfg, nowMs)
                local status        = ComputeStatus(plot, drugCfg)
                -- Show the water bar whenever the plant is in a growing
                -- stage — it's the player's reservoir gauge now.
                local showWater = plot.stage >= 1 and plot.stage <= Grow.HarvestStage(drugCfg) - 1

                SendNUIMessage({
                    action = "plotStatus",
                    data = {
                        visible       = true,
                        x             = sx,
                        y             = sy,
                        drug          = drugCfg.label or plot.drug,
                        status        = status,
                        growProgress  = growProgress,
                        waterProgress = waterProgress,
                        showWater     = showWater,
                        budsLeft      = budsLeft,
                    },
                })
                lastVisible = true
            elseif lastVisible then
                SendNUIMessage({ action = "plotStatus", data = { visible = false } })
                lastVisible = false
            end
        elseif lastVisible then
            SendNUIMessage({ action = "plotStatus", data = { visible = false } })
            lastVisible = false
        end
    end
end)

--- Periodic client-side resolver. Server is authoritative but never ticks;
--- the client computes the locally-resolved stage every few seconds and
--- pings the server only when it crosses a boundary. Server runs SyncPlot,
--- which persists + broadcasts plot:update — that comes back to every
--- client and re-renders the new visual stage. Avoids the "restart to see
--- progress" problem without a wasteful server loop.
CreateThread(function()
    while true do
        -- Short interval keeps visual stage swaps tight on fast-tuned
        -- drugs (e.g. totalGrowMs in seconds, not minutes). The server
        -- only does work when the local probe actually crosses a stage.
        Wait(1000)
        for plotId, s in pairs(PlotState) do
            if s.plot and s.plot.stage_started_at and s.plot.stage_started_at > 0 then
                local drugCfg = Config.Drugs[s.plot.drug]
                if drugCfg then
                    -- Work on a shallow copy so we don't mutate the cached
                    -- snapshot before the server confirms.
                    local probe = {
                        stage            = s.plot.stage,
                        stage_started_at = s.plot.stage_started_at,
                        water_until      = s.plot.water_until,
                    }
                    -- `os` isn't available on the FiveM client — use the
                    -- network cloud time, which matches the server's
                    -- `os.time() * 1000`.
                    Grow.ResolveStage(probe, drugCfg, GetCloudTimeAsInt() * 1000)
                    if probe.stage ~= s.plot.stage then
                        TriggerServerEvent("pickle_drugs:requestResolve", plotId)
                    end
                end
            end
        end
    end
end)

AddEventHandler("onResourceStop", function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    for id in pairs(PlotState) do DespawnPlot(id) end
    PlotState = {}
end)
