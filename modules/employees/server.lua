-- NPC Employee server. Holds the authoritative employee roster, persists
-- it, runs the work scheduler that drives each employee through their
-- assigned plots, and broadcasts named tasks (goto/work/idle/return) to
-- every connected client. Clients spawn their own local ped per employee
-- and follow the task stream; the server fires the gameplay action at
-- each task's deadline so the action lands regardless of any one
-- client's local sync state.

-- `Employees` is the public module table (housing/server.lua and other
-- modules call into Employees.OnHouseLeaseLapsed etc.). The roster of
-- live employees is kept on a separate `Roster` table so module-style
-- function assignments don't show up when we iterate the roster with
-- pairs() — that previously crashed listEmployees and silently broke
-- the assign-plots UI.
Employees = Employees or {}
local Roster = {}           -- id → row
local EmployeeState = {}    -- id → runtime { state, taskDeadline, currentPlotId, currentAction, currentBudIndex, cooldownUntil }
local CurrentTask  = {}     -- id → last broadcast task (sent to joiners)

local function now() return os.time() * 1000 end

local function jsonDecodeArray(s)
    if type(s) ~= "string" then return type(s) == "table" and s or {} end
    local ok, v = pcall(json.decode, s)
    if ok and type(v) == "table" then return v end
    return {}
end

-- ─── Persistence ───────────────────────────────────────────────────────────

--- Normalises a possibly-NULL/blank house_id to nil so downstream
--- truthiness checks (`if emp.house_id then`) actually mean "is bound to
--- a house". oxmysql can hand back empty strings or non-string sentinels
--- for NULL columns; both should be treated as unbound.
local function normaliseHouseId(v)
    if v == nil then return nil end
    if type(v) ~= "string" then return nil end
    if v == "" then return nil end
    return v
end

local function rowFromDb(row)
    return {
        id              = row.id,
        model           = row.model,
        first_name      = row.first_name,
        last_name       = row.last_name,
        home_x          = tonumber(row.home_x) or 0,
        home_y          = tonumber(row.home_y) or 0,
        home_z          = tonumber(row.home_z) or 0,
        home_w          = tonumber(row.home_w) or 0,
        assigned_plots  = jsonDecodeArray(row.assigned_plots),
        house_id        = normaliseHouseId(row.house_id),
        updated_at      = tonumber(row.updated_at) or 0,
    }
end

--- Returns the world-space "home" coords for an employee, falling back to
--- the bound house's interior idle point if the employee was created
--- through a house and has no explicit home_*. Per-house workers idle
--- inside their interior (in the house's bucket); legacy employees stay
--- at their world coords.
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

--- Returns the routing bucket the employee's ped should sit in. 0 unless
--- bound to a teleport-kind house with a non-zero bucket.
local function effectiveBucket(emp)
    if emp.house_id and Housing and Housing.GetHouse then
        local h = Housing.GetHouse(emp.house_id)
        if h and h.kind == "teleport" then return h.bucket or 0 end
    end
    return 0
end

--- Drops plot ids from `emp.assigned_plots` that no longer exist on the
--- server. Plots can be deleted (or recreated with new ids) without the
--- employee table knowing — without this the scheduler keeps trying to
--- work ghost ids and the employee idles forever.
local function scrubStaleAssignments(emp)
    if not emp.assigned_plots or #emp.assigned_plots == 0 then return false end
    local kept = {}
    for _, pid in ipairs(emp.assigned_plots) do
        if Grow and Grow.GetServerPlot and Grow.GetServerPlot(pid) then
            kept[#kept + 1] = pid
        end
    end
    if #kept == #emp.assigned_plots then return false end
    emp.assigned_plots = kept
    return true
end

local function LoadEmployees()
    local rows = MySQL.query.await("SELECT * FROM pickle_drugs_employees") or {}
    for _, row in ipairs(rows) do
        Roster[row.id] = rowFromDb(row)
        EmployeeState[row.id] = { state = "idle", cooldownUntil = 0 }
    end
    debugPrint(("employees: loaded %d"):format(#rows))
end

local function PersistEmployee(emp)
    emp.updated_at = now()
    MySQL.update.await(
        "UPDATE pickle_drugs_employees SET model=?, first_name=?, last_name=?, home_x=?, home_y=?, home_z=?, home_w=?, assigned_plots=?, house_id=?, updated_at=? WHERE id=?",
        {
            emp.model, emp.first_name, emp.last_name,
            emp.home_x, emp.home_y, emp.home_z, emp.home_w,
            json.encode(emp.assigned_plots or {}),
            emp.house_id,
            emp.updated_at,
            emp.id,
        }
    )
end

local function SyncEmployee(emp)
    PersistEmployee(emp)
    TriggerClientEvent("pickle_drugs:employeeUpdate", -1, emp)
end

-- ─── Task broadcast helpers ────────────────────────────────────────────────

local function broadcastTask(emp, task)
    CurrentTask[emp.id] = task
    TriggerClientEvent("pickle_drugs:employeeTask", -1, task)
end

local function makeIdleTask(emp)
    local hx, hy, hz, hw = effectiveHome(emp)
    return {
        empId    = emp.id,
        kind     = "idle",
        target   = { x = hx, y = hy, z = hz, w = hw },
        plotId   = nil,
        anim     = nil,
        deadline = now(),
        bucket   = effectiveBucket(emp),
    }
end

local function distance3(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- ─── Strict 1:1 plot ownership ────────────────────────────────────────────

local function plotOwnerOf(plotId)
    for _, emp in pairs(Roster) do
        for _, pid in ipairs(emp.assigned_plots or {}) do
            if pid == plotId then return emp end
        end
    end
end

local function scrubPlotFromAll(plotId, exceptEmpId)
    for _, emp in pairs(Roster) do
        if emp.id ~= exceptEmpId then
            local before = #emp.assigned_plots
            local kept = {}
            for _, pid in ipairs(emp.assigned_plots) do
                if pid ~= plotId then kept[#kept + 1] = pid end
            end
            if #kept ~= before then
                emp.assigned_plots = kept
                SyncEmployee(emp)
            end
        end
    end
end

-- ─── Admin gate + CRUD ─────────────────────────────────────────────────────

local function adminCheck(src)
    if not Admin or not Admin.IsAdmin then return src == 0 end
    return Admin.IsAdmin(src)
end

local function generateEmployeeId()
    local id = ("emp_%d"):format(now())
    if not Roster[id] then return id end
    return ("%s_%d"):format(id, math.random(1000, 9999))
end

local function notify(src, msg, type_)
    TriggerClientEvent("ox_lib:notify", src,
        { title = "Employees", description = msg, type = type_ or "inform" })
end

RegisterNetEvent("pickle_drugs:createEmployee", function(model, firstName, lastName, x, y, z, w)
    local src = source
    if not adminCheck(src) then return end
    if type(model) ~= "string" or model == "" then notify(src, "Bad model", "error") return end
    if type(firstName) ~= "string" or firstName == "" then notify(src, "Need first name", "error") return end
    if type(lastName)  ~= "string" or lastName  == "" then notify(src, "Need last name",  "error") return end
    x = tonumber(x); y = tonumber(y); z = tonumber(z); w = tonumber(w) or 0.0
    if not x or not y or not z then notify(src, "Bad coords", "error") return end

    local id = generateEmployeeId()
    local emp = {
        id = id, model = model, first_name = firstName, last_name = lastName,
        home_x = x, home_y = y, home_z = z, home_w = w,
        assigned_plots = {}, updated_at = now(),
    }
    Roster[id] = emp
    EmployeeState[id] = { state = "idle", cooldownUntil = 0 }

    MySQL.insert.await(
        "INSERT INTO pickle_drugs_employees (id, model, first_name, last_name, home_x, home_y, home_z, home_w, assigned_plots, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
        { id, model, firstName, lastName, x, y, z, w, "[]", emp.updated_at }
    )
    TriggerClientEvent("pickle_drugs:employeeUpdate", -1, emp)
    -- Initial idle task so freshly-spawned local peds park at home.
    broadcastTask(emp, makeIdleTask(emp))
    notify(src, ("Employee %s %s created"):format(firstName, lastName), "success")
end)

RegisterNetEvent("pickle_drugs:updateEmployeeCoords", function(empId, x, y, z, w)
    local src = source
    if not adminCheck(src) then return end
    local emp = Roster[empId]
    if not emp then return end
    x = tonumber(x); y = tonumber(y); z = tonumber(z); w = tonumber(w) or 0.0
    if not x or not y or not z then return end
    emp.home_x, emp.home_y, emp.home_z, emp.home_w = x, y, z, w
    SyncEmployee(emp)
    -- Reset to idle at the new home so the schedule restarts cleanly.
    EmployeeState[empId] = { state = "idle", cooldownUntil = 0 }
    broadcastTask(emp, makeIdleTask(emp))
    notify(src, "Employee moved", "success")
end)

RegisterNetEvent("pickle_drugs:deleteEmployee", function(empId)
    local src = source
    if not adminCheck(src) then return end
    if not Roster[empId] then return end
    Roster[empId] = nil
    EmployeeState[empId] = nil
    CurrentTask[empId] = nil
    MySQL.update.await("DELETE FROM pickle_drugs_employees WHERE id=?", { empId })
    TriggerClientEvent("pickle_drugs:employeeRemoved", -1, empId)
    notify(src, "Employee dismissed", "success")
end)

RegisterNetEvent("pickle_drugs:assignPlots", function(empId, plotIds)
    local src = source
    local emp = Roster[empId]
    if not emp then return end
    -- Admins can assign anywhere. Otherwise the caller has to be the
    -- owner of the worker's house, and every plot they hand in has to
    -- belong to that same house — so a house owner can't reach into a
    -- neighbour's plots through their own worker.
    local houseOk = false
    if emp.house_id and Housing and Housing.GetHouse and Housing.IsHouseOwner then
        local h = Housing.GetHouse(emp.house_id)
        if h and Housing.IsHouseOwner(src, h) then houseOk = true end
    end
    if not (adminCheck(src) or houseOk) then return end
    if type(plotIds) ~= "table" then plotIds = {} end

    -- Validate each plot id exists, dedupe, scrub from other employees
    -- (strict 1:1 ownership), then assign to this one. House-owner callers
    -- are additionally restricted to plots belonging to the worker's house.
    local seen, kept = {}, {}
    for _, pid in ipairs(plotIds) do
        if type(pid) == "string" and not seen[pid] then
            local plot = Grow.GetServerPlot(pid)
            if plot then
                if houseOk and not adminCheck(src) and plot.house_id ~= emp.house_id then
                    -- House owner trying to assign a plot outside their house — skip.
                else
                    seen[pid] = true
                    kept[#kept + 1] = pid
                    scrubPlotFromAll(pid, empId)
                end
            end
        end
    end
    emp.assigned_plots = kept
    SyncEmployee(emp)
    -- Reset to idle so the next scheduler tick re-evaluates against the
    -- new pool instead of waiting for the in-flight task to finish.
    EmployeeState[empId] = { state = "idle", cooldownUntil = 0 }
    broadcastTask(emp, makeIdleTask(emp))
    notify(src, ("Assigned %d plot(s)"):format(#kept), "success")
end)

-- ─── Callbacks ─────────────────────────────────────────────────────────────

lib.callback.register("pickle_drugs:listEmployees", function()
    local out = {}
    for _, emp in pairs(Roster) do
        out[#out + 1] = {
            id            = emp.id,
            model         = emp.model,
            firstName     = emp.first_name,
            lastName      = emp.last_name,
            home          = { x = emp.home_x, y = emp.home_y, z = emp.home_z, w = emp.home_w },
            assignedPlots = emp.assigned_plots or {},
            houseId       = emp.house_id,
        }
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end)

--- Returns the latest broadcast task per employee. The client uses
--- this on its own boot to replay whatever is in flight when a hot
--- resource restart causes it to miss the original broadcast.
lib.callback.register("pickle_drugs:getCurrentTasks", function()
    local out = {}
    for empId, task in pairs(CurrentTask) do
        out[empId] = task
    end
    return out
end)

--- Returns every plot tagged with its current owner (if any). The
--- assignment NUI uses this to grey out plots taken by other employees
--- while keeping the queried employee's own plots checked.
lib.callback.register("pickle_drugs:getAssignablePlots", function(_src, queryEmpId)
    local out = {}
    for id, plot in pairs(Grow.GetAllServerPlots() or {}) do
        local owner = plotOwnerOf(id)
        out[#out + 1] = {
            id        = id,
            drug      = plot.drug,
            stage     = plot.stage,
            x         = plot.coords_x,
            y         = plot.coords_y,
            z         = plot.coords_z,
            w         = plot.coords_w,
            ownerEmpId = owner and owner.id or nil,
            ownerName  = owner and (owner.first_name .. " " .. owner.last_name) or nil,
            ownedByMe  = owner and owner.id == queryEmpId or false,
        }
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end)

-- ─── Scheduler ─────────────────────────────────────────────────────────────

-- All timings come from Config.Employees so they can be tuned without
-- touching code. Defaults match the original constants if a field is
-- missing from config.
local function empCfg(key, fallback)
    local c = Config and Config.Employees
    if c and c[key] ~= nil then return c[key] end
    return fallback
end

--- Per-action work duration. `Config.Employees.workMs` may be a number
--- (legacy / global) or a table `{ default = ms, soil = ms, ... }`.
local function workMsFor(action)
    local v = empCfg("workMs", 4500)
    local resolved
    if type(v) == "number" then
        resolved = v
    elseif type(v) == "table" then
        if action and v[action] ~= nil then
            resolved = v[action]
        elseif v.default ~= nil then
            resolved = v.default
        end
    end
    if not resolved then resolved = 4500 end
    debugPrint(("workMsFor(%s) -> %s (cfg type=%s)"):format(tostring(action), tostring(resolved), type(v)))
    return resolved
end

local function plotPos(plot)
    return { x = plot.coords_x, y = plot.coords_y, z = plot.coords_z }
end

--- Returns the work spot for a plot — its local-frame `workOffset`
--- rotated by the plot's heading and added to the plot position. The
--- ped stands here facing the plot, so the animation reads as working
--- the pot rather than standing on top of it.
local function workSpotOf(plot)
    local off = empCfg("workOffset", vector3(0.0, 1.0, 0.0))
    local ox, oy, oz = off.x or 0.0, off.y or 0.0, off.z or 0.0
    local hRad = math.rad(plot.coords_w or 0.0)
    -- GTA heading: 0° faces +Y; rotation around Z. forward = (-sin, cos),
    -- right = (cos, sin). worldOffset = right*ox + forward*oy.
    local sinH, cosH = math.sin(hRad), math.cos(hRad)
    local wx = plot.coords_x + cosH * ox - sinH * oy
    local wy = plot.coords_y + sinH * ox + cosH * oy
    local wz = plot.coords_z + oz
    -- Heading the ped should face: from the work spot back toward the
    -- plot. dx,dy = plot - spot.
    local dx, dy = plot.coords_x - wx, plot.coords_y - wy
    local facing = math.deg(math.atan2(-dx, dy))
    return { x = wx, y = wy, z = wz, facing = facing }
end

local function walkDuration(fromXYZ, toXYZ)
    local d = distance3(fromXYZ, toXYZ)
    local ms = math.floor((d / empCfg("walkSpeedMps", 1.5)) * 1000)
    local minMs = empCfg("walkMinMs", 3000)
    local maxMs = empCfg("walkMaxMs", 10000)
    if ms < minMs then ms = minMs end
    if ms > maxMs then ms = maxMs end
    return ms
end

--- Picks the closest assigned plot that needs an action. Returns
--- (plotId, action, budIndex_or_nil) or nil if all assigned plots are
--- already up to date.
--- Every employee — house-bound or not — works only its explicit
--- `assigned_plots` list. House-bound employees were previously auto-
--- assigned every plot in their house, but that meant a worker would
--- silently start tending a freshly-placed plot the moment the owner
--- dropped it. Owners now opt plots in via the /employees assigner; on
--- hire, createHouseEmployee seeds the list with the plots that already
--- exist so the day-one experience matches the old behaviour.
local function plotPoolFor(emp)
    return emp.assigned_plots or {}
end

local function pickNextWorkPlot(emp)
    local nowMs   = now()
    local hx, hy, hz = effectiveHome(emp)
    local origin = { x = hx, y = hy, z = hz }
    local bestId, bestAction, bestBud, bestDist
    for _, pid in ipairs(plotPoolFor(emp)) do
        local plot = Grow.GetServerPlot(pid)
        if plot then
            local drugCfg = Config.Drugs[plot.drug]
            Grow.ResolveStage(plot, drugCfg, nowMs)
            local action, budIdx = Grow.NextEmployeeAction(plot, drugCfg, nowMs)
            if action then
                local d = distance3(origin, plotPos(plot))
                if not bestDist or d < bestDist then
                    bestId, bestAction, bestBud, bestDist = pid, action, budIdx, d
                end
            end
        end
    end
    return bestId, bestAction, bestBud
end

local function performAction(emp, plotId, action, budIndex)
    local plot = Grow.GetServerPlot(plotId)
    if not plot then return false end
    local drugCfg = Config.Drugs[plot.drug]
    if not drugCfg then return false end

    local ok
    if action == "soil"    then ok = Grow.PerformAddSoil(plot, now())
    elseif action == "plant"   then ok = Grow.PerformPlant(plot, drugCfg, now())
    elseif action == "water"   then ok = Grow.PerformWater(plot, drugCfg, now())
    elseif action == "harvest" then ok = Grow.PerformCutBud(plot, drugCfg, budIndex)
    end

    if ok then Grow.SyncServerPlot(plot, true) end
    return ok
end

--- Transition an employee from going → working at the supplied time.
--- Centralised so both the natural deadline path and the client's early
--- arrival signal go through the same broadcast.
local function startWorking(emp, s, plot, nowMs)
    local spot = workSpotOf(plot)
    s.lastPos      = { x = spot.x, y = spot.y, z = spot.z }
    s.atPlotId     = s.currentPlotId
    s.state        = "working"
    s.taskDeadline = nowMs + workMsFor(s.currentAction)
    broadcastTask(emp, {
        empId    = emp.id,
        kind     = "work",
        target   = spot,
        plotId   = s.currentPlotId,
        anim     = empCfg("mechanicAnim", nil),
        scenario = empCfg("mechanicScenario", nil),
        deadline = s.taskDeadline,
    })
end

--- Client-side trigger when the ped reaches the work spot ahead of the
--- server's walk deadline. Validates the employee is still walking to
--- the plot id the client claims, then advances immediately.
RegisterNetEvent("pickle_drugs:employeeArrivedAtPlot", function(empId, plotId)
    local emp = Roster[empId]
    local s   = EmployeeState[empId]
    if not emp or not s then return end
    if s.state ~= "going" or s.currentPlotId ~= plotId then return end
    local plot = Grow.GetServerPlot(plotId)
    if not plot then return end
    startWorking(emp, s, plot, now())
end)

CreateThread(function()
    -- Startup grace: wait long enough for connected clients to mount
    -- their handlers, run the boot fetch (1.5s wait + roster + tasks
    -- callbacks), and finish spawning local peds. Without this, the
    -- first goto broadcast fires before clients are ready and its
    -- deadline is mostly burned by the time they receive it — the ped
    -- ends up walking a fraction of the way and TPing for the rest.
    Wait(6000)
    -- Plot cache is loaded by grow/server.lua independently; by the time
    -- the 6s grace is up it's ready. Drop any assigned plot ids that
    -- don't resolve so a stale row doesn't keep the employee idling.
    for _, emp in pairs(Roster) do
        if scrubStaleAssignments(emp) then
            debugPrint(("employees: scrubbed stale plot ids on %s, %d remain"):format(emp.id, #emp.assigned_plots))
            PersistEmployee(emp)
            TriggerClientEvent("pickle_drugs:employeeUpdate", -1, emp)
        end
    end
    -- Rebind employees that were created via the house "Hire" flow but
    -- ended up with an empty / nil `house_id` (a stale houseId in the
    -- panel state during hire). Match by home coords == an interior's
    -- idle point: that's exactly what createHouseEmployee writes when
    -- it succeeds, so any unbound emp whose home matches a house's
    -- interior idle point is almost certainly that house's worker.
    if Housing and Housing.GetAllHouses and Housing.GetInterior then
        local function near(a, b) return math.abs((a or 0) - (b or 0)) < 0.05 end
        local rebound = 0
        for _, emp in pairs(Roster) do
            if not emp.house_id or emp.house_id == "" then
                for _, h in pairs(Housing.GetAllHouses() or {}) do
                    if h.id ~= "_legacy" then
                        local interior = Housing.GetInterior(h.interior_id)
                        if interior
                           and near(interior.idle_x, emp.home_x)
                           and near(interior.idle_y, emp.home_y)
                           and near(interior.idle_z, emp.home_z)
                        then
                            emp.house_id = h.id
                            PersistEmployee(emp)
                            TriggerClientEvent("pickle_drugs:employeeUpdate", -1, emp)
                            rebound = rebound + 1
                            break
                        end
                    end
                end
            end
        end
        if rebound > 0 then
            print(("[pickle_drugs] employees: rebound %d unbound worker(s) to their house"):format(rebound))
        end
    end
    while true do
        Wait(500)
        local nowMs = now()
        for empId, emp in pairs(Roster) do
            local s = EmployeeState[empId]
            if s then
                if s.state == "idle" then
                    if (s.cooldownUntil or 0) <= nowMs then
                        local pid, action, bud = pickNextWorkPlot(emp)
                        if pid then
                            local plot = Grow.GetServerPlot(pid)
                            local hx, hy, hz = effectiveHome(emp)
                            local origin = { x = hx, y = hy, z = hz }
                            if s.lastPos then origin = s.lastPos end
                            local spot = workSpotOf(plot)
                            s.currentPlotId   = pid
                            s.currentAction   = action
                            s.currentBudIndex = bud

                            -- Only skip the goto when we KNOW the ped is
                            -- currently standing at this exact plot — set
                            -- by a successful going→working transition
                            -- and cleared whenever the ped leaves. A raw
                            -- distance check fired false-positives (e.g.
                            -- when home was near a plot) so we tracked
                            -- the plot id explicitly instead.
                            if s.atPlotId == pid then
                                startWorking(emp, s, plot, nowMs)
                            else
                                local walkMs = walkDuration(origin, spot)
                                s.state        = "going"
                                s.taskDeadline = nowMs + walkMs
                                s.atPlotId     = nil
                                broadcastTask(emp, {
                                    empId      = empId,
                                    kind       = "goto",
                                    target     = spot,
                                    plotId     = pid,
                                    anim       = nil,
                                    deadline   = s.taskDeadline,
                                    durationMs = walkMs,
                                })
                            end
                        else
                            local hx, hy, hz, hw = effectiveHome(emp)
                            if s.lastPos and distance3(s.lastPos, { x = hx, y = hy, z = hz }) > 3.0 then
                            -- Nothing to do but ped wandered; send back home.
                            local target = { x = hx, y = hy, z = hz, w = hw }
                            local walkMs = walkDuration(s.lastPos, target)
                            s.state        = "returning"
                            s.taskDeadline = nowMs + walkMs
                            broadcastTask(emp, {
                                empId      = empId,
                                kind       = "return",
                                target     = target,
                                plotId     = nil,
                                anim       = nil,
                                deadline   = s.taskDeadline,
                                durationMs = walkMs,
                            })
                            end
                        end
                    end
                elseif s.state == "going" then
                    if nowMs >= (s.taskDeadline or 0) then
                        local plot = Grow.GetServerPlot(s.currentPlotId)
                        if plot then
                            startWorking(emp, s, plot, nowMs)
                        else
                            s.state = "idle"
                            s.cooldownUntil = nowMs + empCfg("cooldownMs", 1000)
                        end
                    end
                elseif s.state == "working" then
                    if nowMs >= (s.taskDeadline or 0) then
                        performAction(emp, s.currentPlotId, s.currentAction, s.currentBudIndex)
                        s.state = "idle"
                        s.cooldownUntil = nowMs + empCfg("cooldownMs", 1000)
                        s.currentPlotId = nil
                        s.currentAction = nil
                        s.currentBudIndex = nil
                    end
                elseif s.state == "returning" then
                    if nowMs >= (s.taskDeadline or 0) then
                        local hx, hy, hz = effectiveHome(emp)
                        s.lastPos = { x = hx, y = hy, z = hz }
                        s.atPlotId = nil
                        s.state = "idle"
                        s.cooldownUntil = nowMs + empCfg("cooldownMs", 1000)
                        broadcastTask(emp, makeIdleTask(emp))
                    end
                end
            end
        end
    end
end)

-- ─── Boot ──────────────────────────────────────────────────────────────────

CreateThread(function()
    if not (MySQL and MySQL.ready) then return end
    MySQL.ready(function()
        local ok, err = pcall(function()
            MySQL.query.await([[
                CREATE TABLE IF NOT EXISTS pickle_drugs_employees (
                    id              VARCHAR(64)  PRIMARY KEY,
                    model           VARCHAR(64)  NOT NULL,
                    first_name      VARCHAR(32)  NOT NULL,
                    last_name       VARCHAR(32)  NOT NULL,
                    home_x          DOUBLE       NOT NULL DEFAULT 0,
                    home_y          DOUBLE       NOT NULL DEFAULT 0,
                    home_z          DOUBLE       NOT NULL DEFAULT 0,
                    home_w          DOUBLE       NOT NULL DEFAULT 0,
                    assigned_plots  TEXT         NOT NULL,
                    updated_at      BIGINT       NOT NULL DEFAULT 0
                )
            ]])
            -- Housing migration: house_id binds an employee to a house;
            -- legacy employees keep it NULL and idle at world coords.
            local cols = MySQL.query.await(
                "SHOW COLUMNS FROM pickle_drugs_employees WHERE Field = 'house_id'"
            ) or {}
            if #cols == 0 then
                MySQL.query.await(
                    "ALTER TABLE pickle_drugs_employees ADD COLUMN house_id VARCHAR(64) NULL"
                )
            end
            LoadEmployees()
        end)
        if not ok then
            print(("[pickle_drugs] employees: DB error, starting empty: %s"):format(tostring(err)))
        end
        local count = 0
        for _ in pairs(Roster) do count = count + 1 end
        print(("[pickle_drugs] employees: ready with %d"):format(count))

        -- On a hot resource restart the connected players never get a
        -- `playerJoining` event, so push the roster + an initial idle
        -- task to everyone now. Without this each ped only spawns on
        -- a client after an admin moves them via /employees (because
        -- the move triggers an employeeUpdate broadcast).
        for _, emp in pairs(Roster) do
            TriggerClientEvent("pickle_drugs:employeeUpdate", -1, emp)
            local idle = makeIdleTask(emp)
            CurrentTask[emp.id] = idle
            TriggerClientEvent("pickle_drugs:employeeTask", -1, idle)
        end
        -- Roster is fully populated and pushed to clients. Other modules
        -- (housing.getHouseDetail) gate on this so they don't return an
        -- empty workers list to a panel opened seconds after a hot
        -- restart.
        Employees.RosterReady = true
    end)
end)

-- ─── House-bound employee API ─────────────────────────────────────────────

--- Called by Housing when a lease lapses. Despawn (delete from roster) any
--- employees bound to the house — their idle target is gone (the bucket is
--- about to be cleared) and they shouldn't keep working a property the
--- owner just lost. Admin can re-hire after the next purchase.
function Employees.OnHouseLeaseLapsed(houseId)
    if not houseId then return end
    for id, emp in pairs(Roster) do
        if type(emp) == "table" and emp.house_id == houseId then
            Roster[id] = nil
            EmployeeState[id] = nil
            CurrentTask[id] = nil
            MySQL.update.await("DELETE FROM pickle_drugs_employees WHERE id=?", { id })
            TriggerClientEvent("pickle_drugs:employeeRemoved", -1, id)
        end
    end
end

--- House-bound hire path. Owner-or-admin gated. Coords come from the
--- bound interior's idle point; assigned_plots stays empty (the scheduler
--- treats house-bound employees as "work everything in this house").
RegisterNetEvent("pickle_drugs:createHouseEmployee", function(houseId, model, firstName, lastName)
    local src = source
    if not Housing or not Housing.GetHouse then return end
    local house = Housing.GetHouse(houseId)
    if not house then return end
    if not (Housing.IsHouseOwner(src, house) or adminCheck(src)) then
        notify(src, "Owner only", "error") return
    end
    if type(model) ~= "string" or model == "" then notify(src, "Bad model", "error") return end
    firstName = (type(firstName) == "string" and firstName ~= "") and firstName or "Employee"
    lastName  = (type(lastName)  == "string" and lastName  ~= "") and lastName  or house.id

    local interior = Housing.GetInterior(house.interior_id)
    local ix = interior and interior.idle_x or 0
    local iy = interior and interior.idle_y or 0
    local iz = interior and interior.idle_z or 0
    local iw = interior and interior.idle_w or 0

    -- Seed the assignment with every plot that already exists in the
    -- house at hire time so the day-one experience matches the old
    -- "house workers tend everything" behaviour. New plots placed
    -- afterwards stay unassigned until the owner opts them in via the
    -- /employees assigner — that's the explicit-only contract.
    local seeded = {}
    if Grow and Grow.PlotsForHouse then
        for _, p in ipairs(Grow.PlotsForHouse(houseId)) do
            seeded[#seeded + 1] = p.id
        end
    end
    local id = generateEmployeeId()
    local emp = {
        id = id, model = model, first_name = firstName, last_name = lastName,
        home_x = ix, home_y = iy, home_z = iz, home_w = iw,
        assigned_plots = seeded, house_id = houseId, updated_at = now(),
    }
    Roster[id] = emp
    EmployeeState[id] = { state = "idle", cooldownUntil = 0 }
    MySQL.insert.await(
        "INSERT INTO pickle_drugs_employees (id, model, first_name, last_name, home_x, home_y, home_z, home_w, assigned_plots, house_id, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
        { id, model, firstName, lastName, ix, iy, iz, iw, json.encode(seeded), houseId, emp.updated_at }
    )
    TriggerClientEvent("pickle_drugs:employeeUpdate", -1, emp)
    broadcastTask(emp, makeIdleTask(emp))
    notify(src, "Employee hired", "success")
end)

RegisterNetEvent("pickle_drugs:dismissHouseEmployee", function(empId)
    local src = source
    local emp = Roster[empId]
    if not emp or not emp.house_id then return end
    local house = Housing and Housing.GetHouse and Housing.GetHouse(emp.house_id) or nil
    if not (house and (Housing.IsHouseOwner(src, house) or adminCheck(src))) then return end
    Roster[empId] = nil
    EmployeeState[empId] = nil
    CurrentTask[empId] = nil
    MySQL.update.await("DELETE FROM pickle_drugs_employees WHERE id=?", { empId })
    TriggerClientEvent("pickle_drugs:employeeRemoved", -1, empId)
    notify(src, "Employee dismissed", "success")
end)

lib.callback.register("pickle_drugs:listHouseEmployees", function(_src, houseId)
    local out = {}
    if not houseId then return out end
    for _, emp in pairs(Roster) do
        if type(emp) == "table" and emp.house_id == houseId then
            out[#out + 1] = {
                id = emp.id, model = emp.model,
                firstName = emp.first_name, lastName = emp.last_name,
                houseId = emp.house_id,
            }
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end)

-- Push everything to a joining player (employees + their current task).
AddEventHandler("playerJoining", function()
    local src = source
    SetTimeout(2500, function()
        for _, emp in pairs(Roster) do
            TriggerClientEvent("pickle_drugs:employeeUpdate", src, emp)
        end
        for _, task in pairs(CurrentTask) do
            TriggerClientEvent("pickle_drugs:employeeTask", src, task)
        end
    end)
end)
