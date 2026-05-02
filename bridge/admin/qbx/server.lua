if GetResourceState("qbx_core") ~= "started" then return end

Admin = Admin or {}
Framework = Framework or {}

if not Admin.IsAdmin then
    function Admin.IsAdmin(source)
        if not source or source == 0 then return true end
        -- qbx exposes lib.checkPlayerPermission via ox_lib's CheckPlayerPermission;
        -- the simplest and most-portable check is the qb-style HasPermission proxy
        -- under exports.qbx_core, plus the ace fallback.
        local ok, result = pcall(function()
            return exports.qbx_core:HasPermission(source, "admin")
                or exports.qbx_core:HasPermission(source, "god")
        end)
        if ok and result then return true end
        return IsPlayerAceAllowed(source, "command")
    end
end

if not Framework.GetCitizenId then
    function Framework.GetCitizenId(source)
        if not source then return nil end
        local cid
        local ok = pcall(function()
            local data = exports.qbx_core:GetPlayer(source)
            cid = data and data.PlayerData and data.PlayerData.citizenid or nil
        end)
        if ok and cid then return cid end
        local QBCore = exports["qb-core"] and exports["qb-core"]:GetCoreObject() or nil
        if QBCore and QBCore.Functions and QBCore.Functions.GetPlayer then
            local player = QBCore.Functions.GetPlayer(tonumber(source))
            return player and player.PlayerData and player.PlayerData.citizenid or nil
        end
        return nil
    end
end

if not Framework.AddMoney then
    function Framework.AddMoney(source, amount, account)
        if not source or not amount or amount <= 0 then return false end
        -- qbx_core ships its own AddMoney export; fall back to qb-core
        -- (which qbx is compatible with) if the export isn't there.
        local ok = pcall(function()
            exports.qbx_core:AddMoney(source, account or "cash", amount, "pickle_drugs:dealing")
        end)
        if ok then return true end
        local QBCore = exports["qb-core"] and exports["qb-core"]:GetCoreObject() or nil
        if QBCore and QBCore.Functions and QBCore.Functions.GetPlayer then
            local player = QBCore.Functions.GetPlayer(tonumber(source))
            if player and player.Functions and player.Functions.AddMoney then
                player.Functions.AddMoney(account or "cash", amount, "pickle_drugs:dealing")
                return true
            end
        end
        return false
    end
end

if not Framework.RegisterUsableItem then
    -- qbx ships its own CreateUseableItem export; fall back to qb-core's
    -- core object if qbx is running in compatibility mode alongside qb.
    function Framework.RegisterUsableItem(name, fn)
        if not name or not fn then return end
        local ok = pcall(function()
            exports.qbx_core:CreateUseableItem(name, function(source)
                local cbOk, err = pcall(fn, source)
                if not cbOk then
                    print(("[pickle_drugs] usable %s callback errored: %s"):format(name, tostring(err)))
                end
            end)
        end)
        if ok then return end
        local QBCore = exports["qb-core"] and exports["qb-core"]:GetCoreObject() or nil
        if QBCore and QBCore.Functions and QBCore.Functions.CreateUseableItem then
            QBCore.Functions.CreateUseableItem(name, function(source)
                local cbOk, err = pcall(fn, source)
                if not cbOk then
                    print(("[pickle_drugs] usable %s callback errored: %s"):format(name, tostring(err)))
                end
            end)
        end
    end
end
