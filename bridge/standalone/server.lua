-- Last-resort fallback. Loaded last (alphabetically), but every real bridge
-- early-returns if it isn't the active inventory, so we only initialise the
-- stub when nothing else has populated `Inventory.AddItem` yet.
if Inventory and Inventory.AddItem then return end

Inventory = Inventory or {}

Inventory.AddItem = function(source, name, count)
    debugPrint(("[standalone bridge] no inventory wired — would give source=%s %sx %s"):format(source, count, name))
    return false
end

Inventory.RemoveItem = function() return false end
Inventory.GetItemCount = function() return 0 end
Inventory.GetPlayerItems = function() return {} end

print("[pickle_drugs] no supported inventory detected — running with the standalone stub. Add a bridge under bridge/<inv>/server.lua to enable harvest payouts.")
