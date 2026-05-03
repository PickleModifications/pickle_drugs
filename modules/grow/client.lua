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

--- Thin wrapper over PickleEntity.SafeSpawnProp so this file's existing call
--- sites stay readable. The heavy lifting (model loading, pivot offset
--- compensation, freezing, invincibility) lives in core/client.lua and
--- is shared with every other entity kind.
local function SpawnWorldProp(model, coords, heading)
    return PickleEntity.SafeSpawnProp(model, coords, heading)
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
--- / watering scenes to hide the world copy while their camera scenes run,
--- and by the plot creator to hide the live prop while the admin moves it.
function SetPlotVisible(plotId, visible)
    local s = PlotState[plotId]
    if not s or not s.entities then return end
    for ent in eachEntity(s.entities) do
        if ent and DoesEntityExist(ent) then
            SetEntityVisible(ent, visible, false)
            SetEntityCollision(ent, visible, visible)
        end
    end
end

--- Ensures pot exists; soil only spawns once the player has added it.
--- The pot is permanent for the lifetime of the plot. The soil prop is
--- gated on `soil_added_at > 0` — pre-soil plots show an empty pot, and
--- a post-harvest reset (Grow.ResetPlot clears soil_added_at) despawns it.
local function syncBaseProps(s, plot, center, heading)
    if not s.entities.pot or not DoesEntityExist(s.entities.pot) then
        s.entities.pot = SpawnWorldProp("pickle_pot_01", center, heading)
    end

    local needSoil = (plot.soil_added_at or 0) > 0
    local haveSoil = s.entities.soil and DoesEntityExist(s.entities.soil)
    if needSoil and not haveSoil then
        s.entities.soil = SpawnWorldProp("pickle_soil_01", center, heading)
    elseif not needSoil and haveSoil then
        DeleteEntity(s.entities.soil)
        s.entities.soil = nil
    end
end

--- The interactive planting scene owns the capsule visuals during the
--- plant flow; this stub just drains any leftovers from a pre-planting-scene
--- save so a static capsule never duplicates the in-scene one.
local function syncCapsule(s, _plot, _drugCfg, _center, _heading)
    for _, e in pairs(s.entities.capsule) do
        if e and DoesEntityExist(e) then DeleteEntity(e) end
    end
    s.entities.capsule = {}
end

--- Soil rubble pile. Spawned once the plot is planted (stage_started_at >
--- 0) and removed when the plot is reset back to "needs planting". The
--- layout mirrors the planting scene's converged ring — same count, same
--- angular spacing, same residual radius (5% of the spawn radius after
--- the planting animation closes to 95%) — so the persistent pile reads
--- identical to what the player just clicked into place.
local function syncRubble(s, plot, _drugCfg, center, _heading)
    s.entities.rubble = s.entities.rubble or {}
    local cfg  = (Config.PlantScene and Config.PlantScene.planting) or {}
    local need = cfg.rubble and (plot.stage_started_at or 0) > 0
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

        syncBaseProps(s, curPlot, center, heading)
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

--- Toggles visibility on the persistent soil prop. The soiling scene
--- uses this to hide it during the pour animation (the scene renders its
--- own soil entity that lerps Z as the bag empties) and re-show it when
--- the scene tears down.
function SetPlotSoilVisible(plotId, visible)
    local s = PlotState[plotId]
    if not s or not s.entities then return end
    local e = s.entities.soil
    if e and DoesEntityExist(e) then
        SetEntityVisible(e, visible, false)
    end
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

--- Synthesises a spot table from the plot row. Coords now live on the
--- plot itself (DB-backed); downstream consumers (BuildTargetOptions,
--- ApplyPlotState, SetPlotVisible, etc) still expect a spot-shaped
--- `{ id, drug, coords = vector4(...) }` so we wrap the row.
local function SpotFromPlot(plot)
    if not plot or not plot.id then return nil end
    local x = tonumber(plot.coords_x)
    local y = tonumber(plot.coords_y)
    local z = tonumber(plot.coords_z)
    if not x or not y or not z then return nil end
    return {
        id     = plot.id,
        drug   = plot.drug,
        coords = vector4(x, y, z, tonumber(plot.coords_w) or 0.0),
    }
end

--- Whether this client should render a plot, given which house we're in.
--- Plots in any mlo-kind house render unconditionally (they live in
--- bucket 0). Plots in teleport-kind houses only render when the player
--- is bucketed into that same house — otherwise the same world coords
--- would render N copies stacked on each other (one per isolated tenant
--- of the shared interior template). Orphan plots (no real house) are
--- deleted server-side at boot, so we treat a missing house as a
--- transient state and don't render until housing catches up.
local function shouldRenderPlot(plot)
    if not Housing then return false end
    local houseId = plot.house_id
    if not houseId or houseId == "" then return false end
    local h = Housing.GetHouse(houseId)
    if not h then return false end
    if h.kind == "mlo" then return true end
    return Housing.GetCurrentBucketHouseId() == houseId
end

local PendingPlots = {}

local function applyOrDefer(plot)
    local spot = SpotFromPlot(plot)
    if not spot then return end
    if not shouldRenderPlot(plot) then
        PendingPlots[plot.id] = plot
        DespawnPlot(plot.id)
        PlotState[plot.id] = nil
        return
    end
    PendingPlots[plot.id] = nil
    local existing = PlotState[plot.id]
    if existing and existing.spot then
        local oldC, newC = existing.spot.coords, spot.coords
        local moved = math.abs(oldC.x - newC.x) > 0.01
            or math.abs(oldC.y - newC.y) > 0.01
            or math.abs(oldC.z - newC.z) > 0.01
            or math.abs((oldC.w or 0) - (newC.w or 0)) > 0.01
        if moved then DespawnPlot(plot.id) end
    end
    PlotState[plot.id] = PlotState[plot.id] or {}
    PlotState[plot.id].spot = spot
    PlotState[plot.id].plot = plot
    ApplyPlotState(spot, plot)
end

RegisterNetEvent("pickle_drugs:plotUpdate", function(plot)
    if not plot or not plot.id then return end
    applyOrDefer(plot)
end)

--- Re-evaluate render state when the player moves between buckets — what
--- was hidden on the world side now needs to spawn (and vice versa).
local function reevaluateAll()
    for _, plot in pairs(PendingPlots) do
        if shouldRenderPlot(plot) then applyOrDefer(plot) end
    end
    for id, s in pairs(PlotState) do
        if s.plot and not shouldRenderPlot(s.plot) then
            PendingPlots[id] = s.plot
            DespawnPlot(id)
            PlotState[id] = nil
        end
    end
end

-- Re-evaluation on enteredHouse / leftHouse / houseUpdate / interiorUpdate
-- is centralised in core/client.lua; we register the kind below so it
-- gets called as part of PickleEntity.ReevaluateAll.

RegisterNetEvent("pickle_drugs:plotRemoved", function(plotId)
    if not plotId then return end
    DespawnPlot(plotId)
    PlotState[plotId] = nil
end)

--- Polls IsModelInCdimage for every model the configured drugs reference, up
--- to a deadline. The streamer registers our YDRs/YTYPs a moment after the
--- resource starts; spawning before that returns "model not in cdimage".
local function WaitForAllDrugModels()
    local seen = {}
    local function add(name) if name and not seen[name] then seen[name] = true end end

    -- Generic shared props every drug spawns.
    add("pickle_pot_01"); add("pickle_soil_01")

    -- Scene-wide props (capsule trio, soil bag pair, rubble).
    local ps = Config.PlantScene or {}
    if ps.planting and ps.planting.capsule then
        add(ps.planting.capsule.capsule)
        add(ps.planting.capsule.cap)
        add(ps.planting.capsule.seed)
    end
    if ps.planting and ps.planting.rubble then add(ps.planting.rubble) end
    if ps.soiling and ps.soiling.bag then
        add(ps.soiling.bag.full)
        add(ps.soiling.bag.ripped)
    end

    -- Per-drug stage models.
    for _, drugCfg in pairs(Config.Drugs or {}) do
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
--- broadcasts state changes. Move/Remove are inside the plant scene's
--- bottom action menu rather than out here so the player doesn't have a
--- pile of competing prompts on a single plot.
local function BuildTargetOptions(spot, _drugCfg)
    local id = spot.id
    return {
        {
            name  = "pickle_drugs:interact_" .. id,
            label = "Interact with Plant",
            icon  = "fa-solid fa-hand",
            canInteract = function()
                if IsPlantSceneActive and IsPlantSceneActive() then return false end
                return GetPlotState(id) ~= nil
            end,
            onSelect = function()
                if OpenPlantScene then OpenPlantScene(id) end
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
        coords   = vector3(s.spot.coords.x, s.spot.coords.y, s.spot.coords.z),
        size     = vec3(0.5, 0.5, 1.0),
        rotation = s.spot.coords.w or 0.0,
        debug    = Config.Debug,
        options  = BuildTargetOptions(s.spot, drugCfg),
    })
end

CreateThread(function()
    -- Fetch + apply as soon as ox_lib is ready. We used to block on
    -- WaitForAllDrugModels here, which polled IsModelInCdimage for every
    -- streamed drug asset — those register a beat after the resource
    -- starts, so the wait added ~2-3s before plots even attempted to
    -- spawn (storage doesn't pay this cost because its props are stock
    -- GTA models). With the heal loop in core/client.lua, any model
    -- that wasn't yet registered when the first applyOrDefer ran gets
    -- automatically retried within 2s — the upfront wait is now
    -- redundant work that desyncs plot spawn from locker spawn.
    while not lib do Wait(0) end
    local plots = lib.callback.await("pickle_drugs:getPlots", false) or {}
    for _, plot in ipairs(plots) do
        applyOrDefer(plot)
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

-- ─── Entity framework hooks ──────────────────────────────────────────────
-- The shared Entity runtime in core/client.lua periodically calls heal()
-- on every registered kind so entities whose first spawn failed (model
-- not yet streamed, bucket race, etc.) recover without an explicit
-- nudge. reevaluate() runs whenever housing / bucket / interior state
-- changes — we drain pending plots into the live state and remove plots
-- the player can no longer see.
PickleEntity.RegisterKind("plot", {
    reevaluate = function() reevaluateAll() end,
    heal = function()
        -- 1. Drain any plots still parked in the pending queue —
        -- shouldRenderPlot may now return true if Housing data has
        -- caught up.
        for _, plot in pairs(PendingPlots) do
            if shouldRenderPlot(plot) then applyOrDefer(plot) end
        end
        -- 2. Re-render rows whose pot prop is missing. Most often this
        -- catches the first-boot streamer race where pickle_pot_01
        -- wasn't loaded when applyOrDefer originally ran. ApplyPlotState
        -- doesn't mutate PlotState's keyset so iterating is safe.
        for _, s in pairs(PlotState) do
            if s.spot and s.plot then
                if not s.entities or not s.entities.pot
                    or not DoesEntityExist(s.entities.pot)
                then
                    ApplyPlotState(s.spot, s.plot)
                end
            end
        end
    end,
})
