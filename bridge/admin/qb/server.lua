if GetResourceState("qb-core") ~= "started" or GetResourceState("qbx_core") == "started" then return end

Admin = Admin or {}
Framework = Framework or {}

local QBCore = exports["qb-core"] and exports["qb-core"]:GetCoreObject() or nil
local AdminGroups = { "admin", "god" }

if not Admin.IsAdmin then
    function Admin.IsAdmin(source)
        if not source or source == 0 then return true end
        if not QBCore then return IsPlayerAceAllowed(source, "command") end
        for i = 1, #AdminGroups do
            if QBCore.Functions.HasPermission(source, AdminGroups[i]) then return true end
        end
        return IsPlayerAceAllowed(source, "command")
    end
end

if not Framework.RegisterUsableItem then
    function Framework.RegisterUsableItem(name, fn)
        if not QBCore or not name or not fn then return end
        QBCore.Functions.CreateUseableItem(name, function(source)
            local ok, err = pcall(fn, source)
            if not ok then
                print(("[pickle_drugs] usable %s callback errored: %s"):format(name, tostring(err)))
            end
        end)
    end
end

if not Framework.GetCitizenId then
    function Framework.GetCitizenId(source)
        if not QBCore or not source then return nil end
        local player = QBCore.Functions.GetPlayer(tonumber(source))
        return player and player.PlayerData and player.PlayerData.citizenid or nil
    end
end

if not Framework.AddMoney then
    function Framework.AddMoney(source, amount, account)
        if not QBCore or not source or not amount or amount <= 0 then return false end
        local player = QBCore.Functions.GetPlayer(tonumber(source))
        if not player or not player.Functions or not player.Functions.AddMoney then return false end
        player.Functions.AddMoney(account or "cash", amount, "pickle_drugs:dealing")
        return true
    end
end
