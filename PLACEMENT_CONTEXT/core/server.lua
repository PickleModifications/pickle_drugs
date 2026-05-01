-- =============================================
--  pickle_dealerships | core/server.lua
--  Server-side initialisation, caching & utils
-- =============================================

-- ─── Dealership Cache ────────────────────────────────────────────────────────

DealershipCache = {}

-- ─── Database Initialisation ─────────────────────────────────────────────────

CreateThread(function()
    MySQL.ready(function()
        -- pickle_dealerships
        MySQL.Async.execute([[
            CREATE TABLE IF NOT EXISTS `pickle_dealerships` (
                `id`               INT UNSIGNED    NOT NULL AUTO_INCREMENT,
                `name`             VARCHAR(100)    NOT NULL,
                `location`         VARCHAR(100)    NOT NULL,
                `type`             VARCHAR(50)     NOT NULL DEFAULT 'car',
                `mode`             VARCHAR(50)     NOT NULL DEFAULT 'managed',
                `owner_identifier`  VARCHAR(50)     DEFAULT NULL,
                `tier`             INT UNSIGNED    NOT NULL DEFAULT 1,
                `balance`          BIGINT          NOT NULL DEFAULT 0,
                `reputation`       INT             NOT NULL DEFAULT 0,
                `job`              VARCHAR(50)     DEFAULT NULL,
                `seize_enabled`    TINYINT(1)      NOT NULL DEFAULT 0,
                `metadata`         JSON            DEFAULT NULL,
                `financing_settings` JSON          DEFAULT NULL,
                `created_at`       TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
                `updated_at`       TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
                PRIMARY KEY (`id`),
                KEY `idx_location` (`location`),
                KEY `idx_owner`    (`owner_identifier`),
                KEY `idx_job`      (`job`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
        ]])

        -- pickle_dealership_employees
        MySQL.Async.execute([[
            CREATE TABLE IF NOT EXISTS `pickle_dealership_employees` (
                `id`              INT UNSIGNED   NOT NULL AUTO_INCREMENT,
                `dealership_id`   INT UNSIGNED   NOT NULL,
                `identifier`       VARCHAR(50)    NOT NULL,
                `role`            VARCHAR(30)    NOT NULL DEFAULT 'salesperson',
                `commission_rate` DECIMAL(5,2)   NOT NULL DEFAULT 0.00,
                `hired_at`        TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP,
                `metadata`        JSON           DEFAULT NULL,
                PRIMARY KEY (`id`),
                KEY `idx_dealership` (`dealership_id`),
                KEY `idx_citizen`    (`identifier`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
        ]])

        -- pickle_dealership_stock
        MySQL.Async.execute([[
            CREATE TABLE IF NOT EXISTS `pickle_dealership_stock` (
                `id`              INT UNSIGNED   NOT NULL AUTO_INCREMENT,
                `dealership_id`   INT UNSIGNED   NOT NULL,
                `vehicle_model`   VARCHAR(100)   NOT NULL,
                `vehicle_label`   VARCHAR(150)   DEFAULT NULL,
                `retail_price`    BIGINT         NOT NULL DEFAULT 0,
                `wholesale_cost`  BIGINT         NOT NULL DEFAULT 0,
                `display_spot`    VARCHAR(50)    DEFAULT NULL,
                `color`           JSON           DEFAULT NULL,
                `condition`       DECIMAL(5,2)   NOT NULL DEFAULT 100.00,
                `ordered_at`      TIMESTAMP      NULL DEFAULT NULL,
                `delivered_at`    TIMESTAMP      NULL DEFAULT NULL,
                `sold_at`         TIMESTAMP      NULL DEFAULT NULL,
                `sold_to`         VARCHAR(50)    DEFAULT NULL,
                `sold_by`         VARCHAR(50)    DEFAULT NULL,
                `quantity`        INT UNSIGNED   NOT NULL DEFAULT 1,
                `is_used`         TINYINT(1)     NOT NULL DEFAULT 0,
                `unlisted`        TINYINT(1)     NOT NULL DEFAULT 0,
                `metadata`        JSON           DEFAULT NULL,
                `plate`           VARCHAR(20)    DEFAULT NULL,
                `acquired_from`   VARCHAR(50)    DEFAULT NULL,
                `auction_id`      INT            DEFAULT NULL,
                PRIMARY KEY (`id`),
                KEY `idx_dealership` (`dealership_id`),
                KEY `idx_model`      (`vehicle_model`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
        ]])

        -- pickle_dealership_orders — pending/in-transit orders (separate from available stock)
        MySQL.Async.execute([[
            CREATE TABLE IF NOT EXISTS `pickle_dealership_orders` (
                `id`              INT UNSIGNED   NOT NULL AUTO_INCREMENT,
                `dealership_id`   INT UNSIGNED   NOT NULL,
                `vehicle_model`   VARCHAR(100)   NOT NULL,
                `vehicle_label`   VARCHAR(150)   DEFAULT NULL,
                `retail_price`    BIGINT         NOT NULL DEFAULT 0,
                `wholesale_cost`  BIGINT         NOT NULL DEFAULT 0,
                `quantity`        INT UNSIGNED   NOT NULL DEFAULT 1,
                `delivery_mode`   VARCHAR(16)    NOT NULL DEFAULT 'expedited',
                `route_id`        VARCHAR(32)    DEFAULT NULL,
                `delivery_fee`    BIGINT         NOT NULL DEFAULT 0,
                `claimed_by`      VARCHAR(64)    DEFAULT NULL,
                `claimed_at`      DATETIME       DEFAULT NULL,
                `ordered_at`      TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP,
                `delivered_at`    TIMESTAMP      NULL DEFAULT NULL,
                PRIMARY KEY (`id`),
                KEY `idx_dealership` (`dealership_id`),
                KEY `idx_model`      (`vehicle_model`),
                KEY `idx_delivered`  (`delivered_at`),
                KEY `idx_orders_queue` (`delivery_mode`, `claimed_by`, `delivered_at`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
        ]])

        -- pickle_dealership_ledger
        MySQL.Async.execute([[
            CREATE TABLE IF NOT EXISTS `pickle_dealership_ledger` (
                `id`              INT UNSIGNED   NOT NULL AUTO_INCREMENT,
                `dealership_id`   INT UNSIGNED   NOT NULL,
                `type`            VARCHAR(50)    NOT NULL,
                `amount`          BIGINT         NOT NULL DEFAULT 0,
                `description`     TEXT           DEFAULT NULL,
                `identifier`       VARCHAR(50)    DEFAULT NULL,
                `created_at`      TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (`id`),
                KEY `idx_dealership` (`dealership_id`),
                KEY `idx_type`       (`type`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
        ]])

        -- pickle_dealership_financing
        MySQL.Async.execute([[
            CREATE TABLE IF NOT EXISTS `pickle_dealership_financing` (
                `id`                 INT UNSIGNED   NOT NULL AUTO_INCREMENT,
                `dealership_id`      INT UNSIGNED   NOT NULL,
                `identifier`          VARCHAR(50)    NOT NULL,
                `vehicle_plate`      VARCHAR(20)    NOT NULL,
                `total_amount`       BIGINT         NOT NULL DEFAULT 0,
                `amount_paid`        BIGINT         NOT NULL DEFAULT 0,
                `installment_amount` BIGINT         NOT NULL DEFAULT 0,
                `interest_rate`      DECIMAL(5,2)   NOT NULL DEFAULT 0.00,
                `next_payment`       TIMESTAMP      NULL DEFAULT NULL,
                `missed_payments`    INT UNSIGNED   NOT NULL DEFAULT 0,
                `status`             VARCHAR(30)    NOT NULL DEFAULT 'active',
                `created_at`         TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (`id`),
                KEY `idx_dealership` (`dealership_id`),
                KEY `idx_citizen`    (`identifier`),
                KEY `idx_plate`      (`vehicle_plate`),
                KEY `idx_status`     (`status`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
        ]])

        -- pickle_dealership_coupons
        MySQL.Async.execute([[
            CREATE TABLE IF NOT EXISTS `pickle_dealership_coupons` (
                `id`              INT UNSIGNED   NOT NULL AUTO_INCREMENT,
                `dealership_id`   INT UNSIGNED   NOT NULL,
                `code`            VARCHAR(50)    NOT NULL,
                `discount_type`   VARCHAR(30)    NOT NULL DEFAULT 'percent',
                `discount_value`  DECIMAL(12,2)  NOT NULL DEFAULT 0.00,
                `max_uses`        INT UNSIGNED   NOT NULL DEFAULT 1,
                `uses`            INT UNSIGNED   NOT NULL DEFAULT 0,
                `min_purchase`    BIGINT         NOT NULL DEFAULT 0,
                `vehicle_filter`  JSON           DEFAULT NULL,
                `expires_at`      TIMESTAMP      NULL DEFAULT NULL,
                `created_by`      VARCHAR(50)    DEFAULT NULL,
                `created_at`      TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (`id`),
                KEY `idx_dealership` (`dealership_id`),
                UNIQUE KEY `idx_code` (`dealership_id`, `code`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
        ]])

        -- pickle_dealership_deliveries
        MySQL.Async.execute([[
            CREATE TABLE IF NOT EXISTS `pickle_dealership_deliveries` (
                `id`               INT UNSIGNED   NOT NULL AUTO_INCREMENT,
                `dealership_id`    INT UNSIGNED   NOT NULL,
                `stock_ids`        JSON           DEFAULT NULL,
                `pickup_location`  VARCHAR(100)   DEFAULT NULL,
                `route`            VARCHAR(100)   DEFAULT NULL,
                `status`           VARCHAR(30)    NOT NULL DEFAULT 'pending',
                `assigned_to`      VARCHAR(50)    DEFAULT NULL,
                `started_at`       TIMESTAMP      NULL DEFAULT NULL,
                `completed_at`     TIMESTAMP      NULL DEFAULT NULL,
                `metadata`         JSON           DEFAULT NULL,
                PRIMARY KEY (`id`),
                KEY `idx_dealership` (`dealership_id`),
                KEY `idx_status`     (`status`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
        ]])

        -- Gameplay delivery system: in-game configurable pickup depots
        MySQL.Async.execute([[
            CREATE TABLE IF NOT EXISTS `pickle_delivery_depots` (
                `id`             INT UNSIGNED   NOT NULL AUTO_INCREMENT,
                `name`           VARCHAR(100)   NOT NULL,
                `x`              DOUBLE         NOT NULL,
                `y`              DOUBLE         NOT NULL,
                `z`              DOUBLE         NOT NULL,
                `heading`        DOUBLE         NOT NULL DEFAULT 0,
                `distance_band`  VARCHAR(16)    NOT NULL DEFAULT 'short',
                `dropoff_radius` DOUBLE         NOT NULL DEFAULT 25.0,
                `active`         TINYINT(1)     NOT NULL DEFAULT 1,
                `spawn_x`        DOUBLE         DEFAULT NULL,
                `spawn_y`        DOUBLE         DEFAULT NULL,
                `spawn_z`        DOUBLE         DEFAULT NULL,
                `spawn_heading`  DOUBLE         DEFAULT NULL,
                `created_at`     TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (`id`),
                KEY `idx_active_band` (`active`, `distance_band`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
        ]])

        -- Gameplay delivery system: per-player driver progression
        MySQL.Async.execute([[
            CREATE TABLE IF NOT EXISTS `pickle_dealership_driver_progression` (
                `identifier`         VARCHAR(64)   NOT NULL,
                `xp`                 INT           NOT NULL DEFAULT 0,
                `level`              INT           NOT NULL DEFAULT 1,
                `completed_count`    INT           NOT NULL DEFAULT 0,
                `failed_count`       INT           NOT NULL DEFAULT 0,
                `streak`             INT           NOT NULL DEFAULT 0,
                `lifetime_earnings`  BIGINT        NOT NULL DEFAULT 0,
                `updated_at`         DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
                PRIMARY KEY (`identifier`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
        ]])

        -- pickle_wholesale_catalog (admin-managed vehicle catalog)
        MySQL.Async.execute([[
            CREATE TABLE IF NOT EXISTS `pickle_wholesale_catalog` (
                `id`              INT UNSIGNED   NOT NULL AUTO_INCREMENT,
                `model`           VARCHAR(100)   NOT NULL,
                `label`           VARCHAR(150)   NOT NULL,
                `wholesale`       BIGINT         NOT NULL DEFAULT 0,
                `tier`            VARCHAR(30)    NOT NULL DEFAULT 'basic',
                `class`           VARCHAR(50)    NOT NULL DEFAULT 'sedan',
                `vehicle_type`    VARCHAR(30)    NOT NULL DEFAULT 'car',
                `image`           MEDIUMTEXT     DEFAULT NULL,
                `created_at`      TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (`id`),
                UNIQUE KEY `idx_model` (`model`),
                KEY `idx_type`    (`vehicle_type`),
                KEY `idx_tier`    (`tier`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
        ]])

        -- Auctions
        MySQL.Async.execute([[
            CREATE TABLE IF NOT EXISTS `pickle_dealership_auctions` (
                `id`                  INT AUTO_INCREMENT PRIMARY KEY,
                `stock_id`            INT NOT NULL,
                `dealership_id`       INT NOT NULL,
                `seller_identifier`   VARCHAR(50) DEFAULT NULL,
                `starting_bid`        BIGINT NOT NULL,
                `min_increment`       INT NOT NULL DEFAULT 100,
                `reserve_price`       BIGINT DEFAULT NULL,
                `buyout_price`        BIGINT DEFAULT NULL,
                `duration_minutes`    INT NOT NULL DEFAULT 10,
                `current_bid`         BIGINT DEFAULT NULL,
                `current_bidder`      VARCHAR(50) DEFAULT NULL,
                `current_payment_method` VARCHAR(16) DEFAULT NULL,
                `started_at`          DATETIME DEFAULT CURRENT_TIMESTAMP,
                `ends_at`             DATETIME DEFAULT NULL,
                `ended_at`            DATETIME DEFAULT NULL,
                `status`              ENUM('active','won','cancelled','no_sale') NOT NULL DEFAULT 'active',
                `winner_identifier`   VARCHAR(50) DEFAULT NULL,
                `winning_bid`         BIGINT DEFAULT NULL,
                `claimed_at`          DATETIME DEFAULT NULL,
                KEY `idx_status`  (`status`),
                KEY `idx_ends_at` (`ends_at`),
                KEY `idx_winner`  (`winner_identifier`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
        ]])

        MySQL.Async.execute([[
            CREATE TABLE IF NOT EXISTS `pickle_dealership_auction_bids` (
                `id`                  INT AUTO_INCREMENT PRIMARY KEY,
                `auction_id`          INT NOT NULL,
                `bidder_identifier`   VARCHAR(50) NOT NULL,
                `amount`              BIGINT NOT NULL,
                `payment_method`      VARCHAR(16) NOT NULL DEFAULT 'bank',
                `placed_at`           DATETIME DEFAULT CURRENT_TIMESTAMP,
                `refunded`            TINYINT(1) NOT NULL DEFAULT 0,
                KEY `idx_auction` (`auction_id`),
                KEY `idx_bidder`  (`bidder_identifier`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
        ]])

        -- Defensive migrations: older installs already have these tables without
        -- the payment-method columns we now depend on. Both servers we target
        -- (MariaDB and MySQL 8.0.29+) support ADD COLUMN IF NOT EXISTS.
        MySQL.Async.execute([[
            ALTER TABLE `pickle_dealership_auctions`
            ADD COLUMN IF NOT EXISTS `current_payment_method` VARCHAR(16) DEFAULT NULL
        ]])
        MySQL.Async.execute([[
            ALTER TABLE `pickle_dealership_auction_bids`
            ADD COLUMN IF NOT EXISTS `payment_method` VARCHAR(16) NOT NULL DEFAULT 'bank'
        ]])

        -- Catalog Groups: many-to-many replacement for the rigid tier hierarchy.
        -- A vehicle can live in any number of groups; a dealership can be assigned
        -- to any number of groups; a vehicle appears in a dealership's catalog
        -- when (vehicle.groups ∩ dealership.groups) is non-empty. The legacy
        -- `tier` columns on pickle_wholesale_catalog and pickle_dealerships are
        -- left in place (unread) so older installs can roll back cleanly.
        MySQL.Async.execute([[
            CREATE TABLE IF NOT EXISTS `pickle_catalog_groups` (
                `id`          INT UNSIGNED NOT NULL AUTO_INCREMENT,
                `name`        VARCHAR(64)  NOT NULL,
                `label`       VARCHAR(150) NOT NULL,
                `description` TEXT         DEFAULT NULL,
                `is_default`  TINYINT(1)   NOT NULL DEFAULT 0,
                `created_at`  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (`id`),
                UNIQUE KEY `idx_name` (`name`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
        ]])

        MySQL.Async.execute([[
            CREATE TABLE IF NOT EXISTS `pickle_catalog_vehicle_groups` (
                `catalog_id` INT UNSIGNED NOT NULL,
                `group_id`   INT UNSIGNED NOT NULL,
                PRIMARY KEY (`catalog_id`, `group_id`),
                KEY `idx_group` (`group_id`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
        ]])

        MySQL.Async.execute([[
            CREATE TABLE IF NOT EXISTS `pickle_dealership_groups` (
                `dealership_id` INT          NOT NULL,
                `group_id`      INT UNSIGNED NOT NULL,
                PRIMARY KEY (`dealership_id`, `group_id`),
                KEY `idx_group` (`group_id`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
        ]])

        -- Seed default wholesale catalog (INSERT IGNORE skips existing entries).
        -- oxmysql's `execute` runs exactly one statement, so we strip comments
        -- and split the file on `;` before feeding it in. The current seed
        -- only contains a CREATE TABLE and an INSERT, but splitting keeps
        -- this path working if future seed files grow additional statements.
        if Config.InstallVanillaStock then
            local seedSQL = LoadResourceFile(GetCurrentResourceName(), "vanilla_stock.sql")
            if seedSQL then
                -- Drop block and line comments so a stray "--" or "/* ; */"
                -- can't break the simple semicolon split below.
                seedSQL = seedSQL:gsub("/%*.-%*/", " ")
                seedSQL = seedSQL:gsub("%-%-[^\n]*", "")
                for stmt in seedSQL:gmatch("[^;]+") do
                    local trimmed = stmt:gsub("^%s+", ""):gsub("%s+$", "")
                    if trimmed ~= "" then
                        MySQL.Async.execute(trimmed)
                    end
                end
            end
        end

        -- One-time backfill so existing installs keep their visibility on first
        -- boot after upgrade. Each step is gated on "junction empty" so reboots
        -- and re-seeds remain idempotent.
        BackfillCatalogGroups()

        -- Load pickle_dealerships into cache after tables are ready
        LoadDealerships()
        LoadDeliveryDepots()
    end)
end)

--- Default groups seeded on first boot. Names match the previous tier strings
--- so driver-progression configs (which reference "basic"/"expanded"/"full"/
--- "exclusive" in Config.DeliveryProgression.levels[N].catalogAccess) keep
--- working without any config changes.
local DEFAULT_GROUP_NAMES = { "basic", "expanded", "full", "exclusive" }
local DEFAULT_GROUP_LABEL_KEYS = {
    basic     = "group_basic",
    expanded  = "group_expanded",
    full      = "group_full",
    exclusive = "group_exclusive",
}

--- Catalog tier strings ranked. Used solely by the one-time dealership backfill
--- to translate a legacy numeric tier into the cumulative set of group names a
--- dealership used to have access to (tier 4 → all four groups, tier 1 → basic).
local TIER_RANK = { basic = 1, expanded = 2, full = 3, exclusive = 4 }

function BackfillCatalogGroups()
    -- 1. Seed default groups if the table is empty.
    local groupCount = MySQL.scalar.await("SELECT COUNT(*) FROM `pickle_catalog_groups`") or 0
    if tonumber(groupCount) == 0 then
        for _, name in ipairs(DEFAULT_GROUP_NAMES) do
            local label = (_L and _L(DEFAULT_GROUP_LABEL_KEYS[name])) or name
            MySQL.insert.await(
                "INSERT INTO `pickle_catalog_groups` (`name`, `label`, `is_default`) VALUES (?, ?, 1)",
                { name, label }
            )
        end
    end

    -- 2. Backfill catalog→group junction from the legacy tier column.
    local vgCount = MySQL.scalar.await("SELECT COUNT(*) FROM `pickle_catalog_vehicle_groups`") or 0
    if tonumber(vgCount) == 0 then
        local groups = MySQL.query.await("SELECT `id`, `name` FROM `pickle_catalog_groups`") or {}
        local groupIdByName = {}
        for _, g in ipairs(groups) do groupIdByName[g.name] = g.id end

        local catalogRows = MySQL.query.await("SELECT `id`, `tier` FROM `pickle_wholesale_catalog`") or {}
        for _, row in ipairs(catalogRows) do
            local gid = row.tier and groupIdByName[row.tier]
            if gid then
                MySQL.insert.await(
                    "INSERT IGNORE INTO `pickle_catalog_vehicle_groups` (`catalog_id`, `group_id`) VALUES (?, ?)",
                    { row.id, gid }
                )
            end
        end
    end

    -- 3. Backfill dealership→group junction from the legacy tier column,
    --    expanding the cumulative hierarchy (tier N → all groups up to N).
    --    Done PER-DEALERSHIP so a freshly-created dealership (which adds rows
    --    to the junction before backfill runs at next boot) doesn't prevent
    --    the rest of the dealerships from getting backfilled. Any dealership
    --    that already has at least one group assignment is skipped.
    local groups = MySQL.query.await("SELECT `id`, `name` FROM `pickle_catalog_groups`") or {}
    local groupIdByName = {}
    for _, g in ipairs(groups) do groupIdByName[g.name] = g.id end

    local dealerships = MySQL.query.await([[
        SELECT d.`id`, d.`tier`
        FROM `pickle_dealerships` d
        WHERE NOT EXISTS (
            SELECT 1 FROM `pickle_dealership_groups` dg
            WHERE dg.`dealership_id` = d.`id`
        )
    ]]) or {}
    for _, d in ipairs(dealerships) do
        local tierIdx = tonumber(d.tier) or 1
        local tierCfg = Config.Tiers and Config.Tiers[tierIdx]
        local accessName = tierCfg and tierCfg.catalogAccess or "basic"
        local maxRank = TIER_RANK[accessName] or 1
        for _, name in ipairs(DEFAULT_GROUP_NAMES) do
            if (TIER_RANK[name] or 0) <= maxRank then
                local gid = groupIdByName[name]
                if gid then
                    MySQL.insert.await(
                        "INSERT IGNORE INTO `pickle_dealership_groups` (`dealership_id`, `group_id`) VALUES (?, ?)",
                        { d.id, gid }
                    )
                end
            end
        end
    end
end

-- ─── Delivery Depot Cache ────────────────────────────────────────────────────

DeliveryDepotCache = {}

local function rowToDepot(row)
    -- NOTE: coord tables are plain Lua (not vector4) so they JSON-serialise cleanly to the NUI.
    -- Mission code reads .x/.y/.z/.w so the shape is interchangeable with vector4 at call sites.
    -- `pickupCoords` is where the dispatch ped stands and where drivers interact to start a mission.
    -- `spawnCoords` is where the truck + trailer rig actually spawns; falls back to pickup if unset
    -- so existing depots keep working without reconfiguration.
    local hasSpawn = row.spawn_x and row.spawn_y and row.spawn_z
    return {
        id = row.id,
        name = row.name,
        label = row.name,
        pickupCoords = { x = row.x, y = row.y, z = row.z, w = row.heading or 0.0 },
        spawnCoords = hasSpawn
            and { x = row.spawn_x, y = row.spawn_y, z = row.spawn_z, w = row.spawn_heading or 0.0 }
            or nil,
        active = row.active == 1 or row.active == true,
    }
end

function LoadDeliveryDepots()
    local rows = MySQL.query.await("SELECT * FROM `pickle_delivery_depots` WHERE `active` = 1 ORDER BY `id` ASC") or {}

    DeliveryDepotCache = {}
    for _, row in ipairs(rows) do
        DeliveryDepotCache[row.id] = rowToDepot(row)
    end
    debugPrint(("[pickle_dealerships] Loaded %d delivery depot(s) into cache."):format(#rows))
end

function GetDeliveryDepots()
    local out = {}
    for _, d in pairs(DeliveryDepotCache) do out[#out + 1] = d end
    return out
end

function CreateDeliveryDepot(name, x, y, z, heading)
    if not name or not x or not y or not z then return nil, 'Invalid arguments.' end
    local id = MySQL.insert.await(
        "INSERT INTO `pickle_delivery_depots` (`name`, `x`, `y`, `z`, `heading`) VALUES (?, ?, ?, ?, ?)",
        { name, x, y, z, heading or 0.0 }
    )
    if id then
        DeliveryDepotCache[id] = {
            id = id, name = name, label = name,
            pickupCoords = { x = x, y = y, z = z, w = heading or 0.0 },
            spawnCoords = nil, -- set later via SetDeliveryDepotSpawn; falls back to pickup until then
            active = true,
        }
    end
    return id
end

--- Moves the dispatch ped (pickup) coords for an existing depot.
function SetDeliveryDepotPickup(id, x, y, z, heading)
    id = tonumber(id)
    if not id or not DeliveryDepotCache[id] then return false end
    if not x or not y or not z then return false end
    MySQL.update.await(
        "UPDATE `pickle_delivery_depots` SET `x` = ?, `y` = ?, `z` = ?, `heading` = ? WHERE `id` = ?",
        { x, y, z, heading or 0.0, id }
    )
    DeliveryDepotCache[id].pickupCoords = { x = x, y = y, z = z, w = heading or 0.0 }
    return true
end

--- Sets (or clears, if all coords are nil) the separate truck-spawn point for a depot.
function SetDeliveryDepotSpawn(id, x, y, z, heading)
    id = tonumber(id)
    if not id or not DeliveryDepotCache[id] then return false end
    if x == nil or y == nil or z == nil then
        MySQL.update.await(
            "UPDATE `pickle_delivery_depots` SET `spawn_x` = NULL, `spawn_y` = NULL, `spawn_z` = NULL, `spawn_heading` = NULL WHERE `id` = ?",
            { id }
        )
        DeliveryDepotCache[id].spawnCoords = nil
    else
        MySQL.update.await(
            "UPDATE `pickle_delivery_depots` SET `spawn_x` = ?, `spawn_y` = ?, `spawn_z` = ?, `spawn_heading` = ? WHERE `id` = ?",
            { x, y, z, heading or 0.0, id }
        )
        DeliveryDepotCache[id].spawnCoords = { x = x, y = y, z = z, w = heading or 0.0 }
    end
    return true
end

function UpdateDeliveryDepot(id, fields)
    id = tonumber(id)
    if not id or not DeliveryDepotCache[id] then return false end
    local allowed = { name = true, active = true }
    local sets, params = {}, {}
    for k, v in pairs(fields or {}) do
        if allowed[k] then
            sets[#sets + 1] = ("`%s` = ?"):format(k)
            params[#params + 1] = v
        end
    end
    if #sets == 0 then return false end
    params[#params + 1] = id
    MySQL.update.await(("UPDATE `pickle_delivery_depots` SET %s WHERE `id` = ?"):format(table.concat(sets, ", ")), params)
    LoadDeliveryDepots()
    return true
end

function DeleteDeliveryDepot(id)
    id = tonumber(id)
    if not id then return false end
    MySQL.update.await("UPDATE `pickle_delivery_depots` SET `active` = 0 WHERE `id` = ?", { id })
    DeliveryDepotCache[id] = nil
    return true
end

-- ─── Player Identifier Utilities ─────────────────────────────────────────────

function GetPlayerIdentifiersArray(source)
    local source = tonumber(source)
    if not source then return {} end
    local identifierTypes = {"steam", "discord", "xbl", "live", "license", "license2", "fivem", "ip"}
    local identifiers = {}
    for i = 1, #identifierTypes do
        local identifier = GetPlayerIdentifierByType(source, identifierTypes[i])
        if identifier then
            table.insert(identifiers, identifier)
        end
    end
    return identifiers
end

function GetFilteredPlayerIdentifiers(source)
    local source = tonumber(source)
    if not source then return end
    local identifiers = GetPlayerIdentifiersArray(source)
    local filteredIdentifiers = {}
    for i = 1, #identifiers do
        if not string.match(identifiers[i], "ip:") or not Config.DisableIPIdentifier then
            table.insert(filteredIdentifiers, identifiers[i])
        end
    end
    return filteredIdentifiers
end

function GetPlayerPrefixIdentifier(source)
    local source = tonumber(source)
    if not source then return end
    local prefix = Config.IdentifierPrefix
    local identifiers = GetPlayerIdentifiersArray(source)
    for i = 1, #identifiers do
        if string.match(identifiers[i], prefix .. ":") then
            return identifiers[i]
        end
    end
    if prefix == "license2" then
        for i = 1, #identifiers do
            if string.match(identifiers[i], "license:") then
                return identifiers[i]
            end
        end
    end
end

-- ─── Dealership Cache Functions ──────────────────────────────────────────────

function LoadDealerships()
    local rows = MySQL.query.await("SELECT * FROM `pickle_dealerships`")
    if not rows then return end

    DealershipCache = {}
    for i = 1, #rows do
        local row = rows[i]
        if row.metadata and type(row.metadata) == "string" then
            row.metadata = json.decode(row.metadata) or {}
        end
        DealershipCache[row.id] = row
    end

    debugPrint(("[pickle_dealerships] Loaded %d dealership(s) into cache."):format(#rows))
end

function GetDealership(id)
    if not id then return nil end
    return DealershipCache[tonumber(id)]
end

--- How many catalog entries this dealership could theoretically sell if every
--- tier were unlocked. Used as the denominator on the dashboard stock bar so
--- owners see "models for sale / models the store could ever carry" instead of
--- an arbitrary per-tier cap.
function GetDealershipCatalogMax(dealership)
    local vehicleType = dealership and dealership.type or 'car'
    local types = vehicleType == 'mixed' and { 'car', 'boat', 'air' } or { vehicleType }
    local placeholders = {}
    for i = 1, #types do placeholders[i] = '?' end
    local count = MySQL.scalar.await(
        ('SELECT COUNT(*) FROM pickle_wholesale_catalog WHERE vehicle_type IN (%s)'):format(table.concat(placeholders, ',')),
        types
    ) or 0
    return tonumber(count) or 0
end

--- Returns the dealership's progression state from metadata.xp and the
--- configured level thresholds. Always returns something usable even when
--- progression is disabled (so callers don't have to handle nils).
function GetDealershipProgression(dealership)
    local cfg = Config.DealershipProgression or {}
    local levels = cfg.levels or {}
    local meta = dealership and dealership.metadata
    if type(meta) == "string" then meta = json.decode(meta) or {} end
    local xp = (type(meta) == "table" and tonumber(meta.xp)) or 0

    -- Resolve current level by walking thresholds in ascending order. The dealership's
    -- stored tier can override upward (manual admin bumps), but never downward.
    local resolved = 1
    local highest = 1
    for lvl, def in pairs(levels) do
        lvl = tonumber(lvl)
        if lvl then
            if xp >= (def.xpRequired or 0) and lvl > resolved then resolved = lvl end
            if lvl > highest then highest = lvl end
        end
    end
    if dealership and dealership.tier and dealership.tier > resolved then
        resolved = dealership.tier
    end

    local nextLevel = resolved + 1
    local nextDef = levels[nextLevel]
    local currentDef = levels[resolved] or { label = ("Level " .. tostring(resolved)), xpRequired = 0 }

    return {
        level = resolved,
        label = currentDef.label,
        xp = xp,
        currentLevelXp = currentDef.xpRequired or 0,
        nextLevelXp = nextDef and nextDef.xpRequired or nil,
        isMaxLevel = resolved >= highest,
        enabled = cfg.enabled ~= false,
    }
end

--- Adds XP to a dealership and, if thresholds are crossed, bumps its tier.
--- No-op when progression is disabled. Returns the new progression snapshot.
function AwardDealershipXP(dealershipId, amount)
    local cfg = Config.DealershipProgression or {}
    if cfg.enabled == false then return nil end
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 then return nil end

    local dealership = GetDealership(dealershipId)
    if not dealership then return nil end

    local meta = dealership.metadata
    if type(meta) == "string" then meta = json.decode(meta) or {} end
    if type(meta) ~= "table" then meta = {} end

    meta.xp = (tonumber(meta.xp) or 0) + amount

    -- Auto-tier: compute the highest level whose xpRequired is met.
    local levels = cfg.levels or {}
    local newTier = dealership.tier or 1
    for lvl, def in pairs(levels) do
        lvl = tonumber(lvl)
        if lvl and meta.xp >= (def.xpRequired or 0) and lvl > newTier then
            newTier = lvl
        end
    end

    MySQL.update.await(
        "UPDATE pickle_dealerships SET tier = ?, metadata = ? WHERE id = ?",
        { newTier, json.encode(meta), dealershipId }
    )
    UpdateDealershipCache(dealershipId, { tier = newTier, metadata = meta })

    if newTier > (dealership.tier or 1) then
        TriggerClientEvent('pickle_dealerships:dealershipLevelUp', -1, dealershipId, newTier)
    end

    return GetDealershipProgression(GetDealership(dealershipId))
end

--- Returns the dealership's faction as { name = string|nil, type = 'job'|'gang' }.
--- `dealership.job` holds the faction name (legacy column name kept for back-compat);
--- the type lives in metadata.factionType and defaults to 'job'.
--- Returns the admin-configured access gate for a dealership:
---   mode = 'public' | 'faction'
---   minGrade = number (faction mode only)
function GetDealershipAccess(dealership)
    if not dealership then return { mode = 'public', minGrade = 0 } end
    local meta = dealership.metadata
    if type(meta) == "string" then meta = json.decode(meta) or {} end
    if type(meta) ~= "table" then return { mode = 'public', minGrade = 0 } end
    local mode = meta.accessMode
    if mode ~= "faction" then mode = "public" end
    return { mode = mode, minGrade = tonumber(meta.accessMinGrade) or 0 }
end

--- Checks whether a player may view/purchase at this dealership. Owners,
--- hired employees (DB row), and admins bypass the access gate — this
--- prevents locking out the people who run the lot.
function PlayerCanAccessDealership(source, dealership)
    if not dealership then return false end
    if IsPlayerAdmin and IsPlayerAdmin(source) then return true end

    local identifier = GetIdentifier and GetIdentifier(source) or nil
    if identifier and dealership.owner_identifier == identifier then return true end

    local access = GetDealershipAccess(dealership)
    if access.mode == "public" then return true end

    local faction = GetDealershipFaction(dealership)
    if not faction.name or faction.name == "" then
        -- Faction mode but no faction configured — treat as public to avoid
        -- accidentally locking everyone out. Admin must set the faction.
        return true
    end

    if faction.type == "gang" then
        local name = GetPlayerGangName and GetPlayerGangName(source) or nil
        if name ~= faction.name then return false end
        return (GetPlayerGangGrade and GetPlayerGangGrade(source) or 0) >= access.minGrade
    end
    local name = GetPlayerJobName and GetPlayerJobName(source) or nil
    if name ~= faction.name then return false end
    return (GetPlayerJobGrade and GetPlayerJobGrade(source) or 0) >= access.minGrade
end

function GetDealershipFaction(dealership)
    if not dealership then return { name = nil, type = 'job' } end
    local meta = dealership.metadata
    if type(meta) == "string" then meta = json.decode(meta) or {} end
    local factionType = (type(meta) == "table" and meta.factionType) or 'job'
    if factionType ~= 'job' and factionType ~= 'gang' then factionType = 'job' end
    local name = dealership.job
    if name == "" then name = nil end
    return { name = name, type = factionType }
end

function GetDealershipByLocation(location)
    if not location then return nil end
    for _, dealership in pairs(DealershipCache) do
        if dealership.location == location then
            return dealership
        end
    end
    return nil
end

function UpdateDealershipCache(id, data)
    id = tonumber(id)
    if not id or not data then return end
    if DealershipCache[id] then
        for k, v in pairs(data) do
            DealershipCache[id][k] = v
        end
    else
        DealershipCache[id] = data
    end
end

function AddLedgerEntry(dealershipId, type, amount, description, identifier)
    if not dealershipId or not type or not amount then return end
    MySQL.insert(
        "INSERT INTO `pickle_dealership_ledger` (`dealership_id`, `type`, `amount`, `description`, `identifier`) VALUES (?, ?, ?, ?, ?)",
        { tonumber(dealershipId), type, tonumber(amount), description or "", identifier }
    )
end

-- ─── Permission Checking ─────────────────────────────────────────────────────

function GetPlayerDealershipRole(source, dealershipId)
    local source = tonumber(source)
    dealershipId = tonumber(dealershipId)
    if not source or not dealershipId then return nil end

    -- Check if the player is the owner
    local dealership = GetDealership(dealershipId)
    if not dealership then return nil end

    local identifier = GetIdentifier(source)
    if not identifier then return nil end

    -- Owner check via dealership table
    if dealership.owner_identifier == identifier then
        return "owner"
    end

    -- Employee check via pickle_dealership_employees table
    local rows = MySQL.query.await(
        "SELECT `role` FROM `pickle_dealership_employees` WHERE `dealership_id` = ? AND `identifier` = ? LIMIT 1",
        { dealershipId, identifier }
    )

    if rows and rows[1] then
        return rows[1].role
    end

    return nil
end

function CanPlayerManage(source, dealershipId)
    -- Management rights are strictly limited to the dealership owner and server
    -- admins. Managers are still employees — they can sell via the sales tablet
    -- but cannot touch funds, stock ordering, hires, commissions, etc.
    if IsPlayerAdmin(source) then return true end
    local role = GetPlayerDealershipRole(source, dealershipId)
    return role == "owner"
end

function CanPlayerSell(source, dealershipId)
    if IsPlayerAdmin(source) then return true end
    local role = GetPlayerDealershipRole(source, dealershipId)
    return role == "owner" or role == "manager" or role == "salesperson"
end

--- Centralised "access denied" notifier. Any server-side permission gate
--- that ends in a silent return (e.g. `return nil` from a read callback)
--- should call this first so the player isn't left staring at a stalled
--- UI. `reason` is a locale key; falls back to the generic no_permission
--- string. Safe to call with source == 0 (console) — ShowNotification
--- is a no-op there.
function DenyAccess(source, reason)
    if not source or source == 0 then return end
    local key = reason or "no_permission"
    local msg = _L and _L(key) or key
    ShowNotification(source, msg)
end

-- ─── Driver Progression ──────────────────────────────────────────────────────

local function ResolveDriverLevel(xp)
    local levels = Config.DeliveryProgression and Config.DeliveryProgression.levels
    if not levels then return 1 end
    local resolved = 1
    for lvl, def in pairs(levels) do
        if xp >= (def.xpRequired or 0) and lvl > resolved then
            resolved = lvl
        end
    end
    return resolved
end

local function ResolveNextThreshold(level)
    local levels = Config.DeliveryProgression and Config.DeliveryProgression.levels
    if not levels then return nil end
    local next = levels[level + 1]
    return next and next.xpRequired or nil
end

function GetDriverProgression(identifier)
    if not identifier then return nil end
    local row = MySQL.single.await(
        "SELECT * FROM `pickle_dealership_driver_progression` WHERE `identifier` = ?",
        { identifier }
    )
    if not row then
        MySQL.insert.await(
            "INSERT INTO `pickle_dealership_driver_progression` (`identifier`) VALUES (?)",
            { identifier }
        )
        row = { identifier = identifier, xp = 0, level = 1, completed_count = 0, failed_count = 0, streak = 0, lifetime_earnings = 0 }
    end
    row.level = ResolveDriverLevel(row.xp or 0)
    row.xp_to_next = ResolveNextThreshold(row.level)
    return row
end

function AddDriverXP(identifier, xp)
    if not identifier or not xp or xp == 0 then return nil end
    local current = GetDriverProgression(identifier)
    if not current then return nil end
    local oldLevel = current.level or 1
    local newXP = math.max(0, (current.xp or 0) + xp)
    local newLevel = ResolveDriverLevel(newXP)
    MySQL.update.await(
        "UPDATE `pickle_dealership_driver_progression` SET `xp` = ?, `level` = ? WHERE `identifier` = ?",
        { newXP, newLevel, identifier }
    )
    return { xp = newXP, level = newLevel, leveledUp = newLevel > oldLevel, oldLevel = oldLevel }
end

function RecordDriverDelivery(identifier, earnings, success)
    if not identifier then return end
    if success then
        MySQL.update.await(
            "UPDATE `pickle_dealership_driver_progression` SET `completed_count` = `completed_count` + 1, `streak` = `streak` + 1, `lifetime_earnings` = `lifetime_earnings` + ? WHERE `identifier` = ?",
            { math.max(0, tonumber(earnings) or 0), identifier }
        )
    else
        MySQL.update.await(
            "UPDATE `pickle_dealership_driver_progression` SET `failed_count` = `failed_count` + 1, `streak` = 0 WHERE `identifier` = ?",
            { identifier }
        )
    end
end

function CanDriverAccessTier(identifier, catalogTier)
    if not catalogTier then return true end
    local levels = Config.DeliveryProgression and Config.DeliveryProgression.levels
    if not levels then return true end
    local prog = GetDriverProgression(identifier)
    if not prog then return false end
    local def = levels[prog.level or 1]
    if not def or not def.catalogAccess then return false end
    return def.catalogAccess[catalogTier] == true
end

function GetDriverStreakMultiplier(identifier)
    local cfg = Config.Delivery and Config.Delivery.streak
    if not cfg or not cfg.enabled then return 1.0 end
    local prog = GetDriverProgression(identifier)
    if not prog then return 1.0 end
    local streak = prog.streak or 0
    local bonus = (cfg.perStreakBonusPct or 0) * streak
    local cap = (cfg.maxMultiplier or 1.0) - 1.0
    return 1.0 + math.min(bonus, cap)
end

-- ─── Discord Logging ───────────────────────────────────────────────────────
-- Server-only. URLs live in ServerConfig.Webhooks (config_sv.lua) and are never
-- exposed to clients. All callers must pass at least a category and title; the
-- helper auto-enriches the embed with actor metadata (player name, identifier,
-- source, timestamp) when an actor source is provided.

local webhookColors = {
    sales     = 3066993,  -- green
    stock     = 3447003,  -- blue
    admin     = 15105570, -- orange
    finances  = 15844367, -- gold
    employees = 10181046, -- purple
    financing = 15158332, -- red-orange
    security  = 15158332, -- red
}

--- Send a structured log entry to the Discord webhook mapped to `category`.
---@param category string  One of 'sales' | 'stock' | 'admin' | 'finances' | 'employees' | 'financing' | 'security'
---@param opts table       { title, description, actor (source|number|nil), fields = { { name, value, inline? }, ... }, dealershipId? }
function LogDiscord(category, opts)
    local cfg = ServerConfig and ServerConfig.Webhooks
    if not cfg or not cfg.enabled then return end

    local url = (cfg.urls and cfg.urls[category]) or cfg.fallback
    if not url or url == "" then return end

    opts = opts or {}
    local fields = {}
    -- Copy caller-provided fields first so they render above the auto-enrichment.
    if type(opts.fields) == "table" then
        for _, f in ipairs(opts.fields) do
            fields[#fields + 1] = { name = tostring(f.name or "?"), value = tostring(f.value or "-"), inline = f.inline ~= false }
        end
    end

    -- Auto-enrich with actor metadata. Pass opts.actor = source (number) to
    -- attach the triggering player's name/identifier/source.
    local actorSrc = tonumber(opts.actor)
    if actorSrc then
        local name = GetPlayerCharacterName and GetPlayerCharacterName(actorSrc) or GetPlayerName(actorSrc) or "Unknown"
        local identifier = GetIdentifier and GetIdentifier(actorSrc) or "?"
        fields[#fields + 1] = { name = "Player", value = tostring(name), inline = true }
        fields[#fields + 1] = { name = "Identifier", value = "`" .. tostring(identifier) .. "`", inline = true }
        fields[#fields + 1] = { name = "Source", value = tostring(actorSrc), inline = true }
    end

    if opts.dealershipId then
        fields[#fields + 1] = { name = "Dealership", value = "#" .. tostring(opts.dealershipId), inline = true }
    end

    local embed = {
        title = tostring(opts.title or category),
        description = opts.description and tostring(opts.description) or nil,
        color = webhookColors[category] or 7506394,
        fields = fields,
        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        footer = { text = "pickle_dealerships" },
    }

    local payload = {
        username = cfg.botName or "Pickle Dealerships",
        avatar_url = cfg.avatar and cfg.avatar ~= "" and cfg.avatar or nil,
        embeds = { embed },
    }

    PerformHttpRequest(url, function() end, "POST", json.encode(payload), {
        ["Content-Type"] = "application/json",
    })
end
