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

Inventory.ImagesPath = "nui://qb-inventory/html/images"

Inventory.GetPlayerItems = function(source)
    if not QBCore then return {} end
    local player = QBCore.Functions.GetPlayer(tonumber(source))
    if not player or not player.PlayerData or not player.PlayerData.items then return {} end
    local out = {}
    for slot, item in pairs(player.PlayerData.items) do
        if item and item.name and (tonumber(item.amount) or 0) > 0 then
            out[#out + 1] = {
                slot     = tonumber(item.slot) or tonumber(slot) or 0,
                name     = item.name,
                label    = item.label or item.name,
                count    = tonumber(item.amount) or 0,
                metadata = item.info,
                weight   = tonumber(item.weight) or 0,
            }
        end
    end
    table.sort(out, function(a, b) return a.slot < b.slot end)
    return out
end
