// Admin housing panel. Bottom-anchored bar (Plant-Console style) over
// Houses (world buildings) and Interiors (reusable templates). Both list
// / create / edit / delete the matching row type. The gizmo flows are
// driven by Lua — we send `housingPickPoint` callbacks and listen for the
// picked coords coming back as NUI events.
//
// Walk mode releases NUI focus so the admin can move around and inspect
// their work in-world. The panel stays rendered (preview entities + zones
// remain visible via the Lua-side preview layer) but pointer-events are
// disabled until they re-enter edit mode.

import { useEffect, useMemo, useState } from "react";
import {
    Plus, Trash2, X, MapPin, Save, Building, Layers,
    ArrowLeft, Footprints, Pencil, Hexagon,
} from "lucide-react";

import { fetchNui, useNuiEvent } from "@/lib/nui";

function DrugsTabBar({ active }: { active: "houses" | "interiors" }) {
    const tab = (id: "houses" | "interiors", label: string, Icon: React.ElementType) => {
        const isActive = active === id;
        return (
            <button
                key={id}
                onClick={() => fetchNui("drugsAdminSwitchTab", { tab: id })}
                disabled={isActive}
                className={"px-3 py-1.5 rounded text-xs ring-1 transition-colors inline-flex items-center gap-1.5 " +
                    (isActive
                        ? "bg-emerald-500/25 ring-emerald-400/60 text-emerald-50 cursor-default"
                        : "ring-white/15 text-white/70 hover:bg-white/[0.06]")}
            >
                <Icon className="h-3.5 w-3.5" />
                {label}
            </button>
        );
    };
    return (
        <div className="flex items-center justify-center gap-1">
            {tab("houses", "Properties", Building)}
            {tab("interiors", "Interiors", Layers)}
        </div>
    );
}

export type Vec4 = { x: number; y: number; z: number; w: number };

export type Zone = {
    id: string;
    label: string;
    origin: Vec4;
    xCells: number;
    yCells: number;
    cell: number;
    zTolerance?: number;
};

export type Interior = {
    id: string;
    label: string;
    kind: "teleport" | "mlo";
    door_x: number; door_y: number; door_z: number; door_w: number;
    exit_x: number; exit_y: number; exit_z: number; exit_w: number;
    idle_x: number; idle_y: number; idle_z: number; idle_w: number;
    mgmt_x: number; mgmt_y: number; mgmt_z: number; mgmt_w: number;
    zones: Zone[];
    mlo_polygon?: { points: { x: number; y: number }[]; minZ?: number; maxZ?: number } | null;
};

export type House = {
    id: string;
    label: string;
    interior_id: string;
    door_world_x: number; door_world_y: number; door_world_z: number; door_world_w: number;
    sale_enabled: boolean; sale_price: number;
    rent_enabled: boolean; rent_price: number; rent_cycle_ms: number;
    owner_citizenid?: string | null;
    tenure: "none" | "owned" | "rented";
    rent_due_at: number;
    residents: string[];
    bucket: number;
};

const DEFAULT_INTERIOR = (): Interior => ({
    id: "", label: "New Interior", kind: "teleport",
    door_x: 0, door_y: 0, door_z: 0, door_w: 0,
    exit_x: 0, exit_y: 0, exit_z: 0, exit_w: 0,
    idle_x: 0, idle_y: 0, idle_z: 0, idle_w: 0,
    mgmt_x: 0, mgmt_y: 0, mgmt_z: 0, mgmt_w: 0,
    zones: [],
});

const DEFAULT_HOUSE = (interiorId: string): House => ({
    id: "", label: "New Property", interior_id: interiorId,
    door_world_x: 0, door_world_y: 0, door_world_z: 0, door_world_w: 0,
    sale_enabled: false, sale_price: 1000,
    rent_enabled: false, rent_price: 250, rent_cycle_ms: 7 * 24 * 60 * 60 * 1000,
    tenure: "none", rent_due_at: 0, residents: [], bucket: 0,
});

// MLO data lives on a per-property "shadow interior" server-side. The UI
// edits it as a flat object alongside the property draft; on save the
// server creates/updates the shadow interior and links it.
type MloDraft = {
    label: string;
    idle_x: number; idle_y: number; idle_z: number; idle_w: number;
    mgmt_x: number; mgmt_y: number; mgmt_z: number; mgmt_w: number;
    zones: Zone[];
    mlo_polygon: { points: { x: number; y: number }[]; minZ?: number; maxZ?: number } | null;
};

const DEFAULT_MLO = (label: string): MloDraft => ({
    label,
    idle_x: 0, idle_y: 0, idle_z: 0, idle_w: 0,
    mgmt_x: 0, mgmt_y: 0, mgmt_z: 0, mgmt_w: 0,
    zones: [],
    mlo_polygon: null,
});

function useHousingData(initial: { interiors: Interior[]; houses: House[] }) {
    const [interiors, setInteriors] = useState<Interior[]>(initial.interiors);
    const [houses, setHouses] = useState<House[]>(initial.houses);
    useNuiEvent<{ interiors?: Interior[]; houses?: House[] }>("housingList", (d) => {
        if (d?.interiors) setInteriors(d.interiors);
        if (d?.houses) setHouses(d.houses);
    });
    return { interiors, houses, setInteriors, setHouses };
}

// ─── Compact point editor (inline button + coord summary) ───────────────

function PointEditor({
    label, kind, value, onChange, hint,
}: {
    label: string;
    kind: string;
    value: Vec4;
    onChange: (v: Vec4) => void;
    hint?: string;
}) {
    const isPlaced = value.x !== 0 || value.y !== 0 || value.z !== 0;
    const onPick = () => {
        fetchNui("housingPickPoint", { kind, label, initial: value });
    };
    useNuiEvent<{ kind: string; point: Vec4 | null }>("housingPointPicked", (d) => {
        if (d.kind === kind && d.point) onChange(d.point);
    });
    return (
        <div className="flex items-center justify-between gap-2 rounded-md bg-white/[0.03] ring-1 ring-white/10 px-2.5 py-1.5">
            <div className="min-w-0 flex flex-col leading-tight">
                <span className="text-[10px] uppercase tracking-wider text-white/45">{label}</span>
                <span className="text-[10px] tabular-nums text-white/60 truncate">
                    {isPlaced
                        ? `${value.x.toFixed(1)}, ${value.y.toFixed(1)}, ${value.z.toFixed(1)} · ${(value.w || 0).toFixed(0)}°`
                        : "(not placed)"}
                </span>
                {hint && <span className="text-[9px] text-white/35 italic truncate">{hint}</span>}
            </div>
            <button
                onClick={onPick}
                className="shrink-0 inline-flex items-center gap-1 px-2 py-1 rounded ring-1 ring-emerald-400/40 bg-emerald-500/10 text-emerald-100 hover:bg-emerald-500/25 text-[11px]"
            >
                <MapPin className="h-3 w-3" />
                Place
            </button>
        </div>
    );
}

// ─── Interior editor (inline, columnar) ─────────────────────────────────

function InteriorEditor({
    initial, onClose, onSaved,
}: {
    initial: Interior;
    onClose: () => void;
    onSaved: () => void;
}) {
    // Interior templates are teleport-only; MLOs are now configured
    // inline on a Property and never live in this list.
    const [draft, setDraft] = useState<Interior>({ ...initial, kind: "teleport" });
    const update = (patch: Partial<Interior>) =>
        setDraft((d) => ({ ...d, ...patch }));

    useEffect(() => {
        const points = [
            { kind: "idle", x: draft.idle_x, y: draft.idle_y, z: draft.idle_z, w: draft.idle_w },
            { kind: "mgmt", x: draft.mgmt_x, y: draft.mgmt_y, z: draft.mgmt_z, w: draft.mgmt_w },
            { kind: "door", x: draft.door_x, y: draft.door_y, z: draft.door_z, w: draft.door_w },
            { kind: "exit", x: draft.exit_x, y: draft.exit_y, z: draft.exit_z, w: draft.exit_w },
        ];
        const zones = draft.zones.map((z) => ({
            origin: z.origin, xCells: z.xCells, yCells: z.yCells, cell: z.cell,
        }));
        fetchNui("housingSetPreview", { points, zones });
    }, [draft]);
    useEffect(() => () => { fetchNui("housingClearPreview", {}); }, []);

    useNuiEvent<{ zoneIndex: number; area: { origin: Vec4; xCells: number; yCells: number; cell: number } | null }>(
        "housingZoneAreaPicked",
        (d) => {
            const area = d.area;
            if (!area) return;
            setDraft((cur) => {
                const zones = [...cur.zones];
                if (zones[d.zoneIndex]) {
                    zones[d.zoneIndex] = {
                        ...zones[d.zoneIndex],
                        origin: area.origin,
                        xCells: area.xCells,
                        yCells: area.yCells,
                        cell: area.cell,
                    };
                }
                return { ...cur, zones };
            });
        }
    );

    const addZone = () => {
        setDraft((d) => ({
            ...d, zones: [...d.zones, {
                id: `zone_${d.zones.length + 1}`,
                label: `Zone ${d.zones.length + 1}`,
                origin: { x: 0, y: 0, z: 0, w: 0 },
                xCells: 1, yCells: 1, cell: 1.0, zTolerance: 0.6,
            }],
        }));
    };
    const removeZone = (i: number) =>
        setDraft((d) => ({ ...d, zones: d.zones.filter((_, idx) => idx !== i) }));

    const save = () => {
        fetchNui("housingSaveInterior", { payload: draft });
        onSaved();
    };

    return (
        <div className="grid grid-cols-[260px_minmax(0,1fr)_minmax(0,1fr)] gap-3 h-full min-h-0">
            {/* Column 1 — meta */}
            <div className="flex flex-col gap-2 min-h-0">
                <label className="flex flex-col gap-1">
                    <span className="text-[10px] uppercase tracking-wider text-white/45">Label</span>
                    <input value={draft.label}
                        onChange={(e) => update({ label: e.target.value })}
                        className="bg-white/[0.06] ring-1 ring-white/20 rounded-md px-2.5 py-1.5 text-xs text-white outline-none focus:ring-emerald-400/60" />
                </label>
                <div className="text-[10px] text-white/40 italic leading-snug">
                    Interior templates are reusable bucketed interiors. MLOs are
                    configured per-property, not here.
                </div>
                <div className="mt-auto flex gap-2">
                    <button onClick={onClose}
                        className="flex-1 px-2.5 py-1.5 rounded-md ring-1 ring-white/20 text-white/70 hover:bg-white/10 text-xs inline-flex items-center justify-center gap-1.5">
                        <ArrowLeft className="h-3.5 w-3.5" /> Back
                    </button>
                    <button onClick={save}
                        className="flex-1 px-2.5 py-1.5 inline-flex items-center justify-center gap-1.5 rounded-md ring-1 ring-emerald-400/50 bg-emerald-500/15 text-emerald-100 hover:bg-emerald-500/30 text-xs">
                        <Save className="h-3.5 w-3.5" /> Save
                    </button>
                </div>
            </div>

            {/* Column 2 — interior points */}
            <div className="flex flex-col gap-1.5 min-h-0">
                <span className="text-[11px] uppercase tracking-wider text-white/55 font-medium">Points</span>
                <div className="flex-1 overflow-y-auto pr-1 -mr-1 flex flex-col gap-1.5">
                    <PointEditor label="Door (inside)" kind="door"
                        value={{ x: draft.door_x, y: draft.door_y, z: draft.door_z, w: draft.door_w }}
                        onChange={(p) => update({ door_x: p.x, door_y: p.y, door_z: p.z, door_w: p.w })}
                        hint="Lands on entry; 'Leave' target." />
                    <PointEditor label="Exit (outside)" kind="exit"
                        value={{ x: draft.exit_x, y: draft.exit_y, z: draft.exit_z, w: draft.exit_w }}
                        onChange={(p) => update({ exit_x: p.x, exit_y: p.y, exit_z: p.z, exit_w: p.w })}
                        hint="Lands on exit / lease lapse." />
                    <PointEditor label="Idle (employees)" kind="idle"
                        value={{ x: draft.idle_x, y: draft.idle_y, z: draft.idle_z, w: draft.idle_w }}
                        onChange={(p) => update({ idle_x: p.x, idle_y: p.y, idle_z: p.z, idle_w: p.w })}
                        hint="Workers idle here." />
                    <PointEditor label="Management" kind="mgmt"
                        value={{ x: draft.mgmt_x, y: draft.mgmt_y, z: draft.mgmt_z, w: draft.mgmt_w }}
                        onChange={(p) => update({ mgmt_x: p.x, mgmt_y: p.y, mgmt_z: p.z, mgmt_w: p.w })}
                        hint="Management menu target." />
                </div>
            </div>

            {/* Column 3 — zones */}
            <div className="flex flex-col gap-1.5 min-h-0">
                <div className="flex items-center justify-between">
                    <span className="text-[11px] uppercase tracking-wider text-white/55 font-medium">Zones</span>
                    <button onClick={addZone}
                        className="inline-flex items-center gap-1 px-2 py-1 rounded ring-1 ring-emerald-400/40 bg-emerald-500/10 text-emerald-100 hover:bg-emerald-500/25 text-[11px]">
                        <Plus className="h-3 w-3" /> Add
                    </button>
                </div>
                <div className="flex-1 overflow-y-auto pr-1 -mr-1 flex flex-col gap-1.5">
                    {draft.zones.length === 0 && (
                        <div className="text-[11px] italic text-white/40">
                            No zones yet — at least one needed for placement.
                        </div>
                    )}
                    {draft.zones.map((z, i) => (
                        <div key={i} className="rounded-md bg-white/[0.03] ring-1 ring-white/10 p-2 space-y-1.5">
                            <div className="grid grid-cols-[1fr_auto] gap-1.5">
                                <input value={z.label} onChange={(e) => {
                                    const v = e.target.value; setDraft((d) => {
                                        const zones = [...d.zones]; zones[i] = { ...zones[i], label: v }; return { ...d, zones };
                                    });
                                }} placeholder="label"
                                    className="bg-white/[0.06] ring-1 ring-white/20 rounded-md px-2 py-1 text-[11px] text-white" />
                                <button onClick={() => removeZone(i)}
                                    className="h-7 w-7 inline-flex items-center justify-center rounded-md ring-1 ring-white/20 text-white/70 hover:text-red-200 hover:bg-red-500/15">
                                    <Trash2 className="h-3 w-3" />
                                </button>
                            </div>
                            <div className="flex items-center justify-between gap-2 rounded bg-white/[0.04] ring-1 ring-white/10 px-2 py-1">
                                <span className="text-[10px] tabular-nums text-white/60 truncate">
                                    {z.origin.x !== 0 || z.origin.y !== 0
                                        ? `${z.origin.x.toFixed(1)}, ${z.origin.y.toFixed(1)} · ${z.xCells}×${z.yCells}`
                                        : "(not placed)"}
                                </span>
                                <button onClick={() => fetchNui("housingPickZoneArea", { zoneIndex: i })}
                                    className="inline-flex items-center gap-1 px-2 py-0.5 rounded ring-1 ring-amber-400/40 bg-amber-500/10 text-amber-100 hover:bg-amber-500/25 text-[10px]">
                                    <MapPin className="h-3 w-3" /> Place
                                </button>
                            </div>
                        </div>
                    ))}
                </div>
            </div>
        </div>
    );
}

// ─── Listing block (sale + rent) — shared across teleport / MLO ─────────

function ListingBlock({
    draft, update,
}: {
    draft: House;
    update: (patch: Partial<House>) => void;
}) {
    return (
        <>
            <div className="rounded-md bg-white/[0.03] ring-1 ring-white/10 p-2 space-y-1.5">
                <label className="flex items-center gap-2">
                    <input type="checkbox" checked={draft.sale_enabled}
                        onChange={(e) => update({ sale_enabled: e.target.checked })} />
                    <span className="text-xs text-white/85">For sale</span>
                </label>
                <input type="number" min={0} value={draft.sale_price} disabled={!draft.sale_enabled}
                    onChange={(e) => update({ sale_price: parseInt(e.target.value) || 0 })}
                    placeholder="price"
                    className="bg-white/[0.06] ring-1 ring-white/20 rounded-md px-2 py-1 text-[11px] text-white w-full disabled:opacity-40" />
            </div>
            <div className="rounded-md bg-white/[0.03] ring-1 ring-white/10 p-2 space-y-1.5">
                <label className="flex items-center gap-2">
                    <input type="checkbox" checked={draft.rent_enabled}
                        onChange={(e) => update({ rent_enabled: e.target.checked })} />
                    <span className="text-xs text-white/85">For rent</span>
                </label>
                <div className="grid grid-cols-2 gap-1.5">
                    <input type="number" min={0} value={draft.rent_price} disabled={!draft.rent_enabled}
                        onChange={(e) => update({ rent_price: parseInt(e.target.value) || 0 })}
                        placeholder="price"
                        className="bg-white/[0.06] ring-1 ring-white/20 rounded-md px-2 py-1 text-[11px] text-white disabled:opacity-40" />
                    <input type="number" min={0}
                        value={Math.round(draft.rent_cycle_ms / (24 * 60 * 60 * 1000))}
                        disabled={!draft.rent_enabled}
                        onChange={(e) => update({ rent_cycle_ms: (parseInt(e.target.value) || 1) * 24 * 60 * 60 * 1000 })}
                        placeholder="days/cycle"
                        className="bg-white/[0.06] ring-1 ring-white/20 rounded-md px-2 py-1 text-[11px] text-white disabled:opacity-40" />
                </div>
            </div>
        </>
    );
}

// ─── Property editor (inline) ──────────────────────────────────────────
//
// A property is either:
//   - "Interior Template" → references a reusable teleport interior.
//   - "MLO" → has an inline (per-property) interior config; the server
//     persists this as a hidden "shadow" interior linked to the property.

function HouseEditor({
    initial, initialMlo, interiors, onClose, onSaved,
}: {
    initial: House;
    initialMlo: MloDraft | null; // present when editing an existing MLO property
    interiors: Interior[];
    onClose: () => void;
    onSaved: () => void;
}) {
    // Type starts as "mlo" if the existing house is linked to an MLO
    // shadow interior; otherwise default to "teleport".
    const initialType: "teleport" | "mlo" = initialMlo ? "mlo" : "teleport";
    const [type, setType] = useState<"teleport" | "mlo">(initialType);
    const [draft, setDraft] = useState<House>(initial);
    const [mlo, setMlo] = useState<MloDraft>(initialMlo ?? DEFAULT_MLO(initial.label || "Property MLO"));

    const update = (patch: Partial<House>) => setDraft((d) => ({ ...d, ...patch }));
    const updateMlo = (patch: Partial<MloDraft>) => setMlo((m) => ({ ...m, ...patch }));

    // Mirror the editor's preview into the in-world layer. World door
    // always renders; MLO mode also renders idle / mgmt and any zones.
    useEffect(() => {
        const points: { kind: string; x: number; y: number; z: number; w: number }[] = [{
            kind: "house_door",
            x: draft.door_world_x, y: draft.door_world_y,
            z: draft.door_world_z, w: draft.door_world_w,
        }];
        let zones: { origin: Vec4; xCells: number; yCells: number; cell: number }[] = [];
        if (type === "mlo") {
            points.push(
                { kind: "idle", x: mlo.idle_x, y: mlo.idle_y, z: mlo.idle_z, w: mlo.idle_w },
                { kind: "mgmt", x: mlo.mgmt_x, y: mlo.mgmt_y, z: mlo.mgmt_z, w: mlo.mgmt_w },
            );
            zones = mlo.zones.map((z) => ({
                origin: z.origin, xCells: z.xCells, yCells: z.yCells, cell: z.cell,
            }));
        }
        fetchNui("housingSetPreview", { points, zones });
    }, [draft, mlo, type]);
    useEffect(() => () => { fetchNui("housingClearPreview", {}); }, []);

    useNuiEvent<{ point: Vec4 | null }>("housingDoorPicked", (d) => {
        if (d.point) update({
            door_world_x: d.point.x, door_world_y: d.point.y,
            door_world_z: d.point.z, door_world_w: d.point.w,
        });
    });

    // MLO-mode zone picks reuse the same housingZoneAreaPicked event but
    // route into the mlo draft when type==mlo.
    useNuiEvent<{ zoneIndex: number; area: { origin: Vec4; xCells: number; yCells: number; cell: number } | null }>(
        "housingZoneAreaPicked",
        (d) => {
            if (type !== "mlo") return;
            const area = d.area;
            if (!area) return;
            setMlo((cur) => {
                const zones = [...cur.zones];
                if (zones[d.zoneIndex]) {
                    zones[d.zoneIndex] = {
                        ...zones[d.zoneIndex],
                        origin: area.origin,
                        xCells: area.xCells, yCells: area.yCells, cell: area.cell,
                    };
                }
                return { ...cur, zones };
            });
        }
    );

    useNuiEvent<{ polygon: { points: { x: number; y: number }[]; minZ?: number; maxZ?: number } | null }>(
        "housingPolygonPicked",
        (d) => { if (d?.polygon) updateMlo({ mlo_polygon: d.polygon }); }
    );

    const addMloZone = () => updateMlo({
        zones: [...mlo.zones, {
            id: `zone_${mlo.zones.length + 1}`,
            label: `Zone ${mlo.zones.length + 1}`,
            origin: { x: 0, y: 0, z: 0, w: 0 },
            xCells: 1, yCells: 1, cell: 1.0, zTolerance: 0.6,
        }],
    });
    const removeMloZone = (i: number) =>
        updateMlo({ zones: mlo.zones.filter((_, idx) => idx !== i) });

    const teleportInteriors = interiors.filter(
        (i) => i.kind === "teleport" && !i.id.startsWith("_mlo_") && i.id !== "_legacy"
    );

    const canSave =
        type === "teleport"
            ? !!draft.interior_id
            : true;

    const save = () => {
        if (type === "teleport") {
            fetchNui("housingSaveHouse", { payload: { ...draft, kind: "teleport" } });
        } else {
            fetchNui("housingSaveHouse", { payload: { ...draft, kind: "mlo", mlo } });
        }
        onSaved();
    };

    return (
        <div className="grid grid-cols-[260px_minmax(0,1fr)_minmax(0,1fr)] gap-3 h-full min-h-0">
            {/* Column 1 — meta + type + door */}
            <div className="flex flex-col gap-2 min-h-0">
                <label className="flex flex-col gap-1">
                    <span className="text-[10px] uppercase tracking-wider text-white/45">Label</span>
                    <input value={draft.label}
                        onChange={(e) => update({ label: e.target.value })}
                        className="bg-white/[0.06] ring-1 ring-white/20 rounded-md px-2.5 py-1.5 text-xs text-white outline-none focus:ring-emerald-400/60" />
                </label>
                <div className="flex flex-col gap-1">
                    <span className="text-[10px] uppercase tracking-wider text-white/45">Type</span>
                    <div className="grid grid-cols-2 gap-1">
                        <button
                            onClick={() => setType("teleport")}
                            disabled={!!initial.id && initialType === "mlo"}
                            className={"px-2 py-1.5 rounded ring-1 text-[11px] inline-flex items-center justify-center gap-1.5 disabled:opacity-40 " +
                                (type === "teleport"
                                    ? "bg-emerald-500/25 ring-emerald-400/60 text-emerald-50"
                                    : "ring-white/15 text-white/70 hover:bg-white/[0.06]")}
                        >
                            <Layers className="h-3 w-3" /> Interior
                        </button>
                        <button
                            onClick={() => setType("mlo")}
                            disabled={!!initial.id && initialType === "teleport"}
                            className={"px-2 py-1.5 rounded ring-1 text-[11px] inline-flex items-center justify-center gap-1.5 disabled:opacity-40 " +
                                (type === "mlo"
                                    ? "bg-emerald-500/25 ring-emerald-400/60 text-emerald-50"
                                    : "ring-white/15 text-white/70 hover:bg-white/[0.06]")}
                        >
                            <Building className="h-3 w-3" /> MLO
                        </button>
                    </div>
                </div>
                {type === "teleport" && (
                    <label className="flex flex-col gap-1">
                        <span className="text-[10px] uppercase tracking-wider text-white/45">Interior template</span>
                        <select value={draft.interior_id}
                            onChange={(e) => update({ interior_id: e.target.value })}
                            className="bg-white/[0.06] ring-1 ring-white/20 rounded-md px-2.5 py-1.5 text-xs text-white outline-none">
                            <option value="" className="bg-neutral-900">— pick —</option>
                            {teleportInteriors.map((i) => (
                                <option key={i.id} value={i.id} className="bg-neutral-900">{i.label}</option>
                            ))}
                        </select>
                    </label>
                )}
                <PointEditor label="World door" kind="house_door"
                    value={{ x: draft.door_world_x, y: draft.door_world_y, z: draft.door_world_z, w: draft.door_world_w }}
                    onChange={(p) => update({
                        door_world_x: p.x, door_world_y: p.y,
                        door_world_z: p.z, door_world_w: p.w,
                    })}
                    hint="Door blip / 'Inspect' / 'Enter' target." />
                <div className="mt-auto flex gap-2">
                    <button onClick={onClose}
                        className="flex-1 px-2.5 py-1.5 rounded-md ring-1 ring-white/20 text-white/70 hover:bg-white/10 text-xs inline-flex items-center justify-center gap-1.5">
                        <ArrowLeft className="h-3.5 w-3.5" /> Back
                    </button>
                    <button onClick={save} disabled={!canSave}
                        className="flex-1 px-2.5 py-1.5 inline-flex items-center justify-center gap-1.5 rounded-md ring-1 ring-emerald-400/50 bg-emerald-500/15 text-emerald-100 hover:bg-emerald-500/30 text-xs disabled:opacity-40">
                        <Save className="h-3.5 w-3.5" /> Save
                    </button>
                </div>
            </div>

            {/* Column 2 — listing (teleport) OR MLO points + listing (mlo) */}
            <div className="flex flex-col gap-1.5 min-h-0 overflow-y-auto pr-1 -mr-1">
                {type === "teleport" ? (
                    <>
                        <span className="text-[11px] uppercase tracking-wider text-white/55 font-medium">Listing</span>
                        <ListingBlock draft={draft} update={update} />
                    </>
                ) : (
                    <>
                        <span className="text-[11px] uppercase tracking-wider text-white/55 font-medium">MLO points</span>
                        <PointEditor label="Idle (employees)" kind="idle"
                            value={{ x: mlo.idle_x, y: mlo.idle_y, z: mlo.idle_z, w: mlo.idle_w }}
                            onChange={(p) => updateMlo({ idle_x: p.x, idle_y: p.y, idle_z: p.z, idle_w: p.w })}
                            hint="Workers idle here." />
                        <PointEditor label="Management" kind="mgmt"
                            value={{ x: mlo.mgmt_x, y: mlo.mgmt_y, z: mlo.mgmt_z, w: mlo.mgmt_w }}
                            onChange={(p) => updateMlo({ mgmt_x: p.x, mgmt_y: p.y, mgmt_z: p.z, mgmt_w: p.w })}
                            hint="Management menu target." />
                        <div className="flex items-center justify-between gap-2 rounded-md bg-white/[0.03] ring-1 ring-white/10 px-2.5 py-1.5">
                            <div className="min-w-0 flex flex-col leading-tight">
                                <span className="text-[10px] uppercase tracking-wider text-white/45">MLO bounds</span>
                                <span className="text-[10px] tabular-nums text-white/60 truncate">
                                    {mlo.mlo_polygon
                                        ? `${mlo.mlo_polygon.points.length} vertices · z ${(mlo.mlo_polygon.minZ ?? 0).toFixed(1)}–${(mlo.mlo_polygon.maxZ ?? 0).toFixed(1)}`
                                        : "(not set)"}
                                </span>
                            </div>
                            <button
                                onClick={() => fetchNui("housingPickPolygon", { initial: mlo.mlo_polygon })}
                                className="shrink-0 inline-flex items-center gap-1 px-2 py-1 rounded ring-1 ring-amber-400/40 bg-amber-500/10 text-amber-100 hover:bg-amber-500/25 text-[11px]"
                            >
                                <Hexagon className="h-3 w-3" /> Trace
                            </button>
                        </div>

                        <span className="text-[11px] uppercase tracking-wider text-white/55 font-medium mt-2">Listing</span>
                        <ListingBlock draft={draft} update={update} />
                    </>
                )}
            </div>

            {/* Column 3 — listing (mlo mode) OR nothing extra (teleport — listing fills col 2) */}
            <div className="flex flex-col gap-1.5 min-h-0">
                {type === "mlo" ? (
                    <>
                        <div className="flex items-center justify-between">
                            <span className="text-[11px] uppercase tracking-wider text-white/55 font-medium">Zones</span>
                            <button onClick={addMloZone}
                                className="inline-flex items-center gap-1 px-2 py-1 rounded ring-1 ring-emerald-400/40 bg-emerald-500/10 text-emerald-100 hover:bg-emerald-500/25 text-[11px]">
                                <Plus className="h-3 w-3" /> Add
                            </button>
                        </div>
                        <div className="flex-1 overflow-y-auto pr-1 -mr-1 flex flex-col gap-1.5">
                            {mlo.zones.length === 0 && (
                                <div className="text-[11px] italic text-white/40">No zones yet.</div>
                            )}
                            {mlo.zones.map((z, i) => (
                                <div key={i} className="rounded-md bg-white/[0.03] ring-1 ring-white/10 p-2 space-y-1.5">
                                    <div className="grid grid-cols-[1fr_auto] gap-1.5">
                                        <input value={z.label} onChange={(e) => {
                                            const v = e.target.value;
                                            setMlo((d) => {
                                                const zones = [...d.zones]; zones[i] = { ...zones[i], label: v };
                                                return { ...d, zones };
                                            });
                                        }} placeholder="label"
                                            className="bg-white/[0.06] ring-1 ring-white/20 rounded-md px-2 py-1 text-[11px] text-white" />
                                        <button onClick={() => removeMloZone(i)}
                                            className="h-7 w-7 inline-flex items-center justify-center rounded-md ring-1 ring-white/20 text-white/70 hover:text-red-200 hover:bg-red-500/15">
                                            <Trash2 className="h-3 w-3" />
                                        </button>
                                    </div>
                                    <div className="flex items-center justify-between gap-2 rounded bg-white/[0.04] ring-1 ring-white/10 px-2 py-1">
                                        <span className="text-[10px] tabular-nums text-white/60 truncate">
                                            {z.origin.x !== 0 || z.origin.y !== 0
                                                ? `${z.origin.x.toFixed(1)}, ${z.origin.y.toFixed(1)} · ${z.xCells}×${z.yCells}`
                                                : "(not placed)"}
                                        </span>
                                        <button onClick={() => fetchNui("housingPickZoneArea", { zoneIndex: i })}
                                            className="inline-flex items-center gap-1 px-2 py-0.5 rounded ring-1 ring-amber-400/40 bg-amber-500/10 text-amber-100 hover:bg-amber-500/25 text-[10px]">
                                            <MapPin className="h-3 w-3" /> Place
                                        </button>
                                    </div>
                                </div>
                            ))}
                        </div>
                    </>
                ) : null}
            </div>
        </div>
    );
}

// ─── List rows ──────────────────────────────────────────────────────────

function HouseRow({ h, onEdit, onDelete }: { h: House; onEdit: () => void; onDelete: () => void }) {
    const [confirm, setConfirm] = useState(false);
    const isMlo = h.interior_id?.startsWith("_mlo_");
    return (
        <div className="grid grid-cols-[1fr_auto_auto] items-center gap-2 rounded-md bg-white/[0.04] ring-1 ring-white/10 px-2.5 py-1.5">
            <div className="min-w-0">
                <div className="text-xs text-white truncate font-medium">
                    {h.label} <span className="text-[10px] text-white/45">({h.id})</span>
                </div>
                <div className="text-[10px] text-white/55 tabular-nums truncate">
                    {isMlo ? "MLO" : `interior:${h.interior_id}`} · {h.tenure}
                    {h.sale_enabled && ` · sale $${h.sale_price}`}
                    {h.rent_enabled && ` · rent $${h.rent_price}/cyc`}
                </div>
            </div>
            <button onClick={onEdit}
                className="h-7 w-7 inline-flex items-center justify-center rounded-md ring-1 ring-white/20 text-white/70 hover:text-amber-200 hover:bg-amber-500/15">
                <Pencil className="h-3.5 w-3.5" />
            </button>
            {confirm ? (
                <button onClick={() => { onDelete(); setConfirm(false); }}
                    className="h-7 px-2.5 rounded-md ring-1 bg-red-500/25 ring-red-400/60 text-red-100 hover:bg-red-500/40 text-[10px]">
                    Confirm
                </button>
            ) : (
                <button onClick={() => setConfirm(true)}
                    className="h-7 w-7 inline-flex items-center justify-center rounded-md ring-1 ring-white/20 text-white/70 hover:text-red-200 hover:bg-red-500/15">
                    <Trash2 className="h-3.5 w-3.5" />
                </button>
            )}
        </div>
    );
}

function InteriorRow({ i, onEdit, onDelete }: { i: Interior; onEdit: () => void; onDelete: () => void }) {
    const [confirm, setConfirm] = useState(false);
    return (
        <div className="grid grid-cols-[1fr_auto_auto] items-center gap-2 rounded-md bg-white/[0.04] ring-1 ring-white/10 px-2.5 py-1.5">
            <div className="min-w-0">
                <div className="text-xs text-white truncate font-medium">
                    {i.label} <span className="text-[10px] text-white/45">({i.id})</span>
                </div>
                <div className="text-[10px] text-white/55 truncate">
                    {i.zones.length} zone{i.zones.length === 1 ? "" : "s"}
                </div>
            </div>
            <button onClick={onEdit}
                className="h-7 w-7 inline-flex items-center justify-center rounded-md ring-1 ring-white/20 text-white/70 hover:text-amber-200 hover:bg-amber-500/15">
                <Pencil className="h-3.5 w-3.5" />
            </button>
            {confirm ? (
                <button onClick={() => { onDelete(); setConfirm(false); }}
                    className="h-7 px-2.5 rounded-md ring-1 bg-red-500/25 ring-red-400/60 text-red-100 hover:bg-red-500/40 text-[10px]">
                    Confirm
                </button>
            ) : (
                <button onClick={() => setConfirm(true)}
                    className="h-7 w-7 inline-flex items-center justify-center rounded-md ring-1 ring-white/20 text-white/70 hover:text-red-200 hover:bg-red-500/15">
                    <Trash2 className="h-3.5 w-3.5" />
                </button>
            )}
        </div>
    );
}

// ─── Main panel ─────────────────────────────────────────────────────────

export function HousingPanel({
    initial, panel, hidden, onClose,
}: {
    initial: { interiors: Interior[]; houses: House[] };
    panel: "houses" | "interiors";
    hidden: boolean;
    onClose: () => void;
}) {
    const { interiors, houses } = useHousingData(initial);
    const [tab, setTab] = useState<"houses" | "interiors">(panel);
    const [editingInterior, setEditingInterior] = useState<Interior | null>(null);
    const [editingHouse, setEditingHouse] = useState<House | null>(null);
    const [walking, setWalking] = useState(false);
    const [walkKey, setWalkKey] = useState<string>("F2");

    useEffect(() => setTab(panel), [panel]);

    useNuiEvent<{ walking: boolean; key?: string }>("housingWalkState", (d) => {
        setWalking(!!d?.walking);
        if (d?.key) setWalkKey(d.key);
    });

    const sortedHouses = useMemo(
        () => [...houses].filter((h) => h.id !== "_legacy").sort((a, b) => a.id.localeCompare(b.id)),
        [houses]
    );
    // Visible Interior templates are teleport-kind only; MLO interiors are
    // shadow rows owned by a specific Property and never shown in this list.
    const sortedInteriors = useMemo(
        () => [...interiors]
            .filter((i) => i.id !== "_legacy" && !i.id.startsWith("_mlo_") && i.kind === "teleport")
            .sort((a, b) => a.id.localeCompare(b.id)),
        [interiors]
    );

    // For an MLO property, pull the linked shadow interior so its data
    // populates the inline editor.
    const mloFor = (h: House): MloDraft | null => {
        if (!h.interior_id) return null;
        const i = interiors.find((x) => x.id === h.interior_id);
        if (!i || i.kind !== "mlo") return null;
        return {
            label: i.label,
            idle_x: i.idle_x, idle_y: i.idle_y, idle_z: i.idle_z, idle_w: i.idle_w,
            mgmt_x: i.mgmt_x, mgmt_y: i.mgmt_y, mgmt_z: i.mgmt_z, mgmt_w: i.mgmt_w,
            zones: i.zones,
            mlo_polygon: i.mlo_polygon ?? null,
        };
    };
    const editingHouseMlo = editingHouse ? mloFor(editingHouse) : null;

    const editing = !!editingInterior || !!editingHouse;
    const titleSuffix = editingInterior
        ? (editingInterior.id ? `Edit Interior · ${editingInterior.label}` : "New Interior")
        : editingHouse
            ? (editingHouse.id ? `Edit Property · ${editingHouse.label}` : "New Property")
            : null;

    return (
        <div
            className="fixed left-1/2 -translate-x-1/2 bottom-4 pointer-events-none"
            style={{ visibility: hidden ? "hidden" : "visible" }}
        >
            <div
                className={
                    "pointer-events-auto rounded-2xl bg-black/95 ring-1 ring-white/10 shadow-2xl overflow-hidden " +
                    "w-[1100px] max-w-[96vw] h-[380px] flex flex-col " +
                    (walking ? "opacity-70" : "")
                }
                style={walking ? { pointerEvents: "none" } : undefined}
            >
                {/* Header — label · tabs (or breadcrumb when editing) · walk · close */}
                <div className="grid grid-cols-[auto_1fr_auto_auto] items-center gap-3 px-4 h-9 border-b border-white/5 bg-white/[0.02] shrink-0">
                    <span className="text-[10px] uppercase tracking-[0.18em] text-white/45 whitespace-nowrap">
                        Drugs Admin
                        {titleSuffix && (
                            <span className="ml-2 text-white/55 normal-case tracking-normal">· {titleSuffix}</span>
                        )}
                    </span>
                    <div className="flex justify-center">
                        {!editing && <DrugsTabBar active={tab} />}
                    </div>
                    <button
                        onClick={() => fetchNui("housingToggleWalk", {})}
                        title={walking ? `Resume editing (${walkKey})` : `Walk mode (${walkKey})`}
                        className={"h-7 px-2 inline-flex items-center gap-1.5 rounded ring-1 transition-colors text-[11px] " +
                            (walking
                                ? "bg-amber-500/25 ring-amber-400/60 text-amber-50"
                                : "ring-white/20 text-white/75 hover:bg-white/[0.06]")}
                    >
                        <Footprints className="h-3.5 w-3.5" />
                        {walking ? "Walking" : "Walk"}
                    </button>
                    <button onClick={onClose}
                        className="h-7 w-7 inline-flex items-center justify-center rounded ring-1 ring-white/25 text-white/70 hover:text-red-200 hover:bg-red-500/15">
                        <X className="h-4 w-4" />
                    </button>
                </div>

                {/* Body */}
                <div className="flex-1 min-h-0 p-3">
                    {editingInterior ? (
                        <InteriorEditor
                            initial={editingInterior}
                            onClose={() => setEditingInterior(null)}
                            onSaved={() => setEditingInterior(null)}
                        />
                    ) : editingHouse ? (
                        <HouseEditor
                            initial={editingHouse}
                            initialMlo={editingHouseMlo}
                            interiors={interiors}
                            onClose={() => setEditingHouse(null)}
                            onSaved={() => setEditingHouse(null)}
                        />
                    ) : tab === "houses" ? (
                        <div className="h-full flex flex-col gap-2 min-h-0">
                            <div className="flex items-center justify-between shrink-0">
                                <span className="text-xs text-white/85 font-medium">
                                    Properties <span className="text-white/45">· {sortedHouses.length}</span>
                                </span>
                                <button
                                    onClick={() => setEditingHouse(DEFAULT_HOUSE(""))}
                                    className="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-md ring-1 ring-emerald-400/50 bg-emerald-500/15 text-emerald-100 hover:bg-emerald-500/30 text-xs">
                                    <Plus className="h-3.5 w-3.5" /> New Property
                                </button>
                            </div>
                            <div className="flex-1 overflow-y-auto pr-1 -mr-1 grid grid-cols-2 gap-1.5 auto-rows-min">
                                {sortedHouses.length === 0 ? (
                                    <div className="text-[11px] italic text-white/40 col-span-2">No properties yet.</div>
                                ) : (
                                    sortedHouses.map((h) => (
                                        <HouseRow key={h.id} h={h}
                                            onEdit={() => setEditingHouse(h)}
                                            onDelete={() => fetchNui("housingDeleteHouse", { id: h.id })} />
                                    ))
                                )}
                            </div>
                        </div>
                    ) : (
                        <div className="h-full flex flex-col gap-2 min-h-0">
                            <div className="flex items-center justify-between shrink-0">
                                <span className="text-xs text-white/85 font-medium">
                                    Interior templates <span className="text-white/45">· {sortedInteriors.length}</span>
                                </span>
                                <button
                                    onClick={() => setEditingInterior(DEFAULT_INTERIOR())}
                                    className="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-md ring-1 ring-emerald-400/50 bg-emerald-500/15 text-emerald-100 hover:bg-emerald-500/30 text-xs">
                                    <Plus className="h-3.5 w-3.5" /> New Interior
                                </button>
                            </div>
                            <div className="flex-1 overflow-y-auto pr-1 -mr-1 grid grid-cols-2 gap-1.5 auto-rows-min">
                                {sortedInteriors.length === 0 ? (
                                    <div className="text-[11px] italic text-white/40 col-span-2">No templates yet.</div>
                                ) : (
                                    sortedInteriors.map((i) => (
                                        <InteriorRow key={i.id} i={i}
                                            onEdit={() => setEditingInterior(i)}
                                            onDelete={() => fetchNui("housingDeleteInterior", { id: i.id })} />
                                    ))
                                )}
                            </div>
                        </div>
                    )}
                </div>
            </div>

            {/* Walk-mode banner — pointer-events on so admin can also click it
                back to editing. Anchored just above the panel. */}
            {walking && (
                <div className="absolute left-1/2 -translate-x-1/2 -top-9 pointer-events-auto">
                    <button
                        onClick={() => fetchNui("housingToggleWalk", {})}
                        className="inline-flex items-center gap-2 px-3 py-1.5 rounded-full ring-1 ring-amber-400/50 bg-amber-500/20 text-amber-50 text-xs hover:bg-amber-500/35"
                    >
                        <Footprints className="h-3.5 w-3.5" />
                        Walking — press <kbd className="px-1 rounded bg-white/10 ring-1 ring-white/15 font-mono text-[10px]">{walkKey}</kbd> or click to resume
                    </button>
                </div>
            )}
        </div>
    );
}
