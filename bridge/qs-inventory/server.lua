if GetResourceState("qs-inventory") ~= "started" then return end
if GetResourceState("ox_inventory") == "started" then return end

Inventory = Inventory or {}

Inventory.AddItem = function(source, name, count, metadata)
    return exports["qs-inventory"]:AddItem(source, name, count, nil, metadata)
end

Inventory.RemoveItem = function(source, name, count)
    return exports["qs-inventory"]:RemoveItem(source, name, count)
end

Inventory.GetItemCount = function(source, name)
    return exports["qs-inventory"]:GetItemTotalAmount(source, name) or 0
end
