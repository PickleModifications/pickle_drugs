if GetResourceState('qbx_core') ~= 'started' then return end

function ShowNotification(text)
    lib.notify({ description = text })
end

function CanAccessGroup(data)
    if not data then return true end
    local pdata = exports.qbx_core:GetPlayerData()
    for k, v in pairs(data) do
        if (pdata.job.name == k and pdata.job.grade.level >= v) then return true end
    end
    return false
end

function GetPlayersInArea(coords, radius)
    coords = coords or GetEntityCoords(PlayerPedId())
    radius = radius or 3.0
    local list = lib.getNearbyPlayers(coords, radius)
    local players = {}
    for _, p in pairs(list) do
        if p.id ~= PlayerId() then
            players[#players + 1] = p.id
        end
    end
    return players
end

RegisterNetEvent(GetCurrentResourceName()..":showNotification", function(text)
    ShowNotification(text)
end)

RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
    TriggerServerEvent("pickle_dealerships:initializePlayer")
end)

-- qbx_core also emits this event on character load
RegisterNetEvent('qbx_core:client:playerLoaded', function()
    TriggerServerEvent("pickle_dealerships:initializePlayer")
end)

-- Inventory Fallback (ox_inventory is standard in qbx, but keep fallback for minimal setups)
CreateThread(function()
    Wait(100)

    if InitializeInventory then return InitializeInventory() end

    Inventory = {}
    Inventory.Items = {}
    Inventory.Ready = false

    RegisterNetEvent("pickle_dealerships:setupInventory", function(data)
        Inventory.Items = data.items
        Inventory.Ready = true
    end)

    RegisterNetEvent("pickle_dealerships:updateInventory", function(inventory)
        -- RefreshInventory(inventory)
    end)
end)
