if GetResourceState("es_extended") ~= "started" then return end

Admin = Admin or {}
Framework = Framework or {}

local ESX = exports["es_extended"] and exports["es_extended"]:getSharedObject() or nil
local AdminGroups = { admin = true, superadmin = true, mod = true }

if not Admin.IsAdmin then
    function Admin.IsAdmin(source)
        if not source or source == 0 then return true end
        if ESX then
            local xPlayer = ESX.GetPlayerFromId(source)
            if xPlayer and AdminGroups[xPlayer.getGroup()] then return true end
        end
        return IsPlayerAceAllowed(source, "command")
    end
end

if not Framework.RegisterUsableItem then
    function Framework.RegisterUsableItem(name, fn)
        if not ESX or not name or not fn then return end
        ESX.RegisterUsableItem(name, function(source)
            local ok, err = pcall(fn, source)
            if not ok then
                print(("[pickle_drugs] usable %s callback errored: %s"):format(name, tostring(err)))
            end
        end)
    end
end

if not Framework.GetCitizenId then
    function Framework.GetCitizenId(source)
        if not ESX or not source then return nil end
        local xPlayer = ESX.GetPlayerFromId(source)
        return xPlayer and xPlayer.identifier or nil
    end
end

if not Framework.AddMoney then
    function Framework.AddMoney(source, amount, account)
        if not ESX or not source or not amount or amount <= 0 then return false end
        local xPlayer = ESX.GetPlayerFromId(source)
        if not xPlayer then return false end
        xPlayer.addMoney(amount, account or "money")
        return true
    end
end
