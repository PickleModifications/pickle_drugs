-- In-game bud-offset editor. Aim at the plant, left-click to drop a bud
-- where the camera ray hits its surface; numpad nudges the most-recently
-- placed bud for fine-tuning. /budsave exports the list back into
-- config.lua. Intended for dev only — gated on Config.Debug.

local Editor = nil
-- Editor = {
--   plotId, drug, plant, budModel,
--   ghost   = entity,             -- preview bud at the current ray hit
--   saved   = { vector3, ... },   -- local offsets relative to plant
--   savedEntities = { entity, ... },
--   step    = 0.005,
--   hasHit  = bool,               -- whether the camera ray hit the plant this frame
-- }

local function spawnBud(model, plant, off)
    local hash = LoadModel(model)
    if not hash then return nil end
    local pc = GetEntityCoords(plant)
    local obj = CreateObject(hash, pc.x, pc.y, pc.z, false, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not obj or not DoesEntityExist(obj) then return nil end
    SetEntityCollision(obj, false, false)
    AttachEntityToEntity(obj, plant, 0,
        off.x, off.y, off.z,
        0.0, 0.0, 0.0,
        false, false, false, false, 2, true)
    return obj
end

local function reattach(ent, plant, off)
    AttachEntityToEntity(ent, plant, 0,
        off.x, off.y, off.z,
        0.0, 0.0, 0.0,
        false, false, false, false, 2, true)
end

local function findClosestHarvestPlot()
    local pcoords = GetEntityCoords(PlayerPedId())
    local bestId, bestDist
    for _, id in ipairs(GetAllPlotIds() or {}) do
        local plot = GetPlotState(id)
        local spot = GetPlotSpot(id)
        local drugCfg = plot and Config.Drugs[plot.drug]
        if plot and spot and drugCfg and plot.stage == Grow.HarvestStage(drugCfg) then
            local d = #(pcoords - vector3(spot.coords.x, spot.coords.y, spot.coords.z))
            if not bestDist or d < bestDist then
                bestId, bestDist = id, d
            end
        end
    end
    return bestId
end

local function cleanup()
    if not Editor then return end
    if Editor.ghost and DoesEntityExist(Editor.ghost) then DeleteEntity(Editor.ghost) end
    for _, e in ipairs(Editor.savedEntities) do
        if e and DoesEntityExist(e) then DeleteEntity(e) end
    end
    Editor = nil
    if lib and lib.hideTextUI then lib.hideTextUI() end
end

local function refreshHelp()
    if not Editor or not lib or not lib.showTextUI then return end
    local lines = {
        ("**Bud offset editor** (drug: %s, plot: %s)"):format(Editor.drug, Editor.plotId),
        ("saved: `%d`  step: `%.4f`  %s")
            :format(#Editor.saved, Editor.step,
                Editor.hasHit and "aim: ✓ on plant" or "aim: — point at plant"),
        "**Left-click**: place bud  •  Numpad 4/6/8/2/9/3: nudge last  •  +/-: step",
        "/budundo  /budsave  /budcancel",
    }
    lib.showTextUI(table.concat(lines, "  \n"))
end

--- Forward unit vector from camera rotation (degrees, ZYX order).
local function camForward()
    local rot = GetGameplayCamRot(2)
    local rx, rz = math.rad(rot.x), math.rad(rot.z)
    local cosX = math.cos(rx)
    return vector3(-math.sin(rz) * cosX, math.cos(rz) * cosX, math.sin(rx))
end

--- Casts a ray from the camera and returns hitCoords if it hit the
--- editor's plant entity within `range`. Walks past intermediate hits whose
--- model is in `Editor.skipModels` (e.g. the scissors prop attached to the
--- player's hand) by re-casting from just past the unwanted hit.
local function aimAtPlant(range)
    if not Editor or not Editor.plant or not DoesEntityExist(Editor.plant) then return nil end
    local origin  = GetGameplayCamCoord()
    local forward = camForward()
    local endPt   = origin + forward * range
    local from    = origin

    for _ = 1, 4 do
        -- Flags: 1 (world) | 8 (objects) | 16 (vehicles). Ignore the player
        -- ped; scissors etc. are filtered below since they're separate entities.
        local handle = StartShapeTestRay(
            from.x, from.y, from.z,
            endPt.x, endPt.y, endPt.z,
            1 | 8 | 16, PlayerPedId(), 4)
        local _, hit, endCoords, _, entity = GetShapeTestResult(handle)
        if hit ~= 1 then return nil end
        if entity == Editor.plant then return endCoords end
        if entity ~= 0 and Editor.skipModels[GetEntityModel(entity)] then
            -- Step the origin a hair past the unwanted hit and try again.
            from = endCoords + forward * 0.02
        else
            -- Hit world geometry or some other unrelated entity — stop.
            return nil
        end
    end
    return nil
end

local function placeAt(worldHit)
    if not Editor then return end
    -- Convert world → plant-local. Engine helper accounts for plant rotation.
    local off = GetOffsetFromEntityGivenWorldCoords(Editor.plant, worldHit.x, worldHit.y, worldHit.z)
    Editor.saved[#Editor.saved + 1] = off
    local ent = spawnBud(Editor.budModel, Editor.plant, off)
    Editor.savedEntities[#Editor.savedEntities + 1] = ent
end

local function nudgeLast(dx, dy, dz)
    if not Editor then return end
    local n = #Editor.saved
    if n == 0 then return end
    local v = Editor.saved[n]
    local off = vector3(v.x + dx, v.y + dy, v.z + dz)
    Editor.saved[n] = off
    local ent = Editor.savedEntities[n]
    if ent and DoesEntityExist(ent) then reattach(ent, Editor.plant, off) end
end

-- Main editor thread: ray-cast each frame, drive the ghost preview, and
-- handle click-to-place + numpad nudge.
local function startThread()
    CreateThread(function()
        local lastRefresh = 0
        while Editor do
            local hit = aimAtPlant(6.0)
            local hadHit = Editor.hasHit
            Editor.hasHit = hit ~= nil

            if hit then
                local off = GetOffsetFromEntityGivenWorldCoords(Editor.plant, hit.x, hit.y, hit.z)
                if Editor.ghost and DoesEntityExist(Editor.ghost) then
                    reattach(Editor.ghost, Editor.plant, off)
                    SetEntityVisible(Editor.ghost, true, false)
                end
            else
                if Editor.ghost and DoesEntityExist(Editor.ghost) then
                    SetEntityVisible(Editor.ghost, false, false)
                end
            end

            -- Suppress firing while the editor is up so left-click is repurposed.
            DisableControlAction(0, 24, true)  -- INPUT_ATTACK
            DisableControlAction(0, 25, true)  -- INPUT_AIM
            DisableControlAction(0, 257, true) -- INPUT_ATTACK2
            if hit and IsDisabledControlJustPressed(0, 24) then
                placeAt(hit)
                refreshHelp()
            end

            -- Numpad nudge of the most-recent bud.
            local dx, dy, dz = 0, 0, 0
            if IsControlPressed(0, 108) then dx = -1 end
            if IsControlPressed(0, 109) then dx = 1 end
            if IsControlPressed(0, 111) then dy = 1 end
            if IsControlPressed(0, 110) then dy = -1 end
            if IsControlPressed(0, 117) then dz = 1 end
            if IsControlPressed(0, 118) then dz = -1 end
            if dx ~= 0 or dy ~= 0 or dz ~= 0 then
                nudgeLast(dx * Editor.step, dy * Editor.step, dz * Editor.step)
            end
            if IsControlJustPressed(0, 84) then
                Editor.step = math.min(Editor.step * 2, 1.0)
                refreshHelp()
            elseif IsControlJustPressed(0, 83) then
                Editor.step = math.max(Editor.step / 2, 0.0001)
                refreshHelp()
            end

            local t = GetGameTimer()
            if hadHit ~= Editor.hasHit or t - lastRefresh > 500 then
                refreshHelp()
                lastRefresh = t
            end
            Wait(0)
        end
    end)
end

RegisterCommand("budoffset", function()
    if not Config.Debug then
        print("[pickle_drugs] enable Config.Debug to use the bud offset editor")
        return
    end
    if Editor then cleanup() return end

    local plotId = findClosestHarvestPlot()
    if not plotId then
        print("[pickle_drugs] no harvest-stage plot nearby — grow one to stage 3 first")
        return
    end
    local plot = GetPlotState(plotId)
    if not plot then
        print("[pickle_drugs] plot state missing for " .. plotId)
        return
    end
    local drugCfg = Config.Drugs[plot.drug]
    local plant   = GetPlotPlantEntity(plotId)
    if not plant or not DoesEntityExist(plant) then
        print("[pickle_drugs] plant entity not spawned for plot " .. plotId)
        return
    end
    local budsCfg = drugCfg.stages[Grow.HarvestStage(drugCfg)].buds
    if not budsCfg or not budsCfg.model then
        print("[pickle_drugs] drug has no buds.model configured")
        return
    end

    -- Models the camera ray should pass through instead of treating as the
    -- target. The scissors prop spawned by the cutting flow can be in the
    -- ped's hand and would otherwise block placement on the plant.
    local skipModels = {}
    local cut = Config.PlantScene and Config.PlantScene.cutting
    if cut and cut.tool then skipModels[joaat(cut.tool)] = true end
    if cut and cut.fallCarrier then skipModels[joaat(cut.fallCarrier)] = true end

    Editor = {
        plotId        = plotId,
        drug          = plot.drug,
        plant         = plant,
        budModel      = budsCfg.model,
        saved         = {},
        savedEntities = {},
        step          = 0.005,
        hasHit        = false,
        skipModels    = skipModels,
    }
    Editor.ghost = spawnBud(budsCfg.model, plant, vector3(0.0, 0.0, 0.0))
    if not Editor.ghost then
        print("[pickle_drugs] failed to spawn ghost bud")
        Editor = nil
        return
    end
    SetEntityAlpha(Editor.ghost, 140, false)
    SetEntityVisible(Editor.ghost, false, false)
    refreshHelp()
    startThread()
end, false)

RegisterCommand("budundo", function()
    if not Editor then return end
    local n = #Editor.saved
    if n == 0 then return end
    local ent = Editor.savedEntities[n]
    if ent and DoesEntityExist(ent) then DeleteEntity(ent) end
    Editor.saved[n] = nil
    Editor.savedEntities[n] = nil
    refreshHelp()
end, false)

RegisterCommand("budsave", function()
    if not Editor then return end
    local payload = {}
    for i, v in ipairs(Editor.saved) do
        payload[i] = { x = v.x, y = v.y, z = v.z }
    end
    TriggerServerEvent("pickle_drugs:saveBudOffsets", Editor.drug, payload)
end, false)

RegisterCommand("budcancel", function() cleanup() end, false)

RegisterCommand("budstep", function(_, args)
    if not Editor or not args[1] then return end
    local v = tonumber(args[1])
    if v and v > 0 then
        Editor.step = v
        refreshHelp()
    end
end, false)

AddEventHandler("onResourceStop", function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    cleanup()
end)
