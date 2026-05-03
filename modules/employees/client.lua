-- NPC Employee client. Spawns a local copy of every employee ped at its
-- home coords and follows the server's task stream. Server is the only
-- source of truth — this module just animates the local ped to match.
-- If a goto deadline expires before the ped arrives, we TP it to the
-- target so subsequent work-task playback still lines up with the plot.

local Peds = {}      -- empId → { ped, model, emp, currentTask, tpTimer }

-- ─── Helpers ───────────────────────────────────────────────────────────────

local function loadModel(name)
    local hash = type(name) == "string" and joaat(name) or name
    if not hash or not IsModelInCdimage(hash) then return nil end
    RequestModel(hash)
    local deadline = GetGameTimer() + 5000
    while not HasModelLoaded(hash) and GetGameTimer() < deadline do Wait(0) end
    return HasModelLoaded(hash) and hash or nil
end

local function loadAnim(dict)
    if not dict or HasAnimDictLoaded(dict) then return HasAnimDictLoaded(dict) end
    RequestAnimDict(dict)
    local deadline = GetGameTimer() + 5000
    while not HasAnimDictLoaded(dict) and GetGameTimer() < deadline do Wait(0) end
    return HasAnimDictLoaded(dict)
end

local function distance(ped, target)
    if not ped or not DoesEntityExist(ped) or not target then return math.huge end
    local p = GetEntityCoords(ped)
    local dx, dy, dz = p.x - target.x, p.y - target.y, p.z - target.z
    return math.sqrt(dx*dx + dy*dy + dz*dz)
end

--- Snap a server-supplied coord onto the nearest collidable ground so a
--- ped placed there stands cleanly instead of being buried (the saved Z
--- is the gizmo's raycast hit, which can be a hair below collision when
--- the surface is angled / on a prop). Falls back to the input Z if the
--- ground probe misses.
local function snapToGround(x, y, z)
    local found, gz = GetGroundZFor_3dCoord(x + 0.0, y + 0.0, z + 1.0, false)
    if found and gz and gz > 0.0 then return gz end
    return z
end

-- ─── Ped lifecycle ─────────────────────────────────────────────────────────

local function attachTarget(ped, empId)
    if GetResourceState("ox_target") ~= "started" then return end
    exports.ox_target:addLocalEntity(ped, {
        {
            name  = "pickle_drugs:emp_manage_" .. empId,
            label = "Manage Worker",
            icon  = "fa-solid fa-id-badge",
            distance = 2.5,
            onSelect = function()
                TriggerEvent("pickle_drugs:openWorkerInManagePanel", empId)
            end,
        },
    })
end

--- Resolve the world-space home for the local spawn — workers idle at
--- their bound interior's idle point in the house's bucket.
local function effectiveHome(emp)
    if emp.house_id and Housing and Housing.GetHouse then
        local h = Housing.GetHouse(emp.house_id)
        local interior = h and Housing.GetInterior(h.interior_id) or nil
        if interior and (interior.idle_x ~= 0 or interior.idle_y ~= 0 or interior.idle_z ~= 0) then
            return interior.idle_x, interior.idle_y, interior.idle_z, interior.idle_w
        end
    end
    return emp.home_x, emp.home_y, emp.home_z, emp.home_w
end

local function spawnPed(emp)
    local hash = loadModel(emp.model)
    if not hash then
        debugPrint(("employees: model %s failed to load for %s"):format(tostring(emp.model), emp.id))
        return nil
    end
    local hx, hy, hz, hw = effectiveHome(emp)
    local gz = snapToGround(hx, hy, hz)
    local ped = CreatePed(4, hash, hx, hy, gz, hw or 0.0, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not ped or not DoesEntityExist(ped) then return nil end
    -- Bucket the ped so non-residents don't see it. SetEntityRoutingBucket
    -- is server-only; client-side we use the local-only flag and rely on
    -- the server to set the entity's bucket. Local peds never network, so
    -- buckets are moot — instead we hide the ped to clients who aren't in
    -- the house's bucket by simply not spawning it.
    if emp.house_id and Housing and Housing.GetHouse then
        local h = Housing.GetHouse(emp.house_id)
        if h and h.kind == "teleport" then
            local insideId = Housing.GetCurrentBucketHouseId()
            if insideId ~= emp.house_id then
                DeleteEntity(ped)
                return nil
            end
        end
    end
    SetEntityInvincible(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedDefaultComponentVariation(ped)
    -- Initial pose is idle: freeze so a player walking into them can't
    -- nudge them out of position. Goto/return tasks unfreeze; idle/work
    -- re-freeze (handled in applyTask).
    FreezeEntityPosition(ped, true)
    -- Start parked-in-place; the first task broadcast will override.
    TaskStartScenarioInPlace(ped, "WORLD_HUMAN_GUARD_STAND", 0, true)
    attachTarget(ped, emp.id)
    return ped
end

local function despawn(empId)
    local entry = Peds[empId]
    if not entry then return end
    if entry.tpTimer then entry.tpTimer = nil end
    if entry.ped and DoesEntityExist(entry.ped) then
        if GetResourceState("ox_target") == "started" then
            exports.ox_target:removeLocalEntity(entry.ped)
        end
        DeleteEntity(entry.ped)
    end
    Peds[empId] = nil
end

-- ─── Task application ─────────────────────────────────────────────────────

local function clearPedTasks(ped)
    if not ped or not DoesEntityExist(ped) then return end
    -- Immediate variant skips the scenario's exit anim, which would
    -- otherwise stall a fresh TaskGoToCoord by ~1-2 s while the ped
    -- "stands up" out of WORLD_HUMAN_GUARD_STAND.
    ClearPedTasksImmediately(ped)
    ClearPedSecondaryTask(ped)
end

local function workTaskKey(task)
    if not task or task.kind ~= "work" then return nil end
    local scenario = task.scenario or ""
    local animKey  = ""
    if task.anim and task.anim.dict and task.anim.clip then
        animKey = task.anim.dict .. "/" .. task.anim.clip
    end
    return (task.plotId or "") .. "|" .. scenario .. "|" .. animKey
end

--- Polls the ped's distance to the work spot and fires a one-shot
--- server event the moment the ped is within `arriveDistance`. The
--- server uses this to advance going→working / going_to_locker→
--- depositing without waiting on the walk-duration floor. The thread
--- self-cancels if a new task is applied (entry.arriveSentinel
--- changes). `eventName` + `targetId` switch between plot and locker
--- arrivals — the server has matching net handlers for each.
local function scheduleArriveSignal(empId, eventName, targetId, target)
    local entry = Peds[empId]
    if not entry then return end
    local sentinel = {}
    entry.arriveSentinel = sentinel
    local threshold = (Config and Config.Employees and Config.Employees.arriveDistance) or 1.25
    CreateThread(function()
        while true do
            Wait(150)
            local e = Peds[empId]
            if not e or e.arriveSentinel ~= sentinel then return end
            if not e.ped or not DoesEntityExist(e.ped) then return end
            if distance(e.ped, target) <= threshold then
                e.arriveSentinel = nil
                TriggerServerEvent(eventName, empId, targetId)
                return
            end
        end
    end)
end

local function scheduleArrivalTp(empId, target, deadline)
    CreateThread(function()
        local entry = Peds[empId]
        if not entry then return end
        local sentinel = {}
        entry.tpTimer = sentinel
        local waitMs = math.max(0, deadline - GetGameTimer())
        Wait(waitMs)
        if Peds[empId] ~= entry or entry.tpTimer ~= sentinel then return end
        entry.tpTimer = nil
        if not entry.ped or not DoesEntityExist(entry.ped) then return end
        if distance(entry.ped, target) > 1.5 then
            SetEntityCoords(entry.ped, target.x, target.y, target.z, false, false, false, false)
        end
    end)
end

local function applyTask(empId, task)
    local entry = Peds[empId]
    if not entry or not entry.ped or not DoesEntityExist(entry.ped) then return end
    local prevTask = entry.currentTask
    entry.currentTask = task
    -- Cancel any pending arrival-TP / arrive-signal from the previous
    -- goto so they can't fire after this new task is applied (a stale
    -- TP would re-position the ped mid-anim, a stale arrive-signal
    -- would tell the server we reached a plot we no longer care about).
    entry.tpTimer = nil
    entry.arriveSentinel = nil
    local ped = entry.ped

    if task.kind == "goto" or task.kind == "return" then
        clearPedTasks(ped)
        FreezeEntityPosition(ped, false)
        local t = task.target or {}
        entry.gotoOrigin = GetEntityCoords(ped)
        TaskGoToCoordAnyMeans(ped, t.x or 0.0, t.y or 0.0, t.z or 0.0, 1.3, 0, false, 786603, 0xbf800000)
        if task.durationMs then
            -- Server tells us exactly how long the walk should last; use
            -- a local game-timer offset rather than trying to align with
            -- a server epoch (no os clock client-side, GetCloudTimeAsInt
            -- is only second-granular).
            local remaining = task.durationMs
            if remaining < 250 then remaining = 250 end
            scheduleArrivalTp(empId, t, GetGameTimer() + remaining)
        end
        -- For goto tasks, also poll the ped's distance to the work spot
        -- and tell the server the moment we're close enough — that lets
        -- the scheduler skip the rest of the walk-min floor and start
        -- the work animation immediately. plotId routes to the plot
        -- handler; lockerId routes to the deposit handler. Server
        -- validates state on its end so an unexpected ping is a no-op.
        if task.kind == "goto" then
            if task.plotId then
                scheduleArriveSignal(empId,
                    "pickle_drugs:employeeArrivedAtPlot",
                    task.plotId, t)
            elseif task.lockerId then
                scheduleArriveSignal(empId,
                    "pickle_drugs:employeeArrivedAtLocker",
                    task.lockerId, t)
            end
        end
    elseif task.kind == "work" then
        -- Skip restarting the scenario/anim when the previous task was
        -- the same kind+plot+scenario — keeps the gardener-plant pose
        -- continuous through consecutive harvest cuts (each bud is its
        -- own server-side action but the ped looks like one long work
        -- session).
        if workTaskKey(prevTask) == workTaskKey(task) and prevTask ~= nil then
            return
        end
        clearPedTasks(ped)
        FreezeEntityPosition(ped, false) -- briefly off so the snap+heading apply
        local t = task.target or {}
        if t.x then
            -- Always snap to the exact work spot so the anim plays at
            -- the configured offset from the plot (not wherever the
            -- nav-mesh dropped the ped).
            SetEntityCoords(ped, t.x, t.y, t.z, false, false, false, false)
            if t.facing then
                SetEntityHeading(ped, t.facing)
            end
        end
        if task.scenario and type(task.scenario) == "string" then
            TaskStartScenarioInPlace(ped, task.scenario, 0, true)
        elseif task.anim and task.anim.dict and task.anim.clip then
            if loadAnim(task.anim.dict) then
                TaskPlayAnim(ped, task.anim.dict, task.anim.clip, 8.0, -8.0, -1, 1, 0, false, false, false)
            end
        end
        FreezeEntityPosition(ped, true) -- pin in place for the work animation
    elseif task.kind == "idle" then
        clearPedTasks(ped)
        FreezeEntityPosition(ped, false) -- briefly off so a relocation can apply
        TaskStartScenarioInPlace(ped, "WORLD_HUMAN_GUARD_STAND", 0, true)
        if task.target and entry.ped then
            -- Make sure idle peds are exactly at home (they may have been
            -- mid-walk on a state reset).
            local d = distance(ped, task.target)
            if d > 2.5 then
                local gz = snapToGround(task.target.x, task.target.y, task.target.z)
                SetEntityCoords(ped, task.target.x, task.target.y, gz, false, false, false, false)
                if task.target.w then SetEntityHeading(ped, task.target.w) end
            end
        end
        FreezeEntityPosition(ped, true) -- pin home so players can't shove them off-spot
    end
end

-- ─── Net handlers ──────────────────────────────────────────────────────────

RegisterNetEvent("pickle_drugs:employeeUpdate", function(emp)
    if not emp or not emp.id then return end
    local entry = Peds[emp.id]
    if entry and entry.model ~= emp.model then
        -- Model changed (admin re-create) — respawn from scratch.
        despawn(emp.id)
        entry = nil
    end
    if not entry then
        local ped = spawnPed(emp)
        if not ped then return end
        Peds[emp.id] = { ped = ped, model = emp.model, emp = emp }
    else
        entry.emp = emp
        -- Home moved → relocate the ped right now (fresh idle task will
        -- arrive immediately afterwards from the server).
        if entry.ped and DoesEntityExist(entry.ped) then
            local p = GetEntityCoords(entry.ped)
            local moved = math.abs(p.x - emp.home_x) > 0.5 or math.abs(p.y - emp.home_y) > 0.5
            if moved and entry.currentTask and entry.currentTask.kind == "idle" then
                local gz = snapToGround(emp.home_x, emp.home_y, emp.home_z)
                SetEntityCoords(entry.ped, emp.home_x, emp.home_y, gz, false, false, false, false)
                SetEntityHeading(entry.ped, emp.home_w or 0.0)
            end
        end
    end
end)

RegisterNetEvent("pickle_drugs:employeeRemoved", function(empId)
    despawn(empId)
end)

--- Re-evaluate every employee's local visibility when the player moves
--- between buckets. Peds in teleport interiors only spawn when the
--- player is inside the matching bucket. We rebuild from `lib.callback`
--- so the spawn path decides whether to keep each.
local function reevaluatePeds()
    if not lib then return end
    local list = lib.callback.await("pickle_drugs:listEmployees", false) or {}
    local seen = {}
    for _, e in ipairs(list) do
        seen[e.id] = true
        local emp = {
            id = e.id, model = e.model,
            first_name = e.firstName, last_name = e.lastName,
            home_x = e.home.x, home_y = e.home.y, home_z = e.home.z, home_w = e.home.w,
            assigned_plots = e.assignedPlots,
            house_id = e.houseId,
        }
        local entry = Peds[e.id]
        if not entry then
            local ped = spawnPed(emp)
            if ped then Peds[e.id] = { ped = ped, model = emp.model, emp = emp } end
        else
            -- Despawn if the player has moved out of the relevant bucket.
            if emp.house_id and Housing then
                local h = Housing.GetHouse(emp.house_id)
                if h and h.kind == "teleport"
                    and Housing.GetCurrentBucketHouseId() ~= emp.house_id
                then
                    despawn(e.id)
                end
            end
        end
    end
    for id in pairs(Peds) do
        if not seen[id] then despawn(id) end
    end
end

RegisterNetEvent("pickle_drugs:enteredHouse", function() reevaluatePeds() end)
RegisterNetEvent("pickle_drugs:leftHouse",    function() reevaluatePeds() end)

RegisterNetEvent("pickle_drugs:employeeTask", function(task)
    if not task or not task.empId then return end
    applyTask(task.empId, task)
end)

AddEventHandler("onResourceStop", function(rn)
    if rn ~= GetCurrentResourceName() then return end
    for empId in pairs(Peds) do despawn(empId) end
end)

-- Pull the employee roster on client boot so peds spawn whenever the
-- script restarts — the server's hot-reload broadcast races the client's
-- net-event mount on resource start and can be missed by already-
-- connected players. This callback fetch is idempotent: spawnPed is
-- guarded against double-spawn via the Peds table.
CreateThread(function()
    while not lib do Wait(0) end
    -- Small grace so the server's MySQL.ready boot finishes first; the
    -- callback will return [] until then and we'd just have to retry.
    Wait(1500)
    local list = lib.callback.await("pickle_drugs:listEmployees", false) or {}
    for _, e in ipairs(list) do
        -- Fan out through the existing employeeUpdate handler so a single
        -- code path owns spawning. Map listEmployees' camelCase shape
        -- onto the row-style fields the spawn handler expects.
        TriggerEvent("pickle_drugs:employeeUpdate", {
            id              = e.id,
            model           = e.model,
            first_name      = e.firstName,
            last_name       = e.lastName,
            home_x          = e.home.x,
            home_y          = e.home.y,
            home_z          = e.home.z,
            home_w          = e.home.w,
            assigned_plots  = e.assignedPlots,
            house_id        = e.houseId,
        })
    end
    -- Replay whatever is in flight server-side. Without this, when the
    -- resource hot-reloads while a player is connected, the scheduler
    -- often advances past the goto state before the client's net-event
    -- handlers mount — so the client only ever receives the work task
    -- and the ped teleports onto the plot instead of walking. Re-applying
    -- the current task uses its server-time deadline so the remaining
    -- walk duration is honoured.
    local tasks = lib.callback.await("pickle_drugs:getCurrentTasks", false) or {}
    for _, task in pairs(tasks) do
        if task and task.empId then
            TriggerEvent("pickle_drugs:employeeTask", task)
        end
    end
end)

-- ─── Public open-event hooks (NUI sides handled separately) ─────────────────

function GetEmployee(empId)
    local entry = Peds[empId]
    return entry and entry.emp or nil
end

function GetAllLocalEmployees()
    local out = {}
    for _, entry in pairs(Peds) do
        if entry.emp then out[#out + 1] = entry.emp end
    end
    return out
end

-- ─── Ped models (consumed by HouseManagePanel hire UI) ───────────────────

local PED_MODELS = {
    "a_m_m_business_01",
    "a_m_y_business_03",
    "a_m_m_eastsa_01",
    "a_m_m_farmer_01",
    "s_m_m_dockwork_01",
    "s_m_m_gardener_01",
    "a_m_y_hipster_01",
    "a_m_m_hillbilly_01",
}
Employees = Employees or {}
Employees.PedModels = PED_MODELS
