-- =============================================
--  pickle_dealerships | modules/financing/client.lua
--  Client-side financing interactions
-- =============================================

-- ─── NUI Callbacks ──────────────────────────────────────────────────────────

RegisterNUICallback("createFinancing", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:createFinancing", false, {
        dealershipId = data.dealershipId,
        stockId = data.stockId,
        downPayment = tonumber(data.downPayment) or 0,
        installments = tonumber(data.installments) or 12,
        paymentMethod = data.paymentMethod,
    })

    if result and result.success then
        ShowNotification(_L("financing_approved_detail",
            result.label or result.model,
            GetCurrencyString(result.downPayment),
            result.totalInstallments,
            GetCurrencyString(result.installmentAmount)
        ))

        -- Resolve spawn point from the specific dealership this contract
        -- is for. Old code iterated DealershipConfigs and picked the
        -- first entry with a spawnPoint, which landed customers at an
        -- unrelated shop's lot.
        local location = data.location or result.location
        local cfg = location and DealershipConfigs[location]
        local spawnPoint = cfg and cfg.spawnPoint

        if data.spawnPoint then
            spawnPoint = vector4(data.spawnPoint.x, data.spawnPoint.y, data.spawnPoint.z, data.spawnPoint.w or 0.0)
        end

        if spawnPoint and result.model then
            local modelHash = joaat(result.model)
            RequestModel(modelHash)
            local timeout = 0
            while not HasModelLoaded(modelHash) and timeout < 5000 do
                Wait(10)
                timeout = timeout + 10
            end
            if HasModelLoaded(modelHash) then
                local veh = CreateVeh(modelHash, spawnPoint.x, spawnPoint.y, spawnPoint.z, spawnPoint.w or 0.0, true, false)
                local ped = PlayerPedId()
                TaskWarpPedIntoVehicle(ped, veh, -1)
                SetVehicleEngineOn(veh, true, true, false)
                SetVehicleOnGroundProperly(veh)
            end
        end
    else
        ShowNotification(result and result.message or _L("financing_request_failed"))
    end

    cb(result or { success = false })
end)

RegisterNUICallback("makePayment", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:makePayment", false, {
        financingId = data.financingId,
    })

    if result and result.success then
        if result.fullyPaid then
            ShowNotification(_L("financing_fully_paid"))
        else
            ShowNotification(_L("financing_payment_received",
                GetCurrencyString(result.amountPaid),
                GetCurrencyString(result.remaining)
            ))
        end
    else
        ShowNotification(result and result.message or _L("financing_payment_failed"))
    end

    cb(result or { success = false })
end)

RegisterNUICallback("getPlayerBalances", function(_, cb)
    local result = lib.callback.await("pickle_dealerships:getPlayerBalances", false)
    cb(result or { cash = 0, bank = 0 })
end)

RegisterNUICallback("getMyFinancing", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:getMyFinancing", false, {})
    cb(result or {})
end)

RegisterNUICallback("getFinancingSettings", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:getFinancingSettings", false, {
        dealershipId = data and data.dealershipId or nil,
    })
    cb(result)
end)

RegisterNUICallback("updateFinancingSettings", function(data, cb)
    local ok, msg = lib.callback.await("pickle_dealerships:updateFinancingSettings", false, {
        dealershipId = data.dealershipId,
        settings = data.settings,
    })
    if not ok then ShowNotification(msg or _L("financing_settings_failed")) end
    cb({ success = ok })
end)

RegisterNUICallback("getDealershipFinancingAgreements", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:getDealershipFinancingAgreements", false, {
        dealershipId = data and data.dealershipId or nil,
    })
    cb(result or {})
end)

RegisterNUICallback("forgiveLoan", function(data, cb)
    local ok, msg = lib.callback.await("pickle_dealerships:forgiveLoan", false, {
        financingId = data.financingId,
        dealershipId = data.dealershipId,
    })
    if not ok then ShowNotification(msg or _L("financing_forgive_failed")) end
    cb({ success = ok })
end)

-- ─── Server Events ──────────────────────────────────────────────────────────

RegisterNetEvent("pickle_dealerships:financingReminder", function(data)
    local missedStr = ""
    if data.missedPayments and data.missedPayments > 0 then
        missedStr = (" You have %d/%d missed payments."):format(data.missedPayments, data.maxMissed or Config.FinancingMaxMissed or 3)
    end

    lib.notify({
        title = _L("financing_reminder_title"),
        description = _L("financing_reminder_desc",
            GetCurrencyString(data.installmentAmount),
            data.plate,
            missedStr,
            GetCurrencyString(data.remaining)
        ),
        type = "warning",
        duration = 10000,
    })
end)

RegisterNetEvent("pickle_dealerships:vehicleRepossessed", function(data)
    lib.notify({
        title = _L("financing_repossessed_title"),
        description = _L("financing_repossessed_desc",
            data.plate,
            data.missedPayments
        ),
        type = "error",
        duration = 15000,
    })
end)
