Config = {}

Config.Debug = false

-- Debug shortcut command — opens the cutting view on the first stage-3
-- plot it can find. Real entry is via ox_target on the plot itself.
Config.Command = "growop"

-- ─── Plot registry ──────────────────────────────────────────────────────────
-- Static plot registry. Each entry seeds a row in `pickle_drugs_plots` on
-- resource start (if missing) and gets target zones + world rendering.
-- Future: dynamic placement.
Config.GrowSpots = {
    {
        id     = "starter_weed",
        drug   = "weed",
        coords = vector4(450.4583, -1014.3433, 27.495, 26.7962),
    },
}

-- ─── Drug definitions ───────────────────────────────────────────────────────
-- Each entry is referenced by `Config.GrowSpots[i].drug`. Modules read from
-- here:
--   modules/grow      → stages, capsule, soilBag (rendering + lifecycle)
--   modules/cutting   → cutting (camera, scissors, fall behaviour)
--   modules/watering  → watering (pitcher kinematics, particles, level)
Config.Drugs = {}

Config.Drugs.weed = {
    label = "Weed",

    -- Item names (resolved through the inventory bridge).
    seedItem    = "weed_seed",
    pitcherItem = nil, -- nil = pitcher is summoned by the interaction; set
                       -- a string to gate "Water" behind owning an item.

    -- Pre-stage props shown after the seed is planted but before stage 1
    -- spawns. All three share the capsule's root coords.
    capsule = {
        capsule = "pickle_capsule_01",
        cap     = "pickle_capsule_cap_01",
        seed    = "pickle_capsule_seed_01",
    },

    -- Soil bag props shown during the "Add soil" interaction. The full
    -- bag fades out as the player rips it; the ripped bag sits inside it
    -- and remains for the pour phase.
    soilBag = {
        full   = "pickle_soil_bag_01",
        ripped = "pickle_soil_ripbag_01",
    },

    -- Interactive soiling scene (modules/soiling). Player drags across the
    -- top of the soil bag to rip it (full bag fades to reveal the ripped
    -- bag underneath), then tilts the ripped bag past `pourAngleDeg` over
    -- the pot to fill it. The soil prop rises from `soilStartZ` up to
    -- `planting.rubbleSoilZ` as the fill progresses.
    soiling = {
        ripDistance       = 0.6,    -- accumulated normalised cursor travel needed to fully rip the bag
        pourAngleDeg      = 60.0,   -- |pitch| past which soil pours into the pot
        secondsPerFullBag = 3.0,    -- seconds of pouring (landing in pot) to fully fill from start to end Z
        soilStartZ        = -0.35,  -- pickle_soil_01 Z offset (relative to plot centre) at 0% fill;
                                    -- end Z reuses planting.rubbleSoilZ
        cameraDistMul     = 1.4,
    },

    -- Interactive planting scene (modules/planting). Player tilts the
    -- capsule to drop the seed, then converges 4 soil-rubble clumps from a
    -- small ring around the pot centre to bury it. The same rubble model
    -- is re-spawned by modules/grow/client and stays put for the rest of
    -- the grow until the plant is harvested.
    planting = {
        rubble        = "pickle_soil_rubble_01",
        rubbleCount     = 4,       -- evenly spaced around the soil ring
        rubbleRadius    = 0.09,    -- spawn-ring radius from pot centre (metres)
        rubbleConvergeK = 0.75,    -- 0..1: how far each clump slides toward centre during planting; the persistent pile uses the same residual `(1 - K) * rubbleRadius`
        rubbleSoilZ     = 0.0,    -- absolute Z offset from plot centre where the rubble pile sits
        seedZ           = 0.325,   -- Z offset for the buried seed on top of `rubbleSoilZ`
        tiltDropDeg   = 165.0,     -- |roll| past this snaps to 180° and drops the seed
        cameraDistMul = 1.4,
    },

    -- Total wall-clock from "seed planted" to "fully grown". Split evenly
    -- across the pre-harvest growing stages (1..N-1).
    totalGrowMs = 30 * 1000, -- 10 seconds total

    -- Water reservoir. The plant holds up to `waterCapacityMs` of growing
    -- time; it depletes by real time and growth pauses when it hits 0.
    -- One full pitcher tops the reservoir to 100% (5 registered pours of
    -- `pourPerPlot = 0.20` each). Falls back to totalGrowMs/3 if unset.
    waterCapacityMs = 10 * 60 * 1000,

    -- Growth stages (1-indexed). Stages 1..N-1 share `totalGrowMs`
    -- evenly — stage 1 is the empty/germinating phase (no plant model
    -- yet) and counts as a full growing stage. Stage N is the
    -- harvestable end-cap (carries the buds config).
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

    -- Cutting scene parameters (consumed by modules/cutting).
    cutting = {
        tool     = "pickle_scissors_01",
        toolBone = 28422, -- ped right hand
        toolAnim = {
            dict = "anim@amb@business@weed@weed_inspecting_lo_med_hi@",
            clip = "weigh_v5_cuttingbuds_buyer",
        },
        camera      = { fov = 35.0, distanceMul = 1.0, heightOffset = 0.8 },
        fadeMs      = 400,
        fallMs      = 2000,
        fallCarrier = "sf_prop_sf_apple_01a",
        harvestItem = "weed_bud",
    },

    -- Watering scene parameters (consumed by modules/watering).
    watering = {
        pitcher       = "pickle_water_pot_01",
        liquid        = "pickle_water_liquid_01",
        liquidMaxZ    = 0.0,    -- liquid prop local Z at 100% full
        liquidMinZ    = -0.11,  -- liquid prop local Z at 0% empty
        pourAngleDeg  = 65.0,   -- pitcher pitch past which water pours
        secondsPerFullPitcher = 4.0, -- seconds of continuous pouring to drain a full pitcher
        pourPerPlot   = 0.20,   -- 0..1 poured onto a plot to register one server-side pour
        cameraDistMul = 1.4,    -- framing pull-back for the watering scene
        partFx        = { dict = "core", name = "ent_amb_pouring_water_into_pot" },
        -- Looped fx played on the pot while a pour stream is landing in
        -- it — visualises the water filling the pot. Optional.
        potFx         = { dict = "core", name = "ent_amb_pouring_water_into_pot" },
        potFxZ        = 0.25,   -- vertical offset of the pot fx on the pot
    },
}