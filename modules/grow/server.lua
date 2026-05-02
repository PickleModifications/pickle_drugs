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
    local rows = MySQL.query.await(
        "SELECT * FROM pickle_drugs_entities WHERE kind='plot'") or {}
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
                house_id        = row.house_id,
                zone_id         = row.zone_id or "",
                cell_x          = tonumber(row.cell_x) or 0,
                cell_y          = tonumber(row.cell_y) or 0,
                cell_w          = tonumber(row.cell_w) or 1,
                cell_h          = tonumber(row.cell_h) or 1,
                output_locker_id = (type(row.output_locker_id) == "string" and row.output_locker_id ~= "")
                                   and row.output_locker_id or nil,
            }
            kept = kept + 1
        end
    end
    debugPrint(("grow: loaded %d plots from DB"):format(kept))
end

local function PersistPlot(plot)
    plot.updated_at = now()
    MySQL.update.await(
        "UPDATE pickle_drugs_entities SET stage=?, soil_added_at=?, stage_started_at=?, water_until=?, cut_buds=?, updated_at=? WHERE id=?",
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

--- Called by Storage when a locker is removed. Clears any plots that
--- pointed at it so their next harvest doesn't route to a phantom row.
function Grow.OnLockerDeleted(lockerId)
    if not lockerId then return end
    for _, plot in pairs(Plots) do
        if plot.output_locker_id == lockerId then
            plot.output_locker_id = nil
            MySQL.update.await(
                "UPDATE pickle_drugs_entities SET output_locker_id=NULL WHERE id=?",
                { plot.id }
            )
            TriggerClientEvent("pickle_drugs:plotUpdate", -1, plot)
        end
    end
end

--- Sets the output destination locker for harvested goods. Pass nil/""
--- to unset. Returns true on success.
function Grow.SetPlotOutput(plotId, lockerId)
    local plot = Plots[plotId]
    if not plot then return false end
    if lockerId == "" then lockerId = nil end
    plot.output_locker_id = lockerId
    MySQL.update.await(
        "UPDATE pickle_drugs_entities SET output_locker_id=? WHERE id=?",
        { lockerId, plotId }
    )
    TriggerClientEvent("pickle_drugs:plotUpdate", -1, plot)
    return true
end

RegisterNetEvent("pickle_drugs:setPlotOutput", function(plotId, lockerId)
    local src = source
    local plot = Plots[plotId]
    if not plot or not plot.house_id then return end
    local h = Housing and Housing.GetHouse and Housing.GetHouse(plot.house_id)
    if not h then return end
    local isAdmin = (Admin and Admin.IsAdmin and Admin.IsAdmin(src)) or src == 0
    local allowed = isAdmin
        or (Housing.IsHouseOwner and Housing.IsHouseOwner(src, h))
        or (Housing.PlayerCanAccess and Housing.PlayerCanAccess(src, h))
    if not allowed then return end
    -- Validate the locker belongs to the same house. nil/"" clears.
    if type(lockerId) == "string" and lockerId ~= "" then
        local locker = Storage and Storage.GetLocker and Storage.GetLocker(lockerId)
        if not locker or locker.house_id ~= plot.house_id then return end
    else
        lockerId = nil
    end
    Grow.SetPlotOutput(plotId, lockerId)
    notify(src, lockerId and "Output set" or "Output cleared", "success")
end)

--- Binds an existing plot to a house + zone. Used by the boot orphan
--- scrub when a plot's coords land inside a real house's zone.
function Grow.BindPlotToHouse(plotId, houseId, zoneId, cellX, cellY, cellW, cellH)
    local plot = Plots[plotId]
    if not plot then return false end
    plot.house_id = houseId
    plot.zone_id  = zoneId
    plot.cell_x, plot.cell_y = cellX, cellY
    plot.cell_w, plot.cell_h = cellW, cellH
    MySQL.update.await(
        "UPDATE pickle_drugs_entities SET house_id=?, zone_id=?, cell_x=?, cell_y=?, cell_w=?, cell_h=? WHERE id=?",
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
            MySQL.update.await("DELETE FROM pickle_drugs_entities WHERE id=?", { id })
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

--- Returns true if the player holds at least `count` of `item`. Treats a
--- missing item name (config nil/false) as "no gate".
local function hasItem(src, item, count)
    if not item or item == "" then return true end
    if not (Inventory and Inventory.GetItemCount) then return true end
    return (Inventory.GetItemCount(src, item) or 0) >= (count or 1)
end

--- Removes `count` of `item` from the player. Returns true on success or
--- if no gate is configured. Notifies + returns false otherwise.
local function consumeItem(src, item, count, missingMsg)
    if not item or item == "" then return true end
    count = count or 1
    if not hasItem(src, item, count) then
        if missingMsg then notify(src, missingMsg, "error") end
        return false
    end
    if Inventory and Inventory.RemoveItem then
        local ok = Inventory.RemoveItem(src, item, count)
        if ok == false then
            if missingMsg then notify(src, missingMsg, "error") end
            return false
        end
    end
    return true
end

RegisterNetEvent("pickle_drugs:addSoil", function(plotId)
    local src = source
    local plot = Plots[plotId]
    if not plot then notify(src, SOIL_ERR.no_plot, "error") return end
    -- Pre-check both the soiling state AND the bag of soil before mutating
    -- anything. PerformAddSoil flips the plot to "soiled" so calling it
    -- before consuming the item would let a player without a soil bag
    -- still progress the plot.
    if (plot.soil_added_at or 0) > 0 then
        notify(src, SOIL_ERR.already_soiled, "error") return
    end
    local soilItem = Config.Items and Config.Items.soilBag
    if not consumeItem(src, soilItem, 1, "You need a bag of soil") then return end

    local ok, reason = Grow.PerformAddSoil(plot, now())
    if not ok then
        -- Refund: PerformAddSoil rejected after we charged. Should be
        -- unreachable given the guards above, but stay safe.
        if soilItem and Inventory and Inventory.AddItem then
            Inventory.AddItem(src, soilItem, 1)
        end
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
    if not plot then notify(src, PLANT_ERR.no_plot, "error") return end
    if not drugCfg then notify(src, PLANT_ERR.no_drug_cfg, "error") return end
    if (plot.soil_added_at or 0) <= 0 then
        notify(src, PLANT_ERR.needs_soil, "error") return
    end
    if (plot.stage_started_at or 0) > 0 then
        notify(src, PLANT_ERR.already_planted, "error") return
    end
    local seedItem = drugCfg.planting and drugCfg.planting.seedItem
    if not consumeItem(src, seedItem, 1, "You need a seed for this plant") then return end

    local ok, reason = Grow.PerformPlant(plot, drugCfg, now())
    if not ok then
        if seedItem and Inventory and Inventory.AddItem then
            Inventory.AddItem(src, seedItem, 1)
        end
        notify(src, PLANT_ERR[reason] or "Failed", "error")
        return
    end
    SyncPlot(plot, true)
    notify(src, "Seed planted", "success")
end)

RegisterNetEvent("pickle_drugs:water", function(plotId, fraction)
    local src = source
    local plot = Plots[plotId]
    if not plot then return end
    -- Watering can is a tool — required, not consumed.
    local can = Config.Items and Config.Items.wateringCan
    if not hasItem(src, can, 1) then
        notify(src, "You need a watering pitcher", "error") return
    end
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
    -- Scissors are a tool — required, not consumed.
    local scissors = Config.Items and Config.Items.scissors
    if not hasItem(src, scissors, 1) then
        notify(src, "You need trimming scissors", "error") return
    end
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

--- Returns a map { itemName = count } for the supplied list of items.
--- Used by the plant scene client to gate action buttons (and the
--- pre-flight check before opening soiling/planting/watering/cutting
--- mini-flows) on whether the player actually holds the required tool
--- or consumable. Server is still authoritative on the actual consume.
lib.callback.register("pickle_drugs:getItemCounts", function(src, items)
    local out = {}
    if type(items) ~= "table" then return out end
    if not (Inventory and Inventory.GetItemCount) then
        for _, name in ipairs(items) do out[name] = 999 end
        return out
    end
    for _, name in ipairs(items) do
        if type(name) == "string" and name ~= "" and out[name] == nil then
            out[name] = Inventory.GetItemCount(src, name) or 0
        end
    end
    return out
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

-- ─── Player: create plot inside a house zone ──────────────────────────────

RegisterNetEvent("pickle_drugs:createHousePlot", function(houseId, zoneId, drug, cx, cy, sizeX, sizeY, rotIndex)
    local src = source
    if type(drug) ~= "string" or not Config.Drugs[drug] then
        notify(src, "Unknown drug type", "error") return
    end
    if type(houseId) ~= "string" or houseId == "" or type(zoneId) ~= "string" or zoneId == "" then
        notify(src, "Pick a property first", "error") return
    end
    cx = tonumber(cx); cy = tonumber(cy)
    sizeX = tonumber(sizeX); sizeY = tonumber(sizeY)
    rotIndex = (tonumber(rotIndex) or 0) % 4
    if not cx or not cy or not sizeX or not sizeY then return end

    if not Housing or not Housing.ValidatePlacement then
        notify(src, "Housing system not ready", "error") return
    end
    if not Housing.GetHouse or not Housing.GetHouse(houseId) then
        notify(src, "Property no longer exists", "error") return
    end
    -- Consume the planter item up front. We refund below if the
    -- placement validator rejects (out of bounds, intersects, etc.).
    local potItem = Config.Items and Config.Items.pot
    if not consumeItem(src, potItem, 1, "You need an empty planter") then return end
    -- Build the existing-entity list for this house so the validator can
    -- check collision. Includes plots and storage lockers — both occupy
    -- cells in the same zone grid and must not overlap.
    local existing = Grow.PlotsForHouse(houseId)
    if Storage and Storage.PlacementRowsForHouse then
        for _, l in ipairs(Storage.PlacementRowsForHouse(houseId)) do
            existing[#existing + 1] = l
        end
    end
    local ok, reason, world, fw, fh = Housing.ValidatePlacement(
        src, houseId, zoneId, cx, cy, sizeX, sizeY, rotIndex, existing
    )
    if not ok then
        if potItem and Inventory and Inventory.AddItem then
            Inventory.AddItem(src, potItem, 1)
        end
        notify(src, ("Can't place there (%s)"):format(reason or "?"), "error")
        return
    end

    -- world.w is already the final placement heading (zone heading +
    -- rotIndex*90) — Housing.ValidatePlacement applies it for us.
    local id = generatePlotId(drug)
    local plot = Grow.NewPlot({
        id = id, drug = drug,
        coords = { x = world.x, y = world.y, z = world.z, w = world.w },
    })
    plot.house_id = houseId
    plot.zone_id  = zoneId
    plot.cell_x, plot.cell_y = cx, cy
    plot.cell_w, plot.cell_h = fw, fh
    Plots[id] = plot

    MySQL.insert.await(
        "INSERT INTO pickle_drugs_entities (id, kind, drug, stage, soil_added_at, stage_started_at, water_until, cut_buds, updated_at, coords_x, coords_y, coords_z, coords_w, house_id, zone_id, cell_x, cell_y, cell_w, cell_h, metadata) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        { id, "plot", drug, 1, 0, 0, 0, "[]", now(),
          world.x, world.y, world.z, world.w,
          houseId, zoneId, cx, cy, fw, fh, nil }
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
        "UPDATE pickle_drugs_entities SET coords_x=?, coords_y=?, coords_z=?, coords_w=? WHERE id=?",
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
    MySQL.update.await("DELETE FROM pickle_drugs_entities WHERE id=?", { plotId })
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
    -- Cancel any worker mid-task on this plot before its coords change
    -- under their feet — otherwise the ped would arrive at the old
    -- position or finish its work timer against the stale plot record.
    if Employees and Employees.AbortPlot then Employees.AbortPlot(plotId) end
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
    if Storage and Storage.PlacementRowsForHouse then
        for _, l in ipairs(Storage.PlacementRowsForHouse(plot.house_id)) do
            existing[#existing + 1] = l
        end
    end
    local ok, reason, world, fw, fh = Housing.ValidatePlacement(
        src, plot.house_id, zoneId, cx, cy, sizeX, sizeY, rotIndex, existing
    )
    if not ok then
        notify(src, ("Can't place there (%s)"):format(reason or "?"), "error")
        return
    end

    plot.zone_id = zoneId
    plot.cell_x, plot.cell_y = cx, cy
    plot.cell_w, plot.cell_h = fw, fh
    plot.coords_x, plot.coords_y, plot.coords_z, plot.coords_w =
        world.x, world.y, world.z, world.w
    MySQL.update.await(
        "UPDATE pickle_drugs_entities SET zone_id=?, cell_x=?, cell_y=?, cell_w=?, cell_h=?, coords_x=?, coords_y=?, coords_z=?, coords_w=? WHERE id=?",
        { zoneId, cx, cy, fw, fh, world.x, world.y, world.z, world.w, plotId }
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
    if Employees and Employees.AbortPlot then Employees.AbortPlot(plotId) end
    Plots[plotId] = nil
    MySQL.update.await("DELETE FROM pickle_drugs_entities WHERE id=?", { plotId })
    TriggerClientEvent("pickle_drugs:plotRemoved", -1, plotId)
    -- Refund the planter so the player can move it elsewhere. Soil and
    -- seed (if used) stay consumed — they were destroyed when applied.
    local potItem = Config.Items and Config.Items.pot
    if potItem and Inventory and Inventory.AddItem then
        Inventory.AddItem(src, potItem, 1)
    end
    notify(src, "Entity removed", "success")
end)

-- ─── Boot ───────────────────────────────────────────────────────────────────

CreateThread(function()
    local readyFired = false
    if MySQL and MySQL.ready then
        MySQL.ready(function()
            readyFired = true
            local ok, err = pcall(function()
                -- Pre-rename: an earlier schema put plot rows in
                -- `pickle_drugs_plots`. The unified entities table reuses
                -- the same columns, so we rename in place when the new
                -- table doesn't exist yet.
                local function tableExists(name)
                    local r = MySQL.query.await(
                        "SHOW TABLES LIKE ?", { name }) or {}
                    return #r > 0
                end
                if tableExists("pickle_drugs_plots")
                    and not tableExists("pickle_drugs_entities") then
                    MySQL.query.await(
                        "RENAME TABLE pickle_drugs_plots TO pickle_drugs_entities")
                end

                MySQL.query.await([[
                    CREATE TABLE IF NOT EXISTS pickle_drugs_entities (
                        id              VARCHAR(64)  PRIMARY KEY,
                        kind            VARCHAR(32)  NOT NULL DEFAULT 'plot',
                        drug            VARCHAR(32)  NOT NULL DEFAULT '',
                        stage           TINYINT      NOT NULL DEFAULT 0,
                        soil_added_at   BIGINT       NOT NULL DEFAULT 0,
                        stage_started_at BIGINT      NOT NULL DEFAULT 0,
                        water_until     BIGINT       NOT NULL DEFAULT 0,
                        cut_buds        TEXT         NOT NULL,
                        updated_at      BIGINT       NOT NULL DEFAULT 0,
                        coords_x        DOUBLE       NOT NULL DEFAULT 0,
                        coords_y        DOUBLE       NOT NULL DEFAULT 0,
                        coords_z        DOUBLE       NOT NULL DEFAULT 0,
                        coords_w        DOUBLE       NOT NULL DEFAULT 0,
                        metadata        LONGTEXT     NULL
                    )
                ]])
                local cols = MySQL.query.await(
                    "SHOW COLUMNS FROM pickle_drugs_entities WHERE Field IN ('water_count','water_until','soil_added_at','coords_x','coords_y','coords_z','coords_w','house_id','zone_id','cell_x','cell_y','cell_w','cell_h','kind','metadata','drug','output_locker_id')"
                ) or {}
                local has = {}
                for _, c in ipairs(cols) do has[c.Field] = true end
                if not has.output_locker_id then
                    MySQL.query.await("ALTER TABLE pickle_drugs_entities ADD COLUMN output_locker_id VARCHAR(64) NULL")
                end
                if not has.kind then
                    MySQL.query.await("ALTER TABLE pickle_drugs_entities ADD COLUMN kind VARCHAR(32) NOT NULL DEFAULT 'plot' AFTER id")
                end
                if not has.metadata then
                    MySQL.query.await("ALTER TABLE pickle_drugs_entities ADD COLUMN metadata LONGTEXT NULL")
                end
                -- Storage rows write the empty string for `drug`; relax
                -- the column so the legacy NOT NULL constraint allows it.
                if has.drug then
                    MySQL.query.await(
                        "ALTER TABLE pickle_drugs_entities MODIFY COLUMN drug VARCHAR(32) NOT NULL DEFAULT ''")
                end
                if has.water_count and not has.water_until then
                    MySQL.query.await("ALTER TABLE pickle_drugs_entities CHANGE water_count water_until BIGINT NOT NULL DEFAULT 0")
                    MySQL.query.await("UPDATE pickle_drugs_entities SET water_until = 0")
                end
                if not has.soil_added_at then
                    MySQL.query.await("ALTER TABLE pickle_drugs_entities ADD COLUMN soil_added_at BIGINT NOT NULL DEFAULT 0 AFTER stage")
                    MySQL.query.await("UPDATE pickle_drugs_entities SET soil_added_at = stage_started_at WHERE stage_started_at > 0")
                end
                if not has.coords_x then
                    MySQL.query.await("ALTER TABLE pickle_drugs_entities ADD COLUMN coords_x DOUBLE NOT NULL DEFAULT 0")
                    MySQL.query.await("ALTER TABLE pickle_drugs_entities ADD COLUMN coords_y DOUBLE NOT NULL DEFAULT 0")
                    MySQL.query.await("ALTER TABLE pickle_drugs_entities ADD COLUMN coords_z DOUBLE NOT NULL DEFAULT 0")
                    MySQL.query.await("ALTER TABLE pickle_drugs_entities ADD COLUMN coords_w DOUBLE NOT NULL DEFAULT 0")
                    MySQL.query.await("DELETE FROM pickle_drugs_entities WHERE coords_x = 0 AND coords_y = 0 AND coords_z = 0")
                end
                -- Housing migration: add house_id / zone_id / cell_*.
                if not has.house_id then
                    MySQL.query.await("ALTER TABLE pickle_drugs_entities ADD COLUMN house_id VARCHAR(64) NULL")
                end
                if not has.zone_id then
                    MySQL.query.await("ALTER TABLE pickle_drugs_entities ADD COLUMN zone_id VARCHAR(64) NOT NULL DEFAULT ''")
                end
                if not has.cell_x then
                    MySQL.query.await("ALTER TABLE pickle_drugs_entities ADD COLUMN cell_x INT NOT NULL DEFAULT 0")
                    MySQL.query.await("ALTER TABLE pickle_drugs_entities ADD COLUMN cell_y INT NOT NULL DEFAULT 0")
                    MySQL.query.await("ALTER TABLE pickle_drugs_entities ADD COLUMN cell_w INT NOT NULL DEFAULT 1")
                    MySQL.query.await("ALTER TABLE pickle_drugs_entities ADD COLUMN cell_h INT NOT NULL DEFAULT 1")
                end

                -- Migrate any rows from the short-lived per-type storage
                -- table into the unified entities table, then drop it.
                if tableExists("pickle_drugs_storage") then
                    local sRows = MySQL.query.await(
                        "SELECT * FROM pickle_drugs_storage") or {}
                    for _, r in ipairs(sRows) do
                        local existing = MySQL.query.await(
                            "SELECT id FROM pickle_drugs_entities WHERE id=?",
                            { r.id }) or {}
                        if #existing == 0 then
                            local items = r.items
                            if type(items) == "string" then
                                local okJ, v = pcall(json.decode, items)
                                items = okJ and v or {}
                            end
                            local meta = json.encode({
                                subType = r.kind,
                                items   = items or {},
                            })
                            MySQL.insert.await([[
                                INSERT INTO pickle_drugs_entities
                                    (id, kind, drug, stage, soil_added_at, stage_started_at, water_until, cut_buds,
                                     coords_x, coords_y, coords_z, coords_w,
                                     house_id, zone_id, cell_x, cell_y, cell_w, cell_h,
                                     metadata, updated_at)
                                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                            ]], {
                                r.id, "storage", "", 0, 0, 0, 0, "[]",
                                r.coords_x, r.coords_y, r.coords_z, r.coords_w,
                                r.house_id, r.zone_id,
                                r.cell_x, r.cell_y, r.cell_w, r.cell_h,
                                meta, r.updated_at,
                            })
                        end
                    end
                    MySQL.query.await("DROP TABLE pickle_drugs_storage")
                    print(("[pickle_drugs] migrated %d storage row(s) into entities"):format(#sRows))
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
            -- Other modules (housing.getHouseDetail, employees roster
            -- migration) gate on this so they don't return empty data
            -- to a player who interacts seconds after a hot restart.
            Grow.IsReady = true

            -- Register usable inventory items. The framework bridge fans
            -- this out to whichever framework is active (ESX / QB / QBX).
            -- Using the planter from the player's inventory opens the
            -- placement flow inside their current house — the actual
            -- consume happens server-side when they confirm via
            -- createHousePlot.
            if Framework and Framework.RegisterUsableItem then
                local potItem = Config.Items and Config.Items.pot
                if potItem then
                    Framework.RegisterUsableItem(potItem, function(src)
                        TriggerClientEvent("pickle_drugs:openPotPlacement", src)
                    end)
                end
            end

            -- Orphan scrub. Every plot must belong to a real house. Wait
            -- for housing to publish its roster, then for each plot:
            --   1) if its house_id matches a real house, leave it alone.
            --   2) otherwise bind it to whichever house's zone the plot's
            --      world coords fall inside.
            --   3) if no zone matches, delete the row — no orphans.
            CreateThread(function()
                local deadline = GetGameTimer() + 8000
                while not (Housing and Housing.GetAllHouses)
                      and GetGameTimer() < deadline do
                    Wait(50)
                end
                if not (Housing and Housing.GetAllHouses) then return end
                local houses = Housing.GetAllHouses() or {}
                local rebound, deleted = 0, 0
                for plotId, plot in pairs(Plots) do
                    local hid = plot.house_id
                    local owner = hid and houses[hid] or nil
                    if not owner then
                        local placed = false
                        for _, h in pairs(houses) do
                            local interior = Housing.GetInterior(h.interior_id)
                            if interior and interior.zones then
                                for _, zone in ipairs(interior.zones) do
                                    local zTol = zone.zTolerance
                                        or (Config.Housing and Config.Housing.defaultZTolerance)
                                        or 1.0
                                    if math.abs((plot.coords_z or 0) - (zone.origin and zone.origin.z or 0)) <= zTol then
                                        local cx, cy = Housing.WorldToCell(zone, plot.coords_x or 0, plot.coords_y or 0)
                                        if cx and cy then
                                            local fw = math.max(1, tonumber(plot.cell_w) or 1)
                                            local fh = math.max(1, tonumber(plot.cell_h) or 1)
                                            Grow.BindPlotToHouse(plotId, h.id, zone.id, cx, cy, fw, fh)
                                            rebound = rebound + 1
                                            placed = true
                                            break
                                        end
                                    end
                                end
                            end
                            if placed then break end
                        end
                        if not placed then
                            Plots[plotId] = nil
                            MySQL.update.await("DELETE FROM pickle_drugs_entities WHERE id=?", { plotId })
                            TriggerClientEvent("pickle_drugs:plotRemoved", -1, plotId)
                            deleted = deleted + 1
                        end
                    end
                end
                if rebound > 0 or deleted > 0 then
                    print(("[pickle_drugs] grow: orphan scrub — rebound %d, deleted %d"):format(rebound, deleted))
                end
            end)
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
