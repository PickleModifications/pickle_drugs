if GetResourceState("es_extended") ~= "started" then return end
if Admin and Admin.IsAdmin then return end

Admin = Admin or {}

local ESX = exports["es_extended"] and exports["es_extended"]:getSharedObject() or nil
local AdminGroups = { admin = true, superadmin = true, mod = true }

function Admin.IsAdmin(source)
    if not source or source == 0 then return true end
    if ESX then
        local xPlayer = ESX.GetPlayerFromId(source)
        if xPlayer and AdminGroups[xPlayer.getGroup()] then return true end
    end
    return IsPlayerAceAllowed(source, "command")
end
