import { useEffect, useState } from "react";
import { Building, Layers, MapPin, Move, Plus, Sprout, Trash2, X } from "lucide-react";

import { fetchNui } from "@/lib/nui";

function DrugsTabBar({ active }: { active: "plots" | "houses" | "interiors" }) {
    const tab = (id: "plots" | "houses" | "interiors", label: string, Icon: React.ElementType) => {
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
            {tab("plots", "Plots", Sprout)}
            {tab("houses", "Houses", Building)}
            {tab("interiors", "Interiors", Layers)}
        </div>
    );
}

export { DrugsTabBar };

export type DrugOption = { id: string; label: string };

export type PlotRow = {
    id: string;
    drug: string;
    stage: number;
    x: number;
    y: number;
    z: number;
    w: number;
};

export function CreatorPanel({
    drugs,
    plots,
    hidden,
    onClose,
}: {
    drugs: DrugOption[];
    plots: PlotRow[];
    hidden: boolean;
    onClose: () => void;
}) {
    const [selectedDrug, setSelectedDrug] = useState<string>("");
    const [confirmDelete, setConfirmDelete] = useState<string | null>(null);

    useEffect(() => {
        if (!selectedDrug && drugs.length > 0) setSelectedDrug(drugs[0].id);
    }, [drugs, selectedDrug]);

    if (hidden) return null;

    const drugLabelFor = (id: string) =>
        drugs.find((d) => d.id === id)?.label ?? id;

    const onPlace = () => {
        if (!selectedDrug) return;
        fetchNui("creatorPlace", { drug: selectedDrug });
    };
    const onMove = (plotId: string) => fetchNui("creatorMove", { plotId });
    const onDelete = (plotId: string) => {
        fetchNui("creatorDelete", { plotId });
        setConfirmDelete(null);
    };

    return (
        <div className="fixed inset-0 flex items-center justify-center pointer-events-none">
            <div className="pointer-events-auto rounded-2xl bg-black/95 ring-1 ring-white/10 shadow-2xl overflow-hidden w-[820px] max-w-[92vw] max-h-[80vh] flex flex-col">
                {/* Header */}
                <div className="grid grid-cols-[auto_1fr_auto] items-center gap-4 px-5 h-10 border-b border-white/5 bg-white/[0.02]">
                    <span className="text-[10px] uppercase tracking-[0.18em] text-white/45 whitespace-nowrap">
                        Drugs Admin
                    </span>
                    <DrugsTabBar active="plots" />
                    <button
                        onClick={onClose}
                        className="h-7 w-7 inline-flex items-center justify-center rounded ring-1 ring-white/25 text-white/70 hover:text-red-200 hover:bg-red-500/15 hover:ring-red-400/50 transition-colors"
                        title="Close"
                    >
                        <X className="h-4 w-4" />
                    </button>
                </div>

                <div className="flex divide-x divide-white/5 min-h-0 flex-1">
                    {/* New plot form */}
                    <div className="w-72 p-4 flex flex-col gap-3">
                        <div className="flex items-center gap-2 text-white/85">
                            <Plus className="h-4 w-4" />
                            <span className="text-sm font-medium">New plot</span>
                        </div>

                        <label className="text-[11px] uppercase tracking-wider text-white/45">
                            Drug type
                        </label>
                        <select
                            value={selectedDrug}
                            onChange={(e) => setSelectedDrug(e.target.value)}
                            className="bg-white/[0.06] ring-1 ring-white/20 rounded-md px-3 py-2 text-sm text-white outline-none focus:ring-emerald-400/60"
                        >
                            {drugs.length === 0 && (
                                <option value="">— no drugs configured —</option>
                            )}
                            {drugs.map((d) => (
                                <option key={d.id} value={d.id} className="bg-neutral-900">
                                    {d.label}
                                </option>
                            ))}
                        </select>

                        <button
                            onClick={onPlace}
                            disabled={!selectedDrug}
                            className="mt-auto flex items-center justify-center gap-2 rounded-lg px-3 py-2 ring-1 transition-all bg-emerald-500/15 ring-emerald-400/50 text-emerald-100 hover:bg-emerald-500/30 hover:ring-emerald-400/80 hover:text-emerald-50 hover:shadow-[0_0_18px_-6px_rgba(52,211,153,0.7)] disabled:opacity-40 disabled:cursor-not-allowed"
                        >
                            <MapPin className="h-4 w-4" />
                            <span className="text-sm font-medium">Place plot</span>
                        </button>
                        <p className="text-[10px] text-white/45 leading-relaxed">
                            Aim where you want the plot, then{" "}
                            <kbd className="px-1 rounded bg-white/10 ring-1 ring-white/15 text-[10px] font-mono">
                                G
                            </kbd>{" "}
                            to freeze,{" "}
                            <kbd className="px-1 rounded bg-white/10 ring-1 ring-white/15 text-[10px] font-mono">
                                A
                            </kbd>
                            /
                            <kbd className="px-1 rounded bg-white/10 ring-1 ring-white/15 text-[10px] font-mono">
                                D
                            </kbd>{" "}
                            to rotate,{" "}
                            <kbd className="px-1 rounded bg-white/10 ring-1 ring-white/15 text-[10px] font-mono">
                                E
                            </kbd>{" "}
                            to save.
                        </p>
                    </div>

                    {/* Plot list */}
                    <div className="flex-1 p-4 flex flex-col gap-2 min-h-0">
                        <div className="flex items-center justify-between">
                            <span className="text-sm text-white/85 font-medium">
                                Existing plots
                            </span>
                            <span className="text-[11px] text-white/45 tabular-nums">
                                {plots.length} total
                            </span>
                        </div>

                        <div className="flex-1 overflow-y-auto pr-1 -mr-1 flex flex-col gap-1.5">
                            {plots.length === 0 && (
                                <div className="flex-1 flex items-center justify-center text-white/40 text-sm italic">
                                    No plots — place your first one.
                                </div>
                            )}
                            {plots.map((p) => (
                                <div
                                    key={p.id}
                                    className="grid grid-cols-[1fr_auto_auto] items-center gap-3 rounded-lg bg-white/[0.04] ring-1 ring-white/10 px-3 py-2"
                                >
                                    <div className="min-w-0">
                                        <div className="flex items-center gap-2">
                                            <span className="text-sm text-white truncate font-medium">
                                                {drugLabelFor(p.drug)}
                                            </span>
                                            <span className="text-[10px] text-white/45 tabular-nums">
                                                stage {p.stage}
                                            </span>
                                        </div>
                                        <div className="text-[11px] text-white/50 tabular-nums truncate">
                                            {p.id}
                                            {" · "}
                                            {p.x.toFixed(1)}, {p.y.toFixed(1)},{" "}
                                            {p.z.toFixed(1)}
                                        </div>
                                    </div>
                                    <button
                                        onClick={() => onMove(p.id)}
                                        title="Move plot"
                                        className="h-8 w-8 inline-flex items-center justify-center rounded-md ring-1 ring-white/20 text-white/70 hover:text-amber-200 hover:bg-amber-500/15 hover:ring-amber-400/50 transition-colors"
                                    >
                                        <Move className="h-4 w-4" />
                                    </button>
                                    {confirmDelete === p.id ? (
                                        <button
                                            onClick={() => onDelete(p.id)}
                                            title="Confirm delete"
                                            className="h-8 px-3 inline-flex items-center justify-center rounded-md ring-1 bg-red-500/25 ring-red-400/60 text-red-100 hover:bg-red-500/40 transition-colors text-[11px] font-medium"
                                        >
                                            Confirm
                                        </button>
                                    ) : (
                                        <button
                                            onClick={() => setConfirmDelete(p.id)}
                                            title="Delete plot"
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
