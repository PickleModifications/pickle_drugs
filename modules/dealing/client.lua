-- Dealing client. Three responsibilities:
--   1. Spawn / despawn customer peds for accepted deals (visible to
--      everyone in the world; bucket 0).
--   2. Maintain the local zone/customer roster + an admin-side "preview"
--      renderer (zone circles + deal-point markers) that's only on while
--      the admin has the Dealing tab open.
--   3. Track the calling player's own deals (offered/negotiating/accepted)
--      and push them to the NUI: Messages app + DealsHud.

local Zones      = {}      -- id → row
local Customers  = {}      -- id → row
local MyDeals    = {}      -- dealId → row (deals owned by *this* player)

-- Spawned customer peds (one per active accepted deal). Keyed by deal id
-- so the despawn broadcast can map straight back.
local CustomerPeds = {}    -- dealId → { ped, blip, ownerCid }

-- Preview render toggle, switched on by NUI when the admin focuses the
-- Dealing tab. Off otherwise so we don't burn DrawMarker calls.
local PreviewOn      = false
local PreviewZoneId  = nil  -- zone currently being edited (highlight)

-- ─── Helpers ───────────────────────────────────────────────────────────────

local function loadModel(name)
    local hash = type(name) == "string" and joaat(name) or name
    if not hash or not IsModelInCdimage(hash) then return nil end
    RequestModel(hash)
    local deadline = GetGameTimer() + 5000
    while not HasModelLoaded(hash) and GetGameTimer() < deadline do Wait(0) end
    return HasModelLoaded(hash) and hash or nil
end

local function snapToGround(x, y, z)
    local found, gz = GetGroundZFor_3dCoord(x + 0.0, y + 0.0, z + 1.0, false)
    if found and gz and gz > 0.0 then return gz end
    return z
end

local function notify(msg, type_)
    lib.notify({ title = "Dealing", description = msg, type = type_ or "inform" })
end

local function pushHud()
    -- Snapshot of all of the calling player's currently-relevant deals.
    -- Sorted newest-first; the HUD trims to the top N visually.
    local list = {}
    for _, d in pairs(MyDeals) do list[#list + 1] = d end
    table.sort(list, function(a, b) return (a.created_at or 0) > (b.created_at or 0) end)
    SendNUIMessage({ action = "dealsHudUpdate", data = list })
    -- Unread badge on the phone Messages icon = count of offered /
    -- negotiating deals (accepted ones are visible in the HUD instead).
    local unread = 0
    for _, d in ipairs(list) do
        if d.state == "offered" or d.state == "negotiating" then unread = unread + 1 end
    end
    SendNUIMessage({ action = "messagesUnread", data = unread })
end

local function pushMessages()
    local list = {}
    for _, d in pairs(MyDeals) do list[#list + 1] = d end
    table.sort(list, function(a, b) return (a.created_at or 0) > (b.created_at or 0) end)
    SendNUIMessage({ action = "dealingMessages", data = {
        deals     = list,
        zones     = Zones,
        customers = Customers,
    } })
end

-- ─── Customer ped lifecycle ───────────────────────────────────────────────
--
-- Two-phase spawn:
--   1. dealingCustomerSpawn arrives → register a Pending entry with the
--      payload + (for the owner) drop a navigation blip immediately.
--      The ped itself is NOT created yet — at this point the player is
--      typically nowhere near the deal point, so the world isn't
--      streamed and a ground-Z probe would silently fall back to the
--      payload Z (often the admin-set zone Z, which floats in the air
--      or is buried inside terrain).
--   2. A polling thread checks distance to each pending payload. Once
--      the player is within streamRange, it forces collision to load
--      around the spot, probes the actual ground, then creates the ped
--      at the snapped Z. From this point the entry lives in CustomerPeds.
--
-- streamRange is intentionally generous (~80m default) so the ped is
-- already standing where it'll stay by the time the player can see it.

local PendingCustomers = {}  -- dealId → { payload, blip }

local function isMineFor(dealId, payload)
    -- "Is this my deal?" — true if server stamped owner_src matches our
    -- player id, or (fallback) if we have the deal in MyDeals.
    local myServerId = GetPlayerServerId(PlayerId())
    if payload and payload.owner_src and payload.owner_src == myServerId then return true end
    return MyDeals[dealId] ~= nil
end

local function makeBlipFor(payload)
    local pt = payload.pt
    local b = AddBlipForCoord(pt.x, pt.y, pt.z)
    SetBlipSprite(b, 108) -- briefcase
    SetBlipScale(b, 0.85)
    SetBlipColour(b, 5)   -- amber
    SetBlipAsShortRange(b, false)
    BeginTextCommandSetBlipName("STRING")
    AddTextComponentString("Customer · " ..
        (payload.customer.first_name or "") .. " " ..
        (payload.customer.last_name or ""))
    EndTextCommandSetBlipName(b)
    return b
end

--- Forces collision + ped chunks to load around (x,y,z) so the
--- subsequent ground-Z probe + CreatePed land on real geometry.
--- Bounded by ~1.5s so we don't hang the spawn thread forever if the
--- map streamer can't satisfy us (we'll fall back to payload Z then).
local function loadAround(x, y, z)
    RequestCollisionAtCoord(x + 0.0, y + 0.0, z + 0.0)
    NewLoadSceneStart(x + 0.0, y + 0.0, z + 0.0, 0.0, 0.0, 0.0, 50.0, 0)
    local deadline = GetGameTimer() + 1500
    while not HasCollisionLoadedAroundEntity(PlayerPedId()) and GetGameTimer() < deadline do
        Wait(0)
    end
    NewLoadSceneStop()
end

--- Probes a real ground Z above (x, y). Starts the probe well above
--- the configured Z so we hit the *terrain* surface rather than (e.g.)
--- a vehicle sitting on top of the spot. Returns the input Z if the
--- streamer hasn't loaded the area (the caller usually pre-flushes
--- via loadAround, but a return-to-fallback keeps the spawn from
--- failing silently).
local function findGround(x, y, z)
    for _, probeFromZ in ipairs({ z + 50.0, z + 200.0, z, z - 5.0 }) do
        local found, gz = GetGroundZFor_3dCoord(x + 0.0, y + 0.0, probeFromZ, false)
        if found and gz and gz > -100.0 then return gz end
    end
    return z
end

local function attachTargetTo(ped, dealId)
    if GetResourceState("ox_target") ~= "started" then return end
    exports.ox_target:addLocalEntity(ped, {
        {
            name     = "pickle_drugs:dealing_complete_" .. dealId,
            label    = "Complete Deal",
            icon     = "fa-solid fa-handshake",
            distance = 2.5,
            canInteract = function() return MyDeals[dealId] ~= nil end,
            onSelect = function()
                TriggerServerEvent("pickle_drugs:dealingComplete", dealId)
            end,
        },
    })
end

--- Realises a pending customer into a live ped. Called by the stream
--- thread when the player is close enough that the ground probe will
--- succeed and the ped will be visible immediately.
local function realisePending(dealId)
    local pending = PendingCustomers[dealId]
    if not pending then return end
    local payload = pending.payload
    local pt = payload.pt
    local hash = loadModel(payload.customer.model)
    if not hash then return end -- model load failed; thread will retry

    loadAround(pt.x, pt.y, pt.z)
    local gz = findGround(pt.x, pt.y, pt.z)
    local ped = CreatePed(4, hash, pt.x, pt.y, gz, pt.w or 0.0, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not ped or not DoesEntityExist(ped) then return end

    SetEntityInvincible(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedDefaultComponentVariation(ped)
    -- Position-frozen so the customer doesn't wander while waiting.
    -- No scenario started: scenarios lock the ped's heading and
    -- silently block SetEntityHeading / TaskAchieveHeading writes,
    -- which is exactly what was breaking the "face the player" turn.
    -- A frozen, scenario-less ped just stands in T-default-idle —
    -- still reads as "loitering on the corner" visually but accepts
    -- direct heading changes.
    FreezeEntityPosition(ped, true)
    attachTargetTo(ped, dealId)

    -- Move from pending → live, preserving the blip we created on
    -- accept (so the player kept their navigation marker while
    -- travelling).
    PendingCustomers[dealId] = nil
    CustomerPeds[dealId] = {
        ped         = ped,
        blip        = pending.blip,
        ownerSrc    = payload.owner_src,
        -- One-shot rotation flag — flipped true the first time the
        -- player is on-screen + within 10m, so we don't spin the
        -- ped on every poll cycle.
        facedPlayer = false,
        -- Set when the completion handler fires so other systems
        -- (rotation poller, ox_target) leave the ped alone while it
        -- does its anim → walk-away exit.
        completing  = false,
    }
end

local function spawnCustomer(payload)
    if not payload or not payload.deal_id or not payload.pt or not payload.customer then return end
    local dealId = payload.deal_id
    -- Idempotent: if already pending or live, ignore re-broadcasts (e.g.
    -- a playerJoining rehydrate after a reconnect).
    if CustomerPeds[dealId] or PendingCustomers[dealId] then return end

    local blip = isMineFor(dealId, payload) and makeBlipFor(payload) or nil
    PendingCustomers[dealId] = { payload = payload, blip = blip }
end

local function despawnCustomer(dealId)
    -- Clear from whichever bucket the deal is in.
    local pending = PendingCustomers[dealId]
    if pending then
        if pending.blip and DoesBlipExist(pending.blip) then RemoveBlip(pending.blip) end
        PendingCustomers[dealId] = nil
    end
    local entry = CustomerPeds[dealId]
    if entry then
        if entry.ped and DoesEntityExist(entry.ped) then
            if GetResourceState("ox_target") == "started" then
                exports.ox_target:removeLocalEntity(entry.ped)
            end
            DeleteEntity(entry.ped)
        end
        if entry.blip and DoesBlipExist(entry.blip) then RemoveBlip(entry.blip) end
        CustomerPeds[dealId] = nil
    end
end

--- Heading (degrees, GTA convention) needed for `from` to face `to`.
--- GTA heading 0 = +Y; positive heading rotates clockwise (as viewed
--- from above), so heading = atan2(-dx, dy) in degrees.
local function headingFacing(fromCoords, toCoords)
    local dx = toCoords.x - fromCoords.x
    local dy = toCoords.y - fromCoords.y
    return math.deg(math.atan2(-dx, dy))
end

local SMOOTH_TURN_MS    = 800
local SMOOTH_TURN_STEPS = 24    -- ~33ms / step → 800ms total turn

--- Smoothly rotates a customer ped to face `targetEntity`.
---
--- Tasks (scenarios, animations, walk-to-coord, …) all clamp the
--- ped's heading internally — direct SetEntityHeading writes get
--- stomped on the next frame. So the very first thing we do is
--- ClearPedTasks to drop the ped out of whatever it's doing; then
--- the heading is interpolated frame-by-frame along an eased curve
--- so the rotation looks deliberate rather than snapped.
---
--- The position freeze must be off during the rotation too — frozen
--- entities ignore both task and direct rotation writes. We toggle
--- the freeze around the interp and (for non-completion turns) put
--- the freeze back at the end so the ped doesn't wander after.
function smoothTurnTowards(entry, targetEntity)
    if not entry or not entry.ped or not DoesEntityExist(entry.ped) then return end
    if not targetEntity or not DoesEntityExist(targetEntity) then return end
    local ped = entry.ped
    CreateThread(function()
        ClearPedTasks(ped)
        FreezeEntityPosition(ped, false)
        Wait(0)

        local startHdg   = GetEntityHeading(ped)
        local targetHdg  = headingFacing(GetEntityCoords(ped), GetEntityCoords(targetEntity))
        local delta = ((targetHdg - startHdg + 540) % 360) - 180
        local stepMs = math.max(16, math.floor(SMOOTH_TURN_MS / SMOOTH_TURN_STEPS))

        for i = 1, SMOOTH_TURN_STEPS do
            if not DoesEntityExist(ped) then return end
            local t = i / SMOOTH_TURN_STEPS
            local e = (t < 0.5) and (4 * t * t * t)
                                  or (1 - ((-2 * t + 2) ^ 3) / 2)
            SetEntityHeading(ped, startHdg + delta * e)
            Wait(stepMs)
        end
        if not DoesEntityExist(ped) then return end
        SetEntityHeading(ped, targetHdg)
        -- Re-freeze only for "look at me" rotations — the completion
        -- handler wants the ped unfrozen for the upcoming anim +
        -- walk-away.
        if not entry.completing then
            FreezeEntityPosition(ped, true)
        end
    end)
end

-- ── Stream / LOS / face-player poller ────────────────────────────────────
-- Two responsibilities, both keyed off proximity to the player:
--   1. Promote pending customers to live peds once the player is
--      close enough that the spawn lands on visible terrain.
--   2. For each live customer, rotate it ONCE to face the player the
--      first time we have clear LOS — keeps the ped from staring off
--      into the void as the player walks up to it. The `facedPlayer`
--      flag prevents repeat spins on subsequent poll cycles.
CreateThread(function()
    while true do
        Wait(500)
        local me = PlayerPedId()
        if me and DoesEntityExist(me) then
            local mc = GetEntityCoords(me)

            -- (1) Stream-in promotion.
            if next(PendingCustomers) ~= nil then
                local range = (Config.Dealing and Config.Dealing.streamRange) or 80.0
                for dealId, pending in pairs(PendingCustomers) do
                    local pt = pending.payload.pt
                    local dx, dy, dz = mc.x - pt.x, mc.y - pt.y, mc.z - pt.z
                    if (dx * dx + dy * dy + dz * dz) <= (range * range) then
                        realisePending(dealId)
                    end
                end
            end

            -- (2) Face-the-player one-shot rotation. Triggers the
            -- moment the customer ped is BOTH on-screen AND inside
            -- 10m. The earlier LOS-based check failed too often on
            -- street corners (street furniture / lamp posts blocked
            -- the trace) — visibility + proximity captures the same
            -- "the player has seen me" intent without false negatives.
            -- Skip peds mid-completion (their anim/walk takes over).
            for _, entry in pairs(CustomerPeds) do
                if not entry.facedPlayer and not entry.completing
                    and entry.ped and DoesEntityExist(entry.ped)
                then
                    local pc = GetEntityCoords(entry.ped)
                    local dx, dy, dz = mc.x - pc.x, mc.y - pc.y, mc.z - pc.z
                    if (dx * dx + dy * dy + dz * dz) <= 100 -- 10m squared
                        and IsEntityOnScreen(entry.ped)
                    then
                        -- Mark first so the next poll tick doesn't
                        -- queue another rotation while this one is
                        -- still mid-interpolation.
                        entry.facedPlayer = true
                        smoothTurnTowards(entry, me)
                    end
                end
            end
        end
    end
end)

-- ── Completion: mutual deal animation → walk-away → delete ───────────────
-- Server fires `dealingCustomerComplete` instead of an immediate
-- despawn so the customer ped can do a proper exit:
--   1. Both peds (player + customer) face each other and play the
--      `mp_common` give-take animation pair (the FiveM-community-
--      standard hand-exchange gesture for drug deals).
--   2. After the anim, the customer unfreezes and walks ~15m away.
--   3. After the configured linger, the ped is deleted.
local DEAL_ANIM_DICT = "mp_common"
local DEAL_ANIM_GIVE = "givetake1_a" -- player hands over
local DEAL_ANIM_TAKE = "givetake1_b" -- customer receives
local DEAL_ANIM_MS   = 1700           -- one play-through of the loop
local WALK_AWAY_MS   = 10000          -- ped walks for this long, then
                                      -- gets deleted

local function loadAnimDict(dict)
    if HasAnimDictLoaded(dict) then return true end
    RequestAnimDict(dict)
    local deadline = GetGameTimer() + 2000
    while not HasAnimDictLoaded(dict) and GetGameTimer() < deadline do Wait(0) end
    return HasAnimDictLoaded(dict)
end

RegisterNetEvent("pickle_drugs:dealingCustomerComplete", function(payload)
    if type(payload) ~= "table" or not payload.deal_id then return end
    local dealId = payload.deal_id
    local entry = CustomerPeds[dealId]
    if not entry or not entry.ped or not DoesEntityExist(entry.ped) then
        -- No spawn yet (player completed before stream-in) or already
        -- gone — just clear pending if present.
        despawnCustomer(dealId)
        return
    end

    local cust = entry.ped
    entry.completing = true
    -- Detach ox_target right away so a second player can't fire
    -- another completion event mid-anim.
    if GetResourceState("ox_target") == "started" then
        exports.ox_target:removeLocalEntity(cust)
    end
    if entry.blip and DoesBlipExist(entry.blip) then
        RemoveBlip(entry.blip)
        entry.blip = nil
    end

    local isOwner = payload.owner_src == GetPlayerServerId(PlayerId())

    CreateThread(function()
        local me = PlayerPedId()

        -- Smooth turn the customer to face the player (frame-by-frame
        -- heading interp — see smoothTurnTowards for why direct task
        -- rotation isn't reliable). The player ped isn't in any task
        -- so the engine native works for them.
        if me and DoesEntityExist(me) then
            smoothTurnTowards(entry, me)
            if isOwner then
                ClearPedTasks(me)
                TaskTurnPedToFaceEntity(me, cust, SMOOTH_TURN_MS)
            end
            Wait(SMOOTH_TURN_MS + 100)
        end
        if not DoesEntityExist(cust) then return end

        if loadAnimDict(DEAL_ANIM_DICT) then
            -- ClearPedTasks before each TaskPlayAnim — the interp
            -- doesn't queue a task, but defensively we make sure
            -- nothing residual stomps the anim.
            ClearPedTasks(cust)
            TaskPlayAnim(cust, DEAL_ANIM_DICT, DEAL_ANIM_TAKE,
                8.0, -8.0, DEAL_ANIM_MS, 0, 0, false, false, false)
            if isOwner and me and DoesEntityExist(me) then
                ClearPedTasks(me)
                TaskPlayAnim(me, DEAL_ANIM_DICT, DEAL_ANIM_GIVE,
                    8.0, -8.0, DEAL_ANIM_MS, 0, 0, false, false, false)
            end
        end

        Wait(DEAL_ANIM_MS)
        if not DoesEntityExist(cust) then return end

        -- Walk away — pick a target ~15m away in the direction
        -- *opposite* of where the customer is facing (which is now
        -- toward the player after the rotation). Unfreeze + clear
        -- tasks first so the walk task can actually take hold.
        ClearPedTasks(cust)
        FreezeEntityPosition(cust, false)
        local heading = GetEntityHeading(cust)
        local rad     = math.rad(heading + 180.0)
        local fx      = -math.sin(rad)
        local fy      =  math.cos(rad)
        local pos     = GetEntityCoords(cust)
        local target  = vector3(pos.x + fx * 15.0, pos.y + fy * 15.0, pos.z)
        TaskGoStraightToCoord(cust, target.x, target.y, target.z, 1.3, -1, 0.0, 0.0)

        Wait(WALK_AWAY_MS)
        despawnCustomer(dealId)
    end)
end)

-- ─── Net handlers ─────────────────────────────────────────────────────────

RegisterNetEvent("pickle_drugs:dealingZoneUpdate", function(z)
    if not z or not z.id then return end
    Zones[z.id] = z
    SendNUIMessage({ action = "dealingZoneUpdate", data = z })
end)
RegisterNetEvent("pickle_drugs:dealingZoneSaved", function(d)
    -- Per-source response after a save. Forwarded so the editor
    -- can adopt the server-assigned id (when tempId was empty).
    SendNUIMessage({ action = "dealingZoneSaved", data = d })
end)
RegisterNetEvent("pickle_drugs:dealingZoneRemoved", function(id)
    if not id then return end
    Zones[id] = nil
    SendNUIMessage({ action = "dealingZoneRemoved", data = id })
end)
RegisterNetEvent("pickle_drugs:dealingCustomerUpdate", function(c)
    if not c or not c.id then return end
    Customers[c.id] = c
    SendNUIMessage({ action = "dealingCustomerUpdate", data = c })
end)
RegisterNetEvent("pickle_drugs:dealingCustomerRemoved", function(id)
    if not id then return end
    Customers[id] = nil
    SendNUIMessage({ action = "dealingCustomerRemoved", data = id })
end)
RegisterNetEvent("pickle_drugs:dealingActiveUpdate", function(d)
    if not d or not d.id then return end
    MyDeals[d.id] = d
    pushHud()
    pushMessages()
end)
RegisterNetEvent("pickle_drugs:dealingActiveRemoved", function(id)
    if not id then return end
    MyDeals[id] = nil
    pushHud()
    pushMessages()
end)
RegisterNetEvent("pickle_drugs:dealingCustomerSpawn",   spawnCustomer)
RegisterNetEvent("pickle_drugs:dealingCustomerDespawn", despawnCustomer)

-- ─── Admin: zone circle + deal-point preview ──────────────────────────────

--- Decode a "#RRGGBB" string into r, g, b 0..255 ints. Falls back to
--- a neutral grey on malformed input so the renderer never errors.
local function hexToRgb(hex)
    if type(hex) ~= "string" then return 200, 200, 200 end
    local h = hex:gsub("^#", "")
    if #h ~= 6 then return 200, 200, 200 end
    local r = tonumber(h:sub(1, 2), 16)
    local g = tonumber(h:sub(3, 4), 16)
    local b = tonumber(h:sub(5, 6), 16)
    return r or 200, g or 200, b or 200
end

CreateThread(function()
    while true do
        if PreviewOn then
            for _, z in pairs(Zones) do
                local sel = (z.id == PreviewZoneId)
                local r, g, b = hexToRgb(z.color)
                -- Selected zone gets a brighter outline + fill; the
                -- others render dimmer so the active edit target reads
                -- clearly against the rest of the map.
                local zBase = z.center_z or 20.0

                local lineAlpha = sel and 240 or 160
                local fillAlpha = sel and 80 or 30
                if z.kind == "polygon" and z.points and #z.points >= 2 then
                    local n = #z.points
                    local zTop = zBase + 1.5
                    for i = 1, n do
                        local nextI = (i % n) + 1
                        if i < n or n >= 3 then
                            local a = z.points[i]
                            local c = z.points[nextI]
                            DrawLine(a.x, a.y, zBase, c.x, c.y, zBase, r, g, b, lineAlpha)
                            DrawLine(a.x, a.y, zBase, a.x, a.y, zTop, r, g, b, sel and 200 or 120)
                        end
                    end
                else
                    DrawMarker(
                        1, -- vertical cylinder
                        z.center_x, z.center_y, zBase - 1.0,
                        0, 0, 0, 0, 0, 0,
                        (z.radius or 50) * 2, (z.radius or 50) * 2, 1.5,
                        r, g, b, fillAlpha,
                        false, false, 2, false, nil, nil, false
                    )
                end

                if z.deal_points then
                    for _, p in ipairs(z.deal_points) do
                        DrawMarker(
                            27, -- ring
                            p.x, p.y, (p.z or zBase) + 0.05,
                            0, 0, 0, 0, 0, 0,
                            1.0, 1.0, 0.4,
                            r, g, b, sel and 200 or 140,
                            false, false, 2, false, nil, nil, false
                        )
                    end
                end
            end
            Wait(0)
        else
            Wait(500)
        end
    end
end)

RegisterNUICallback("dealingPreview", function(data, cb)
    PreviewOn     = data and data.on and true or false
    PreviewZoneId = data and data.zoneId or nil
    cb({ ok = true })
end)

-- In-world deal-point picker. Camera raycast loop, ESC cancel, E confirm.
-- Returns the picked point via SendNUIMessage so the React panel can
-- append it to the zone's deal_points array and trigger a save.
RegisterNUICallback("dealingPickDealPoint", function(data, cb)
    cb({ ok = true })
    local zoneId = data and data.zoneId
    if not zoneId then return end
    CreateThread(function()
        SetNuiFocus(false, false)
        SendNUIMessage({ action = "dealingPickerActive", data = { zoneId = zoneId } })
        local cancelled = false
        local result = nil
        while true do
            Wait(0)
            -- Camera-forward raycast.
            local cam = GetGameplayCamCoord()
            local fwd = GetGameplayCamRot(2)
            local rad = math.rad(fwd.z + 90.0)
            local pitch = math.rad(fwd.x)
            local dx = math.cos(rad) * math.cos(pitch)
            local dy = math.sin(rad) * math.cos(pitch)
            local dz = math.sin(pitch)
            local ex = cam.x + dx * 100.0
            local ey = cam.y + dy * 100.0
            local ez = cam.z + dz * 100.0
            local _, hit, hitPos = GetShapeTestResult(StartShapeTestRay(
                cam.x, cam.y, cam.z, ex, ey, ez, 1, PlayerPedId(), 0))
            local px, py, pz = ex, ey, ez
            if hit then px, py, pz = hitPos.x, hitPos.y, hitPos.z end

            DrawMarker(28, px, py, pz, 0,0,0, 0,0,0, 0.5, 0.5, 0.5,
                80, 200, 120, 200, false, false, 2, false, nil, nil, false)

            if IsControlJustPressed(0, 38) then -- E
                result = { x = px, y = py, z = pz, w = 0.0 }
                break
            end
            if IsControlJustPressed(0, 200) or IsControlJustPressed(0, 322) then -- ESC
                cancelled = true
                break
            end
        end
        SendNUIMessage({ action = "dealingPickerDone", data = {
            zoneId    = zoneId,
            cancelled = cancelled,
            point     = result,
        } })
        SetNuiFocus(true, true)
    end)
end)

-- "Pick zone center" — click in-world to set the zone's center coords.
-- Same shape as dealingPickDealPoint, different result key.
RegisterNUICallback("dealingPickZoneCenter", function(data, cb)
    cb({ ok = true })
    local zoneId = data and data.zoneId
    CreateThread(function()
        SetNuiFocus(false, false)
        SendNUIMessage({ action = "dealingPickerActive", data = { zoneId = zoneId, kind = "center" } })
        local cancelled = false
        local result = nil
        while true do
            Wait(0)
            local cam = GetGameplayCamCoord()
            local fwd = GetGameplayCamRot(2)
            local rad = math.rad(fwd.z + 90.0)
            local pitch = math.rad(fwd.x)
            local dx = math.cos(rad) * math.cos(pitch)
            local dy = math.sin(rad) * math.cos(pitch)
            local dz = math.sin(pitch)
            local ex = cam.x + dx * 200.0
            local ey = cam.y + dy * 200.0
            local ez = cam.z + dz * 200.0
            local _, hit, hitPos = GetShapeTestResult(StartShapeTestRay(
                cam.x, cam.y, cam.z, ex, ey, ez, 1, PlayerPedId(), 0))
            local px, py, pz = ex, ey, ez
            if hit then px, py, pz = hitPos.x, hitPos.y, hitPos.z end
            DrawMarker(1, px, py, pz - 1.0, 0,0,0, 0,0,0, 4.0, 4.0, 1.5,
                80, 200, 255, 60, false, false, 2, false, nil, nil, false)
            if IsControlJustPressed(0, 38) then result = { x = px, y = py, z = pz }; break end
            if IsControlJustPressed(0, 200) or IsControlJustPressed(0, 322) then cancelled = true; break end
        end
        SendNUIMessage({ action = "dealingPickerDone", data = {
            zoneId    = zoneId,
            kind      = "center",
            cancelled = cancelled,
            point     = result,
        } })
        SetNuiFocus(true, true)
    end)
end)

-- ─── Admin NUI callbacks (DealingPanel) ──────────────────────────────────

-- Snapshot fetch for the admin tab. Always pulls fresh from the
-- server rather than reading the local Zones/Customers cache — that
-- cache lags whenever a client misses the boot-time broadcast (hot
-- resource restart races the client's script reload), which would
-- show an empty Dealing tab even when the DB has the data. We also
-- backfill the local cache here so subsequent broadcast events merge
-- cleanly on top of a known-good baseline.
RegisterNUICallback("dealingList", function(_, cb)
    local snap = lib.callback.await("pickle_drugs:listDealing", false)
    if type(snap) ~= "table" then
        cb({ zones = {}, customers = {} })
        return
    end
    for _, z in ipairs(snap.zones or {}) do Zones[z.id] = z end
    for _, c in ipairs(snap.customers or {}) do Customers[c.id] = c end
    cb(snap)
end)

RegisterNUICallback("dealingSaveZone", function(data, cb)
    cb({ ok = true })
    if data then TriggerServerEvent("pickle_drugs:saveDealingZone", data) end
end)
RegisterNUICallback("dealingDeleteZone", function(data, cb)
    cb({ ok = true })
    if data and data.id then TriggerServerEvent("pickle_drugs:deleteDealingZone", data.id) end
end)
RegisterNUICallback("dealingSaveCustomer", function(data, cb)
    cb({ ok = true })
    if data then TriggerServerEvent("pickle_drugs:saveDealingCustomer", data) end
end)
RegisterNUICallback("dealingDeleteCustomer", function(data, cb)
    cb({ ok = true })
    if data and data.id then TriggerServerEvent("pickle_drugs:deleteDealingCustomer", data.id) end
end)

-- ─── Player NUI callbacks (Messages app) ─────────────────────────────────

RegisterNUICallback("dealingAccept", function(data, cb)
    cb({ ok = true })
    if data and data.dealId then
        TriggerServerEvent("pickle_drugs:dealingAccept", data.dealId)
    end
end)
RegisterNUICallback("dealingReject", function(data, cb)
    cb({ ok = true })
    if data and data.dealId then
        TriggerServerEvent("pickle_drugs:dealingReject", data.dealId)
    end
end)
RegisterNUICallback("dealingCounter", function(data, cb)
    cb({ ok = true })
    if data and data.dealId then
        TriggerServerEvent("pickle_drugs:dealingCounter",
            data.dealId, tonumber(data.qty), tonumber(data.unitPrice))
    end
end)
RegisterNUICallback("dealingListMyDeals", function(_, cb)
    -- Snapshot read used by the Messages app on first open.
    local list = {}
    for _, d in pairs(MyDeals) do list[#list + 1] = d end
    table.sort(list, function(a, b) return (a.created_at or 0) > (b.created_at or 0) end)
    cb({ deals = list, zones = Zones, customers = Customers })
end)

-- ─── Boot ────────────────────────────────────────────────────────────────

CreateThread(function()
    -- Bootstrap the player's own deal list AND the public zone/customer
    -- roster once the NUI is ready and the server has had a beat to
    -- push playerJoining state. Without the roster fetch the Messages
    -- app shows "Meet me in unknown zone" on a fresh client whose
    -- broadcast cache hasn't yet been populated (race between the
    -- server's MySQL.ready broadcast and the client's NetEvent
    -- handlers being installed).
    Wait(2500)
    local pub = lib.callback.await("pickle_drugs:listDealing", false)
    if type(pub) == "table" then
        for _, z in ipairs(pub.zones or {})     do Zones[z.id]     = z end
        for _, c in ipairs(pub.customers or {}) do Customers[c.id] = c end
    end
    local snap = lib.callback.await("pickle_drugs:listMyDeals", false)
    if type(snap) == "table" then
        for _, d in ipairs(snap) do MyDeals[d.id] = d end
        pushHud()
        -- Push the messages snapshot now that we have zones+customers
        -- in the local cache; otherwise the Messages app's first
        -- mount would still see "Unknown zone".
        pushMessages()
    end
end)

AddEventHandler("onResourceStop", function(rn)
    if rn ~= GetCurrentResourceName() then return end
    -- Iterate snapshot keys so despawnCustomer's mutation doesn't
    -- corrupt the iterator. Covers both pending + live entries.
    local ids = {}
    for id in pairs(CustomerPeds)     do ids[#ids + 1] = id end
    for id in pairs(PendingCustomers) do ids[#ids + 1] = id end
    for _, id in ipairs(ids) do despawnCustomer(id) end
end)
