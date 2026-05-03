import { jsx as _jsx, jsxs as _jsxs } from "react/jsx-runtime";
// Player-facing house management panel. Shown when the player interacts
// with the world door ("Inspect Property") or the in-house management
// ox_target. Bottom-anchored bar (Plant-Console style) with tabs so the
// player can flip between Property / Access / Workers without
// re-targeting the management point. A "Walk" toggle releases NUI focus
// so the player can move around and inspect the house in-world; the
// panel stays mounted (with reduced opacity) and resumes on ESC or
// click.
//
// Plants and storage lockers are managed directly in-world via the
// plot / locker ox_targets, not from this panel.
import { useEffect, useState } from "react";
import { Building, DollarSign, Users, X, Trash2, UserPlus, ListChecks, Footprints, KeyRound, Home, ArrowLeft, Plus, Sprout, } from "lucide-react";
import { fetchNui, useNuiEvent } from "@/lib/nui";
function fmtMoney(n) {
    return "$" + n.toLocaleString();
}
function fmtDue(at) {
    if (!at)
        return "—";
    const ms = at - Date.now();
    if (ms <= 0)
        return "OVERDUE";
    const s = Math.floor(ms / 1000);
    const d = Math.floor(s / 86400);
    if (d > 0)
        return `${d}d`;
    const h = Math.floor(s / 3600);
    if (h > 0)
        return `${h}h`;
    return `${Math.max(1, Math.floor(s / 60))}m`;
}
function TabButton({ label, Icon, active, onClick, }) {
    return (_jsxs("button", { onClick: onClick, disabled: active, className: "px-3 py-1.5 rounded text-xs ring-1 transition-colors inline-flex items-center gap-1.5 " +
            (active
                ? "bg-emerald-500/25 ring-emerald-400/60 text-emerald-50 cursor-default"
                : "ring-white/15 text-white/70 hover:bg-white/[0.06]"), children: [_jsx(Icon, { className: "h-3.5 w-3.5" }), label] }));
}
export function HouseManagePanel({ data, hidden, onClose, }) {
    const { house, isOwner, pedModels } = data;
    const canManage = isOwner || !!data.isAdmin;
    const [residentDraft, setResidentDraft] = useState("");
    const [residents, setResidents] = useState(house.residents || []);
    const [employees, setEmployees] = useState(data.employees || []);
    const [hireModel, setHireModel] = useState(pedModels?.[0] ?? "");
    const [hireFirst, setHireFirst] = useState("");
    const [hireLast, setHireLast] = useState("");
    const [walking, setWalking] = useState(false);
    const [walkKey, setWalkKey] = useState("ESC");
    const [tab, setTab] = useState(data.initialAssigner ? "workers" : "property");
    const [assigner, setAssigner] = useState(data.initialAssigner ?? null);
    useEffect(() => { setEmployees(data.employees || []); }, [data.employees]);
    useEffect(() => { setResidents(house.residents || []); }, [house.residents]);
    useNuiEvent("houseEmployeesList", (d) => {
        if (d?.employees)
            setEmployees(d.employees);
    });
    useNuiEvent("houseManageWalkState", (d) => {
        setWalking(!!d?.walking);
        if (d?.key)
            setWalkKey(d.key);
    });
    // Lua pushes this in response to the "Assign plots" click. Switches
    // the Workers tab from the roster list to an inline plot picker.
    useNuiEvent("houseManageAssignerData", (d) => {
        if (!d?.empId)
            return;
        setAssigner(d);
        setTab("workers");
    });
    const hireEmployee = () => {
        if (!hireModel)
            return;
        fetchNui("houseHireEmployee", {
            houseId: house.id,
            model: hireModel,
            firstName: hireFirst.trim(),
            lastName: hireLast.trim(),
        });
        setHireFirst("");
        setHireLast("");
    };
    const dismissEmployee = (empId) => fetchNui("houseDismissEmployee", { houseId: house.id, empId });
    const assignWorkerPlots = (empId) => fetchNui("houseAssignWorkerPlots", { empId });
    const tenureColor = house.tenure === "owned" ? "text-emerald-300" :
        house.tenure === "rented" ? "text-amber-300" :
            "text-white/60";
    const addResident = () => {
        const v = residentDraft.trim();
        if (!v || residents.includes(v))
            return;
        const next = [...residents, v];
        setResidents(next);
        setResidentDraft("");
        fetchNui("houseSetResidents", { houseId: house.id, residents: next });
    };
    const removeResident = (cid) => {
        const next = residents.filter((r) => r !== cid);
        setResidents(next);
        fetchNui("houseSetResidents", { houseId: house.id, residents: next });
    };
    // ─── Tab visibility ────────────────────────────────────────────────
    const tabs = ["property"];
    if (house.tenure !== "none" && canManage)
        tabs.push("access", "workers");
    useEffect(() => {
        if (!tabs.includes(tab))
            setTab(tabs[0] ?? "property");
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [house.tenure, canManage]);
    return (_jsxs("div", { className: "fixed left-1/2 -translate-x-1/2 bottom-4 pointer-events-none", style: { visibility: hidden ? "hidden" : "visible" }, children: [_jsxs("div", { className: "pointer-events-auto rounded-2xl bg-black/95 ring-1 ring-white/10 shadow-2xl overflow-hidden " +
                    "w-[680px] max-w-[96vw] h-[360px] flex flex-col " +
                    (walking ? "opacity-70" : ""), style: walking ? { pointerEvents: "none" } : undefined, children: [_jsxs("div", { className: "grid grid-cols-[auto_1fr_auto_auto] items-center gap-3 px-4 h-9 border-b border-white/5 bg-white/[0.02] shrink-0", children: [_jsxs("div", { className: "flex items-center gap-2 whitespace-nowrap", children: [_jsx(Building, { className: "h-4 w-4 text-emerald-300" }), _jsx("span", { className: "text-sm text-white font-medium", children: house.label }), _jsxs("span", { className: "text-[10px] uppercase tracking-wider " + tenureColor, children: [house.tenure, house.tenure === "rented" && ` · due ${fmtDue(house.rent_due_at)}`] })] }), _jsxs("div", { className: "flex justify-center gap-1", children: [tabs.includes("property") && (_jsx(TabButton, { label: "Property", Icon: Home, active: tab === "property", onClick: () => setTab("property") })), tabs.includes("access") && (_jsx(TabButton, { label: "Access", Icon: KeyRound, active: tab === "access", onClick: () => setTab("access") })), tabs.includes("workers") && (_jsx(TabButton, { label: "Workers", Icon: Users, active: tab === "workers", onClick: () => setTab("workers") }))] }), _jsxs("button", { onClick: () => fetchNui("houseManageToggleWalk", {}), title: walking ? `Resume (${walkKey})` : `Walk (${walkKey})`, className: "h-7 px-2 inline-flex items-center gap-1.5 rounded ring-1 transition-colors text-[11px] " +
                                    (walking
                                        ? "bg-amber-500/25 ring-amber-400/60 text-amber-50"
                                        : "ring-white/20 text-white/75 hover:bg-white/[0.06]"), children: [_jsx(Footprints, { className: "h-3.5 w-3.5" }), walking ? "Walking" : "Walk"] }), _jsx("button", { onClick: onClose, className: "h-7 w-7 inline-flex items-center justify-center rounded ring-1 ring-white/25 text-white/70 hover:text-red-200 hover:bg-red-500/15", children: _jsx(X, { className: "h-4 w-4" }) })] }), _jsxs("div", { className: "flex-1 min-h-0 overflow-y-auto p-4", children: [tab === "property" && (_jsx(PropertyTab, { data: data, canManage: canManage })), tab === "access" && canManage && (_jsx(AccessTab, { residents: residents, residentDraft: residentDraft, setResidentDraft: setResidentDraft, addResident: addResident, removeResident: removeResident })), tab === "workers" && canManage && !assigner && (_jsx(WorkersTab, { employees: employees, pedModels: pedModels, hireModel: hireModel, setHireModel: setHireModel, hireFirst: hireFirst, setHireFirst: setHireFirst, hireLast: hireLast, setHireLast: setHireLast, onHire: hireEmployee, onDismiss: dismissEmployee, onAssign: assignWorkerPlots })), tab === "workers" && canManage && assigner && (_jsx(InlineAssigner, { state: assigner, onClose: () => setAssigner(null), onAddPlot: () => fetchNui("housePickWorkerPlot", { empId: assigner.empId }), onSave: (plotIds) => {
                                    // Saves in-place — keep the assigner mounted so
                                    // the player can keep pruning slots without
                                    // re-opening the worker.
                                    fetchNui("houseManageAssignerSave", { empId: assigner.empId, plotIds });
                                    setAssigner({ ...assigner, assignedPlots: plotIds });
                                } }))] })] }), walking && (_jsx("div", { className: "absolute left-1/2 -translate-x-1/2 -top-9 pointer-events-auto", children: _jsxs("button", { onClick: () => fetchNui("houseManageToggleWalk", {}), className: "inline-flex items-center gap-2 px-3 py-1.5 rounded-full ring-1 ring-amber-400/50 bg-amber-500/20 text-amber-50 text-xs hover:bg-amber-500/35", children: [_jsx(Footprints, { className: "h-3.5 w-3.5" }), "Walking \u2014 press ", _jsx("kbd", { className: "px-1 rounded bg-white/10 ring-1 ring-white/15 font-mono text-[10px]", children: walkKey }), " or click to resume"] }) }))] }));
}
// ─── Tabs ────────────────────────────────────────────────────────────────
function PropertyTab({ data, canManage }) {
    const { house } = data;
    return (_jsxs("div", { className: "space-y-3", children: [house.tenure === "none" && (_jsxs("div", { className: "grid grid-cols-2 gap-3", children: [house.sale_enabled && (_jsxs("button", { onClick: () => fetchNui("housePurchase", { houseId: house.id, mode: "buy" }), className: "rounded-lg bg-emerald-500/10 ring-1 ring-emerald-400/40 p-4 text-left hover:bg-emerald-500/25 hover:ring-emerald-400/70 transition-colors", children: [_jsxs("div", { className: "flex items-center gap-2 text-emerald-200", children: [_jsx(DollarSign, { className: "h-4 w-4" }), _jsx("span", { className: "text-sm font-medium", children: "Buy" })] }), _jsx("div", { className: "text-2xl font-semibold text-emerald-50 mt-1 tabular-nums", children: fmtMoney(house.sale_price) }), _jsx("div", { className: "text-[11px] text-white/50", children: "One-time payment, owned forever." })] })), house.rent_enabled && (_jsxs("button", { onClick: () => fetchNui("housePurchase", { houseId: house.id, mode: "rent" }), className: "rounded-lg bg-amber-500/10 ring-1 ring-amber-400/40 p-4 text-left hover:bg-amber-500/25 hover:ring-amber-400/70 transition-colors", children: [_jsxs("div", { className: "flex items-center gap-2 text-amber-200", children: [_jsx(DollarSign, { className: "h-4 w-4" }), _jsx("span", { className: "text-sm font-medium", children: "Rent" })] }), _jsx("div", { className: "text-2xl font-semibold text-amber-50 mt-1 tabular-nums", children: fmtMoney(house.rent_price) }), _jsxs("div", { className: "text-[11px] text-white/50", children: ["per ", Math.round(house.rent_cycle_ms / (24 * 60 * 60 * 1000)), "d cycle"] })] })), !house.sale_enabled && !house.rent_enabled && (_jsx("div", { className: "col-span-2 text-sm italic text-white/50", children: "This property isn't currently for sale or rent." }))] })), house.tenure !== "none" && canManage && (_jsxs("div", { className: "grid grid-cols-2 gap-3", children: [house.tenure === "rented" && (_jsxs("button", { onClick: () => fetchNui("housePayRent", { houseId: house.id }), className: "rounded-lg bg-amber-500/10 ring-1 ring-amber-400/40 p-3 text-left hover:bg-amber-500/25", children: [_jsx("div", { className: "text-sm text-amber-100 font-medium", children: "Pay rent" }), _jsx("div", { className: "text-lg font-semibold text-amber-50 tabular-nums", children: fmtMoney(house.rent_price) })] })), _jsxs("button", { onClick: () => fetchNui("houseCancelLease", { houseId: house.id }), className: "rounded-lg bg-red-500/10 ring-1 ring-red-400/40 p-3 text-left hover:bg-red-500/25", children: [_jsx("div", { className: "text-sm text-red-200 font-medium", children: "Cancel lease" }), _jsx("div", { className: "text-[11px] text-white/55", children: "Lapses immediately. Entities stay until next purchase." })] })] })), house.tenure !== "none" && !canManage && (_jsx("div", { className: "text-[12px] italic text-white/55", children: "You have access to this property but aren't the owner. Speak to the owner if you want to manage workers or placement." }))] }));
}
function AccessTab({ residents, residentDraft, setResidentDraft, addResident, removeResident, }) {
    return (_jsxs("div", { className: "space-y-3", children: [_jsxs("div", { className: "flex items-center gap-2 text-white/85", children: [_jsx(Users, { className: "h-4 w-4" }), _jsx("span", { className: "text-sm font-medium", children: "Residents" }), _jsxs("span", { className: "text-[11px] text-white/40", children: ["\u00B7 ", residents.length] })] }), _jsxs("div", { className: "flex gap-2", children: [_jsx("input", { value: residentDraft, onChange: (e) => setResidentDraft(e.target.value), placeholder: "citizenid", className: "flex-1 bg-white/[0.06] ring-1 ring-white/20 rounded-md px-3 py-2 text-sm text-white outline-none focus:ring-emerald-400/60" }), _jsx("button", { onClick: addResident, className: "px-3 py-2 rounded-md ring-1 ring-emerald-400/50 bg-emerald-500/15 text-emerald-100 hover:bg-emerald-500/30 text-xs", children: "Add" })] }), _jsxs("div", { className: "flex flex-wrap gap-1.5", children: [residents.length === 0 && (_jsx("span", { className: "text-[11px] italic text-white/40", children: "Just the owner \u2014 add citizenids to share access." })), residents.map((r) => (_jsxs("span", { className: "inline-flex items-center gap-1.5 rounded-md bg-white/[0.06] ring-1 ring-white/15 px-2 py-1 text-[11px] text-white/80", children: [r, _jsx("button", { onClick: () => removeResident(r), className: "text-white/45 hover:text-red-300", children: _jsx(Trash2, { className: "h-3 w-3" }) })] }, r)))] })] }));
}
function WorkersTab({ employees, pedModels, hireModel, setHireModel, hireFirst, setHireFirst, hireLast, setHireLast, onHire, onDismiss, onAssign, }) {
    return (_jsxs("div", { className: "space-y-3", children: [_jsxs("div", { className: "flex items-center gap-2 text-white/85", children: [_jsx(UserPlus, { className: "h-4 w-4" }), _jsx("span", { className: "text-sm font-medium", children: "Workers" }), _jsxs("span", { className: "text-[11px] text-white/40", children: ["\u00B7 ", employees.length, " hired"] })] }), _jsxs("div", { className: "grid grid-cols-[1fr_auto_auto_auto] gap-2", children: [_jsx("select", { value: hireModel, onChange: (e) => setHireModel(e.target.value), className: "bg-white/[0.06] ring-1 ring-white/20 rounded-md px-2 py-1.5 text-sm text-white outline-none", children: (pedModels || []).map((m) => (_jsx("option", { value: m, className: "bg-neutral-900", children: m }, m))) }), _jsx("input", { value: hireFirst, onChange: (e) => setHireFirst(e.target.value), placeholder: "First", className: "w-24 bg-white/[0.06] ring-1 ring-white/20 rounded-md px-2 py-1.5 text-sm text-white outline-none focus:ring-emerald-400/60" }), _jsx("input", { value: hireLast, onChange: (e) => setHireLast(e.target.value), placeholder: "Last", className: "w-24 bg-white/[0.06] ring-1 ring-white/20 rounded-md px-2 py-1.5 text-sm text-white outline-none focus:ring-emerald-400/60" }), _jsx("button", { onClick: onHire, className: "px-3 py-1.5 rounded-md ring-1 ring-emerald-400/50 bg-emerald-500/15 text-emerald-100 hover:bg-emerald-500/30 text-xs", children: "Hire" })] }), _jsxs("div", { className: "space-y-1", children: [employees.length === 0 && (_jsx("span", { className: "text-[11px] italic text-white/40", children: "Hire a worker to tend every plot in this house automatically." })), employees.map((e) => (_jsxs("div", { className: "flex items-center gap-2 rounded-md bg-white/[0.04] ring-1 ring-white/10 px-2.5 py-1.5", children: [_jsxs("span", { className: "text-sm text-white/90", children: [e.firstName, " ", e.lastName] }), _jsx("span", { className: "text-[10px] text-white/40 truncate", children: e.model }), _jsx("button", { onClick: () => onAssign(e.id), title: "Assign plots", className: "ml-auto h-6 w-6 inline-flex items-center justify-center rounded ring-1 ring-white/15 text-white/70 hover:text-emerald-200 hover:bg-emerald-500/15", children: _jsx(ListChecks, { className: "h-3.5 w-3.5" }) }), _jsx("button", { onClick: () => onDismiss(e.id), title: "Dismiss", className: "h-6 w-6 inline-flex items-center justify-center rounded ring-1 ring-white/15 text-white/55 hover:text-red-300 hover:bg-red-500/15", children: _jsx(Trash2, { className: "h-3.5 w-3.5" }) })] }, e.id)))] })] }));
}
// Slot grid: shows each currently-assigned plot as a card and pads up to
// `maxPlots` with empty "+ add" slots. Removing a plot saves the new list
// immediately. Clicking an empty slot drops out to the in-world picker
// (raycast a plot to add); the panel re-opens with refreshed state once
// the player confirms or cancels in-world.
function InlineAssigner({ state, onClose, onAddPlot, onSave, }) {
    const maxPlots = Math.max(1, state.maxPlots || 10);
    const assignedIds = state.assignedPlots ?? [];
    const plotById = new Map(state.plots.map((p) => [p.id, p]));
    const assignedPlots = assignedIds
        .map((id) => plotById.get(id))
        .filter((p) => !!p);
    const filledCount = assignedPlots.length;
    const emptyCount = Math.max(0, maxPlots - filledCount);
    const removePlot = (plotId) => {
        onSave(assignedIds.filter((id) => id !== plotId));
    };
    return (_jsxs("div", { className: "h-full flex flex-col gap-2 min-h-0", children: [_jsxs("div", { className: "flex items-center gap-2 shrink-0", children: [_jsx("button", { onClick: onClose, className: "h-7 w-7 inline-flex items-center justify-center rounded ring-1 ring-white/20 text-white/70 hover:bg-white/[0.06]", title: "Back to workers", children: _jsx(ArrowLeft, { className: "h-3.5 w-3.5" }) }), _jsx(ListChecks, { className: "h-4 w-4 text-emerald-300" }), _jsx("span", { className: "text-sm font-medium text-white/90", children: "Assigned plots" }), _jsxs("span", { className: "text-[11px] text-white/55", children: ["\u00B7 ", state.firstName, " ", state.lastName] }), _jsxs("span", { className: "ml-auto text-[11px] text-white/55 tabular-nums", children: [filledCount, " / ", maxPlots] })] }), _jsxs("div", { className: "flex-1 overflow-y-auto pr-1 -mr-1 grid grid-cols-2 gap-1.5 content-start", children: [assignedPlots.map((p) => (_jsxs("div", { className: "grid grid-cols-[20px_1fr_auto] items-center gap-2 rounded-md ring-1 ring-emerald-400/40 bg-emerald-500/10 px-2.5 py-1.5", children: [_jsx(Sprout, { className: "h-3.5 w-3.5 text-emerald-300" }), _jsxs("div", { className: "min-w-0", children: [_jsxs("div", { className: "text-xs font-medium text-emerald-50 truncate", children: [p.drug, " \u00B7 stage ", p.stage] }), _jsxs("div", { className: "text-[10px] text-white/50 tabular-nums truncate", children: [p.x.toFixed(1), ", ", p.y.toFixed(1), ", ", p.z.toFixed(1)] })] }), _jsx("button", { onClick: () => removePlot(p.id), title: "Remove", className: "h-6 w-6 inline-flex items-center justify-center rounded ring-1 ring-white/15 text-white/55 hover:text-red-300 hover:bg-red-500/15", children: _jsx(Trash2, { className: "h-3 w-3" }) })] }, p.id))), Array.from({ length: emptyCount }).map((_, i) => (_jsxs("button", { onClick: i === 0 ? onAddPlot : undefined, disabled: i !== 0, title: i === 0 ? "Pick a plot in-world" : "Empty slot", className: "flex items-center justify-center gap-1.5 rounded-md ring-1 border-dashed px-2.5 py-2 text-xs transition-colors " +
                            (i === 0
                                ? "ring-emerald-400/40 text-emerald-200 hover:bg-emerald-500/15 cursor-pointer "
                                : "ring-white/10 text-white/30 cursor-default "), children: [_jsx(Plus, { className: "h-3.5 w-3.5" }), i === 0 ? "Add plot" : "Empty"] }, `empty-${i}`)))] }), _jsxs("div", { className: "text-[11px] text-white/45 italic shrink-0", children: ["Workers may tend up to ", maxPlots, " plots. Adding sends you in-world to point at a plot."] })] }));
}
