-- =============================================
--  pickle_dealerships | modules/conversion/client.lua
--  NUI → server bridge for the Import tab.
-- =============================================

RegisterNUICallback("conversionListResources", function(_, cb)
    cb(lib.callback.await("pickle_dealerships:conversionListResources", false) or {})
end)

RegisterNUICallback("conversionListEntity", function(data, cb)
    cb(lib.callback.await("pickle_dealerships:conversionListEntity", false, data) or { success = false })
end)

RegisterNUICallback("conversionRun", function(data, cb)
    cb(lib.callback.await("pickle_dealerships:conversionRun", false, data) or { success = false })
end)
