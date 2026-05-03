-- Dealers client. Owns:
--   * In-world ped lifecycle for summoned dealers (player asks dealer to
--     come; ped spawns near the player and walks over). Local-only —
--     each summon is private to the summoning player's client.
--   * In-world ped lifecycle for autonomous dealer deals (broadcast to
--     every client like customer peds, since they need to be visible
--     to whoever's around the customer).
--   * NUI bridges for dealer CRUD + hire/dismiss/summon/give-stock.

local AdminSlots = {}       -- id → { id, zone_id, cut_pct } (admin tab)
local MySlots    = {}       -- id → personalised slot view (the only player-facing list)

-- Local-only summoned peds (one per slot at most). Two-phase like the
-- customer ped lifecycle: a Pending entry holds the meet point + blip
-- while the player is too far for ground-Z to be reliable; a polling
-- thread realises the entry into a Live ped once the player is within
-- streaming range, at which point the ground probe + collision load
-- land the ped on real geometry.
local PendingDealers = {}   -- slotId → { slot, pt, zone_label, blip }
local SummonedPeds   = {}   -- slotId → { ped, blip }
local STREAM_RANGE   = 80.0
-- Broadcast autonomous-deal peds (visible to every client around the
-- customer). Mirrors PendingCustomers/CustomerPeds in dealing/client.
local AutoPeds    = {}      -- dealId → { ped, customerPed?, completing? }

local function loadModel(name)
    local hash = (type(name) == "number") and name or joaat(name or 0)
    if not IsModelInCdimage(hash) then return nil end
    RequestModel(hash)
    local deadline = GetGameTimer() + 5000
    while not HasModelLoaded(hash) and GetGameTimer() < deadline do Wait(0) end
    return HasModelLoaded(hash) and hash or nil
end

local function loadAround(x, y, z)
    RequestCollisionAtCoord(x + 0.0, y + 0.0, z + 0.0)
    NewLoadSceneStart(x + 0.0, y + 0.0, z + 0.0, 0.0, 0.0, 0.0, 50.0, 0)
    local deadline = GetGameTimer() + 1500
    while not HasCollisionLoadedAroundEntity(PlayerPedId()) and GetGameTimer() < deadline do
        Wait(0)
    end
    NewLoadSceneStop()
end

local function findGround(x, y, z)
    for _, probeFromZ in ipairs({ z + 50.0, z + 200.0, z, z - 5.0 }) do
        local found, gz = GetGroundZFor_3dCoord(x + 0.0, y + 0.0, probeFromZ, false)
        if found and gz and gz > -100.0 then return gz end
    end
    return z
end

-- ─── Summoned ped (local-only, walks to the summoning player) ─────────────

local function attachSummonTarget(ped, slotId)
    if GetResourceState("ox_target") ~= "started" then return end
    exports.ox_target:addLocalEntity(ped, {
        {
            name     = "pickle_drugs:dealer_give_" .. slotId,
            label    = "Hand over stock",
            icon     = "fa-solid fa-hand-holding",
            distance = 2.5,
            onSelect = function()
                -- Reuses the existing locker StoragePanel by opening the
                -- dealer as a virtual locker (id prefixed "dealer:" —
                -- routed by storage/server.lua to the Dealers adapter).
                if Storage and Storage.OpenLocker then
                    Storage.OpenLocker("dealer:" .. slotId)
                end
            end,
        },
        {
            name     = "pickle_drugs:dealer_dismiss_summon_" .. slotId,
            label    = "Send away",
            icon     = "fa-solid fa-arrow-right-from-bracket",
            distance = 2.5,
            onSelect = function()
                Dealers_DismissWithExitAnim(slotId)
            end,
        },
    })
end

local function makeMeetBlip(pt, slot, zoneLabel)
    local b = AddBlipForCoord(pt.x, pt.y, pt.z)
    SetBlipSprite(b, 280)              -- handshake
    SetBlipScale(b, 0.9)
    SetBlipColour(b, 5)                -- amber
    SetBlipAsShortRange(b, false)
    SetBlipRoute(b, true)
    SetBlipRouteColour(b, 5)
    BeginTextCommandSetBlipName("STRING")
    AddTextComponentString(("Dealer · %s %s%s"):format(
        slot.first_name or "", slot.last_name or "",
        zoneLabel and (" · " .. zoneLabel) or ""))
    EndTextCommandSetBlipName(b)
    return b
end

-- ─── Exit animation (mirrors customer deal completion) ───────────────────
-- Constants intentionally match the customer-deal hand-exchange so dealer
-- and customer farewells read identically. Falls back to instant despawn
-- when the ped isn't live yet (still pending stream-in).

local DEAL_ANIM_DICT  = "mp_common"
local DEAL_ANIM_GIVE  = "givetake1_a"   -- player hands over
local DEAL_ANIM_TAKE  = "givetake1_b"   -- dealer receives
local DEAL_ANIM_MS    = 1700
local WALK_AWAY_MS    = 10000

local function loadAnimDict(dict)
    if HasAnimDictLoaded(dict) then return true end
    RequestAnimDict(dict)
    local deadline = GetGameTimer() + 2000
    while not HasAnimDictLoaded(dict) and GetGameTimer() < deadline do Wait(0) end
    return HasAnimDictLoaded(dict)
end

function Dealers_DismissWithExitAnim(slotId)
    -- Pending (not-yet-spawned) dealer: nothing to animate, drop now.
    if PendingDealers[slotId] and not SummonedPeds[slotId] then
        Dealers_DespawnSummoned(slotId)
        return
    end
    local entry = SummonedPeds[slotId]
    if not entry or not entry.ped or not DoesEntityExist(entry.ped) then
        Dealers_DespawnSummoned(slotId)
        return
    end
    -- Idempotent — second call while exit anim is in flight is a no-op.
    if entry.exiting then return end
    entry.exiting = true

    -- Tear the target / blip down immediately so the player can't open
    -- the inventory or re-summon while the anim is playing.
    if GetResourceState("ox_target") == "started" then
        exports.ox_target:removeLocalEntity(entry.ped)
    end
    if entry.blip and DoesBlipExist(entry.blip) then
        RemoveBlip(entry.blip)
        entry.blip = nil
    end
    -- Reflect "no meetup" in the phone immediately — the ped is going
    -- through its exit; the player shouldn't see "Cancel Meetup" still.
    SendNUIMessage({ action = "dealerSummonState", data = { id = slotId, summoned = false } })

    CreateThread(function()
        local dealer = entry.ped
        local me     = PlayerPedId()

        -- Smooth turn the dealer to face the player (frame-by-frame
        -- heading interp via the shared helper). Player turns to face
        -- the dealer with the engine native.
        if me and DoesEntityExist(me) and smoothTurnTowards then
            smoothTurnTowards(entry, me)
            ClearPedTasks(me)
            TaskTurnPedToFaceEntity(me, dealer, 800)
            Wait(900)
        end
        if not DoesEntityExist(dealer) then
            SummonedPeds[slotId] = nil
            return
        end

        if loadAnimDict(DEAL_ANIM_DICT) then
            ClearPedTasks(dealer)
            TaskPlayAnim(dealer, DEAL_ANIM_DICT, DEAL_ANIM_TAKE,
                8.0, -8.0, DEAL_ANIM_MS, 0, 0, false, false, false)
            if me and DoesEntityExist(me) then
                ClearPedTasks(me)
                TaskPlayAnim(me, DEAL_ANIM_DICT, DEAL_ANIM_GIVE,
                    8.0, -8.0, DEAL_ANIM_MS, 0, 0, false, false, false)
            end
        end
        Wait(DEAL_ANIM_MS)
        if not DoesEntityExist(dealer) then
            SummonedPeds[slotId] = nil
            return
        end

        -- Walk away ~15m in the direction opposite of where the dealer
        -- now faces (toward the player), then despawn after the linger.
        ClearPedTasks(dealer)
        FreezeEntityPosition(dealer, false)
        local heading = GetEntityHeading(dealer)
        local rad     = math.rad(heading + 180.0)
        local pos     = GetEntityCoords(dealer)
        local target  = vector3(pos.x + (-math.sin(rad)) * 15.0,
                                pos.y + ( math.cos(rad)) * 15.0,
                                pos.z)
        TaskGoStraightToCoord(dealer, target.x, target.y, target.z, 1.3, -1, 0.0, 0.0)

        Wait(WALK_AWAY_MS)
        -- Final teardown — DespawnSummoned would also wipe the blip
        -- which we already removed, so it's safe to call again.
        if DoesEntityExist(dealer) then DeleteEntity(dealer) end
        SummonedPeds[slotId] = nil
    end)
end

RegisterNetEvent("pickle_drugs:dealerExitAnim", function(slotId)
    if slotId then Dealers_DismissWithExitAnim(slotId) end
end)

function Dealers_DespawnSummoned(slotId)
    local pending = PendingDealers[slotId]
    if pending then
        if pending.blip and DoesBlipExist(pending.blip) then RemoveBlip(pending.blip) end
        PendingDealers[slotId] = nil
    end
    local entry = SummonedPeds[slotId]
    if entry then
        if entry.ped and DoesEntityExist(entry.ped) then
            if GetResourceState("ox_target") == "started" then
                exports.ox_target:removeLocalEntity(entry.ped)
            end
            DeleteEntity(entry.ped)
        end
        if entry.blip and DoesBlipExist(entry.blip) then RemoveBlip(entry.blip) end
        SummonedPeds[slotId] = nil
    end
    SendNUIMessage({ action = "dealerSummonState", data = { id = slotId, summoned = false } })
end

--- Realise a pending dealer into a live ped. Called by the streaming
--- thread once the player is close enough that the collision/ground
--- probe will produce accurate Z. Forwards the meet blip from the
--- pending entry so the navigation marker doesn't blink.
local function realisePendingDealer(slotId)
    local pending = PendingDealers[slotId]
    if not pending then return end
    local hash = loadModel(pending.slot.model or "g_m_y_lost_01")
    if not hash then return end -- thread will retry next tick
    local pt = pending.pt
    loadAround(pt.x, pt.y, pt.z)
    local gz = findGround(pt.x, pt.y, pt.z)
    local dealer = CreatePed(4, hash, pt.x, pt.y, gz, pt.w or 0.0, false, true)
    SetModelAsNoLongerNeeded(hash)
    if not dealer or not DoesEntityExist(dealer) then return end

    SetEntityInvincible(dealer, true)
    SetBlockingOfNonTemporaryEvents(dealer, true)
    SetPedDefaultComponentVariation(dealer)
    FreezeEntityPosition(dealer, true)

    PendingDealers[slotId] = nil
    SummonedPeds[slotId] = {
        ped         = dealer,
        blip        = pending.blip,
        -- One-shot rotation flag — flipped true the first time the
        -- player is on-screen + within 10m, so the ped rotates once
        -- to face them instead of every poll cycle. Mirrors the
        -- customer-ped pattern in dealing/client.lua.
        facedPlayer = false,
    }
    attachSummonTarget(dealer, slotId)
end

-- Two responsibilities, both keyed off proximity to the player:
--   1. Promote pending dealers to live peds once the player is close
--      enough that the ground-Z probe lands on real terrain.
--   2. For each live dealer, rotate it ONCE to face the player the
--      first time they're inside 10m and on screen — same one-shot
--      pattern the customer-ped poller uses, via the shared
--      `smoothTurnTowards` global from dealing/client.lua.
CreateThread(function()
    while true do
        local hasPending = next(PendingDealers) ~= nil
        local hasLive    = next(SummonedPeds) ~= nil
        Wait((hasPending or hasLive) and 500 or 1500)
        local me = PlayerPedId()
        if me and DoesEntityExist(me) then
            local mc = GetEntityCoords(me)

            -- (1) Stream-in promotion.
            if next(PendingDealers) then
                local toRealise = {}
                for id, entry in pairs(PendingDealers) do
                    local dx, dy = entry.pt.x - mc.x, entry.pt.y - mc.y
                    if (dx * dx + dy * dy) <= (STREAM_RANGE * STREAM_RANGE) then
                        toRealise[#toRealise + 1] = id
                    end
                end
                for _, id in ipairs(toRealise) do realisePendingDealer(id) end
            end

            -- (2) Face-player one-shot. Only if both close and visible,
            -- so the ped doesn't pirouette mid-walk-up.
            for _, entry in pairs(SummonedPeds) do
                if not entry.facedPlayer
                    and entry.ped and DoesEntityExist(entry.ped)
                then
                    local pc = GetEntityCoords(entry.ped)
                    local dx, dy, dz = mc.x - pc.x, mc.y - pc.y, mc.z - pc.z
                    if (dx * dx + dy * dy + dz * dz) <= 100 -- 10m squared
                        and IsEntityOnScreen(entry.ped)
                    then
                        entry.facedPlayer = true
                        if smoothTurnTowards then
                            smoothTurnTowards(entry, me)
                        end
                    end
                end
            end
        end
    end
end)

RegisterNetEvent("pickle_drugs:dealerSpawnNearMe", function(payload)
    if type(payload) ~= "table" or not payload.slot or not payload.pt then return end
    local slot = payload.slot
    local pt   = payload.pt
    -- Re-summon to a different point: tear down whatever's pending /
    -- live first so the new entry takes over cleanly.
    Dealers_DespawnSummoned(slot.id)

    -- Two-phase: register the meet, drop the navigation blip immediately
    -- so the player can navigate, but defer ped creation until the
    -- streaming thread sees them within range. Otherwise the ground-Z
    -- probe falls back to the payload Z (often the zone reference
    -- plane) and the ped lands inside terrain.
    local blip = makeMeetBlip(pt, slot, payload.zone_label)
    PendingDealers[slot.id] = {
        slot       = slot,
        pt         = pt,
        zone_label = payload.zone_label,
        blip       = blip,
    }
    SendNUIMessage({ action = "dealerSummonState", data = { id = slot.id, summoned = true } })
end)

-- ─── Owner / public roster sync ───────────────────────────────────────────

-- Personalised slot view for the local player (one per admin slot).
-- Contains the player's randomised name + model and their hire/inventory
-- state. This is the only payload the phone consumes.
RegisterNetEvent("pickle_drugs:dealerSlotUpdate", function(s)
    if not s or not s.id then return end
    MySlots[s.id] = s
    SendNUIMessage({ action = "dealerSlotUpdate", data = s })
end)

RegisterNetEvent("pickle_drugs:dealerSlotRemoved", function(id)
    if not id then return end
    MySlots[id] = nil
    SendNUIMessage({ action = "dealerSlotRemoved", data = id })
    Dealers_DespawnSummoned(id)
end)

-- Admin-tab payload — bare slot (id, zone_id, cut_pct), no player identity.
RegisterNetEvent("pickle_drugs:dealerAdminSlotUpdate", function(s)
    if not s or not s.id then return end
    AdminSlots[s.id] = s
    SendNUIMessage({ action = "dealerAdminSlotUpdate", data = s })
end)

RegisterNetEvent("pickle_drugs:dealerAdminSlotRemoved", function(id)
    if not id then return end
    AdminSlots[id] = nil
    SendNUIMessage({ action = "dealerAdminSlotRemoved", data = id })
end)

RegisterNetEvent("pickle_drugs:dealerOwnerRemoved", function(id)
    if not id then return end
    -- Local player just dismissed — server will follow up with a fresh
    -- dealerSlotUpdate carrying hired=false, but tear down the meet ped
    -- right away so the cancel feels instant.
    SendNUIMessage({ action = "dealerOwnerRemoved", data = id })
    Dealers_DespawnSummoned(id)
end)

RegisterNetEvent("pickle_drugs:dealerSlotSaved", function(d)
    if d then SendNUIMessage({ action = "dealerSlotSaved", data = d }) end
end)

-- ─── Autonomous-deal ped (broadcast, walks to customer ped) ───────────────
--
-- The dealing scheduler tells every client when an autonomous dealer
-- deal kicks off. We spawn the dealer ped near the customer's deal
-- point and walk it onto the spot. After a short "exchange" idle the
-- server settles the deal and we tear the ped down.

RegisterNetEvent("pickle_drugs:dealerAutoSpawn", function(payload)
    if type(payload) ~= "table" or not payload.deal_id then return end
    if AutoPeds[payload.deal_id] then return end
    local pt = payload.pt
    if not pt then return end
    local hash = loadModel(payload.dealer_model or "g_m_y_lost_01")
    if not hash then return end
    -- Spawn ~8m back from the deal point so they walk in.
    local ang = math.random() * 2 * math.pi
    local sx = pt.x + math.cos(ang) * 8.0
    local sy = pt.y + math.sin(ang) * 8.0
    loadAround(sx, sy, pt.z)
    local sz = findGround(sx, sy, pt.z)
    local ped = CreatePed(4, hash, sx, sy, sz, 0.0, false, false)
    SetModelAsNoLongerNeeded(hash)
    if not ped or not DoesEntityExist(ped) then return end
    SetEntityInvincible(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedDefaultComponentVariation(ped)
    TaskGoStraightToCoord(ped, pt.x, pt.y, pt.z, 1.4, -1, pt.w or 0.0, 0.5)
    -- pt is kept on the entry so the despawn (= deal complete) handler
    -- can turn the ped to face the customer (who's standing on pt) and
    -- play the hand-off anim before they walk away.
    AutoPeds[payload.deal_id] = { ped = ped, pt = pt }
end)

local function autoHeadingFacing(fromCoords, toCoords)
    local dx = toCoords.x - fromCoords.x
    local dy = toCoords.y - fromCoords.y
    return math.deg(math.atan2(-dx, dy))
end

local function autoSmoothTurnToCoord(ped, target, ms)
    if not DoesEntityExist(ped) then return end
    ms = ms or 800
    CreateThread(function()
        ClearPedTasks(ped)
        FreezeEntityPosition(ped, false)
        Wait(0)
        local startHdg  = GetEntityHeading(ped)
        local targetHdg = autoHeadingFacing(GetEntityCoords(ped), target)
        local delta     = ((targetHdg - startHdg + 540) % 360) - 180
        local steps     = 24
        local stepMs    = math.max(16, math.floor(ms / steps))
        for i = 1, steps do
            if not DoesEntityExist(ped) then return end
            local t = i / steps
            local e = (t < 0.5) and (4 * t * t * t) or (1 - ((-2 * t + 2) ^ 3) / 2)
            SetEntityHeading(ped, startHdg + delta * e)
            Wait(stepMs)
        end
        if DoesEntityExist(ped) then SetEntityHeading(ped, targetHdg) end
    end)
end

--- "Despawn" is a misnomer at this point — the event marks the deal as
--- settled; the ped now plays the hand-off animation, walks away, and
--- self-deletes after the linger. Mirrors the customer-complete flow
--- so the two peds finish their meet together rather than one of them
--- vanishing mid-anim.
RegisterNetEvent("pickle_drugs:dealerAutoDespawn", function(dealId)
    local entry = AutoPeds[dealId]
    if not entry then return end
    if entry.exiting then return end
    entry.exiting = true

    local dealer = entry.ped
    if not dealer or not DoesEntityExist(dealer) then
        AutoPeds[dealId] = nil
        return
    end

    CreateThread(function()
        -- Face the deal point (where the customer is). The customer
        -- ped's own complete handler turns it to face the player; the
        -- dealer here turns to face the customer's spot and plays the
        -- give-anim while the customer plays take.
        if entry.pt then
            autoSmoothTurnToCoord(dealer, entry.pt, 800)
            Wait(900)
        end
        if not DoesEntityExist(dealer) then AutoPeds[dealId] = nil return end

        if loadAnimDict(DEAL_ANIM_DICT) then
            ClearPedTasks(dealer)
            TaskPlayAnim(dealer, DEAL_ANIM_DICT, DEAL_ANIM_GIVE,
                8.0, -8.0, DEAL_ANIM_MS, 0, 0, false, false, false)
        end
        Wait(DEAL_ANIM_MS)
        if not DoesEntityExist(dealer) then AutoPeds[dealId] = nil return end

        -- Walk ~15m in the direction opposite of where the dealer is
        -- now facing (which is toward the customer) — same exit walk
        -- the customer ped uses.
        ClearPedTasks(dealer)
        FreezeEntityPosition(dealer, false)
        local heading = GetEntityHeading(dealer)
        local rad     = math.rad(heading + 180.0)
        local pos     = GetEntityCoords(dealer)
        local target  = vector3(pos.x + (-math.sin(rad)) * 15.0,
                                pos.y + ( math.cos(rad)) * 15.0,
                                pos.z)
        TaskGoStraightToCoord(dealer, target.x, target.y, target.z, 1.3, -1, 0.0, 0.0)

        Wait(WALK_AWAY_MS)
        if DoesEntityExist(dealer) then DeleteEntity(dealer) end
        AutoPeds[dealId] = nil
    end)
end)

-- ─── NUI callbacks ────────────────────────────────────────────────────────

RegisterNUICallback("dealerListAdmin", function(_, cb)
    local list = lib.callback.await("pickle_drugs:listDealersAdmin", false) or {}
    for _, s in ipairs(list) do AdminSlots[s.id] = s end
    cb(list)
end)

RegisterNUICallback("dealerListMine", function(_, cb)
    local list = lib.callback.await("pickle_drugs:listMyDealers", false) or {}
    for _, s in ipairs(list) do MySlots[s.id] = s end
    cb(list)
end)

RegisterNUICallback("dealerSave", function(data, cb)
    cb({ ok = true })
    if data then TriggerServerEvent("pickle_drugs:saveDealer", data) end
end)

RegisterNUICallback("dealerDelete", function(data, cb)
    cb({ ok = true })
    if data and data.id then TriggerServerEvent("pickle_drugs:deleteDealer", data.id) end
end)

RegisterNUICallback("dealerHire", function(data, cb)
    cb({ ok = true })
    if data and data.id then TriggerServerEvent("pickle_drugs:hireDealer", data.id) end
end)

RegisterNUICallback("dealerDismiss", function(data, cb)
    cb({ ok = true })
    if data and data.id then TriggerServerEvent("pickle_drugs:dismissDealer", data.id) end
end)

RegisterNUICallback("dealerSummon", function(data, cb)
    cb({ ok = true })
    if data and data.id then TriggerServerEvent("pickle_drugs:dealerSummon", data.id) end
end)

RegisterNUICallback("dealerCancelSummon", function(data, cb)
    cb({ ok = true })
    if data and data.id then Dealers_DismissWithExitAnim(data.id) end
end)

--- Snapshot of which slots currently have a summoned ped on this client.
--- The phone uses this on mount so the button label reflects the current
--- meetup state (Schedule vs Cancel) instead of always defaulting to
--- Schedule until a state event lands.
RegisterNUICallback("dealerSummonStates", function(_, cb)
    local out = {}
    for id in pairs(SummonedPeds)   do out[#out + 1] = id end
    for id in pairs(PendingDealers) do out[#out + 1] = id end
    cb(out)
end)

-- ─── Boot ────────────────────────────────────────────────────────────────

CreateThread(function()
    Wait(2500)
    -- Admin slot list + personalised slot list so admin/manage UI snapshots
    -- are correct on first open without waiting for a server broadcast.
    local adm = lib.callback.await("pickle_drugs:listDealersAdmin", false) or {}
    for _, s in ipairs(adm) do AdminSlots[s.id] = s end
    local mine = lib.callback.await("pickle_drugs:listMyDealers", false) or {}
    for _, s in ipairs(mine) do MySlots[s.id] = s end
end)

AddEventHandler("onResourceStop", function(rn)
    if rn ~= GetCurrentResourceName() then return end
    -- Snapshot ids first so Dealers_DespawnSummoned's mutation doesn't
    -- corrupt the iterator.
    local ids = {}
    for id in pairs(SummonedPeds)   do ids[#ids + 1] = id end
    for id in pairs(PendingDealers) do ids[#ids + 1] = id end
    for _, id in ipairs(ids) do Dealers_DespawnSummoned(id) end
    for dealId, e in pairs(AutoPeds) do
        if e.ped and DoesEntityExist(e.ped) then DeleteEntity(e.ped) end
        AutoPeds[dealId] = nil
    end
end)
