-- Authoritative plot state. Persists in oxmysql; never ticks. Stage
-- advancement is computed by Grow.ResolveStage on every read/write, and the
-- result is broadcast to clients only when the resolved state differs from
-- what's stored.

local Plots = {}        -- id → plot row (in-memory cache; SQL is source of truth)

local function now() return os.time() * 1000 end

--- Loads all configured spots from DB, creating rows for any that don't
--- exist yet. Runs once at resource start.
local function LoadPlots()
    local spots = Config.GrowSpots or {}
    if #spots == 0 then return end

    local rows = MySQL.query.await("SELECT * FROM pickle_drugs_plots") or {}
    local byId = {}
    for _, row in ipairs(rows) do byId[row.id] = row end

    for _, spot in ipairs(spots) do
        local row = byId[spot.id]
        if row then
            local cutBuds = row.cut_buds
            if type(cutBuds) == "string" then
                cutBuds = json.decode(cutBuds) or {}
            end
            -- Legacy rows used 0-indexed stages; bump to 1-indexed.
            local stage = tonumber(row.stage) or 0
            if stage < 1 then stage = 1 end
            local soilAddedAt = tonumber(row.soil_added_at) or 0
            local stageStartedAt = tonumber(row.stage_started_at) or 0
            -- Pre-soil migration: rows that already had a planted seed
            -- predate the soil step; backfill so they don't regress to
            -- "Needs Soil" and lose growth state.
            if soilAddedAt == 0 and stageStartedAt > 0 then
                soilAddedAt = stageStartedAt
            end
            Plots[spot.id] = {
                id              = row.id,
                drug            = row.drug,
                stage           = stage,
                soil_added_at   = soilAddedAt,
                stage_started_at = stageStartedAt,
                water_until     = tonumber(row.water_until) or 0,
                cut_buds        = cutBuds or {},
                updated_at      = tonumber(row.updated_at) or 0,
            }
        else
            Plots[spot.id] = Grow.NewPlot(spot)
            MySQL.insert.await(
                "INSERT INTO pickle_drugs_plots (id, drug, stage, soil_added_at, stage_started_at, water_until, cut_buds, updated_at) VALUES (?,?,?,?,?,?,?,?)",
                { spot.id, spot.drug, 1, 0, 0, 0, "[]", now() }
            )
        end
    end

    debugPrint(("grow: loaded %d plots from DB"):format(#spots))
end

--- Persists a plot row.
local function PersistPlot(plot)
    plot.updated_at = now()
    MySQL.update.await(
        "UPDATE pickle_drugs_plots SET stage=?, soil_added_at=?, stage_started_at=?, water_until=?, cut_buds=?, updated_at=? WHERE id=?",
        {
            plot.stage,
            plot.soil_added_at or 0,
            plot.stage_started_at,
            plot.water_until,
            json.encode(plot.cut_buds or {}),
            plot.updated_at,
            plot.id,
        }
    )
end

--- Resolves the plot to current state, persists if anything changed, and
--- broadcasts the latest snapshot. Returns the plot for chaining.
local function SyncPlot(plot, force)
    local drugCfg = Config.Drugs[plot.drug]
    local _, changed = Grow.ResolveStage(plot, drugCfg, now())
    if changed or force then
        PersistPlot(plot)
        TriggerClientEvent("pickle_drugs:plotUpdate", -1, plot)
    end
    return plot
end

--- Returns the current state of every plot, resolved.
local function GetAllPlots()
    local out = {}
    for _, plot in pairs(Plots) do
        SyncPlot(plot)
        out[#out + 1] = plot
    end
    return out
end

-- ─── Public events ──────────────────────────────────────────────────────────

local function notify(src, msg, type_)
    TriggerClientEvent("ox_lib:notify", src, { title = "Drugs", description = msg, type = type_ or "inform" })
end

--- Add soil to an empty pot. Sets soil_added_at, which gates the plant
--- step and flips the world view from "empty pot" to "pot + soil".
RegisterNetEvent("pickle_drugs:addSoil", function(plotId)
    local src = source
    local plot = Plots[plotId]
    if not plot then notify(src, "Plot not found", "error") return end
    if (plot.soil_added_at or 0) ~= 0 then
        notify(src, "Soil already added", "error") return
    end
    plot.soil_added_at = now()
    SyncPlot(plot, true)
    notify(src, "Soil added", "success")
end)

--- Plant a seed. Consumes the drug's seedItem; sets the plot's
--- stage_started_at, which kicks the lazy stage resolver into motion.
RegisterNetEvent("pickle_drugs:plant", function(plotId)
    local src = source
    local plot = Plots[plotId]
    if not plot then notify(src, "Plot not found", "error") return end
    if (plot.soil_added_at or 0) == 0 then
        notify(src, "Add soil first", "error") return
    end
    if plot.stage_started_at ~= 0 then
        notify(src, "Already planted", "error") return
    end

    local drugCfg = Config.Drugs[plot.drug]
    if not drugCfg then return end

    -- Item requirement disabled for now — wire back via Inventory.GetItemCount /
    -- RemoveItem when an inventory item is set up for `drugCfg.seedItem`.

    plot.stage            = 1
    plot.stage_started_at = now()
    plot.water_until      = 0
    plot.cut_buds         = {}
    SyncPlot(plot, true)
    notify(src, "Seed planted", "success")
end)

--- Register a single pour against a plot. Client decides when a pour
--- "lands" (when its pitcher angle and proximity to the pot are right) and
--- fires this; server just bumps the counter and re-resolves the stage.
RegisterNetEvent("pickle_drugs:water", function(plotId, fraction)
    local plot = Plots[plotId]
    if not plot then return end
    local drugCfg = Config.Drugs[plot.drug]
    if not drugCfg then return end
    local harvest = Grow.HarvestStage(drugCfg)
    if plot.stage < 1 or plot.stage > harvest then return end
    local default = (drugCfg.watering and drugCfg.watering.pourPerPlot) or 0.20
    -- Client may send a partial fraction (e.g. flushing a sub-threshold
    -- accumulator on scene close). Clamp to the configured pourPerPlot
    -- so a malicious client can't grant itself a full pitcher per call.
    local f = tonumber(fraction) or default
    if f <= 0 then return end
    if f > default then f = default end
    Grow.AddWater(plot, drugCfg, now(), f)
    SyncPlot(plot, true)
end)

--- Client-side ticker pings this when its locally-resolved stage diverges
--- from the cached server stage. We re-run SyncPlot which is no-op unless
--- the resolver actually advances the plot.
RegisterNetEvent("pickle_drugs:requestResolve", function(plotId)
    local plot = Plots[plotId]
    if not plot then return end
    SyncPlot(plot, false)
end)

--- Cut one bud at stage 3. Granted index goes into `cut_buds`; harvest item
--- is awarded via the inventory bridge. When the plot has no buds left, it
--- resets to stage 0.
RegisterNetEvent("pickle_drugs:cutBud", function(plotId, budIndex)
    local src = source
    local plot = Plots[plotId]
    if not plot then return end
    budIndex = tonumber(budIndex)
    if not budIndex then return end

    local drugCfg = Config.Drugs[plot.drug]
    local harvest = drugCfg and Grow.HarvestStage(drugCfg) or 0
    if plot.stage ~= harvest then return end
    local s3 = drugCfg and drugCfg.stages[harvest]
    if not s3 or not s3.buds or not s3.buds.offsets then return end
    if budIndex < 1 or budIndex > #s3.buds.offsets then return end

    -- Reject double-cuts.
    for _, idx in ipairs(plot.cut_buds or {}) do
        if idx == budIndex then return end
    end

    plot.cut_buds[#plot.cut_buds + 1] = budIndex

    local harvestItem = drugCfg.cutting and drugCfg.cutting.harvestItem
    if harvestItem and Inventory and Inventory.AddItem then
        Inventory.AddItem(src, harvestItem, 1)
    end

    -- Last bud cut → reset for the next cycle.
    if #plot.cut_buds >= #s3.buds.offsets then
        debugPrint(("plot %s fully harvested — resetting to stage 0"):format(plotId))
        Grow.ResetPlot(plot)
    end

    SyncPlot(plot, true)
end)

-- ─── Callbacks ──────────────────────────────────────────────────────────────

lib.callback.register("pickle_drugs:getPlots", function()
    return GetAllPlots()
end)

-- ─── Boot ───────────────────────────────────────────────────────────────────

--- Seeds Plots from Config.GrowSpots without touching the DB. Used as a
--- fallback so the resource still works in dev/no-DB setups; state lives
--- only in memory and resets on restart.
local function SeedInMemory()
    for _, spot in ipairs(Config.GrowSpots or {}) do
        if not Plots[spot.id] then
            Plots[spot.id] = Grow.NewPlot(spot)
        end
    end
    print(("[pickle_drugs] grow: seeded %d in-memory plots (no DB)"):format(#(Config.GrowSpots or {})))
end

CreateThread(function()
    -- Wait for oxmysql + schema, then load. If oxmysql never readies (no DB
    -- configured / down), fall back to in-memory state so the gameplay loop
    -- still works locally.
    local readyFired = false
    if MySQL and MySQL.ready then
        MySQL.ready(function()
            readyFired = true
            local ok, err = pcall(function()
                MySQL.query.await([[
                    CREATE TABLE IF NOT EXISTS pickle_drugs_plots (
                        id              VARCHAR(64)  PRIMARY KEY,
                        drug            VARCHAR(32)  NOT NULL,
                        stage           TINYINT      NOT NULL DEFAULT 0,
                        soil_added_at   BIGINT       NOT NULL DEFAULT 0,
                        stage_started_at BIGINT      NOT NULL DEFAULT 0,
                        water_until     BIGINT       NOT NULL DEFAULT 0,
                        cut_buds        TEXT         NOT NULL,
                        updated_at      BIGINT       NOT NULL DEFAULT 0
                    )
                ]])
                -- Migrate from the old water_count column if upgrading.
                local cols = MySQL.query.await(
                    "SHOW COLUMNS FROM pickle_drugs_plots WHERE Field IN ('water_count','water_until','soil_added_at')"
                ) or {}
                local has = {}
                for _, c in ipairs(cols) do has[c.Field] = true end
                if has.water_count and not has.water_until then
                    MySQL.query.await("ALTER TABLE pickle_drugs_plots CHANGE water_count water_until BIGINT NOT NULL DEFAULT 0")
                    MySQL.query.await("UPDATE pickle_drugs_plots SET water_until = 0")
                end
                if not has.soil_added_at then
                    MySQL.query.await("ALTER TABLE pickle_drugs_plots ADD COLUMN soil_added_at BIGINT NOT NULL DEFAULT 0 AFTER stage")
                    -- Backfill: anything already planted predates the soil
                    -- step; mark soil added at the same instant so the plot
                    -- doesn't regress to "Needs Soil".
                    MySQL.query.await("UPDATE pickle_drugs_plots SET soil_added_at = stage_started_at WHERE stage_started_at > 0")
                end
                LoadPlots()
            end)
            if not ok then
                print(("[pickle_drugs] grow: DB error, falling back to in-memory: %s"):format(tostring(err)))
                SeedInMemory()
            end
            for _, plot in pairs(Plots) do
                SyncPlot(plot, true)
            end
            print(("[pickle_drugs] grow: ready with %d plots"):format(#(Config.GrowSpots or {})))
        end)
    end

    -- Watchdog: if MySQL.ready hasn't fired after 5s, seed in memory so
    -- clients eventually get a snapshot.
    Wait(5000)
    if not readyFired then
        print("[pickle_drugs] grow: MySQL.ready never fired after 5s — using in-memory state")
        SeedInMemory()
        for _, plot in pairs(Plots) do
            SyncPlot(plot, true)
        end
    end
end)

-- New clients: push them the current snapshot once their resource is up.
AddEventHandler("playerJoining", function()
    local src = source
    SetTimeout(2000, function()
        for _, plot in pairs(Plots) do
            SyncPlot(plot)
            TriggerClientEvent("pickle_drugs:plotUpdate", src, plot)
        end
    end)
end)
