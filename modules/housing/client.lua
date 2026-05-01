-- Housing client. Handles:
--   * Receiving the server's interior/house roster.
--   * Door blips + ox_target attached to each world building's door.
--   * Teleport in/out (server-driven; we just play the screen fade).
--   * Management ox_target inside each house (in the house's bucket).
--   * MLO polyzone detection (entry/exit) + management target inside the
--     polygon for mlo-kind houses.
--   * Grid rendering + placement preview when the player initiates a
--     "Place Entity" flow from the management panel.

local Interiors = {}            -- id → row
local Houses    = {}            -- id → row
local DoorTargets = {}          -- houseId → ox_target zone name
local InsideHouseId = nil       -- the house we're currently inside (any kind)
local CurrentBucketHouse = nil  -- house we're bucketed into (teleport kind)

-- ─── Helpers ──────────────────────────────────────────────────────────────

local function fadeOut(ms)
    DoScreenFadeOut(ms or 400)
    while not IsScreenFadedOut() do Wait(0) end
end

local function fadeIn(ms)
    DoScreenFadeIn(ms or 400)
end

local function teleportPlayerTo(coords, withFade)
    local ped = PlayerPedId()
    if withFade then fadeOut((Config.Housing.teleport or {}).fadeOutMs or 400) end
    SetEntityCoords(ped, coords.x + 0.0, coords.y + 0.0, coords.z + 0.0, false, false, false, false)
    SetEntityHeading(ped, coords.w or 0.0)
    if withFade then
        Wait(150)
        fadeIn((Config.Housing.teleport or {}).fadeInMs or 400)
    end
end

local function targetAvailable()
    return GetResourceState("ox_target") == "started"
end

-- ─── Door target ──────────────────────────────────────────────────────────

local function refreshDoorTarget(h)
    if not targetAvailable() then return end
    local zoneName = "pickle_drugs:house_door_" .. h.id
    if DoorTargets[h.id] then
        exports.ox_target:removeZone(zoneName)
        DoorTargets[h.id] = nil
    end
    if not h.door_world_x or (h.door_world_x == 0 and h.door_world_y == 0) then return end

    local opts = {
        {
            name  = zoneName .. ":inspect",
            label = "Inspect Property",
            icon  = "fa-solid fa-house",
            distance = 2.5,
            canInteract = function()
                return h.tenure == "none" or not Houses[h.id]
                    or not InsideHouseId
            end,
            onSelect = function()
                TriggerEvent("pickle_drugs:openHouseManage", h.id)
            end,
        },
        {
            name  = zoneName .. ":enter",
            label = "Enter",
            icon  = "fa-solid fa-door-open",
            distance = 2.5,
            canInteract = function()
                local hh = Houses[h.id]
                if not hh or hh.tenure == "none" then return false end
                return true
            end,
            onSelect = function()
                TriggerServerEvent("pickle_drugs:enterHouse", h.id)
            end,
        },
    }

    exports.ox_target:addBoxZone({
        coords = vec3(h.door_world_x, h.door_world_y, h.door_world_z),
        size   = vec3(2.0, 2.0, 2.5),
        rotation = h.door_world_w or 0.0,
        debug  = Config.Debug,
        name   = zoneName,
        options = opts,
    })
    DoorTargets[h.id] = zoneName
end

local function removeDoorTarget(houseId)
    if not targetAvailable() then return end
    local name = DoorTargets[houseId]
    if name then
        exports.ox_target:removeZone(name)
        DoorTargets[houseId] = nil
    end
end

-- ─── Interior management & exit targets ───────────────────────────────────

local InteriorTargets = {}      -- houseId → { mgmt = name, exit = name }
local InteriorProps   = {}      -- houseId → { mgmt = entity }

local function pointPlaced(x, y, z)
    if x == nil or y == nil or z == nil then return false end
    return not (x == 0 and y == 0 and z == 0)
end

local function loadModelLocal(name)
    local hash = type(name) == "string" and joaat(name) or name
    if not hash or not IsModelInCdimage(hash) then return nil end
    RequestModel(hash)
    local deadline = GetGameTimer() + 5000
    while not HasModelLoaded(hash) and GetGameTimer() < deadline do Wait(0) end
    return HasModelLoaded(hash) and hash or nil
end

local function spawnMgmtProp(houseId, interior)
    if (InteriorProps[houseId] or {}).mgmt then return end
    if not pointPlaced(interior.mgmt_x, interior.mgmt_y, interior.mgmt_z) then return end
    local cfg = (Config.Housing.placementProps or {}).mgmt
    local model = (cfg and cfg.model) or "prop_laptop_01a"
    local hash = loadModelLocal(model)
    if not hash then return end
    local obj = CreateObject(hash, interior.mgmt_x + 0.0, interior.mgmt_y + 0.0,
        interior.mgmt_z + 0.0, false, false, false)
    if not obj or obj == 0 then SetModelAsNoLongerNeeded(hash); return end
    SetEntityHeading(obj, interior.mgmt_w or 0.0)
    PlaceObjectOnGroundProperly(obj)
    FreezeEntityPosition(obj, true)
    SetEntityCollision(obj, false, false)
    SetEntityAsMissionEntity(obj, true, true)
    SetModelAsNoLongerNeeded(hash)
    InteriorProps[houseId] = InteriorProps[houseId] or {}
    InteriorProps[houseId].mgmt = obj
end

local function despawnMgmtProp(houseId)
    local rec = InteriorProps[houseId]
    if rec and rec.mgmt and DoesEntityExist(rec.mgmt) then
        DeleteEntity(rec.mgmt)
    end
    InteriorProps[houseId] = nil
end

local function refreshInteriorTargets(h)
    if not targetAvailable() then return end
    local prev = InteriorTargets[h.id]
    if prev then
        if prev.mgmt then exports.ox_target:removeZone(prev.mgmt) end
        if prev.exit then exports.ox_target:removeZone(prev.exit) end
        InteriorTargets[h.id] = nil
    end

    local interior = Interiors[h.interior_id]
    if not interior then despawnMgmtProp(h.id) return end

    -- For MLO houses we render targets + the mgmt prop unconditionally
    -- (everyone shares bucket 0; ox_target's distance gate handles UX).
    -- For teleport houses, only render when the player is in the bucket.
    local visible = (interior.kind == "mlo" and h.tenure ~= "none")
        or (h.id == InsideHouseId)
    if not visible then despawnMgmtProp(h.id) return end

    if pointPlaced(interior.mgmt_x, interior.mgmt_y, interior.mgmt_z) then
        spawnMgmtProp(h.id, interior)
    else
        despawnMgmtProp(h.id)
    end

    local mgmtName, exitName
    if pointPlaced(interior.mgmt_x, interior.mgmt_y, interior.mgmt_z) then
        mgmtName = "pickle_drugs:house_mgmt_" .. h.id
        exports.ox_target:addBoxZone({
            coords = vec3(interior.mgmt_x, interior.mgmt_y, interior.mgmt_z + 1.0),
            size   = vec3(1.6, 1.6, 2.6),
            rotation = interior.mgmt_w or 0.0,
            debug  = Config.Debug,
            name   = mgmtName,
            options = {
                {
                    name = mgmtName .. ":open",
                    label = "Manage Property",
                    icon = "fa-solid fa-clipboard-list",
                    distance = 2.5,
                    onSelect = function()
                        TriggerEvent("pickle_drugs:openHouseManage", h.id)
                    end,
                },
            },
        })
    end

    if interior.kind == "teleport"
       and pointPlaced(interior.door_x, interior.door_y, interior.door_z)
    then
        exitName = "pickle_drugs:house_exit_" .. h.id
        exports.ox_target:addBoxZone({
            coords = vec3(interior.door_x, interior.door_y, interior.door_z + 1.0),
            size   = vec3(1.6, 1.6, 2.6),
            rotation = interior.door_w or 0.0,
            debug  = Config.Debug,
            name   = exitName,
            options = {
                {
                    name = exitName .. ":exit",
                    label = "Leave",
                    icon = "fa-solid fa-door-closed",
                    distance = 2.5,
                    onSelect = function()
                        TriggerServerEvent("pickle_drugs:exitHouse", h.id)
                    end,
                },
            },
        })
    end

    InteriorTargets[h.id] = { mgmt = mgmtName, exit = exitName }
end

-- ─── House update plumbing ────────────────────────────────────────────────

RegisterNetEvent("pickle_drugs:interiorUpdate", function(i)
    if not i or not i.id then return end
    Interiors[i.id] = i
    -- Refresh door targets for any house bound to this interior so kind
    -- changes propagate. Also re-spawn the interior (mgmt / exit) targets
    -- if the player is currently inside this house — without it, a fresh
    -- save's mgmt point doesn't land until the player re-enters.
    for _, h in pairs(Houses) do
        if h.interior_id == i.id then
            refreshDoorTarget(h)
            -- MLO mgmt prop is rendered for everyone with the house loaded;
            -- teleport ones only when the player is inside the bucket.
            if i.kind == "mlo" or h.id == InsideHouseId then
                refreshInteriorTargets(h)
            end
        end
    end
end)

RegisterNetEvent("pickle_drugs:interiorRemoved", function(id)
    Interiors[id] = nil
end)

RegisterNetEvent("pickle_drugs:houseUpdate", function(h)
    if not h or not h.id then return end
    Houses[h.id] = h
    refreshDoorTarget(h)
    local interior = Interiors[h.interior_id]
    if (interior and interior.kind == "mlo") or h.id == InsideHouseId then
        refreshInteriorTargets(h)
    end
end)

RegisterNetEvent("pickle_drugs:houseRemoved", function(id)
    Houses[id] = nil
    removeDoorTarget(id)
    despawnMgmtProp(id)
    if InsideHouseId == id then InsideHouseId = nil end
end)

RegisterNetEvent("pickle_drugs:teleportTo", function(coords, withFade)
    if not coords then return end
    teleportPlayerTo(coords, withFade)
end)

RegisterNetEvent("pickle_drugs:enteredHouse", function(houseId)
    InsideHouseId = houseId
    local h = Houses[houseId]
    if h then
        if h.kind ~= "mlo" then CurrentBucketHouse = houseId end
        refreshInteriorTargets(h)
    end
end)

RegisterNetEvent("pickle_drugs:leftHouse", function(houseId)
    if InsideHouseId == houseId then
        local h = Houses[houseId]
        if h then
            local prev = InteriorTargets[h.id]
            if prev and targetAvailable() then
                if prev.mgmt then exports.ox_target:removeZone(prev.mgmt) end
                if prev.exit then exports.ox_target:removeZone(prev.exit) end
            end
            InteriorTargets[h.id] = nil
            despawnMgmtProp(h.id)
        end
        InsideHouseId = nil
        CurrentBucketHouse = nil
    end
end)

-- ─── MLO polyzone (no bucket; detect entry/exit by point-in-poly) ─────────

CreateThread(function()
    -- ox_lib zones live alongside us; use a polling loop instead of zone
    -- callbacks so we don't have to (un)register on every house update.
    while true do
        Wait(750)
        if next(Houses) ~= nil then
            local ped = PlayerPedId()
            local pos = GetEntityCoords(ped)
            local detected = nil
            for id, h in pairs(Houses) do
                local interior = Interiors[h.interior_id]
                if interior and interior.kind == "mlo" and interior.mlo_polygon then
                    if Housing and Housing.PointInPoly and
                       Housing.PointInPoly(interior.mlo_polygon, pos.x, pos.y, pos.z)
                    then
                        detected = id
                        break
                    end
                end
            end
            if detected and detected ~= InsideHouseId then
                InsideHouseId = detected
                refreshInteriorTargets(Houses[detected])
            elseif not detected and InsideHouseId then
                local h = Houses[InsideHouseId]
                if h and h.kind == "mlo" then
                    local prev = InteriorTargets[h.id]
                    if prev and targetAvailable() then
                        if prev.mgmt then exports.ox_target:removeZone(prev.mgmt) end
                    end
                    InteriorTargets[h.id] = nil
                    InsideHouseId = nil
                end
            end
        end
    end
end)

-- ─── Door blips ───────────────────────────────────────────────────────────

local Blips = {}

local function refreshBlip(h)
    if Blips[h.id] then RemoveBlip(Blips[h.id]); Blips[h.id] = nil end
    if not h.door_world_x or (h.door_world_x == 0 and h.door_world_y == 0) then return end
    local b = AddBlipForCoord(h.door_world_x, h.door_world_y, h.door_world_z)
    SetBlipSprite(b, 40)
    SetBlipScale(b, 0.7)
    SetBlipColour(b, h.tenure == "none" and 2 or (h.tenure == "owned" and 5 or 47))
    SetBlipAsShortRange(b, true)
    BeginTextCommandSetBlipName("STRING")
    AddTextComponentString(h.label or h.id)
    EndTextCommandSetBlipName(b)
    Blips[h.id] = b
end

RegisterNetEvent("pickle_drugs:houseUpdate", function(h)
    if h and h.id then refreshBlip(h) end
end)

RegisterNetEvent("pickle_drugs:houseRemoved", function(id)
    if Blips[id] then RemoveBlip(Blips[id]); Blips[id] = nil end
end)

-- ─── Polygon hit-test (simple point-in-polygon) ───────────────────────────

if Housing and not Housing.PointInPoly then
    function Housing.PointInPoly(poly, x, y, z)
        if type(poly) ~= "table" then return false end
        local pts = poly.points or poly
        if type(pts) ~= "table" or #pts < 3 then return false end
        if poly.minZ and z and z < poly.minZ then return false end
        if poly.maxZ and z and z > poly.maxZ then return false end
        local inside = false
        local n = #pts
        local j = n
        for i = 1, n do
            local pi, pj = pts[i], pts[j]
            local pix, piy = pi.x, pi.y
            local pjx, pjy = pj.x, pj.y
            if ((piy > y) ~= (pjy > y)) and
               (x < (pjx - pix) * (y - piy) / ((pjy - piy) + 1e-9) + pix)
            then
                inside = not inside
            end
            j = i
        end
        return inside
    end
end

-- ─── Placement (raycast + grid-snap) ──────────────────────────────────────
--
-- Player picks a drug; we spawn the entity prop attached to the player's
-- camera raycast on the floor. When the cursor isn't inside any of the
-- house's zones (in xy + z tolerance), the placement is invalid (red
-- footprint). Once the cursor enters a zone, the entity snaps to that
-- zone's grid; the footprint goes green when the cells are free, stays
-- red when they're occupied or fall outside the zone bounds. Scroll
-- wheel rotates 0/90/180/270 relative to the active zone's heading. E
-- confirms; ESC cancels.

local Placement = nil

local function loadModel(model)
    if type(model) == "string" then model = joaat(model) end
    if not IsModelInCdimage(model) then return nil end
    RequestModel(model)
    local deadline = GetGameTimer() + 5000
    while not HasModelLoaded(model) and GetGameTimer() < deadline do Wait(0) end
    return HasModelLoaded(model) and model or nil
end

local function raycastFromCamera(maxDist)
    local cam = GetGameplayCamCoord()
    local rot = GetGameplayCamRot(2)
    local rx, rz = math.rad(rot.x), math.rad(rot.z)
    local cosX = math.cos(rx)
    local fwd = vector3(-math.sin(rz) * cosX, math.cos(rz) * cosX, math.sin(rx))
    local dest = cam + fwd * (maxDist or 200.0)
    local handle = StartShapeTestRay(cam.x, cam.y, cam.z, dest.x, dest.y, dest.z, -1, PlayerPedId(), 0)
    local _, hit, endCoords = GetShapeTestResult(handle)
    if hit then return endCoords end
    local pedZ = GetEntityCoords(PlayerPedId()).z
    return vector3(dest.x, dest.y, pedZ)
end

--- Returns the zone (and bottom-left footprint cell) that contains the
--- world point + footprint, or nil if none match. The footprint is
--- centred on the cell under the cursor and clamped so it stays inside
--- the matched zone.
local function resolveZoneAt(p, wx, wy, wz, fw, fh)
    for _, zone in ipairs(p.zones) do
        local cx, cy = Housing.WorldToCell(zone, wx, wy)
        local zTol = zone.zTolerance or Config.Housing.defaultZTolerance or 1.0
        if cx and cy and math.abs(wz - zone.origin.z) <= zTol then
            -- Centre footprint on the cell under the cursor, clamped.
            local cx0 = math.max(0, math.min(zone.xCells - fw, cx - math.floor((fw - 1) / 2)))
            local cy0 = math.max(0, math.min(zone.yCells - fh, cy - math.floor((fh - 1) / 2)))
            return zone, cx0, cy0
        end
    end
    return nil, nil, nil
end

--- Snap world-space pose for a footprint of `(fw,fh)` anchored at cell
--- `(cx,cy)` of `zone`, with rotation step `rotIndex` (0..3). Returns
--- (worldX, worldY, worldZ, headingDeg).
local function snapPoseForFootprint(zone, cx, cy, fw, fh, rotIndex)
    local lx = (cx + fw / 2 - zone.xCells / 2) * zone.cell
    local ly = (cy + fh / 2 - zone.yCells / 2) * zone.cell
    local hRad = math.rad(zone.origin.w or 0.0)
    local cosH, sinH = math.cos(hRad), math.sin(hRad)
    local wx = zone.origin.x + cosH * lx - sinH * ly
    local wy = zone.origin.y + sinH * lx + cosH * ly
    local heading = (rotIndex % 4) * 90.0
    return wx, wy, zone.origin.z, heading
end

--- Draws a flat colored quad covering the entity's footprint. Coordinates
--- are world-space; heading degrees rotate the rectangle in xy.
local function drawFootprintBox(wx, wy, wz, heading, sizeX, sizeY, color, alpha)
    local hx = sizeX / 2
    local hy = sizeY / 2
    local hRad = math.rad(heading)
    local cosH, sinH = math.cos(hRad), math.sin(hRad)
    local function corner(lx, ly)
        return {
            x = wx + cosH * lx - sinH * ly,
            y = wy + sinH * lx + cosH * ly,
            z = wz + 0.03,
        }
    end
    local c1 = corner(-hx, -hy)
    local c2 = corner( hx, -hy)
    local c3 = corner( hx,  hy)
    local c4 = corner(-hx,  hy)
    -- Two triangles, both windings, so it's visible from either side.
    DrawPoly(c1.x, c1.y, c1.z, c2.x, c2.y, c2.z, c3.x, c3.y, c3.z,
        color.r, color.g, color.b, alpha)
    DrawPoly(c1.x, c1.y, c1.z, c3.x, c3.y, c3.z, c4.x, c4.y, c4.z,
        color.r, color.g, color.b, alpha)
    DrawPoly(c3.x, c3.y, c3.z, c2.x, c2.y, c2.z, c1.x, c1.y, c1.z,
        color.r, color.g, color.b, alpha)
    DrawPoly(c4.x, c4.y, c4.z, c3.x, c3.y, c3.z, c1.x, c1.y, c1.z,
        color.r, color.g, color.b, alpha)
end

--- Draws a flat triangular arrow on top of the footprint pointing in the
--- entity's facing direction so the player can see which way the prop will
--- be oriented before confirming. Sized as a fraction of the footprint so
--- it scales naturally with multi-cell entities.
local function drawDirectionArrow(wx, wy, wz, heading, sizeX, sizeY, color, alpha)
    -- Arrow lives in the entity's local frame: tip at +Y, base spanning X.
    -- GTA heading 0° = facing +Y, rotation about Z, so the local frame
    -- matches the same convention drawFootprintBox uses.
    local len = math.min(sizeX, sizeY) * 0.45
    local base = len * 0.6
    local hRad = math.rad(heading)
    local cosH, sinH = math.cos(hRad), math.sin(hRad)
    local function point(lx, ly)
        return {
            x = wx + cosH * lx - sinH * ly,
            y = wy + sinH * lx + cosH * ly,
            z = wz + 0.05, -- slightly above the footprint quad to avoid z-fight
        }
    end
    local tip   = point(0.0,   -len * 0.55)
    local left  = point(-base / 2, len * 0.45)
    local right = point( base / 2, len * 0.45)
    DrawPoly(left.x, left.y, left.z, right.x, right.y, right.z, tip.x, tip.y, tip.z,
        color.r, color.g, color.b, alpha)
    DrawPoly(tip.x, tip.y, tip.z, right.x, right.y, right.z, left.x, left.y, left.z,
        color.r, color.g, color.b, alpha)
end

--- Draws every zone's grid as faint cell outlines so the player can see
--- where snapping will happen. Occupied cells get a darker tint.
local function drawAllZones(p)
    local cfg = Config.Housing.placement
    local empty    = cfg.emptyColor    or { r = 220, g = 220, b = 220 }
    local occupied = cfg.occupiedColor or { r = 110, g = 110, b = 110 }
    for _, zone in ipairs(p.zones) do
        local occ = p.occupiedByZone[zone.id] or {}
        for cx = 0, zone.xCells - 1 do
            for cy = 0, zone.yCells - 1 do
                local key = cx .. ":" .. cy
                local color = occ[key] and occupied or empty
                local alpha = occ[key] and 120 or 70
                local pose = Housing.CellToWorld(zone, cx, cy)
                drawFootprintBox(pose.x, pose.y, pose.z,
                    zone.origin.w or 0.0,
                    zone.cell - 0.04, zone.cell - 0.04,
                    color, alpha)
            end
        end
    end
end

local function placementLoop()
    local sentinel = {}
    Placement.sentinel = sentinel
    -- Input buffer: ignore confirm/cancel for a moment so the click that
    -- started the flow doesn't leak through as an immediate action.
    local startedAt = GetGameTimer()

    while Placement and Placement.sentinel == sentinel do
        Wait(0)
        local p = Placement
        if not p then return end

        local pastBuffer = (GetGameTimer() - startedAt) > 200
        local rotated = (p.rotIndex % 2 == 1)
        local fw = rotated and p.fhBase or p.fwBase
        local fh = rotated and p.fwBase or p.fhBase

        local cursor = raycastFromCamera(200.0)
        local zone, cx, cy = resolveZoneAt(p, cursor.x, cursor.y, cursor.z, fw, fh)

        local valid, snapX, snapY, snapZ, heading
        local sizeX = (rotated and p.sizeY or p.sizeX) or 0.0
        local sizeY = (rotated and p.sizeX or p.sizeY) or 0.0
        if zone then
            snapX, snapY, snapZ, heading = snapPoseForFootprint(zone, cx, cy, fw, fh, p.rotIndex)
            valid = Housing.CanPlaceAt(zone, cx, cy, fw, fh, p.occupiedByZone[zone.id])
            -- Re-derive footprint world size from the snapped zone's cell
            -- (zones share Config.Housing.gridCellSize but we don't assume).
            sizeX = fw * zone.cell
            sizeY = fh * zone.cell
        else
            -- Free placement: park entity on the cursor, no snap, no valid.
            snapX, snapY, snapZ = cursor.x, cursor.y, cursor.z
            heading = (p.rotIndex % 4) * 90.0
            valid = false
            local cell = (Config.Housing and Config.Housing.gridCellSize) or 0.5
            sizeX = math.max(p.sizeX, fw * cell)
            sizeY = math.max(p.sizeY, fh * cell)
        end

        -- Update entity preview pose.
        if p.entity and DoesEntityExist(p.entity) then
            SetEntityCoords(p.entity, snapX, snapY, snapZ, false, false, false, false)
            SetEntityRotation(p.entity, 0.0, 0.0, heading, 2, true)
        end

        -- Always render zone grids so the player sees their snap targets.
        drawAllZones(p)

        -- Footprint box under the entity: green if valid, red otherwise.
        local cfg = Config.Housing.placement
        local valColor = cfg.validColor   or { r = 80,  g = 200, b = 120 }
        local invColor = cfg.invalidColor or { r = 230, g = 80,  b = 80  }
        local boxColor = valid and valColor or invColor
        drawFootprintBox(snapX, snapY, snapZ, heading, sizeX, sizeY, boxColor, 180)
        -- Forward-facing arrow on top of the footprint. Uses a contrasting
        -- white tint so it reads on both the green (valid) and red (invalid)
        -- footprint colors without requiring a separate config entry.
        drawDirectionArrow(snapX, snapY, snapZ, heading, sizeX, sizeY,
            { r = 255, g = 255, b = 255 }, 220)

        -- Stash the picked cell so confirm has it.
        p.lastZone, p.lastCx, p.lastCy = zone, cx, cy
        p.lastSizeX, p.lastSizeY = sizeX, sizeY

        -- Input. Disable conflicting controls each frame.
        DisableControlAction(0, 21,  true) -- LEFT SHIFT
        DisableControlAction(0, 38,  true) -- E (confirm)
        DisableControlAction(0, 24,  true) -- LMB (don't shoot)
        DisableControlAction(0, 25,  true) -- RMB (don't aim)
        DisableControlAction(0, 14,  true) -- WHEEL_PREV
        DisableControlAction(0, 15,  true) -- WHEEL_NEXT
        DisableControlAction(0, 17,  true) -- INPUT_NEXT_CAMERA / scroll up alt
        DisableControlAction(0, 18,  true) -- scroll down alt
        DisableControlAction(0, 199, true)
        DisableControlAction(0, 200, true)
        DisableControlAction(0, 322, true)
        if IsPauseMenuActive() then
            SetFrontendActive(false)
            ActivateFrontendMenu(`FE_MENU_VERSION_EMPTY_NO_BACKGROUND`, true, -1)
        end

        -- Scroll wheel rotates the snapped placement. Controls 14/15 are
        -- INPUT_WEAPON_WHEEL_PREV/NEXT which mouse wheel maps to.
        if IsDisabledControlJustPressed(0, 14) then
            p.rotIndex = (p.rotIndex - 1) % 4
            if p.rotIndex < 0 then p.rotIndex = p.rotIndex + 4 end
        elseif IsDisabledControlJustPressed(0, 15) then
            p.rotIndex = (p.rotIndex + 1) % 4
        end

        -- Confirm. The control is disabled so we read its disabled state.
        if pastBuffer and IsDisabledControlJustPressed(0, 38) then
            if valid then
                local fn = p.confirmFn
                Placement = nil
                if fn then fn(p) end
                return
            end
        end

        -- Cancel. Same suppression pattern as the rest of the pickers.
        if pastBuffer and (
            IsDisabledControlJustReleased(0, 199)
            or IsDisabledControlJustReleased(0, 200)
            or IsDisabledControlJustReleased(0, 322)
        ) then
            local fn = p.cancelFn
            Placement = nil
            if fn then fn() end
            return
        end
    end
end

--- Public: start a placement flow. The player picks an entity (drug);
--- this resolves footprint dims and lets them place it anywhere across
--- the property's zones via raycast. Confirm fires
--- `onConfirm({ zoneId, cx, cy, sizeX, sizeY, rotIndex })`.
function Housing.StartPlacement(opts)
    if Placement then return end
    if not opts or not opts.zones or #opts.zones == 0 or not opts.model then return end
    local hash = loadModel(opts.model)
    if not hash then return end
    local pmin, pmax = GetModelDimensions(hash)
    local sizeX = math.abs(pmax.x - pmin.x)
    local sizeY = math.abs(pmax.y - pmin.y)

    -- Footprint baseline against the first zone's cell — every zone in a
    -- property today shares Config.Housing.gridCellSize, so the cell count
    -- is the same regardless of which zone we ultimately snap into.
    local baseCell = opts.zones[1].cell or (Config.Housing.gridCellSize or 0.5)
    local fw = math.max(1, math.ceil(sizeX / baseCell))
    local fh = math.max(1, math.ceil(sizeY / baseCell))

    -- Per-zone occupancy maps for collision.
    local occupiedByZone = {}
    for _, z in ipairs(opts.zones) do
        occupiedByZone[z.id] = Housing.BuildOccupancy(z, opts.existing or {})
    end

    -- Spawn the preview entity. Non-collidable, alpha-blended; we drive
    -- its pose every frame from the placement loop.
    local ped = PlayerPedId()
    local pcoords = GetEntityCoords(ped)
    local entity = CreateObject(hash, pcoords.x, pcoords.y, pcoords.z, false, false, false)
    SetEntityCollision(entity, false, false)
    SetEntityAlpha(entity, 200, false)
    FreezeEntityPosition(entity, true)
    SetModelAsNoLongerNeeded(hash)

    Placement = {
        houseId        = opts.houseId,
        zones          = opts.zones,
        model          = opts.model,
        entity         = entity,
        sizeX          = sizeX,
        sizeY          = sizeY,
        fwBase         = fw,
        fhBase         = fh,
        rotIndex       = ((tonumber(opts.initialRotIndex) or 0) % 4 + 4) % 4,
        occupiedByZone = occupiedByZone,
        confirmFn = function(p)
            if not p.lastZone then return end
            if opts.onConfirm then
                opts.onConfirm({
                    houseId  = p.houseId, zoneId = p.lastZone.id,
                    cx       = p.lastCx, cy = p.lastCy,
                    sizeX    = p.lastSizeX, sizeY = p.lastSizeY,
                    rotIndex = p.rotIndex,
                })
            end
        end,
        cancelFn = opts.onCancel or function() end,
    }

    SendNUIMessage({
        action = "openPlacementHud",
        data = {
            zoneLabel = "Property",
            xCells    = nil,
            yCells    = nil,
            cell      = baseCell,
        },
    })
    CreateThread(function()
        placementLoop()
        if Placement and Placement.entity and DoesEntityExist(Placement.entity) then
            DeleteEntity(Placement.entity)
        elseif entity and DoesEntityExist(entity) then
            -- Loop already cleared Placement; clean up the local handle.
            DeleteEntity(entity)
        end
        SendNUIMessage({ action = "closePlacementHud" })
    end)
end

-- ─── Manage panel (player-facing) ─────────────────────────────────────────

local ManageOpen = false
local OpenHouseId = nil

local function openManage(houseId)
    if ManageOpen then return end
    local detail = lib.callback.await("pickle_drugs:getHouseDetail", false, houseId)
    if not detail then return end
    ManageOpen = true
    OpenHouseId = houseId
    SetNuiFocus(true, true)
    -- Build per-zone entity lists for the placement UI.
    local zonePlots = {}
    for _, p in ipairs(detail.entities or {}) do
        zonePlots[p.zone_id] = zonePlots[p.zone_id] or {}
        table.insert(zonePlots[p.zone_id], p)
    end
    local employees = lib.callback.await("pickle_drugs:listHouseEmployees", false, houseId) or {}
    local pedModels = (Employees and Employees.PedModels) or {}
    SendNUIMessage({
        action = "openHouseManage",
        data = {
            house      = detail.house,
            interior   = detail.interior,
            cid        = detail.cid,
            canAccess  = detail.canAccess,
            isOwner    = detail.isOwner,
            entities   = detail.entities,
            zonePlots  = zonePlots,
            drugs      = lib.callback.await("pickle_drugs:listDrugs", false) or {},
            employees  = employees,
            pedModels  = pedModels,
        },
    })
end

local function closeManage()
    if not ManageOpen then return end
    ManageOpen = false
    OpenHouseId = nil
    SetNuiFocus(false, false)
    SendNUIMessage({ action = "closeHouseManage" })
end

--- Refetches entities for the open house and pushes a list refresh to
--- the panel. Used by the live event handlers below so removing /
--- moving / placing a plot updates the UI immediately without forcing
--- the player to close + reopen.
local function pushHouseEntities(houseId)
    if not ManageOpen or houseId ~= OpenHouseId then return end
    local detail = lib.callback.await("pickle_drugs:getHouseDetail", false, houseId)
    if not detail then return end
    SendNUIMessage({
        action = "houseEntitiesList",
        data   = { entities = detail.entities or {} },
    })
end

-- Live refresh: any plot mutation that touches the open house redraws
-- the placed-entities list. Plots placed in another house are ignored.
RegisterNetEvent("pickle_drugs:plotUpdate", function(plot)
    if not ManageOpen or not OpenHouseId or not plot then return end
    if plot.house_id ~= OpenHouseId then return end
    pushHouseEntities(OpenHouseId)
end)

RegisterNetEvent("pickle_drugs:plotRemoved", function(_plotId)
    if not ManageOpen or not OpenHouseId then return end
    -- We don't get the removed plot's house_id back; refetching is cheap
    -- and the panel filter catches the no-op case.
    pushHouseEntities(OpenHouseId)
end)

-- Same idea for the workers list.
RegisterNetEvent("pickle_drugs:employeeUpdate", function(emp)
    if not ManageOpen or not OpenHouseId or not emp then return end
    if emp.house_id ~= OpenHouseId then return end
    local list = lib.callback.await("pickle_drugs:listHouseEmployees", false, OpenHouseId) or {}
    SendNUIMessage({ action = "houseEmployeesList", data = { employees = list } })
end)

RegisterNetEvent("pickle_drugs:employeeRemoved", function(_empId)
    if not ManageOpen or not OpenHouseId then return end
    local list = lib.callback.await("pickle_drugs:listHouseEmployees", false, OpenHouseId) or {}
    SendNUIMessage({ action = "houseEmployeesList", data = { employees = list } })
end)

RegisterNetEvent("pickle_drugs:openHouseManage", function(houseId)
    openManage(houseId)
end)

RegisterNUICallback("houseManageClose", function(_, cb)
    closeManage()
    cb({ ok = true })
end)

RegisterNUICallback("housePurchase", function(data, cb)
    cb({ ok = true })
    if data and data.houseId and data.mode then
        TriggerServerEvent("pickle_drugs:purchaseHouse", data.houseId, data.mode)
    end
end)

RegisterNUICallback("housePayRent", function(data, cb)
    cb({ ok = true })
    if data and data.houseId then
        TriggerServerEvent("pickle_drugs:payRent", data.houseId)
    end
end)

RegisterNUICallback("houseCancelLease", function(data, cb)
    cb({ ok = true })
    if data and data.houseId then
        TriggerServerEvent("pickle_drugs:cancelLease", data.houseId)
    end
end)

RegisterNUICallback("houseSetResidents", function(data, cb)
    cb({ ok = true })
    if data and data.houseId and type(data.residents) == "table" then
        TriggerServerEvent("pickle_drugs:setResidents", data.houseId, data.residents)
    end
end)

local function pushHouseEmployees(houseId)
    if not ManageOpen then return end
    local list = lib.callback.await("pickle_drugs:listHouseEmployees", false, houseId) or {}
    SendNUIMessage({ action = "houseEmployeesList", data = { employees = list } })
end

RegisterNUICallback("houseHireEmployee", function(data, cb)
    cb({ ok = true })
    if not data or not data.houseId or not data.model then return end
    TriggerServerEvent("pickle_drugs:createHouseEmployee",
        data.houseId, data.model, data.firstName, data.lastName)
    SetTimeout(400, function() pushHouseEmployees(data.houseId) end)
end)

RegisterNUICallback("houseDismissEmployee", function(data, cb)
    cb({ ok = true })
    if not data or not data.empId or not data.houseId then return end
    TriggerServerEvent("pickle_drugs:dismissHouseEmployee", data.empId)
    SetTimeout(400, function() pushHouseEmployees(data.houseId) end)
end)

-- "Assign Plots" on a worker row in the house panel. Hands off to the
-- existing employee assigner UI (modules/employees/client.lua), which is
-- the same widget the admin /employees command uses.
RegisterNUICallback("houseAssignWorkerPlots", function(data, cb)
    cb({ ok = true })
    if not data or not data.empId then return end
    closeManage()
    if Employees and Employees.OpenAssigner then Employees.OpenAssigner(data.empId) end
end)

--- Reusable plot mover. Used by both the manage panel ("Move" button on
--- a row) and the in-world ox_target on the plot itself. The plot must
--- already belong to a real house — for `_legacy` plots the player should
--- use the admin `/drugs` flow instead.
function Housing.MovePlot(plotId, houseId)
    if not plotId or not houseId then return end
    local h = Houses[houseId]
    local interior = h and Interiors[h.interior_id]
    if not interior or not interior.zones or #interior.zones == 0 then return end

    if ManageOpen then
        SetNuiFocus(false, false)
        SendNUIMessage({ action = "closeHouseManage" })
        ManageOpen = false
    end

    local detail = lib.callback.await("pickle_drugs:getHouseDetail", false, houseId) or {}
    local existing, target = {}, nil
    for _, p in ipairs(detail.entities or {}) do
        if p.id == plotId then
            target = p
        else
            existing[#existing + 1] = p
        end
    end
    if not target then return end

    local drugCfg = Config.Drugs[target.drug]
    local model = (drugCfg and drugCfg.placementModel) or "pickle_pot_01"

    -- Derive the rotIndex relative to the source zone's heading. The plot
    -- stores absolute world heading in coords_w; placement uses 0..3 steps
    -- relative to zone.origin.w. Round to the nearest step in case the row
    -- predates the snap logic.
    local zoneW = 0.0
    for _, z in ipairs(interior.zones) do
        if z.id == target.zone_id then zoneW = z.origin and z.origin.w or 0.0 break end
    end
    local relDeg = ((target.coords_w or 0.0) - zoneW) % 360
    local initialRotIndex = math.floor((relDeg + 45) / 90) % 4

    Housing.StartPlacement({
        houseId         = houseId,
        zones           = interior.zones,
        model           = model,
        existing        = existing,
        initialRotIndex = initialRotIndex,
        onConfirm = function(res)
            TriggerServerEvent("pickle_drugs:moveHousePlot",
                plotId, res.zoneId,
                res.cx, res.cy, res.sizeX, res.sizeY, res.rotIndex)
        end,
        onCancel = function() end,
    })
end

RegisterNUICallback("houseStartMovePlot", function(data, cb)
    cb({ ok = true })
    if not data or not data.houseId or not data.plotId then return end
    Housing.MovePlot(data.plotId, data.houseId)
end)

-- In-scene entry point invoked by the plot's ox_target ("Move plant").
-- The grow client only knows the plot id; we resolve the house id from the
-- live plot record so the plot's ox_target row stays compact.
RegisterNetEvent("pickle_drugs:movePlotInScene", function(plotId, houseId)
    Housing.MovePlot(plotId, houseId)
end)

--- Player-facing delete (owner/admin gated server-side). Mirrors the
--- admin `deletePlot` event but routes through ownership.
RegisterNUICallback("houseDeletePlot", function(data, cb)
    cb({ ok = true })
    if not data or not data.plotId then return end
    TriggerServerEvent("pickle_drugs:deleteHousePlot", data.plotId)
end)

RegisterNUICallback("houseStartPlacement", function(data, cb)
    cb({ ok = true })
    if not data or not data.houseId or not data.drug then return end
    local h = Houses[data.houseId]
    local interior = h and Interiors[h.interior_id]
    if not interior or not interior.zones or #interior.zones == 0 then return end

    -- Hide the manage panel during placement.
    SetNuiFocus(false, false)
    SendNUIMessage({ action = "closeHouseManage" })
    ManageOpen = false

    -- The plot's persistent base prop is the soil pot; show that during
    -- placement so the preview matches what the player actually gets.
    -- Per-drug override via Config.Drugs[drug].placementModel if a future
    -- drug ships with a different base.
    local drugCfg = Config.Drugs[data.drug]
    local model = (drugCfg and drugCfg.placementModel) or "pickle_pot_01"
    -- Re-fetch the latest entities so collision is current.
    local detail = lib.callback.await("pickle_drugs:getHouseDetail", false, data.houseId) or {}
    Housing.StartPlacement({
        houseId  = data.houseId,
        zones    = interior.zones,
        model    = model,
        existing = detail.entities or {},
        onConfirm = function(res)
            TriggerServerEvent("pickle_drugs:createHousePlot",
                data.houseId, res.zoneId, data.drug,
                res.cx, res.cy, res.sizeX, res.sizeY, res.rotIndex)
        end,
        onCancel = function() end,
    })
end)

-- ─── Boot fetch (catch-up after hot reload) ───────────────────────────────

CreateThread(function()
    while not lib do Wait(0) end
    Wait(1500)
    local data = lib.callback.await("pickle_drugs:listHousing", false) or {}
    for _, i in ipairs(data.interiors or {}) do
        Interiors[i.id] = i
    end
    for _, h in ipairs(data.houses or {}) do
        Houses[h.id] = h
        refreshDoorTarget(h)
        refreshBlip(h)
        local interior = Interiors[h.interior_id]
        if interior and interior.kind == "mlo" then
            refreshInteriorTargets(h)
        end
    end
end)

AddEventHandler("onResourceStop", function(rn)
    if rn ~= GetCurrentResourceName() then return end
    if targetAvailable() then
        for _, name in pairs(DoorTargets) do exports.ox_target:removeZone(name) end
        for _, t in pairs(InteriorTargets) do
            if t.mgmt then exports.ox_target:removeZone(t.mgmt) end
            if t.exit then exports.ox_target:removeZone(t.exit) end
        end
    end
    for id, _ in pairs(InteriorProps) do despawnMgmtProp(id) end
    for _, b in pairs(Blips) do RemoveBlip(b) end
end)

-- ─── Public read accessors for other modules (e.g. employees client) ──────

function Housing.GetHouse(id) return Houses[id] end
function Housing.GetInterior(id) return Interiors[id] end
function Housing.GetCurrentHouseId() return InsideHouseId end
function Housing.GetCurrentBucketHouseId() return CurrentBucketHouse end
