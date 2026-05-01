-- Authoritative plot state. Persists in oxmysql; never ticks. Stage
-- advancement is computed by Grow.ResolveStage on every read/write, and the
-- result is broadcast to clients only when the resolved state differs from
-- what's stored. Plots now belong to a house (`house_id`) and to a zone
-- inside that house's interior (`zone_id`); the zone-local cell footprint
-- is persisted alongside so collision is consistent across restarts.

local Plots = {}        -- id → plot row (in-memory cache; SQL is source of truth)

local function now() return os.time() * 1000 end

--- Builds the in-memory cache from the DB.
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
                house_id        = row.house_id or "_legacy",
                zone_id         = row.zone_id or "",
                cell_x          = tonumber(row.cell_x) or 0,
                cell_y          = tonumber(row.cell_y) or 0,
                cell_w          = tonumber(row.cell_w) or 1,
                cell_h          = tonumber(row.cell_h) or 1,
            }
            kept = kept + 1
        end
    end
    debugPrint(("grow: loaded %d plots from DB"):format(kept))
end

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

local function SyncPlot(plot, force)
    local drugCfg = Config.Drugs[plot.drug]
    local _, changed = Grow.ResolveStage(plot, drugCfg, now())
    if changed or force then
        PersistPlot(plot)
        TriggerClientEvent("pickle_drugs:plotUpdate", -1, plot)
    end
    return plot
end

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

function Grow.GetServerPlot(id) return Plots[id] end
function Grow.GetAllServerPlots() return Plots end

--- Re-binds an existing plot to a real house + zone. Used by the legacy-
--- plot migration in housing: plots created by admin `/drugs` carry
--- `house_id = "_legacy"` and never appear in the per-house panel — the
--- migration finds those whose world coords land inside a real house's
--- zone and calls this to glue them in.
function Grow.RebindPlotToHouse(plotId, houseId, zoneId, cellX, cellY, cellW, cellH)
    local plot = Plots[plotId]
    if not plot then return false end
    plot.house_id = houseId
    plot.zone_id  = zoneId
    plot.cell_x, plot.cell_y = cellX, cellY
    plot.cell_w, plot.cell_h = cellW, cellH
    MySQL.update.await(
        "UPDATE pickle_drugs_plots SET house_id=?, zone_id=?, cell_x=?, cell_y=?, cell_w=?, cell_h=? WHERE id=?",
        { houseId, zoneId, cellX, cellY, cellW, cellH, plotId }
    )
    TriggerClientEvent("pickle_drugs:plotUpdate", -1, plot)
    return true
end
function Grow.SyncServerPlot(plot, force) return SyncPlot(plot, force) end
function Grow.ServerNow() return now() end

--- Returns every plot belonging to the given house. Resolves before
--- returning so the caller sees a current snapshot.
function Grow.PlotsForHouse(houseId)
    local out = {}
    for _, plot in pairs(Plots) do
        if plot.house_id == houseId then
            SyncPlot(plot)
            out[#out + 1] = plot
        end
    end
    return out
end

--- Called by Housing when a lease lapses. We don't currently delete plots
--- (the next purchaser inherits the placements) — just broadcast a refresh
--- so clients re-evaluate their bucket-gated render.
function Grow.OnHouseLeaseLapsed(houseId)
    for _, plot in pairs(Plots) do
        if plot.house_id == houseId then
            TriggerClientEvent("pickle_drugs:plotUpdate", -1, plot)
        end
    end
end

--- Called by Housing when an admin deletes a house. Drop every plot bound
--- to it (they'd otherwise be unreachable since the bucket is gone).
function Grow.OnHouseDeleted(houseId)
    for id, plot in pairs(Plots) do
        if plot.house_id == houseId then
            Plots[id] = nil
            MySQL.update.await("DELETE FROM pickle_drugs_plots WHERE id=?", { id })
            TriggerClientEvent("pickle_drugs:plotRemoved", -1, id)
        end
    end
end

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

RegisterNetEvent("pickle_drugs:water", function(plotId, fraction)
    local plot = Plots[plotId]
    if not plot then return end
    local drugCfg = Config.Drugs[plot.drug]
    local ok = Grow.PerformWater(plot, drugCfg, now(), fraction)
    if ok then SyncPlot(plot, true) end
end)

RegisterNetEvent("pickle_drugs:requestResolve", function(plotId)
    local plot = Plots[plotId]
    if not plot then return end
    SyncPlot(plot, false)
end)

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

lib.callback.register("pickle_drugs:listDrugs", function()
    local out = {}
    for id, cfg in pairs(Config.Drugs or {}) do
        out[#out + 1] = { id = id, label = cfg.label or id }
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    debugPrint(("listDrugs -> %d entries"):format(#out))
    return out
end)

-- ─── Admin gate ────────────────────────────────────────────────────────────

local function adminCheck(src)
    if not Admin or not Admin.IsAdmin then return src == 0 end
    return Admin.IsAdmin(src)
end

local function generatePlotId(drug)
    local base = ("%s_%d"):format(drug, now())
    if not Plots[base] then return base end
    return ("%s_%d"):format(base, math.random(1000, 9999))
end

-- ─── Admin: legacy create (no house — falls through to "_legacy") ─────────

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

    -- Make sure there's a target house. Admin-placed plots default to the
    -- _legacy bucket-0 house.
    if Housing and Housing.EnsureLegacyHouse then Housing.EnsureLegacyHouse() end

    local id = generatePlotId(drug)
    local plot = Grow.NewPlot({ id = id, drug = drug, coords = { x = x, y = y, z = z, w = w } })
    plot.house_id = "_legacy"
    plot.zone_id  = ""
    plot.cell_x, plot.cell_y, plot.cell_w, plot.cell_h = 0, 0, 1, 1
    Plots[id] = plot

    MySQL.insert.await(
        "INSERT INTO pickle_drugs_plots (id, drug, stage, soil_added_at, stage_started_at, water_until, cut_buds, updated_at, coords_x, coords_y, coords_z, coords_w, house_id, zone_id, cell_x, cell_y, cell_w, cell_h) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        { id, drug, 1, 0, 0, 0, "[]", now(), x, y, z, w, "_legacy", "", 0, 0, 1, 1 }
    )

    TriggerClientEvent("pickle_drugs:plotUpdate", -1, plot)
    notify(src, ("Plot %s created"):format(id), "success")
end)

-- ─── Player: create plot inside a house zone ──────────────────────────────

RegisterNetEvent("pickle_drugs:createHousePlot", function(houseId, zoneId, drug, cx, cy, sizeX, sizeY, rotIndex)
    local src = source
    if type(drug) ~= "string" or not Config.Drugs[drug] then
        notify(src, "Unknown drug type", "error") return
    end
    if type(houseId) ~= "string" or type(zoneId) ~= "string" then return end
    cx = tonumber(cx); cy = tonumber(cy)
    sizeX = tonumber(sizeX); sizeY = tonumber(sizeY)
    rotIndex = (tonumber(rotIndex) or 0) % 4
    if not cx or not cy or not sizeX or not sizeY then return end

    if not Housing or not Housing.ValidatePlacement then
        notify(src, "Housing system not ready", "error") return
    end
    -- Build the existing-plot list for this house so the validator can
    -- check collision.
    local existing = Grow.PlotsForHouse(houseId)
    local ok, reason, world, fw, fh = Housing.ValidatePlacement(
        src, houseId, zoneId, cx, cy, sizeX, sizeY, existing
    )
    if not ok then
        notify(src, ("Can't place there (%s)"):format(reason or "?"), "error")
        return
    end

    -- Apply the player's rotation pick (0/90/180/270 around zone heading).
    local plotHeading = (world.w or 0.0) + rotIndex * 90.0

    local id = generatePlotId(drug)
    local plot = Grow.NewPlot({
        id = id, drug = drug,
        coords = { x = world.x, y = world.y, z = world.z, w = plotHeading },
    })
    plot.house_id = houseId
    plot.zone_id  = zoneId
    plot.cell_x, plot.cell_y = cx, cy
    plot.cell_w, plot.cell_h = fw, fh
    Plots[id] = plot

    MySQL.insert.await(
        "INSERT INTO pickle_drugs_plots (id, drug, stage, soil_added_at, stage_started_at, water_until, cut_buds, updated_at, coords_x, coords_y, coords_z, coords_w, house_id, zone_id, cell_x, cell_y, cell_w, cell_h) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        { id, drug, 1, 0, 0, 0, "[]", now(),
          world.x, world.y, world.z, world.w,
          houseId, zoneId, cx, cy, fw, fh }
    )
    TriggerClientEvent("pickle_drugs:plotUpdate", -1, plot)
    notify(src, "Entity placed", "success")
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

-- ─── Player: move / delete a plot inside their house ──────────────────────

--- Resident-or-owner-or-admin: re-aim a placed plot within the same house.
--- Re-runs the same placement validator the create flow uses, with the
--- moved plot excluded from the collision occupancy so it doesn't block
--- itself.
RegisterNetEvent("pickle_drugs:moveHousePlot", function(plotId, zoneId, cx, cy, sizeX, sizeY, rotIndex)
    local src = source
    local plot = Plots[plotId]
    if not plot or not plot.house_id then return end
    if type(zoneId) ~= "string" then return end
    cx = tonumber(cx); cy = tonumber(cy)
    sizeX = tonumber(sizeX); sizeY = tonumber(sizeY)
    rotIndex = (tonumber(rotIndex) or 0) % 4
    if not cx or not cy or not sizeX or not sizeY then return end

    if not Housing or not Housing.ValidatePlacement then
        notify(src, "Housing system not ready", "error") return
    end
    local existing = {}
    for _, p in ipairs(Grow.PlotsForHouse(plot.house_id)) do
        if p.id ~= plotId then existing[#existing + 1] = p end
    end
    local ok, reason, world, fw, fh = Housing.ValidatePlacement(
        src, plot.house_id, zoneId, cx, cy, sizeX, sizeY, existing
    )
    if not ok then
        notify(src, ("Can't place there (%s)"):format(reason or "?"), "error")
        return
    end
    local plotHeading = (world.w or 0.0) + rotIndex * 90.0

    plot.zone_id = zoneId
    plot.cell_x, plot.cell_y = cx, cy
    plot.cell_w, plot.cell_h = fw, fh
    plot.coords_x, plot.coords_y, plot.coords_z, plot.coords_w =
        world.x, world.y, world.z, plotHeading
    MySQL.update.await(
        "UPDATE pickle_drugs_plots SET zone_id=?, cell_x=?, cell_y=?, cell_w=?, cell_h=?, coords_x=?, coords_y=?, coords_z=?, coords_w=? WHERE id=?",
        { zoneId, cx, cy, fw, fh, world.x, world.y, world.z, plotHeading, plotId }
    )
    TriggerClientEvent("pickle_drugs:plotUpdate", -1, plot)
    notify(src, "Entity moved", "success")
end)

--- Resident-or-owner-or-admin delete. Routed through the housing access
--- check rather than the global admin gate so house owners can clean up
--- their own props.
RegisterNetEvent("pickle_drugs:deleteHousePlot", function(plotId)
    local src = source
    local plot = Plots[plotId]
    if not plot or not plot.house_id then return end
    local h = Housing and Housing.GetHouse and Housing.GetHouse(plot.house_id) or nil
    if not h then return end
    local allowed = adminCheck(src)
        or (Housing.IsHouseOwner and Housing.IsHouseOwner(src, h))
        or (Housing.PlayerCanAccess and Housing.PlayerCanAccess(src, h))
    if not allowed then return end
    Plots[plotId] = nil
    MySQL.update.await("DELETE FROM pickle_drugs_plots WHERE id=?", { plotId })
    TriggerClientEvent("pickle_drugs:plotRemoved", -1, plotId)
    notify(src, "Entity removed", "success")
end)

-- ─── Boot ───────────────────────────────────────────────────────────────────

CreateThread(function()
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
                local cols = MySQL.query.await(
                    "SHOW COLUMNS FROM pickle_drugs_plots WHERE Field IN ('water_count','water_until','soil_added_at','coords_x','coords_y','coords_z','coords_w','house_id','zone_id','cell_x','cell_y','cell_w','cell_h')"
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
                    MySQL.query.await("DELETE FROM pickle_drugs_plots WHERE coords_x = 0 AND coords_y = 0 AND coords_z = 0")
                end
                -- Housing migration: add house_id / zone_id / cell_*. Any
                -- pre-existing rows are reassigned to the auto-generated
                -- _legacy house so they stay reachable.
                if not has.house_id then
                    MySQL.query.await("ALTER TABLE pickle_drugs_plots ADD COLUMN house_id VARCHAR(64) NOT NULL DEFAULT '_legacy'")
                end
                if not has.zone_id then
                    MySQL.query.await("ALTER TABLE pickle_drugs_plots ADD COLUMN zone_id VARCHAR(64) NOT NULL DEFAULT ''")
                end
                if not has.cell_x then
                    MySQL.query.await("ALTER TABLE pickle_drugs_plots ADD COLUMN cell_x INT NOT NULL DEFAULT 0")
                    MySQL.query.await("ALTER TABLE pickle_drugs_plots ADD COLUMN cell_y INT NOT NULL DEFAULT 0")
                    MySQL.query.await("ALTER TABLE pickle_drugs_plots ADD COLUMN cell_w INT NOT NULL DEFAULT 1")
                    MySQL.query.await("ALTER TABLE pickle_drugs_plots ADD COLUMN cell_h INT NOT NULL DEFAULT 1")
                end
                -- Make sure the _legacy house exists before any plot rows
                -- claim it. Housing.EnsureLegacyHouse is idempotent.
                if Housing and Housing.EnsureLegacyHouse then
                    Housing.EnsureLegacyHouse()
                end
                -- Reassign any orphan rows that ended up with empty house_id.
                MySQL.query.await(
                    "UPDATE pickle_drugs_plots SET house_id='_legacy' WHERE house_id IS NULL OR house_id=''"
                )
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
            -- Other modules (housing.getHouseDetail, employees roster
            -- migration) gate on this so they don't return empty data
            -- to a player who interacts seconds after a hot restart.
            Grow.IsReady = true
        end)
    end

    Wait(5000)
    if not readyFired then
        print("[pickle_drugs] grow: MySQL.ready never fired after 5s — running with zero plots")
    end
end)

AddEventHandler("playerJoining", function()
    local src = source
    SetTimeout(2000, function()
        for _, plot in pairs(Plots) do
            SyncPlot(plot)
            TriggerClientEvent("pickle_drugs:plotUpdate", src, plot)
        end
    end)
end)
