import { ListChecks, User, X } from "lucide-react";

import { fetchNui } from "@/lib/nui";

export type EmployeeRow = {
    id: string;
    model: string;
    firstName: string;
    lastName: string;
    home: { x: number; y: number; z: number; w: number };
    assignedPlots: string[];
    houseId?: string | null;
    // Worker-held items keyed by destination locker id (or "_unrouted").
    carry?: Record<string, Record<string, number>>;
    carryTotal?: number;
    carryCap?: number;
};

// Read-only admin roster. Workers are hired / dismissed through the
// per-house management panel; this view exists so an admin can quickly
// re-assign which plots a worker tends across houses without entering
// each house's panel.
export function EmployeesPanel({
    employees,
    hidden,
    onClose,
}: {
    employees: EmployeeRow[];
    hidden: boolean;
    onClose: () => void;
}) {
    if (hidden) return null;

    const onAssign = (empId: string) =>
        fetchNui("employeesAssign", { empId });

    return (
        <div className="fixed inset-0 flex items-center justify-center pointer-events-none">
            <div className="pointer-events-auto rounded-2xl bg-black/95 ring-1 ring-white/10 shadow-2xl overflow-hidden w-[640px] max-w-[92vw] max-h-[80vh] flex flex-col">
                <div className="grid grid-cols-[auto_1fr_auto] items-center gap-4 px-5 h-10 border-b border-white/5 bg-white/[0.02]">
                    <span className="text-[10px] uppercase tracking-[0.18em] text-white/45 whitespace-nowrap">
                        Employee Roster
                    </span>
                    <span className="text-[11px] text-white/50 italic justify-self-center">
                        Assign which plots each worker tends
                    </span>
                    <button
                        onClick={onClose}
                        className="h-7 w-7 inline-flex items-center justify-center rounded ring-1 ring-white/25 text-white/70 hover:text-red-200 hover:bg-red-500/15 hover:ring-red-400/50 transition-colors"
                        title="Close"
                    >
                        <X className="h-4 w-4" />
                    </button>
                </div>

                <div className="p-4 flex flex-col gap-2 min-h-0 flex-1">
                    <div className="flex items-center justify-between">
                        <span className="text-sm text-white/85 font-medium">
                            Active employees
                        </span>
                        <span className="text-[11px] text-white/45 tabular-nums">
                            {employees.length} total
                        </span>
                    </div>

                    <div className="flex-1 overflow-y-auto pr-1 -mr-1 flex flex-col gap-1.5">
                        {employees.length === 0 && (
                            <div className="flex-1 flex items-center justify-center text-white/40 text-sm italic">
                                No employees — hire one from a house's management panel.
                            </div>
                        )}
                        {employees.map((e) => (
                            <div
                                key={e.id}
                                className="grid grid-cols-[auto_1fr_auto] items-center gap-3 rounded-lg bg-white/[0.04] ring-1 ring-white/10 px-3 py-2"
                            >
                                <div className="h-8 w-8 inline-flex items-center justify-center rounded-md ring-1 ring-white/15 bg-white/[0.04]">
                                    <User className="h-4 w-4 text-white/70" />
                                </div>
                                <div className="min-w-0">
                                    <div className="flex items-center gap-2">
                                        <span className="text-sm text-white truncate font-medium">
                                            {e.firstName} {e.lastName}
                                        </span>
                                        <span className="text-[10px] text-white/45 tabular-nums">
                                            {e.assignedPlots.length} plot
                                            {e.assignedPlots.length === 1 ? "" : "s"}
                                        </span>
                                    </div>
                                    <div className="text-[11px] text-white/50 tabular-nums truncate">
                                        {e.houseId ?? "no house"}
                                        {" · "}
                                        {e.model}
                                    </div>
                                </div>
                                <button
                                    onClick={() => onAssign(e.id)}
                                    title="Assign plots"
                                    className="h-8 px-3 inline-flex items-center justify-center gap-1.5 rounded-md ring-1 ring-emerald-400/40 bg-emerald-500/15 text-emerald-100 hover:bg-emerald-500/30 transition-colors text-[11px] font-medium"
                                >
                                    <ListChecks className="h-3.5 w-3.5" />
                                    Assign
                                </button>
                            </div>
                        ))}
                    </div>
                </div>
            </div>
        </div>
    );
}
