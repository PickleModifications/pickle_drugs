-- Housing shared helpers. Pure math: zone-local grid math, bbox→footprint,
-- collision, and id helpers. No state lives here. Server and client both
-- consume this — the server runs Housing.CanPlaceAt as the authority and
-- the client runs CellToWorld for the placement preview.

Housing = Housing or {}

-- ─── ID + bucket helpers ──────────────────────────────────────────────────

--- Deterministic numeric hash of a house id. Used to derive a stable
--- routing bucket from `Config.Housing.bucketBase`.
---@param id string
---@return integer
function Housing.HashId(id)
    if type(id) ~= "string" or id == "" then return 0 end
    local h = 0
    for i = 1, #id do
        h = (h * 131 + string.byte(id, i)) % 2147483647
    end
    return h
end

--- Returns the routing bucket for a house. MLO houses don't isolate, so
--- they always run in bucket 0.
---@param house table
---@return integer
function Housing.BucketFor(house)
    if not house or not house.id then return 0 end
    if house.kind == "mlo" then return 0 end
    local base = (Config and Config.Housing and Config.Housing.bucketBase) or 100000
    return base + (Housing.HashId(house.id) % 900000)
end

-- ─── Zone math ────────────────────────────────────────────────────────────

local function rad(deg) return (deg or 0.0) * math.pi / 180.0 end

--- Returns the zone-local (x, y) coordinates of the centre of cell
--- (cx, cy). Origin sits at the centre of the grid.
---@param zone table  { xCells, yCells, cell }
---@param cx integer  0-indexed column
---@param cy integer  0-indexed row
---@return number lx
---@return number ly
function Housing.CellLocal(zone, cx, cy)
    local lx = (cx + 0.5 - zone.xCells / 2) * zone.cell
    local ly = (cy + 0.5 - zone.yCells / 2) * zone.cell
    return lx, ly
end

--- Rotates a zone-local (lx, ly) into world space using the zone's
--- heading. Returns world (wx, wy, wz).
---@param zone table
---@param lx number
---@param ly number
---@return number wx
---@return number wy
---@return number wz
function Housing.LocalToWorld(zone, lx, ly)
    local h = rad(zone.origin.w)
    local cosH, sinH = math.cos(h), math.sin(h)
    local wx = zone.origin.x + cosH * lx - sinH * ly
    local wy = zone.origin.y + sinH * lx + cosH * ly
    local wz = zone.origin.z
    return wx, wy, wz
end

--- World (wx, wy) → zone-local (lx, ly). Useful for "what cell is the
--- player standing on?" queries.
function Housing.WorldToLocal(zone, wx, wy)
    local h = rad(zone.origin.w)
    local cosH, sinH = math.cos(h), math.sin(h)
    local dx, dy = wx - zone.origin.x, wy - zone.origin.y
    -- Inverse rotation = transpose for orthonormal R.
    local lx =  cosH * dx + sinH * dy
    local ly = -sinH * dx + cosH * dy
    return lx, ly
end

--- World (wx, wy) → cell indexes (cx, cy). Returns nil if outside grid.
---@return integer|nil cx
---@return integer|nil cy
function Housing.WorldToCell(zone, wx, wy)
    local lx, ly = Housing.WorldToLocal(zone, wx, wy)
    local cx = math.floor(lx / zone.cell + zone.xCells / 2)
    local cy = math.floor(ly / zone.cell + zone.yCells / 2)
    if cx < 0 or cy < 0 or cx >= zone.xCells or cy >= zone.yCells then
        return nil, nil
    end
    return cx, cy
end

--- Cell (cx, cy) → world centre coords + heading (heading = zone.origin.w).
---@return table { x, y, z, w }
function Housing.CellToWorld(zone, cx, cy)
    local lx, ly = Housing.CellLocal(zone, cx, cy)
    local wx, wy, wz = Housing.LocalToWorld(zone, lx, ly)
    return { x = wx, y = wy, z = wz, w = zone.origin.w or 0.0 }
end

-- ─── Heading helpers ──────────────────────────────────────────────────────
-- A placed entity's world heading is `zone.origin.w + rotIndex * 90`, where
-- `rotIndex` is the 0..3 quarter-turn the player picked during placement.
-- Both server (when persisting) and client (when rendering the preview, or
-- recovering an initial rotIndex on move) must agree on this formula —
-- centralising it here keeps the bug class "forgot to add rotIndex*90 in
-- one of N call sites" out of the codebase.

--- Final world heading (degrees) for an entity placed at `rotIndex` in `zone`.
---@param zone table
---@param rotIndex integer  0..3
---@return number headingDeg
function Housing.WorldHeading(zone, rotIndex)
    local zoneW = (zone and zone.origin and zone.origin.w) or 0.0
    local r = ((tonumber(rotIndex) or 0) % 4 + 4) % 4
    return (zoneW + r * 90.0) % 360
end

--- Inverse of WorldHeading: given a stored world heading and the source
--- zone, recover the 0..3 rotIndex. Rounds to the nearest quarter-turn so
--- legacy rows that drifted slightly still snap cleanly.
---@param zone table
---@param headingDeg number
---@return integer rotIndex
function Housing.RotIndexFromHeading(zone, headingDeg)
    local zoneW = (zone and zone.origin and zone.origin.w) or 0.0
    local relDeg = (((tonumber(headingDeg) or 0.0) - zoneW) % 360 + 360) % 360
    return math.floor((relDeg + 45) / 90) % 4
end

-- ─── Footprint ────────────────────────────────────────────────────────────

--- Given model bbox extents (sizeX, sizeY in metres) and a zone, returns
--- the footprint in cells. Always at least 1×1.
---@param sizeX number
---@param sizeY number
---@param zone table
---@return integer w
---@return integer h
function Housing.FootprintFromSize(sizeX, sizeY, zone)
    local cell = zone.cell or 0.5
    local w = math.max(1, math.ceil(math.abs(sizeX) / cell))
    local h = math.max(1, math.ceil(math.abs(sizeY) / cell))
    return w, h
end

-- ─── Collision ────────────────────────────────────────────────────────────

--- Checks whether a footprint of size (w, h) anchored at (cx, cy) fits in
--- the zone and doesn't overlap `occupied`. `occupied` is a set keyed
--- "cx:cy" → true. Returns ok, reason.
---@param zone table
---@param cx integer
---@param cy integer
---@param w integer
---@param h integer
---@param occupied table
---@return boolean ok
---@return string|nil reason
function Housing.CanPlaceAt(zone, cx, cy, w, h, occupied)
    if not zone then return false, "no_zone" end
    cx, cy, w, h = math.floor(cx), math.floor(cy), math.floor(w), math.floor(h)
    if w < 1 or h < 1 then return false, "bad_size" end
    if cx < 0 or cy < 0 then return false, "out_of_bounds" end
    if cx + w > zone.xCells or cy + h > zone.yCells then
        return false, "out_of_bounds"
    end
    if occupied then
        for ox = cx, cx + w - 1 do
            for oy = cy, cy + h - 1 do
                if occupied[ox .. ":" .. oy] then return false, "intersects" end
            end
        end
    end
    return true, nil
end

--- Builds an occupancy map for a zone from a list of placed entities.
--- Each entity is `{ cell_x, cell_y, cell_w, cell_h, zone_id }`. Entries
--- belonging to other zones are skipped.
---@param zone table
---@param entities table
---@return table occupied
function Housing.BuildOccupancy(zone, entities)
    local occ = {}
    if not entities then return occ end
    for _, e in ipairs(entities) do
        if e.zone_id == zone.id then
            local cx, cy = math.floor(e.cell_x or 0), math.floor(e.cell_y or 0)
            local w, h   = math.max(1, math.floor(e.cell_w or 1)),
                           math.max(1, math.floor(e.cell_h or 1))
            for ox = cx, cx + w - 1 do
                for oy = cy, cy + h - 1 do
                    occ[ox .. ":" .. oy] = e.id or true
                end
            end
        end
    end
    return occ
end

-- ─── Misc ─────────────────────────────────────────────────────────────────

--- Returns the corner positions of a zone in world coords (4 vec2s
--- starting bottom-left, going counter-clockwise). Used for the polyzone
--- the client builds for "is the player inside this zone" checks.
function Housing.ZoneCornersWorld(zone)
    local halfX = zone.xCells * zone.cell / 2
    local halfY = zone.yCells * zone.cell / 2
    local corners = {
        { -halfX, -halfY },
        {  halfX, -halfY },
        {  halfX,  halfY },
        { -halfX,  halfY },
    }
    local out = {}
    for _, c in ipairs(corners) do
        local wx, wy, _ = Housing.LocalToWorld(zone, c[1], c[2])
        out[#out + 1] = { x = wx, y = wy }
    end
    return out
end

function Housing.LeaseCycleMs(house)
    if not house then return 0 end
    return tonumber(house.rent_cycle_ms) or 0
end

return Housing
