-- Authoritative plot state. Persists in oxmysql; never ticks. Stage
-- advancement is computed by Grow.ResolveStage on every read/write, and the
-- result is broadcast to clients only when the resolved state differs from
-- what's stored.

local Plots = {}        -- id → plot row (in-memory cache; SQL is source of truth)

local function now() return os.time() * 1000 end

--- Builds the in-memory cache from the DB. Coords now live on the row
--- itself; there's no longer a static config to seed from. Rows missing
--- coords (legacy installs) are dropped — they predate the creator UI
--- and the admin will re-place them via /drugs.
local function LoadPlots()
    local rows = MySQL.query.await("SELECT * FROM pickle_drugs_plots") or {}
    local kept = 0
    for _, row in ipairs(rows) do
        local x, y, z = tonumber(row.coords_x), tonumber(row.coords_y), tonumber(row.coords_z)
        if x and y and z and (x ~= 0 or y ~= 0 or z ~= 0) then
            local cutBuds = row.cut_buds
            if type(cutBuds) == "string" then
                cutBuds = json.decode(cutBuds) or {}
            end
            local stage = tonumber(row.stage) or 0
            if stage < 1 then stage = 1 end
            local soilAddedAt = tonumber(row.soil_added_at) or 0
            local stageStartedAt = tonumber(row.stage_started_at) or 0
            if soilAddedAt == 0 and stageStartedAt > 0 then
                soilAddedAt = stageStartedAt
            end
            Plots[row.id] = {
                id              = row.id,
                drug            = row.drug,
                stage           = stage,
                soil_added_at   = soilAddedAt,
                stage_started_at = stageStartedAt,
                water_until     = tonumber(row.water_until) or 0,
                cut_buds        = cutBuds or {},
                updated_at      = tonumber(row.updated_at) or 0,
                coords_x        = x,
                coords_y        = y,
                coords_z        = z,
                coords_w        = tonumber(row.coords_w) or 0,
            }
            kept = kept + 1
        end
    end
    debugPrint(("grow: loaded %d plots from DB"):format(kept))
end

--- Persists a plot row's gameplay state. Coords are persisted separately
--- by the CRUD events (create / updatePlotCoords) and never change here.
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

--- Cross-module hooks. The employee scheduler (modules/employees/server)
--- needs read access to plots and a way to push state through the same
--- broadcast/persist pipeline the player events use.
function Grow.GetServerPlot(id) return Plots[id] end
function Grow.GetAllServerPlots() return Plots end
function Grow.SyncServerPlot(plot, force) return SyncPlot(plot, force) end
function Grow.ServerNow() return now() end

local SOIL_ERR = {
    no_plot         = "Plot not found",
    already_soiled  = "Soil already added",
}
local PLANT_ERR = {
    no_plot          = "Plot not found",
    needs_soil       = "Add soil first",
    already_planted  = "Already planted",
    no_drug_cfg      = "Unknown drug",
}

RegisterNetEvent("pickle_drugs:addSoil", function(plotId)
    local src = source
    local plot = Plots[plotId]
    local ok, reason = Grow.PerformAddSoil(plot, now())
    if not ok then
        notify(src, SOIL_ERR[reason] or "Failed", "error")
        return
    end
    SyncPlot(plot, true)
    notify(src, "Soil added", "success")
end)

RegisterNetEvent("pickle_drugs:plant", function(plotId)
    local src = source
    local plot = Plots[plotId]
    local drugCfg = plot and Config.Drugs[plot.drug] or nil
    local ok, reason = Grow.PerformPlant(plot, drugCfg, now())
    if not ok then
        notify(src, PLANT_ERR[reason] or "Failed", "error")
        return
    end
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
    local ok = Grow.PerformWater(plot, drugCfg, now(), fraction)
    if ok then SyncPlot(plot, true) end
end)

--- Client-side ticker pings this when its locally-resolved stage diverges
--- from the cached server stage. We re-run SyncPlot which is no-op unless
--- the resolver actually advances the plot.
RegisterNetEvent("pickle_drugs:requestResolve", function(plotId)
    local plot = Plots[plotId]
    if not plot then return end
    SyncPlot(plot, false)
end)

--- Cut one bud at the harvest stage. Awards the harvest item to the
--- player who initiated the cut; NPC employees skip the inventory step
--- by calling Grow.PerformCutBud directly without going through this
--- event handler.
RegisterNetEvent("pickle_drugs:cutBud", function(plotId, budIndex)
    local src = source
    local plot = Plots[plotId]
    if not plot then return end
    local drugCfg = Config.Drugs[plot.drug]
    local ok = Grow.PerformCutBud(plot, drugCfg, budIndex)
    if not ok then return end

    local harvestItem = drugCfg and drugCfg.cutting and drugCfg.cutting.harvestItem
    if harvestItem and Inventory and Inventory.AddItem then
        Inventory.AddItem(src, harvestItem, 1)
    end
    SyncPlot(plot, true)
end)

-- ─── Callbacks ──────────────────────────────────────────────────────────────

lib.callback.register("pickle_drugs:getPlots", function()
    return GetAllPlots()
end)

--- Drug picker for the creator UI. Returns each entry in Config.Drugs as
--- { id, label } so the client doesn't need access to the full drug
--- recipe (which is server-only-loadable in shared scope).
lib.callback.register("pickle_drugs:listDrugs", function()
    local out = {}
    for id, cfg in pairs(Config.Drugs or {}) do
        out[#out + 1] = { id = id, label = cfg.label or id }
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    debugPrint(("listDrugs -> %d entries"):format(#out))
    return out
end)

-- ─── Admin CRUD events ─────────────────────────────────────────────────────

local function adminCheck(src)
    if not Admin or not Admin.IsAdmin then return src == 0 end
    return Admin.IsAdmin(src)
end

local function generatePlotId(drug)
    -- Human-readable ID keyed on drug + ms epoch. Collision-free for any
    -- realistic create cadence; falls back to a random suffix if a row
    -- with the same id somehow exists.
    local base = ("%s_%d"):format(drug, now())
    if not Plots[base] then return base end
    return ("%s_%d"):format(base, math.random(1000, 9999))
end

RegisterNetEvent("pickle_drugs:createPlot", function(drug, x, y, z, w)
    local src = source
    if not adminCheck(src) then return end
    if type(drug) ~= "string" or not Config.Drugs[drug] then
        notify(src, "Unknown drug type", "error") return
    end
    x = tonumber(x); y = tonumber(y); z = tonumber(z); w = tonumber(w) or 0.0
    if not x or not y or not z then
        notify(src, "Invalid coordinates", "error") return
    end

    local id = generatePlotId(drug)
    local plot = Grow.NewPlot({ id = id, drug = drug, coords = { x = x, y = y, z = z, w = w } })
    Plots[id] = plot

    MySQL.insert.await(
        "INSERT INTO pickle_drugs_plots (id, drug, stage, soil_added_at, stage_started_at, water_until, cut_buds, updated_at, coords_x, coords_y, coords_z, coords_w) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
        { id, drug, 1, 0, 0, 0, "[]", now(), x, y, z, w }
    )

    TriggerClientEvent("pickle_drugs:plotUpdate", -1, plot)
    notify(src, ("Plot %s created"):format(id), "success")
end)

RegisterNetEvent("pickle_drugs:updatePlotCoords", function(plotId, x, y, z, w)
    local src = source
    if not adminCheck(src) then return end
    local plot = Plots[plotId]
    if not plot then notify(src, "Plot not found", "error") return end
    x = tonumber(x); y = tonumber(y); z = tonumber(z); w = tonumber(w) or 0.0
    if not x or not y or not z then return end

    plot.coords_x, plot.coords_y, plot.coords_z, plot.coords_w = x, y, z, w
    MySQL.update.await(
        "UPDATE pickle_drugs_plots SET coords_x=?, coords_y=?, coords_z=?, coords_w=? WHERE id=?",
        { x, y, z, w, plotId }
    )
    TriggerClientEvent("pickle_drugs:plotUpdate", -1, plot)
    notify(src, "Plot moved", "success")
end)

RegisterNetEvent("pickle_drugs:deletePlot", function(plotId)
    local src = source
    if not adminCheck(src) then return end
    if not Plots[plotId] then return end
    Plots[plotId] = nil
    MySQL.update.await("DELETE FROM pickle_drugs_plots WHERE id=?", { plotId })
    TriggerClientEvent("pickle_drugs:plotRemoved", -1, plotId)
    notify(src, "Plot deleted", "success")
end)

-- ─── Boot ───────────────────────────────────────────────────────────────────

CreateThread(function()
    -- Wait for oxmysql + schema, then load. With static config gone, plots
    -- only exist in the DB — without one the resource simply has zero
    -- plots and the admin must create them via /drugs.
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
                        updated_at      BIGINT       NOT NULL DEFAULT 0,
                        coords_x        DOUBLE       NOT NULL DEFAULT 0,
                        coords_y        DOUBLE       NOT NULL DEFAULT 0,
                        coords_z        DOUBLE       NOT NULL DEFAULT 0,
                        coords_w        DOUBLE       NOT NULL DEFAULT 0
                    )
                ]])
                -- Schema migrations. Each step is idempotent (gated on
                -- whether the column already exists).
                local cols = MySQL.query.await(
                    "SHOW COLUMNS FROM pickle_drugs_plots WHERE Field IN ('water_count','water_until','soil_added_at','coords_x','coords_y','coords_z','coords_w')"
                ) or {}
                local has = {}
                for _, c in ipairs(cols) do has[c.Field] = true end
                if has.water_count and not has.water_until then
                    MySQL.query.await("ALTER TABLE pickle_drugs_plots CHANGE water_count water_until BIGINT NOT NULL DEFAULT 0")
                    MySQL.query.await("UPDATE pickle_drugs_plots SET water_until = 0")
                end
                if not has.soil_added_at then
                    MySQL.query.await("ALTER TABLE pickle_drugs_plots ADD COLUMN soil_added_at BIGINT NOT NULL DEFAULT 0 AFTER stage")
                    MySQL.query.await("UPDATE pickle_drugs_plots SET soil_added_at = stage_started_at WHERE stage_started_at > 0")
                end
                if not has.coords_x then
                    MySQL.query.await("ALTER TABLE pickle_drugs_plots ADD COLUMN coords_x DOUBLE NOT NULL DEFAULT 0")
                    MySQL.query.await("ALTER TABLE pickle_drugs_plots ADD COLUMN coords_y DOUBLE NOT NULL DEFAULT 0")
                    MySQL.query.await("ALTER TABLE pickle_drugs_plots ADD COLUMN coords_z DOUBLE NOT NULL DEFAULT 0")
                    MySQL.query.await("ALTER TABLE pickle_drugs_plots ADD COLUMN coords_w DOUBLE NOT NULL DEFAULT 0")
                    -- Legacy rows had no coords (Config.GrowSpots used to
                    -- supply them). With the static config gone they're
                    -- unrecoverable — drop them so the admin re-places
                    -- via /drugs.
                    MySQL.query.await("DELETE FROM pickle_drugs_plots WHERE coords_x = 0 AND coords_y = 0 AND coords_z = 0")
                end
                LoadPlots()
            end)
            if not ok then
                print(("[pickle_drugs] grow: DB error, starting empty: %s"):format(tostring(err)))
            end
            for _, plot in pairs(Plots) do
                SyncPlot(plot, true)
            end
            local count = 0
            for _ in pairs(Plots) do count = count + 1 end
            print(("[pickle_drugs] grow: ready with %d plots"):format(count))
        end)
    end

    -- Watchdog: if MySQL.ready hasn't fired after 5s, log and continue —
    -- without coords there's nothing useful to seed in-memory.
    Wait(5000)
    if not readyFired then
        print("[pickle_drugs] grow: MySQL.ready never fired after 5s — running with zero plots")
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
