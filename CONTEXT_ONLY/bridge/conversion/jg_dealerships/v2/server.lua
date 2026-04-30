-- =============================================
--  pickle_dealerships | bridge/conversion/jg_dealerships/v2/server.lua
--  jg_dealerships v2 adapter. v2 introduces a real catalog table
--  (`dealership_vehicles`) and a quantitative stock table
--  (`dealership_stock`) — those entities are version-specific. The other
--  entities (dealerships/employees/coupons/sales) match v1 and are reused
--  via JgConversionHelpers.
-- =============================================

local function safeJsonDecode(value)
    if value == nil or value == '' then return nil end
    if type(value) == 'table' then return value end
    local ok, decoded = pcall(json.decode, value)
    if ok then return decoded end
    return nil
end

-- ===================== entity: catalog (v2 — real table) =====================
local catalogEntity = {
    label = 'Wholesale Catalog',
    requires = { 'dealership_vehicles' },
    list = function()
        local rows = MySQL.query.await("SELECT spawn_code, brand, model, category, price FROM dealership_vehicles ORDER BY brand, model") or {}
        local out = {}
        for _, r in ipairs(rows) do
            local brand = r.brand and r.brand ~= '' and (r.brand .. ' ') or ''
            out[#out + 1] = {
                id = r.spawn_code,
                label = brand .. (r.model or r.spawn_code) .. ' — $' .. (math.floor(tonumber(r.price) or 0)),
                meta = { class = r.category, price = tonumber(r.price) or 0 },
            }
        end
        return out
    end,
    import = function(selectedIds, options, _ctx)
        local policy = options.conflictPolicy or 'skip'
        local res = { inserted = 0, skipped = 0, notFound = {} }
        for _, id in ipairs(selectedIds) do
            local r = MySQL.single.await("SELECT * FROM dealership_vehicles WHERE spawn_code = ? LIMIT 1", { id })
            if not r then
                res.notFound[#res.notFound + 1] = id
            else
                local price = math.floor(tonumber(r.price) or 0)
                local minPrice = tonumber(r.min_price)
                local wholesale = (r.price_limits_enabled == 1 and minPrice) and math.floor(minPrice)
                    or math.max(1000, math.floor(price * 0.7))
                local label = r.model or r.spawn_code
                if r.brand and r.brand ~= '' then label = r.brand .. ' ' .. label end
                local class = r.category or 'sedan'
                local sql = policy == 'overwrite'
                    and "INSERT INTO pickle_wholesale_catalog (model, label, wholesale, tier, class, vehicle_type) VALUES (?, ?, ?, 'basic', ?, 'car') ON DUPLICATE KEY UPDATE wholesale = VALUES(wholesale), label = VALUES(label), class = VALUES(class)"
                    or  "INSERT IGNORE INTO pickle_wholesale_catalog (model, label, wholesale, tier, class, vehicle_type) VALUES (?, ?, ?, 'basic', ?, 'car')"
                local affected = MySQL.update.await(sql, { r.spawn_code, label, wholesale, class })
                if affected and affected > 0 then res.inserted = res.inserted + 1
                else res.skipped = res.skipped + 1 end
            end
        end
        return res
    end,
}

-- ===================== entity: stock (v2 — quantitative table) =====================
-- v2 uses `dealership_stock` with (dealership, vehicle, stock, price) where
-- `stock` is a quantity. We expose a synthetic id "<dealership>:<vehicle>" so the
-- user can pick individual rows in the UI. Each picked row inserts `stock`
-- copies into pickle_dealership_stock.
local stockEntity = {
    label = 'Stock',
    requires = { 'dealership_stock' },
    list = function()
        local rows = MySQL.query.await("SELECT dealership, vehicle, stock, price FROM dealership_stock") or {}
        local out = {}
        for _, r in ipairs(rows) do
            out[#out + 1] = {
                id = tostring(r.dealership) .. ':' .. tostring(r.vehicle),
                label = (r.vehicle or '?') .. ' x' .. (r.stock or 0) .. ' @ $' .. math.floor(tonumber(r.price) or 0),
                meta = { dealership = r.dealership, vehicle = r.vehicle, qty = r.stock },
            }
        end
        return out
    end,
    import = function(selectedIds, _options, ctx)
        local res = { inserted = 0, skipped = 0, notFound = {} }
        for _, compositeId in ipairs(selectedIds) do
            local dealership, vehicle = compositeId:match('^(.+):(.+)$')
            if not dealership or not vehicle then
                res.notFound[#res.notFound + 1] = compositeId
            else
                local r = MySQL.single.await(
                    "SELECT * FROM dealership_stock WHERE dealership = ? AND vehicle = ? LIMIT 1",
                    { dealership, vehicle }
                )
                local pickleId = ctx.legacyIdMap[tostring(dealership)]
                if not r then
                    res.notFound[#res.notFound + 1] = compositeId
                elseif not pickleId then
                    res.skipped = res.skipped + 1
                else
                    local catalogRow = MySQL.single.await(
                        "SELECT label, wholesale FROM pickle_wholesale_catalog WHERE model = ? LIMIT 1",
                        { vehicle }
                    )
                    local wholesale = (catalogRow and catalogRow.wholesale) or 50000
                    local label = (catalogRow and catalogRow.label) or vehicle
                    local retail = math.floor(tonumber(r.price) or wholesale * 1.3)
                    local qty = math.max(1, tonumber(r.stock) or 1)
                    local newId = MySQL.insert.await(
                        "INSERT INTO pickle_dealership_stock (dealership_id, vehicle_model, vehicle_label, wholesale_cost, retail_price, quantity, ordered_at, delivered_at, acquired_from) VALUES (?, ?, ?, ?, ?, ?, NOW(), NOW(), 'jg_v2_import')",
                        { pickleId, vehicle, label, wholesale, retail, qty }
                    )
                    if newId then res.inserted = res.inserted + 1
                    else res.skipped = res.skipped + 1 end
                end
            end
        end
        return res
    end,
}

-- Suppress luacheck unused-local warning for the helper we only carry for parity.
local _ = safeJsonDecode

CreateThread(function()
    RegisterConversionAdapter({
        resource = 'jg_dealerships',
        version = 'v2',
        resourceLabel = 'JG Dealerships',
        order = { 'catalog', 'dealerships', 'employees', 'stock', 'coupons', 'sales' },
        entities = {
            catalog = catalogEntity,
            dealerships = JgConversionHelpers.dealershipsEntity,
            employees = JgConversionHelpers.employeesEntity,
            stock = stockEntity,
            coupons = JgConversionHelpers.couponsEntity,
            sales = JgConversionHelpers.salesEntity,
        },
    })
end)
