import { jsx as _jsx, jsxs as _jsxs } from "react/jsx-runtime";
// Player-facing house management panel. Shown when the player interacts
// with the world door ("Inspect Property") or the in-house management
// ox_target. Surfaces buy/rent for unowned houses; for owned/rented
// houses, shows pay-rent / cancel-lease, residents list, hire workers,
// and "Place Entity" (initiates the grid-based placement flow).
import { useEffect, useState } from "react";
import { Building, DollarSign, Users, X, Sprout, Hammer, Trash2, UserPlus, Move, ListChecks } from "lucide-react";
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
export function HouseManagePanel({ data, onClose, }) {
    const { house, interior, isOwner, drugs, pedModels } = data;
    // Admins manage every house (hire/dismiss workers, place/move/remove
    // entities) regardless of ownership. canManage gates the same UI an
    // owner sees.
    const canManage = isOwner || !!data.isAdmin;
    const zones = interior?.zones || [];
    const [selectedDrug, setSelectedDrug] = useState(drugs[0]?.id ?? "");
    const [residentDraft, setResidentDraft] = useState("");
    const [residents, setResidents] = useState(house.residents || []);
    const [employees, setEmployees] = useState(data.employees || []);
    const [entities, setEntities] = useState(data.entities || []);
    const [hireModel, setHireModel] = useState(pedModels?.[0] ?? "");
    const [hireFirst, setHireFirst] = useState("");
    const [hireLast, setHireLast] = useState("");
    useEffect(() => {
        setEmployees(data.employees || []);
    }, [data.employees]);
    useEffect(() => {
        setEntities(data.entities || []);
    }, [data.entities]);
    useNuiEvent("houseEmployeesList", (d) => {
        if (d?.employees)
            setEmployees(d.employees);
    });
    // Live entity refresh: server broadcasts plotUpdate / plotRemoved
    // when anyone places, moves, or removes a plot in this house and the
    // client refetches + sends this event so the UI doesn't go stale.
    useNuiEvent("houseEntitiesList", (d) => {
        if (d?.entities)
            setEntities(d.entities);
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
    const dismissEmployee = (empId) => {
        fetchNui("houseDismissEmployee", { houseId: house.id, empId });
    };
    const assignWorkerPlots = (empId) => {
        fetchNui("houseAssignWorkerPlots", { empId });
    };
    const tenureColor = house.tenure === "owned" ? "text-emerald-300" :
        house.tenure === "rented" ? "text-amber-300" :
            "text-white/60";
    const startPlacement = () => {
        if (!selectedDrug)
            return;
        fetchNui("houseStartPlacement", {
            houseId: house.id,
            drug: selectedDrug,
        });
    };
    const movePlot = (plotId) => {
        fetchNui("houseStartMovePlot", { houseId: house.id, plotId });
    };
    const deletePlot = (plotId) => {
        fetchNui("houseDeletePlot", { plotId });
    };
    const drugLabelFor = (id) => drugs.find((d) => d.id === id)?.label ?? id;
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
    return (_jsx("div", { className: "fixed inset-0 flex items-center justify-center pointer-events-none", children: _jsxs("div", { className: "pointer-events-auto rounded-2xl bg-black/95 ring-1 ring-white/10 shadow-2xl w-[760px] max-w-[92vw] max-h-[84vh] flex flex-col overflow-hidden", children: [_jsxs("div", { className: "grid grid-cols-[auto_1fr_auto] items-center gap-3 px-5 h-11 border-b border-white/5 bg-white/[0.02]", children: [_jsxs("div", { className: "flex items-center gap-2", children: [_jsx(Building, { className: "h-4 w-4 text-emerald-300" }), _jsx("span", { className: "text-sm text-white font-medium", children: house.label })] }), _jsxs("span", { className: "text-[11px] uppercase tracking-wider justify-self-center " + tenureColor, children: [house.tenure, house.tenure === "rented" && ` · due ${fmtDue(house.rent_due_at)}`] }), _jsx("button", { onClick: onClose, className: "h-7 w-7 inline-flex items-center justify-center rounded ring-1 ring-white/25 text-white/70 hover:text-red-200 hover:bg-red-500/15", children: _jsx(X, { className: "h-4 w-4" }) })] }), _jsxs("div", { className: "flex-1 overflow-y-auto p-5 space-y-4", children: [house.tenure === "none" && (_jsxs("div", { className: "grid grid-cols-2 gap-3", children: [house.sale_enabled && (_jsxs("button", { onClick: () => fetchNui("housePurchase", { houseId: house.id, mode: "buy" }), className: "rounded-lg bg-emerald-500/10 ring-1 ring-emerald-400/40 p-4 text-left hover:bg-emerald-500/25 hover:ring-emerald-400/70 transition-colors", children: [_jsxs("div", { className: "flex items-center gap-2 text-emerald-200", children: [_jsx(DollarSign, { className: "h-4 w-4" }), _jsx("span", { className: "text-sm font-medium", children: "Buy" })] }), _jsx("div", { className: "text-2xl font-semibold text-emerald-50 mt-1 tabular-nums", children: fmtMoney(house.sale_price) }), _jsx("div", { className: "text-[11px] text-white/50", children: "One-time payment, owned forever." })] })), house.rent_enabled && (_jsxs("button", { onClick: () => fetchNui("housePurchase", { houseId: house.id, mode: "rent" }), className: "rounded-lg bg-amber-500/10 ring-1 ring-amber-400/40 p-4 text-left hover:bg-amber-500/25 hover:ring-amber-400/70 transition-colors", children: [_jsxs("div", { className: "flex items-center gap-2 text-amber-200", children: [_jsx(DollarSign, { className: "h-4 w-4" }), _jsx("span", { className: "text-sm font-medium", children: "Rent" })] }), _jsx("div", { className: "text-2xl font-semibold text-amber-50 mt-1 tabular-nums", children: fmtMoney(house.rent_price) }), _jsxs("div", { className: "text-[11px] text-white/50", children: ["per ", Math.round(house.rent_cycle_ms / (24 * 60 * 60 * 1000)), "d cycle"] })] })), !house.sale_enabled && !house.rent_enabled && (_jsx("div", { className: "col-span-2 text-sm italic text-white/50", children: "This property isn't currently for sale or rent." }))] })), house.tenure !== "none" && canManage && (_jsxs("div", { className: "grid grid-cols-2 gap-3", children: [house.tenure === "rented" && (_jsxs("button", { onClick: () => fetchNui("housePayRent", { houseId: house.id }), className: "rounded-lg bg-amber-500/10 ring-1 ring-amber-400/40 p-3 text-left hover:bg-amber-500/25", children: [_jsx("div", { className: "text-sm text-amber-100 font-medium", children: "Pay rent" }), _jsx("div", { className: "text-lg font-semibold text-amber-50 tabular-nums", children: fmtMoney(house.rent_price) })] })), _jsxs("button", { onClick: () => fetchNui("houseCancelLease", { houseId: house.id }), className: "rounded-lg bg-red-500/10 ring-1 ring-red-400/40 p-3 text-left hover:bg-red-500/25", children: [_jsx("div", { className: "text-sm text-red-200 font-medium", children: "Cancel lease" }), _jsx("div", { className: "text-[11px] text-white/55", children: "Lapses immediately. Entities stay until next purchase." })] })] })), house.tenure !== "none" && canManage && (_jsxs("div", { className: "rounded-lg bg-white/[0.03] ring-1 ring-white/10 p-3 space-y-2", children: [_jsxs("div", { className: "flex items-center gap-2 text-white/85", children: [_jsx(Users, { className: "h-4 w-4" }), _jsx("span", { className: "text-sm font-medium", children: "Residents" })] }), _jsxs("div", { className: "flex gap-2", children: [_jsx("input", { value: residentDraft, onChange: (e) => setResidentDraft(e.target.value), placeholder: "citizenid", className: "flex-1 bg-white/[0.06] ring-1 ring-white/20 rounded-md px-3 py-2 text-sm text-white outline-none focus:ring-emerald-400/60" }), _jsx("button", { onClick: addResident, className: "px-3 py-2 rounded-md ring-1 ring-emerald-400/50 bg-emerald-500/15 text-emerald-100 hover:bg-emerald-500/30 text-xs", children: "Add" })] }), _jsxs("div", { className: "flex flex-wrap gap-1.5", children: [residents.length === 0 && (_jsx("span", { className: "text-[11px] italic text-white/40", children: "Just the owner \u2014 add citizenids to share access." })), residents.map((r) => (_jsxs("span", { className: "inline-flex items-center gap-1.5 rounded-md bg-white/[0.06] ring-1 ring-white/15 px-2 py-1 text-[11px] text-white/80", children: [r, _jsx("button", { onClick: () => removeResident(r), className: "text-white/45 hover:text-red-300", children: _jsx(Trash2, { className: "h-3 w-3" }) })] }, r)))] })] })), house.tenure !== "none" && canManage && (_jsxs("div", { className: "rounded-lg bg-white/[0.03] ring-1 ring-white/10 p-3 space-y-2", children: [_jsxs("div", { className: "flex items-center gap-2 text-white/85", children: [_jsx(UserPlus, { className: "h-4 w-4" }), _jsx("span", { className: "text-sm font-medium", children: "Workers" }), _jsxs("span", { className: "text-[11px] text-white/40", children: ["\u00B7 ", employees.length, " hired"] })] }), _jsxs("div", { className: "grid grid-cols-[1fr_auto_auto_auto] gap-2", children: [_jsx("select", { value: hireModel, onChange: (e) => setHireModel(e.target.value), className: "bg-white/[0.06] ring-1 ring-white/20 rounded-md px-2 py-1.5 text-sm text-white outline-none", children: (pedModels || []).map((m) => (_jsx("option", { value: m, className: "bg-neutral-900", children: m }, m))) }), _jsx("input", { value: hireFirst, onChange: (e) => setHireFirst(e.target.value), placeholder: "First", className: "w-24 bg-white/[0.06] ring-1 ring-white/20 rounded-md px-2 py-1.5 text-sm text-white outline-none focus:ring-emerald-400/60" }), _jsx("input", { value: hireLast, onChange: (e) => setHireLast(e.target.value), placeholder: "Last", className: "w-24 bg-white/[0.06] ring-1 ring-white/20 rounded-md px-2 py-1.5 text-sm text-white outline-none focus:ring-emerald-400/60" }), _jsx("button", { onClick: hireEmployee, className: "px-3 py-1.5 rounded-md ring-1 ring-emerald-400/50 bg-emerald-500/15 text-emerald-100 hover:bg-emerald-500/30 text-xs", children: "Hire" })] }), _jsxs("div", { className: "space-y-1", children: [employees.length === 0 && (_jsx("span", { className: "text-[11px] italic text-white/40", children: "Hire a worker to tend every plot in this house automatically." })), employees.map((e) => (_jsxs("div", { className: "flex items-center gap-2 rounded-md bg-white/[0.04] ring-1 ring-white/10 px-2.5 py-1.5", children: [_jsxs("span", { className: "text-sm text-white/90", children: [e.firstName, " ", e.lastName] }), _jsx("span", { className: "text-[10px] text-white/40 truncate", children: e.model }), _jsx("button", { onClick: () => assignWorkerPlots(e.id), title: "Assign plots", className: "ml-auto h-6 w-6 inline-flex items-center justify-center rounded ring-1 ring-white/15 text-white/70 hover:text-emerald-200 hover:bg-emerald-500/15", children: _jsx(ListChecks, { className: "h-3.5 w-3.5" }) }), _jsx("button", { onClick: () => dismissEmployee(e.id), title: "Dismiss", className: "h-6 w-6 inline-flex items-center justify-center rounded ring-1 ring-white/15 text-white/55 hover:text-red-300 hover:bg-red-500/15", children: _jsx(Trash2, { className: "h-3.5 w-3.5" }) })] }, e.id)))] })] })), house.tenure !== "none" && (data.canAccess || canManage) && (_jsxs("div", { className: "rounded-lg bg-white/[0.03] ring-1 ring-white/10 p-3 space-y-2", children: [_jsxs("div", { className: "flex items-center gap-2 text-white/85", children: [_jsx(Sprout, { className: "h-4 w-4" }), _jsx("span", { className: "text-sm font-medium", children: "Placed entities" }), _jsxs("span", { className: "text-[11px] text-white/40", children: ["\u00B7 ", entities.length] })] }), _jsxs("div", { className: "space-y-1", children: [entities.length === 0 && (_jsx("span", { className: "text-[11px] italic text-white/40", children: "Nothing placed in this house yet. Use \"Place an entity\" below to add one." })), entities.map((p) => (_jsxs("div", { className: "flex items-center gap-2 rounded-md bg-white/[0.04] ring-1 ring-white/10 px-2.5 py-1.5", children: [_jsx("span", { className: "text-sm text-white/90", children: drugLabelFor(p.drug) }), _jsxs("span", { className: "text-[10px] text-white/40 truncate", children: [p.zone_id, " \u00B7 ", p.cell_x, ",", p.cell_y] }), _jsx("button", { onClick: () => movePlot(p.id), title: "Move", className: "ml-auto h-6 w-6 inline-flex items-center justify-center rounded ring-1 ring-white/15 text-white/70 hover:text-emerald-200 hover:bg-emerald-500/15", children: _jsx(Move, { className: "h-3.5 w-3.5" }) }), _jsx("button", { onClick: () => deletePlot(p.id), title: "Remove", className: "h-6 w-6 inline-flex items-center justify-center rounded ring-1 ring-white/15 text-white/55 hover:text-red-300 hover:bg-red-500/15", children: _jsx(Trash2, { className: "h-3.5 w-3.5" }) })] }, p.id)))] })] })), house.tenure !== "none" && (data.canAccess) && zones.length > 0 && (_jsxs("div", { className: "rounded-lg bg-white/[0.03] ring-1 ring-white/10 p-3 space-y-2", children: [_jsxs("div", { className: "flex items-center gap-2 text-white/85", children: [_jsx(Sprout, { className: "h-4 w-4" }), _jsx("span", { className: "text-sm font-medium", children: "Place an entity" })] }), _jsx("select", { value: selectedDrug, onChange: (e) => setSelectedDrug(e.target.value), className: "w-full bg-white/[0.06] ring-1 ring-white/20 rounded-md px-2.5 py-1.5 text-sm text-white outline-none", children: drugs.map((d) => (_jsx("option", { value: d.id, className: "bg-neutral-900", children: d.label }, d.id))) }), _jsxs("button", { onClick: startPlacement, className: "w-full inline-flex items-center justify-center gap-2 px-3 py-2 rounded-md ring-1 ring-emerald-400/50 bg-emerald-500/15 text-emerald-100 hover:bg-emerald-500/30 text-sm", children: [_jsx(Hammer, { className: "h-4 w-4" }), " Start placement"] }), _jsx("div", { className: "text-[11px] italic text-white/40", children: "Aim where you want it. Snaps to grid when over a zone \u00B7 scroll to rotate \u00B7 E to confirm \u00B7 ESC to cancel." })] }))] })] }) }));
}
