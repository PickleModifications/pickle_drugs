local displayVehicles = {}
local ghostVehicles = {}
local currentDealership = nil
local isInZone = false
local seizeDealerships = {}  -- cached list of seize-enabled dealerships this player can manage

local GHOST_MODEL = `xm_prop_lab_barrier02` -- prop for empty display spots

--- Refresh the cached list of seize-enabled dealerships this player can manage
local function RefreshSeizeDealerships()
    seizeDealerships = lib.callback.await('pickle_dealerships:getSeizeDealerships', false) or {}
end

--- Parse a display spot into x, y, z, w regardless of format (vector4, table)
local function ParseSpot(spot)
    if type(spot) == "vector4" then
        return spot.x, spot.y, spot.z, spot.w
    elseif type(spot) == "table" then
        return spot.x or spot[1], spot.y or spot[2], spot.z or spot[3], spot.w or spot[4] or 0.0
    end
    return nil, nil, nil, nil
end

--- Cleanup ghost vehicles
function DeleteGhostVehicles()
    for _, data in ipairs(ghostVehicles) do
        if data.entity and DoesEntityExist(data.entity) then
            DeleteEntity(data.entity)
        end
        if data.zoneIdx and RemoveTargetZone then
            RemoveTargetZone(data.zoneIdx)
        end
    end
    ghostVehicles = {}
end

--- Removes the ghost+zone for a specific spot if present (surgical).
local function DeleteGhostAt(spotId)
    local kept = {}
    for _, data in ipairs(ghostVehicles) do
        if data.spotId == spotId then
            if data.entity and DoesEntityExist(data.entity) then DeleteEntity(data.entity) end
            if data.zoneIdx and RemoveTargetZone then RemoveTargetZone(data.zoneIdx) end
        else
            kept[#kept + 1] = data
        end
    end
    ghostVehicles = kept
end

--- Removes the display vehicle + its target options for a specific spot (surgical).
local function DeleteDisplayVehicleAt(spotId)
    local kept = {}
    for _, dv in ipairs(displayVehicles) do
        if dv.displaySpot == spotId then
            if dv.targetOptions and RemoveTargetPed and dv.entity and DoesEntityExist(dv.entity) then
                RemoveTargetPed(dv.entity, dv.targetOptions)
            end
            if dv.entity and DoesEntityExist(dv.entity) then DeleteEntity(dv.entity) end
        else
            kept[#kept + 1] = dv
        end
    end
    displayVehicles = kept
end

--- Spawn transparent placeholder vehicles on empty display spots (staff only)
local function SpawnGhostVehicles(locationKey, occupiedSpots)
    DeleteGhostVehicles()

    local cfg = DealershipConfigs[locationKey]
    if not cfg or not cfg.displaySpots then return end

    -- Check if player has a role at this dealership
    local role = lib.callback.await('pickle_dealerships:getPlayerRole', false, locationKey)
    if not role then return end -- not staff, no ghosts

    local canManage = role == 'owner' or role == 'manager' or role == 'admin'

    for _, spot in ipairs(cfg.displaySpots) do
        local spotId = spot.id and tonumber(spot.id)
        if spotId and not occupiedSpots[spotId] then
            local x, y, z, w = ParseSpot(spot)
            if x and y and z then
                local obj = CreateProp(GHOST_MODEL, x, y, z - 1.26, false, false, false)
                if obj and DoesEntityExist(obj) then
                    SetEntityRotation(obj, 90.0, 0.0, w or 0.0, 2, true)
                    FreezeEntityPosition(obj, true)
                    SetEntityCollision(obj, false, false)
                    SetEntityAlpha(obj, 200, false)
                    SetEntityInvincible(obj, true)

                    -- Walk-up picker: empty spots use a coordinate-based sphere zone
                    -- instead of an entity target because the ghost prop has no
                    -- collision (so ox_target's raycast would pass through it).
                    local zoneIdx
                    if canManage and AddTargetZone then
                        local capturedSpotId = spotId
                        local capturedCoords = { x = x, y = y, z = z, w = w or 0.0 }
                        zoneIdx = AddTargetZone(
                            vector3(x, y, z),
                            1.5,
                            {
                                {
                                    name = 'pickle_dealerships:pickSpot_' .. spotId,
                                    label = _L('spot_place_vehicle') or 'Place Vehicle',
                                    icon = 'fas fa-car',
                                    distance = 3.0,
                                    onSelect = function()
                                        TriggerEvent('pickle_dealerships:openSpotPicker', locationKey, capturedSpotId, capturedCoords)
                                    end,
                                },
                            }
                        )
                    end

                    ghostVehicles[#ghostVehicles + 1] = {
                        entity = obj,
                        spotId = spotId,
                        zoneIdx = zoneIdx,
                    }
                end
            end
        end
    end

    SetModelAsNoLongerNeeded(GHOST_MODEL)
end

--- Spawns display vehicles for the current dealership
---@param locationKey string
--- Spawns ONE display vehicle at a given spot. Pushes into displayVehicles and
--- attaches targets. Used both by the full rebuild and the targeted refresh.
local function SpawnDisplayVehicleAt(item, spotId, x, y, z, w, locationKey, staffCanManage)
    local model = item.vehicle_model or item.model
    local modelHash = type(model) == "string" and joaat(model) or model
    local veh = CreateVeh(modelHash, vector3(x, y, z), w or 0.0, false)
    if not veh or not DoesEntityExist(veh) then return nil end

    FreezeEntityPosition(veh, true)
    SetVehicleDoorsLocked(veh, 2)
    SetEntityInvincible(veh, true)

    local isUsed = item.is_used == true or tonumber(item.is_used) == 1
    local props = item.metadata
    if isUsed and props then
        if type(props) == 'string' then props = json.decode(props) or {} end
        if type(props) == 'table' then
            props.plate = nil
            lib.setVehicleProperties(veh, props)
        end
    end

    SetVehicleNumberPlateText(veh, 'DISPLAY')

    local targetOptions
    if Config.UseTarget then
        local capturedStockId = item.id
        local capturedSpotId = spotId
        local capturedCoords = { x = x, y = y, z = z, w = w or 0.0 }
        local capturedLocation = locationKey
        targetOptions = {}

        -- Primary interaction: open a single-vehicle spot view centered at this
        -- spot's coords (not the showcase anchor). Customers see only this one
        -- car with the normal purchase / finance actions; no sidebar browsing.
        targetOptions[#targetOptions + 1] = {
            name = 'pickle_dealerships:inspect_' .. item.id,
            label = _L('interact_view_vehicle') or 'View Vehicle',
            icon = 'fa-solid fa-magnifying-glass',
            distance = 3.0,
            onSelect = function()
                TriggerEvent('pickle_dealerships:openSpotView', capturedLocation, capturedSpotId, capturedCoords, capturedStockId)
            end,
        }

        if isUsed then
            targetOptions[#targetOptions + 1] = {
                name = 'pickle_dealerships:pickleFax_' .. item.id,
                label = 'View PickleFAX',
                icon = 'fa-solid fa-file-invoice',
                distance = 3.0,
                onSelect = function() OpenNui('pickleFax', { stockId = capturedStockId }) end,
            }
        end

        if staffCanManage then
            targetOptions[#targetOptions + 1] = {
                name = 'pickle_dealerships:swapSpot_' .. spotId,
                label = _L('spot_swap_vehicle') or 'Swap Vehicle',
                icon = 'fas fa-arrows-rotate',
                distance = 3.0,
                onSelect = function()
                    TriggerEvent('pickle_dealerships:openSpotPicker', locationKey, capturedSpotId, capturedCoords)
                end,
            }
            targetOptions[#targetOptions + 1] = {
                name = 'pickle_dealerships:clearSpot_' .. spotId,
                label = _L('spot_remove_vehicle') or 'Remove From Display',
                icon = 'fas fa-trash',
                distance = 3.0,
                onSelect = function()
                    lib.callback.await('pickle_dealerships:setDisplaySpot', false, locationKey, capturedStockId, nil)
                end,
            }
        end

        if #targetOptions > 0 then AddTargetPed(veh, targetOptions) end
    end

    local dv = {
        entity = veh,
        stockId = item.id,
        model = model,
        retailPrice = item.retail_price,
        wholesalePrice = item.wholesale_cost,
        displaySpot = spotId,
        isUsed = isUsed,
        targetOptions = targetOptions, -- kept so surgical removal can clean target entries
    }
    displayVehicles[#displayVehicles + 1] = dv
    return dv
end

--- Spawns ONE ghost + zone at an empty spot (staff only).
local function SpawnGhostAt(locationKey, spotId, x, y, z, w, canManage)
    local obj = CreateProp(GHOST_MODEL, x, y, z - 1.26, false, false, false)
    if not obj or not DoesEntityExist(obj) then return nil end

    SetEntityRotation(obj, 90.0, 0.0, w or 0.0, 2, true)
    FreezeEntityPosition(obj, true)
    SetEntityCollision(obj, false, false)
    SetEntityAlpha(obj, 200, false)
    SetEntityInvincible(obj, true)

    local zoneIdx
    if canManage and AddTargetZone then
        local capturedSpotId = spotId
        local capturedCoords = { x = x, y = y, z = z, w = w or 0.0 }
        zoneIdx = AddTargetZone(
            vector3(x, y, z),
            1.25,
            {
                {
                    name = 'pickle_dealerships:pickSpot_' .. spotId,
                    label = _L('spot_place_vehicle') or 'Place Vehicle',
                    icon = 'fas fa-car',
                    distance = 3.0,
                    onSelect = function()
                        TriggerEvent('pickle_dealerships:openSpotPicker', locationKey, capturedSpotId, capturedCoords)
                    end,
                },
            }
        )
    end

    local g = { entity = obj, spotId = spotId, zoneIdx = zoneIdx }
    ghostVehicles[#ghostVehicles + 1] = g
    return g
end

local function SpawnDisplayVehicles(locationKey)
    DeleteDisplayVehicles()
    DeleteGhostVehicles()

    local cfg = DealershipConfigs[locationKey]
    if not cfg or not cfg.displaySpots then return end

    local stock = lib.callback.await('pickle_dealerships:getStock', false, locationKey)
    if not stock then stock = {} end

    local occupiedSpots = {}
    local role = lib.callback.await('pickle_dealerships:getPlayerRole', false, locationKey)
    local staffCanManage = role == 'owner' or role == 'manager' or role == 'admin'

    for _, item in ipairs(stock) do
        local isDelivered = item.delivered_at and item.delivered_at ~= "" and not item.sold_at
        local isUnlisted = item.unlisted == 1 or item.unlisted == true
        local isAtAuction = item.auction_id ~= nil and item.auction_id ~= json.null
        if item.display_spot and isDelivered and not isUnlisted and not isAtAuction then
            local spotId = tonumber(item.display_spot)
            local spot
            for _, s in ipairs(cfg.displaySpots) do
                if s.id and tonumber(s.id) == spotId then spot = s; break end
            end
            if spot then
                local x, y, z, w = ParseSpot(spot)
                if x and y and z then
                    if SpawnDisplayVehicleAt(item, spotId, x, y, z, w, locationKey, staffCanManage) then
                        occupiedSpots[spotId] = true
                    end
                end
            end
        end
    end

    SpawnGhostVehicles(locationKey, occupiedSpots)
end

--- Surgical single-spot refresh. Removes whatever is currently rendered at
--- `spotId` (vehicle or ghost+zone), then re-queries the server for the stock
--- currently assigned and re-spawns only what's needed. Prevents the full
--- teardown-and-rebuild that used to happen on every spot change.
local function RefreshSingleSpot(locationKey, spotId)
    if not spotId then return end
    local cfg = DealershipConfigs[locationKey]
    if not cfg or not cfg.displaySpots then return end

    local spot
    for _, s in ipairs(cfg.displaySpots) do
        if s.id and tonumber(s.id) == spotId then spot = s; break end
    end
    if not spot then
        -- Spot no longer exists; just clean up any renders tied to it.
        DeleteDisplayVehicleAt(spotId)
        DeleteGhostAt(spotId)
        return
    end

    local x, y, z, w = ParseSpot(spot)
    if not x then return end

    -- Clean whatever was here.
    DeleteDisplayVehicleAt(spotId)
    DeleteGhostAt(spotId)

    local item = lib.callback.await('pickle_dealerships:getStockAtSpot', false, locationKey, spotId)

    if item then
        local role = lib.callback.await('pickle_dealerships:getPlayerRole', false, locationKey)
        local staffCanManage = role == 'owner' or role == 'manager' or role == 'admin'
        SpawnDisplayVehicleAt(item, spotId, x, y, z, w, locationKey, staffCanManage)
    else
        local role = lib.callback.await('pickle_dealerships:getPlayerRole', false, locationKey)
        local canManage = role == 'owner' or role == 'manager' or role == 'admin'
        if canManage then
            SpawnGhostAt(locationKey, spotId, x, y, z, w, canManage)
        end
    end
end

--- Deletes all display vehicles
function DeleteDisplayVehicles()
    for _, data in ipairs(displayVehicles) do
        if data.entity and DoesEntityExist(data.entity) then
            DeleteEntity(data.entity)
        end
    end
    displayVehicles = {}
end

--- Opens NUI with vehicle detail information
---@param locationKey string
---@param stockItem table
function OpenVehicleDetails(locationKey, stockItem)
    SetNuiFocus(true, true)
    SendNUIMessage({
        type = 'open',
        page = 'vehicleDetails',
        data = {
            location = locationKey,
            stockId = stockItem.id,
            model = stockItem.vehicle_model or stockItem.model,
            retailPrice = stockItem.retail_price,
            wholesalePrice = stockItem.wholesale_cost,
            displaySpot = stockItem.display_spot,
        },
    })
end

--- Listen for zone enter/exit from main module
RegisterNetEvent('pickle_dealerships:enteredDealership', function(locationKey, data)
    currentDealership = locationKey
    isInZone = true
    SpawnDisplayVehicles(locationKey)
    RefreshSeizeDealerships()
end)

RegisterNetEvent('pickle_dealerships:exitedDealership', function(locationKey)
    if currentDealership == locationKey then
        isInZone = false
        currentDealership = nil
        DeleteDisplayVehicles()
        DeleteGhostVehicles()
    end
end)

--- Showroom picker opened: hide whatever vehicle is currently rendered at the
--- target spot so the preview camera isn't pointed at two cars overlapping.
--- DB is untouched — CleanupShowroom will fire a targeted refresh on close.
RegisterNetEvent('pickle_dealerships:spotPickerOpened', function(locationKey, spotId)
    if currentDealership ~= locationKey or not isInZone then return end
    DeleteDisplayVehicleAt(tonumber(spotId))
    DeleteGhostAt(tonumber(spotId))
end)

--- Listen for stock changes to refresh display.
--- If the server sends specific spot IDs, only those get re-rendered. Otherwise
--- fall back to a full rebuild (used for stock state that isn't spot-scoped —
--- delivery arrival, unlist toggle, etc).
RegisterNetEvent('pickle_dealerships:refreshDisplay', function(locationKey, spotIds)
    if currentDealership ~= locationKey or not isInZone then return end
    -- Skip the spot the player is actively previewing in the picker — the
    -- new vehicle would spawn under the showroom camera while the menu is
    -- still open. CleanupShowroom fires its own targeted refresh on close
    -- that reconciles the spot once the camera is gone.
    local pickerSpot = GetActivePickerSpotId and GetActivePickerSpotId() or nil

    if type(spotIds) == 'table' and #spotIds > 0 then
        for _, spotId in ipairs(spotIds) do
            local n = tonumber(spotId)
            if n and n ~= pickerSpot then
                RefreshSingleSpot(locationKey, n)
            end
        end
    elseif not pickerSpot then
        SpawnDisplayVehicles(locationKey)
    end
end)

--- Surgically refresh display spots: remove vehicles on deleted spots, rebuild ghosts
RegisterNetEvent('pickle_dealerships:refreshDisplaySpots', function(locationKey)
    if currentDealership ~= locationKey or not isInZone then return end

    local cfg = DealershipConfigs[locationKey]

    -- Build a set of valid spot IDs from current config
    local validSpotIds = {}
    if cfg and cfg.displaySpots then
        for _, spot in ipairs(cfg.displaySpots) do
            if spot.id then validSpotIds[tonumber(spot.id)] = true end
        end
    end

    -- Remove display vehicles whose spot ID no longer exists
    local kept = {}
    local occupiedSpots = {}
    for _, dv in ipairs(displayVehicles) do
        if dv.displaySpot and not validSpotIds[dv.displaySpot] then
            if dv.entity and DoesEntityExist(dv.entity) then
                DeleteEntity(dv.entity)
            end
        else
            kept[#kept + 1] = dv
            if dv.displaySpot then
                occupiedSpots[dv.displaySpot] = true
            end
        end
    end
    displayVehicles = kept

    -- Rebuild just the ghosts
    DeleteGhostVehicles()
    SpawnGhostVehicles(locationKey, occupiedSpots)
end)

-- ─── NUI Callbacks ──────────────────────────────────────────────────────────

local function ResolveLocation(data)
    if data.location then return data.location end
    local current = exports.pickle_dealerships:GetCurrentDealership()
    return current
end

RegisterNUICallback("getCatalog", function(data, cb)
    local location = ResolveLocation(data)
    if not location then
        cb({ items = {}, total = 0, page = 1, pageSize = 50 })
        return
    end
    local result = lib.callback.await('pickle_dealerships:getCatalog', false, {
        location = location,
        page = data.page or 1,
        pageSize = data.pageSize or 50,
        search = data.search or '',
        classFilter = data.classFilter or 'all',
        tierFilter = data.tierFilter or 'all',
    })
    cb(result or { items = {}, total = 0, page = 1, pageSize = 50 })
end)

RegisterNUICallback("orderVehicle", function(data, cb)
    local location = ResolveLocation(data)
    if not location then
        cb({ success = false, message = "Could not resolve dealership location." })
        return
    end

    local success, result = lib.callback.await(
        'pickle_dealerships:orderVehicle',
        false,
        location,
        data.model,
        data.wholesale,
        tonumber(data.quantity) or 1,
        data.deliveryMode
    )
    if success then
        ShowNotification(_L("stock_order_success"))
        cb({ success = true, stockId = result })
    else
        ShowNotification(result or _L("stock_order_failed"))
        cb({ success = false, message = result or _L("stock_order_failed") })
    end
end)

RegisterNUICallback("previewOrderCost", function(data, cb)
    local result = lib.callback.await('pickle_dealerships:previewOrderCost', false, data.model, tonumber(data.quantity) or 1)
    cb(result or {})
end)

RegisterNUICallback("getPickleFax", function(data, cb)
    local result = lib.callback.await('pickle_dealerships:getPickleFax', false, { stockId = tonumber(data.stockId) })
    cb(result)
end)

RegisterNUICallback("getStock", function(data, cb)
    local location = ResolveLocation(data)
    if not location then
        cb({})
        return
    end
    local result = lib.callback.await('pickle_dealerships:getStock', false, location)
    cb(result or {})
end)

RegisterNUICallback("getShowroomStock", function(data, cb)
    local location = ResolveLocation(data)
    if not location then
        cb({ items = {}, total = 0, page = 1, pageSize = 20 })
        return
    end
    local result = lib.callback.await('pickle_dealerships:getShowroomStock', false, {
        location = location,
        page = data.page or 1,
        pageSize = data.pageSize or 20,
        search = data.search or '',
        classFilter = data.classFilter or 'all',
        minPrice = data.minPrice,
        maxPrice = data.maxPrice,
        sortBy = data.sortBy,
    })
    cb(result or { items = {}, total = 0, page = 1, pageSize = 20 })
end)

RegisterNUICallback("setRetailPrice", function(data, cb)
    local location = ResolveLocation(data)
    if not location then
        cb({ success = false, message = "Could not resolve location." })
        return
    end

    local success, err = lib.callback.await('pickle_dealerships:setRetailPrice', false, location, data.stockId, data.retailPrice)
    if success then
        cb({ success = true })
    else
        ShowNotification(err or _L("stock_retail_price_failed"))
        cb({ success = false, message = err or "Failed." })
    end
end)

RegisterNUICallback("setStockMinGrade", function(data, cb)
    local location = ResolveLocation(data)
    if not location then
        cb({ success = false, message = "Could not resolve location." })
        return
    end

    local success, result = lib.callback.await('pickle_dealerships:setStockMinGrade', false, location, data.stockId, data.minGrade)
    if success then
        cb({ success = true, minGrade = result })
    else
        ShowNotification(result or _L("stock_min_grade_failed"))
        cb({ success = false, message = result or "Failed." })
    end
end)

RegisterNUICallback("toggleUnlisted", function(data, cb)
    local location = ResolveLocation(data)
    if not location then
        cb({ success = false, message = "Could not resolve location." })
        return
    end

    local success, unlisted = lib.callback.await('pickle_dealerships:toggleUnlisted', false, location, data.stockId)
    if success then
        cb({ success = true, unlisted = unlisted })
    else
        cb({ success = false, message = unlisted or "Failed." })
    end
end)

RegisterNUICallback("setDisplaySpot", function(data, cb)
    local location = ResolveLocation(data)
    if not location then
        cb({ success = false, message = "Could not resolve location." })
        return
    end

    local success, err = lib.callback.await('pickle_dealerships:setDisplaySpot', false, location, data.stockId, data.spot)
    if success then
        cb({ success = true })
    else
        ShowNotification(err or _L("stock_display_spot_failed"))
        cb({ success = false, message = err or "Failed." })
    end
end)

RegisterNUICallback("getDisplaySpots", function(data, cb)
    local location = ResolveLocation(data)
    if not location then
        cb({ spots = {} })
        return
    end
    local cfg = DealershipConfigs[location]
    local spots = {}
    if cfg and cfg.displaySpots then
        for i, spot in ipairs(cfg.displaySpots) do
            spots[#spots + 1] = {
                id = spot.id and tonumber(spot.id) or i,
                index = i,
            }
        end
    end
    cb({ spots = spots })
end)

-- ─── Pre-owned trade-in flow ────────────────────────────────────────────────

--- Vehicle owner confirms / declines a pending trade-in
lib.callback.register('pickle_dealerships:confirmTradeIn', function(data)
    if type(data) ~= 'table' then return false end
    local header = ('%s Trade-In Offer'):format(data.dealershipName or 'Dealership')
    local content = ('**%s** is offering **$%s** for your **%s** (plate %s).\n\nAccept the trade-in?'):format(
        data.dealershipName or 'A dealership',
        data.buyPrice or 0,
        data.label or 'vehicle',
        data.plate or '?'
    )
    local answer = lib.alertDialog({
        header = header,
        content = content,
        centered = true,
        cancel = true,
        labels = { confirm = 'Accept', cancel = 'Decline' },
    })
    return answer == 'confirm'
end)


--- Open the trade-in dialog for a targeted vehicle
local function StartTradeIn(vehicle)
    if not currentDealership then
        ShowNotification(_L('trade_in_not_in_dealership'))
        return
    end
    if not vehicle or not DoesEntityExist(vehicle) or GetEntityType(vehicle) ~= 2 then return end

    local rawPlate = GetVehicleNumberPlateText(vehicle)
    if not rawPlate then return end
    local plate = rawPlate:gsub('^%s*(.-)%s*$', '%1')
    if plate == '' then
        ShowNotification(_L('trade_in_no_plate'))
        return
    end

    local properties = lib.getVehicleProperties(vehicle)
    if not properties then
        ShowNotification(_L('trade_in_no_props'))
        return
    end

    -- Ask the server to resolve the model (and any catalog suggestion) from the plate's framework record
    local suggestion = lib.callback.await('pickle_dealerships:getTradeInSuggestion', false, currentDealership, plate)
    if not suggestion or suggestion.ownerless then
        ShowNotification(_L('trade_in_not_registered'))
        return
    end
    local msrp = suggestion.wholesale
    local suggestedOffer = msrp and math.floor(msrp * 0.9) or 1000
    local label = suggestion.label or 'Vehicle'

    local input = lib.inputDialog('Trade-In: ' .. tostring(label), {
        { type = 'number', label = 'Offer Price', description = msrp and ('Suggested: $' .. suggestedOffer .. ' (MSRP: $' .. msrp .. ')') or 'No catalog reference for this model.', default = suggestedOffer, required = true, min = 1 },
        { type = 'number', label = 'Retail Price (lot)', description = 'Price the dealership will sell it for.', default = msrp or 1000, required = true, min = 1 },
    })
    if not input then return end

    local buyPrice = tonumber(input[1])
    local retailPrice = tonumber(input[2])
    if not buyPrice or not retailPrice then return end

    -- Hand the server a network id so it can delete the vehicle even if this
    -- client (the manager running the target) doesn't own the entity.
    -- Client-only DeleteEntity silently no-ops on non-owned networked vehicles,
    -- which is why traded-in cars kept lingering on the street.
    local netId = NetworkGetNetworkIdFromEntity(vehicle)

    local ok, err = lib.callback.await('pickle_dealerships:tradeInVehicle', false, currentDealership, {
        plate = plate,
        properties = properties,
        buyPrice = buyPrice,
        retailPrice = retailPrice,
        netId = netId,
    })
    if not ok then
        ShowNotification(err or _L('trade_in_failed'))
        return
    end

    -- Server handles the authoritative delete (see tradeInVehicle). Local
    -- follow-up is belt-and-suspenders for the case where this client has
    -- control and the server-side delete didn't reach us yet.
    if DoesEntityExist(vehicle) then
        SetEntityAsMissionEntity(vehicle, true, true)
        DeleteEntity(vehicle)
    end
end

--- Seize a vehicle (no consent, no payment, unlisted stock)
local function StartSeize(vehicle)
    if not vehicle or not DoesEntityExist(vehicle) or GetEntityType(vehicle) ~= 2 then return end

    local rawPlate = GetVehicleNumberPlateText(vehicle)
    if not rawPlate then return end
    local plate = rawPlate:gsub('^%s*(.-)%s*$', '%1')
    if plate == '' then
        ShowNotification(_L('trade_in_no_plate'))
        return
    end

    local properties = lib.getVehicleProperties(vehicle)
    if not properties then
        ShowNotification(_L('trade_in_no_props'))
        return
    end

    -- Reject NPC / unregistered vehicles up front
    local isOwned = lib.callback.await('pickle_dealerships:isPlateOwned', false, plate)
    if not isOwned then
        ShowNotification(_L('seize_not_player_owned'))
        return
    end

    -- Resolve the model name + display label from the entity (hash → name → game label)
    local modelHash = GetEntityModel(vehicle)
    local modelName = tostring(GetDisplayNameFromVehicleModel(modelHash)):lower()
    local labelKey = GetDisplayNameFromVehicleModel(modelHash)
    local displayLabel = GetLabelText(labelKey)
    if not displayLabel or displayLabel == '' or displayLabel == 'NULL' then
        displayLabel = labelKey or modelName
    end

    -- Pick which dealership to seize into
    local targetDealership
    if #seizeDealerships == 1 then
        targetDealership = seizeDealerships[1]
    else
        local options = {}
        for _, d in ipairs(seizeDealerships) do
            options[#options + 1] = { label = d.name, value = d.id }
        end
        local choice = lib.inputDialog(_L('seize_select_dealership'), {
            { type = 'select', label = _L('label_dealership'), options = options, required = true },
        })
        if not choice then return end
        for _, d in ipairs(seizeDealerships) do
            if d.id == tonumber(choice[1]) then targetDealership = d break end
        end
    end
    if not targetDealership then return end

    -- Confirmation
    local confirm = lib.alertDialog({
        header = _L('seize_confirm_header'),
        content = _L('seize_confirm_body', plate, targetDealership.name),
        centered = true,
        cancel = true,
    })
    if confirm ~= 'confirm' then return end

    local netId = NetworkGetNetworkIdFromEntity(vehicle)

    local ok, err = lib.callback.await('pickle_dealerships:seizeVehicle', false, {
        dealershipId = targetDealership.id,
        plate = plate,
        properties = properties,
        modelName = modelName,
        label = displayLabel,
        netId = netId,
    })
    if not ok then
        ShowNotification(err or _L('seize_failed'))
        return
    end

    -- Server handles the authoritative delete. Local delete is belt-and-
    -- suspenders — silently no-ops if we don't own the networked entity.
    if DoesEntityExist(vehicle) then
        SetEntityAsMissionEntity(vehicle, true, true)
        DeleteEntity(vehicle)
    end
end

CreateThread(function()
    if not Config.UseTarget then return end
    Wait(2000) -- wait for target bridge

    -- Initial fetch of seize dealerships
    RefreshSeizeDealerships()

    -- Display vehicles (spot-placed units) should not expose trade-in / seize
    -- options — those are for player-driven cars, not the lot inventory itself.
    local function IsDisplayVehicle(entity)
        if not entity then return false end
        for _, d in ipairs(displayVehicles) do
            if d.entity == entity then return true end
        end
        return false
    end

    AddTargetGlobalVehicle({
        {
            name = 'pickle_dealerships:tradeIn',
            label = _L('interact_trade_in'),
            icon = 'fa-solid fa-handshake-simple',
            distance = 2.5,
            canInteract = function(entity)
                if not currentDealership then return false end
                if IsDisplayVehicle(entity) then return false end
                -- Hide trade-in if this dealership has seize enabled
                for _, d in ipairs(seizeDealerships) do
                    if d.location == currentDealership then return false end
                end
                local role = lib.callback.await('pickle_dealerships:getPlayerRole', false, currentDealership)
                return role == 'owner' or role == 'manager' or role == 'admin'
            end,
            onSelect = function(data)
                StartTradeIn(data.entity)
            end,
        },
        {
            name = 'pickle_dealerships:seizeVehicle',
            label = _L('interact_seize_vehicle'),
            icon = 'fa-solid fa-shield-halved',
            distance = 2.5,
            canInteract = function(entity)
                if IsDisplayVehicle(entity) then return false end
                return #seizeDealerships > 0
            end,
            onSelect = function(data)
                StartSeize(data.entity)
            end,
        },
    })
end)

--- Refresh seize cache when server notifies us (admin toggled seize mode)
RegisterNetEvent('pickle_dealerships:refreshSeizeCache', function()
    RefreshSeizeDealerships()
end)

--- Cleanup on resource stop
AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    DeleteDisplayVehicles()
    DeleteGhostVehicles()
end)
