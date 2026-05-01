-- Default vehicle-keys bridge. Dispatches the events listed in
-- Config.VehicleKeys so whichever key system is actually running (qb, qbx,
-- cd_garage, Renewed-Vehiclekeys, etc.) picks up ownership.
--
-- To integrate a custom key system, either add entries to Config.VehicleKeys.events,
-- set Config.VehicleKeys.customHandler, or drop in a replacement bridge file
-- under bridge/vehicle_keys/<name>/client.lua that redefines GiveVehicleKeys.

function GiveVehicleKeys(veh)
    local cfg = Config.VehicleKeys
    if not cfg or cfg.enabled == false then return end
    if not veh or not DoesEntityExist(veh) then return end

    local plate = GetVehicleNumberPlateText(veh)
    if not plate then return end
    plate = plate:gsub("%s+", "")
    if plate == "" then return end

    if type(cfg.customHandler) == 'function' then
        cfg.customHandler(veh, plate)
        return
    end

    for _, entry in ipairs(cfg.events or {}) do
        if entry and entry.name then
            if entry.scope == 'server' then
                TriggerServerEvent(entry.name, plate)
            else
                TriggerEvent(entry.name, plate)
            end
        end
    end
end
