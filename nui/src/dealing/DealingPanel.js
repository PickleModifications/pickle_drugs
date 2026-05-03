import { jsxs as _jsxs, jsx as _jsx } from "react/jsx-runtime";
import { useEffect, useMemo, useRef, useState } from "react";
import { Plus, Trash2, Save, Pencil, MapPin, Edit3, Briefcase, X } from "lucide-react";
import { fetchNui, useNuiEvent } from "@/lib/nui";
import { WorldMap } from "./WorldMap";
const DEFAULT_ZONE_COLOR = "#38bdf8";
const NEW_ZONE = () => ({
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
const NEW_CUSTOMER = () => ({
    id: "",
    first_name: "Customer",
    last_name: "",
    model: "a_m_m_business_01",
    zones: [],
    idle_scenario: "WORLD_HUMAN_SMOKING",
});
const NEW_DEALER = (zoneId) => ({
    id: "",
    zone_id: zoneId,
    cut_pct: 0.10,
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
export function DealingPanel() {
    const [zones, setZones] = useState([]);
    const [customers, setCustomers] = useState([]);
    const [selectedZoneId, setSelectedZoneId] = useState(null);
    const [draftZone, setDraftZone] = useState(null);
    const [editingCustomerId, setEditingCustomerId] = useState(null);
    const [draftCustomer, setDraftCustomer] = useState(null);
    const [dealers, setDealers] = useState([]);
    // Map click-mode: "edit" routes clicks into polygon vertex
    // authoring; "deal" routes them into deal-point placement
    // (rejected unless inside the polygon).
    const [mapMode, setMapMode] = useState("edit");
    // Reset map mode whenever the active zone changes — switching
    // between zones shouldn't carry deal-point intent across them.
    useEffect(() => setMapMode("edit"), [selectedZoneId, draftZone?.id]);
    // Debounced auto-save state for the active zone draft. Mirrors
    // the housing editor pattern: skip the very first commit (which
    // is the load), require a server-assigned id (manual "Create" for
    // new zones), and surface a small SaveStatusPill so the admin
    // sees their changes flushing.
    const [zoneSaveStatus, setZoneSaveStatus] = useState("idle");
    const zoneSaveTimer = useRef(null);
    const zoneSavedFlash = useRef(null);
    const zoneFirstSync = useRef(true);
    // Reset the "skip the loading commit" guard whenever the
    // selected zone changes — otherwise switching zones would burn
    // the first edit on the new zone as a no-op.
    useEffect(() => { zoneFirstSync.current = true; }, [selectedZoneId]);
    // Initial fetch + push the in-world preview on while the panel is open.
    useEffect(() => {
        let cancelled = false;
        (async () => {
            const data = (await fetchNui("dealingList", {}));
            if (cancelled || !data)
                return;
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
    useNuiEvent("dealingZoneUpdate", (z) => {
        if (!z)
            return;
        setZones((prev) => {
            const i = prev.findIndex((x) => x.id === z.id);
            if (i < 0)
                return [...prev, z];
            const next = prev.slice();
            next[i] = z;
            return next;
        });
        // If the in-world picker just landed a center on the active draft,
        // sync it through.
        setDraftZone((d) => (d && d.id === z.id ? z : d));
    });
    useNuiEvent("dealingZoneRemoved", (id) => {
        setZones((prev) => prev.filter((x) => x.id !== id));
        setDraftZone((d) => (d && d.id === id ? null : d));
        setSelectedZoneId((s) => (s === id ? null : s));
    });
    useNuiEvent("dealingCustomerUpdate", (c) => {
        if (!c)
            return;
        setCustomers((prev) => {
            const i = prev.findIndex((x) => x.id === c.id);
            if (i < 0)
                return [...prev, c];
            const next = prev.slice();
            next[i] = c;
            return next;
        });
    });
    useNuiEvent("dealingCustomerRemoved", (id) => {
        setCustomers((prev) => prev.filter((x) => x.id !== id));
        setEditingCustomerId((s) => (s === id ? null : s));
    });
    // Dealer roster (admin view) — bare zone-anchored slots.
    useEffect(() => {
        (async () => {
            const list = (await fetchNui("dealerListAdmin", {}));
            if (list)
                setDealers(list);
        })();
    }, []);
    useNuiEvent("dealerAdminSlotUpdate", (s) => {
        if (!s?.id)
            return;
        setDealers((prev) => {
            const i = prev.findIndex((x) => x.id === s.id);
            if (i < 0)
                return [...prev, s];
            const next = prev.slice();
            next[i] = s;
            return next;
        });
    });
    useNuiEvent("dealerAdminSlotRemoved", (id) => {
        setDealers((prev) => prev.filter((x) => x.id !== id));
    });
    // Per-source ack from the server after a save. For brand-new
    // zones (tempId == "") it carries the assigned id so the editor
    // can adopt it and start auto-saving subsequent edits.
    useNuiEvent("dealingZoneSaved", (d) => {
        if (!d || !d.savedId)
            return;
        if (d.tempId === "") {
            setDraftZone((cur) => cur && !cur.id ? { ...cur, id: d.savedId } : cur);
            setSelectedZoneId((s) => s ?? d.savedId);
        }
        setZoneSaveStatus("saved");
        if (zoneSavedFlash.current)
            window.clearTimeout(zoneSavedFlash.current);
        zoneSavedFlash.current = window.setTimeout(() => setZoneSaveStatus("idle"), 1500);
    });
    // Picker callback — Lua finishes a center / deal-point pick, fires this.
    useNuiEvent("dealingPickerDone", (r) => {
        if (!r || r.cancelled || !r.point)
            return;
        setDraftZone((d) => {
            if (!d || d.id !== r.zoneId)
                return d;
            if (r.kind === "center") {
                return { ...d, center_x: r.point.x, center_y: r.point.y, center_z: r.point.z };
            }
            return { ...d, deal_points: [...d.deal_points, r.point] };
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
        if (!draftZone)
            return;
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
        if (zoneSaveTimer.current)
            window.clearTimeout(zoneSaveTimer.current);
        zoneSaveTimer.current = window.setTimeout(() => {
            fetchNui("dealingSaveZone", draftZone);
        }, 600);
        return () => {
            if (zoneSaveTimer.current)
                window.clearTimeout(zoneSaveTimer.current);
        };
    }, [draftZone]);
    const selectedZone = useMemo(() => draftZone ?? zones.find((z) => z.id === selectedZoneId) ?? null, [draftZone, zones, selectedZoneId]);
    const customersInSelected = useMemo(() => {
        if (!selectedZone)
            return customers;
        return customers.filter((c) => c.zones.includes(selectedZone.id));
    }, [customers, selectedZone]);
    const startEditingZone = (z) => {
        setSelectedZoneId(z.id || null);
        setDraftZone({ ...z });
    };
    const startNewZone = () => {
        const z = NEW_ZONE();
        setDraftZone(z);
        setSelectedZoneId(null);
    };
    const cancelDraftZone = () => {
        setDraftZone(null);
        setSelectedZoneId(null);
    };
    const saveDraftZone = () => {
        if (!draftZone)
            return;
        fetchNui("dealingSaveZone", draftZone);
        setDraftZone(null);
    };
    const deleteSelectedZone = () => {
        if (!selectedZone || !selectedZone.id)
            return;
        fetchNui("dealingDeleteZone", { id: selectedZone.id });
    };
    const startEditingCustomer = (c) => {
        setEditingCustomerId(c.id);
        setDraftCustomer({ ...c });
    };
    const startNewCustomer = () => {
        setEditingCustomerId("__new__");
        setDraftCustomer(NEW_CUSTOMER());
    };
    const saveDraftCustomer = () => {
        if (!draftCustomer)
            return;
        fetchNui("dealingSaveCustomer", draftCustomer);
        setEditingCustomerId(null);
        setDraftCustomer(null);
    };
    const deleteCustomer = (id) => fetchNui("dealingDeleteCustomer", { id });
    const dealersInSelected = useMemo(() => {
        if (!selectedZone || !selectedZone.id)
            return [];
        return dealers.filter((d) => d.zone_id === selectedZone.id);
    }, [dealers, selectedZone]);
    const addDealerToSelectedZone = () => {
        if (!selectedZone || !selectedZone.id)
            return;
        fetchNui("dealerSave", NEW_DEALER(selectedZone.id));
    };
    const updateDealerCut = (d, cutPct) => {
        fetchNui("dealerSave", { ...d, cut_pct: Math.max(0, Math.min(1, cutPct)) });
    };
    const deleteDealer = (id) => fetchNui("dealerDelete", { id });
    return (_jsxs("div", { className: "h-full grid grid-cols-[220px_1fr_340px_1fr] gap-3 min-h-0 text-white", children: [_jsxs("div", { className: "min-h-0 flex flex-col gap-2", children: [_jsxs("div", { className: "flex items-center justify-between shrink-0", children: [_jsxs("span", { className: "text-xs text-white/85 font-medium", children: ["Zones ", _jsxs("span", { className: "text-white/45", children: ["\u00B7 ", zones.length] })] }), _jsxs("button", { onClick: startNewZone, className: "inline-flex items-center gap-1.5 px-2 py-1 rounded ring-1 ring-emerald-400/50 bg-emerald-500/15 text-emerald-100 hover:bg-emerald-500/30 text-[11px]", children: [_jsx(Plus, { className: "h-3 w-3" }), " New"] })] }), _jsxs("div", { className: "flex-1 overflow-y-auto pr-1 -mr-1 flex flex-col gap-1", children: [zones.length === 0 && (_jsx("div", { className: "text-[11px] italic text-white/40", children: "No zones yet." })), zones.map((z) => {
                                const active = selectedZoneId === z.id;
                                const cuCount = customers.filter((c) => c.zones.includes(z.id)).length;
                                return (_jsxs("button", { onClick: () => startEditingZone(z), className: "text-left rounded px-2 py-1.5 ring-1 transition-colors " +
                                        (active
                                            ? "ring-sky-400/60 bg-sky-500/10"
                                            : "ring-white/10 hover:bg-white/[0.04]"), children: [_jsx("div", { className: "text-xs truncate", children: z.label }), _jsxs("div", { className: "text-[10px] text-white/45 tabular-nums", children: [(z.points?.length ?? 0), " verts \u00B7 ", z.deal_points.length, " pts \u00B7 ", cuCount, " cust"] })] }, z.id));
                            })] })] }), _jsx("div", { className: "min-h-0 flex flex-col", children: _jsx(WorldMap, { zones: zones.map((z) => ({
                        id: z.id,
                        label: z.label,
                        kind: z.kind ?? "polygon",
                        color: z.color || DEFAULT_ZONE_COLOR,
                        centerX: z.center_x,
                        centerY: z.center_y,
                        centerZ: z.center_z,
                        radius: z.radius,
                        points: z.points ?? [],
                        dealPoints: z.deal_points,
                    })), selectedZoneId: selectedZone?.id ?? null, draftShape: selectedZone
                        ? {
                            centerX: selectedZone.center_x,
                            centerY: selectedZone.center_y,
                            points: selectedZone.points ?? [],
                        }
                        : null, draftDealPoints: selectedZone?.deal_points ?? [], mode: mapMode, onSelectZone: (id) => {
                        const z = zones.find((x) => x.id === id);
                        if (z)
                            startEditingZone(z);
                    }, onShapeChange: (patch) => {
                        if (!selectedZone)
                            return;
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
                                ...(patch.points !== undefined ? { points: patch.points } : {}),
                            };
                        });
                    }, onAddDealPointBlocked: () => 
                    // Map already shows where it landed via the
                    // cursor readout. A toast on every miss feels
                    // noisy; instead light up a brief amber tint
                    // on the panel by toggling status.
                    setZoneSaveStatus("idle"), onAddDealPoint: (x, y) => {
                        if (!selectedZone)
                            return;
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
                    } }) }), _jsx("div", { className: "min-h-0 flex flex-col overflow-y-auto pr-1 -mr-1", children: selectedZone ? (_jsx(ZoneEditor, { zone: selectedZone, mapMode: mapMode, onMapMode: setMapMode, saveStatus: zoneSaveStatus, onChange: (patch) => setDraftZone((d) => ({ ...(d ?? selectedZone), ...patch })), onRemoveDealPoint: (idx) => setDraftZone((d) => {
                        const base = d ?? selectedZone;
                        const pts = base.deal_points.slice();
                        pts.splice(idx, 1);
                        return { ...base, deal_points: pts };
                    }), dealers: dealersInSelected, onAddDealer: addDealerToSelectedZone, onDealerCutChange: updateDealerCut, onDeleteDealer: deleteDealer, onCreate: saveDraftZone, onClose: cancelDraftZone, onDelete: selectedZone.id ? deleteSelectedZone : undefined })) : (_jsx("div", { className: "text-[11px] italic text-white/40 px-1", children: "Click a zone on the map to edit, or create a new one." })) }), _jsxs("div", { className: "min-h-0 flex flex-col gap-2", children: [_jsxs("div", { className: "flex items-center justify-between shrink-0", children: [_jsxs("span", { className: "text-xs text-white/85 font-medium", children: ["Customers ", _jsxs("span", { className: "text-white/45", children: ["\u00B7 ", customersInSelected.length, customersInSelected.length !== customers.length ? ` of ${customers.length}` : ""] })] }), _jsxs("button", { onClick: startNewCustomer, className: "inline-flex items-center gap-1.5 px-2 py-1 rounded ring-1 ring-emerald-400/50 bg-emerald-500/15 text-emerald-100 hover:bg-emerald-500/30 text-[11px]", children: [_jsx(Plus, { className: "h-3 w-3" }), " New"] })] }), _jsxs("div", { className: "flex-1 overflow-y-auto pr-1 -mr-1 flex flex-col gap-1", children: [editingCustomerId === "__new__" && draftCustomer && (_jsx(CustomerEditor, { zones: zones, customer: draftCustomer, onChange: (patch) => setDraftCustomer((d) => ({ ...d, ...patch })), onSave: saveDraftCustomer, onCancel: () => { setDraftCustomer(null); setEditingCustomerId(null); } })), customersInSelected.map((c) => {
                                const editing = editingCustomerId === c.id && draftCustomer;
                                if (editing) {
                                    return (_jsx(CustomerEditor, { zones: zones, customer: draftCustomer, onChange: (patch) => setDraftCustomer((d) => ({ ...d, ...patch })), onSave: saveDraftCustomer, onCancel: () => { setDraftCustomer(null); setEditingCustomerId(null); }, onDelete: () => deleteCustomer(c.id) }, c.id));
                                }
                                return (_jsxs("button", { onClick: () => startEditingCustomer(c), className: "text-left rounded px-2 py-1.5 ring-1 ring-white/10 hover:bg-white/[0.04] flex items-center gap-2", children: [_jsxs("div", { className: "flex-1 min-w-0", children: [_jsxs("div", { className: "text-xs truncate", children: [c.first_name, " ", c.last_name] }), _jsxs("div", { className: "text-[10px] text-white/45 truncate", children: [c.model, " \u00B7 ", c.zones.length, " zone", c.zones.length === 1 ? "" : "s"] })] }), _jsx(Pencil, { className: "h-3 w-3 text-white/40" })] }, c.id));
                            }), customersInSelected.length === 0 && editingCustomerId !== "__new__" && (_jsx("div", { className: "text-[11px] italic text-white/40", children: selectedZone ? "No customers assigned to this zone." : "No customers yet." }))] })] })] }));
}
function ZoneEditor({ zone, mapMode, onMapMode, saveStatus, onChange, onRemoveDealPoint, dealers, onAddDealer, onDealerCutChange, onDeleteDealer, onCreate, onClose, onDelete, }) {
    const persisted = !!zone.id;
    return (_jsxs("div", { className: "rounded ring-1 ring-white/10 bg-white/[0.02] p-2 flex flex-col gap-1.5 text-[11px]", children: [_jsxs("div", { className: "flex gap-1.5 items-stretch", children: [_jsx("input", { type: "color", value: zone.color || "#38bdf8", onChange: (e) => onChange({ color: e.target.value }), className: "w-8 h-auto bg-black/40 ring-1 ring-white/10 rounded cursor-pointer p-0.5", title: "Zone color" }), _jsx("input", { value: zone.label, onChange: (e) => onChange({ label: e.target.value }), className: "flex-1 bg-black/40 ring-1 ring-white/10 rounded px-1.5 py-1 text-xs", placeholder: "Zone label" })] }), _jsx(Coord, { label: "Z", value: zone.center_z, onChange: (v) => onChange({ center_z: v }) }), _jsx("div", { className: "flex gap-1", children: [
                    { id: "edit", label: "Edit polygon", Icon: Edit3 },
                    { id: "deal", label: "Add deal point", Icon: MapPin },
                ].map(({ id, label, Icon }) => {
                    const active = mapMode === id;
                    return (_jsxs("button", { onClick: () => onMapMode(id), className: "flex-1 inline-flex items-center justify-center gap-1.5 px-2 py-1 rounded ring-1 transition-colors text-[11px] " +
                            (active
                                ? id === "deal"
                                    ? "bg-amber-500/25 ring-amber-400/50 text-amber-50"
                                    : "bg-sky-500/25 ring-sky-400/50 text-sky-50"
                                : "ring-white/15 text-white/65 hover:bg-white/[0.06]"), children: [_jsx(Icon, { className: "h-3 w-3" }), " ", label] }, id));
                }) }), zone.deal_points.length > 0 && (_jsx("div", { className: "max-h-16 overflow-y-auto flex flex-col gap-0.5", children: zone.deal_points.map((p, i) => (_jsxs("div", { className: "flex items-center gap-1.5 text-[10px] text-white/55", children: [_jsx("span", { className: "font-mono w-4", children: i + 1 }), _jsxs("span", { className: "flex-1 truncate tabular-nums", children: [p.x.toFixed(1), ", ", p.y.toFixed(1), ", ", p.z.toFixed(1)] }), _jsx("button", { onClick: () => onRemoveDealPoint(i), className: "hover:text-red-300", children: _jsx(Trash2, { className: "h-3 w-3" }) })] }, i))) })), persisted && (_jsxs("div", { className: "pt-1.5 mt-0.5 border-t border-white/5 flex flex-col gap-1", children: [_jsxs("div", { className: "flex items-center justify-between", children: [_jsxs("span", { className: "text-[10px] uppercase tracking-wider text-white/55 inline-flex items-center gap-1", children: [_jsx(Briefcase, { className: "h-3 w-3 text-amber-300" }), "Dealers \u00B7 ", dealers.length] }), _jsxs("button", { onClick: onAddDealer, className: "inline-flex items-center gap-1 px-1.5 py-0.5 rounded ring-1 ring-amber-400/50 bg-amber-500/15 text-amber-100 hover:bg-amber-500/30 text-[10px]", children: [_jsx(Plus, { className: "h-3 w-3" }), " Add"] })] }), dealers.length === 0 ? (_jsx("div", { className: "text-[10px] italic text-white/35", children: "No dealers in this zone." })) : (_jsx("div", { className: "flex flex-col gap-0.5 max-h-24 overflow-y-auto", children: dealers.map((d) => (_jsxs("div", { className: "flex items-center gap-1.5 px-1.5 py-1 rounded ring-1 ring-white/10 bg-black/30", children: [_jsx("span", { className: "text-[10px] text-white/50 font-mono truncate flex-1", children: d.id.slice(-6) }), _jsxs("label", { className: "inline-flex items-center gap-1 bg-black/40 ring-1 ring-white/10 rounded px-1 py-0.5", children: [_jsx("span", { className: "text-white/45 text-[9px]", children: "cut" }), _jsx("input", { type: "number", min: 0, max: 100, value: Math.round((d.cut_pct ?? 0.10) * 100), onChange: (e) => onDealerCutChange(d, Math.max(0, Math.min(1, (parseInt(e.target.value) || 0) / 100))), className: "bg-transparent w-9 outline-none text-[11px] tabular-nums" }), _jsx("span", { className: "text-white/45 text-[9px]", children: "%" })] }), _jsx("button", { onClick: () => onDeleteDealer(d.id), className: "hover:text-red-300 text-white/45", title: "Remove dealer", children: _jsx(X, { className: "h-3 w-3" }) })] }, d.id))) }))] })), _jsxs("div", { className: "flex items-center justify-between gap-1.5 pt-1 border-t border-white/5", children: [onDelete ? (_jsxs("button", { onClick: onDelete, className: "inline-flex items-center gap-1 px-2 py-1 rounded ring-1 ring-red-400/40 text-red-200 hover:bg-red-500/15 text-[11px]", children: [_jsx(Trash2, { className: "h-3 w-3" }), " Delete"] })) : _jsx("span", {}), _jsxs("div", { className: "flex items-center gap-1.5", children: [persisted ? (_jsx(ZoneSaveStatusPill, { status: saveStatus })) : (_jsxs("button", { onClick: onCreate, className: "inline-flex items-center gap-1 px-2 py-1 rounded ring-1 ring-emerald-400/50 bg-emerald-500/15 text-emerald-100 hover:bg-emerald-500/30 text-[11px]", children: [_jsx(Save, { className: "h-3 w-3" }), " Create"] })), _jsx("button", { onClick: onClose, className: "px-2 py-1 rounded ring-1 ring-white/15 text-white/60 hover:bg-white/[0.06] text-[11px]", children: "Close" })] })] })] }));
}
// Compact save status pill — mirrors the housing editor's affordance.
function ZoneSaveStatusPill({ status }) {
    if (status === "pending") {
        return (_jsxs("span", { className: "px-2 py-1 inline-flex items-center gap-1.5 rounded ring-1 ring-amber-400/40 bg-amber-500/10 text-amber-100/80 text-[11px]", children: [_jsx("span", { className: "h-1.5 w-1.5 rounded-full bg-amber-300/80 animate-pulse" }), "Saving\u2026"] }));
    }
    if (status === "saved") {
        return (_jsxs("span", { className: "px-2 py-1 inline-flex items-center gap-1.5 rounded ring-1 ring-emerald-400/40 bg-emerald-500/10 text-emerald-100/85 text-[11px]", children: [_jsx("span", { className: "h-1.5 w-1.5 rounded-full bg-emerald-300/80" }), "Saved"] }));
    }
    return (_jsx("span", { className: "px-2 py-1 inline-flex items-center gap-1.5 rounded ring-1 ring-white/15 text-white/45 text-[11px]", children: "Auto-save on" }));
}
function Coord({ label, value, onChange }) {
    return (_jsxs("label", { className: "flex items-center gap-1 bg-black/40 ring-1 ring-white/10 rounded px-1.5 py-1", children: [_jsx("span", { className: "text-white/45 text-[10px] w-3", children: label }), _jsx("input", { type: "number", value: Number.isFinite(value) ? Number(value.toFixed(1)) : 0, onChange: (e) => onChange(parseFloat(e.target.value) || 0), className: "bg-transparent w-full outline-none text-xs" })] }));
}
function CustomerEditor({ customer, zones, onChange, onSave, onCancel, onDelete, }) {
    return (_jsxs("div", { className: "rounded ring-1 ring-sky-400/40 bg-sky-500/5 p-2 flex flex-col gap-1.5", children: [_jsxs("div", { className: "grid grid-cols-2 gap-1.5", children: [_jsx("input", { value: customer.first_name, onChange: (e) => onChange({ first_name: e.target.value }), placeholder: "First", className: "bg-black/40 ring-1 ring-white/10 rounded px-1.5 py-1 text-xs" }), _jsx("input", { value: customer.last_name, onChange: (e) => onChange({ last_name: e.target.value }), placeholder: "Last", className: "bg-black/40 ring-1 ring-white/10 rounded px-1.5 py-1 text-xs" })] }), _jsx("select", { value: customer.model, onChange: (e) => onChange({ model: e.target.value }), className: "bg-black/40 ring-1 ring-white/10 rounded px-1.5 py-1 text-xs", children: MODELS.map((m) => _jsx("option", { value: m, children: m }, m)) }), _jsx("select", { value: customer.idle_scenario, onChange: (e) => onChange({ idle_scenario: e.target.value }), className: "bg-black/40 ring-1 ring-white/10 rounded px-1.5 py-1 text-xs", children: SCENARIOS.map((s) => _jsx("option", { value: s, children: s }, s)) }), _jsx("div", { className: "text-[10px] text-white/55 mt-1", children: "Zones" }), _jsxs("div", { className: "flex flex-wrap gap-1 max-h-20 overflow-y-auto", children: [zones.length === 0 && (_jsx("span", { className: "text-[10px] italic text-white/35", children: "Create a zone first." })), zones.map((z) => {
                        const on = customer.zones.includes(z.id);
                        return (_jsx("button", { onClick: () => onChange({
                                zones: on
                                    ? customer.zones.filter((id) => id !== z.id)
                                    : [...customer.zones, z.id],
                            }), className: "px-1.5 py-0.5 rounded text-[10px] ring-1 transition-colors " +
                                (on
                                    ? "bg-sky-500/25 ring-sky-400/60 text-sky-50"
                                    : "ring-white/15 text-white/55 hover:bg-white/[0.06]"), children: z.label }, z.id));
                    })] }), _jsxs("div", { className: "flex items-center justify-between gap-1.5 pt-1 border-t border-white/5", children: [onDelete ? (_jsxs("button", { onClick: onDelete, className: "inline-flex items-center gap-1 px-2 py-1 rounded ring-1 ring-red-400/40 text-red-200 hover:bg-red-500/15 text-[11px]", children: [_jsx(Trash2, { className: "h-3 w-3" }), " Delete"] })) : _jsx("span", {}), _jsxs("div", { className: "flex gap-1.5", children: [_jsx("button", { onClick: onCancel, className: "px-2 py-1 rounded ring-1 ring-white/15 text-white/60 hover:bg-white/[0.06] text-[11px]", children: "Cancel" }), _jsxs("button", { onClick: onSave, className: "inline-flex items-center gap-1 px-2 py-1 rounded ring-1 ring-emerald-400/50 bg-emerald-500/15 text-emerald-100 hover:bg-emerald-500/30 text-[11px]", children: [_jsx(Save, { className: "h-3 w-3" }), " Save"] })] })] })] }));
}
