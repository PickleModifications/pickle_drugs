-- Admin-side housing UI client. Hooks into the `/drugs` admin command so
-- admins can CRUD houses and interior templates from the same panel they
-- use to place plots today. Gizmo flows are reused for placing world
-- doors and the four interior points (door / exit / idle / management).
--
-- A persistent in-world preview layer renders the draft's points (as their
-- per-kind props/peds) and zones (as cell tiles) so the admin sees the
-- whole layout while editing — both inside the menu and during a pick.

local Open = false
local SubPanel = nil       -- "houses" | "interiors" | nil
local Walking = false      -- true → NUI focus released so admin can move
local InPlacement = false  -- true while a gizmo / zone pick is running

local WALK_KEY_LABEL = "ESC"

local function pushWalkState()
    SendNUIMessage({
        action = "housingWalkState",
        data   = { walking = Walking, key = WALK_KEY_LABEL },
    })
end

--- Set the walk-mode state. While walking, NUI focus is released so the
--- admin can move around and inspect their work in-world; the panel stays
--- mounted (and the persistent preview keeps drawing) but is non-interactive
--- until walk mode is toggled off.
local function setWalking(walking)
    if Walking == walking then return end
    Walking = walking and true or false
    if Open then
        SetNuiFocus(not Walking, not Walking)
    end
    pushWalkState()
end

local function pushList()
    local data = lib.callback.await("pickle_drugs:listHousing", false) or {}
    SendNUIMessage({
        action = "housingList",
        data   = { interiors = data.interiors or {}, houses = data.houses or {} },
    })
end

local function open(panel)
    if Open and SubPanel == panel then return end
    Open = true
    SubPanel = panel
    Walking = false
    SetNuiFocus(true, true)
    local data = lib.callback.await("pickle_drugs:listHousing", false) or {}
    SendNUIMessage({
        action = "openHousing",
        data = {
            panel = panel, -- "houses" or "interiors"
            interiors = data.interiors or {},
            houses    = data.houses or {},
        },
    })
    pushWalkState()
end

local function close()
    if not Open then return end
    Open = false
    SubPanel = nil
    Walking = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = "closeHousing" })
end

local function minimizeForGizmo()
    SetNuiFocus(false, false)
    SendNUIMessage({ action = "housingMinimize" })
end

local function restoreFromGizmo()
    if not Open then return end
    SetNuiFocus(true, true)
    pushList()
    SendNUIMessage({ action = "housingRestore", data = { panel = SubPanel } })
end

RegisterNetEvent("pickle_drugs:openHousing", function(panel)
    open(panel or "houses")
end)

-- Live refresh on server-side mutations.
RegisterNetEvent("pickle_drugs:houseUpdate",      function() if Open then pushList() end end)
RegisterNetEvent("pickle_drugs:houseRemoved",     function() if Open then pushList() end end)
RegisterNetEvent("pickle_drugs:interiorUpdate",   function() if Open then pushList() end end)
RegisterNetEvent("pickle_drugs:interiorRemoved",  function() if Open then pushList() end end)

-- ─── Placement spec ──────────────────────────────────────────────────────

local function placementSpec(kind)
    local props = (Config.Housing and Config.Housing.placementProps) or {}
    return props[kind] or { model = "prop_mp_repair" }
end

local function gridCell()
    return (Config.Housing and Config.Housing.gridCellSize) or 1.0
end

--- Cast a ray from the gameplay camera forward; returns the hit point or
--- a fallback at the player's z. Shared by every picker in this module.
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

-- ─── Persistent preview layer ────────────────────────────────────────────
-- Keeps the draft's points + zones rendered in-world for as long as the
-- editor is open. React mirrors the draft into Preview via housingSetPreview;
-- pickPoint / pickZoneArea hide just the entry being edited.

local Preview = {
    points        = {},   -- list of { kind, x, y, z, w }
    zones         = {},   -- list of { origin = {x,y,z,w}, xCells, yCells, cell }
    entities      = {},   -- map: kind → entity handle
    entityPos     = {},   -- map: kind → cached pose so we don't respawn on no-op rebuilds
    skipKind      = nil,
    skipZoneIndex = nil,
    drawSentinel  = nil,
}

local function isPlaced(p)
    if not p or not p.x then return false end
    return not (p.x == 0 and p.y == 0 and p.z == 0)
end

local function spawnPreviewEntity(spec, point)
    if not isPlaced(point) then return nil end
    local model = spec.model
    local hash = type(model) == "string" and joaat(model) or model
    if not hash or not IsModelInCdimage(hash) then return nil end
    RequestModel(hash)
    local deadline = GetGameTimer() + 5000
    while not HasModelLoaded(hash) and GetGameTimer() < deadline do Wait(0) end
    if not HasModelLoaded(hash) then return nil end
    local ent
    if spec.isPed then
        ent = CreatePed(4, hash, point.x, point.y, point.z, point.w or 0.0, false, false)
        SetEntityInvincible(ent, true)
        SetBlockingOfNonTemporaryEvents(ent, true)
        FreezeEntityPosition(ent, true)
    else
        ent = CreateObject(hash, point.x, point.y, point.z, false, false, false)
        SetEntityRotation(ent, 0.0, 0.0, point.w or 0.0, 2, true)
        FreezeEntityPosition(ent, true)
    end
    SetModelAsNoLongerNeeded(hash)
    if ent and DoesEntityExist(ent) then
        SetEntityCollision(ent, false, false)
        SetEntityAlpha(ent, 180, false)
    end
    return ent
end

local function clearPreviewEntities()
    for _, ent in pairs(Preview.entities) do
        if DoesEntityExist(ent) then DeleteEntity(ent) end
    end
    Preview.entities = {}
    Preview.entityPos = {}
end

local function poseEqual(a, b)
    if not a or not b then return false end
    return math.abs((a.x or 0) - (b.x or 0)) < 0.001
       and math.abs((a.y or 0) - (b.y or 0)) < 0.001
       and math.abs((a.z or 0) - (b.z or 0)) < 0.001
       and math.abs(((a.w or 0) - (b.w or 0)) % 360) < 0.5
end

--- Reconciles Preview.entities with Preview.points incrementally:
---   * deletes entities for kinds that are no longer placed / are skipped
---   * keeps entities whose pose is unchanged (no model reload thrash)
---   * spawns entities for new or moved kinds
--- Without the diff, every editor keystroke would call clearPreviewEntities
--- → respawn → restart RequestModel — entities never finish loading and
--- never visibly appear.
local function rebuildPreviewEntities()
    local desired = {}
    for _, p in ipairs(Preview.points) do
        if p.kind ~= Preview.skipKind and isPlaced(p) then
            desired[p.kind] = p
        end
    end

    -- Remove stale or moved entities.
    for kind, ent in pairs(Preview.entities) do
        local d = desired[kind]
        if not d or not poseEqual(d, Preview.entityPos[kind]) then
            if DoesEntityExist(ent) then DeleteEntity(ent) end
            Preview.entities[kind]  = nil
            Preview.entityPos[kind] = nil
        else
            -- Already correct — drop from desired so we don't respawn it.
            desired[kind] = nil
        end
    end

    -- Spawn anything that wasn't kept.
    for kind, p in pairs(desired) do
        local ent = spawnPreviewEntity(placementSpec(kind), p)
        if ent then
            Preview.entities[kind]  = ent
            Preview.entityPos[kind] = { x = p.x, y = p.y, z = p.z, w = p.w }
        end
    end
end

local function zoneAabb(z)
    local cell = z.cell or gridCell()
    local hx = z.xCells * cell / 2
    local hy = z.yCells * cell / 2
    return z.origin.x - hx, z.origin.y - hy, z.origin.x + hx, z.origin.y + hy
end

local function rectsOverlap(ax1, ay1, ax2, ay2, bx1, by1, bx2, by2)
    return ax1 < bx2 - 1e-6 and bx1 + 1e-6 < ax2
       and ay1 < by2 - 1e-6 and by1 + 1e-6 < ay2
end

--- Returns the four world-space corners of a cell at zone-local index
--- `(relCx, relCy)`. Cells are centre-anchored: cell (0, 0)'s centre sits
--- at `(originWx, originWy)`, and cell (relCx, relCy)'s centre sits at
--- local `(relCx * cell, relCy * cell)`. The whole frame rotates by
--- `rotRad` around `(originWx, originWy)`.
local function cellWorldCorners(originWx, originWy, relCx, relCy, cell, rotRad)
    local cx, cy = relCx * cell, relCy * cell
    local half = cell / 2 - 0.02
    local lx0, ly0 = cx - half, cy - half
    local lx1, ly1 = cx + half, cy + half
    local cosR, sinR = math.cos(rotRad), math.sin(rotRad)
    local function R(lx, ly)
        return originWx + cosR * lx - sinR * ly,
               originWy + sinR * lx + cosR * ly
    end
    local x1, y1 = R(lx0, ly0)
    local x2, y2 = R(lx1, ly0)
    local x3, y3 = R(lx1, ly1)
    local x4, y4 = R(lx0, ly1)
    return x1, y1, x2, y2, x3, y3, x4, y4
end

--- Renders a single cell as a low translucent box. Built from DrawPoly so
--- we can rotate the cell around the zone origin (DrawBox is axis-aligned
--- and can't honour the zone's heading). Walls are drawn so the cell
--- reads as a 3D extrusion rather than a flat tile.
local function drawCellBox(originWx, originWy, relCx, relCy, z, cell, rotRad, height, color, alpha)
    local x1, y1, x2, y2, x3, y3, x4, y4 =
        cellWorldCorners(originWx, originWy, relCx, relCy, cell, rotRad)
    local r, g, b = color.r, color.g, color.b
    local zb, zt = z + 0.02, z + height

    local function quad(ax, ay, az, bx, by, bz, cx, cy, cz, dx, dy, dz)
        DrawPoly(ax, ay, az, bx, by, bz, cx, cy, cz, r, g, b, alpha)
        DrawPoly(ax, ay, az, cx, cy, cz, dx, dy, dz, r, g, b, alpha)
        DrawPoly(cx, cy, cz, bx, by, bz, ax, ay, az, r, g, b, alpha)
        DrawPoly(dx, dy, dz, cx, cy, cz, ax, ay, az, r, g, b, alpha)
    end

    -- Top + bottom faces.
    quad(x1, y1, zb, x2, y2, zb, x3, y3, zb, x4, y4, zb)
    quad(x1, y1, zt, x2, y2, zt, x3, y3, zt, x4, y4, zt)
    -- Four side walls (each a vertical quad between two adjacent corners).
    quad(x1, y1, zb, x2, y2, zb, x2, y2, zt, x1, y1, zt)
    quad(x2, y2, zb, x3, y3, zb, x3, y3, zt, x2, y2, zt)
    quad(x3, y3, zb, x4, y4, zb, x4, y4, zt, x3, y3, zt)
    quad(x4, y4, zb, x1, y1, zb, x1, y1, zt, x4, y4, zt)
end

--- Loose AABB enclosing the rotated cell's footprint. Used for overlap
--- detection against existing zones; loose-but-no-false-negatives is fine
--- for the picker's red/green feedback.
local function cellAabbBounds(originWx, originWy, relCx, relCy, cell, rotRad)
    local x1, y1, x2, y2, x3, y3, x4, y4 =
        cellWorldCorners(originWx, originWy, relCx, relCy, cell, rotRad)
    local minX = math.min(x1, x2, x3, x4)
    local maxX = math.max(x1, x2, x3, x4)
    local minY = math.min(y1, y2, y3, y4)
    local maxY = math.max(y1, y2, y3, y4)
    return minX, minY, maxX, maxY
end

--- Builds a map of "cx:cy" → count, counting how many active draft zones
--- (excluding skipZoneIndex and unplaced zones) cover each grid cell.
--- Cells with count >= 2 are painted red so the admin sees overlap live.
local function buildPreviewOccupancy()
    local occ = {}
    local cell = gridCell()
    for i, z in ipairs(Preview.zones) do
        if i ~= Preview.skipZoneIndex
           and z.origin and z.xCells and z.yCells
           and z.xCells > 0 and z.yCells > 0
           and isPlaced(z.origin)
        then
            local zCell = z.cell or cell
            if math.abs(zCell - cell) < 1e-4 then
                local x0 = z.origin.x - z.xCells * zCell / 2
                local y0 = z.origin.y - z.yCells * zCell / 2
                local cx0 = math.floor((x0 + 1e-4) / cell)
                local cy0 = math.floor((y0 + 1e-4) / cell)
                for ix = 0, z.xCells - 1 do
                    for iy = 0, z.yCells - 1 do
                        local k = (cx0 + ix) .. ":" .. (cy0 + iy)
                        occ[k] = (occ[k] or 0) + 1
                    end
                end
            end
        end
    end
    return occ
end

local function drawZoneCellsWithOverlap(z, occ, empty, invalid)
    local cell = z.cell or gridCell()
    local rotDeg = (z.origin and z.origin.w) or 0.0
    local rotRad = math.rad(rotDeg)
    -- Cells are centre-anchored relative to the zone's stored origin
    -- (z.origin.x, z.origin.y is the world centre of the bounding rect).
    -- Cell (ix, iy)'s centre offset from origin in local coords is
    -- ((ix - (xCells-1)/2) * cell, (iy - (yCells-1)/2) * cell).
    local axisAligned = math.abs((rotDeg % 360 + 360) % 360) < 1e-3
    local x0 = z.origin.x - z.xCells * cell / 2
    local y0 = z.origin.y - z.yCells * cell / 2
    local cx0 = axisAligned and math.floor((x0 + 1e-4) / cell) or 0
    local cy0 = axisAligned and math.floor((y0 + 1e-4) / cell) or 0
    local hx = (z.xCells - 1) / 2
    local hy = (z.yCells - 1) / 2
    for ix = 0, z.xCells - 1 do
        for iy = 0, z.yCells - 1 do
            local hits = false
            if axisAligned then
                hits = (occ[(cx0 + ix) .. ":" .. (cy0 + iy)] or 0) >= 2
            end
            local color = hits and invalid or empty
            local alpha = hits and 200 or 80
            drawCellBox(z.origin.x, z.origin.y, ix - hx, iy - hy,
                z.origin.z, cell, rotRad, 0.1, color, alpha)
        end
    end
end

local function startPreviewDrawLoop()
    if Preview.drawSentinel then return end
    local sentinel = {}
    Preview.drawSentinel = sentinel
    CreateThread(function()
        local cfg = (Config.Housing and Config.Housing.placement) or {}
        local empty   = cfg.emptyColor   or { r = 220, g = 220, b = 220 }
        local invalid = cfg.invalidColor or { r = 230, g = 80,  b = 80  }
        while Preview.drawSentinel == sentinel do
            Wait(0)
            local occ = buildPreviewOccupancy()
            for i, z in ipairs(Preview.zones) do
                if i ~= Preview.skipZoneIndex
                   and z.origin and z.xCells and z.yCells
                   and z.xCells > 0 and z.yCells > 0
                   and isPlaced(z.origin)
                then
                    drawZoneCellsWithOverlap(z, occ, empty, invalid)
                end
            end
        end
    end)
end

local function stopPreviewDrawLoop()
    Preview.drawSentinel = nil
end

local function clearPreviewState()
    stopPreviewDrawLoop()
    clearPreviewEntities()
    Preview.points = {}
    Preview.zones  = {}
    Preview.skipKind = nil
    Preview.skipZoneIndex = nil
end

RegisterNUICallback("housingSetPreview", function(data, cb)
    cb({ ok = true })
    Preview.points = (data and data.points) or {}
    Preview.zones  = (data and data.zones)  or {}
    rebuildPreviewEntities()
    startPreviewDrawLoop()
end)

RegisterNUICallback("housingClearPreview", function(_, cb)
    cb({ ok = true })
    clearPreviewState()
end)

-- ─── Gizmo: pick a single point ───────────────────────────────────────────

--- Returns vec4 {x,y,z,w} or nil if cancelled. While the gizmo is active
--- we hide the persistent preview entity for the same kind so the gizmo
--- prop isn't doubled up by the static one.
local function pickPoint(initial, label, kind)
    if not StartGizmoEditor then return nil end
    InPlacement = true
    minimizeForGizmo()
    Preview.skipKind = kind
    rebuildPreviewEntities()
    local spec = placementSpec(kind)
    local opts = {
        model        = spec.model,
        isPed        = spec.isPed and true or false,
        enableCancel = true,
        deleteEntity = true,
        label        = label,
    }
    if isPlaced(initial) then
        opts.coords   = vector3(initial.x, initial.y, initial.z)
        opts.rotation = vector3(0.0, 0.0, initial.w or 0.0)
    end
    local result = StartGizmoEditor(opts)
    InPlacement = false
    Preview.skipKind = nil
    -- Optimistically update the preview point in-place so the static entity
    -- respawns at the gizmo's final position rather than flickering at the
    -- old one until React's next housingSetPreview arrives.
    if result and result.position then
        local picked = {
            kind = kind,
            x = result.position.x,
            y = result.position.y,
            z = result.position.z,
            w = (result.rotation and result.rotation.z) or 0.0,
        }
        local updated = false
        for i, pt in ipairs(Preview.points) do
            if pt.kind == kind then Preview.points[i] = picked; updated = true; break end
        end
        if not updated then Preview.points[#Preview.points + 1] = picked end
    end
    rebuildPreviewEntities()
    restoreFromGizmo()
    if not result or not result.position then return nil end
    return {
        x = result.position.x,
        y = result.position.y,
        z = result.position.z,
        w = (result.rotation and result.rotation.z) or 0.0,
    }
end

-- ─── World-door picker (raycast, no entity) ──────────────────────────────
--
-- The world door used to ride the gizmo flow. That gizmo path was unstable
-- for some reason — clicking "Place" produced a brief NUI flicker and the
-- gizmo would exit before the player could interact. This is a fresh,
-- minimal raycast picker: each frame we cast forward from the camera, draw
-- a flat marker at the hit, scroll to rotate, LMB to confirm, ESC to
-- cancel. No entity is spawned; nothing about the gizmo loop is involved.

local function pickWorldDoor(initial)
    InPlacement = true
    minimizeForGizmo()
    Preview.skipKind = "house_door"
    rebuildPreviewEntities()
    SendNUIMessage({
        action = "openZonePickerHud",
        data   = { phase = "worldDoor", vertices = 0 },
    })

    local rotIndex = math.floor((((initial and initial.w) or 0.0) / 90.0) + 0.5) % 4
    if rotIndex < 0 then rotIndex = rotIndex + 4 end
    local startedAt = GetGameTimer()
    local result = nil

    while true do
        Wait(0)
        local pastBuffer = (GetGameTimer() - startedAt) > 200
        local cursor = raycastFromCamera(200.0)
        local heading = rotIndex * 90.0

        -- Flat marker on the floor: a 0.6m square + a forward line so the
        -- admin sees both the spot and which way the door faces. Built
        -- from DrawPoly / DrawLine so we don't depend on DrawMarker's
        -- texture args (those choke at the native bindings on some
        -- builds and the call fails before any frame renders).
        do
            local s = 0.3
            local hRad = math.rad(heading)
            local cosH, sinH = math.cos(hRad), math.sin(hRad)
            local function corner(lx, ly)
                return {
                    x = cursor.x + cosH * lx - sinH * ly,
                    y = cursor.y + sinH * lx + cosH * ly,
                    z = cursor.z + 0.04,
                }
            end
            local c1 = corner(-s, -s)
            local c2 = corner( s, -s)
            local c3 = corner( s,  s)
            local c4 = corner(-s,  s)
            DrawPoly(c1.x, c1.y, c1.z, c2.x, c2.y, c2.z, c3.x, c3.y, c3.z, 80, 200, 220, 200)
            DrawPoly(c1.x, c1.y, c1.z, c3.x, c3.y, c3.z, c4.x, c4.y, c4.z, 80, 200, 220, 200)
            DrawPoly(c3.x, c3.y, c3.z, c2.x, c2.y, c2.z, c1.x, c1.y, c1.z, 80, 200, 220, 200)
            DrawPoly(c4.x, c4.y, c4.z, c3.x, c3.y, c3.z, c1.x, c1.y, c1.z, 80, 200, 220, 200)
            -- Forward arrow: a line from the centre out along +y (local).
            local tip = corner(0.0, s + 0.6)
            DrawLine(cursor.x, cursor.y, cursor.z + 0.05,
                     tip.x, tip.y, tip.z, 220, 220, 80, 220)
        end

        DisableControlAction(0, 24,  true) -- LMB
        DisableControlAction(0, 25,  true) -- RMB
        DisableControlAction(0, 14,  true) -- WHEEL_PREV
        DisableControlAction(0, 15,  true) -- WHEEL_NEXT
        DisableControlAction(0, 199, true)
        DisableControlAction(0, 200, true)
        DisableControlAction(0, 322, true)
        if IsPauseMenuActive() then
            SetFrontendActive(false)
            ActivateFrontendMenu(`FE_MENU_VERSION_EMPTY_NO_BACKGROUND`, true, -1)
        end

        if IsDisabledControlJustPressed(0, 14) then
            rotIndex = (rotIndex - 1) % 4
            if rotIndex < 0 then rotIndex = rotIndex + 4 end
        elseif IsDisabledControlJustPressed(0, 15) then
            rotIndex = (rotIndex + 1) % 4
        end

        if pastBuffer and IsDisabledControlJustReleased(0, 24) then
            result = { x = cursor.x, y = cursor.y, z = cursor.z, w = heading }
            break
        end
        if pastBuffer and (
            IsDisabledControlJustReleased(0, 199)
            or IsDisabledControlJustReleased(0, 200)
            or IsDisabledControlJustReleased(0, 322)
        ) then
            break
        end
    end

    SendNUIMessage({ action = "closeZonePickerHud" })
    InPlacement = false
    Preview.skipKind = nil
    if result then
        local picked = { kind = "house_door", x = result.x, y = result.y, z = result.z, w = result.w }
        local updated = false
        for i, pt in ipairs(Preview.points) do
            if pt.kind == "house_door" then Preview.points[i] = picked; updated = true; break end
        end
        if not updated then Preview.points[#Preview.points + 1] = picked end
    end
    rebuildPreviewEntities()
    restoreFromGizmo()
    return result
end

-- ─── NUI callbacks: interiors ────────────────────────────────────────────

RegisterNUICallback("housingClose", function(_, cb)
    close()
    clearPreviewState()
    cb({ ok = true })
end)

RegisterNUICallback("housingToggleWalk", function(_, cb)
    cb({ ok = true })
    if not Open then return end
    setWalking(not Walking)
end)

-- ESC handler. Mirrors the placement-cancel pattern in pickZoneArea: kill
-- every pause-menu input each frame and bounce the engine back out of any
-- frontend it has already flagged before our IsDisabledControlJustReleased
-- check fires. Only runs while the panel is open AND we're not currently
-- inside a gizmo / zone pick (those have their own ESC suppression and
-- consume the press for cancel).
CreateThread(function()
    while true do
        if Open and not InPlacement then
            DisableControlAction(0, 199, true) -- INPUT_FRONTEND_PAUSE
            DisableControlAction(0, 200, true) -- INPUT_FRONTEND_PAUSE_ALTERNATE
            DisableControlAction(0, 322, true) -- INPUT_FRONTEND_PAUSE_ALTERNATE (alt)
            if IsPauseMenuActive() then
                SetFrontendActive(false)
                ActivateFrontendMenu(`FE_MENU_VERSION_EMPTY_NO_BACKGROUND`, true, -1)
            end
            if IsDisabledControlJustReleased(0, 199)
               or IsDisabledControlJustReleased(0, 200)
               or IsDisabledControlJustReleased(0, 322)
            then
                setWalking(not Walking)
            end
            Wait(0)
        else
            Wait(100)
        end
    end
end)

--- Tab switcher used by the shared `Drugs Admin` header. The two tabs
--- (Properties / Interiors) are both owned by this module, so we just
--- swap the active panel state.
RegisterNUICallback("drugsAdminSwitchTab", function(data, cb)
    cb({ ok = true })
    if not data or not data.tab then return end
    if Open then close() end
    clearPreviewState()
    SetNuiFocus(false, false)
    if data.tab == "houses" then
        open("houses")
    elseif data.tab == "interiors" then
        open("interiors")
    elseif data.tab == "dealing" then
        open("dealing")
    end
end)

RegisterNUICallback("housingPickPoint", function(data, cb)
    cb({ ok = true })
    CreateThread(function()
        local kind = data and data.kind
        local p
        -- House (world) door uses the dedicated raycast flow; everything
        -- else still goes through the gizmo for fine 3D positioning.
        if kind == "house_door" then
            p = pickWorldDoor(data and data.initial)
        else
            p = pickPoint(
                data and data.initial,
                data and data.label or "Place point",
                kind
            )
        end
        SendNUIMessage({
            action = "housingPointPicked",
            data = { kind = kind, point = p },
        })
    end)
end)

-- ─── Zone area picker ─────────────────────────────────────────────────────
-- Two-phase raycast flow: first click anchors a one-cell origin block, then
-- the grid grows from there toward the cursor in real time. Second click
-- confirms the bounds. Cell size is `Config.Housing.gridCellSize` and cells
-- are axis-aligned. HUD is rendered via NUI (ZonePickerHud) — never via
-- native help text. Cells overlapping any existing zone are flagged red so
-- the admin can shrink/move the bounds before confirming.

--- Returns true if the cell whose AABB is `[x1,y1] .. [x2,y2]` overlaps
--- any existing draft zone outside `excludeZoneIndex`. Zones are arbitrary
--- world rectangles now (origin is no longer snapped to a global grid),
--- so overlap is purely AABB-based.
local function cellAabbHitsExisting(x1, y1, x2, y2, excludeZoneIndex)
    for i, z in ipairs(Preview.zones) do
        if i ~= excludeZoneIndex and z.xCells and z.yCells and z.origin then
            local bx1, by1, bx2, by2 = zoneAabb(z)
            if rectsOverlap(x1, y1, x2, y2, bx1, by1, bx2, by2) then
                return true
            end
        end
    end
    return false
end

--- Draws the new zone's cells anchored at world-space `(originWx, originWy)`
--- and rotated by `rotDeg`. Cells overlapping any existing zone (other than
--- `excludeZoneIndex`) are painted invalid; the origin cell (relative 0,0)
--- is highlighted; the rest use empty. Returns true if any cell collides.
local function drawNewZoneCells(originWx, originWy, minCx, minCy, xCells, yCells, z, rotDeg, excludeZoneIndex)
    local cfg = (Config.Housing and Config.Housing.placement) or {}
    local valid   = cfg.validColor   or { r = 80,  g = 200, b = 120 }
    local invalid = cfg.invalidColor or { r = 230, g = 80,  b = 80  }
    local empty   = cfg.emptyColor   or { r = 220, g = 220, b = 220 }
    local cell = gridCell()
    local rotRad = math.rad(rotDeg or 0)
    local anyOverlap = false
    for ix = 0, xCells - 1 do
        for iy = 0, yCells - 1 do
            local relCx, relCy = minCx + ix, minCy + iy
            local x1, y1, x2, y2 = cellAabbBounds(originWx, originWy, relCx, relCy, cell, rotRad)
            local hits = cellAabbHitsExisting(x1, y1, x2, y2, excludeZoneIndex)
            local color, alpha
            if hits then
                color, alpha = invalid, 220
                anyOverlap = true
            elseif relCx == 0 and relCy == 0 then
                color, alpha = valid, 220
            else
                color, alpha = empty, 160
            end
            drawCellBox(originWx, originWy, relCx, relCy, z, cell, rotRad, 0.1, color, alpha)
        end
    end
    return anyOverlap
end

--- Picks a zone area. Returns { origin = {x,y,z,w}, xCells, yCells } or nil.
--- The origin world position is the first click — the zone is NOT snapped
--- to a global grid. Rotation is configured DURING the origin phase by
--- scrolling (Shift = coarse 22.5° steps, Ctrl = fine 1° steps, default
--- 5°); LMB locks the origin + rotation. After that, only bounds extend
--- via the cursor; rotation no longer changes until RMB resets origin.
--- `excludeZoneIndex` marks the zone being re-picked so it isn't compared
--- against itself for overlap.
local function pickZoneArea(excludeZoneIndex)
    InPlacement = true
    minimizeForGizmo()
    Preview.skipZoneIndex = excludeZoneIndex
    SendNUIMessage({ action = "openZonePickerHud", data = { phase = "origin" } })

    local cell = gridCell()
    -- origin once placed: { wx, wy, z } in world coords AND a captured
    -- rotDeg. Cells are centre-anchored: cell (0, 0)'s centre sits at
    -- (origin.wx, origin.wy). Cell (relCx, relCy)'s centre is at local
    -- (relCx*cell, relCy*cell), rotated by rotDeg around origin.
    local origin = nil
    local rotDeg = 0.0
    local result = nil
    local lastPhase, lastX, lastY, lastInvalid, lastRot = "origin", 1, 1, false, -1

    while true do
        Wait(0)
        local cursor = raycastFromCamera(200.0)

        DisableControlAction(0, 24,  true)
        DisableControlAction(0, 25,  true)
        DisableControlAction(0, 142, true)
        DisableControlAction(0, 257, true)
        DisableControlAction(0, 199, true)
        DisableControlAction(0, 200, true)
        DisableControlAction(0, 322, true)
        DisableControlAction(0, 14,  true) -- scroll prev
        DisableControlAction(0, 15,  true) -- scroll next
        DisableControlAction(0, 21,  true) -- LSHIFT
        DisableControlAction(0, 36,  true) -- LCTRL
        if IsPauseMenuActive() then
            SetFrontendActive(false)
            ActivateFrontendMenu(`FE_MENU_VERSION_EMPTY_NO_BACKGROUND`, true, -1)
        end

        if origin == nil then
            -- Origin phase: rotation is editable here. Scroll wheel
            -- rotates the preview cell around the cursor; modifiers
            -- tune the step (Shift coarse, Ctrl fine).
            local step = 5.0
            if IsDisabledControlPressed(0, 21) then step = 22.5 end
            if IsDisabledControlPressed(0, 36) then step = 1.0  end
            if IsDisabledControlJustPressed(0, 14) then
                rotDeg = (rotDeg - step) % 360
            elseif IsDisabledControlJustPressed(0, 15) then
                rotDeg = (rotDeg + step) % 360
            end

            -- Single 1×1 cell centred at the cursor, rotated around it.
            local invalid = drawNewZoneCells(cursor.x, cursor.y, 0, 0, 1, 1, cursor.z, rotDeg, excludeZoneIndex)
            if lastPhase ~= "origin" or lastInvalid ~= invalid or lastRot ~= rotDeg then
                lastPhase, lastInvalid, lastRot = "origin", invalid, rotDeg
                SendNUIMessage({
                    action = "updateZonePickerHud",
                    data   = { phase = "origin", invalid = invalid, rotDeg = rotDeg },
                })
            end

            if IsDisabledControlJustReleased(0, 24) and not invalid then
                origin = { wx = cursor.x, wy = cursor.y, z = cursor.z }
            elseif IsDisabledControlJustReleased(0, 199)
                or IsDisabledControlJustReleased(0, 200)
                or IsDisabledControlJustReleased(0, 322) then
                break
            end
        else
            -- Bounds phase: rotation locked, only bounds extend.
            -- Inverse-rotate the cursor displacement from the origin,
            -- then round to nearest cell index in the centre-anchored
            -- convention (cell n covers [n - 0.5, n + 0.5] * cell).
            local rotRad = math.rad(rotDeg)
            local cosR, sinR = math.cos(rotRad), math.sin(rotRad)
            local dx, dy = cursor.x - origin.wx, cursor.y - origin.wy
            local localX =  cosR * dx + sinR * dy
            local localY = -sinR * dx + cosR * dy
            local cursorCx = math.floor(localX / cell + 0.5)
            local cursorCy = math.floor(localY / cell + 0.5)

            local minCx = math.min(0, cursorCx)
            local minCy = math.min(0, cursorCy)
            local maxCx = math.max(0, cursorCx)
            local maxCy = math.max(0, cursorCy)
            local xCells = maxCx - minCx + 1
            local yCells = maxCy - minCy + 1

            local invalid = drawNewZoneCells(origin.wx, origin.wy, minCx, minCy, xCells, yCells, origin.z, rotDeg, excludeZoneIndex)

            if lastPhase ~= "bounds" or lastX ~= xCells or lastY ~= yCells
               or lastInvalid ~= invalid or lastRot ~= rotDeg
            then
                lastPhase, lastX, lastY, lastInvalid, lastRot = "bounds", xCells, yCells, invalid, rotDeg
                SendNUIMessage({
                    action = "updateZonePickerHud",
                    data   = {
                        phase   = "bounds",
                        xCells  = xCells,
                        yCells  = yCells,
                        cell    = cell,
                        invalid = invalid,
                        rotDeg  = rotDeg,
                    },
                })
            end

            if IsDisabledControlJustReleased(0, 24) and not invalid then
                -- Stored zone origin is the world centre of the bounding
                -- rect. The centre offset from the click point in the
                -- zone's local frame is ((minCx+maxCx)/2, (minCy+maxCy)/2)
                -- * cell; we rotate that back into world.
                local lcx = (minCx + maxCx) / 2.0 * cell
                local lcy = (minCy + maxCy) / 2.0 * cell
                local centerX = origin.wx + cosR * lcx - sinR * lcy
                local centerY = origin.wy + sinR * lcx + cosR * lcy
                result = {
                    origin = { x = centerX, y = centerY, z = origin.z, w = rotDeg },
                    xCells = xCells,
                    yCells = yCells,
                    cell   = cell,
                }
                break
            elseif IsDisabledControlJustReleased(0, 25) then
                -- RMB resets the origin and unlocks rotation again.
                origin = nil
                rotDeg = 0.0
            elseif IsDisabledControlJustReleased(0, 199)
                or IsDisabledControlJustReleased(0, 200)
                or IsDisabledControlJustReleased(0, 322) then
                break
            end
        end
    end

    SendNUIMessage({ action = "closeZonePickerHud" })
    InPlacement = false
    Preview.skipZoneIndex = nil
    restoreFromGizmo()
    return result
end

RegisterNUICallback("housingPickZoneArea", function(data, cb)
    cb({ ok = true })
    CreateThread(function()
        -- React sends a 0-based draft index; Lua's Preview.zones is 1-based.
        local jsIndex = data and data.zoneIndex
        local luaIndex = (type(jsIndex) == "number") and (jsIndex + 1) or nil
        local area = pickZoneArea(luaIndex)
        SendNUIMessage({
            action = "housingZoneAreaPicked",
            data = { zoneIndex = jsIndex, area = area },
        })
    end)
end)

-- ─── MLO polygon picker ───────────────────────────────────────────────────
-- Click to place a vertex on the floor; Backspace removes the last; E
-- confirms (≥3 vertices); Esc cancels. minZ/maxZ are derived from the
-- player's height range when confirming.

local function pickMloPolygon(initial)
    InPlacement = true
    minimizeForGizmo()
    SendNUIMessage({ action = "openZonePickerHud", data = { phase = "polygon" } })
    local points = {}
    if initial and type(initial.points) == "table" then
        for _, p in ipairs(initial.points) do
            points[#points + 1] = { x = p.x + 0.0, y = p.y + 0.0 }
        end
    end
    local result = nil
    local minZSeen, maxZSeen = math.huge, -math.huge
    while true do
        Wait(0)
        local cursor = raycastFromCamera(200.0)
        if cursor.z < minZSeen then minZSeen = cursor.z end
        if cursor.z > maxZSeen then maxZSeen = cursor.z end
        local pedZ = GetEntityCoords(PlayerPedId()).z
        if pedZ < minZSeen then minZSeen = pedZ end
        if pedZ > maxZSeen then maxZSeen = pedZ end

        DisableControlAction(0, 24,  true)
        DisableControlAction(0, 25,  true)
        DisableControlAction(0, 142, true)
        DisableControlAction(0, 257, true)
        DisableControlAction(0, 199, true)
        DisableControlAction(0, 200, true)
        DisableControlAction(0, 322, true)
        DisableControlAction(0, 177, true) -- BACKSPACE
        DisableControlAction(0, 38,  true) -- E
        if IsPauseMenuActive() then
            SetFrontendActive(false)
            ActivateFrontendMenu(`FE_MENU_VERSION_EMPTY_NO_BACKGROUND`, true, -1)
        end

        -- Render edges + vertex pillars.
        local color = { r = 80, g = 200, b = 220 }
        local n = #points
        local renderZ = pedZ
        for i = 1, n do
            local a = points[i]
            local b = points[(i % n) + 1]
            DrawLine(a.x, a.y, renderZ, b.x, b.y, renderZ, color.r, color.g, color.b, 220)
        end
        for _, p in ipairs(points) do
            DrawLine(p.x, p.y, renderZ - 1.0, p.x, p.y, renderZ + 3.0, color.r, color.g, color.b, 220)
        end
        -- Preview line from last vertex to cursor.
        if n > 0 then
            local last = points[n]
            DrawLine(last.x, last.y, renderZ, cursor.x, cursor.y, renderZ, 220, 220, 220, 140)
        end
        DrawLine(cursor.x, cursor.y, cursor.z - 0.5, cursor.x, cursor.y, cursor.z + 1.5, 220, 220, 80, 220)

        SendNUIMessage({
            action = "updateZonePickerHud",
            data   = { phase = "polygon", vertices = n },
        })

        if IsDisabledControlJustReleased(0, 24) then
            points[#points + 1] = { x = cursor.x, y = cursor.y }
        elseif IsDisabledControlJustReleased(0, 177) then
            if #points > 0 then points[#points] = nil end
        elseif IsDisabledControlJustReleased(0, 38) then
            if #points >= 3 then
                local minZ = (minZSeen == math.huge) and pedZ or minZSeen
                local maxZ = (maxZSeen == -math.huge) and (pedZ + 4.0) or (maxZSeen + 1.0)
                result = { points = points, minZ = minZ - 0.5, maxZ = maxZ + 0.5 }
                break
            end
        elseif IsDisabledControlJustReleased(0, 199)
            or IsDisabledControlJustReleased(0, 200)
            or IsDisabledControlJustReleased(0, 322) then
            break
        end
    end
    SendNUIMessage({ action = "closeZonePickerHud" })
    InPlacement = false
    restoreFromGizmo()
    return result
end

RegisterNUICallback("housingPickPolygon", function(data, cb)
    cb({ ok = true })
    CreateThread(function()
        local poly = pickMloPolygon(data and data.initial)
        SendNUIMessage({
            action = "housingPolygonPicked",
            data   = { polygon = poly },
        })
    end)
end)

RegisterNUICallback("housingSaveInterior", function(data, cb)
    cb({ ok = true })
    if data and type(data.payload) == "table" then
        TriggerServerEvent("pickle_drugs:saveInterior", data.payload)
    end
end)

RegisterNUICallback("housingDeleteInterior", function(data, cb)
    cb({ ok = true })
    if data and data.id then
        TriggerServerEvent("pickle_drugs:deleteInterior", data.id)
    end
end)

-- ─── NUI callbacks: houses ────────────────────────────────────────────────

RegisterNUICallback("housingPickDoor", function(data, cb)
    cb({ ok = true })
    CreateThread(function()
        local p = pickPoint(data and data.initial, "Place world door", "house_door")
        SendNUIMessage({
            action = "housingDoorPicked",
            data   = { houseDraft = data and data.houseDraft, point = p },
        })
    end)
end)

RegisterNUICallback("housingSaveHouse", function(data, cb)
    cb({ ok = true })
    if data and type(data.payload) == "table" then
        TriggerServerEvent("pickle_drugs:saveHouse", data.payload)
    end
end)

RegisterNUICallback("housingDeleteHouse", function(data, cb)
    cb({ ok = true })
    if data and data.id then
        TriggerServerEvent("pickle_drugs:deleteHouse", data.id)
    end
end)

-- ─── Admin teleport-into-interior shortcut ───────────────────────────────

RegisterNUICallback("housingTeleportToInteriorDoor", function(data, cb)
    cb({ ok = true })
    if not data or not data.x or not data.y or not data.z then return end
    local ped = PlayerPedId()
    SetEntityCoords(ped, data.x + 0.0, data.y + 0.0, data.z + 0.0, false, false, false, false)
    if data.w then SetEntityHeading(ped, data.w + 0.0) end
end)

AddEventHandler("onResourceStop", function(rn)
    if rn ~= GetCurrentResourceName() then return end
    clearPreviewState()
    if Open then SetNuiFocus(false, false) end
end)
