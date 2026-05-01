-- =============================================
--  pickle_dealerships | bridge/vehicle_images/default/client.lua
--  Vehicle-image dispatcher + no-op default provider.
--
--  The NUI calls `getVehicleImageUrl` whenever a <VehicleImg> mounts
--  without an explicit `image` prop (i.e. no admin upload on the catalog
--  row). This file answers that callback by asking whatever provider
--  bridge has registered itself — the default returns nil, which lets
--  the NUI fall back to the packaged vehicle_images/ folder.
--
--  Concrete providers (see bridge/vehicle_images/uz_autoshot) overwrite
--  `VehicleImageProvider` during their own resource-ready thread.
-- =============================================

VehicleImageProvider = VehicleImageProvider or {
    name = "default",
    get  = function(_) return nil end,
}

--- Resolves a vehicle image URL for the given model, or nil if the
--- active provider can't produce one.
---@param model string
---@return string|nil
function ResolveVehicleImageURL(model)
    if type(model) ~= "string" or model == "" then return nil end
    if type(VehicleImageProvider) ~= "table" or type(VehicleImageProvider.get) ~= "function" then return nil end
    local url = VehicleImageProvider.get(model:lower())
    if type(url) == "string" and url ~= "" then return url end
    return nil
end

RegisterNUICallback("getVehicleImageUrl", function(data, cb)
    cb({ url = ResolveVehicleImageURL(data and data.model) })
end)
