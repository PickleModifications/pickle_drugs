import { useEffect, useMemo, useRef, useState } from "react";
import { Plus, Trash2, Save, Pencil, MapPin, Edit3 } from "lucide-react";

import { fetchNui, useNuiEvent } from "@/lib/nui";
import { WorldMap } from "./WorldMap";

// Mirrors the shapes the Lua side stores. `id` is server-issued; the
// admin authors everything else. Zones are polygon-only in the editor
// — the `kind` field is preserved so legacy `circle` rows still load
// + render, but new edits always save as `polygon`. `color` is a
// #RRGGBB hex used for the leaflet outline + the in-world preview.
export type DealingZone = {
    id: string;
    label: string;
    kind: "circle" | "polygon";
    color: string;
    center_x: number;
    center_y: number;
    center_z: number;
    radius: number;
    points: { x: number; y: number }[];
    risk_mult: number;
    deal_points: { x: number; y: number; z: number; w?: number }[];
};

export type DealingCustomer = {
    id: string;
    first_name: string;
    last_name: string;
    model: string;
    zones: string[]; // zone ids
    idle_scenario: string;
};

const DEFAULT_ZONE_COLOR = "#38bdf8";

const NEW_ZONE = (): DealingZone => ({
    id: "",
    label: "New Zone",
    kind: "polygon",
    color: DEFAULT_ZONE_COLOR,
    center_x: 0, center_y: 0, center_z: 30,
    radius: 0,
    points: [],
    risk_mult: 1.0,
    deal_points: [],
});

const NEW_CUSTOMER = (): DealingCustomer => ({
    id: "",
    first_name: "Customer",
    last_name: "",
    model: "a_m_m_business_01",
    zones: [],
    idle_scenario: "WORLD_HUMAN_SMOKING",
});

const SCENARIOS = [
    "WORLD_HUMAN_SMOKING",
    "WORLD_HUMAN_SMOKING_POT",
    "WORLD_HUMAN_DRINKING",
    "WORLD_HUMAN_LEANING",
    "WORLD_HUMAN_STAND_IMPATIENT",
    "WORLD_HUMAN_HANG_OUT_STREET",
    "WORLD_HUMAN_AA_COFFEE",
];

const MODELS = [
    "a_m_m_business_01",
    "a_m_m_hasjew_01",
    "a_m_y_business_01",
    "a_m_y_hipster_01",
    "a_m_y_skater_01",
    "a_f_y_hipster_01",
    "a_f_y_business_02",
    "g_m_y_lost_01",
    "g_m_y_strpunk_01",
    "g_m_y_ballaeast_01",
];

type SaveStatus = "idle" | "pending" | "saved";

export function DealingPanel() {
    const [zones, setZones] = useState<DealingZone[]>([]);
    const [customers, setCustomers] = useState<DealingCustomer[]>([]);
    const [selectedZoneId, setSelectedZoneId] = useState<string | null>(null);
    const [draftZone, setDraftZone] = useState<DealingZone | null>(null);
    const [editingCustomerId, setEditingCustomerId] = useState<string | null>(null);
    const [draftCustomer, setDraftCustomer] = useState<DealingCustomer | null>(null);
    // Map click-mode: "edit" routes clicks into polygon vertex
    // authoring; "deal" routes them into deal-point placement
    // (rejected unless inside the polygon).
    const [mapMode, setMapMode] = useState<"edit" | "deal">("edit");
    // Reset map mode whenever the active zone changes — switching
    // between zones shouldn't carry deal-point intent across them.
    useEffect(() => setMapMode("edit"), [selectedZoneId, draftZone?.id]);

    // Debounced auto-save state for the active zone draft. Mirrors
    // the housing editor pattern: skip the very first commit (which
    // is the load), require a server-assigned id (manual "Create" for
    // new zones), and surface a small SaveStatusPill so the admin
    // sees their changes flushing.
    const [zoneSaveStatus, setZoneSaveStatus] = useState<SaveStatus>("idle");
    const zoneSaveTimer  = useRef<number | null>(null);
    const zoneSavedFlash = useRef<number | null>(null);
    const zoneFirstSync  = useRef(true);
    // Reset the "skip the loading commit" guard whenever the
    // selected zone changes — otherwise switching zones would burn
    // the first edit on the new zone as a no-op.
    useEffect(() => { zoneFirstSync.current = true; }, [selectedZoneId]);

    // Initial fetch + push the in-world preview on while the panel is open.
    useEffect(() => {
        let cancelled = false;
        (async () => {
            const data = (await fetchNui("dealingList", {})) as
                | { zones: DealingZone[]; customers: DealingCustomer[] }
                | undefined;
            if (cancelled || !data) return;
            setZones(data.zones || []);
            setCustomers(data.customers || []);
        })();
        fetchNui("dealingPreview", { on: true });
        return () => {
            cancelled = true;
            fetchNui("dealingPreview", { on: false });
        };
    }, []);

    // Live updates from server broadcasts (relayed by client.lua).
    useNuiEvent<DealingZone>("dealingZoneUpdate", (z) => {
        if (!z) return;
        setZones((prev) => {
            const i = prev.findIndex((x) => x.id === z.id);
            if (i < 0) return [...prev, z];
            const next = prev.slice();
            next[i] = z;
            return next;
        });
        // If the in-world picker just landed a center on the active draft,
        // sync it through.
        setDraftZone((d) => (d && d.id === z.id ? z : d));
    });
    useNuiEvent<string>("dealingZoneRemoved", (id) => {
        setZones((prev) => prev.filter((x) => x.id !== id));
        setDraftZone((d) => (d && d.id === id ? null : d));
        setSelectedZoneId((s) => (s === id ? null : s));
    });
    useNuiEvent<DealingCustomer>("dealingCustomerUpdate", (c) => {
        if (!c) return;
        setCustomers((prev) => {
            const i = prev.findIndex((x) => x.id === c.id);
            if (i < 0) return [...prev, c];
            const next = prev.slice();
            next[i] = c;
            return next;
        });
    });
    useNuiEvent<string>("dealingCustomerRemoved", (id) => {
        setCustomers((prev) => prev.filter((x) => x.id !== id));
        setEditingCustomerId((s) => (s === id ? null : s));
    });

    // Per-source ack from the server after a save. For brand-new
    // zones (tempId == "") it carries the assigned id so the editor
    // can adopt it and start auto-saving subsequent edits.
    useNuiEvent<{ tempId: string; savedId: string }>("dealingZoneSaved", (d) => {
        if (!d || !d.savedId) return;
        if (d.tempId === "") {
            setDraftZone((cur) =>
                cur && !cur.id ? { ...cur, id: d.savedId } : cur,
            );
            setSelectedZoneId((s) => s ?? d.savedId);
        }
        setZoneSaveStatus("saved");
        if (zoneSavedFlash.current) window.clearTimeout(zoneSavedFlash.current);
        zoneSavedFlash.current = window.setTimeout(
            () => setZoneSaveStatus("idle"),
            1500,
        );
    });

    // Picker callback — Lua finishes a center / deal-point pick, fires this.
    useNuiEvent<{
        zoneId: string;
        kind?: "center" | undefined;
        cancelled: boolean;
        point?: { x: number; y: number; z: number; w?: number };
    }>("dealingPickerDone", (r) => {
        if (!r || r.cancelled || !r.point) return;
        setDraftZone((d) => {
            if (!d || d.id !== r.zoneId) return d;
            if (r.kind === "center") {
                return { ...d, center_x: r.point!.x, center_y: r.point!.y, center_z: r.point!.z };
            }
            return { ...d, deal_points: [...d.deal_points, r.point!] };
        });
    });

    useEffect(() => {
        // Update the in-world highlight when the admin picks a different zone.
        fetchNui("dealingPreview", { on: true, zoneId: selectedZoneId ?? undefined });
    }, [selectedZoneId]);

    // ── Debounced auto-save for the active zone draft ───────────────
    // Mirrors the housing editor: 600ms debounce, skips the load
    // commit, requires a server-assigned id (brand-new zones go
    // through the manual "Create" button so their first save assigns
    // an id we can then auto-save against).
    useEffect(() => {
        if (!draftZone) return;
        if (zoneFirstSync.current) {
            zoneFirstSync.current = false;
            return;
        }
        if (!draftZone.id) {
            // Pre-create state — auto-save would race new ids.
            setZoneSaveStatus("idle");
            return;
        }
        setZoneSaveStatus("pending");
        if (zoneSaveTimer.current) window.clearTimeout(zoneSaveTimer.current);
        zoneSaveTimer.current = window.setTimeout(() => {
            fetchNui("dealingSaveZone", draftZone);
        }, 600);
        return () => {
            if (zoneSaveTimer.current) window.clearTimeout(zoneSaveTimer.current);
        };
    }, [draftZone]);

    const selectedZone = useMemo(
        () => draftZone ?? zones.find((z) => z.id === selectedZoneId) ?? null,
        [draftZone, zones, selectedZoneId],
    );
    const customersInSelected = useMemo(() => {
        if (!selectedZone) return customers;
        return customers.filter((c) => c.zones.includes(selectedZone.id));
    }, [customers, selectedZone]);

    const startEditingZone = (z: DealingZone) => {
        setSelectedZoneId(z.id || null);
        setDraftZone({ ...z });
    };
    const startNewZone = () => {
        const z = NEW_ZONE();
        setDraftZone(z);
        setSelectedZoneId(null);
    };
    const cancelDraftZone = () => setDraftZone(null);
    const saveDraftZone = () => {
        if (!draftZone) return;
        fetchNui("dealingSaveZone", draftZone);
        setDraftZone(null);
    };
    const deleteSelectedZone = () => {
        if (!selectedZone || !selectedZone.id) return;
        fetchNui("dealingDeleteZone", { id: selectedZone.id });
    };

    const startEditingCustomer = (c: DealingCustomer) => {
        setEditingCustomerId(c.id);
        setDraftCustomer({ ...c });
    };
    const startNewCustomer = () => {
        setEditingCustomerId("__new__");
        setDraftCustomer(NEW_CUSTOMER());
    };
    const saveDraftCustomer = () => {
        if (!draftCustomer) return;
        fetchNui("dealingSaveCustomer", draftCustomer);
        setEditingCustomerId(null);
        setDraftCustomer(null);
    };
    const deleteCustomer = (id: string) => fetchNui("dealingDeleteCustomer", { id });

    return (
        <div className="h-full grid grid-cols-[220px_340px_1fr] gap-3 min-h-0 text-white">
            {/* ── Column 1: Zone list ──────────────────────────────────── */}
            <div className="min-h-0 flex flex-col gap-2">
                <div className="flex items-center justify-between shrink-0">
                    <span className="text-xs text-white/85 font-medium">
                        Zones <span className="text-white/45">· {zones.length}</span>
                    </span>
                    <button
                        onClick={startNewZone}
                        className="inline-flex items-center gap-1.5 px-2 py-1 rounded ring-1 ring-emerald-400/50 bg-emerald-500/15 text-emerald-100 hover:bg-emerald-500/30 text-[11px]"
                    >
                        <Plus className="h-3 w-3" /> New
                    </button>
                </div>
                <div className="flex-1 overflow-y-auto pr-1 -mr-1 flex flex-col gap-1">
                    {zones.length === 0 && (
                        <div className="text-[11px] italic text-white/40">No zones yet.</div>
                    )}
                    {zones.map((z) => {
                        const active = selectedZoneId === z.id;
                        const cuCount = customers.filter((c) => c.zones.includes(z.id)).length;
                        return (
                            <button
                                key={z.id}
                                onClick={() => startEditingZone(z)}
                                className={
                                    "text-left rounded px-2 py-1.5 ring-1 transition-colors " +
                                    (active
                                        ? "ring-sky-400/60 bg-sky-500/10"
                                        : "ring-white/10 hover:bg-white/[0.04]")
                                }
                            >
                                <div className="text-xs truncate">{z.label}</div>
                                <div className="text-[10px] text-white/45 tabular-nums">
                                    {(z.points?.length ?? 0)} verts · {z.deal_points.length} pts · {cuCount} cust
                                </div>
                            </button>
                        );
                    })}
                </div>
            </div>

            {/* ── Column 2: Map (always visible) + zone editor ────────── */}
            <div className="min-h-0 flex flex-col gap-2">
                <WorldMap
                    zones={zones.map((z) => ({
                        id:         z.id,
                        label:      z.label,
                        kind:       z.kind ?? "polygon",
                        color:      z.color || DEFAULT_ZONE_COLOR,
                        centerX:    z.center_x,
                        centerY:    z.center_y,
                        centerZ:    z.center_z,
                        radius:     z.radius,
                        points:     z.points ?? [],
                        dealPoints: z.deal_points,
                    }))}
                    selectedZoneId={selectedZone?.id ?? null}
                    draftShape={
                        selectedZone
                            ? {
                                  centerX: selectedZone.center_x,
                                  centerY: selectedZone.center_y,
                                  points:  selectedZone.points ?? [],
                              }
                            : null
                    }
                    draftDealPoints={selectedZone?.deal_points ?? []}
                    mode={mapMode}
                    onSelectZone={(id) => {
                        const z = zones.find((x) => x.id === id);
                        if (z) startEditingZone(z);
                    }}
                    onShapeChange={(patch) => {
                        if (!selectedZone) return;
                        setDraftZone((d) => {
                            const base = d ?? selectedZone;
                            return {
                                ...base,
                                // Always-polygon now; preserve the kind
                                // tag so the schema column reflects the
                                // editor's intent.
                                kind: "polygon",
                                ...(patch.centerX !== undefined ? { center_x: patch.centerX } : {}),
                                ...(patch.centerY !== undefined ? { center_y: patch.centerY } : {}),
                                ...(patch.points  !== undefined ? { points:   patch.points  } : {}),
                            };
                        });
                    }}
                    onAddDealPointBlocked={() =>
                        // Map already shows where it landed via the
                        // cursor readout. A toast on every miss feels
                        // noisy; instead light up a brief amber tint
                        // on the panel by toggling status.
                        setZoneSaveStatus("idle")
                    }
                    onAddDealPoint={(x, y) => {
                        if (!selectedZone) return;
                        setDraftZone((d) => {
                            const base = d ?? selectedZone;
                            // Z falls back to center_z so deal points
                            // sit on the same plane as the zone for
                            // the in-world preview. Admin can adjust
                            // numerically in the editor's deal-point
                            // list if they need a precise floor.
                            return {
                                ...base,
                                deal_points: [
                                    ...base.deal_points,
                                    { x, y, z: base.center_z, w: 0 },
                                ],
                            };
                        });
                    }}
                />
                {selectedZone ? (
                    <ZoneEditor
                        zone={selectedZone}
                        mapMode={mapMode}
                        onMapMode={setMapMode}
                        saveStatus={zoneSaveStatus}
                        onChange={(patch) =>
                            setDraftZone((d) => ({ ...(d ?? selectedZone), ...patch }))
                        }
                        onRemoveDealPoint={(idx) =>
                            setDraftZone((d) => {
                                const base = d ?? selectedZone;
                                const pts = base.deal_points.slice();
                                pts.splice(idx, 1);
                                return { ...base, deal_points: pts };
                            })
                        }
                        onCreate={saveDraftZone}
                        onClose={cancelDraftZone}
                        onDelete={selectedZone.id ? deleteSelectedZone : undefined}
                    />
                ) : (
                    <div className="text-[11px] italic text-white/40 px-1">
                        Click a zone on the map to edit, or create a new one.
                    </div>
                )}
            </div>

            {/* ── Column 3: Customer list ─────────────────────────────── */}
            <div className="min-h-0 flex flex-col gap-2">
                <div className="flex items-center justify-between shrink-0">
                    <span className="text-xs text-white/85 font-medium">
                        Customers <span className="text-white/45">· {customersInSelected.length}{customersInSelected.length !== customers.length ? ` of ${customers.length}` : ""}</span>
                    </span>
                    <button
                        onClick={startNewCustomer}
                        className="inline-flex items-center gap-1.5 px-2 py-1 rounded ring-1 ring-emerald-400/50 bg-emerald-500/15 text-emerald-100 hover:bg-emerald-500/30 text-[11px]"
                    >
                        <Plus className="h-3 w-3" /> New
                    </button>
                </div>
                <div className="flex-1 overflow-y-auto pr-1 -mr-1 flex flex-col gap-1">
                    {editingCustomerId === "__new__" && draftCustomer && (
                        <CustomerEditor
                            zones={zones}
                            customer={draftCustomer}
                            onChange={(patch) => setDraftCustomer((d) => ({ ...(d as DealingCustomer), ...patch }))}
                            onSave={saveDraftCustomer}
                            onCancel={() => { setDraftCustomer(null); setEditingCustomerId(null); }}
                        />
                    )}
                    {customersInSelected.map((c) => {
                        const editing = editingCustomerId === c.id && draftCustomer;
                        if (editing) {
                            return (
                                <CustomerEditor
                                    key={c.id}
                                    zones={zones}
                                    customer={draftCustomer!}
                                    onChange={(patch) => setDraftCustomer((d) => ({ ...(d as DealingCustomer), ...patch }))}
                                    onSave={saveDraftCustomer}
                                    onCancel={() => { setDraftCustomer(null); setEditingCustomerId(null); }}
                                    onDelete={() => deleteCustomer(c.id)}
                                />
                            );
                        }
                        return (
                            <button
                                key={c.id}
                                onClick={() => startEditingCustomer(c)}
                                className="text-left rounded px-2 py-1.5 ring-1 ring-white/10 hover:bg-white/[0.04] flex items-center gap-2"
                            >
                                <div className="flex-1 min-w-0">
                                    <div className="text-xs truncate">{c.first_name} {c.last_name}</div>
                                    <div className="text-[10px] text-white/45 truncate">
                                        {c.model} · {c.zones.length} zone{c.zones.length === 1 ? "" : "s"}
                                    </div>
                                </div>
                                <Pencil className="h-3 w-3 text-white/40" />
                            </button>
                        );
                    })}
                    {customersInSelected.length === 0 && editingCustomerId !== "__new__" && (
                        <div className="text-[11px] italic text-white/40">
                            {selectedZone ? "No customers assigned to this zone." : "No customers yet."}
                        </div>
                    )}
                </div>
            </div>
        </div>
    );
}

function ZoneEditor({
    zone, mapMode, onMapMode, saveStatus, onChange, onRemoveDealPoint,
    onCreate, onClose, onDelete,
}: {
    zone: DealingZone;
    mapMode: "edit" | "deal";
    onMapMode: (m: "edit" | "deal") => void;
    saveStatus: SaveStatus;
    onChange: (patch: Partial<DealingZone>) => void;
    onRemoveDealPoint: (idx: number) => void;
    // First-save for brand-new zones (server-assigned id is needed
    // before auto-save kicks in). Hidden once the zone has an id.
    onCreate: () => void;
    onClose: () => void;
    onDelete?: () => void;
}) {
    const persisted = !!zone.id;
    return (
        <div className="rounded ring-1 ring-white/10 bg-white/[0.02] p-2 flex flex-col gap-1.5 text-[11px]">
            <div className="flex gap-1.5 items-stretch">
                {/* Color picker — native CEF input. The square swatch
                    doubles as the visual identity on the map + in-world
                    preview, so it sits at the head of the row for
                    quick-glance association with the label. */}
                <input
                    type="color"
                    value={zone.color || "#38bdf8"}
                    onChange={(e) => onChange({ color: e.target.value })}
                    className="w-8 h-auto bg-black/40 ring-1 ring-white/10 rounded cursor-pointer p-0.5"
                    title="Zone color"
                />
                <input
                    value={zone.label}
                    onChange={(e) => onChange({ label: e.target.value })}
                    className="flex-1 bg-black/40 ring-1 ring-white/10 rounded px-1.5 py-1 text-xs"
                    placeholder="Zone label"
                />
            </div>
            {/* Z is the only manual coord — it's the ground height the
                in-world preview draws the polygon at. X/Y of the
                polygon vertices come from clicking the map. */}
            <Coord label="Z" value={zone.center_z} onChange={(v) => onChange({ center_z: v })} />

            {/* Map-mode toggle row — switches between editing the
                polygon vertices and dropping deal points inside the
                polygon. The toggle is what gates the WorldMap into
                each authoring task. */}
            <div className="flex gap-1">
                {([
                    { id: "edit", label: "Edit polygon", Icon: Edit3 },
                    { id: "deal", label: "Add deal point", Icon: MapPin },
                ] as const).map(({ id, label, Icon }) => {
                    const active = mapMode === id;
                    return (
                        <button
                            key={id}
                            onClick={() => onMapMode(id)}
                            className={
                                "flex-1 inline-flex items-center justify-center gap-1.5 px-2 py-1 rounded ring-1 transition-colors text-[11px] " +
                                (active
                                    ? id === "deal"
                                        ? "bg-amber-500/25 ring-amber-400/50 text-amber-50"
                                        : "bg-sky-500/25 ring-sky-400/50 text-sky-50"
                                    : "ring-white/15 text-white/65 hover:bg-white/[0.06]")
                            }
                        >
                            <Icon className="h-3 w-3" /> {label}
                        </button>
                    );
                })}
            </div>

            {zone.deal_points.length > 0 && (
                <div className="max-h-16 overflow-y-auto flex flex-col gap-0.5">
                    {zone.deal_points.map((p, i) => (
                        <div key={i} className="flex items-center gap-1.5 text-[10px] text-white/55">
                            <span className="font-mono w-4">{i + 1}</span>
                            <span className="flex-1 truncate tabular-nums">
                                {p.x.toFixed(1)}, {p.y.toFixed(1)}, {p.z.toFixed(1)}
                            </span>
                            <button
                                onClick={() => onRemoveDealPoint(i)}
                                className="hover:text-red-300"
                            >
                                <Trash2 className="h-3 w-3" />
                            </button>
                        </div>
                    ))}
                </div>
            )}

            <div className="flex items-center justify-between gap-1.5 pt-1 border-t border-white/5">
                {onDelete ? (
                    <button
                        onClick={onDelete}
                        className="inline-flex items-center gap-1 px-2 py-1 rounded ring-1 ring-red-400/40 text-red-200 hover:bg-red-500/15 text-[11px]"
                    >
                        <Trash2 className="h-3 w-3" /> Delete
                    </button>
                ) : <span />}
                <div className="flex items-center gap-1.5">
                    {persisted ? (
                        <ZoneSaveStatusPill status={saveStatus} />
                    ) : (
                        <button
                            onClick={onCreate}
                            className="inline-flex items-center gap-1 px-2 py-1 rounded ring-1 ring-emerald-400/50 bg-emerald-500/15 text-emerald-100 hover:bg-emerald-500/30 text-[11px]"
                        >
                            <Save className="h-3 w-3" /> Create
                        </button>
                    )}
                    <button
                        onClick={onClose}
                        className="px-2 py-1 rounded ring-1 ring-white/15 text-white/60 hover:bg-white/[0.06] text-[11px]"
                    >
                        Close
                    </button>
                </div>
            </div>
        </div>
    );
}

// Compact save status pill — mirrors the housing editor's affordance.
function ZoneSaveStatusPill({ status }: { status: SaveStatus }) {
    if (status === "pending") {
        return (
            <span className="px-2 py-1 inline-flex items-center gap-1.5 rounded ring-1 ring-amber-400/40 bg-amber-500/10 text-amber-100/80 text-[11px]">
                <span className="h-1.5 w-1.5 rounded-full bg-amber-300/80 animate-pulse" />
                Saving…
            </span>
        );
    }
    if (status === "saved") {
        return (
            <span className="px-2 py-1 inline-flex items-center gap-1.5 rounded ring-1 ring-emerald-400/40 bg-emerald-500/10 text-emerald-100/85 text-[11px]">
                <span className="h-1.5 w-1.5 rounded-full bg-emerald-300/80" />
                Saved
            </span>
        );
    }
    return (
        <span className="px-2 py-1 inline-flex items-center gap-1.5 rounded ring-1 ring-white/15 text-white/45 text-[11px]">
            Auto-save on
        </span>
    );
}

function Coord({ label, value, onChange }: { label: string; value: number; onChange: (v: number) => void }) {
    return (
        <label className="flex items-center gap-1 bg-black/40 ring-1 ring-white/10 rounded px-1.5 py-1">
            <span className="text-white/45 text-[10px] w-3">{label}</span>
            <input
                type="number"
                value={Number.isFinite(value) ? Number(value.toFixed(1)) : 0}
                onChange={(e) => onChange(parseFloat(e.target.value) || 0)}
                className="bg-transparent w-full outline-none text-xs"
            />
        </label>
    );
}

function CustomerEditor({
    customer, zones, onChange, onSave, onCancel, onDelete,
}: {
    customer: DealingCustomer;
    zones: DealingZone[];
    onChange: (patch: Partial<DealingCustomer>) => void;
    onSave: () => void;
    onCancel: () => void;
    onDelete?: () => void;
}) {
    return (
        <div className="rounded ring-1 ring-sky-400/40 bg-sky-500/5 p-2 flex flex-col gap-1.5">
            <div className="grid grid-cols-2 gap-1.5">
                <input
                    value={customer.first_name}
                    onChange={(e) => onChange({ first_name: e.target.value })}
                    placeholder="First"
                    className="bg-black/40 ring-1 ring-white/10 rounded px-1.5 py-1 text-xs"
                />
                <input
                    value={customer.last_name}
                    onChange={(e) => onChange({ last_name: e.target.value })}
                    placeholder="Last"
                    className="bg-black/40 ring-1 ring-white/10 rounded px-1.5 py-1 text-xs"
                />
            </div>
            <select
                value={customer.model}
                onChange={(e) => onChange({ model: e.target.value })}
                className="bg-black/40 ring-1 ring-white/10 rounded px-1.5 py-1 text-xs"
            >
                {MODELS.map((m) => <option key={m} value={m}>{m}</option>)}
            </select>
            <select
                value={customer.idle_scenario}
                onChange={(e) => onChange({ idle_scenario: e.target.value })}
                className="bg-black/40 ring-1 ring-white/10 rounded px-1.5 py-1 text-xs"
            >
                {SCENARIOS.map((s) => <option key={s} value={s}>{s}</option>)}
            </select>
            <div className="text-[10px] text-white/55 mt-1">Zones</div>
            <div className="flex flex-wrap gap-1 max-h-20 overflow-y-auto">
                {zones.length === 0 && (
                    <span className="text-[10px] italic text-white/35">Create a zone first.</span>
                )}
                {zones.map((z) => {
                    const on = customer.zones.includes(z.id);
                    return (
                        <button
                            key={z.id}
                            onClick={() =>
                                onChange({
                                    zones: on
                                        ? customer.zones.filter((id) => id !== z.id)
                                        : [...customer.zones, z.id],
                                })
                            }
                            className={
                                "px-1.5 py-0.5 rounded text-[10px] ring-1 transition-colors " +
                                (on
                                    ? "bg-sky-500/25 ring-sky-400/60 text-sky-50"
                                    : "ring-white/15 text-white/55 hover:bg-white/[0.06]")
                            }
                        >
                            {z.label}
                        </button>
                    );
                })}
            </div>
            <div className="flex items-center justify-between gap-1.5 pt-1 border-t border-white/5">
                {onDelete ? (
                    <button
                        onClick={onDelete}
                        className="inline-flex items-center gap-1 px-2 py-1 rounded ring-1 ring-red-400/40 text-red-200 hover:bg-red-500/15 text-[11px]"
                    >
                        <Trash2 className="h-3 w-3" /> Delete
                    </button>
                ) : <span />}
                <div className="flex gap-1.5">
                    <button onClick={onCancel} className="px-2 py-1 rounded ring-1 ring-white/15 text-white/60 hover:bg-white/[0.06] text-[11px]">
                        Cancel
                    </button>
                    <button
                        onClick={onSave}
                        className="inline-flex items-center gap-1 px-2 py-1 rounded ring-1 ring-emerald-400/50 bg-emerald-500/15 text-emerald-100 hover:bg-emerald-500/30 text-[11px]"
                    >
                        <Save className="h-3 w-3" /> Save
                    </button>
                </div>
            </div>
        </div>
    );
}
