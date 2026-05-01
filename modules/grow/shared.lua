-- Shared plot helpers used by both client and server. The state machine is
-- "lazy": stage advancement is computed on demand from elapsed wall-clock and
-- water count, never on a tick. Caller persists the resolved state.

Grow = Grow or {}

--- Returns the highest configured stage index for a drug. The stages
--- table is keyed 0..N — stage 0 is "empty pre-plant" and stage N is the
--- harvestable end-cap (carries the buds config). Pre-harvest growing
--- stages are 1..N-1.
---@param drugCfg table
---@return integer
function Grow.HarvestStage(drugCfg)
    if not drugCfg or not drugCfg.stages then return 0 end
    return #drugCfg.stages
end

--- Returns a fresh plot row with default values for the given spot.
---@param spot table { id, drug, coords }
---@return table plot
function Grow.NewPlot(spot)
    return {
        id              = spot.id,
        drug            = spot.drug,
        stage           = 1,
        soil_added_at   = 0,            -- 0 means "no soil yet" (Needs Soil state)
        stage_started_at = 0,           -- 0 means "not planted yet"
        water_until     = 0,            -- ms epoch; growth only progresses up to this point
        cut_buds        = {},           -- array of bud-slot indexes already cut at the harvest stage
        updated_at      = 0,
    }
end

--- Returns the drug's water reservoir capacity in ms. Falls back to a
--- third of `totalGrowMs` so a sensibly-tuned drug works without extra
--- config.
function Grow.WaterCapacityMs(drugCfg)
    if not drugCfg then return 0 end
    if drugCfg.waterCapacityMs and drugCfg.waterCapacityMs > 0 then
        return drugCfg.waterCapacityMs
    end
    if drugCfg.totalGrowMs and drugCfg.totalGrowMs > 0 then
        return drugCfg.totalGrowMs / 3.0
    end
    return 0
end

--- Returns 0..1 water level for a plot at `now`.
function Grow.WaterLevel(plot, drugCfg, now)
    local cap = Grow.WaterCapacityMs(drugCfg)
    if cap <= 0 then return 0.0 end
    local remaining = (plot.water_until or 0) - now
    if remaining <= 0 then return 0.0 end
    if remaining > cap then remaining = cap end
    return remaining / cap
end

--- Adds water to the reservoir. `fraction` is 0..1 of full capacity.
--- Caps at full. If the reservoir was already empty, the lost growing
--- time stays lost — `stage_started_at` is shifted forward by the dry
--- duration so the resolver doesn't credit it.
function Grow.AddWater(plot, drugCfg, now, fraction)
    local cap = Grow.WaterCapacityMs(drugCfg)
    if cap <= 0 then return end
    local prev = plot.water_until or 0
    if prev < now and (plot.stage_started_at or 0) > 0 then
        -- Shift stage_started_at forward by however long we were dry, but
        -- not past `now`. Without this, dry time would silently count as
        -- growth when we top up.
        local dryStart = math.max(prev, plot.stage_started_at or 0)
        local dry = now - dryStart
        if dry > 0 then
            plot.stage_started_at = (plot.stage_started_at or 0) + dry
        end
        prev = now
    end
    local add = cap * (fraction or 0)
    local new = prev + add
    local maxAt = now + cap
    if new > maxAt then new = maxAt end
    plot.water_until = new
end

--- Advances `plot.stage` as far as elapsed time + water counts allow.
--- Returns the (possibly mutated) plot and a `changed` flag the caller can
--- use to decide whether to persist + broadcast.
---@param plot table
---@param drugCfg table  Config.Drugs[plot.drug]
---@param now number      ms epoch
---@return table plot
---@return boolean changed
function Grow.ResolveStage(plot, drugCfg, now)
    if not drugCfg or not drugCfg.stages then return plot, false end
    -- stage_started_at == 0 means "no seed planted yet" — never advance
    -- until a plant event sets the timer.
    if (plot.stage_started_at or 0) == 0 then
        return plot, false
    end

    -- Apply the global multiplier so every stage scales uniformly. Default
    -- 1.0 if unset.
    local mul = 1.0

    local harvest = Grow.HarvestStage(drugCfg)

    -- `totalGrowMs` is split evenly across all pre-harvest stages
    -- (1..harvest-1) — including the empty post-plant stage 1, so the
    -- player sees an even progression: empty → 01 → 02 → … → harvest.
    -- The harvest stage itself is the end-cap (duration 0).
    local growingCount = harvest - 1
    local perStage = 0
    if drugCfg.totalGrowMs and drugCfg.totalGrowMs > 0 and growingCount > 0 then
        perStage = drugCfg.totalGrowMs / growingCount
    end

    local function durationFor(stage)
        if stage >= 1 and stage <= harvest - 1 then
            return perStage * mul
        end
        return 0
    end

    -- Growth time only counts up to `water_until` — anything past that is
    -- dry and contributes nothing. Zero-duration stages (stage 0) advance
    -- unconditionally; they're transient and never need water.
    local changed = false
    while plot.stage < harvest do
        local sCfg = drugCfg.stages[plot.stage]
        if not sCfg then break end
        local duration = durationFor(plot.stage)
        if duration > 0 then
            local effectiveNow = math.min(now, plot.water_until or 0)
            local elapsed = effectiveNow - (plot.stage_started_at or 0)
            if elapsed < duration then break end
        end
        plot.stage_started_at = (plot.stage_started_at or 0) + duration
        plot.stage = plot.stage + 1
        changed = true
    end
    return plot, changed
end

--- Resets a plot to "empty soil, awaiting seed".
---@param plot table
function Grow.ResetPlot(plot)
    plot.stage = 1
    plot.soil_added_at = 0
    plot.stage_started_at = 0
    plot.water_until = 0
    plot.cut_buds = {}
end

--- Returns the array of remaining bud indexes for a harvestable plot.
--- Indexes align with `Config.Drugs[drug].stages[harvest].buds.offsets`.
---@param plot table
---@param drugCfg table
---@return number[] indexes
function Grow.RemainingBudIndexes(plot, drugCfg)
    local harvest = Grow.HarvestStage(drugCfg)
    if plot.stage ~= harvest then return {} end
    local s3 = drugCfg.stages[harvest]
    if not s3 or not s3.buds or not s3.buds.offsets then return {} end
    local cut = {}
    for _, idx in ipairs(plot.cut_buds or {}) do cut[idx] = true end
    local remaining = {}
    for i = 1, #s3.buds.offsets do
        if not cut[i] then remaining[#remaining + 1] = i end
    end
    return remaining
end
