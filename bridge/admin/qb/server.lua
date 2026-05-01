if GetResourceState("qb-core") ~= "started" or GetResourceState("qbx_core") == "started" then return end
if Admin and Admin.IsAdmin then return end

Admin = Admin or {}

local QBCore = exports["qb-core"] and exports["qb-core"]:GetCoreObject() or nil
local AdminGroups = { "admin", "god" }

function Admin.IsAdmin(source)
    if not source or source == 0 then return true end
    if not QBCore then return IsPlayerAceAllowed(source, "command") end
    for i = 1, #AdminGroups do
        if QBCore.Functions.HasPermission(source, AdminGroups[i]) then return true end
    end
    return IsPlayerAceAllowed(source, "command")
end
