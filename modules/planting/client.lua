-- Interactive planting scene. Mirrors modules/watering/client structurally:
-- a scripted camera frames the pot, the cursor drives the capsule's
-- position in front of the camera, and A/D adjust roll. Three phases run
-- in sequence:
--
--   "cap"        — capsule + cap + seed visible; click anywhere to pop
--                  the cap off with physics.
--   "tilt"       — A/D tilts the capsule like the watering pitcher; once
--                  |roll| crosses tiltDropDeg the seed is detached and
--                  falls to the soil.
--   "wait_seed"  — poll the seed's velocity; when it has settled, advance.
--   "soil"       — four rubble clumps spawn in a ring around the pot
--                  centre. Click each to slide it inward; once the last
--                  one converges, fire pickle_drugs:plant on the server.
--
-- Persistent rubble (the four clumps stacked at centre during growth) is
-- owned by modules/grow/client; this scene only animates its own ring set
-- and hands off via the server's plot:update broadcast.

local PlantState = nil
-- PlantState = {
--   plotId, spot, drugCfg, plotCenter, cam,
--   capsule, cap, seed,
--   capProxy,                       -- invisible apple at the cap's visual
--                                    --   centre; raycast target so cap-click
--                                    --   hit-tests the cap region only.
--   capProxyOffset = vector3,       -- local-space cap centre relative to
--                                    --   the capsule entity origin.
--   capPopped, seedDropped, seedSettled,
--   tiltRoll,                       -- degrees, A/D adjusted while grabbed
--   grabbed,                        -- true while LMB is held on the capsule
--   rubble        = { ent, ... },   -- ring clumps
--   rubbleAnim    = { [i] = { t0, fromX, fromY, fromZ } },
--   rubbleArrived = { [i] = bool },
--   phase = "cap" | "tilt" | "wait_seed" | "soil" | "done",
--   cursorX, cursorY, held,
-- }

local CAPSULE_DEPTH = 1.0    -- metres in front of the cutting cam
local SEED_SETTLE_VELOCITY   = 0.05
local SEED_SETTLE_FRAMES     = 20
local SEED_SETTLE_TIMEOUT_MS = 4000  -- hard cap so we always advance even
                                     -- if the proxy keeps micro-rolling
local RUBBLE_TRAVEL_MS     = 450
local CAP_PROXY_MODEL      = "prop_golf_ball"
local MAX_TILT_ROLL        = 180.0  -- player can rotate fully upside-down

local PLANT_CAPSULE_REST_Z = 0.5    -- metres above pot base; clears the
                                    -- rim when flipped upside-down so the
                                    -- seed can fall in.

function GetPlantingCamPreset(spot, _drugCfg)
    local sceneCfg = (Config.PlantScene and Config.PlantScene.planting) or {}
    local cam = sceneCfg.camera or {}
    local fov = cam.fov or 38.0
    local potHash = joaat("pickle_pot_01")
    local pMin, pMax = GetModelDimensions(potHash)
    local center  = vector3(spot.coords.x, spot.coords.y, spot.coords.z)
    local heading = spot.coords.w or 0.0

    local sceneBotZ = center.z + pMin.z
    local sceneTopZ = center.z + PLANT_CAPSULE_REST_Z + 0.18
    local sceneH    = sceneTopZ - sceneBotZ
    local sceneW    = math.max(pMax.x - pMin.x, pMax.y - pMin.y, 0.4)

    local aimZ = (sceneTopZ + sceneBotZ) * 0.5
    local aspect = GetAspectRatio(false) or 1.777
    local fitH = (sceneH * 0.5) / math.tan(math.rad(fov) * 0.5)
    local fitW = (sceneW * 0.5) / math.tan(math.rad(fov) * 0.5) / aspect
    local distance = math.max(fitH, fitW) * (cam.distanceMul or 1.0)

    local rad = math.rad(heading)
    local camX = center.x + math.sin(rad) * distance
    local camY = center.y - math.cos(rad) * distance
    local camZ = aimZ + (cam.heightOffset or 1.0)
    local lookZ = aimZ + (cam.lookOffset or 0.0)

    return {
        coords = vector3(camX, camY, camZ),
        point  = vector3(center.x, center.y, lookZ),
        fov    = fov,
    }
end

local function CreatePlantingCam(center, heading, drugCfg)
    local pose = GetPlantingCamPreset({ coords = vector4(center.x, center.y, center.z, heading) }, drugCfg)
    local cam = CreateCam("DEFAULT_SCRIPTED_CAMERA", true)
    SetCamCoord(cam, pose.coords.x, pose.coords.y, pose.coords.z)
    PointCamAtCoord(cam, pose.point.x, pose.point.y, pose.point.z)
    SetCamFov(cam, pose.fov)
    SetCamActive(cam, true)
    RenderScriptCams(true, false, 0, true, true)
    return cam, pose.fov
end

local function SpawnCapsuleTrio(_drugCfg, anchor)
    local c = Config.PlantScene and Config.PlantScene.planting and Config.PlantScene.planting.capsule
    if not c then return end
    local capsuleHash = LoadModel(c.capsule)
    local capHash     = LoadModel(c.cap)
    local seedHash    = LoadModel(c.seed)
    if not capsuleHash or not capHash or not seedHash then return end

    local capsule = CreateObject(capsuleHash, anchor.x, anchor.y, anchor.z, false, false, false)
    -- Collision stays on so the cursor's camera ray can hit-test the
    -- capsule (for both cap-pop clicks and grab-to-drag in the tilt phase).
    -- The capsule is frozen so the player can't push it physically.
    SetEntityCollision(capsule, true, false)
    FreezeEntityPosition(capsule, true)

    -- Cap and seed are attached at identity offsets — the source models all
    -- render at the same world coords by design, so an identity attach
    -- keeps the trio rigidly together until we detach a piece.
    local cap = CreateObject(capHash, anchor.x, anchor.y, anchor.z, false, false, false)
    SetEntityCollision(cap, false, false)
    AttachEntityToEntity(cap, capsule, 0,
        0.0, 0.0, 0.0,
        0.0, 0.0, 0.0,
        false, false, false, false, 2, true)

    local seed = CreateObject(seedHash, anchor.x, anchor.y, anchor.z, false, false, false)
    SetEntityCollision(seed, false, false)
    AttachEntityToEntity(seed, capsule, 0,
        0.0, 0.0, 0.0,
        0.0, 0.0, 0.0,
        false, false, false, false, 2, true)

    -- Cap-region centre in capsule-local space. Cap is attached at
    -- identity, so its visual position is purely the cap model's geometric
    -- offset from its origin — read it once via GetModelDimensions and
    -- reuse it as the proxy's local-space anchor.
    local cMin, cMax = GetModelDimensions(capHash)
    local capLocal = vector3(
        (cMin.x + cMax.x) * 0.5,
        (cMin.y + cMax.y) * 0.5,
        (cMin.z + cMax.z) * 0.5)

    SetModelAsNoLongerNeeded(capsuleHash)
    SetModelAsNoLongerNeeded(capHash)
    SetModelAsNoLongerNeeded(seedHash)
    return capsule, cap, seed, capLocal
end

local function SpawnCapProxy(capsule, capLocal)
    if not capsule or not capLocal then return nil end
    local hash = LoadModel(CAP_PROXY_MODEL)
    if not hash then return nil end
    local w = GetOffsetFromEntityInWorldCoords(capsule, capLocal.x, capLocal.y, capLocal.z)
    local proxy = CreateObject(hash, w.x, w.y, w.z, false, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not proxy or not DoesEntityExist(proxy) then return nil end
    SetEntityCollision(proxy, true, false)
    FreezeEntityPosition(proxy, true)
    SetEntityVisible(proxy, Config.Debug == true, false)
    return proxy
end

local function RefreshCapProxy()
    if not PlantState or PlantState.capPopped then return end
    local proxy   = PlantState.capProxy
    local capsule = PlantState.capsule
    local off     = PlantState.capProxyOffset
    if not proxy or not capsule or not off then return end
    if not DoesEntityExist(proxy) or not DoesEntityExist(capsule) then return end
    local w = GetOffsetFromEntityInWorldCoords(capsule, off.x, off.y, off.z)
    SetEntityCoordsNoOffset(proxy, w.x, w.y, w.z, false, false, false)
end

local function SpawnRubbleRing(_drugCfg, center)
    local cfg = (Config.PlantScene and Config.PlantScene.planting) or {}
    local model = cfg.rubble
    if not model then return {} end
    local hash = LoadModel(model)
    if not hash then return {} end

    local count  = cfg.rubbleCount or 4
    local radius = cfg.rubbleRadius or 0.09
    local zOff = cfg.rubbleSoilZ or 0.0
    PlantState.rubbleZOff = zOff

    local out = {}
    for i = 1, count do
        local theta = (i - 1) * (2.0 * math.pi / count)
        local x = center.x + math.cos(theta) * radius
        local y = center.y + math.sin(theta) * radius
        local z = center.z + zOff
        local ent = CreateObjectNoOffset(hash, x, y, z, false, false, false)
        if ent and DoesEntityExist(ent) then
            SetEntityCollision(ent, true, false)
            FreezeEntityPosition(ent, true)
            out[i] = ent
        end
    end
    SetModelAsNoLongerNeeded(hash)
    return out
end

local function CleanupPlantingScene(skipFade)
    if not PlantState then return end
    if PlantState.tearingDown then return end
    PlantState.tearingDown = true

    local embedded = PlantState.embedded
    local onClose  = PlantState.onClose
    local fadeMs = 400
    if not skipFade and not embedded then
        DoScreenFadeOut(fadeMs)
        while not IsScreenFadedOut() do Wait(0) end
    end

    if not embedded then
        RenderScriptCams(false, false, 0, true, true)
        if PlantState.cam then DestroyCam(PlantState.cam, false) end
    end

    local toDelete = {}
    if PlantState.capsule  then toDelete[#toDelete + 1] = PlantState.capsule end
    if PlantState.cap      then toDelete[#toDelete + 1] = PlantState.cap end
    if PlantState.seed     then toDelete[#toDelete + 1] = PlantState.seed end
    if PlantState.capProxy then toDelete[#toDelete + 1] = PlantState.capProxy end
    if PlantState.seedProxy then toDelete[#toDelete + 1] = PlantState.seedProxy end
    for _, r in ipairs(PlantState.rubble or {}) do toDelete[#toDelete + 1] = r end
    for _, ent in ipairs(toDelete) do
        if ent and DoesEntityExist(ent) then DeleteEntity(ent) end
    end

    if SetPlotRubbleVisible then SetPlotRubbleVisible(PlantState.plotId, true) end

    if not embedded then
        SetNuiFocus(false, false)
        SendNUIMessage({ action = "closePlanting" })

        local ped = PlayerPedId()
        FreezeEntityPosition(ped, false)
        SetEntityVisible(ped, true, false)
        DisplayRadar(true)
        DisplayHud(true)
        ClearFocus()

        if not skipFade then DoScreenFadeIn(fadeMs) end
    end
    PlantState = nil
    if onClose then onClose() end
end

function CancelPlantingScene()
    if PlantState then CleanupPlantingScene(true) end
end

--- Camera-basis math copied from modules/watering. Returns:
---   camCoord   — camera world position
---   point      — a world point at `depth` along the cursor ray (used for
---                ray-cast hit-testing only, NOT for placing the capsule)
---   fwd        — camera forward unit vector
local function CursorToWorldPoint(cx, cy, depth, fovDeg)
    local camCoord = GetCamCoord(PlantState.cam)
    local camRot   = GetCamRot(PlantState.cam, 2)
    local rx, _, rz = math.rad(camRot.x), math.rad(camRot.y), math.rad(camRot.z)
    local fx = -math.sin(rz) * math.cos(rx)
    local fy =  math.cos(rz) * math.cos(rx)
    local fz =  math.sin(rx)
    local rXx, rXy, rXz = math.cos(rz), math.sin(rz), 0.0
    local upX = rXy * fz - rXz * fy
    local upY = rXz * fx - rXx * fz
    local upZ = rXx * fy - rXy * fx

    local fovRad = math.rad(fovDeg or 38.0)
    local screenH = math.tan(fovRad * 0.5) * depth
    local aspect  = GetAspectRatio(false) or 1.777
    local screenW = screenH * aspect
    local sx = (cx - 0.5) * 2.0 * screenW
    local sy = (cy - 0.5) * 2.0 * screenH

    local px = camCoord.x + fx * depth + rXx * sx - upX * sy
    local py = camCoord.y + fy * depth + rXy * sx - upY * sy
    local pz = camCoord.z + fz * depth + rXz * sx - upZ * sy
    return camCoord, vector3(px, py, pz), vector3(fx, fy, fz)
end

--- Capsule placement during drag. Unlike CursorToWorldPoint (which puts
--- the point on the camera's screen plane and therefore drifts toward /
--- away from the camera as the cursor moves vertically with a tilted-down
--- camera), this maps cursor X/Y to:
---   X → ground-horizontal axis perpendicular to camera→pot (no Z)
---   Y → world Z (purely vertical)
--- The result is anchored at PlantState.restAnchor so the capsule's
--- distance from the camera stays constant regardless of where the cursor
--- is on screen.
local function CursorToCapsulePos(cx, cy, fovDeg)
    local anchor = PlantState.restAnchor
    local camCoord = GetCamCoord(PlantState.cam)
    local camRot   = GetCamRot(PlantState.cam, 2)
    local rz = math.rad(camRot.z)
    -- Ground-parallel right vector (yaw only).
    local rXx, rXy = math.cos(rz), math.sin(rz)

    -- Distance from camera to the rest anchor along the ground plane —
    -- used to size cursor offsets so a fixed cursor delta corresponds to
    -- roughly the same on-screen movement regardless of camera distance.
    local dx, dy = anchor.x - camCoord.x, anchor.y - camCoord.y
    local depth = math.max(0.5, math.sqrt(dx * dx + dy * dy))

    local fovRad = math.rad(fovDeg or 38.0)
    local screenH = math.tan(fovRad * 0.5) * depth
    local aspect  = GetAspectRatio(false) or 1.777
    local screenW = screenH * aspect
    local sx = (cx - 0.5) * 2.0 * screenW
    local sy = (cy - 0.5) * 2.0 * screenH

    local px = anchor.x + rXx * sx
    local py = anchor.y + rXy * sx
    local pz = anchor.z - sy
    return vector3(px, py, pz)
end

--- Recompute restAnchor so that the current cursor position maps to the
--- capsule's current world position. Called on every grab press so the
--- capsule doesn't jump to the cursor — it stays put and tracks deltas
--- from there.
local function RebaseAnchorToCurrent(cx, cy, fovDeg)
    if not PlantState or not PlantState.capsule then return end
    if not DoesEntityExist(PlantState.capsule) then return end
    local capPos   = GetEntityCoords(PlantState.capsule)
    local camCoord = GetCamCoord(PlantState.cam)
    local camRot   = GetCamRot(PlantState.cam, 2)
    local rz       = math.rad(camRot.z)
    local rXx, rXy = math.cos(rz), math.sin(rz)

    local dx, dy = capPos.x - camCoord.x, capPos.y - camCoord.y
    local depth  = math.max(0.5, math.sqrt(dx * dx + dy * dy))

    local fovRad  = math.rad(fovDeg or 38.0)
    local screenH = math.tan(fovRad * 0.5) * depth
    local aspect  = GetAspectRatio(false) or 1.777
    local screenW = screenH * aspect
    local sx = (cx - 0.5) * 2.0 * screenW
    local sy = (cy - 0.5) * 2.0 * screenH

    PlantState.restAnchor = vector3(
        capPos.x - rXx * sx,
        capPos.y - rXy * sx,
        capPos.z + sy)
end

local function PopCap()
    if not PlantState or PlantState.capPopped then return end
    PlantState.capPopped = true
    PlantState.phase = "tilt"
    -- The proxy is no longer needed once the cap is gone; remove it
    -- before the cap detaches so the next frame's RefreshCapProxy is a
    -- cheap no-op.
    if PlantState.capProxy and DoesEntityExist(PlantState.capProxy) then
        DeleteEntity(PlantState.capProxy)
    end
    PlantState.capProxy = nil

    local cap = PlantState.cap
    if not cap or not DoesEntityExist(cap) then return end
    DetachEntity(cap, true, true)
    SetEntityCollision(cap, true, true)
    FreezeEntityPosition(cap, false)
    SetEntityHasGravity(cap, true)
    ActivatePhysics(cap)
    -- A small upward + outward kick so it visibly pops off rather than
    -- just dropping. Direction is camera-relative so it always reads as
    -- "forward and up" from the player's view.
    local _, _, fwd = CursorToWorldPoint(0.5, 0.5, 1.0, 38.0)
    ApplyForceToEntity(cap, 1, fwd.x * 0.05, fwd.y * 0.05, 0.5, 0.0, 0.0, 0.0, 0, false, true, true, false, true)
end

local function SwapSeedToProxy()
    if not PlantState or PlantState.seedProxy then return end
    local seed = PlantState.seed
    if not seed or not DoesEntityExist(seed) then return end

    local seedPos = GetEntityCoords(seed)
    local hash = LoadModel(CAP_PROXY_MODEL)
    if not hash then return end
    local proxy = CreateObject(hash, seedPos.x, seedPos.y, seedPos.z, false, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not proxy or not DoesEntityExist(proxy) then return end

    -- Park the seed: turn off its own physics + collision and freeze it.
    -- The main thread copies the proxy's position onto the seed each
    -- frame (same pattern as the cap proxy in reverse), which keeps the
    -- seed visually present where attachment would hide it.
    SetEntityCollision(seed, false, false)
    FreezeEntityPosition(seed, true)
    SetEntityCoordsNoOffset(seed, seedPos.x, seedPos.y, seedPos.z, false, false, false)

    SetEntityVisible(proxy, Config.Debug == true, false)
    SetEntityCollision(proxy, true, true)
    SetEntityHasGravity(proxy, true)
    ActivatePhysics(proxy)
    PlantState.seedProxy = proxy
end

local function DropSeed()
    if not PlantState or PlantState.seedDropped then return end
    PlantState.seedDropped = true
    PlantState.phase = "wait_seed"
    PlantState.waitSeedStart = GetGameTimer()
    local seed = PlantState.seed
    if not seed or not DoesEntityExist(seed) then return end

    -- Drop the seed under its own physics first so it visibly exits the
    -- capsule. After a brief delay we swap it onto a golf-ball proxy
    -- whose spherical collider settles cleanly on the soil.
    DetachEntity(seed, true, true)
    SetEntityCollision(seed, true, true)
    FreezeEntityPosition(seed, false)
    SetEntityHasGravity(seed, true)
    ActivatePhysics(seed)

    SetTimeout(200, function() SwapSeedToProxy() end)
end

local function EnterSoilPhase()
    if not PlantState or PlantState.phase == "soil" or PlantState.phase == "done" then return end
    PlantState.phase = "soil"
    PlantState.rubble        = SpawnRubbleRing(PlantState.drugCfg, PlantState.plotCenter)
    PlantState.rubbleAnim    = {}
    PlantState.rubbleArrived = {}

    -- The golf-ball proxy did its job (settling the seed somewhere on the
    -- soil); now the rubble takes over and the seed gets snapped to the
    -- pot centre at the same Z the rubble uses, so the convergence reads
    -- as the seed being buried under the pile.
    if PlantState.seedProxy and DoesEntityExist(PlantState.seedProxy) then
        DeleteEntity(PlantState.seedProxy)
    end
    PlantState.seedProxy = nil
    if PlantState.seed and DoesEntityExist(PlantState.seed) then
        local zOff = PlantState.rubbleZOff or 0.0
        local seedZ = (Config.PlantScene and Config.PlantScene.planting and Config.PlantScene.planting.seedZ) or 0.0
        SetEntityCoordsNoOffset(PlantState.seed,
            PlantState.plotCenter.x,
            PlantState.plotCenter.y,
            PlantState.plotCenter.z + zOff + seedZ,
            false, false, false)
    end
end

local function FinishScene()
    if not PlantState or PlantState.phase == "done" then return end
    PlantState.phase = "done"
    -- Server flips stage_started_at; the next plot:update broadcast will
    -- spawn the persistent rubble pile (currently hidden) and the scene's
    -- own ring set is deleted in CleanupPlantingScene.
    TriggerServerEvent("pickle_drugs:plant", PlantState.plotId)
    -- Brief hold so the converged ring reads on screen before fade.
    SetTimeout(250, function() CleanupPlantingScene() end)
end

--- Returns true if the cursor's camera ray hits `targetEntity`. Used to
--- gate cap-pop clicks (proxy entity at the cap's visual centre) and the
--- grab-to-drag (capsule body itself).
local function CursorHitsEntity(cx, cy, fovDeg, targetEntity)
    if not targetEntity or not DoesEntityExist(targetEntity) then return false end
    local camCoord, point = CursorToWorldPoint(cx, cy, 1.0, fovDeg)
    local dx, dy, dz = point.x - camCoord.x, point.y - camCoord.y, point.z - camCoord.z
    local dlen = math.sqrt(dx * dx + dy * dy + dz * dz)
    if dlen <= 0 then return false end
    dx, dy, dz = dx / dlen, dy / dlen, dz / dlen
    local range = 8.0
    local handle = StartShapeTestRay(
        camCoord.x, camCoord.y, camCoord.z,
        camCoord.x + dx * range, camCoord.y + dy * range, camCoord.z + dz * range,
        1 | 8 | 16, PlayerPedId(), 4)
    local _, hit, _, _, entity = GetShapeTestResult(handle)
    return hit == 1 and entity == targetEntity
end

local function HitTestRubble(cx, cy, fovDeg)
    local camCoord, point, _ = CursorToWorldPoint(cx, cy, 1.0, fovDeg)
    local dx, dy, dz = point.x - camCoord.x, point.y - camCoord.y, point.z - camCoord.z
    local dlen = math.sqrt(dx * dx + dy * dy + dz * dz)
    if dlen <= 0 then return nil end
    dx, dy, dz = dx / dlen, dy / dlen, dz / dlen

    local rubbleByEntity = {}
    for i, ent in ipairs(PlantState.rubble or {}) do
        if not PlantState.rubbleArrived[i] and ent and DoesEntityExist(ent) then
            rubbleByEntity[ent] = i
        end
    end

    local range = 6.0
    local fX, fY, fZ = camCoord.x, camCoord.y, camCoord.z
    for _ = 1, 4 do
        local tX, tY, tZ = camCoord.x + dx * range, camCoord.y + dy * range, camCoord.z + dz * range
        local handle = StartShapeTestRay(fX, fY, fZ, tX, tY, tZ, 1 | 8 | 16, PlayerPedId(), 4)
        local _, hit, endCoords, _, entity = GetShapeTestResult(handle)
        if hit ~= 1 then return nil end
        local idx = rubbleByEntity[entity]
        if idx then return idx end
        -- Step past anything else (pot/soil/etc) and keep going — rubble
        -- sits flush with the soil and could be partially occluded by it.
        fX = endCoords.x + dx * 0.02
        fY = endCoords.y + dy * 0.02
        fZ = endCoords.z + dz * 0.02
    end
    return nil
end

local function StartRubbleAnim(idx)
    local ent = PlantState.rubble[idx]
    if not ent or not DoesEntityExist(ent) then return end
    local c = GetEntityCoords(ent)
    PlantState.rubbleAnim[idx] = { t0 = GetGameTimer(), fromX = c.x, fromY = c.y, fromZ = c.z }
end

local function TickRubbleAnims()
    if not PlantState or not PlantState.rubbleAnim then return end
    local nowMs   = GetGameTimer()
    local doneCount = 0
    for i, ent in ipairs(PlantState.rubble or {}) do
        local anim = PlantState.rubbleAnim[i]
        if PlantState.rubbleArrived[i] then
            doneCount = doneCount + 1
        elseif anim and ent and DoesEntityExist(ent) then
            local t = math.min(1.0, (nowMs - anim.t0) / RUBBLE_TRAVEL_MS)
            -- Smoothstep so the clumps decelerate as they meet at centre.
            local s = t * t * (3.0 - 2.0 * t)
            -- Z is pinned to the clump's spawn Z so the ring slides flat
            -- across the soil rather than rising as it converges. XY
            -- closes to `rubbleConvergeK` of the way to centre — anything
            -- short of 1 leaves a residual ring so clumps pile against
            -- each other rather than stacking at a single point.
            local k = (Config.PlantScene and Config.PlantScene.planting and Config.PlantScene.planting.rubbleConvergeK) or 0.95
            local x = anim.fromX + (PlantState.plotCenter.x - anim.fromX) * s * k
            local y = anim.fromY + (PlantState.plotCenter.y - anim.fromY) * s * k
            local z = anim.fromZ
            SetEntityCoordsNoOffset(ent, x, y, z, false, false, false)
            if t >= 1.0 then
                PlantState.rubbleArrived[i] = true
                doneCount = doneCount + 1
            end
        end
    end
    if doneCount >= #PlantState.rubble and #PlantState.rubble > 0 and PlantState.phase == "soil" then
        FinishScene()
    end
end

local function RunPlantingThread()
    CreateThread(function()
        local lastTime    = GetGameTimer()
        local rotateSpeed = 120.0   -- deg/sec, A/D — bumped so reaching 180°
                                    -- doesn't feel like a slog.
        local maxRoll     = MAX_TILT_ROLL
        local settleHits  = 0

        while PlantState do
            DisableAllControlActions(0)
            local nowMs = GetGameTimer()
            local dt    = (nowMs - lastTime) / 1000.0
            lastTime    = nowMs

            local cx, cy = PlantState.cursorX or 0.5, PlantState.cursorY or 0.5

            -- Capsule pose only updates while the player is actively
            -- holding LMB on the capsule. Otherwise it stays where it was
            -- last placed — both at scene start (above the pot) and after
            -- the player releases mid-tilt. A/D roll is also gated on
            -- `grabbed` so the capsule can't be tilted from a distance.
            if PlantState.grabbed and PlantState.capsule and DoesEntityExist(PlantState.capsule) then
                local world = CursorToCapsulePos(cx, cy, 38.0)
                local _, _, fwd = CursorToWorldPoint(cx, cy, CAPSULE_DEPTH, 38.0)
                if PlantState.held and PlantState.held["KeyA"] then
                    PlantState.tiltRoll = math.max(-maxRoll, (PlantState.tiltRoll or 0) - rotateSpeed * dt)
                end
                if PlantState.held and PlantState.held["KeyD"] then
                    PlantState.tiltRoll = math.min( maxRoll, (PlantState.tiltRoll or 0) + rotateSpeed * dt)
                end
                SetEntityCoordsNoOffset(PlantState.capsule, world.x, world.y, world.z, false, false, false)
                SetEntityRotation(PlantState.capsule,
                    0.0,
                    PlantState.tiltRoll or 0.0,
                    math.deg(math.atan(fwd.y, fwd.x)) - 90.0,
                    2, true)
            end

            -- Tilt-to-drop trigger. Once |roll| crosses tiltDropDeg we
            -- snap the capsule fully upside-down (sign-preserving ±180°)
            -- so the seed falls cleanly straight down rather than off at
            -- whatever odd angle the player happened to release at.
            if PlantState.phase == "tilt" then
                local dropDeg = (Config.PlantScene and Config.PlantScene.planting and Config.PlantScene.planting.tiltDropDeg) or 165.0
                local roll = PlantState.tiltRoll or 0.0
                if math.abs(roll) >= dropDeg then
                    PlantState.tiltRoll = (roll >= 0) and 180.0 or -180.0
                    if PlantState.capsule and DoesEntityExist(PlantState.capsule) then
                        local _, _, fwd = CursorToWorldPoint(
                            PlantState.cursorX or 0.5, PlantState.cursorY or 0.5,
                            CAPSULE_DEPTH, 38.0)
                        SetEntityRotation(PlantState.capsule,
                            0.0, PlantState.tiltRoll,
                            math.deg(math.atan(fwd.y, fwd.x)) - 90.0,
                            2, true)
                    end
                    DropSeed()
                end
            end

            -- Cap proxy follows the capsule's rotation each frame so the
            -- click target stays glued to the cap's visual centre.
            RefreshCapProxy()

            -- Seed visually rides the golf-ball proxy. Proxy is the
            -- physics body; seed is frozen and copied onto it.
            if PlantState.seedProxy and PlantState.seed
                and DoesEntityExist(PlantState.seedProxy)
                and DoesEntityExist(PlantState.seed) then
                local p = GetEntityCoords(PlantState.seedProxy)
                SetEntityCoordsNoOffset(PlantState.seed, p.x, p.y, p.z, false, false, false)
            end

            -- Wait for seed to settle on the soil.
            if PlantState.phase == "wait_seed" then
                local settleEnt = PlantState.seedProxy or PlantState.seed
                if settleEnt and DoesEntityExist(settleEnt) then
                    local v = GetEntityVelocity(settleEnt)
                    local mag = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
                    if mag <= SEED_SETTLE_VELOCITY then
                        settleHits = settleHits + 1
                    else
                        settleHits = 0
                    end
                end
                local elapsed = nowMs - (PlantState.waitSeedStart or nowMs)
                if settleHits >= SEED_SETTLE_FRAMES or elapsed >= SEED_SETTLE_TIMEOUT_MS then
                    EnterSoilPhase()
                end
            end

            if PlantState.phase == "soil" then
                TickRubbleAnims()
            end

            Wait(0)
        end
    end)
end

--- Public entry. Wired into modules/grow/client's "Plant seed" target.
---@param plotId string
function OpenPlantingScene(plotId, opts)
    if PlantState then return end
    opts = opts or {}
    local embedded = opts.embedded == true

    local plot = GetPlotState(plotId)
    local spot = GetPlotSpot(plotId)
    if not plot or not spot then return end
    local drugCfg = Config.Drugs[plot.drug]
    local sceneCfg = Config.PlantScene and Config.PlantScene.planting
    if not drugCfg or not sceneCfg or not sceneCfg.capsule then return end
    if (plot.stage_started_at or 0) ~= 0 then return end

    local center = vector3(spot.coords.x, spot.coords.y, spot.coords.z)
    local heading = spot.coords.w or 0.0
    local fadeMs = 400

    if not embedded then
        DoScreenFadeOut(fadeMs)
        while not IsScreenFadedOut() do Wait(0) end

        local ped = PlayerPedId()
        FreezeEntityPosition(ped, true)
        SetEntityVisible(ped, false, false)
        DisplayRadar(false)
        DisplayHud(false)
        SetFocusArea(center.x, center.y, center.z, 0.0, 0.0, 0.0)
    end

    local cam = embedded and opts.cam or CreatePlantingCam(center, heading, drugCfg)
    local capsule, cap, seed, capLocal = SpawnCapsuleTrio(drugCfg, vector3(center.x, center.y, center.z + 1.5))
    local capProxy = SpawnCapProxy(capsule, capLocal)

    PlantState = {
        plotId         = plotId,
        spot           = spot,
        drugCfg        = drugCfg,
        cam            = cam,
        capsule        = capsule,
        cap            = cap,
        seed           = seed,
        capProxy       = capProxy,
        capProxyOffset = capLocal,
        capPopped     = false,
        seedDropped   = false,
        rubble        = {},
        rubbleAnim    = {},
        rubbleArrived = {},
        tiltRoll      = 0.0,
        phase         = "cap",
        cursorX       = 0.5,
        cursorY       = 0.5,
        held          = {},
        plotCenter    = center,
        restAnchor    = vector3(center.x, center.y, center.z + PLANT_CAPSULE_REST_Z),
        embedded      = embedded,
        onClose       = opts.onClose,
    }

    -- Park the capsule directly above the pot opening so a fully-tilted
    -- capsule drops the seed straight into the soil. X/Y match the plot
    -- centre; only Z is offset upward. Z is well below the camera height
    -- (camZ ≈ center.z + 1.0) so the capsule renders in frame above the
    -- pot. The per-frame loop only updates pose while grabbed, so this is
    -- the resting state until the player picks it up.
    if capsule then
        local capZ = center.z + PLANT_CAPSULE_REST_Z
        SetEntityCoordsNoOffset(capsule, center.x, center.y, capZ, false, false, false)
        -- Face the capsule toward the camera. The cam sits opposite the
        -- heading direction (cos/sin signs flipped), so heading itself is
        -- the right yaw to make the capsule "look at" the camera.
        SetEntityRotation(capsule, 0.0, 0.0, heading, 2, true)
    end

    -- Persistent rubble would only appear after server bumps stage_started_at,
    -- but hide it pre-emptively in case a stale cache shows them; re-enabled
    -- on cleanup.
    if SetPlotRubbleVisible then SetPlotRubbleVisible(plotId, false) end

    if not embedded then
        SetNuiFocus(true, true)
        SendNUIMessage({ action = "openPlanting", data = { plotId = plotId } })
        DoScreenFadeIn(fadeMs)
    end
    RunPlantingThread()
end

-- ─── NUI callbacks ──────────────────────────────────────────────────────────

RegisterNUICallback("plantingClose", function(_, cb)
    CleanupPlantingScene()
    cb({ ok = true })
end)

RegisterNUICallback("plantingInput", function(data, cb)
    if not PlantState then cb({ ok = false }) return end
    if data.cursorX and data.cursorY then
        PlantState.cursorX = tonumber(data.cursorX)
        PlantState.cursorY = tonumber(data.cursorY)
    end
    if data.heldKeys then
        PlantState.held = {}
        for _, k in ipairs(data.heldKeys) do PlantState.held[k] = true end
    end
    cb({ ok = true })
end)

--- Mouse press / release routed by phase:
---   pressed=true  + cap   phase + ray on capsule → pop cap
---   pressed=true  + tilt  phase + ray on capsule → grab (start dragging)
---   pressed=true  + soil  phase + ray on rubble  → start that clump's anim
---   pressed=false                                → release grab
--- Clicks that miss the capsule / rubble do nothing — the capsule is not
--- magnetised to the cursor and only follows it while grabbed.
RegisterNUICallback("plantingClick", function(data, cb)
    if not PlantState then cb({ ok = false }) return end
    local pressed = data and data.pressed
    local cx = tonumber(data and data.x) or 0.5
    local cy = tonumber(data and data.y) or 0.5

    if not pressed then
        PlantState.grabbed = false
        cb({ ok = true })
        return
    end

    if PlantState.phase == "cap" then
        -- Cap-region click pops the cap; clicking the rest of the capsule
        -- still lets the player pick it up and reposition it. Test the
        -- proxy first because it sits inside the capsule's bounds — if we
        -- tested the capsule first the body would always shadow the cap.
        if CursorHitsEntity(cx, cy, 38.0, PlantState.capProxy) then
            PopCap()
            cb({ ok = true, hit = true })
            return
        elseif CursorHitsEntity(cx, cy, 38.0, PlantState.capsule) then
            RebaseAnchorToCurrent(cx, cy, 38.0)
            PlantState.grabbed = true
            cb({ ok = true, hit = true })
            return
        end
    elseif PlantState.phase == "tilt" then
        if CursorHitsEntity(cx, cy, 38.0, PlantState.capsule) then
            RebaseAnchorToCurrent(cx, cy, 38.0)
            PlantState.grabbed = true
            cb({ ok = true, hit = true })
            return
        end
    elseif PlantState.phase == "soil" then
        local idx = HitTestRubble(cx, cy, 38.0)
        if idx and not PlantState.rubbleAnim[idx] and not PlantState.rubbleArrived[idx] then
            StartRubbleAnim(idx)
            cb({ ok = true, hit = true })
            return
        end
    end

    cb({ ok = true, hit = false })
end)

AddEventHandler("onResourceStop", function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end
    CleanupPlantingScene(true)
end)
