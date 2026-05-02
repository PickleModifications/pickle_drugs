import { jsx as _jsx, jsxs as _jsxs } from "react/jsx-runtime";
import { useEffect, useRef, useState } from "react";
import L from "leaflet";
import "leaflet/dist/leaflet.css";
// ─── CRS calibration ──────────────────────────────────────────────────────
//
// Canonical GTA V Leaflet CRS: pixel = (scaleX·lng + originX,
// -scaleY·lat + originY). Coords arrive as [worldY, worldX] so that
// negative scaleY flips Y so increasing world Y reads as "up" on screen.
const CENTER_X = 117.3;
const CENTER_Y = 172.8;
const SCALE_X = 0.02072;
const SCALE_Y = 0.0205;
const TILE_BASE = "https://raw.githubusercontent.com/TheAzylium/bcsoMap/master/src/assets/mapStyles";
const TILES = {
    atlas: `${TILE_BASE}/styleAtlas/{z}/{x}/{y}.jpg`,
    satellite: `${TILE_BASE}/styleSatelite/{z}/{x}/{y}.jpg`,
};
const MAP_W = 320;
const MAP_H = 290;
const DEFAULT_COLOR = "#38bdf8";
// ─── Helpers ──────────────────────────────────────────────────────────────
function makeCRS() {
    return L.extend({}, L.CRS.Simple, {
        projection: L.Projection.LonLat,
        transformation: new L.Transformation(SCALE_X, CENTER_X, -SCALE_Y, CENTER_Y),
        scale: (zoom) => Math.pow(2, zoom),
        zoom: (sc) => Math.log(sc) / Math.LN2,
        distance: (a, b) => Math.hypot(b.lng - a.lng, b.lat - a.lat),
        infinite: true,
    });
}
// Standard ray-casting point-in-polygon. Mirrors Dealing.PointInPolygon
// in shared.lua (server uses the same predicate to validate, but doing
// the check client-side too gives instant UX feedback).
export function pointInPolygon(px, py, pts) {
    if (pts.length < 3)
        return false;
    let inside = false;
    let j = pts.length - 1;
    for (let i = 0; i < pts.length; i++) {
        const xi = pts[i].x, yi = pts[i].y;
        const xj = pts[j].x, yj = pts[j].y;
        if ((yi > py) !== (yj > py)) {
            const denom = yj - yi;
            if (denom !== 0) {
                const xCross = ((xj - xi) * (py - yi)) / denom + xi;
                if (px < xCross)
                    inside = !inside;
            }
        }
        j = i;
    }
    return inside;
}
// ─── Component ────────────────────────────────────────────────────────────
export function WorldMap({ zones, selectedZoneId, draftShape, draftDealPoints, mode, onSelectZone, onShapeChange, onAddDealPoint, onAddDealPointBlocked, }) {
    const containerRef = useRef(null);
    const mapRef = useRef(null);
    const overlayRef = useRef(null);
    // Stable refs so the map's click handler — bound once at mount —
    // always sees the latest props without re-binding.
    const stateRef = useRef({
        selectedZoneId, draftShape, mode,
        onShapeChange, onSelectZone, onAddDealPoint, onAddDealPointBlocked,
    });
    stateRef.current = {
        selectedZoneId, draftShape, mode,
        onShapeChange, onSelectZone, onAddDealPoint, onAddDealPointBlocked,
    };
    const [cursor, setCursor] = useState(null);
    // ── Mount the map exactly once ──────────────────────────────────
    useEffect(() => {
        const el = containerRef.current;
        if (!el || mapRef.current)
            return;
        const map = L.map(el, {
            crs: makeCRS(),
            maxBounds: [[-4000, -5500], [8000, 6000]],
            maxBoundsViscosity: 1.0,
            minZoom: 1,
            maxZoom: 5,
            zoom: 3,
            zoomControl: true,
            attributionControl: false,
            preferCanvas: true,
            center: [0, 0],
        });
        const atlas = L.tileLayer(TILES.atlas, {
            minZoom: 0, maxZoom: 5, noWrap: true, tileSize: 256,
        });
        const satellite = L.tileLayer(TILES.satellite, {
            minZoom: 0, maxZoom: 5, noWrap: true, tileSize: 256,
        });
        atlas.addTo(map);
        L.control.layers({ Atlas: atlas, Satellite: satellite }, undefined, { position: "topright", collapsed: true }).addTo(map);
        const overlay = L.layerGroup().addTo(map);
        overlayRef.current = overlay;
        // ── Background map click ────────────────────────────────────
        // Branches on the parent-controlled mode. The active draft's
        // polygon is non-interactive so map clicks fall through it;
        // other zones are interactive (their click handler selects).
        map.on("click", (e) => {
            const s = stateRef.current;
            if (!s.draftShape)
                return;
            const x = e.latlng.lng;
            const y = e.latlng.lat;
            if (s.mode === "deal") {
                if (pointInPolygon(x, y, s.draftShape.points)) {
                    s.onAddDealPoint(x, y);
                }
                else {
                    s.onAddDealPointBlocked?.();
                }
                return;
            }
            // mode === "edit": append a vertex.
            s.onShapeChange({ points: [...s.draftShape.points, { x, y }] });
        });
        map.on("mousemove", (e) => {
            setCursor({ x: e.latlng.lng, y: e.latlng.lat });
        });
        map.on("mouseout", () => setCursor(null));
        mapRef.current = map;
        return () => {
            map.remove();
            mapRef.current = null;
            overlayRef.current = null;
        };
    }, []);
    // ── Re-draw all zones + draft + deal points on prop changes ────
    useEffect(() => {
        const overlay = overlayRef.current;
        if (!overlay)
            return;
        overlay.clearLayers();
        // Render a polygon-shaped zone (or fall back to circle for
        // legacy unmigrated rows). Used both for the active draft and
        // for non-selected zones, with different opacity/interaction
        // settings supplied by the caller.
        const drawZone = (z, opts) => {
            const stroke = z.color || DEFAULT_COLOR;
            if (z.points && z.points.length >= 3) {
                const layer = L.polygon(z.points.map((p) => [p.y, p.x]), {
                    color: stroke,
                    weight: opts.weight,
                    fillColor: stroke,
                    fillOpacity: opts.fillOpacity,
                    interactive: opts.interactive,
                    bubblingMouseEvents: false,
                }).addTo(overlay);
                if (opts.onClick)
                    layer.on("click", opts.onClick);
            }
            else if (z.kind === "circle" &&
                Number.isFinite(z.centerX) &&
                Number.isFinite(z.centerY) &&
                z.radius > 0) {
                // Legacy circle row that hasn't been re-edited as a
                // polygon yet — render so it's still visible / clickable
                // for selection (admin can then redraw as polygon).
                const layer = L.circle([z.centerY, z.centerX], {
                    radius: z.radius,
                    color: stroke,
                    weight: opts.weight,
                    fillColor: stroke,
                    fillOpacity: opts.fillOpacity,
                    interactive: opts.interactive,
                    bubblingMouseEvents: false,
                }).addTo(overlay);
                if (opts.onClick)
                    layer.on("click", opts.onClick);
            }
        };
        // Other (non-selected) zones, dim, click-to-select.
        const others = zones.filter((z) => z.id !== selectedZoneId);
        others.forEach((z) => {
            drawZone(z, {
                interactive: true,
                fillOpacity: 0.08,
                weight: 1.5,
                onClick: () => onSelectZone(z.id),
            });
            // Light deal-point dots so the admin sees other zones'
            // routing context while editing this one.
            z.dealPoints.forEach((p) => {
                L.circleMarker([p.y, p.x], {
                    radius: 3,
                    color: "#000",
                    weight: 1,
                    fillColor: z.color || DEFAULT_COLOR,
                    fillOpacity: 0.55,
                    interactive: false,
                }).addTo(overlay);
            });
        });
        // Active zone (drafting) — pull color from the persisted row,
        // shape from the draft. Render even if the draft has no id yet
        // (brand-new unsaved zone won't be in `zones`).
        const selectedZone = selectedZoneId
            ? zones.find((z) => z.id === selectedZoneId)
            : undefined;
        if (draftShape) {
            const color = selectedZone?.color || DEFAULT_COLOR;
            const stroke = color;
            // Polygon outline — fill / line weight emphasised so the
            // active draft reads above the others on the map.
            if (draftShape.points.length >= 3) {
                L.polygon(draftShape.points.map((p) => [p.y, p.x]), {
                    color: stroke,
                    weight: 2.5,
                    fillColor: stroke,
                    fillOpacity: 0.20,
                    interactive: false,
                }).addTo(overlay);
            }
            else if (draftShape.points.length === 2) {
                L.polyline(draftShape.points.map((p) => [p.y, p.x]), { color: stroke, weight: 2, dashArray: "4 4", interactive: false }).addTo(overlay);
            }
            // Vertex handles — only interactive in edit mode. In deal
            // mode the polygon is read-only context (the admin is
            // placing deal points, not editing the shape) so vertex
            // dots render thinner and don't accept clicks.
            const editing = mode === "edit";
            draftShape.points.forEach((p, i) => {
                if (editing) {
                    L.circleMarker([p.y, p.x], {
                        radius: 5,
                        color: "#0c0c0c",
                        weight: 1.5,
                        fillColor: stroke,
                        fillOpacity: 1,
                        interactive: true,
                        bubblingMouseEvents: false,
                    })
                        .bindTooltip(String(i + 1), { direction: "top" })
                        .on("click", () => {
                        const cur = stateRef.current.draftShape;
                        if (!cur)
                            return;
                        const next = cur.points.slice();
                        next.splice(i, 1);
                        stateRef.current.onShapeChange({ points: next });
                    })
                        .addTo(overlay);
                }
                else {
                    // Read-only marker — small, non-interactive.
                    L.circleMarker([p.y, p.x], {
                        radius: 2.5,
                        color: stroke,
                        weight: 0,
                        fillColor: stroke,
                        fillOpacity: 0.7,
                        interactive: false,
                    }).addTo(overlay);
                }
            });
            // Active deal points (numbered, amber).
            draftDealPoints.forEach((p, i) => {
                L.circleMarker([p.y, p.x], {
                    radius: 5,
                    color: "#000",
                    weight: 1,
                    fillColor: "#fbbf24",
                    fillOpacity: 1,
                    interactive: false,
                })
                    .bindTooltip(String(i + 1), {
                    permanent: true,
                    direction: "right",
                    offset: [4, 0],
                })
                    .addTo(overlay);
            });
        }
    }, [zones, selectedZoneId, draftShape, draftDealPoints, mode, onSelectZone]);
    return (_jsxs("div", { className: "relative rounded-md overflow-hidden ring-1 ring-white/10 bg-[#0b1220]", style: { width: MAP_W, height: MAP_H }, children: [_jsx("div", { ref: containerRef, className: "w-full h-full" }), draftShape && (_jsx("div", { className: "absolute top-1 left-1 z-[400] text-[10px] px-2 py-1 rounded ring-1 " +
                    (mode === "deal"
                        ? "bg-amber-500/30 ring-amber-400/50 text-amber-50"
                        : "bg-sky-500/25 ring-sky-400/50 text-sky-50"), children: mode === "deal" ? "Placing deal points" : "Editing polygon" })), _jsx("div", { className: "absolute bottom-1 left-1 text-[9px] text-white/70 pointer-events-none bg-black/60 rounded px-1.5 py-0.5 tabular-nums", children: cursor
                    ? `x ${Math.round(cursor.x)}  y ${Math.round(cursor.y)}`
                    : !draftShape
                        ? "click any zone to edit · or create new"
                        : mode === "deal"
                            ? "click inside polygon to drop a deal point"
                            : "click to add vertex · click a vertex to remove" })] }));
}
