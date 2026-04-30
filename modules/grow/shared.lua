-- Shared plot helpers used by both client and server. The state machine is
-- "lazy": stage advancement is computed on demand from elapsed wall-clock and
-- water count, never on a tick. Caller persists the resolved state.

Grow = Grow or {}

--- Returns a fresh plot row with default values for the given spot.
---@param spot table { id, drug, coords }
---@return table plot
function Grow.NewPlot(spot)
    return {
        id              = spot.id,
        drug            = spot.drug,
        stage           = 0,
        stage_started_at = 0,           -- 0 means "not planted yet"
        water_count     = 0,
        cut_buds        = {},           -- array of bud-slot indexes already cut at stage 3
        updated_at      = 0,
    }
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
    -- Stage 0 with stage_started_at=0 means "no seed planted yet" — never
    -- advance until a plant event sets the timer.
    if plot.stage == 0 and (plot.stage_started_at or 0) == 0 then
        return plot, false
    end

    -- Apply the global multiplier so every stage scales uniformly. Default
    -- 1.0 if unset.
    local mul = 1.0

    -- If `totalGrowMs` is set on the drug, distribute that total across the
    -- pre-harvest stages (stage 0 = empty, stages 1..2 = growing; stage 3
    -- is the harvestable end-cap and stays at its configured durationMs).
    local perStage
    if drugCfg.totalGrowMs and drugCfg.totalGrowMs > 0 then
        perStage = drugCfg.totalGrowMs / 2.0
    end

    local function durationFor(stage)
        local sCfg = drugCfg.stages[stage]
        if not sCfg then return 0 end
        if perStage and (stage == 1 or stage == 2) then
            return perStage * mul
        end
        return (sCfg.durationMs or 0) * mul
    end

    local changed = false
    while plot.stage < 3 do
        local sCfg = drugCfg.stages[plot.stage]
        if not sCfg then break end
        local duration = durationFor(plot.stage)
        local elapsed = now - (plot.stage_started_at or 0)
        if elapsed < duration then break end
        if (plot.water_count or 0) < (sCfg.waterRequired or 0) then break end
        plot.stage_started_at = (plot.stage_started_at or 0) + duration
        plot.water_count = 0
        plot.stage = plot.stage + 1
        changed = true
    end
    return plot, changed
end

--- Resets a plot to "empty soil, awaiting seed".
---@param plot table
function Grow.ResetPlot(plot)
    plot.stage = 0
    plot.stage_started_at = 0
    plot.water_count = 0
    plot.cut_buds = {}
end

--- Returns the array of remaining bud indexes for a stage-3 plot. Indexes
--- align with `Config.Drugs[drug].stages[3].buds.offsets`.
---@param plot table
---@param drugCfg table
---@return number[] indexes
function Grow.RemainingBudIndexes(plot, drugCfg)
    if plot.stage ~= 3 then return {} end
    local s3 = drugCfg.stages[3]
    if not s3 or not s3.buds or not s3.buds.offsets then return {} end
    local cut = {}
    for _, idx in ipairs(plot.cut_buds or {}) do cut[idx] = true end
    local remaining = {}
    for i = 1, #s3.buds.offsets do
        if not cut[i] then remaining[#remaining + 1] = i end
    end
    return remaining
end
