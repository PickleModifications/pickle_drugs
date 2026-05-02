-- Storage shared helpers. Pure data — looked up by both client and server.

Storage = Storage or {}

--- Returns the type definition (label/model/slots) for a storage row, or nil.
---@param kind string|nil
function Storage.TypeFor(kind)
    if not kind or not Config or not Config.Storage or not Config.Storage.types then
        return nil
    end
    return Config.Storage.types[kind]
end

--- Slot cap for a storage row by kind. Falls back to 0 when the kind is
--- unknown — callers should treat that as "reject".
function Storage.SlotsFor(kind)
    local t = Storage.TypeFor(kind)
    return (t and tonumber(t.slots)) or 0
end

return Storage
