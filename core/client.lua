-- Debug shortcut: server hits this; we open the cutting scene on the first
-- stage-3 plot we know about (or print why we can't).
RegisterNetEvent("pickle_drugs:debugOpenCutting", function()
    for _, id in ipairs(GetAllPlotIds() or {}) do
        local plot = GetPlotState(id)
        local drugCfg = plot and Config.Drugs[plot.drug]
        if plot and drugCfg and plot.stage == Grow.HarvestStage(drugCfg) then
            OpenCuttingScene(id)
            return
        end
    end
    print("[pickle_drugs] /growop: no harvestable plot available")
end)

-- ─── Entity framework (client runtime) ────────────────────────────────────
-- Kind-agnostic infrastructure for every placed entity (plots, lockers,
-- future types). Per-kind logic registers via PickleEntity.RegisterKind in
-- core/shared.lua; this file owns:
--
--   * Robust prop spawning (PickleEntity.SafeSpawnProp) — model loading races
--     used to leave pots invisible until something forced a re-render
--     (e.g. an admin moving the plot in /drugs). The heal loop below
--     also self-recovers if the streamer hadn't registered a model on
--     the first attempt.
--
--   * Bucket-aware should-render check, shared across kinds.
--
--   * Heal loop ticking every 2s — invokes each kind's heal() so per-kind
--     state can re-spawn entities whose props vanished or never spawned.

--- Returns a renderable object for `model` placed at the supplied
--- coords/heading. Compensates the model's pivot offset (so the bbox
--- centre lands on the footprint centre) and tries to load the model up
--- to `timeoutMs` before giving up. Returns nil on failure — callers
--- should treat that as "try again later" and rely on the heal loop.
---@param model string|integer
---@param coords table {x,y,z}
---@param heading number
---@param timeoutMs number|nil
---@return integer|nil entity
function PickleEntity.SafeSpawnProp(model, coords, heading, timeoutMs)
    if not model or not coords then return nil end
    local hash = LoadModel(model, timeoutMs or 4000)
    if not hash then return nil end
    -- Coerce to float. FiveM natives that take a float argument
    -- (SetEntityHeading, SetEntityRotation) silently no-op if Lua hands
    -- them an integer — which `(zoneW + rotIndex*90) % 360` produces
    -- exactly when both sides are whole numbers (e.g. 235). The `+ 0.0`
    -- forces the value into Lua's float subtype so the native binding
    -- marshals it correctly.
    local h = ((tonumber(heading) or 0.0) % 360) + 0.0
    local cx, cy, cz = coords.x, coords.y, coords.z
    if Housing and Housing.AdjustSpawnCoords then
        cx, cy, cz = Housing.AdjustSpawnCoords(model, cx, cy, cz, h)
    end

    local obj = CreateObject(hash, cx, cy, cz, false, false, false)
    if not obj or not DoesEntityExist(obj) then
        SetModelAsNoLongerNeeded(hash)
        return nil
    end

    -- Pose order matters for stubborn prop classes (door-bearing
    -- container props like gr_prop_gr_gunlocker_01a). The placement
    -- preview's working sequence is collision-off → freeze → rotate,
    -- because the engine's physics-anchor override eats rotation
    -- writes on a live, collidable, unfrozen entity. Mirror that here:
    -- disable collision, freeze, then rotate. We re-enable collision
    -- after so the prop still blocks the player.
    SetEntityCollision(obj, false, false)
    FreezeEntityPosition(obj, true)
    SetEntityCoordsNoOffset(obj, cx, cy, cz, false, false, false)
    SetEntityHeading(obj, h)

    if not DoesEntityExist(obj) then
        SetModelAsNoLongerNeeded(hash)
        return nil
    end

    SetEntityCollision(obj, true, true)
    SetEntityInvincible(obj, true)
    SetModelAsNoLongerNeeded(hash)
    return obj
end

--- Bucket-aware visibility check for a row that carries `house_id`. MLO
--- houses always render. Teleport houses only render when the player is
--- bucketed into that exact house.
function PickleEntity.ShouldRender(row)
    if not row or not row.house_id or row.house_id == "" then return false end
    if not Housing or not Housing.GetHouse then return false end
    local h = Housing.GetHouse(row.house_id)
    if not h then return false end
    if h.kind == "mlo" then return true end
    return Housing.GetCurrentBucketHouseId() == row.house_id
end

--- Calls every registered kind's heal() once. Triggered periodically so
--- entities whose first spawn failed (model not yet streamed, bucket not
--- set, etc.) recover without a manual nudge.
local function healAll()
    for _, handlers in pairs(PickleEntity.kinds or {}) do
        if handlers and handlers.heal then
            local ok, err = pcall(handlers.heal)
            if not ok then
                debugPrint("entity heal error:", err)
            end
        end
    end
end

--- Calls every registered kind's reevaluate() — used when housing /
--- bucket / interior state changes so entities flip between rendered
--- and pending in a single coherent pass.
local function reevaluateAll()
    for _, handlers in pairs(PickleEntity.kinds or {}) do
        if handlers and handlers.reevaluate then
            local ok, err = pcall(handlers.reevaluate)
            if not ok then
                debugPrint("entity reevaluate error:", err)
            end
        end
    end
end

CreateThread(function()
    -- Short leading delay just so we don't race the kinds' RegisterKind
    -- calls at script load. After that the heal cadence is the floor on
    -- "how long before an entity recovers" so keep it tight.
    Wait(500)
    while true do
        healAll()
        Wait(1000)
    end
end)

-- Centralised re-evaluation triggers. Each kind's renderer subscribes
-- via RegisterKind { reevaluate = fn } instead of wiring its own.
RegisterNetEvent("pickle_drugs:enteredHouse",   reevaluateAll)
RegisterNetEvent("pickle_drugs:leftHouse",      reevaluateAll)
RegisterNetEvent("pickle_drugs:houseUpdate",    reevaluateAll)
RegisterNetEvent("pickle_drugs:interiorUpdate", reevaluateAll)

PickleEntity.HealAll       = healAll
PickleEntity.ReevaluateAll = reevaluateAll
