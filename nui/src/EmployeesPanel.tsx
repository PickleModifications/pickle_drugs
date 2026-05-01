import { useEffect, useState } from "react";
import { Move, Plus, Trash2, User, X } from "lucide-react";

import { fetchNui } from "@/lib/nui";

export type EmployeeRow = {
    id: string;
    model: string;
    firstName: string;
    lastName: string;
    home: { x: number; y: number; z: number; w: number };
    assignedPlots: string[];
};

export function EmployeesPanel({
    models,
    employees,
    hidden,
    onClose,
}: {
    models: string[];
    employees: EmployeeRow[];
    hidden: boolean;
    onClose: () => void;
}) {
    const [selectedModel, setSelectedModel] = useState(models[0] ?? "");
    const [firstName, setFirstName] = useState("");
    const [lastName, setLastName] = useState("");
    const [confirmDelete, setConfirmDelete] = useState<string | null>(null);

    useEffect(() => {
        if (!selectedModel && models.length > 0) setSelectedModel(models[0]);
    }, [models, selectedModel]);

    if (hidden) return null;

    const onPlace = () => {
        if (!selectedModel) return;
        fetchNui("employeesPlace", {
            model: selectedModel,
            firstName: firstName.trim(),
            lastName: lastName.trim(),
        });
        // Clear locals; the server-generated employee will appear in the list.
        setFirstName("");
        setLastName("");
    };
    const onMove = (empId: string) => fetchNui("employeesMove", { empId });
    const onDelete = (empId: string) => {
        fetchNui("employeesDelete", { empId });
        setConfirmDelete(null);
    };

    return (
        <div className="fixed inset-0 flex items-center justify-center pointer-events-none">
            <div className="pointer-events-auto rounded-2xl bg-black/95 ring-1 ring-white/10 shadow-2xl overflow-hidden w-[860px] max-w-[92vw] max-h-[80vh] flex flex-col">
                <div className="grid grid-cols-[auto_1fr_auto] items-center gap-4 px-5 h-10 border-b border-white/5 bg-white/[0.02]">
                    <span className="text-[10px] uppercase tracking-[0.18em] text-white/45 whitespace-nowrap">
                        Employee Roster
                    </span>
                    <span className="text-[11px] text-white/50 italic justify-self-center">
                        Hire, relocate & dismiss NPC workers
                    </span>
                    <button
                        onClick={onClose}
                        className="h-7 w-7 inline-flex items-center justify-center rounded ring-1 ring-white/25 text-white/70 hover:text-red-200 hover:bg-red-500/15 hover:ring-red-400/50 transition-colors"
                        title="Close"
                    >
                        <X className="h-4 w-4" />
                    </button>
                </div>

                <div className="flex divide-x divide-white/5 min-h-0 flex-1">
                    <div className="w-80 p-4 flex flex-col gap-3">
                        <div className="flex items-center gap-2 text-white/85">
                            <Plus className="h-4 w-4" />
                            <span className="text-sm font-medium">Hire employee</span>
                        </div>

                        <label className="text-[11px] uppercase tracking-wider text-white/45">
                            First name
                        </label>
                        <input
                            value={firstName}
                            onChange={(e) => setFirstName(e.target.value)}
                            maxLength={32}
                            placeholder="(random if blank)"
                            className="bg-white/[0.06] ring-1 ring-white/20 rounded-md px-3 py-2 text-sm text-white outline-none focus:ring-emerald-400/60"
                        />
                        <label className="text-[11px] uppercase tracking-wider text-white/45">
                            Last name
                        </label>
                        <input
                            value={lastName}
                            onChange={(e) => setLastName(e.target.value)}
                            maxLength={32}
                            placeholder="(random if blank)"
                            className="bg-white/[0.06] ring-1 ring-white/20 rounded-md px-3 py-2 text-sm text-white outline-none focus:ring-emerald-400/60"
                        />

                        <label className="text-[11px] uppercase tracking-wider text-white/45">
                            Model
                        </label>
                        <select
                            value={selectedModel}
                            onChange={(e) => setSelectedModel(e.target.value)}
                            className="bg-white/[0.06] ring-1 ring-white/20 rounded-md px-3 py-2 text-sm text-white outline-none focus:ring-emerald-400/60"
                        >
                            {models.map((m) => (
                                <option key={m} value={m} className="bg-neutral-900">
                                    {m}
                                </option>
                            ))}
                        </select>

                        <button
                            onClick={onPlace}
                            disabled={!selectedModel}
                            className="mt-auto flex items-center justify-center gap-2 rounded-lg px-3 py-2 ring-1 transition-all bg-emerald-500/15 ring-emerald-400/50 text-emerald-100 hover:bg-emerald-500/30 hover:ring-emerald-400/80 hover:text-emerald-50 hover:shadow-[0_0_18px_-6px_rgba(52,211,153,0.7)] disabled:opacity-40 disabled:cursor-not-allowed"
                        >
                            <User className="h-4 w-4" />
                            <span className="text-sm font-medium">Place employee</span>
                        </button>
                    </div>

                    <div className="flex-1 p-4 flex flex-col gap-2 min-h-0">
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
                                    No employees — hire your first one.
                                </div>
                            )}
                            {employees.map((e) => (
                                <div
                                    key={e.id}
                                    className="grid grid-cols-[1fr_auto_auto] items-center gap-3 rounded-lg bg-white/[0.04] ring-1 ring-white/10 px-3 py-2"
                                >
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
                                            {e.id}
                                            {" · "}
                                            {e.model}
                                            {" · "}
                                            {e.home.x.toFixed(1)}, {e.home.y.toFixed(1)},{" "}
                                            {e.home.z.toFixed(1)}
                                        </div>
                                    </div>
                                    <button
                                        onClick={() => onMove(e.id)}
                                        title="Move home"
                                        className="h-8 w-8 inline-flex items-center justify-center rounded-md ring-1 ring-white/20 text-white/70 hover:text-amber-200 hover:bg-amber-500/15 hover:ring-amber-400/50 transition-colors"
                                    >
                                        <Move className="h-4 w-4" />
                                    </button>
                                    {confirmDelete === e.id ? (
                                        <button
                                            onClick={() => onDelete(e.id)}
                                            title="Confirm dismiss"
                                            className="h-8 px-3 inline-flex items-center justify-center rounded-md ring-1 bg-red-500/25 ring-red-400/60 text-red-100 hover:bg-red-500/40 transition-colors text-[11px] font-medium"
                                        >
                                            Confirm
                                        </button>
                                    ) : (
                                        <button
                                            onClick={() => setConfirmDelete(e.id)}
                                            title="Dismiss employee"
                                            className="h-8 w-8 inline-flex items-center justify-center rounded-md ring-1 ring-white/20 text-white/70 hover:text-red-200 hover:bg-red-500/15 hover:ring-red-400/50 transition-colors"
                                        >
                                            <Trash2 className="h-4 w-4" />
                                        </button>
                                    )}
                                </div>
                            ))}
                        </div>
                    </div>
                </div>
            </div>
        </div>
    );
}
