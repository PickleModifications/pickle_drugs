import { User, X } from "lucide-react";

import type { EmployeeRow } from "./EmployeesPanel";

export function EmployeeInfoPanel({
    employee,
    onClose,
}: {
    employee: EmployeeRow;
    onClose: () => void;
}) {
    return (
        <div className="fixed inset-0 flex items-center justify-center pointer-events-none">
            <div className="pointer-events-auto rounded-2xl bg-black/95 ring-1 ring-white/10 shadow-2xl overflow-hidden w-[420px] max-w-[92vw] flex flex-col">
                <div className="grid grid-cols-[auto_1fr_auto] items-center gap-4 px-5 h-10 border-b border-white/5 bg-white/[0.02]">
                    <span className="text-[10px] uppercase tracking-[0.18em] text-white/45 whitespace-nowrap">
                        Employee
                    </span>
                    <span className="text-[11px] text-white/50 italic justify-self-center">
                        Read-only · use /employees to edit
                    </span>
                    <button
                        onClick={onClose}
                        className="h-7 w-7 inline-flex items-center justify-center rounded ring-1 ring-white/25 text-white/70 hover:text-red-200 hover:bg-red-500/15 hover:ring-red-400/50 transition-colors"
                        title="Close"
                    >
                        <X className="h-4 w-4" />
                    </button>
                </div>

                <div className="p-5 flex flex-col gap-4">
                    <div className="flex items-center gap-3">
                        <div className="h-12 w-12 rounded-xl bg-emerald-500/15 ring-1 ring-emerald-500/30 flex items-center justify-center">
                            <User className="h-6 w-6 text-emerald-300" />
                        </div>
                        <div>
                            <div className="text-base text-white font-semibold">
                                {employee.firstName} {employee.lastName}
                            </div>
                            <div className="text-[11px] text-white/45 tabular-nums">
                                {employee.id}
                            </div>
                        </div>
                    </div>

                    <div className="grid grid-cols-2 gap-3 text-[12px]">
                        <Field label="Model" value={employee.model} />
                        <Field
                            label="Plots"
                            value={`${employee.assignedPlots.length}`}
                        />
                        <Field
                            label="Home X"
                            value={employee.home.x.toFixed(2)}
                        />
                        <Field
                            label="Home Y"
                            value={employee.home.y.toFixed(2)}
                        />
                        <Field
                            label="Home Z"
                            value={employee.home.z.toFixed(2)}
                        />
                        <Field
                            label="Heading"
                            value={`${employee.home.w.toFixed(0)}°`}
                        />
                    </div>

                    {employee.assignedPlots.length > 0 && (
                        <div>
                            <div className="text-[11px] uppercase tracking-wider text-white/45 mb-1.5">
                                Assigned plots
                            </div>
                            <div className="flex flex-wrap gap-1.5">
                                {employee.assignedPlots.map((id) => (
                                    <span
                                        key={id}
                                        className="text-[11px] tabular-nums rounded bg-white/[0.06] ring-1 ring-white/15 px-2 py-0.5 text-white/75"
                                    >
                                        {id}
                                    </span>
                                ))}
                            </div>
                        </div>
                    )}
                </div>
            </div>
        </div>
    );
}

function Field({ label, value }: { label: string; value: string }) {
    return (
        <div className="rounded-lg bg-white/[0.04] ring-1 ring-white/10 px-3 py-2">
            <div className="text-[10px] uppercase tracking-wider text-white/45">
                {label}
            </div>
            <div className="text-white/85 tabular-nums">{value}</div>
        </div>
    );
}
