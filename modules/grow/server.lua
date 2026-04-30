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
            Plots[spot.id] = {
                id              = row.id,
                drug            = row.drug,
                stage           = row.stage or 0,
                stage_started_at = tonumber(row.stage_started_at) or 0,
                water_count     = row.water_count or 0,
                cut_buds        = cutBuds or {},
                updated_at      = tonumber(row.updated_at) or 0,
            }
        else
            Plots[spot.id] = Grow.NewPlot(spot)
            MySQL.insert.await(
                "INSERT INTO pickle_drugs_plots (id, drug, stage, stage_started_at, water_count, cut_buds, updated_at) VALUES (?,?,?,?,?,?,?)",
                { spot.id, spot.drug, 0, 0, 0, "[]", now() }
            )
        end
    end

    debugPrint(("grow: loaded %d plots from DB"):format(#spots))
end

--- Persists a plot row.
local function PersistPlot(plot)
    plot.updated_at = now()
    MySQL.update.await(
        "UPDATE pickle_drugs_plots SET stage=?, stage_started_at=?, water_count=?, cut_buds=?, updated_at=? WHERE id=?",
        {
            plot.stage,
            plot.stage_started_at,
            plot.water_count,
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

--- Plant a seed. Consumes the drug's seedItem; sets the plot's
--- stage_started_at, which kicks the lazy stage resolver into motion.
RegisterNetEvent("pickle_drugs:plant", function(plotId)
    local src = source
    local plot = Plots[plotId]
    if not plot then notify(src, "Plot not found", "error") return end
    if plot.stage ~= 0 or plot.stage_started_at ~= 0 then
        notify(src, "Already planted", "error") return
    end

    local drugCfg = Config.Drugs[plot.drug]
    if not drugCfg then return end

    -- Item requirement disabled for now — wire back via Inventory.GetItemCount /
    -- RemoveItem when an inventory item is set up for `drugCfg.seedItem`.

    plot.stage_started_at = now()
    plot.water_count      = 0
    SyncPlot(plot, true)
    notify(src, "Seed planted", "success")
end)

--- Register a single pour against a plot. Client decides when a pour
--- "lands" (when its pitcher angle and proximity to the pot are right) and
--- fires this; server just bumps the counter and re-resolves the stage.
RegisterNetEvent("pickle_drugs:water", function(plotId)
    local plot = Plots[plotId]
    if not plot then return end
    if plot.stage < 1 or plot.stage > 3 then return end
    plot.water_count = (plot.water_count or 0) + 1
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
    if not plot or plot.stage ~= 3 then return end
    budIndex = tonumber(budIndex)
    if not budIndex then return end

    local drugCfg = Config.Drugs[plot.drug]
    local s3 = drugCfg and drugCfg.stages[3]
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
                        stage_started_at BIGINT      NOT NULL DEFAULT 0,
                        water_count     TINYINT      NOT NULL DEFAULT 0,
                        cut_buds        TEXT         NOT NULL,
                        updated_at      BIGINT       NOT NULL DEFAULT 0
                    )
                ]])
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
