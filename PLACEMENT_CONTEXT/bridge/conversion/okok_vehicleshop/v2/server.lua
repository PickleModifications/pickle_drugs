-- =============================================
--  pickle_dealerships | bridge/conversion/okok_vehicleshop/v2/server.lua
--  okok Vehicleshop v2 adapter. Reuses entity factories from v1 via
--  OkokConversionHelpers, adds financing which only exists in v2.
-- =============================================

-- Financing: per-contract picker (not per-shop). Assigns each imported
-- contract to the first dealership the user has already imported in this
-- run, since okok's financed_vehicles table is not shop-scoped.
local financingEntity = {
    label = 'Active Financing Contracts',
    requires = { 'okokvehicleshop_financed_vehicles' },
    list = function()
        local rows = MySQL.query.await("SELECT id, vehicle_name, vehicle_plate, owner_id, finance_amount, paid_amount FROM okokvehicleshop_financed_vehicles") or {}
        local out = {}
        for _, r in ipairs(rows) do
            out[#out + 1] = {
                id = r.id,
                label = string.format('%s (%s) — %s owes $%s',
                    r.vehicle_name or '?', r.vehicle_plate or '?',
                    r.owner_id or '?',
                    tostring((tonumber(r.finance_amount) or 0) - (tonumber(r.paid_amount) or 0))),
                meta = { plate = r.vehicle_plate, owner = r.owner_id },
            }
        end
        return out
    end,
    import = function(selectedIds, _options, ctx)
        local res = { inserted = 0, skipped = 0, notFound = {} }
        local fallbackDealership = nil
        for _, pickleId in pairs(ctx.legacyIdMap) do fallbackDealership = pickleId; break end
        for _, id in ipairs(selectedIds) do
            local r = MySQL.single.await("SELECT * FROM okokvehicleshop_financed_vehicles WHERE id = ? LIMIT 1", { id })
            if not r then
                res.notFound[#res.notFound + 1] = id
            elseif not fallbackDealership then
                res.skipped = res.skipped + 1
            else
                local total = tonumber(r.finance_amount) or 0
                local paid = tonumber(r.paid_amount) or 0
                local status = (paid >= total and total > 0) and 'paid' or 'active'
                local newId = MySQL.insert.await(
                    "INSERT INTO pickle_dealership_financing (dealership_id, identifier, vehicle_plate, total_amount, amount_paid, installment_amount, missed_payments, status) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                    {
                        fallbackDealership, r.owner_id, r.vehicle_plate, total, paid,
                        tonumber(r.monthly_payment) or 0,
                        tonumber(r.failed_payments) or 0, status,
                    }
                )
                if newId then res.inserted = res.inserted + 1
                else res.skipped = res.skipped + 1 end
            end
        end
        return res
    end,
}

CreateThread(function()
    RegisterConversionAdapter({
        resource = 'okok_vehicleshop',
        version = 'v2',
        label = 'okok Vehicleshop (v2)',
        resourceLabel = 'okok Vehicleshop',
        order = { 'catalog', 'dealerships', 'employees', 'sales', 'financing' },
        entities = {
            catalog = OkokConversionHelpers.catalogEntity(),
            dealerships = OkokConversionHelpers.dealershipsEntity(true),
            employees = OkokConversionHelpers.employeesEntity(),
            sales = OkokConversionHelpers.salesEntity(),
            financing = financingEntity,
        },
    })
end)
