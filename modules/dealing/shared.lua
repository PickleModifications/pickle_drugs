-- Shared helpers for the Dealing module. Used by both client (preview
-- rendering, in-zone checks) and server (deal scheduling).

Dealing = Dealing or {}

--- True if a 2D point falls inside a circular zone.
function Dealing.PointInCircle(px, py, cx, cy, r)
    if not (px and py and cx and cy and r) then return false end
    local dx, dy = px - cx, py - cy
    return (dx * dx + dy * dy) <= (r * r)
end

--- Standard ray-casting point-in-polygon. `pts` is an array of
--- {x, y} vertices defining a (presumed simple, non-self-intersecting)
--- polygon. Returns false for malformed input or polygons with < 3
--- vertices.
function Dealing.PointInPolygon(px, py, pts)
    if not (px and py) or type(pts) ~= "table" or #pts < 3 then return false end
    local inside = false
    local n = #pts
    local j = n
    for i = 1, n do
        local xi, yi = pts[i].x, pts[i].y
        local xj, yj = pts[j].x, pts[j].y
        if (yi > py) ~= (yj > py) then
            local denom = (yj - yi)
            if denom ~= 0 then
                local xCross = (xj - xi) * (py - yi) / denom + xi
                if px < xCross then inside = not inside end
            end
        end
        j = i
    end
    return inside
end

--- Generic "is this 2D point inside this zone?" — dispatches on
--- zone.kind. Used by clients (in-world preview gating) and the server
--- (could be wired into proximity checks if we ever bound completion
--- to "inside the zone" rather than "near a deal point").
function Dealing.PointInZone(px, py, zone)
    if not zone then return false end
    if zone.kind == "polygon" then
        return Dealing.PointInPolygon(px, py, zone.points)
    end
    return Dealing.PointInCircle(px, py, zone.center_x, zone.center_y, zone.radius)
end

--- Synthetic spawn point derived from the zone's shape — used when the
--- zone has no admin-defined deal points. Circles → center; polygons
--- → centroid (arithmetic mean of vertices). Z and W default to the
--- zone's center_z and 0 respectively.
function Dealing.SyntheticDealPoint(zone)
    if not zone then return nil end
    if zone.kind == "polygon" and type(zone.points) == "table" and #zone.points >= 1 then
        local sx, sy = 0, 0
        for _, p in ipairs(zone.points) do
            sx = sx + (p.x or 0)
            sy = sy + (p.y or 0)
        end
        local n = #zone.points
        return { x = sx / n, y = sy / n, z = zone.center_z or 0, w = 0 }
    end
    return {
        x = zone.center_x or 0,
        y = zone.center_y or 0,
        z = zone.center_z or 0,
        w = 0,
    }
end

--- Returns the deal point the spawned customer should occupy. Picks
--- deterministically by index modulo so a single accepted deal always
--- lands on the same spot — clients spawning the ped from a server
--- broadcast must agree on which point to use. Falls back to a
--- synthetic centre point when the zone has no admin-defined deal
--- points so a freshly-authored zone still works without forcing the
--- admin to add explicit spawn spots first.
---@param zone table { deal_points = { {x,y,z,w}, ... }, ... }
---@param idx integer 1-based deal point index (server-stamped)
---@return table|nil { x, y, z, w }
function Dealing.PickDealPoint(zone, idx)
    if not zone then return nil end
    local pts = zone.deal_points
    if type(pts) == "table" and #pts > 0 then
        local i = ((tonumber(idx) or 1) - 1) % #pts + 1
        return pts[i]
    end
    return Dealing.SyntheticDealPoint(zone)
end

--- "Total" of a deal — qty * unitPrice, with a minimum of 0.
function Dealing.DealTotal(deal)
    if not deal then return 0 end
    local q = tonumber(deal.qty) or 0
    local p = tonumber(deal.unit_price) or 0
    return math.max(0, math.floor(q * p))
end
