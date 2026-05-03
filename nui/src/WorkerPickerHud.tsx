// HUD shown while the player is in the worker plot-picker mode. The
// raycast, footprint boxes, and zone grid are all drawn in 3D by the
// Lua client; this just tells the player what they're looking at and
// how to confirm/cancel.

export type WorkerPickerHudData = {
    slotsUsed: number;
    slotsMax: number;
    available: number;
};

export function WorkerPickerHud({ data }: { data: WorkerPickerHudData }) {
    return (
        <div className="fixed inset-x-0 bottom-6 flex flex-col items-center gap-2 pointer-events-none">
            <div className="rounded-2xl bg-black/85 ring-1 ring-white/15 shadow-2xl px-4 py-2.5 flex items-center gap-3 text-[12px] text-white/85">
                <span className="text-[10px] uppercase tracking-[0.18em] text-emerald-200/80">
                    Assign plot
                </span>
                <span className="h-4 w-px bg-white/10" />
                <span className="text-white/80 tabular-nums">
                    Slot {Math.min(data.slotsUsed + 1, data.slotsMax)} / {data.slotsMax}
                </span>
                <span className="text-[11px] text-white/45 tabular-nums">
                    · {data.available} available
                </span>
                <span className="h-4 w-px bg-white/10" />
                <span className="flex items-center gap-1.5">
                    <Kbd>Aim</Kbd> Look at a plot
                </span>
                <span className="flex items-center gap-1.5">
                    <Kbd>E</Kbd> <span className="text-emerald-200/90">Assign</span>
                </span>
                <span className="flex items-center gap-1.5">
                    <Kbd>Esc</Kbd> <span className="text-red-200/90">Cancel</span>
                </span>
            </div>
            <div className="rounded-2xl bg-black/70 ring-1 ring-white/10 px-3 py-1.5 flex items-center gap-3 text-[11px] text-white/70">
                <Swatch className="bg-emerald-400/80 ring-emerald-300/60" /> Free
                <Swatch className="bg-white/85 ring-white/60" /> Yours
                <Swatch className="bg-red-500/80 ring-red-400/70" /> Other worker
            </div>
        </div>
    );
}

function Kbd({ children }: { children: React.ReactNode }) {
    return (
        <kbd className="inline-flex items-center align-middle h-[18px] px-1.5 mx-0.5 rounded bg-white/10 ring-1 ring-white/15 text-[11px] font-mono leading-none">
            {children}
        </kbd>
    );
}

function Swatch({ className }: { className: string }) {
    return (
        <span className={"inline-block h-2.5 w-3.5 rounded-sm ring-1 " + className} />
    );
}
