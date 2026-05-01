// HUD shown while the player is in placement mode. The entity preview
// + footprint box + zone grids are drawn in 3D by the Lua client; this
// just reminds the player of the keybinds.

export type PlacementHudData = {
    zoneLabel: string;
    cell: number;
};

export function HousePlacementHud({ data }: { data: PlacementHudData }) {
    return (
        <div className="fixed inset-x-0 bottom-6 flex justify-center pointer-events-none">
            <div className="rounded-2xl bg-black/85 ring-1 ring-white/15 shadow-2xl px-4 py-2.5 flex items-center gap-3 text-[12px] text-white/85">
                <span className="text-[10px] uppercase tracking-[0.18em] text-white/45">Placement</span>
                <span className="h-4 w-px bg-white/10" />
                <span className="text-white/80">{data.zoneLabel}</span>
                <span className="text-[11px] text-white/45 tabular-nums">
                    grid {data.cell.toFixed(2)}m
                </span>
                <span className="h-4 w-px bg-white/10" />
                <span className="flex items-center gap-1.5">
                    <Kbd>Aim</Kbd> Move
                </span>
                <span className="flex items-center gap-1.5">
                    <Kbd>Scroll</Kbd> Rotate
                </span>
                <span className="flex items-center gap-1.5">
                    <Kbd>E</Kbd> <span className="text-emerald-200/90">Confirm</span>
                </span>
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
