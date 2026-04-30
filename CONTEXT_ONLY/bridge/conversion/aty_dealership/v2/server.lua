-- =============================================
--  pickle_dealerships | bridge/conversion/aty_dealership/v2/server.lua
--  aty_dealership v2 adapter.
--
--  aty stores one row per dealership in `aty_dealership` with most state
--  packed into JSON columns:
--    vehicles   = [{ model, label, category, stock, price, sellingPrice }, ...]
--    locations  = { purchase, ped, preview, orderPoint, spawn, dashboard,
--                   test, dealership }  -- each is { x, y, z, w }
--    employees  = [{ citizenid, rank, ... }]  (varies per server install)
--    coupons    = { "CODE": { discount, ... }, ... } | {}
--    ranks      = [...]  (ignored — pickle has its own RBAC)
--    sales      = [...]  (ignored — historical ledger)
--  Financing lives in a separate `vehicle_installments` table.
--
--  Conversion strategy: the "dealerships" entity is the root — importing a
--  row seeds ctx.legacyIdMap[sourceId] so the other entities can resolve
--  their FKs back to the new pickle dealership id. The catalog entity is
--  synthetic — aty has no catalog table, so we fold every unique
--  (model, label, price) across all vehicles JSON blobs into
--  pickle_wholesale_catalog.
-- =============================================

local function safeJsonDecode(value)
    if value == nil or value == '' then return nil end
    if type(value) == 'table' then return value end
    local ok, decoded = pcall(json.decode, value)
    if ok then return decoded end
    return nil
end

-- aty stores coords as { w, z, y, x }; pickle wants a plain { x, y, z, w }.
local function point(p)
    if type(p) ~= 'table' then return nil end
    local x, y, z = tonumber(p.x), tonumber(p.y), tonumber(p.z)
    if not x or not y or not z then return nil end
    return { x = x, y = y, z = z, w = tonumber(p.w) or 0.0 }
end

-- aty category strings → pickle class keys. Anything unmatched falls
-- through to 'sedan' which is pickle's own default so the import never
-- errors on an unknown category.
local CLASS_BY_CATEGORY = {
    sedans = 'sedan', sedan = 'sedan',
    compacts = 'compact', compact = 'compact',
    coupes = 'coupe', coupe = 'coupe',
    sports = 'sports',
    sportsclassics = 'sports_classic', sports_classics = 'sports_classic',
    super = 'super', supers = 'super',
    muscle = 'muscle', muscles = 'muscle',
    suvs = 'suv', suv = 'suv',
    offroad = 'offroad', offroads = 'offroad',
    vans = 'van', van = 'van',
    motorcycles = 'motorcycle', motorcycle = 'motorcycle', bikes = 'motorcycle',
    cycles = 'cycle', cycle = 'cycle',
    boats = 'boat', boat = 'boat',
    helicopters = 'helicopter', helicopter = 'helicopter',
    planes = 'plane', plane = 'plane',
}

local VEHICLE_TYPE_BY_CLASS = {
    boat = 'boat', helicopter = 'air', plane = 'air',
}

local function classOf(category)
    if not category then return 'sedan' end
    return CLASS_BY_CATEGORY[tostring(category):lower()] or 'sedan'
end

local function vehicleTypeOfClass(class)
    return VEHICLE_TYPE_BY_CLASS[class] or 'car'
end

--- Iterates every aty_dealership row's `vehicles` JSON array and yields
--- each decoded entry alongside its source row id. Used by both the
--- catalog and stock entities so neither duplicates the JSON traversal.
local function forEachAtyVehicle(cb)
    local rows = MySQL.query.await("SELECT id, vehicles FROM aty_dealership") or {}
    for _, r in ipairs(rows) do
        local list = safeJsonDecode(r.vehicles)
        if type(list) == 'table' then
            for _, v in ipairs(list) do
                if type(v) == 'table' and v.model then
                    cb(r.id, v)
                end
            end
        end
    end
end

-- ===================== entity: catalog =====================
-- aty has no catalog table; synthesise it from unique models across every
-- dealership's `vehicles` JSON. The picker shows one row per model, the
-- user ticks which ones to seed into pickle_wholesale_catalog.
local catalogEntity = {
    label = 'Wholesale Catalog',
    requires = { 'aty_dealership' },
    list = function()
        local byModel = {}
        forEachAtyVehicle(function(_id, v)
            local model = tostring(v.model):lower()
            if not byModel[model] then
                byModel[model] = {
                    model = model,
                    label = v.label,
                    category = v.category,
                    -- Prefer `price` as the wholesale input, sellingPrice is
                    -- aty's retail — but fall back if price is missing.
                    price = tonumber(v.price) or tonumber(v.sellingPrice) or 0,
                }
            end
        end)
        local out = {}
        for _, m in pairs(byModel) do
            out[#out + 1] = {
                id = m.model,
                label = (m.label or m.model) .. ' — $' .. math.floor(m.price),
                meta = { class = classOf(m.category), price = m.price },
            }
        end
        table.sort(out, function(a, b) return a.id < b.id end)
        return out
    end,
    import = function(selectedIds, options, _ctx)
        local policy = options.conflictPolicy or 'skip'
        local res = { inserted = 0, skipped = 0, notFound = {} }
        local set = {}
        for _, id in ipairs(selectedIds) do set[tostring(id):lower()] = true end

        local byModel = {}
        forEachAtyVehicle(function(_id, v)
            local model = tostring(v.model):lower()
            if set[model] and not byModel[model] then byModel[model] = v end
        end)

        for id in pairs(set) do
            local v = byModel[id]
            if not v then
                res.notFound[#res.notFound + 1] = id
            else
                -- aty's `price` is what the shop paid and `sellingPrice` is
                -- what it charges — pickle's `wholesale` matches `price`.
                -- Fall back to 70% of sellingPrice when only the retail is
                -- available so the import never produces a zero-cost row.
                local wholesale = math.floor(tonumber(v.price) or (tonumber(v.sellingPrice) or 0) * 0.7)
                if wholesale <= 0 then wholesale = 1000 end
                local class = classOf(v.category)
                local vtype = vehicleTypeOfClass(class)
                local label = v.label or id
                local sql = policy == 'overwrite'
                    and "INSERT INTO pickle_wholesale_catalog (model, label, wholesale, tier, class, vehicle_type) VALUES (?, ?, ?, 'basic', ?, ?) ON DUPLICATE KEY UPDATE wholesale = VALUES(wholesale), label = VALUES(label), class = VALUES(class), vehicle_type = VALUES(vehicle_type)"
                    or  "INSERT IGNORE INTO pickle_wholesale_catalog (model, label, wholesale, tier, class, vehicle_type) VALUES (?, ?, ?, 'basic', ?, ?)"
                local affected = MySQL.update.await(sql, { id, label, wholesale, class, vtype })
                if affected and affected > 0 then res.inserted = res.inserted + 1
                else res.skipped = res.skipped + 1 end
            end
        end
        return res
    end,
}

-- ===================== entity: dealerships =====================
local dealershipsEntity = {
    label = 'Dealerships',
    requires = { 'aty_dealership' },
    list = function()
        local rows = MySQL.query.await("SELECT id, name, owner, type, balance FROM aty_dealership ORDER BY id") or {}
        local out = {}
        for _, r in ipairs(rows) do
            out[#out + 1] = {
                id = r.id,
                label = (r.name or ('aty Dealership ' .. r.id)) .. (r.owner and (' — ' .. r.owner) or ''),
                meta = { mode = r.type, owner = r.owner, balance = tonumber(r.balance) or 0 },
            }
        end
        return out
    end,
    import = function(selectedIds, options, ctx)
        local policy = options.conflictPolicy or 'skip'
        local prefix = options.namePrefix or ''
        local res = { inserted = 0, skipped = 0, notFound = {} }
        for _, id in ipairs(selectedIds) do
            local r = MySQL.single.await("SELECT * FROM aty_dealership WHERE id = ?", { id })
            if not r then
                res.notFound[#res.notFound + 1] = id
            else
                local locationKey = 'aty_' .. tostring(r.id)
                if policy ~= 'duplicate' then
                    local existing = MySQL.single.await("SELECT id FROM pickle_dealerships WHERE location = ? LIMIT 1", { locationKey })
                    if existing then
                        ctx.legacyIdMap[tostring(r.id)] = existing.id
                        res.skipped = res.skipped + 1
                        goto continue
                    end
                end

                local locs = safeJsonDecode(r.locations) or {}
                local coords       = point(locs.dealership) or point(locs.preview) or point(locs.ped)
                local spawnPoint   = point(locs.spawn)
                local deliveryPt   = point(locs.orderPoint)
                local mgmtPoint    = point(locs.dashboard)
                local salesPoint   = point(locs.purchase)
                local showroomPt   = point(locs.preview) or point(locs.ped)

                local meta = {
                    imported_from = 'aty_dealership',
                    legacy_id = r.id,
                    acceptedCurrency = 'both',
                }
                if coords then meta.coords = coords end
                if spawnPoint then meta.spawnPoint = spawnPoint end
                if deliveryPt then meta.deliveryPoint = deliveryPt end

                local ipts = {}
                if mgmtPoint  then ipts.management = mgmtPoint end
                if salesPoint then ipts.sales      = salesPoint end
                if showroomPt then ipts.showroom   = showroomPt end
                if next(ipts) then meta.interactionPoints = ipts end

                -- aty's `job` column is 'all' for public-access dealerships;
                -- any other value is a faction gate.
                local factionName = (r.job and r.job ~= '' and r.job ~= 'all') and r.job or nil
                if factionName then meta.factionType = 'job' end

                local ownerId = (r.owner and r.owner ~= '') and r.owner or nil
                -- aty's `type` is 'owned' | 'self-served'. Pickle's
                -- equivalents are 'player-owned' and 'managed'.
                local mode = (r.type == 'owned' or ownerId) and 'player-owned' or 'managed'

                -- Best-effort type inference: if every vehicle category on
                -- the shop resolves to the same pickle type, use it;
                -- otherwise fall back to 'mixed'.
                local vehList = safeJsonDecode(r.vehicles) or {}
                local seenType, mixed = nil, false
                for _, v in ipairs(vehList) do
                    local vt = vehicleTypeOfClass(classOf(v.category))
                    if seenType == nil then seenType = vt
                    elseif seenType ~= vt then mixed = true; break end
                end
                local dealerType = mixed and 'mixed' or (seenType or 'car')

                local newId = MySQL.insert.await(
                    "INSERT INTO pickle_dealerships (name, location, type, mode, owner_identifier, balance, job, metadata) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                    {
                        prefix .. (r.name or ('aty Dealership ' .. r.id)),
                        locationKey,
                        dealerType,
                        mode,
                        ownerId,
                        tonumber(r.balance) or 0,
                        factionName,
                        json.encode(meta),
                    }
                )
                if newId then
                    ctx.legacyIdMap[tostring(r.id)] = newId
                    res.inserted = res.inserted + 1
                else
                    res.skipped = res.skipped + 1
                end
            end
            ::continue::
        end
        return res
    end,
}

-- ===================== entity: employees =====================
-- aty stores employees as a JSON array on each dealership row. We expose
-- one pickable entry per (dealership, employee) pair via a synthetic id.
local function parseAtyEmployees(dealershipId, rawJson)
    local list = safeJsonDecode(rawJson)
    if type(list) ~= 'table' then return {} end
    local out = {}
    for i, e in ipairs(list) do
        if type(e) == 'table' then
            -- aty installs vary on the exact keys — accept both
            -- citizenid/identifier and rank/role/job.
            local citizenid = e.citizenid or e.identifier or e.cid
            local role = e.rank or e.role or e.job or 'salesperson'
            if citizenid then
                out[#out + 1] = {
                    dealershipId = dealershipId,
                    index = i,
                    citizenid = citizenid,
                    role = tostring(role):lower(),
                }
            end
        end
    end
    return out
end

local employeesEntity = {
    label = 'Employees',
    requires = { 'aty_dealership' },
    list = function()
        local rows = MySQL.query.await("SELECT id, name, employees FROM aty_dealership") or {}
        local out = {}
        for _, r in ipairs(rows) do
            for _, emp in ipairs(parseAtyEmployees(r.id, r.employees)) do
                out[#out + 1] = {
                    id = emp.dealershipId .. ':' .. emp.index,
                    label = emp.citizenid .. ' (' .. emp.role .. ') @ ' .. (r.name or ('Dealership ' .. r.id)),
                    meta = { dealership = r.id, citizenid = emp.citizenid, role = emp.role },
                }
            end
        end
        return out
    end,
    import = function(selectedIds, _options, ctx)
        local res = { inserted = 0, skipped = 0, notFound = {} }
        -- Group picks by dealership so we read each source row once.
        local byDealership = {}
        for _, composite in ipairs(selectedIds) do
            local d, i = composite:match('^(%d+):(%d+)$')
            if d and i then
                byDealership[d] = byDealership[d] or {}
                byDealership[d][#byDealership[d] + 1] = tonumber(i)
            else
                res.notFound[#res.notFound + 1] = composite
            end
        end

        for sourceId, indices in pairs(byDealership) do
            local r = MySQL.single.await("SELECT employees FROM aty_dealership WHERE id = ?", { tonumber(sourceId) })
            local parsed = r and parseAtyEmployees(tonumber(sourceId), r.employees) or {}
            local pickleId = ctx.legacyIdMap[sourceId]
            if not pickleId then
                for _ = 1, #indices do res.skipped = res.skipped + 1 end
            else
                for _, idx in ipairs(indices) do
                    local emp = parsed[idx]
                    if not emp then
                        res.notFound[#res.notFound + 1] = sourceId .. ':' .. idx
                    else
                        -- aty's rank names don't line up with pickle's
                        -- fixed role enum (owner/manager/salesperson). Map
                        -- the common "boss"/"owner" ranks to manager so
                        -- they keep their elevated permissions; everything
                        -- else becomes a salesperson.
                        local role = emp.role
                        if role == 'boss' or role == 'owner' then
                            role = 'manager'
                        elseif role ~= 'manager' and role ~= 'salesperson' then
                            role = 'salesperson'
                        end
                        local newId = MySQL.insert.await(
                            "INSERT INTO pickle_dealership_employees (dealership_id, identifier, role, commission_rate) VALUES (?, ?, ?, 0)",
                            { pickleId, emp.citizenid, role }
                        )
                        if newId then res.inserted = res.inserted + 1
                        else res.skipped = res.skipped + 1 end
                    end
                end
            end
        end
        return res
    end,
}

-- ===================== entity: stock =====================
-- aty's per-dealership `vehicles` JSON doubles as catalog and stock. We
-- key each pickable row by "<dealership>:<model>" and insert one
-- pickle_dealership_stock row per pick (quantity column absorbs the
-- `stock` count).
local stockEntity = {
    label = 'Stock',
    requires = { 'aty_dealership' },
    list = function()
        local rows = MySQL.query.await("SELECT id, name, vehicles FROM aty_dealership") or {}
        local out = {}
        for _, r in ipairs(rows) do
            local list = safeJsonDecode(r.vehicles)
            if type(list) == 'table' then
                for _, v in ipairs(list) do
                    if type(v) == 'table' and v.model then
                        out[#out + 1] = {
                            id = tostring(r.id) .. ':' .. tostring(v.model):lower(),
                            label = (v.label or v.model) .. ' x' .. (tonumber(v.stock) or 1)
                                .. ' @ $' .. math.floor(tonumber(v.sellingPrice) or tonumber(v.price) or 0)
                                .. ' — ' .. (r.name or ('Dealership ' .. r.id)),
                            meta = {
                                dealership = r.id,
                                model = v.model,
                                stock = tonumber(v.stock) or 1,
                                sellingPrice = tonumber(v.sellingPrice) or 0,
                            },
                        }
                    end
                end
            end
        end
        return out
    end,
    import = function(selectedIds, _options, ctx)
        local res = { inserted = 0, skipped = 0, notFound = {} }
        -- Group picks by dealership row so each source is read once.
        local bySource = {}
        for _, composite in ipairs(selectedIds) do
            local d, m = composite:match('^(%d+):(.+)$')
            if d and m then
                bySource[d] = bySource[d] or {}
                bySource[d][m:lower()] = composite
            else
                res.notFound[#res.notFound + 1] = composite
            end
        end

        for sourceId, models in pairs(bySource) do
            local r = MySQL.single.await("SELECT vehicles FROM aty_dealership WHERE id = ?", { tonumber(sourceId) })
            local pickleId = ctx.legacyIdMap[sourceId]
            local list = r and safeJsonDecode(r.vehicles) or {}
            if not pickleId then
                for _ in pairs(models) do res.skipped = res.skipped + 1 end
            else
                for _, v in ipairs(list) do
                    local key = v.model and tostring(v.model):lower() or nil
                    if key and models[key] then
                        local wholesale = tonumber(v.price) or math.floor((tonumber(v.sellingPrice) or 0) * 0.7)
                        if wholesale <= 0 then wholesale = 1000 end
                        local retail = tonumber(v.sellingPrice) or math.floor(wholesale * 1.3)
                        local qty = math.max(1, tonumber(v.stock) or 1)
                        local newId = MySQL.insert.await(
                            "INSERT INTO pickle_dealership_stock (dealership_id, vehicle_model, vehicle_label, wholesale_cost, retail_price, quantity, ordered_at, delivered_at, acquired_from) VALUES (?, ?, ?, ?, ?, ?, NOW(), NOW(), 'aty_v2_import')",
                            { pickleId, v.model, v.label or v.model, wholesale, retail, qty }
                        )
                        if newId then res.inserted = res.inserted + 1
                        else res.skipped = res.skipped + 1 end
                        models[key] = nil
                    end
                end
                -- Anything left in `models` didn't match the current JSON.
                for composite in pairs(models) do res.notFound[#res.notFound + 1] = composite end
            end
        end
        return res
    end,
}

-- ===================== entity: coupons =====================
-- aty's coupons column is a JSON object keyed by code → { discount, ... }.
-- Shapes vary across forks; we read the common keys defensively and fall
-- back to a sane default when a field is missing.
local couponsEntity = {
    label = 'Coupons',
    requires = { 'aty_dealership' },
    list = function()
        local rows = MySQL.query.await("SELECT id, name, coupons FROM aty_dealership") or {}
        local out = {}
        for _, r in ipairs(rows) do
            local obj = safeJsonDecode(r.coupons)
            if type(obj) == 'table' then
                for code, def in pairs(obj) do
                    if type(def) == 'table' then
                        out[#out + 1] = {
                            id = tostring(r.id) .. ':' .. tostring(code),
                            label = tostring(code) .. ' — ' .. (r.name or ('Dealership ' .. r.id)),
                            meta = { dealership = r.id, code = code },
                        }
                    end
                end
            end
        end
        return out
    end,
    import = function(selectedIds, _options, ctx)
        local res = { inserted = 0, skipped = 0, notFound = {} }
        local bySource = {}
        for _, composite in ipairs(selectedIds) do
            local d, code = composite:match('^(%d+):(.+)$')
            if d and code then
                bySource[d] = bySource[d] or {}
                bySource[d][code] = composite
            else
                res.notFound[#res.notFound + 1] = composite
            end
        end

        for sourceId, codes in pairs(bySource) do
            local r = MySQL.single.await("SELECT coupons FROM aty_dealership WHERE id = ?", { tonumber(sourceId) })
            local obj = r and safeJsonDecode(r.coupons) or {}
            local pickleId = ctx.legacyIdMap[sourceId]
            if not pickleId then
                for _ in pairs(codes) do res.skipped = res.skipped + 1 end
            else
                for code in pairs(codes) do
                    local def = obj[code]
                    if type(def) ~= 'table' then
                        res.notFound[#res.notFound + 1] = sourceId .. ':' .. code
                    else
                        -- aty coupons use either a percent or flat value —
                        -- detect by presence of a `type` key, otherwise
                        -- inspect the numeric magnitude (<=100 ⇒ percent).
                        local rawValue = tonumber(def.discount) or tonumber(def.value) or tonumber(def.amount) or 0
                        local discountType = def.type or def.discountType
                        if not discountType then
                            discountType = (rawValue > 0 and rawValue <= 100) and 'percent' or 'flat'
                        end
                        local maxUses = tonumber(def.maxUses or def.uses_max or def.limit) or 1
                        local minPurchase = tonumber(def.minPurchase or def.min) or 0
                        local newId = MySQL.insert.await(
                            "INSERT IGNORE INTO pickle_dealership_coupons (dealership_id, code, discount_type, discount_value, max_uses, min_purchase) VALUES (?, ?, ?, ?, ?, ?)",
                            { pickleId, code, discountType, rawValue, maxUses, minPurchase }
                        )
                        if newId and newId > 0 then res.inserted = res.inserted + 1
                        else res.skipped = res.skipped + 1 end
                    end
                end
            end
        end
        return res
    end,
}

-- ===================== entity: financing =====================
-- aty keeps installments in a separate `vehicle_installments` table,
-- optionally keyed to a dealership id. Rows without a dealership_id (or
-- pointing at a dealership the user didn't import this run) fall back to
-- the first dealership pickle knows about from this import run, matching
-- the okok v2 adapter's behaviour.
local financingEntity = {
    label = 'Financing Contracts',
    requires = { 'vehicle_installments' },
    list = function()
        local rows = MySQL.query.await(
            "SELECT id, citizenid, vehicle_model, vehicle_label, plate, dealership_id, total_amount, remaining_amount, monthly_payment, remaining_months FROM vehicle_installments"
        ) or {}
        local out = {}
        for _, r in ipairs(rows) do
            out[#out + 1] = {
                id = r.id,
                label = string.format('%s (%s) — %s owes $%s',
                    r.vehicle_label or r.vehicle_model or '?',
                    r.plate or '?',
                    r.citizenid or '?',
                    tostring(tonumber(r.remaining_amount) or 0)),
                meta = { dealership = r.dealership_id, plate = r.plate, owner = r.citizenid },
            }
        end
        return out
    end,
    import = function(selectedIds, _options, ctx)
        local res = { inserted = 0, skipped = 0, notFound = {} }
        local fallback = nil
        for _, pickleId in pairs(ctx.legacyIdMap) do fallback = pickleId; break end

        for _, id in ipairs(selectedIds) do
            local r = MySQL.single.await("SELECT * FROM vehicle_installments WHERE id = ?", { id })
            if not r then
                res.notFound[#res.notFound + 1] = id
            else
                local pickleId = r.dealership_id and ctx.legacyIdMap[tostring(r.dealership_id)] or fallback
                if not pickleId then
                    res.skipped = res.skipped + 1
                else
                    local total = tonumber(r.total_amount) or 0
                    local remaining = tonumber(r.remaining_amount) or 0
                    local paid = math.max(0, total - remaining)
                    local status = (remaining <= 0 and total > 0) and 'paid' or 'active'
                    local newId = MySQL.insert.await(
                        "INSERT INTO pickle_dealership_financing (dealership_id, identifier, vehicle_plate, total_amount, amount_paid, installment_amount, status) VALUES (?, ?, ?, ?, ?, ?, ?)",
                        {
                            pickleId, r.citizenid, r.plate, total, paid,
                            tonumber(r.monthly_payment) or 0, status,
                        }
                    )
                    if newId then res.inserted = res.inserted + 1
                    else res.skipped = res.skipped + 1 end
                end
            end
        end
        return res
    end,
}

CreateThread(function()
    RegisterConversionAdapter({
        resource = 'aty_dealership',
        version = 'v2',
        resourceLabel = 'aty Dealership',
        order = { 'catalog', 'dealerships', 'employees', 'stock', 'coupons', 'financing' },
        entities = {
            catalog = catalogEntity,
            dealerships = dealershipsEntity,
            employees = employeesEntity,
            stock = stockEntity,
            coupons = couponsEntity,
            financing = financingEntity,
        },
    })
end)
