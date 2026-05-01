import { jsx as _jsx, jsxs as _jsxs } from "react/jsx-runtime";
import { useEffect, useMemo, useState } from "react";
import { Check, Lock, X } from "lucide-react";
import { fetchNui } from "@/lib/nui";
export function AssignerPanel({ empId, firstName, lastName, plots, initiallyAssigned, onClose, }) {
    const [checked, setChecked] = useState(() => new Set(initiallyAssigned ?? []));
    useEffect(() => {
        setChecked(new Set(initiallyAssigned ?? []));
    }, [empId, initiallyAssigned]);
    const sortedPlots = useMemo(() => {
        return [...plots].sort((a, b) => {
            // Mine first, then unassigned, then taken-by-other
            const rank = (p) => p.ownedByMe ? 0 : !p.ownerEmpId ? 1 : 2;
            return rank(a) - rank(b) || a.id.localeCompare(b.id);
        });
    }, [plots]);
    const toggle = (p) => {
        if (p.ownerEmpId && !p.ownedByMe)
            return; // taken by another employee
        setChecked((prev) => {
            const next = new Set(prev);
            if (next.has(p.id))
                next.delete(p.id);
            else
                next.add(p.id);
            return next;
        });
    };
    const onSave = () => {
        fetchNui("assignerSave", { empId, plotIds: Array.from(checked) });
    };
    return (_jsx("div", { className: "fixed inset-0 flex items-center justify-center pointer-events-none", children: _jsxs("div", { className: "pointer-events-auto rounded-2xl bg-black/95 ring-1 ring-white/10 shadow-2xl overflow-hidden w-[640px] max-w-[92vw] max-h-[78vh] flex flex-col", children: [_jsxs("div", { className: "grid grid-cols-[auto_1fr_auto] items-center gap-4 px-5 h-10 border-b border-white/5 bg-white/[0.02]", children: [_jsx("span", { className: "text-[10px] uppercase tracking-[0.18em] text-white/45 whitespace-nowrap", children: "Assign Plots" }), _jsxs("span", { className: "text-[12px] text-white/85 justify-self-center", children: [firstName, " ", lastName] }), _jsx("button", { onClick: onClose, className: "h-7 w-7 inline-flex items-center justify-center rounded ring-1 ring-white/25 text-white/70 hover:text-red-200 hover:bg-red-500/15 hover:ring-red-400/50 transition-colors", title: "Close", children: _jsx(X, { className: "h-4 w-4" }) })] }), _jsxs("div", { className: "flex-1 overflow-y-auto p-3 flex flex-col gap-1.5", children: [sortedPlots.length === 0 && (_jsx("div", { className: "flex-1 flex items-center justify-center text-white/40 text-sm italic py-12", children: "No plots created yet \u2014 use /drugs to make some." })), sortedPlots.map((p) => {
                            const takenByOther = !!p.ownerEmpId && !p.ownedByMe;
                            const isChecked = checked.has(p.id);
                            return (_jsxs("button", { disabled: takenByOther, onClick: () => toggle(p), className: "grid grid-cols-[24px_1fr_auto] items-center gap-3 rounded-lg ring-1 px-3 py-2 text-left transition-colors " +
                                    (takenByOther
                                        ? "bg-white/[0.02] ring-white/10 text-white/35 cursor-not-allowed "
                                        : isChecked
                                            ? "bg-emerald-500/15 ring-emerald-400/50 text-emerald-100 hover:bg-emerald-500/25 "
                                            : "bg-white/[0.04] ring-white/15 text-white/85 hover:bg-white/[0.08] hover:ring-white/30 "), children: [_jsx("span", { className: "inline-flex items-center justify-center", children: takenByOther ? (_jsx(Lock, { className: "h-4 w-4 opacity-60" })) : (_jsx("span", { className: "h-4 w-4 rounded ring-1 inline-flex items-center justify-center " +
                                                (isChecked
                                                    ? "bg-emerald-500/40 ring-emerald-300/70"
                                                    : "bg-transparent ring-white/40"), children: isChecked && (_jsx(Check, { className: "h-3 w-3 text-emerald-50" })) })) }), _jsxs("div", { className: "min-w-0", children: [_jsxs("div", { className: "text-sm font-medium truncate", children: [p.drug, " \u00B7 stage ", p.stage] }), _jsxs("div", { className: "text-[11px] text-white/50 tabular-nums truncate", children: [p.id, " \u00B7 ", p.x.toFixed(1), ", ", p.y.toFixed(1), ",", " ", p.z.toFixed(1)] })] }), takenByOther && p.ownerName && (_jsxs("span", { className: "text-[10px] text-white/50 italic", children: ["owned by ", p.ownerName] }))] }, p.id));
                        })] }), _jsxs("div", { className: "flex items-center justify-between gap-3 px-4 py-3 border-t border-white/5 bg-white/[0.02]", children: [_jsxs("span", { className: "text-[11px] text-white/55 tabular-nums", children: [checked.size, " selected"] }), _jsxs("div", { className: "flex items-center gap-2", children: [_jsx("button", { onClick: onClose, className: "rounded-md px-3 py-1.5 ring-1 ring-white/20 text-white/75 hover:bg-white/[0.06] hover:ring-white/35 transition-colors text-sm", children: "Cancel" }), _jsx("button", { onClick: onSave, className: "rounded-md px-3 py-1.5 ring-1 bg-emerald-500/25 ring-emerald-400/60 text-emerald-50 hover:bg-emerald-500/40 hover:shadow-[0_0_18px_-6px_rgba(52,211,153,0.6)] transition-all text-sm font-medium", children: "Save" })] })] })] }) }));
}
