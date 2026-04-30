-- =============================================
--  pickle_dealerships | modules/financing/server.lua
--  Vehicle financing system — per-dealership settings, create/pay/repo
-- =============================================

-- ─── Helpers ────────────────────────────────────────────────────────────────

local function GetStockItem(stockId)
    local rows = MySQL.query.await(
        "SELECT * FROM `pickle_dealership_stock` WHERE `id` = ? LIMIT 1",
        { tonumber(stockId) }
    )
    return rows and rows[1] or nil
end

local function MarkStockSold(stockId, identifier, soldBy)
    MySQL.update(
        "UPDATE `pickle_dealership_stock` SET `sold_at` = NOW(), `sold_to` = ?, `sold_by` = ? WHERE `id` = ?",
        { identifier, soldBy, tonumber(stockId) }
    )
end

local function AddDealershipBalance(dealershipId, amount)
    MySQL.update.await(
        "UPDATE `pickle_dealerships` SET `balance` = `balance` + ? WHERE `id` = ?",
        { tonumber(amount), tonumber(dealershipId) }
    )
    local freshBalance = MySQL.scalar.await(
        "SELECT `balance` FROM `pickle_dealerships` WHERE `id` = ?",
        { tonumber(dealershipId) }
    )
    if freshBalance then
        UpdateDealershipCache(dealershipId, { balance = tonumber(freshBalance) })
    end
end

-- ─── Per-Dealership Financing Settings ──────────────────────────────────────

local DEFAULT_SETTINGS = {
    financingEnabled = true,
    minDownPercent = 30,
    interestRate = 5,
    paymentIntervalHours = 24,
    maxMissedPayments = 3,
    installmentOptions = { 4, 8, 12 },
    -- Credit score gate. The per-dealership toggle is meaningful only when
    -- Config.CreditScore.enabled is true on the server; otherwise the check
    -- silently no-ops. minCreditScore clamps to the typical FICO range.
    requireCreditScore = false,
    minCreditScore = 600,
}

local function GetFinancingSettings(dealershipId)
    local dealership = GetDealership(dealershipId)
    if not dealership then return DEFAULT_SETTINGS end

    -- Merge DB-stored settings over defaults
    local settings = {}
    for k, v in pairs(DEFAULT_SETTINGS) do settings[k] = v end

    local stored = dealership.financing_settings
    if stored then
        if type(stored) == "string" then stored = json.decode(stored) end
        if type(stored) == "table" then
            for k, v in pairs(stored) do
                if DEFAULT_SETTINGS[k] ~= nil then settings[k] = v end
            end
        end
    end

    -- Override with global Config as fallbacks (for legacy compat)
    if not dealership.financing_settings then
        settings.minDownPercent = (Config.FinancingMinDown or 0.30) * 100
        settings.interestRate = (Config.FinancingInterest or 0.05) * 100
        settings.paymentIntervalHours = Config.FinancingPaymentInterval or 24
        settings.maxMissedPayments = Config.FinancingMaxMissed or 3
    end

    return settings
end

lib.callback.register("pickle_dealerships:getFinancingSettings", function(_, data)
    local dealershipId = tonumber(data and data.dealershipId)
    if not dealershipId then return nil end

    local dealership = GetDealership(dealershipId)
    if not dealership then return nil end

    -- Financing used to be tier-gated; it's now available to every dealership.
    -- The owner can still toggle financing off via updateFinancingSettings, and
    -- the customer-facing UI reads `financingEnabled` off the returned blob.
    local blob = GetFinancingSettings(dealershipId)
    -- Surface whether a real credit-score provider is wired up so the
    -- settings UI can grey out / annotate the toggle instead of letting an
    -- owner enable a requirement that will never run.
    blob.creditScoreProviderActive = IsCreditScoreProviderActive()
    return blob
end)

lib.callback.register("pickle_dealerships:updateFinancingSettings", function(source, data)
    local dealershipId = tonumber(data and data.dealershipId)
    if not dealershipId then return false, "Invalid request." end

    local role = GetPlayerDealershipRole(source, dealershipId)
    if role ~= 'owner' and role ~= 'admin' then
        return false, "Only owners can change financing settings."
    end

    local settings = data.settings
    if type(settings) ~= "table" then return false, "Invalid settings." end

    -- Validate ranges
    local validated = {}
    validated.financingEnabled = settings.financingEnabled ~= false
    validated.minDownPercent = math.max(10, math.min(90, tonumber(settings.minDownPercent) or 30))
    validated.interestRate = math.max(0, math.min(50, tonumber(settings.interestRate) or 5))
    validated.paymentIntervalHours = math.max(1, math.min(168, tonumber(settings.paymentIntervalHours) or 24))
    validated.maxMissedPayments = math.max(1, math.min(10, tonumber(settings.maxMissedPayments) or 3))
    validated.requireCreditScore = settings.requireCreditScore == true
    validated.minCreditScore = math.max(300, math.min(850, tonumber(settings.minCreditScore) or 600))

    local opts = settings.installmentOptions
    if type(opts) == "table" and #opts > 0 then
        local validOpts = {}
        for _, v in ipairs(opts) do
            local n = tonumber(v)
            if n and n >= 2 and n <= 48 then validOpts[#validOpts + 1] = n end
        end
        table.sort(validOpts)
        validated.installmentOptions = #validOpts > 0 and validOpts or { 4, 8, 12 }
    else
        validated.installmentOptions = { 4, 8, 12 }
    end

    MySQL.update.await(
        "UPDATE `pickle_dealerships` SET `financing_settings` = ? WHERE `id` = ?",
        { json.encode(validated), dealershipId }
    )

    -- Refresh cache
    UpdateDealershipCache(dealershipId, { financing_settings = json.encode(validated) })

    return true
end)

-- ─── Create Financing ───────────────────────────────────────────────────────

--- Returns the player's cash + bank balances (for the financing dialog's pre-flight funds check)
lib.callback.register("pickle_dealerships:getPlayerBalances", function(source)
    return {
        cash = GetMoney(source, "money") or 0,
        bank = GetMoney(source, "bank") or 0,
    }
end)

lib.callback.register("pickle_dealerships:createFinancing", function(source, data)
    local dealershipId = tonumber(data.dealershipId)
    local stockId = tonumber(data.stockId)
    local downPayment = tonumber(data.downPayment) or 0
    local installments = tonumber(data.installments) or 12
    local paymentMethod = data.paymentMethod == "cash" and "money" or "bank"

    if not dealershipId or not stockId then
        return { success = false, message = "Invalid request." }
    end

    local dealership = GetDealership(dealershipId)
    if not dealership then
        return { success = false, message = "Dealership not found." }
    end

    -- Financing is no longer tier-gated. The dealership-level toggle below
    -- (settings.financingEnabled) is the only remaining gate, so owners can
    -- still opt out per-shop without admin intervention.
    local settings = GetFinancingSettings(dealershipId)
    if not settings.financingEnabled then
        return { success = false, message = "Financing is currently disabled at this dealership." }
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
    if stockItem.auction_id then
        return { success = false, message = "Vehicle is currently at auction." }
    end

    -- Validate installment count is in the allowed options
    local validInstallments = false
    for _, opt in ipairs(settings.installmentOptions or { 4, 8, 12 }) do
        if opt == installments then validInstallments = true break end
    end
    if not validInstallments then
        return { success = false, message = "Invalid installment plan." }
    end

    local price = stockItem.retail_price
    local minDown = math.floor(price * settings.minDownPercent / 100)

    if downPayment < minDown then
        return { success = false, message = ("Minimum down payment is %s (%d%%)."):format(GetCurrencyString(minDown), settings.minDownPercent) }
    end

    local identifier = GetIdentifier(source)
    if not identifier then
        return { success = false, message = "Could not identify player." }
    end

    -- Credit score gate. Only runs when both (a) the dealership opted in and
    -- (b) Config.CreditScore.enabled makes GetPlayerCreditScore return a real
    -- value. A nil score here means the provider is off/missing or doesn't
    -- know this player — fail closed so missing data can't be used to bypass
    -- the minimum.
    if settings.requireCreditScore and IsCreditScoreProviderActive() then
        local score = GetPlayerCreditScore(identifier)
        if not score then
            return { success = false, message = _L("financing_credit_score_unavailable") }
        end
        local required = tonumber(settings.minCreditScore) or 600
        if score < required then
            return { success = false, message = _L("financing_credit_score_too_low", required, score) }
        end
    end

    local playerMoney = GetMoney(source, paymentMethod)
    if playerMoney < downPayment then
        return { success = false, message = "Insufficient funds for down payment." }
    end

    -- Calculate financing details
    local remainingBalance = price - downPayment
    local interestRate = settings.interestRate / 100
    local totalWithInterest = remainingBalance + math.floor(remainingBalance * interestRate)
    local installmentAmount = math.ceil(totalWithInterest / installments)

    -- Deduct down payment from the selected account
    RemoveMoney(source, downPayment, paymentMethod)

    -- Sales tax
    local salesTax = math.floor(price * (Config.SalesTax or 0))
    local netDownPayment = downPayment - math.floor(downPayment * (Config.SalesTax or 0))

    AddDealershipBalance(dealershipId, netDownPayment)
    MarkStockSold(stockId, identifier, nil)

    -- Register vehicle with a single, authoritative plate (matches the sales flow
    -- so GetOwnedVehicleFromPlate resolves correctly for repossession / seize).
    local isUsed = stockItem.is_used == 1 or stockItem.is_used == true
    local plate
    local properties
    if isUsed and stockItem.plate and stockItem.plate ~= '' then
        plate = stockItem.plate
        properties = stockItem.metadata
        if type(properties) == "string" then properties = json.decode(properties) or {} end
        if type(properties) ~= "table" then properties = {} end
        properties.plate = plate
    else
        plate = GeneratePlate()
        properties = { plate = plate }
    end
    AddOwnedVehicleWithProps(source, stockItem.vehicle_model, plate, properties)

    -- Calculate next payment time
    local paymentIntervalSeconds = (settings.paymentIntervalHours or 24) * 3600
    local nextPaymentTimestamp = os.time() + paymentIntervalSeconds

    MySQL.insert(
        "INSERT INTO `pickle_dealership_financing` (`dealership_id`, `identifier`, `vehicle_plate`, `total_amount`, `amount_paid`, `installment_amount`, `interest_rate`, `next_payment`, `status`) VALUES (?, ?, ?, ?, ?, ?, ?, FROM_UNIXTIME(?), 'active')",
        {
            dealershipId,
            identifier,
            string.upper(plate),
            totalWithInterest,
            0,
            installmentAmount,
            settings.interestRate,
            nextPaymentTimestamp,
        }
    )

    AddLedgerEntry(dealershipId, "sale", price, ("Financed vehicle: %s (down: %s)"):format(stockItem.vehicle_label or stockItem.vehicle_model, GetCurrencyString(downPayment)), identifier)
    if salesTax > 0 then
        AddLedgerEntry(dealershipId, "tax", -salesTax, ("Sales tax on financed %s"):format(stockItem.vehicle_label or stockItem.vehicle_model), nil)
    end

    return {
        success = true,
        plate = plate,
        model = stockItem.vehicle_model,
        label = stockItem.vehicle_label or stockItem.vehicle_model,
        isUsed = isUsed,
        properties = isUsed and stockItem.metadata or nil,
        downPayment = downPayment,
        installmentAmount = installmentAmount,
        totalInstallments = installments,
        totalWithInterest = totalWithInterest,
        location = dealership.location,
    }
end)

-- ─── Make Payment ───────────────────────────────────────────────────────────

lib.callback.register("pickle_dealerships:makePayment", function(source, data)
    local financingId = tonumber(data.financingId)
    if not financingId then
        return { success = false, message = "Invalid request." }
    end

    local identifier = GetIdentifier(source)
    if not identifier then
        return { success = false, message = "Could not identify player." }
    end

    local rows = MySQL.query.await(
        "SELECT * FROM `pickle_dealership_financing` WHERE `id` = ? AND `identifier` = ? AND `status` = 'active' LIMIT 1",
        { financingId, identifier }
    )
    local financing = rows and rows[1] or nil
    if not financing then
        return { success = false, message = "Financing agreement not found or already completed." }
    end

    local paymentAmount = financing.installment_amount
    local remaining = financing.total_amount - financing.amount_paid

    if paymentAmount > remaining then
        paymentAmount = remaining
    end

    local playerMoney = GetMoney(source, "bank")
    if playerMoney < paymentAmount then
        return { success = false, message = "Insufficient funds for payment." }
    end

    RemoveMoney(source, paymentAmount, "bank")

    local newAmountPaid = financing.amount_paid + paymentAmount
    local fullyPaid = newAmountPaid >= financing.total_amount

    local netPayment = paymentAmount - math.floor(paymentAmount * (Config.SalesTax or 0))
    AddDealershipBalance(financing.dealership_id, netPayment)

    local settings = GetFinancingSettings(financing.dealership_id)
    local paymentIntervalSeconds = (settings.paymentIntervalHours or 24) * 3600
    local nextPaymentTimestamp = os.time() + paymentIntervalSeconds

    if fullyPaid then
        MySQL.update(
            "UPDATE `pickle_dealership_financing` SET `amount_paid` = ?, `status` = 'paid', `missed_payments` = 0 WHERE `id` = ?",
            { newAmountPaid, financingId }
        )
        AddLedgerEntry(financing.dealership_id, "financing_payment", paymentAmount, ("Final financing payment for plate %s"):format(financing.vehicle_plate), identifier)
    else
        MySQL.update(
            "UPDATE `pickle_dealership_financing` SET `amount_paid` = ?, `next_payment` = FROM_UNIXTIME(?), `missed_payments` = 0 WHERE `id` = ?",
            { newAmountPaid, nextPaymentTimestamp, financingId }
        )
        AddLedgerEntry(financing.dealership_id, "financing_payment", paymentAmount, ("Financing payment for plate %s"):format(financing.vehicle_plate), identifier)
    end

    return {
        success = true,
        amountPaid = paymentAmount,
        totalPaid = newAmountPaid,
        remaining = financing.total_amount - newAmountPaid,
        fullyPaid = fullyPaid,
    }
end)

-- ─── Get My Financing ───────────────────────────────────────────────────────

lib.callback.register("pickle_dealerships:getMyFinancing", function(source)
    local identifier = GetIdentifier(source)
    if not identifier then return {} end

    local rows = MySQL.query.await(
        "SELECT f.*, d.name AS dealership_name FROM `pickle_dealership_financing` f LEFT JOIN `pickle_dealerships` d ON f.dealership_id = d.id WHERE f.identifier = ? AND f.status = 'active' ORDER BY f.created_at DESC",
        { identifier }
    )
    if not rows then return {} end

    local results = {}
    for i = 1, #rows do
        local row = rows[i]
        results[#results + 1] = {
            id = row.id,
            dealershipId = row.dealership_id,
            dealershipName = row.dealership_name,
            vehiclePlate = row.vehicle_plate,
            totalAmount = row.total_amount,
            amountPaid = row.amount_paid,
            remaining = row.total_amount - row.amount_paid,
            installmentAmount = row.installment_amount,
            interestRate = row.interest_rate,
            nextPayment = row.next_payment,
            missedPayments = row.missed_payments,
            status = row.status,
            createdAt = row.created_at,
        }
    end

    return results
end)

-- ─── Owner: Get Dealership Agreements ──────────────────────────────────────

lib.callback.register("pickle_dealerships:getDealershipFinancingAgreements", function(source, data)
    local dealershipId = tonumber(data and data.dealershipId)
    if not dealershipId then return {} end

    local role = GetPlayerDealershipRole(source, dealershipId)
    if role ~= 'owner' and role ~= 'admin' then return {} end

    local rows = MySQL.query.await(
        "SELECT * FROM `pickle_dealership_financing` WHERE `dealership_id` = ? ORDER BY `status` ASC, `created_at` DESC",
        { dealershipId }
    ) or {}

    return rows
end)

-- ─── Owner: Forgive Loan ───────────────────────────────────────────────────

lib.callback.register("pickle_dealerships:forgiveLoan", function(source, data)
    local financingId = tonumber(data and data.financingId)
    local dealershipId = tonumber(data and data.dealershipId)
    if not financingId or not dealershipId then return false, "Invalid request." end

    local role = GetPlayerDealershipRole(source, dealershipId)
    if role ~= 'owner' and role ~= 'admin' then
        return false, "Only owners can forgive loans."
    end

    local rows = MySQL.query.await(
        "SELECT * FROM `pickle_dealership_financing` WHERE `id` = ? AND `dealership_id` = ? AND `status` = 'active' LIMIT 1",
        { financingId, dealershipId }
    )
    if not rows or not rows[1] then return false, "Agreement not found." end

    MySQL.update(
        "UPDATE `pickle_dealership_financing` SET `status` = 'paid', `amount_paid` = `total_amount`, `missed_payments` = 0 WHERE `id` = ?",
        { financingId }
    )

    AddLedgerEntry(dealershipId, "loan_forgiven", 0, ("Loan forgiven for plate %s by owner"):format(rows[1].vehicle_plate), GetIdentifier(source))

    return true
end)

-- ─── Financing Check Thread (Overdue Payments) ─────────────────────────────

CreateThread(function()
    Wait(10000)

    while true do
        Wait(5 * 60 * 1000) -- Every 5 minutes

        local now = os.time()
        local rows = MySQL.query.await(
            "SELECT * FROM `pickle_dealership_financing` WHERE `status` = 'active' AND `next_payment` IS NOT NULL AND `next_payment` < NOW()"
        )

        if rows then
            for i = 1, #rows do
                local financing = rows[i]
                local settings = GetFinancingSettings(financing.dealership_id)
                local maxMissed = settings.maxMissedPayments or 3
                local newMissed = financing.missed_payments + 1

                if newMissed >= maxMissed then
                    MySQL.update(
                        "UPDATE `pickle_dealership_financing` SET `status` = 'repossessed', `missed_payments` = ? WHERE `id` = ?",
                        { newMissed, financing.id }
                    )
                    RemoveOwnedVehicle(financing.identifier, financing.vehicle_plate)
                    AddLedgerEntry(financing.dealership_id, "repossession", 0, ("Vehicle repossessed: plate %s after %d missed payments"):format(financing.vehicle_plate, newMissed), financing.identifier)

                    LogDiscord("financing", {
                        title = "Vehicle Repossessed",
                        dealershipId = financing.dealership_id,
                        fields = {
                            { name = "Identifier", value = "`" .. tostring(financing.identifier) .. "`", inline = true },
                            { name = "Plate", value = "`" .. tostring(financing.vehicle_plate) .. "`", inline = true },
                            { name = "Missed Payments", value = tostring(newMissed), inline = true },
                            { name = "Total", value = GetCurrencyString(tonumber(financing.total_amount) or 0), inline = true },
                            { name = "Paid", value = GetCurrencyString(tonumber(financing.amount_paid) or 0), inline = true },
                        },
                    })

                    local playerSource = GetSourceFromIdentifier(financing.identifier)
                    if playerSource then
                        TriggerClientEvent("pickle_dealerships:vehicleRepossessed", playerSource, {
                            plate = financing.vehicle_plate,
                            missedPayments = newMissed,
                        })
                    end
                else
                    local paymentIntervalSeconds = (settings.paymentIntervalHours or 24) * 3600
                    local nextPaymentTimestamp = now + paymentIntervalSeconds

                    MySQL.update(
                        "UPDATE `pickle_dealership_financing` SET `missed_payments` = ?, `next_payment` = FROM_UNIXTIME(?) WHERE `id` = ?",
                        { newMissed, nextPaymentTimestamp, financing.id }
                    )

                    local playerSource = GetSourceFromIdentifier(financing.identifier)
                    if playerSource then
                        TriggerClientEvent("pickle_dealerships:financingReminder", playerSource, {
                            plate = financing.vehicle_plate,
                            missedPayments = newMissed,
                            maxMissed = maxMissed,
                            installmentAmount = financing.installment_amount,
                            remaining = financing.total_amount - financing.amount_paid,
                        })
                    end
                end
            end
        end
    end
end)
