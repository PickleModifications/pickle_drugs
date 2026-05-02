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

Inventory.ImagesPath = "nui://qs-inventory/html/images"

Inventory.GetPlayerItems = function(source)
    local raw = exports["qs-inventory"]:GetInventory(source) or {}
    local out = {}
    for _, item in pairs(raw) do
        if item and item.name and (tonumber(item.amount) or 0) > 0 then
            out[#out + 1] = {
                slot     = tonumber(item.slot) or 0,
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
