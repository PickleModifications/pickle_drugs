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
        coords = vector4(450.4583, -1014.3433, 27.4815, 26.7962),
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

    -- Cosmetic-only soil bag shown during the "Add soil" interaction.
    soilBag = {
        full   = "pickle_soil_bag_01",
        ripped = "pickle_soil_ripbag_01",
    },

    -- Total wall-clock from "seed planted" to "fully grown" (stage 3). When
    -- set, it overrides individual stage `durationMs` values — the time is
    -- split evenly across stages 1 + 2 (stage 3 is the harvestable end-cap
    -- and stays at 0). Set to nil to use per-stage `durationMs` directly.
    totalGrowMs = 15 * 1000, -- 30 minutes by default

    -- 4 growth stages. `durationMs` is the per-stage fallback when
    -- `totalGrowMs` is nil; advancing also requires `waterRequired` pours.
    -- Stage 0 = empty plot, no plant. Stage 3 = harvestable.
    stages = {
        [0] = { model = nil,                   durationMs = 0,             waterRequired = 0 },
        [1] = { model = "pickle_weed_tree_01", durationMs = 5  * 60 * 1000, waterRequired = 1 },
        [2] = { model = "pickle_weed_tree_02", durationMs = 10 * 60 * 1000, waterRequired = 2 },
        [3] = {
            model = "pickle_weed_tree_03",
            durationMs = 0,
            waterRequired = 0,
            buds = {
                model     = "pickle_weed_bud_01",
                hitRadius = 0.06,
                offsets = {
                    -- Front-left column
                    { x = -0.1, y = 0.115, z = 0.985 },
                    { x = -0.1, y = 0.115, z = 0.825 },
                    { x = -0.1, y = 0.115, z = 0.665 },
                    { x = -0.1, y = 0.115, z = 0.505 },
                    -- Right column
                    { x =  0.1, y = -0.115, z = 0.985 },
                    { x =  0.1, y = -0.115, z = 0.825 },
                    { x =  0.1, y = -0.115, z = 0.665 },
                    { x =  0.1, y = -0.115, z = 0.505 },
                    -- Front-right column
                    { x =  0.1, y = 0.115, z = 0.89 },
                    { x =  0.1, y = 0.115, z = 0.75 },
                    { x =  0.1, y = 0.115, z = 0.585 },
                    { x =  0.1, y = 0.115, z = 0.415 },
                    -- Back-right column
                    { x = -0.1, y = -0.115, z = 0.89 },
                    { x = -0.1, y = -0.115, z = 0.75 },
                    { x = -0.1, y = -0.115, z = 0.585 },
                    { x = -0.1, y = -0.115, z = 0.415 },
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
        liquidMinZ    = -0.18,  -- liquid prop local Z at 0% empty
        pourAngleDeg  = 65.0,   -- pitcher pitch past which water pours
        secondsPerFullPitcher = 4.0, -- seconds of continuous pouring to drain a full pitcher
        pourPerPlot   = 0.20,   -- 0..1 poured onto a plot to register one server-side pour
        cameraDistMul = 1.4,    -- framing pull-back for the watering scene
        partFx        = { dict = "core", name = "ent_amb_pouring_water_into_pot" },
    },
}
