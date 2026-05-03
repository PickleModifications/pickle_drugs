Config = {}

Config.Debug = false

-- Debug shortcut: opens the cutting view on the first stage-3 plot found.
Config.Command = "growop"

-- ─── Plant scene ──────────────────────────────────────────────────────────
-- All per-action mechanics + camera framing for in-world plant interactions.
-- Global across drugs; per-drug entries below only specify the recipe
-- (label, items, grow times, stage models).
--
-- Each `camera` block:
--   distanceMul   pull-back multiplier on the auto-fit camera distance
--   heightOffset  metres added to the look point to position the camera
--   lookOffset    metres added to the look point itself (tilt up/down)
--   fov           field of view in degrees
--
-- menuCam is special — distance/camZ/lookZ are absolute world-Z offsets
-- from the plot origin (not auto-fit).
Config.PlantScene = {
    transitionMs = 600,

    menuCam = {
        distance = 1.6,
        camZ     = 1.45,
        lookZ    = 0.75,
        fov      = 40.0,
    },

    soiling = {
        bag = {
            full   = "pickle_soil_bag_01",
            ripped = "pickle_soil_ripbag_01",
        },
        ripDistance       = 0.6,    -- normalised cursor travel to fully rip
        pourAngleDeg      = 60.0,   -- |pitch| past which soil pours
        secondsPerFullBag = 3.0,    -- pour time to fully fill a pot
        soilStartZ        = -0.35,  -- soil prop Z at 0% fill
        camera            = { fov = 38.0, distanceMul = 1.4, heightOffset = 1.0, lookOffset = 0.0 },
    },

    planting = {
        capsule = {
            capsule = "pickle_capsule_01",
            cap     = "pickle_capsule_cap_01",
            seed    = "pickle_capsule_seed_01",
        },
        rubble          = "pickle_soil_rubble_01",
        rubbleCount     = 4,
        rubbleRadius    = 0.09,
        rubbleConvergeK = 0.75,
        rubbleSoilZ     = 0.0,
        seedZ           = 0.325,
        tiltDropDeg     = 165.0,    -- |roll| past which the seed drops
        camera          = { fov = 38.0, distanceMul = 1.4, heightOffset = 1.0, lookOffset = 0.0 },
    },

    watering = {
        pitcher       = "pickle_water_pot_01",
        liquid        = "pickle_water_liquid_01",
        liquidMaxZ    = 0.0,        -- liquid Z at 100% full
        liquidMinZ    = -0.11,      -- liquid Z at 0% empty
        pourAngleDeg  = 65.0,       -- pitcher pitch past which water pours
        secondsPerFullPitcher = 4.0,
        pourPerPlot   = 0.20,       -- 0..1 per registered pour
        partFx        = { dict = "core", name = "ent_amb_pouring_water_into_pot" },
        potFx         = { dict = "core", name = "ent_amb_pouring_water_into_pot" },
        potFxZ        = 0.25,
        camera        = { fov = 38.0, distanceMul = 1.4, heightOffset = 0.6, lookOffset = 0.0 },
    },

    cutting = {
        tool     = "pickle_scissors_01",
        toolBone = 28422,           -- ped right hand
        toolAnim = {
            dict = "anim@amb@business@weed@weed_inspecting_lo_med_hi@",
            clip = "weigh_v5_cuttingbuds_buyer",
        },
        fadeMs      = 400,
        fallMs      = 2000,
        fallCarrier = "sf_prop_sf_apple_01a",
        camera      = { fov = 35.0, distanceMul = 0.8, heightOffset = 0.8, lookOffset = 0.1 },
    },
}

-- ─── NPC Employees ─────────────────────────────────────────────────────────
Config.Employees = {
    workMs = {
        default = 4500,
        soil    = 4500,
        plant   = 4500,
        water   = 4500,
        harvest = 1000,
        deposit = 2500,
    },
    carryCapacity = 25,         -- items before the worker must deposit
    cooldownMs    = 1000,
    walkMinMs     = 10000,
    walkMaxMs     = 15000,
    walkSpeedMps  = 1.5,
    mechanicScenario = nil,
    mechanicAnim = {
        dict = "mini@repair",
        clip = "fixing_a_ped",
    },
    workOffset = vector3(0.0, -1.0, 0.0),  -- ped stand point in plot frame
    arriveDistance = 1.25,
    maxPlotsPerWorker = 10,
}

-- ─── Housing ───────────────────────────────────────────────────────────────
-- Houses + interiors live in DB and are CRUD-managed via /drugs.
Config.Housing = {
    gridCellSize = 0.5,

    -- Preview models for admin pick flows.
    placementProps = {
        door       = { model = "v_ilev_fh_frntdoor" },
        exit       = { model = "v_ilev_fh_frntdoor" },
        idle       = { model = "s_m_m_gardener_01", isPed = true },
        mgmt       = { model = "prop_laptop_01a" },
        house_door = { model = "v_ilev_fh_frntdoor" },
    },

    defaultZTolerance = 0.6,
    sweepIntervalMs   = 60 * 1000,
    rentGracePeriodMs = 0,
    bucketBase        = 100000,

    placement = {
        previewAlpha  = 180,
        gridLineAlpha = 90,
        validColor    = { r = 80,  g = 200, b = 120 },
        invalidColor  = { r = 230, g = 80,  b = 80 },
        emptyColor    = { r = 220, g = 220, b = 220 },
        occupiedColor = { r = 110, g = 110, b = 110 },
        cellHeight    = 0.05,
    },

    money = {
        mode      = "framework",    -- "cash" | "framework"
        cashItem  = "cash",
        moneyType = "cash",         -- "cash" | "bank"
    },

    teleport = {
        fadeOutMs = 400,
        fadeInMs  = 400,
    },
}

-- ─── Dealing ───────────────────────────────────────────────────────────────
-- NPC customers + dealing zones, managed via /drugs → "Dealing" tab.
Config.Dealing = {
    cooldownMs        = 5 * 60 * 1000,
    failureCooldownMs = 10 * 60 * 1000,
    maxQty            = 10,
    completeWindowMs  = 6 * 60 * 1000,
    acceptThreshold   = 0.90,
    schedulerTickMs   = 30 * 1000,
    offerIntervalMs   = 4 * 60 * 1000,
    priceJitter       = 0.15,
    -- Streaming distance for customer ped spawn. Spawning at range avoids
    -- the ground-Z probe falling back to the admin-set zone Z when the
    -- chunk isn't loaded.
    streamRange       = 80.0,

    -- Dealer cut: default % the dealer keeps when they auto-fulfil an
    -- offer. Per-dealer override lives in pickle_drugs_dealers.cut_pct.
    dealerCutPct           = 0.10,
    -- How long the dealer + customer ped stand on the deal point before
    -- the auto-deal settles (item decremented + owner credited).
    dealerAutoCompleteMs   = 12000,
    -- Slot capacity for the dealer's on-person inventory (same UI as a
    -- locker — split / combine / rearrange / deposit / withdraw).
    dealerInventorySlots   = 25,
}

-- ─── Drugs ─────────────────────────────────────────────────────────────────
-- Each drug is a recipe: label, deal price, items, grow timing, and stage
-- models. Scene mechanics (soiling/planting/watering/cutting) are global
-- and live in Config.PlantScene above.
Config.Drugs = {}

Config.Drugs.weed = {
    label = "Weed",
    deal  = { basePrice = 35 },

    -- Inventory items.
    seedItem    = "pickle_weed_seed",   -- consumed when planted
    harvestItem = "pickle_weed_bud",    -- produced by cutting

    -- Growth timing.
    totalGrowMs     = 60 * 1000,        -- planted → fully grown
    waterCapacityMs = 10 * 60 * 1000,   -- reservoir between top-ups

    -- Growth stages (1-indexed). Stage 1 has no model (germinating);
    -- the last stage carries the buds config (harvestable).
    stages = {
        { model = nil },
        { model = "pickle_weed_tree_01" },
        { model = "pickle_weed_tree_02" },
        {
            model = "pickle_weed_tree_03",
            buds = {
                model = "pickle_weed_bud_01",
                offsets = {
                    { x = 0.1168, y = 0.1394, z = 1.1584 },
                    { x = -0.1088, y = 0.1374, z = 1.0830 },
                    { x = -0.1128, y = -0.1312, z = 1.0828 },
                    { x = 0.1146, y = -0.1352, z = 1.1584 },
                    { x = 0.1640, y = 0.0046, z = 1.0058 },
                    { x = 0.0004, y = 0.1748, z = 0.9408 },
                    { x = -0.1752, y = -0.0026, z = 0.9412 },
                    { x = -0.1738, y = -0.0038, z = 0.6710 },
                    { x = -0.1760, y = -0.0004, z = 0.4072 },
                    { x = -0.1044, y = -0.1214, z = 0.5450 },
                    { x = -0.0012, y = -0.1674, z = 0.7358 },
                    { x = -0.1102, y = -0.1280, z = 0.8044 },
                    { x = 0.1032, y = -0.1380, z = 0.8740 },
                    { x = 0.0012, y = -0.1678, z = 1.0066 },
                    { x = 0.1066, y = -0.1302, z = 0.6082 },
                    { x = 0.1650, y = 0.0094, z = 0.7370 },
                    { x = 0.1086, y = 0.1298, z = 0.6084 },
                    { x = -0.0018, y = 0.1708, z = 0.6704 },
                    { x = -0.0996, y = 0.1280, z = 0.5458 },
                    { x = -0.1062, y = 0.1308, z = 0.8038 },
                    { x = 0.0030, y = -0.1656, z = 0.4728 },
                    { x = 0.1024, y = -0.1254, z = 0.3450 },
                    { x = 0.1752, y = 0.0064, z = 0.4728 },
                    { x = 0.1164, y = 0.1270, z = 0.3478 },
                    { x = -0.0002, y = 0.1734, z = 0.4062 },
                },
            },
        },
    },
}

-- ─── Inventory ────────────────────────────────────────────────────────────
-- Fallback path for item images; the active inventory bridge usually wins.
Config.Inventory = {
    imagesPath = "nui://ox_inventory/web/images",
}

-- Shared inventory items used across every grow flow. Set any to false/nil
-- to skip the corresponding gate.
Config.Items = {
    pot         = "pickle_pot",          -- consumed at plot placement
    soilBag     = "pickle_soil_bag",     -- consumed when soil is added
    wateringCan = "pickle_watering_can", -- required to water
    scissors    = "pickle_scissors",     -- required to cut buds
}

-- ─── Storage ──────────────────────────────────────────────────────────────
Config.Storage = {
    types = {
        small  = { label = "Small Locker",  model = "ch_prop_ch_service_locker_01b", slots = 10 },
        medium = { label = "Medium Locker", model = "ch_prop_ch_service_locker_02a", slots = 25 },
        large  = { label = "Gun Locker",    model = "gr_prop_gr_gunlocker_01a",      slots = 50 },
    },
}
