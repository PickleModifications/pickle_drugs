// Player-facing house management panel. Shown when the player interacts
// with the world door ("Inspect Property") or the in-house management
// ox_target. Surfaces buy/rent for unowned houses; for owned/rented
// houses, shows pay-rent / cancel-lease, residents list, hire workers,
// and "Place Entity" (initiates the grid-based placement flow).

import { useEffect, useState } from "react";
import { Building, DollarSign, Users, X, Sprout, Hammer, Trash2, UserPlus, Move, ListChecks } from "lucide-react";

import { fetchNui, useNuiEvent } from "@/lib/nui";
import type { House, Interior, Zone } from "./HousingPanel";

type Plot = {
    id: string;
    drug: string;
    zone_id: string;
    cell_x: number; cell_y: number; cell_w: number; cell_h: number;
};

type DrugOption = { id: string; label: string };

type HouseEmployee = {
    id: string;
    model: string;
    firstName: string;
    lastName: string;
    houseId: string;
};

export type HouseManageData = {
    house: House;
    interior: Interior;
    cid: string | null;
    canAccess: boolean;
    isOwner: boolean;
    isAdmin?: boolean;
    entities: Plot[];
    zonePlots: Record<string, Plot[]>;
    drugs: DrugOption[];
    employees: HouseEmployee[];
    pedModels: string[];
};

function fmtMoney(n: number) {
    return "$" + n.toLocaleString();
}

function fmtDue(at: number): string {
    if (!at) return "—";
    const ms = at - Date.now();
    if (ms <= 0) return "OVERDUE";
    const s = Math.floor(ms / 1000);
    const d = Math.floor(s / 86400);
    if (d > 0) return `${d}d`;
    const h = Math.floor(s / 3600);
    if (h > 0) return `${h}h`;
    return `${Math.max(1, Math.floor(s / 60))}m`;
}

export function HouseManagePanel({
    data, onClose,
}: {
    data: HouseManageData;
    onClose: () => void;
}) {
    const { house, interior, isOwner, drugs, pedModels } = data;
    // Admins manage every house (hire/dismiss workers, place/move/remove
    // entities) regardless of ownership. canManage gates the same UI an
    // owner sees.
    const canManage = isOwner || !!data.isAdmin;
    const zones: Zone[] = interior?.zones || [];
    const [selectedDrug, setSelectedDrug] = useState<string>(drugs[0]?.id ?? "");
    const [residentDraft, setResidentDraft] = useState("");
    const [residents, setResidents] = useState<string[]>(house.residents || []);
    const [employees, setEmployees] = useState<HouseEmployee[]>(data.employees || []);
    const [entities, setEntities] = useState<Plot[]>(data.entities || []);
    const [hireModel, setHireModel] = useState<string>(pedModels?.[0] ?? "");
    const [hireFirst, setHireFirst] = useState("");
    const [hireLast, setHireLast] = useState("");

    useEffect(() => {
        setEmployees(data.employees || []);
    }, [data.employees]);

    useEffect(() => {
        setEntities(data.entities || []);
    }, [data.entities]);

    useNuiEvent<{ employees: HouseEmployee[] }>("houseEmployeesList", (d) => {
        if (d?.employees) setEmployees(d.employees);
    });

    // Live entity refresh: server broadcasts plotUpdate / plotRemoved
    // when anyone places, moves, or removes a plot in this house and the
    // client refetches + sends this event so the UI doesn't go stale.
    useNuiEvent<{ entities: Plot[] }>("houseEntitiesList", (d) => {
        if (d?.entities) setEntities(d.entities);
    });

    const hireEmployee = () => {
        if (!hireModel) return;
        fetchNui("houseHireEmployee", {
            houseId: house.id,
            model: hireModel,
            firstName: hireFirst.trim(),
            lastName: hireLast.trim(),
        });
        setHireFirst("");
        setHireLast("");
    };

    const dismissEmployee = (empId: string) => {
        fetchNui("houseDismissEmployee", { houseId: house.id, empId });
    };

    const assignWorkerPlots = (empId: string) => {
        fetchNui("houseAssignWorkerPlots", { empId });
    };

    const tenureColor =
        house.tenure === "owned" ? "text-emerald-300" :
        house.tenure === "rented" ? "text-amber-300" :
        "text-white/60";

    const startPlacement = () => {
        if (!selectedDrug) return;
        fetchNui("houseStartPlacement", {
            houseId: house.id,
            drug: selectedDrug,
        });
    };

    const movePlot = (plotId: string) => {
        fetchNui("houseStartMovePlot", { houseId: house.id, plotId });
    };

    const deletePlot = (plotId: string) => {
        fetchNui("houseDeletePlot", { plotId });
    };

    const drugLabelFor = (id: string) =>
        drugs.find((d) => d.id === id)?.label ?? id;

    const addResident = () => {
        const v = residentDraft.trim();
        if (!v || residents.includes(v)) return;
        const next = [...residents, v];
        setResidents(next);
        setResidentDraft("");
        fetchNui("houseSetResidents", { houseId: house.id, residents: next });
    };

    const removeResident = (cid: string) => {
        const next = residents.filter((r) => r !== cid);
        setResidents(next);
        fetchNui("houseSetResidents", { houseId: house.id, residents: next });
    };

    return (
        <div className="fixed inset-0 flex items-center justify-center pointer-events-none">
            <div className="pointer-events-auto rounded-2xl bg-black/95 ring-1 ring-white/10 shadow-2xl w-[760px] max-w-[92vw] max-h-[84vh] flex flex-col overflow-hidden">
                <div className="grid grid-cols-[auto_1fr_auto] items-center gap-3 px-5 h-11 border-b border-white/5 bg-white/[0.02]">
                    <div className="flex items-center gap-2">
                        <Building className="h-4 w-4 text-emerald-300" />
                        <span className="text-sm text-white font-medium">{house.label}</span>
                    </div>
                    <span className={"text-[11px] uppercase tracking-wider justify-self-center " + tenureColor}>
                        {house.tenure}
                        {house.tenure === "rented" && ` · due ${fmtDue(house.rent_due_at)}`}
                    </span>
                    <button onClick={onClose}
                        className="h-7 w-7 inline-flex items-center justify-center rounded ring-1 ring-white/25 text-white/70 hover:text-red-200 hover:bg-red-500/15">
                        <X className="h-4 w-4" />
                    </button>
                </div>

                <div className="flex-1 overflow-y-auto p-5 space-y-4">
                    {/* Unowned: show purchase / rent controls */}
                    {house.tenure === "none" && (
                        <div className="grid grid-cols-2 gap-3">
                            {house.sale_enabled && (
                                <button
                                    onClick={() => fetchNui("housePurchase", { houseId: house.id, mode: "buy" })}
                                    className="rounded-lg bg-emerald-500/10 ring-1 ring-emerald-400/40 p-4 text-left hover:bg-emerald-500/25 hover:ring-emerald-400/70 transition-colors">
                                    <div className="flex items-center gap-2 text-emerald-200">
                                        <DollarSign className="h-4 w-4" />
                                        <span className="text-sm font-medium">Buy</span>
                                    </div>
                                    <div className="text-2xl font-semibold text-emerald-50 mt-1 tabular-nums">
                                        {fmtMoney(house.sale_price)}
                                    </div>
                                    <div className="text-[11px] text-white/50">One-time payment, owned forever.</div>
                                </button>
                            )}
                            {house.rent_enabled && (
                                <button
                                    onClick={() => fetchNui("housePurchase", { houseId: house.id, mode: "rent" })}
                                    className="rounded-lg bg-amber-500/10 ring-1 ring-amber-400/40 p-4 text-left hover:bg-amber-500/25 hover:ring-amber-400/70 transition-colors">
                                    <div className="flex items-center gap-2 text-amber-200">
                                        <DollarSign className="h-4 w-4" />
                                        <span className="text-sm font-medium">Rent</span>
                                    </div>
                                    <div className="text-2xl font-semibold text-amber-50 mt-1 tabular-nums">
                                        {fmtMoney(house.rent_price)}
                                    </div>
                                    <div className="text-[11px] text-white/50">
                                        per {Math.round(house.rent_cycle_ms / (24 * 60 * 60 * 1000))}d cycle
                                    </div>
                                </button>
                            )}
                            {!house.sale_enabled && !house.rent_enabled && (
                                <div className="col-span-2 text-sm italic text-white/50">
                                    This property isn't currently for sale or rent.
                                </div>
                            )}
                        </div>
                    )}

                    {/* Owned: lease controls */}
                    {house.tenure !== "none" && canManage && (
                        <div className="grid grid-cols-2 gap-3">
                            {house.tenure === "rented" && (
                                <button
                                    onClick={() => fetchNui("housePayRent", { houseId: house.id })}
                                    className="rounded-lg bg-amber-500/10 ring-1 ring-amber-400/40 p-3 text-left hover:bg-amber-500/25">
                                    <div className="text-sm text-amber-100 font-medium">Pay rent</div>
                                    <div className="text-lg font-semibold text-amber-50 tabular-nums">
                                        {fmtMoney(house.rent_price)}
                                    </div>
                                </button>
                            )}
                            <button
                                onClick={() => fetchNui("houseCancelLease", { houseId: house.id })}
                                className="rounded-lg bg-red-500/10 ring-1 ring-red-400/40 p-3 text-left hover:bg-red-500/25">
                                <div className="text-sm text-red-200 font-medium">Cancel lease</div>
                                <div className="text-[11px] text-white/55">
                                    Lapses immediately. Entities stay until next purchase.
                                </div>
                            </button>
                        </div>
                    )}

                    {/* Residents */}
                    {house.tenure !== "none" && canManage && (
                        <div className="rounded-lg bg-white/[0.03] ring-1 ring-white/10 p-3 space-y-2">
                            <div className="flex items-center gap-2 text-white/85">
                                <Users className="h-4 w-4" />
                                <span className="text-sm font-medium">Residents</span>
                            </div>
                            <div className="flex gap-2">
                                <input value={residentDraft}
                                    onChange={(e) => setResidentDraft(e.target.value)}
                                    placeholder="citizenid"
                                    className="flex-1 bg-white/[0.06] ring-1 ring-white/20 rounded-md px-3 py-2 text-sm text-white outline-none focus:ring-emerald-400/60" />
                                <button onClick={addResident}
                                    className="px-3 py-2 rounded-md ring-1 ring-emerald-400/50 bg-emerald-500/15 text-emerald-100 hover:bg-emerald-500/30 text-xs">
                                    Add
                                </button>
                            </div>
                            <div className="flex flex-wrap gap-1.5">
                                {residents.length === 0 && (
                                    <span className="text-[11px] italic text-white/40">Just the owner — add citizenids to share access.</span>
                                )}
                                {residents.map((r) => (
                                    <span key={r} className="inline-flex items-center gap-1.5 rounded-md bg-white/[0.06] ring-1 ring-white/15 px-2 py-1 text-[11px] text-white/80">
                                        {r}
                                        <button onClick={() => removeResident(r)} className="text-white/45 hover:text-red-300">
                                            <Trash2 className="h-3 w-3" />
                                        </button>
                                    </span>
                                ))}
                            </div>
                        </div>
                    )}

                    {/* Employees */}
                    {house.tenure !== "none" && canManage && (
                        <div className="rounded-lg bg-white/[0.03] ring-1 ring-white/10 p-3 space-y-2">
                            <div className="flex items-center gap-2 text-white/85">
                                <UserPlus className="h-4 w-4" />
                                <span className="text-sm font-medium">Workers</span>
                                <span className="text-[11px] text-white/40">
                                    · {employees.length} hired
                                </span>
                            </div>
                            <div className="grid grid-cols-[1fr_auto_auto_auto] gap-2">
                                <select value={hireModel}
                                    onChange={(e) => setHireModel(e.target.value)}
                                    className="bg-white/[0.06] ring-1 ring-white/20 rounded-md px-2 py-1.5 text-sm text-white outline-none">
                                    {(pedModels || []).map((m) => (
                                        <option key={m} value={m} className="bg-neutral-900">{m}</option>
                                    ))}
                                </select>
                                <input value={hireFirst}
                                    onChange={(e) => setHireFirst(e.target.value)}
                                    placeholder="First"
                                    className="w-24 bg-white/[0.06] ring-1 ring-white/20 rounded-md px-2 py-1.5 text-sm text-white outline-none focus:ring-emerald-400/60" />
                                <input value={hireLast}
                                    onChange={(e) => setHireLast(e.target.value)}
                                    placeholder="Last"
                                    className="w-24 bg-white/[0.06] ring-1 ring-white/20 rounded-md px-2 py-1.5 text-sm text-white outline-none focus:ring-emerald-400/60" />
                                <button onClick={hireEmployee}
                                    className="px-3 py-1.5 rounded-md ring-1 ring-emerald-400/50 bg-emerald-500/15 text-emerald-100 hover:bg-emerald-500/30 text-xs">
                                    Hire
                                </button>
                            </div>
                            <div className="space-y-1">
                                {employees.length === 0 && (
                                    <span className="text-[11px] italic text-white/40">
                                        Hire a worker to tend every plot in this house automatically.
                                    </span>
                                )}
                                {employees.map((e) => (
                                    <div key={e.id} className="flex items-center gap-2 rounded-md bg-white/[0.04] ring-1 ring-white/10 px-2.5 py-1.5">
                                        <span className="text-sm text-white/90">{e.firstName} {e.lastName}</span>
                                        <span className="text-[10px] text-white/40 truncate">{e.model}</span>
                                        <button onClick={() => assignWorkerPlots(e.id)}
                                            title="Assign plots"
                                            className="ml-auto h-6 w-6 inline-flex items-center justify-center rounded ring-1 ring-white/15 text-white/70 hover:text-emerald-200 hover:bg-emerald-500/15">
                                            <ListChecks className="h-3.5 w-3.5" />
                                        </button>
                                        <button onClick={() => dismissEmployee(e.id)}
                                            title="Dismiss"
                                            className="h-6 w-6 inline-flex items-center justify-center rounded ring-1 ring-white/15 text-white/55 hover:text-red-300 hover:bg-red-500/15">
                                            <Trash2 className="h-3.5 w-3.5" />
                                        </button>
                                    </div>
                                ))}
                            </div>
                        </div>
                    )}

                    {/* Existing entities — move/remove */}
                    {house.tenure !== "none" && (data.canAccess || canManage) && (
                        <div className="rounded-lg bg-white/[0.03] ring-1 ring-white/10 p-3 space-y-2">
                            <div className="flex items-center gap-2 text-white/85">
                                <Sprout className="h-4 w-4" />
                                <span className="text-sm font-medium">Placed entities</span>
                                <span className="text-[11px] text-white/40">
                                    · {entities.length}
                                </span>
                            </div>
                            <div className="space-y-1">
                                {entities.length === 0 && (
                                    <span className="text-[11px] italic text-white/40">
                                        Nothing placed in this house yet. Use "Place an entity" below to add one.
                                    </span>
                                )}
                                {entities.map((p) => (
                                    <div key={p.id} className="flex items-center gap-2 rounded-md bg-white/[0.04] ring-1 ring-white/10 px-2.5 py-1.5">
                                        <span className="text-sm text-white/90">{drugLabelFor(p.drug)}</span>
                                        <span className="text-[10px] text-white/40 truncate">
                                            {p.zone_id} · {p.cell_x},{p.cell_y}
                                        </span>
                                        <button onClick={() => movePlot(p.id)}
                                            title="Move"
                                            className="ml-auto h-6 w-6 inline-flex items-center justify-center rounded ring-1 ring-white/15 text-white/70 hover:text-emerald-200 hover:bg-emerald-500/15">
                                            <Move className="h-3.5 w-3.5" />
                                        </button>
                                        <button onClick={() => deletePlot(p.id)}
                                            title="Remove"
                                            className="h-6 w-6 inline-flex items-center justify-center rounded ring-1 ring-white/15 text-white/55 hover:text-red-300 hover:bg-red-500/15">
                                            <Trash2 className="h-3.5 w-3.5" />
                                        </button>
                                    </div>
                                ))}
                            </div>
                        </div>
                    )}

                    {/* Placement */}
                    {house.tenure !== "none" && (data.canAccess) && zones.length > 0 && (
                        <div className="rounded-lg bg-white/[0.03] ring-1 ring-white/10 p-3 space-y-2">
                            <div className="flex items-center gap-2 text-white/85">
                                <Sprout className="h-4 w-4" />
                                <span className="text-sm font-medium">Place an entity</span>
                            </div>
                            <select value={selectedDrug} onChange={(e) => setSelectedDrug(e.target.value)}
                                className="w-full bg-white/[0.06] ring-1 ring-white/20 rounded-md px-2.5 py-1.5 text-sm text-white outline-none">
                                {drugs.map((d) => (
                                    <option key={d.id} value={d.id} className="bg-neutral-900">{d.label}</option>
                                ))}
                            </select>
                            <button onClick={startPlacement}
                                className="w-full inline-flex items-center justify-center gap-2 px-3 py-2 rounded-md ring-1 ring-emerald-400/50 bg-emerald-500/15 text-emerald-100 hover:bg-emerald-500/30 text-sm">
                                <Hammer className="h-4 w-4" /> Start placement
                            </button>
                            <div className="text-[11px] italic text-white/40">
                                Aim where you want it. Snaps to grid when over a zone · scroll to rotate · E to confirm · ESC to cancel.
                            </div>
                        </div>
                    )}
                </div>
            </div>
        </div>
    );
}
