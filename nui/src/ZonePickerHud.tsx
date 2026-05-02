// HUD shown while the admin is picking a placement zone or MLO polygon
// in the world. Phases: "origin" (highlight the cell under the cursor)
// → "bounds" (live size readout while the grid grows) for zones; or
// "polygon" (vertex-by-vertex tracing) for MLO bounds.

export type ZonePickerHudData = {
    phase: "origin" | "bounds" | "polygon" | "worldDoor";
    xCells?: number;
    yCells?: number;
    cell?: number;
    invalid?: boolean;
    vertices?: number;
    rotDeg?: number;
};

export function ZonePickerHud({ data }: { data: ZonePickerHudData }) {
    if (data.phase === "worldDoor") {
        return (
            <div className="fixed inset-x-0 bottom-6 flex justify-center pointer-events-none">
                <div className="rounded-2xl bg-black/85 ring-1 ring-white/15 shadow-2xl px-4 py-2.5 flex items-center gap-3 text-[12px] text-white/85">
                    <span className="text-[10px] uppercase tracking-[0.18em] text-white/45">World Door</span>
                    <span className="h-4 w-px bg-white/10" />
                    <span className="text-white/80">Aim at the door spot</span>
                    <span className="h-4 w-px bg-white/10" />
                    <span className="flex items-center gap-1.5"><Kbd>Scroll</Kbd> Rotate</span>
                    <span className="flex items-center gap-1.5">
                        <Kbd>LMB</Kbd> <span className="text-emerald-200/90">Confirm</span>
                    </span>
                    <span className="flex items-center gap-1.5">
                        <Kbd>Esc</Kbd> <span className="text-red-200/90">Cancel</span>
                    </span>
                </div>
            </div>
        );
    }
    if (data.phase === "polygon") {
        const verts = data.vertices ?? 0;
        const canConfirm = verts >= 3;
        return (
            <div className="fixed inset-x-0 bottom-6 flex justify-center pointer-events-none">
                <div className="rounded-2xl bg-black/85 ring-1 ring-white/15 shadow-2xl px-4 py-2.5 flex items-center gap-3 text-[12px] text-white/85">
                    <span className="text-[10px] uppercase tracking-[0.18em] text-white/45">MLO Bounds</span>
                    <span className="h-4 w-px bg-white/10" />
                    <span className="text-white/80">Trace polygon</span>
                    <span className="text-[11px] text-white/45 tabular-nums">{verts} vertex{verts === 1 ? "" : "es"}</span>
                    <span className="h-4 w-px bg-white/10" />
                    <span className="flex items-center gap-1.5"><Kbd>LMB</Kbd> Add</span>
                    <span className="flex items-center gap-1.5"><Kbd>Bksp</Kbd> Undo</span>
                    <span className="flex items-center gap-1.5">
                        <Kbd>E</Kbd>
                        <span className={canConfirm ? "text-emerald-200/90" : "text-white/35"}>Confirm</span>
                    </span>
                    <span className="flex items-center gap-1.5">
                        <Kbd>Esc</Kbd> <span className="text-red-200/90">Cancel</span>
                    </span>
                </div>
            </div>
        );
    }
    const isBounds = data.phase === "bounds";
    const invalid = !!data.invalid;
    return (
        <div className="fixed inset-x-0 bottom-6 flex justify-center pointer-events-none">
            <div className="rounded-2xl bg-black/85 ring-1 ring-white/15 shadow-2xl px-4 py-2.5 flex items-center gap-3 text-[12px] text-white/85">
                <span className="text-[10px] uppercase tracking-[0.18em] text-white/45">Zone</span>
                <span className="h-4 w-px bg-white/10" />
                <span className="text-white/80">
                    {isBounds ? "Set bounds" : "Set origin"}
                </span>
                {isBounds && (
                    <span className="text-[11px] text-white/45 tabular-nums">
                        {data.xCells}×{data.yCells} @ {(data.cell ?? 1).toFixed(2)}m
                        {typeof data.rotDeg === "number" &&
                            ` · ${data.rotDeg.toFixed(data.rotDeg % 1 === 0 ? 0 : 1)}°`}
                    </span>
                )}
                {!isBounds && typeof data.rotDeg === "number" && (
                    <span className="text-[11px] text-white/45 tabular-nums">
                        {data.rotDeg.toFixed(data.rotDeg % 1 === 0 ? 0 : 1)}°
                    </span>
                )}
                {invalid && (
                    <span className="text-[11px] text-red-200/90">overlap — adjust</span>
                )}
                <span className="h-4 w-px bg-white/10" />
                <span className="flex items-center gap-1.5">
                    <Kbd>LMB</Kbd>
                    <span className={invalid ? "text-white/35" : "text-emerald-200/90"}>
                        {isBounds ? "Confirm" : "Set origin"}
                    </span>
                </span>
                {!isBounds && (
                    <>
                        <span className="flex items-center gap-1.5">
                            <Kbd>Scroll</Kbd> Rotate
                        </span>
                        <span className="text-[11px] text-white/40">
                            <Kbd>Shift</Kbd> coarse · <Kbd>Ctrl</Kbd> fine
                        </span>
                    </>
                )}
                {isBounds && (
                    <span className="flex items-center gap-1.5">
                        <Kbd>RMB</Kbd> Reset origin
                    </span>
                )}
                <span className="flex items-center gap-1.5">
                    <Kbd>Esc</Kbd> <span className="text-red-200/90">Cancel</span>
                </span>
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
