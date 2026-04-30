RegisterNUICallback("getDealershipProgression", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:getDealershipProgression", false, data.dealershipId)
    cb({ progression = result })
end)

RegisterNUICallback("getDealershipFinances", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:getDealershipFinances", false, data.dealershipId)
    if result then
        cb({ success = true, data = result })
    else
        cb({ success = false, message = _L("management_finances_failed") })
    end
end)

RegisterNUICallback("withdrawFunds", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:withdrawFunds", false, {
        dealershipId = data.dealershipId,
        amount       = data.amount,
    })
    if result and result.success then
        ShowNotification(result.message)
        cb({ success = true, newBalance = result.newBalance })
    else
        ShowNotification(result and result.message or _L("management_withdrawal_failed"))
        cb({ success = false, message = result and result.message or _L("management_withdrawal_failed") })
    end
end)

RegisterNUICallback("depositFunds", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:depositFunds", false, {
        dealershipId = data.dealershipId,
        amount       = data.amount,
    })
    if result and result.success then
        ShowNotification(result.message)
        cb({ success = true, newBalance = result.newBalance })
    else
        ShowNotification(result and result.message or _L("management_deposit_failed"))
        cb({ success = false, message = result and result.message or _L("management_deposit_failed") })
    end
end)

RegisterNUICallback("upgradeTier", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:upgradeTier", false, {
        dealershipId = data.dealershipId,
    })
    if result and result.success then
        ShowNotification(result.message)
        -- Refresh the UI with updated tier info
        SendNUIMessage({
            type    = "tierUpgraded",
            newTier = result.newTier,
            newBalance = result.newBalance,
        })
        cb({ success = true, newTier = result.newTier, newBalance = result.newBalance })
    else
        ShowNotification(result and result.message or _L("management_upgrade_failed"))
        cb({ success = false, message = result and result.message or _L("management_upgrade_failed") })
    end
end)

RegisterNUICallback("createCoupon", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:createCoupon", false, {
        dealershipId  = data.dealershipId,
        code          = data.code,
        discountType  = data.discountType,
        discountValue = data.discountValue,
        maxUses       = data.maxUses,
        minPurchase   = data.minPurchase,
        vehicleFilter = data.vehicleFilter,
        expiresAt     = data.expiresAt,
    })
    if result and result.success then
        ShowNotification(result.message)
        cb({ success = true })
    else
        ShowNotification(result and result.message or _L("management_coupon_create_failed"))
        cb({ success = false, message = result and result.message or _L("management_coupon_create_failed") })
    end
end)

RegisterNUICallback("deleteCoupon", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:deleteCoupon", false, {
        dealershipId = data.dealershipId,
        couponId     = data.couponId,
    })
    if result and result.success then
        ShowNotification(result.message)
        cb({ success = true })
    else
        ShowNotification(result and result.message or _L("management_coupon_delete_failed"))
        cb({ success = false, message = result and result.message or _L("management_coupon_delete_failed") })
    end
end)

RegisterNUICallback("getCoupons", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:getCoupons", false, data.dealershipId)
    if result then
        cb({ success = true, coupons = result })
    else
        cb({ success = false, message = _L("management_coupons_fetch_failed") })
    end
end)

RegisterNUICallback("getCommissionRates", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:getCommissionRates", false, data.dealershipId)
    if result then
        cb({ success = true, rates = result })
    else
        cb({ success = false, message = _L("management_commission_fetch_failed") })
    end
end)

RegisterNUICallback("setCommissionRates", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:setCommissionRates", false, {
        dealershipId = data.dealershipId,
        rates        = data.rates, -- [{ level, rate }, ...]
    })
    if result and result.success then
        ShowNotification(result.message)
        cb({ success = true })
    else
        ShowNotification(result and result.message or _L("management_commission_update_failed"))
        cb({ success = false, message = result and result.message or _L("management_commission_update_failed") })
    end
end)

RegisterNUICallback("getShowroomAltCurrencies", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:getShowroomAltCurrencies", false, data.dealershipId)
    cb(result or {})
end)

RegisterNUICallback("getAcceptedAltCurrencies", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:getAcceptedAltCurrencies", false, data.dealershipId)
    if result then
        cb({ success = true, available = result.available or {}, accepted = result.accepted or {} })
    else
        cb({ success = false, available = {}, accepted = {} })
    end
end)

RegisterNUICallback("setAcceptedAltCurrencies", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:setAcceptedAltCurrencies", false, {
        dealershipId = data.dealershipId,
        accepted     = data.accepted,
    })
    if result and result.success then
        ShowNotification(result.message)
        cb({ success = true })
    else
        ShowNotification(result and result.message or _L("alt_currencies_update_failed"))
        cb({ success = false, message = result and result.message or _L("alt_currencies_update_failed") })
    end
end)

RegisterNUICallback("getSocietyAllowlist", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:getSocietyAllowlist", false, data.dealershipId)
    if result then
        cb({ success = true, allowlist = result.allowlist or {} })
    else
        cb({ success = false, message = _L("management_society_fetch_failed") })
    end
end)

RegisterNUICallback("setSocietyAllowlist", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:setSocietyAllowlist", false, {
        dealershipId = data.dealershipId,
        allowlist    = data.allowlist,
    })
    if result and result.success then
        ShowNotification(result.message)
        cb({ success = true })
    else
        ShowNotification(result and result.message or _L("management_society_update_failed"))
        cb({ success = false, message = result and result.message or _L("management_society_update_failed") })
    end
end)

RegisterNUICallback("canUseSocietyFunds", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:canUseSocietyFunds", false, data.dealershipId)
    cb({ match = result })
end)

RegisterNUICallback("getDashboardStats", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:getDashboardStats", false, data.dealershipId)
    if result then
        cb({ success = true, data = result })
    else
        cb({ success = false, message = _L("management_dashboard_failed") })
    end
end)

RegisterNUICallback("getRevenueReport", function(data, cb)
    local result = lib.callback.await("pickle_dealerships:getRevenueReport", false, data)
    cb(result)
end)
