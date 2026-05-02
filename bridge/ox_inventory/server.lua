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

--- Returns a flat array of the player's current inventory:
---   { { slot, name, label, count, metadata, weight }, ... }
--- Used by modules/storage to render the right-hand "your inventory"
--- grid in the storage panel. ox_inventory's GetInventoryItems is a
--- slot-keyed map; we flatten and stamp the slot back on each entry.
Inventory.ImagesPath = "nui://ox_inventory/web/images"

Inventory.GetPlayerItems = function(source)
    local raw = exports.ox_inventory:GetInventoryItems(source) or {}
    local items = exports.ox_inventory:Items() or {}
    local out = {}
    for slot, item in pairs(raw) do
        if item and item.name and (tonumber(item.count) or 0) > 0 then
            local def = items[item.name] or {}
            out[#out + 1] = {
                slot     = tonumber(slot) or 0,
                name     = item.name,
                label    = item.label or def.label or item.name,
                count    = tonumber(item.count) or 0,
                metadata = item.metadata,
                weight   = tonumber(item.weight) or tonumber(def.weight) or 0,
            }
        end
    end
    table.sort(out, function(a, b) return a.slot < b.slot end)
    return out
end
