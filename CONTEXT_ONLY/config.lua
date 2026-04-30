Config = {}
Config.Language = "en"
Config.Debug = false
Config.RenderDistance = 100.0
Config.InteractDistance = 2.0
Config.UseTarget = true
Config.Currency = { currency = "USD", countryCode = "en-US" }
Config.ImageDirectory = "nui://ox_inventory/web/images/"
Config.ImageExtension = "png"

-- Vehicle-image provider.
-- Controls where the NUI fetches per-model vehicle photos from when the
-- catalog row has no admin-uploaded image. Supported providers:
--   "default"     — packaged vehicle_images/ folder shipped with this resource
--   "uz-autoshot" — exports['uz-autoshot']:getVehiclePhotoURL(model)
--                   (https://uz-scripts.com/docs/free/uz-autoshot/exports)
-- Admin-uploaded images (set via the Catalog page) always win over the
-- provider URL, so you can still override individual vehicles.
Config.VehicleImages = {
    provider = "default",
}
Config.InstallVanillaStock = true
Config.AdminCommand = "dealerships" -- Command to open the admin panel

-- Generated license-plate format for new vehicles sold by dealerships.
-- Pattern characters:
--   A = random uppercase letter (A–Z)
--   1 = random digit (0–9)
--   ?  = random letter OR digit
--   anything else = literal (e.g. space, dash, leading prefix)
-- Examples:
--   "AAAA1111"  → ABCD1234  (default, 8-char, matches stock QB/CD Garage)
--   "AAA 111"   → ABC 123   (7-char with middle space)
--   "11AAA111"  → 12ABC345
--   "MYSERV-11" → MYSERV-47 (literal prefix + 2 digits)
-- Garages commonly normalise stored plates to 8 characters and strip
-- whitespace, so a non-8-char or space-containing format may fight your
-- garage system's expectations.
Config.PlateFormat = "AAAA1111"

-- UI Settings
Config.UI = {
    accentColor = "FF1CA717", -- Hex color for accent/primary UI elements
}
Config.IdentifierPrefix = "license2"

Config.AdminGroups = {
    "qbcore.admin",
    "qbcore.god",
    "god",
    "admin",
    "mod",
    "superadmin",
}

Config.TargetIcons = {
    dealership = "fas fa-car",
    management = "fas fa-briefcase",
    sales = "fas fa-handshake",
    employee = "fas fa-id-badge",
    npc_customer = "fas fa-user",
    kiosk = "fas fa-tablet-alt",
}

-- Dealership progression. Each sale awards XP to the dealership; crossing the
-- xpRequired threshold of the next level automatically bumps `tier`, which the
-- catalog access logic already uses to gate higher-wholesale vehicles.
-- Set `enabled = false` to freeze tier at whatever admins set manually.
Config.DealershipProgression = {
    enabled              = true,
    xpPerSale            = 10,      -- flat XP per vehicle sold
    xpPerSaleRevenueRate = 0.001,   -- bonus XP = retail_price * this (so bigger sales matter more)
    xpPerNpcSale         = 5,       -- NPC customer sales give less than real-player sales
    levels = {
        [1] = { xpRequired = 0,     label = "Starter Lot" },
        [2] = { xpRequired = 500,   label = "Established" },
        [3] = { xpRequired = 2500,  label = "Premium" },
        [4] = { xpRequired = 10000, label = "Enterprise" },
    },
}

-- Alternative payment methods (beyond cash/bank). Dealership owners pick which
-- of these are accepted at their lot. Each entry registers through the
-- alt_currencies bridge (bridge/alt_currencies/registry/server.lua).
--
-- Entry shape:
--   enabled       — master toggle for the server
--   label         — display name in the UI
--   type          — 'pickle_store' | 'item' | 'custom'
--   valuePerUnit  — how many $ one native unit is worth (e.g. 1 coin = $1, 1 item = $1000)
--   item          — inventory item name (type = 'item' only)
Config.AltCurrencies = {
    pickle_store = {
        enabled      = true,
        label        = "Store Coins",
        type         = "pickle_store",
        valuePerUnit = 1000,
        -- Optional: show an icon next to the amount instead of a "$". Use a
        -- server-reachable URL (NUI can fetch cross-origin images).
        iconUrl      = "nui://pickle_store/nui/images/diamonds.png",
        -- How the amount is spoken in the UI. "%s" is substituted with the
        -- numeric native amount. Leave both unset to fall back to `label`.
        singular     = "%s coin",
        plural       = "%s coins",
    },
    -- Example item currency — duplicate and adjust per server.
    -- crypto = {
    --     enabled      = true,
    --     label        = "Cryptocoin",
    --     type         = "item",
    --     item         = "cryptostick",
    --     valuePerUnit = 1000,
    --     iconUrl      = "https://example.com/crypto.png",
    --     singular     = "%s crypto",
    --     plural       = "%s crypto",
    -- },
}

Config.FrameworkSettings = {
    dirtyMoney = "DEFAULT",
    society = "qb-management",
    usableItemMetadata = function(item, data)
        if type(data) == "table" and data.metadata then return data.metadata end
        if type(item) == "table" and item.metadata then return item.metadata end
        if type(data) == "table" and data.info then return data.info end
        if type(item) == "table" and item.info then return item.info end
    end
}

-- Economy Settings
Config.ImportTax = 0.10
Config.SalesTax = 0.05
Config.DefaultCommission = 0.08
Config.SellbackRate = 0.60

-- Delivery Settings
Config.DeliveryTime = 1 -- Minutes per vehicle for expedited (timed) delivery mode

-- Gameplay delivery system
Config.Delivery = {
    expeditedFeePct = 0.05,              -- surcharge on wholesale for Expedited mode — makes local strictly cheaper
    payoutPct = 0.05,                    -- driver earns this % of retail (paid from within the dealership's wholesale+tax total, not on top)
    failRefundRate = 0.5,                -- % of wholesale returned to the dealership on failed delivery
    xpPerDelivery = 25,                  -- base XP per successful local delivery
    xpTierMultiplier = {                 -- scales XP by catalog tier of the delivered vehicle
        basic = 1.0, expanded = 1.5, full = 2.0, exclusive = 3.0,
    },
    failXpPenalty = 0.5,                 -- multiplier applied to would-be XP on fail (also resets streak)
    streak = {
        enabled = true,
        perStreakBonusPct = 0.05,        -- +5% payout per consecutive success
        maxMultiplier = 1.25,            -- cap at +25%
    },
    damagePenalty = {
        enabled = true,
        fullPayoutAboveCondition = 90,   -- 100% payout when vehicle arrives at >=90% condition
        zeroPayoutBelowCondition = 25,   -- total forfeit below this (order still consumed)
    },
    maxActiveQueuePerDealership = 10,    -- cap on unclaimed local offers per dealership
    dealershipRepBonus = 1,              -- +rep granted to destination dealership on successful local delivery
}

Config.DeliveryProgression = {
    levels = {
        [1] = { label = "Rookie",  xpRequired = 0,    catalogAccess = { basic = true } },
        [2] = { label = "Courier", xpRequired = 500,  catalogAccess = { basic = true, expanded = true } },
        [3] = { label = "Hauler",  xpRequired = 2000, catalogAccess = { basic = true, expanded = true, full = true } },
        [4] = { label = "Elite",   xpRequired = 5000, catalogAccess = { basic = true, expanded = true, full = true, exclusive = true } },
    },
}

-- Trailer setup for local deliveries. Controls which trailer model gets spawned per delivery type,
-- which catalog classes map to which "size" bucket, per-trailer capacity, slot fill order, and the
-- attach offsets for each slot on the tr2 flatbed.
--
-- Want to move or add slots? Run `/debug_trailer` in-game, drive the test car to each spot, capture
-- with `/debug_trailer capture <N>`, then `/debug_trailer print` — paste the printed block into
-- `tr2Slots` below.
Config.Trailer = {
    -- Trailer + towing models used for each delivery type.
    models = {
        truck    = 'phantom',   -- tractor that gets spawned hitched to the trailer at depot pickup
        tr2      = 'tr2',       -- open double-decker car hauler for small/medium vehicles + bikes
        enclosed = 'trailers',  -- sealed cargo trailer for anything that won't fit on tr2
    },

    -- NPC model at each depot — the ped the driver talks to in order to start a delivery.
    depotPedModel = 's_m_y_dockwork_01',
    depotInteractLabel = 'Start Delivery',
    depotInteractIcon  = 'fas fa-truck',

    -- Map blip shown at every active depot. The depot's name (from the pickle_delivery_depots DB row)
    -- is used as the label. See https://docs.fivem.net/docs/game-references/blips/ for sprite/colour IDs.
    depotBlip = {
        enabled    = true,
        sprite     = 477,   -- "Delivery" car-hauler icon
        color      = 5,     -- yellow
        scale      = 0.8,
        shortRange = true,  -- only visible when player is nearby (set false for always-on)
    },

    -- Catalog class → size bucket. Case-insensitive lookup via string.lower on the catalog's `class` column.
    -- Mediums cap at 4 per trailer and never sit at adjacent slot indexes.
    -- Smalls/bikes have no index-adjacency rule and fill the gap slots between mediums first.
    -- Any class NOT listed here routes to the enclosed trailer (no visual attach).
    classes = {
        medium = { sedan = true, muscle = true, super = true, ['sports classic'] = true, sports_classic = true, sportsclassic = true, classic = true },
        small  = { compact = true, coupe = true, sports = true },
        bike   = { motorcycle = true, motorcycles = true, cycle = true, cycles = true },
    },

    -- `total` is max vehicles per trailer; `medium` is the subset cap on medium-class vehicles.
    capacity = {
        tr2      = { total = 6, medium = 4 },
        enclosed = { total = 4, medium = 4 },
    },

    -- Slot indexes in the order they should be filled.
    -- Medium order picks corners of each deck so two mediums never sit at adjacent indexes.
    -- Small/bike order picks the centerline "gap" slots first so they tuck between mediums.
    slotOrder = {
        medium = { 1, 3, 4, 6 },
        small  = { 2, 5, 1, 3, 4, 6 },
    },

    -- Per-slot attach offsets for the tr2 trailer (relative to trailer entity root, bone 0).
    --   +Y = toward the rear ramp, -Y = toward the hitch
    --   Lower deck surface ~z=0.75-1.00, upper deck ~z=2.70-2.95
    --   rotX = pitch (nose up/down), rotY = roll (bank), rotZ = yaw (heading) — all in degrees
    tr2Slots = {
        { x =  0.03, y =  4.97, z = 0.94, rotX =  0.10, rotY = -0.02, rotZ =  0.14 }, -- 1: lower-rear   (ramp-side endpoint)
        { x =  0.03, y =  0.06, z = 1.10, rotX = -3.34, rotY = -0.41, rotZ =  0.05 }, -- 2: lower-middle (centerline gap)
        { x =  0.02, y = -4.77, z = 1.05, rotX =  4.65, rotY =  0.01, rotZ = -0.17 }, -- 3: lower-front  (hitch-side endpoint)
        { x = -0.07, y =  4.91, z = 2.91, rotX =  3.26, rotY =  0.01, rotZ = -0.17 }, -- 4: upper-rear
        { x = -0.04, y =  0.05, z = 2.94, rotX = -3.49, rotY = -0.19, rotZ = -0.11 }, -- 5: upper-middle (centerline gap)
        { x = -0.00, y = -4.80, z = 3.04, rotX =  1.36, rotY = -0.11, rotZ =  0.26 }, -- 6: upper-front
    },
}

-- Vehicle Keys Integration
-- Fires when a player obtains a vehicle (purchase, financing, auction claim,
-- employee-facilitated sale, test drive, delivery truck). Each entry is
-- dispatched with the vehicle plate as its single argument.
--
--   scope = 'client'  → TriggerEvent(name, plate)
--   scope = 'server'  → TriggerServerEvent(name, plate)
--
-- Safe to list multiple systems side-by-side; the one that's actually running
-- picks it up and the rest no-op. For anything the defaults don't cover, set
-- `customHandler = function(veh, plate) ... end` — if present, the default
-- event list is skipped and your handler runs instead. You can also replace
-- bridge/vehicle_keys/default/client.lua with your own bridge file to swap
-- out the whole implementation.
Config.VehicleKeys = {
    enabled = true,
    events = {
        { name = 'vehiclekeys:client:SetOwner',               scope = 'client' }, -- qb-vehiclekeys / qbx_vehiclekeys
        { name = 'qb-vehiclekeys:server:AcquireVehicleKeys',  scope = 'server' }, -- qb-vehiclekeys
        { name = 'vehiclekeys:server:setVehicleOwner',        scope = 'server' }, -- cd_garage / Renewed-Vehiclekeys
    },
    customHandler = nil, -- function(veh, plate) ... end
}

-- Test Drive Settings
Config.TestDriveTime = 120 -- Seconds
Config.TestDriveRadius = 500.0

-- Lot Rent (0 = disabled, otherwise daily cost)
Config.LotRent = 0

-- Financing Settings
Config.FinancingMinDown = 0.30
Config.FinancingInterest = 0.05
Config.FinancingMaxMissed = 3
Config.FinancingPaymentInterval = 24 -- Hours between installments

-- Credit Score Integration
-- When enabled, dealership owners can require a minimum credit score before
-- a customer is allowed to open a financing agreement. Scores are fetched
-- through the bridge provider named below. Supported providers:
--   "tgg-banking" — exports['tgg-banking']:GetCreditScore(identifier)
-- Leaving enabled=false makes GetPlayerCreditScore always return nil, so the
-- per-dealership requireCreditScore toggle becomes a no-op.
Config.CreditScore = {
    enabled = false,
    provider = "tgg-banking",
}

-- Tier Definitions
Config.Tiers = {
    [1] = {
        label = "Starter Lot",
        stockCap = 1000,
        employeeCap = 2,
        displaySpots = 2,
        upgradeCost = 0,
        catalogAccess = "basic",
        features = { "financing" },
    },
    [2] = {
        label = "Established",
        stockCap = 10,
        employeeCap = 4,
        displaySpots = 4,
        upgradeCost = 200000,
        catalogAccess = "expanded",
        features = { "financing" },
    },
    [3] = {
        label = "Premium",
        stockCap = 20,
        employeeCap = 6,
        displaySpots = 8,
        upgradeCost = 500000,
        catalogAccess = "full",
        features = { "test_drives", "financing", "showroom" },
    },
    [4] = {
        label = "Enterprise",
        stockCap = 35,
        employeeCap = 10,
        displaySpots = 12,
        upgradeCost = 1500000,
        catalogAccess = "exclusive",
        features = { "test_drives", "financing", "showroom", "coupons", "bulk_discount", "multi_trailer" },
    },
}

-- Delivery Routes
Config.DeliveryRoutes = {
    ["short"] = {
        label = "Local Depot",
        distance = "short",
        discount = 0,
        riskLevel = 0,
        pickupCoords = vector4(895.59, -1053.24, 32.83, 180.0),
        dropoffRadius = 50.0,
    },
    ["medium"] = {
        label = "Port of LS",
        distance = "medium",
        discount = 0.05,
        riskLevel = 1,
        pickupCoords = vector4(1214.63, -3233.49, 5.86, 175.0),
        dropoffRadius = 50.0,
    },
    ["long"] = {
        label = "Paleto Import Dock",
        distance = "long",
        discount = 0.10,
        riskLevel = 2,
        pickupCoords = vector4(-204.78, 6528.86, 1.50, 45.0),
        dropoffRadius = 50.0,
    },
}

-- Trailer model for trucking deliveries
Config.TrailerModel = `tr2`
Config.DeliveryTruckModel = `flatbed`

-- Color mode options for dealerships
Config.ColorModes = {
    rgb_wheel = "Full RGB Color Wheel",
    rgb_palette = "Curated RGB Palette",
    color_ids = "GTA Color IDs",
}

-- Default RGB palette (used when colorMode = 'rgb_palette')
Config.DefaultColorPalette = {
    { label = "Midnight Black", r = 10, g = 10, b = 10 },
    { label = "Arctic White", r = 252, g = 252, b = 252 },
    { label = "Racing Red", r = 192, g = 14, b = 26 },
    { label = "Electric Blue", r = 30, g = 80, b = 190 },
    { label = "Forest Green", r = 20, g = 100, b = 36 },
    { label = "Sunset Orange", r = 230, g = 100, b = 20 },
    { label = "Royal Purple", r = 80, g = 20, b = 140 },
    { label = "Silver Metallic", r = 180, g = 185, b = 190 },
    { label = "Gold", r = 200, g = 170, b = 50 },
    { label = "Matte Gray", r = 100, g = 100, b = 100 },
    { label = "Navy Blue", r = 15, g = 25, b = 80 },
    { label = "Wine Red", r = 100, g = 10, b = 20 },
}

-- Default dealership settings (applied to all admin-created dealerships)
Config.DealershipDefaults = {
    selfService = false,
    deliveryMode = "timed",
    colorMode = "rgb_wheel",
    acceptedCurrency = "both",
    blip = { sprite = 326, color = 3, scale = 0.8 },
    zoneRadius = 40.0,
}

-- NPC Customer System
Config.NPCCustomers = {
    enabled = true,
    spawnInterval =  {min = 1, max = 3}, -- { min = 300, max = 900 },
    maxConcurrent = 3,
    patienceTime = { min = 60, max = 120 },
    maxPresentations = 3,
    maxNegotiationRounds = 5,
    consumeStock = true,
    businessHours = nil,
    xpPerSale = 15,
    reputationPerSale = 1,
    walkAwayPenalty = -1,
    -- Every NPC-accepted offer must leave the dealership with at least this
    -- much profit after commission. The evaluator rejects below-floor offers
    -- during negotiation, and completeNPCSale re-checks server-side so the
    -- dealership can never be forced to sell at a loss. 0.05 = 5%.
    minProfitMargin = 0.05,

    tierBudgetMultiplier = {
        [1] = 1.0,
        [2] = 1.2,
        [3] = 1.5,
        [4] = 2.0,
    },

    budgetTiers = {
        { label = "Budget", min = 5000, max = 25000, weight = 40 },
        { label = "Mid-Range", min = 25000, max = 100000, weight = 30 },
        { label = "Premium", min = 100000, max = 500000, weight = 20 },
        { label = "Luxury", min = 500000, max = 2000000, weight = 10 },
    },

    personalityWeights = {
        haggler = 25,
        impulse_buyer = 20,
        researcher = 25,
        skeptic = 20,
        walkaway = 10,
    },

    typePreferences = {
        sports = 20, sedan = 25, suv = 20, truck = 10,
        muscle = 10, offroad = 5, coupe = 10,
    },

    flexibilityRange = { min = 0.2, max = 0.6 },

    pedModels = {
        budget = {
            "a_m_y_skater_01", "a_f_y_hipster_01", "a_m_y_hipster_01",
            "a_f_y_tourist_01", "a_m_y_genstreet_01", "a_f_y_genhot_01",
        },
        midrange = {
            "a_m_y_business_01", "a_f_y_business_01", "a_m_y_business_02",
            "a_f_y_business_02", "a_m_y_scdressy_01", "a_f_y_scdressy_01",
        },
        premium = {
            "a_m_y_bevhills_01", "a_f_y_bevhills_01", "a_m_y_bevhills_02",
            "a_f_y_bevhills_02", "a_m_m_bevhills_01", "a_f_m_bevhills_01",
        },
        luxury = {
            "a_m_m_bevhills_02", "a_f_y_bevhills_04", "a_m_y_clubcust_01",
            "a_f_m_bevhills_02", "ig_bankman", "ig_car3guy1",
        },
    },

    greetings = {
        sports = {
            "I'm looking for something fast. Something that really moves, you know?",
            "Need a car that turns heads on the highway. Speed is everything.",
            "My buddy just got a sports car and I can't let him show me up.",
        },
        sedan = {
            "I need something reliable. Good on gas, comfortable ride.",
            "Looking for a family car, nothing too flashy.",
            "Just need something practical to get to work and back.",
        },
        suv = {
            "I need something with space. Got a big family, you know?",
            "Looking for an SUV, something that handles well on rough roads.",
            "Want something big and safe. Safety is my priority.",
        },
        muscle = {
            "I want something with raw power. American muscle, baby.",
            "Looking for something loud. I want people to hear me coming.",
            "Need a car with some real grunt under the hood.",
        },
        super = {
            "Money's not really an object. Show me the best you've got.",
            "I want the fastest car on your lot. Period.",
            "Looking for something exclusive. Something nobody else has.",
        },
        default = {
            "Hey, I'm looking to buy a vehicle today.",
            "Hi there! What do you have available?",
            "I'm in the market for something new. What can you show me?",
        },
    },

    reactions = {
        great = {
            "Now THAT'S what I'm talking about! This is perfect!",
            "Oh wow, this is exactly what I had in mind!",
            "Yes! This is the one. Let's talk numbers.",
        },
        good = {
            "Hmm, not exactly what I had in mind, but I could see it...",
            "It's nice. Not perfect, but I'm interested.",
            "Okay, this has potential. What's the price?",
        },
        poor = {
            "That's... not really my style.",
            "Ehh, I was hoping for something different.",
            "I don't know about this one. Got anything else?",
        },
        terrible = {
            "Are you serious? That's not even close to what I asked for.",
            "No. Just... no. Were you even listening?",
            "Come on, I told you what I wanted. This isn't it.",
        },
    },

    negotiation = {
        stand_firm = {
            success = { "Alright, I guess that's fair.", "Fine, you drive a hard bargain." },
            fail = { "That's too high. Come on, work with me here.", "I can find a better deal elsewhere." },
        },
        concession = {
            success = { "Now we're getting somewhere!", "That's more like it. I appreciate you working with me." },
            fail = { "Still too much. Can you do better?", "Getting closer, but not there yet." },
        },
        highlight_features = {
            success = { "You know what, you're right. It is worth it.", "I didn't think about it that way. Good point." },
            fail = { "Yeah, but that doesn't justify the price.", "Features are nice, but the price has to be right." },
        },
        urgency = {
            success = { "Wait, someone else is looking at it? Okay, let's do this.", "I don't want to miss out. Let's close this deal." },
            fail = { "Nice try, but I'm not falling for that.", "I'll take my chances. Drop the price." },
        },
        sweeten = {
            success = { "Oh, that's a nice touch! Okay, I'm in.", "With that thrown in? Deal." },
            fail = { "That's nice but it doesn't change the price issue.", "A freebie doesn't make up for the markup." },
        },
        match_need = {
            success = { "You actually listened! That means a lot. Let's do it.", "You're right, this does match what I need. I'll take it." },
            fail = { "Close, but not quite what I meant.", "I appreciate the effort, but the price still needs work." },
        },
        final_offer = {
            accept = { "Fine, you got yourself a deal.", "Alright, final answer: I'll take it." },
            reject = { "No deal. I'm walking.", "Sorry, that's still too much. I'm out." },
        },
    },
}

-- Discord webhooks are configured server-side only. See config_sv.lua →
-- ServerConfig.Webhooks. Webhook URLs are deliberately never replicated to
-- clients to prevent abuse if a player dumps the shared config.

-- Photo Booth (vehicle catalog photography)
-- Multiple locations can be defined; each can restrict which vehicle classes use it.
-- The first location whose `classes` list contains the vehicle's class is used.
-- A location with no `classes` (or classes = {}) acts as the fallback for anything unmatched.
Config.PhotoBooth = {
    routingBucket = 999,
    locations = {
        {
            label = "Interior Studio",
            coords = vector4(-1508.0502, -2992.9255, -81.2074, 181.9531),
            camRadius = 6.0,
            camHeight = 2.0,
            classes = { "compact", "sedan", "sports", "super", "muscle", "coupe", "suv", "offroad", "van" },
        },
        {
            label = "Ocean View",
            coords = vector4(0.0, 0.0, 1500.0, 0.0),
            camRadius = 10.0,
            camHeight = 3.0,
            classes = { "boat" },
        },
        {
            label = "Airport",
            coords = vector4(-1052.4316, -3505.4155, 14.1398, 329.4947),
            camRadius = 10.0,
            camHeight = 3.0,
            classes = { "plane", "helicopter" },
        },
    },
}

-- Auction system — all durations in minutes. Escrow on bid, anti-snipe on late bids.
Config.Auction = {
    durations = { 1, 3, 5, 10, 15 },  -- minute presets shown in the list-for-auction dialog
    defaultDuration = 10,               -- minutes
    antiSnipeSeconds = 30,              -- bids within this window of end push end_at forward by same amount
    minIncrementFloor = 50,             -- seller-chosen min_increment may not be below this
    houseCutPct = 0.0,                  -- 0.0 = all net to dealership balance; e.g. 0.05 = 5% platform fee
    viewerBucketBase = 5000,            -- per-viewer routing bucket = base + source id (keeps showcases private)
    finalizerTickMs = 1000,             -- how often the server scans for expired auctions
}
