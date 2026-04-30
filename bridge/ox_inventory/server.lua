if GetResourceState("ox_inventory") ~= "started" then return end

Inventory = Inventory or {}

Inventory.AddItem = function(source, name, count, metadata)
    return exports.ox_inventory:AddItem(source, name, count, metadata)
end

Inventory.RemoveItem = function(source, name, count, metadata)
    return exports.ox_inventory:RemoveItem(source, name, count, metadata)
end

Inventory.GetItemCount = function(source, name)
    return exports.ox_inventory:GetItemCount(source, name) or 0
end
