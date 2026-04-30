if GetResourceState("qb-inventory") ~= "started" then return end
if GetResourceState("ox_inventory") == "started" then return end

local QBCore = exports["qb-core"] and exports["qb-core"]:GetCoreObject() or nil

Inventory = Inventory or {}

Inventory.AddItem = function(source, name, count, metadata)
    if not QBCore then return false end
    local player = QBCore.Functions.GetPlayer(tonumber(source))
    if not player then return false end
    return player.Functions.AddItem(name, count, nil, metadata)
end

Inventory.RemoveItem = function(source, name, count)
    if not QBCore then return false end
    local player = QBCore.Functions.GetPlayer(tonumber(source))
    if not player then return false end
    return player.Functions.RemoveItem(name, count)
end

Inventory.GetItemCount = function(source, name)
    if not QBCore then return 0 end
    local player = QBCore.Functions.GetPlayer(tonumber(source))
    if not player then return 0 end
    local item = player.Functions.GetItemByName(name)
    return item and item.amount or 0
end
