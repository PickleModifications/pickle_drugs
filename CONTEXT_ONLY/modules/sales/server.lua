-- =============================================
--  pickle_dealerships | modules/sales/server.lua
--  Vehicle sales to players
-- =============================================

-- ─── Test drive routing buckets ─────────────────────────────────────────────
-- Each test drive runs in its own bucket so the driver can't crash into other
-- players, other players' vehicles, or traffic. Bucket IDs are derived from
-- server ID so concurrent drives don't collide. Restored on test drive end,
-- player disconnect, or resource stop.

local TEST_DRIVE_BUCKET_BASE = 90000
local originalBuckets = {} -- [src] = previous bucket id

local function EnterTestDriveBucket(source)
    local src = tonumber(source)
    if not src or originalBuckets[src] then return end
    local key = tostring(src)
    originalBuckets[src] = GetPlayerRoutingBucket(key)
    SetPlayerRoutingBucket(key, TEST_DRIVE_BUCKET_BASE + src)
end

local function LeaveTestDriveBucket(source)
    local src = tonumber(source)
    if not src then return end
    local prev = originalBuckets[src]
    if prev == nil then return end
    SetPlayerRoutingBucket(tostring(src), prev)
    originalBuckets[src] = nil
end

RegisterNetEvent('pickle_dealerships:enterTestDriveBucket', function()
    EnterTestDriveBucket(source)
end)

RegisterNetEvent('pickle_dealerships:leaveTestDriveBucket', function()
    LeaveTestDriveBucket(source)
end)

AddEventHandler('playerDropped', function()
    LeaveTestDriveBucket(source)
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    for src, prev in pairs(originalBuckets) do
        pcall(SetPlayerRoutingBucket, tostring(src), prev)
    end
    originalBuckets = {}
end)

-- ─── Helpers ────────────────────────────────────────────────────────────────

local function GetStockItem(stockId)
    local rows = MySQL.query.await(
        "SELECT * FROM `pickle_dealership_stock` WHERE `id` = ? LIMIT 1",
        { tonumber(stockId) }
    )
    return rows and rows[1] or nil
end

local function ValidateCoupon(dealershipId, code, purchasePrice)
    if not code or code == "" then return nil end
    local rows = MySQL.query.await(
        "SELECT * FROM `pickle_dealership_coupons` WHERE `dealership_id` = ? AND `code` = ? LIMIT 1",
        { tonumber(dealershipId), tostring(code) }
    )
    local coupon = rows and rows[1] or nil
    if not coupon then return nil end
    if coupon.uses >= coupon.max_uses then return nil end
    if coupon.expires_at and os.time() > coupon.expires_at then return nil end
    if coupon.min_purchase > 0 and purchasePrice < coupon.min_purchase then return nil end

    local discount = 0
    if coupon.discount_type == "percent" then
        discount = math.floor(purchasePrice * (tonumber(coupon.discount_value) / 100))
    else
        discount = math.floor(tonumber(coupon.discount_value))
    end

    -- Increment uses
    MySQL.update("UPDATE `pickle_dealership_coupons` SET `uses` = `uses` + 1 WHERE `id` = ?", { coupon.id })

    return discount, coupon
end

local function MarkStockSold(stockId, identifier, soldBy)
    local stock = MySQL.single.await(
        "SELECT `quantity`, `acquired_from` FROM `pickle_dealership_stock` WHERE `id` = ?",
        { tonumber(stockId) }
    )
    -- NPC-seeded stock is intentionally infinite — don't decrement or mark sold
    -- so the automated dealership keeps offering the vehicle.
    if stock and stock.acquired_from == 'npc_seed' then
        return
    end
    if stock and stock.quantity > 1 then
        MySQL.update(
            "UPDATE `pickle_dealership_stock` SET `quantity` = `quantity` - 1 WHERE `id` = ?",
            { tonumber(stockId) }
        )
    else
        MySQL.update(
            "UPDATE `pickle_dealership_stock` SET `sold_at` = NOW(), `sold_to` = ?, `sold_by` = ? WHERE `id` = ?",
            { identifier, soldBy, tonumber(stockId) }
        )
    end
end

local function AddDealershipBalance(dealershipId, amount)
    MySQL.update.await(
        "UPDATE `pickle_dealerships` SET `balance` = `balance` + ? WHERE `id` = ?",
        { tonumber(amount), tonumber(dealershipId) }
    )
    -- Read fresh balance from DB to keep cache accurate
    local freshBalance = MySQL.scalar.await(
        "SELECT `balance` FROM `pickle_dealerships` WHERE `id` = ?",
        { tonumber(dealershipId) }
    )
    if freshBalance then
        UpdateDealershipCache(dealershipId, { balance = tonumber(freshBalance) })
    end
end

--- Returns the matched allowlist entry for this player against the dealership's
--- society allowlist, or nil if they do not qualify.
local function MatchSocietyAllowlist(source, dealership)
    local meta = dealership and dealership.metadata
    if type(meta) == "string" then meta = json.decode(meta) or {} end
    if type(meta) ~= "table" then return nil end

    local allowlist = meta.societyAllowlist
    if type(allowlist) ~= "table" or #allowlist == 0 then return nil end

    local jobName = GetPlayerJobName and GetPlayerJobName(source) or nil
    local jobGrade = GetPlayerJobGrade and GetPlayerJobGrade(source) or 0
    local gangName = GetPlayerGangName and GetPlayerGangName(source) or nil
    local gangGrade = GetPlayerGangGrade and GetPlayerGangGrade(source) or 0

    for _, entry in ipairs(allowlist) do
        local minGrade = tonumber(entry.minGrade) or 0
        if entry.type == "job" and entry.name and entry.name == jobName and jobGrade >= minGrade then
            return entry
        elseif entry.type == "gang" and entry.name and entry.name == gangName and gangGrade >= minGrade then
            return entry
        end
    end
    return nil
end

--- Returns true if the player meets the stock item's min-grade requirement.
--- Grade is matched against the dealership's configured faction (job or gang).
local function PlayerMeetsMinGrade(source, dealership, stockItem)
    local stockMeta = stockItem and stockItem.metadata
    if type(stockMeta) == "string" then stockMeta = json.decode(stockMeta) or {} end
    if type(stockMeta) ~= "table" then return true end

    local minGrade = tonumber(stockMeta.minGrade)
    if not minGrade or minGrade <= 0 then return true end

    local faction = GetDealershipFaction(dealership)
    if not faction.name or faction.name == "" then return true end

    if faction.type == "gang" then
        local gangName = GetPlayerGangName and GetPlayerGangName(source) or nil
        if gangName ~= faction.name then return false end
        return (GetPlayerGangGrade and GetPlayerGangGrade(source) or 0) >= minGrade
    else
        local jobName = GetPlayerJobName and GetPlayerJobName(source) or nil
        if jobName ~= faction.name then return false end
        return (GetPlayerJobGrade and GetPlayerJobGrade(source) or 0) >= minGrade
    end
end

local function ProcessSale(source, dealershipId, stockItem, paymentMethod, couponCode, soldByCitizenid)
    local identifier = GetIdentifier(source)
    if not identifier then return false, "Could not identify player." end

    local dealership = GetDealership(dealershipId)
    if not dealership then return false, "Dealership not found." end

    if not PlayerCanAccessDealership(source, dealership) then
        return false, _L("error_access_denied")
    end

    if not PlayerMeetsMinGrade(source, dealership, stockItem) then
        return false, _L("error_grade_too_low")
    end

    local price = stockItem.retail_price
    local discount = 0
    if couponCode and couponCode ~= "" then
        discount = ValidateCoupon(dealershipId, couponCode, price) or 0
    end
    local finalPrice = math.max(0, price - discount)

    local societyEntry = nil
    local altCurrencyUsed = nil -- populated when paymentMethod begins with "alt:"
    if type(paymentMethod) == "string" and paymentMethod:sub(1, 4) == "alt:" then
        local key = paymentMethod:sub(5)
        local def = GetAltCurrency and GetAltCurrency(key) or nil
        if not def then
            return false, _L("error_alt_currency_unavailable")
        end

        -- Dealership must opt into this currency.
        local meta = dealership.metadata
        if type(meta) == "string" then meta = json.decode(meta) or {} end
        local accepted = type(meta) == "table" and meta.acceptedAltCurrencies or {}
        local ok = false
        for _, k in ipairs(accepted) do if k == key then ok = true; break end end
        if not ok then
            return false, _L("error_alt_currency_not_accepted")
        end

        local native = AltCurrencyNativeAmount(def, finalPrice)
        local balance = tonumber(def.get(source)) or 0
        if balance < native then
            return false, _L("error_alt_currency_insufficient", def.label or key)
        end
        if not def.remove(source, native) then
            return false, _L("error_alt_currency_insufficient", def.label or key)
        end
        altCurrencyUsed = { key = key, label = def.label or key, native = native }
    elseif paymentMethod == "society" then
        societyEntry = MatchSocietyAllowlist(source, dealership)
        if not societyEntry then
            return false, _L("error_not_in_allowlist")
        end

        local societyName = societyEntry.name
        local balance = 0
        local done = false
        GetSocietyBalance(societyName, function(b) balance = tonumber(b) or 0; done = true end)
        local waited = 0
        while not done and waited < 3000 do
            Wait(25); waited = waited + 25
        end
        if balance < finalPrice then
            return false, _L("error_society_insufficient")
        end
        RemoveSocietyMoney(societyName, finalPrice)
    else
        -- Cash / bank. Dealerships can disable either to force alt-currency sales
        -- (e.g. donator-only shops). Default both on when the flag is unset.
        local basePaymentMeta = dealership.metadata
        if type(basePaymentMeta) == "string" then basePaymentMeta = json.decode(basePaymentMeta) or {} end
        local baseCfg = type(basePaymentMeta) == "table" and basePaymentMeta.acceptedBasePayments or nil
        local cashOn = not baseCfg or baseCfg.cash ~= false
        local bankOn = not baseCfg or baseCfg.bank ~= false
        if paymentMethod == "bank" and not bankOn then
            return false, _L("error_payment_method_disabled") or "This dealership doesn't accept bank payments."
        end
        if (paymentMethod == "cash" or paymentMethod == "money") and not cashOn then
            return false, _L("error_payment_method_disabled") or "This dealership doesn't accept cash payments."
        end

        local currency = "money"
        if paymentMethod == "bank" then
            currency = "bank"
        end

        -- Check funds
        local playerMoney = GetMoney(source, currency)
        if playerMoney < finalPrice then
            return false, "Insufficient funds."
        end

        -- Deduct money
        RemoveMoney(source, finalPrice, currency)
    end

    -- Mark stock as sold
    MarkStockSold(stockItem.id, identifier, soldByCitizenid)

    -- Calculate tax and net revenue
    local salesTax = math.floor(finalPrice * Config.SalesTax)
    local netRevenue = finalPrice - salesTax

    -- Add revenue to dealership balance
    AddDealershipBalance(dealershipId, netRevenue)

    -- Ledger: sale
    local ledgerDesc = ("Vehicle sold: %s for %s"):format(stockItem.vehicle_label or stockItem.vehicle_model, GetCurrencyString(finalPrice))
    if societyEntry then
        ledgerDesc = ledgerDesc .. (" (society: %s:%s)"):format(societyEntry.type, societyEntry.name)
    elseif altCurrencyUsed then
        ledgerDesc = ledgerDesc .. (" (alt: %s x%d)"):format(altCurrencyUsed.key, altCurrencyUsed.native)
    end
    AddLedgerEntry(dealershipId, "sale", finalPrice, ledgerDesc, identifier)

    -- Ledger: tax
    if salesTax > 0 then
        AddLedgerEntry(dealershipId, "tax", -salesTax, ("Sales tax on %s"):format(stockItem.vehicle_label or stockItem.vehicle_model), nil)
    end

    -- Commission
    if soldByCitizenid then
        -- Lookup priority: per-employee override → dealership grade-based rate (using the seller's
        -- REAL framework job grade, never a synthetic role label) → Config.DefaultCommission.
        local empRow = MySQL.single.await(
            "SELECT `commission_rate` FROM `pickle_dealership_employees` WHERE `dealership_id` = ? AND `identifier` = ? LIMIT 1",
            { tonumber(dealershipId), soldByCitizenid }
        )

        local commissionRate = Config.DefaultCommission or 0.08
        local empOverride = empRow and tonumber(empRow.commission_rate)
        if empOverride and empOverride > 0 then
            -- DB stores percentage (0-100); normalise to decimal.
            commissionRate = empOverride / 100
        else
            local meta = dealership and dealership.metadata
            if type(meta) == "string" then meta = json.decode(meta) or {} end
            if dealership and type(meta) == "table" and type(meta.commissionRates) == "table" and dealership.job and dealership.job ~= "" then
                local sellerSource = GetSourceFromIdentifier(soldByCitizenid)
                local sellerGrade = sellerSource and GetPlayerJobGrade and GetPlayerJobGrade(sellerSource) or nil
                if sellerGrade then
                    -- commissionRates is stored with string keys (JSON normalisation) keyed by level.
                    local gradeRate = meta.commissionRates[tostring(sellerGrade)] or meta.commissionRates[sellerGrade]
                    if gradeRate then
                        commissionRate = tonumber(gradeRate) / 100
                    end
                end
            end
        end

        -- Commission is a percentage of PROFIT (sale price minus what the
        -- dealership paid for the unit), not of the sale price itself. Losses
        -- on a sale yield no commission.
        local wholesaleCost = tonumber(stockItem.wholesale_cost) or 0
        local profit = math.max(0, finalPrice - wholesaleCost)
        local commission = math.floor(profit * commissionRate)
        if commission > 0 then
            -- Deduct commission from dealership balance
            AddDealershipBalance(dealershipId, -commission)

            -- Pay the salesperson
            local sellerSource = GetSourceFromIdentifier(soldByCitizenid)
            if sellerSource then
                AddMoney(sellerSource, commission, "bank")
            end

            AddLedgerEntry(dealershipId, "commission", -commission, ("Commission to salesperson for %s"):format(stockItem.vehicle_label or stockItem.vehicle_model), soldByCitizenid)
        end
    end

    -- Register vehicle with a single, authoritative plate
    local isUsed = stockItem.is_used == true or tonumber(stockItem.is_used) == 1
    local plate
    local props
    if isUsed and stockItem.plate and stockItem.plate ~= '' then
        plate = stockItem.plate
        props = stockItem.metadata
        if type(props) == 'string' then props = json.decode(props) or {} end
        if type(props) ~= 'table' then props = {} end
        props.plate = plate
    else
        plate = GeneratePlate()
        props = { plate = plate }
    end
    AddOwnedVehicleWithProps(source, stockItem.vehicle_model, plate, props)

    -- Notify
    -- Award dealership XP (progression / auto-tier).
    if AwardDealershipXP then
        local cfg = Config.DealershipProgression or {}
        local xp = (cfg.xpPerSale or 0) + math.floor(finalPrice * (cfg.xpPerSaleRevenueRate or 0))
        AwardDealershipXP(dealershipId, xp)
    end

    -- Purchase success toast is delivered by the NUI wrapper on the buyer's client
    -- (sales_purchase_success); skip the server-side dupe.

    debugPrint(("[Sales] Player %s purchased %s (stock #%d) for %s"):format(identifier, stockItem.vehicle_model, stockItem.id, GetCurrencyString(finalPrice)))

    LogDiscord("sales", {
        title = isUsed and "Pre-Owned Sale" or "Vehicle Sale",
        actor = source,
        dealershipId = dealershipId,
        fields = {
            { name = "Dealership", value = dealership and dealership.name or "?", inline = true },
            { name = "Vehicle", value = (stockItem.vehicle_label or stockItem.vehicle_model) .. " (`" .. (stockItem.vehicle_model or "?") .. "`)", inline = true },
            { name = "Plate", value = "`" .. tostring(plate or "?") .. "`", inline = true },
            { name = "Price", value = GetCurrencyString(finalPrice), inline = true },
            { name = "Payment", value = tostring(altCurrencyUsed and altCurrencyUsed.key or paymentMethod or "?"), inline = true },
            { name = "Salesperson", value = tostring(soldByCitizenid and ("`" .. soldByCitizenid .. "`") or "self-service"), inline = true },
        },
    })

    return true, plate, finalPrice
end

-- ─── Callbacks ──────────────────────────────────────────────────────────────

lib.callback.register("pickle_dealerships:purchaseVehicle", function(source, data)
    local dealershipId = tonumber(data.dealershipId)
    local stockId = tonumber(data.stockId)
    local paymentMethod = data.paymentMethod or "cash"
    local couponCode = data.couponCode
    if not dealershipId or not stockId then
        return { success = false, message = "Invalid request." }
    end

    local dealership = GetDealership(dealershipId)
    if not dealership then
        return { success = false, message = "Dealership not found." }
    end

    local stockItem = GetStockItem(stockId)
    if not stockItem then
        return { success = false, message = "Vehicle not found in stock." }
    end
    if stockItem.dealership_id ~= dealershipId then
        return { success = false, message = "Vehicle does not belong to this dealership." }
    end
    if not stockItem.delivered_at then
        return { success = false, message = "Vehicle has not been delivered yet." }
    end
    if stockItem.sold_at then
        return { success = false, message = "Vehicle has already been sold." }
    end
    if stockItem.unlisted == 1 or stockItem.unlisted == true then
        return { success = false, message = "This vehicle is not available for purchase." }
    end

    local success, plate, finalPrice = ProcessSale(source, dealershipId, stockItem, paymentMethod, couponCode, nil)
    if not success then
        return { success = false, message = plate } -- plate holds error message on failure
    end

    return {
        success = true,
        plate = plate,
        price = finalPrice,
        model = stockItem.vehicle_model,
        label = stockItem.vehicle_label or stockItem.vehicle_model,
        -- Surface the dealership's location key so the client picks up
        -- the correct spawnPoint from DealershipConfigs instead of the
        -- first dealership it happens to iterate over.
        location = dealership.location,
    }
end)

lib.callback.register("pickle_dealerships:employeeSale", function(source, data)
    local dealershipId = tonumber(data.dealershipId)
    local stockId = tonumber(data.stockId)
    local targetPlayerId = tonumber(data.targetPlayerId)
    local couponCode = data.couponCode
    if not dealershipId or not stockId or not targetPlayerId then
        return { success = false, message = "Invalid request." }
    end

    -- Verify the employee can sell
    if not CanPlayerSell(source, dealershipId) then
        return { success = false, message = "You do not have permission to sell vehicles." }
    end

    local dealership = GetDealership(dealershipId)
    if not dealership then
        return { success = false, message = "Dealership not found." }
    end

    local stockItem = GetStockItem(stockId)
    if not stockItem then
        return { success = false, message = "Vehicle not found in stock." }
    end
    if stockItem.dealership_id ~= dealershipId then
        return { success = false, message = "Vehicle does not belong to this dealership." }
    end
    if not stockItem.delivered_at then
        return { success = false, message = "Vehicle has not been delivered yet." }
    end
    if stockItem.sold_at then
        return { success = false, message = "Vehicle has already been sold." }
    end

    -- Verify target player exists
    local targetName = GetPlayerName(targetPlayerId)
    if not targetName then
        return { success = false, message = "Target player not found." }
    end

    local sellerCitizenid = GetIdentifier(source)

    -- Use custom price if provided, otherwise use retail price
    local salePrice = data.price and tonumber(data.price) or stockItem.retail_price
    if salePrice and salePrice ~= stockItem.retail_price then
        -- Update the retail price temporarily for this sale
        stockItem.retail_price = salePrice
    end

    -- Trigger confirmation on the target player's client
    TriggerClientEvent("pickle_dealerships:confirmPurchase", targetPlayerId, {
        dealershipId = dealershipId,
        stockId = stockId,
        model = stockItem.vehicle_model,
        label = stockItem.vehicle_label or stockItem.vehicle_model,
        price = stockItem.retail_price,
        couponCode = couponCode,
        soldBy = sellerCitizenid,
        sellerName = GetPlayerCharacterName(source),
        -- Dealership location key so the customer's client resolves the
        -- correct spawnPoint on its own DealershipConfigs.
        location = dealership.location,
    })

    return { success = true, message = "Purchase confirmation sent to customer." }
end)

-- Handle confirmed employee sale from the target player
lib.callback.register("pickle_dealerships:confirmEmployeeSale", function(source, data)
    local dealershipId = tonumber(data.dealershipId)
    local stockId = tonumber(data.stockId)
    local paymentMethod = data.paymentMethod or "bank"
    local couponCode = data.couponCode
    local soldBy = data.soldBy

    if not dealershipId or not stockId then
        return { success = false, message = "Invalid request." }
    end

    local stockItem = GetStockItem(stockId)
    if not stockItem then
        return { success = false, message = "Vehicle no longer available." }
    end
    if stockItem.sold_at then
        return { success = false, message = "Vehicle has already been sold." }
    end

    -- Override retail price if custom price was set
    if data.price then
        stockItem.retail_price = tonumber(data.price)
    end

    local dealership = GetDealership(dealershipId)
    if not dealership then
        return { success = false, message = "Dealership not found." }
    end

    local success, plate, finalPrice = ProcessSale(source, dealershipId, stockItem, paymentMethod, couponCode, soldBy)
    if not success then
        return { success = false, message = plate }
    end

    return {
        success = true,
        plate = plate,
        price = finalPrice,
        model = stockItem.vehicle_model,
        label = stockItem.vehicle_label or stockItem.vehicle_model,
        location = dealership.location,
    }
end)

--- Returns the alt payment methods this dealership accepts, including the
--- calling player's balance and the native amount needed for `price`. Called
--- by the sales UI to render dynamic payment tabs.
lib.callback.register("pickle_dealerships:getAltPaymentOptions", function(source, data)
    local dealershipId = tonumber(data and data.dealershipId)
    local price = tonumber(data and data.price) or 0
    if not dealershipId then return {} end

    local dealership = GetDealership(dealershipId)
    if not dealership then return {} end

    local meta = dealership.metadata
    if type(meta) == "string" then meta = json.decode(meta) or {} end
    local accepted = type(meta) == "table" and meta.acceptedAltCurrencies or {}

    local out = {}
    for _, key in ipairs(accepted) do
        local def = GetAltCurrency and GetAltCurrency(key) or nil
        if def then
            local native = AltCurrencyNativeAmount(def, price)
            local balance = tonumber(def.get(source)) or 0
            out[#out + 1] = {
                key = key,
                label = def.label or key,
                type = def.type,
                valuePerUnit = def.valuePerUnit,
                balance = balance,
                required = native,
                canAfford = balance >= native,
            }
        end
    end
    return out
end)

lib.callback.register("pickle_dealerships:getVehicleDetails", function(source, data)
    local stockId = tonumber(data.stockId)
    if not stockId then return nil end

    local stockItem = GetStockItem(stockId)
    if not stockItem then return nil end
    if stockItem.unlisted == 1 or stockItem.unlisted == true then return nil end

    -- Parse color JSON if stored as string
    local color = stockItem.color
    if color and type(color) == "string" then
        color = json.decode(color)
    end

    -- Pre-owned units store the full vehicle property blob in `metadata`
    local isUsed = stockItem.is_used == true or tonumber(stockItem.is_used) == 1
    local properties = nil
    if isUsed then
        properties = stockItem.metadata
        if properties and type(properties) == "string" then
            properties = json.decode(properties)
        end
    end

    return {
        id = stockItem.id,
        dealershipId = stockItem.dealership_id,
        model = stockItem.vehicle_model,
        label = stockItem.vehicle_label or stockItem.vehicle_model,
        price = stockItem.retail_price,
        wholesaleCost = stockItem.wholesale_cost,
        color = color,
        condition = stockItem.condition,
        displaySpot = stockItem.display_spot,
        delivered = stockItem.delivered_at ~= nil,
        sold = stockItem.sold_at ~= nil,
        soldTo = stockItem.sold_to,
        soldBy = stockItem.sold_by,
        orderedAt = stockItem.ordered_at,
        deliveredAt = stockItem.delivered_at,
        soldAt = stockItem.sold_at,
        isUsed = isUsed,
        plate = stockItem.plate,
        acquiredFrom = stockItem.acquired_from,
        properties = properties,
    }
end)

lib.callback.register("pickle_dealerships:getPickleFax", function(_, data)
    local stockId = tonumber(data and data.stockId)
    if not stockId then return nil end

    local stockItem = GetStockItem(stockId)
    if not stockItem then return nil end

    local isUsed = stockItem.is_used == true or tonumber(stockItem.is_used) == 1
    if not isUsed then return nil end

    local properties = stockItem.metadata
    if properties and type(properties) == "string" then
        properties = json.decode(properties)
    end

    return {
        id = stockItem.id,
        model = stockItem.vehicle_model,
        label = stockItem.vehicle_label or stockItem.vehicle_model,
        isUsed = true,
        condition = tonumber(stockItem.condition) or 0,
        plate = stockItem.plate,
        acquiredFrom = stockItem.acquired_from,
        orderedAt = stockItem.ordered_at,
        deliveredAt = stockItem.delivered_at,
        retailPrice = stockItem.retail_price,
        wholesaleCost = stockItem.wholesale_cost,
        properties = properties,
    }
end)
