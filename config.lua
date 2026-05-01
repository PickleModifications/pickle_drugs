Config = {}

Config.Debug = false

-- Debug shortcut command — opens the cutting view on the first stage-3
-- plot it can find. Real entry is via ox_target on the plot itself.
Config.Command = "growop"

-- ─── Unified plant scene ───────────────────────────────────────────────────
-- Tunable parameters for the "Interact with Plant" scene. Camera tween
-- duration is in milliseconds; inspect orbit rate is degrees/second.
Config.PlantScene = {
    transitionMs            = 600,
    inspectOrbitDegPerSec   = 12.0,
}

-- ─── NPC Employees ─────────────────────────────────────────────────────────
-- Per-task timing for NPC workers managed via /employees.
--   workMs        — duration of the mechanic animation per action (soil,
--                   plant, water, harvest one bud). Server fires the
--                   actual gameplay mutation when this expires.
--   cooldownMs    — pause between consecutive actions while idle.
--   walkMinMs     — floor for any goto duration (prevents teleport-feel
--                   on very close plots).
--   walkMaxMs     — ceiling so far-away plots don't stall the schedule.
--   walkSpeedMps  — meters per second used to scale walk time by
--                   distance. The local ped uses TaskGoToCoordAnyMeans
--                   at its own speed; this number drives the deadline.
--   mechanicAnim  — animation played during `work` tasks.
Config.Employees = {
    -- Animation duration per action. `default` is used for any action
    -- that doesn't have its own override below. Action keys: "soil",
    -- "plant", "water", "harvest". Server fires the gameplay mutation
    -- when this expires.
    workMs = {
        default = 4500,
        soil    = 4500,
        plant   = 4500,
        water   = 4500,
        harvest = 1000,
    },
    cooldownMs   = 1000,
    walkMinMs    = 10000,
    walkMaxMs    = 15000,
    walkSpeedMps = 1.5,
    -- Animation played for every NPC work action (soil / plant / water /
    -- harvest). Scenario is left nil so the client always falls through
    -- to the anim path — `mini@repair / fixing_a_ped` reads as a kneeling
    -- mechanic-style fix that works for every action without needing a
    -- prop attached to the ped's hand.
    mechanicScenario = nil,
    mechanicAnim = {
        dict = "mini@repair",
        clip = "fixing_a_ped",
    },
    -- Where the ped stands when working a plot, expressed in the plot's
    -- local frame (x = right, y = forward, z = up — so the default
    -- {0, 1, 0} stands the ped 1m in front of the pot facing it).
    workOffset = vector3(0.0, -1.0, 0.0),
    -- Distance (m) at which a walking ped is considered "arrived" — the
    -- client signals the server to skip the remaining walk-min floor and
    -- start the work animation immediately.
    arriveDistance = 1.25,
}

-- ─── Housing ───────────────────────────────────────────────────────────────
-- Houses (world buildings) and reusable interior templates live in DB and
-- are CRUD-managed via the `/drugs` admin UI. The block below tunes the
-- shared player-facing behaviour (grid renderer, lease ticker, etc).
--
-- Houses are either:
--   * teleport — bucketed, the player teleports to the interior's door
--                point and exits via an in-interior ox_target.
--   * mlo      — existing in-world building, no bucket, no teleport;
--                ox_lib polyzone is used to detect entry/exit instead.
Config.Housing = {
    -- Cell size (in metres) used by the in-world zone picker. Cells are
    -- always axis-aligned squares of this size.
    gridCellSize = 0.5,

    -- Preview models used when an admin picks an interior / world point.
    -- `isPed = true` spawns the model as a ped (e.g. for the idle employee
    -- point); otherwise it's spawned as a prop. Each entry's model is also
    -- used to render the *other* already-placed points in-world while a
    -- pick is in progress, so the admin can see the full layout.
    placementProps = {
        door       = { model = "v_ilev_fh_frntdoor" },
        exit       = { model = "v_ilev_fh_frntdoor" },
        idle       = { model = "s_m_m_gardener_01", isPed = true },
        mgmt       = { model = "prop_laptop_01a" },
        house_door = { model = "v_ilev_fh_frntdoor" },
    },

    -- "Same z-level (grace penalty is fine)" — entities are placed at the
    -- zone's z but the visualizer accepts a vertical tolerance per zone.
    -- This is just the default; zones can override.
    defaultZTolerance = 0.6,

    -- Lease ticker. Sweep every `sweepIntervalMs`; if rent_due_at is past
    -- the current time the lease lapses (entities frozen, peds despawned,
    -- residents booted from the bucket).
    sweepIntervalMs   = 60 * 1000,
    rentGracePeriodMs = 0,

    -- Routing buckets are derived from the house id: bucketBase + hash.
    -- 100000 keeps us clear of typical world / framework reserved ranges.
    bucketBase = 100000,

    -- Player-side placement preview tuning. Colours are 0..255.
    placement = {
        previewAlpha    = 180,
        gridLineAlpha   = 90,
        validColor      = { r = 80,  g = 200, b = 120 },
        invalidColor    = { r = 230, g = 80,  b = 80 },
        emptyColor      = { r = 220, g = 220, b = 220 },
        occupiedColor   = { r = 110, g = 110, b = 110 },
        cellHeight      = 0.05, -- visual thickness of the rendered cell tile
    },

    -- Money handling. "cash" mode debits a cash item via the Inventory
    -- bridge; "framework" mode calls Player.GetMoney/RemoveMoney through
    -- the housing module's inline framework probe (qb/qbx/esx).
    money = {
        mode      = "framework",          -- "cash" | "framework"
        cashItem  = "cash",               -- only used in "cash" mode
        moneyType = "cash",               -- framework wallet ("cash" | "bank")
    },

    -- Teleport transition tuning.
    teleport = {
        fadeOutMs = 400,
        fadeInMs  = 400,
    },
}

-- ─── Drug definitions ───────────────────────────────────────────────────────
-- Plot LOCATIONS are no longer here — they live in `pickle_drugs_plots`
-- and are CRUD-managed via the `/drugs` admin UI.
--
-- Each entry below is the static *recipe* for a drug type (models, stages,
-- scene parameters). When an admin creates a plot they pick from this
-- table. Modules read from here:
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
    totalGrowMs = 300 * 1000, -- 10 seconds total

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