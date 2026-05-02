// Storage locker panel. Split layout: storage grid on the left, the
// player's inventory on the right. Items move between the two grids by
// pointer-drag — the HTML5 drag-and-drop API isn't reliable inside CEF
// (FiveM's NUI host paints the no-drop cursor regardless of dropEffect),
// so we implement dragging manually: pointerdown captures a source,
// pointermove drives a floating ghost, pointerup hit-tests the slot
// under the cursor and fires the right transfer.

import { useEffect, useRef, useState } from "react";
import { Box, Mouse, X } from "lucide-react";

import { fetchNui, useNuiEvent } from "@/lib/nui";

type StorageItem = {
    name: string;
    label?: string;
    count: number;
    metadata?: unknown;
};

type PlayerItem = {
    slot: number;
    name: string;
    label?: string;
    count: number;
    metadata?: unknown;
    weight?: number;
};

export type StorageData = {
    id: string;
    kind: string;
    label: string;
    slots: number;
    items: Record<string, StorageItem>;
    player: PlayerItem[];
    imagesPath?: string;
};

type DragSource =
    | { side: "storage"; slot: number; item: StorageItem }
    | { side: "player"; slot: number; item: StorageItem };

type DragState = {
    source: DragSource;
    image: string;
    x: number;
    y: number;
    // 1..10. count = round(stack * level / 10), min 1. Scroll wheel
    // while dragging steps it.
    level: number;
};

const MAX_LEVEL = 10;

function countAtLevel(stack: number, level: number) {
    return Math.max(1, Math.min(stack, Math.round(stack * level / MAX_LEVEL)));
}

const SLOT_ATTR = "data-slot-id";

function prettyName(name: string, label?: string) {
    if (label && label.trim()) return label;
    return name.replace(/_/g, " ");
}

export function StoragePanel({
    data, onClose,
}: {
    data: StorageData;
    onClose: () => void;
}) {
    const [snap, setSnap] = useState<StorageData>(data);
    const [drag, setDrag] = useState<DragState | null>(null);
    const dragRef = useRef<DragState | null>(null);
    dragRef.current = drag;

    useEffect(() => { setSnap(data); }, [data]);

    useNuiEvent<StorageData>("storageContents", (d) => {
        if (d && d.id === data.id) setSnap(d);
    });

    const slots = Math.max(1, snap.slots || 0);
    const storageSlots: (StorageItem | null)[] = [];
    for (let i = 1; i <= slots; i++) {
        storageSlots.push(snap.items?.[String(i)] || snap.items?.[i as unknown as string] || null);
    }

    const imagesPath = (snap.imagesPath || "").replace(/\/+$/, "");
    const imageFor = (name: string) =>
        imagesPath ? `${imagesPath}/${name}.png` : "";

    const finishDrop = (target: { side: "storage" | "player"; slot: number | null }) => {
        const cur = dragRef.current;
        if (!cur) return;
        const src = cur.source;
        const count = countAtLevel(src.item.count, cur.level);
        if (target.side === "storage") {
            if (src.side === "player") {
                fetchNui("storageTransfer", {
                    direction: "deposit",
                    fromSlot: src.slot,
                    toSlot: target.slot ?? undefined,
                    count,
                });
            } else if (src.side === "storage" && target.slot && src.slot !== target.slot) {
                // Within-locker rearrange always moves the whole stack —
                // partial reorders make no inventory sense.
                fetchNui("storageTransfer", {
                    direction: "rearrange",
                    fromSlot: src.slot,
                    toSlot: target.slot,
                });
            }
        } else if (target.side === "player") {
            if (src.side === "storage") {
                fetchNui("storageTransfer", {
                    direction: "withdraw",
                    fromSlot: src.slot,
                    count,
                });
            }
        }
    };

    // Global pointer move/up while dragging. Listening on window means we
    // never lose the drag if the cursor exits a slot's bounds.
    useEffect(() => {
        if (!drag) return;
        const onMove = (e: PointerEvent) => {
            setDrag((d) => (d ? { ...d, x: e.clientX, y: e.clientY } : d));
        };
        const onUp = (e: PointerEvent) => {
            // Hit-test the element under the pointer for either a slot
            // (data-slot-id="storage:N" / "player:N") or a grid container
            // (data-grid="storage" / "player") so dropping in whitespace
            // also works.
            const stack = document.elementsFromPoint(e.clientX, e.clientY);
            let resolved: { side: "storage" | "player"; slot: number | null } | null = null;
            for (const el of stack) {
                const slotId = (el as HTMLElement).getAttribute?.(SLOT_ATTR);
                if (slotId) {
                    const [side, slotStr] = slotId.split(":");
                    if (side === "storage" || side === "player") {
                        resolved = { side, slot: parseInt(slotStr, 10) };
                        break;
                    }
                }
                const grid = (el as HTMLElement).getAttribute?.("data-grid");
                if (grid === "storage" || grid === "player") {
                    resolved = { side: grid, slot: null };
                    break;
                }
            }
            if (resolved) finishDrop(resolved);
            setDrag(null);
        };
        const onWheel = (e: WheelEvent) => {
            e.preventDefault();
            const dir = e.deltaY > 0 ? -1 : 1;
            setDrag((d) => {
                if (!d) return d;
                const next = Math.max(1, Math.min(MAX_LEVEL, d.level + dir));
                return next === d.level ? d : { ...d, level: next };
            });
        };
        window.addEventListener("pointermove", onMove);
        window.addEventListener("pointerup", onUp);
        window.addEventListener("pointercancel", onUp);
        // Passive: false so preventDefault sticks — otherwise the wheel
        // both scrolls the panel AND adjusts the level.
        window.addEventListener("wheel", onWheel, { passive: false });
        return () => {
            window.removeEventListener("pointermove", onMove);
            window.removeEventListener("pointerup", onUp);
            window.removeEventListener("pointercancel", onUp);
            window.removeEventListener("wheel", onWheel);
        };
    }, [drag !== null]);

    const startDrag = (source: DragSource, e: React.PointerEvent) => {
        // Accept primary (left, button 0) or secondary (right, button 2)
        // — right-drag is an ergonomic alternative when the player is
        // already palming the mouse for in-world right-aim controls.
        if (e.button !== 0 && e.button !== 2) return;
        e.preventDefault();
        setDrag({
            source,
            image: imageFor(source.item.name),
            x: e.clientX,
            y: e.clientY,
            level: MAX_LEVEL,
        });
    };

    return (
        <div className="fixed inset-0 flex items-center justify-center pointer-events-none">
            <div
                onContextMenu={(e) => e.preventDefault()}
                className="pointer-events-auto rounded-2xl bg-black/95 ring-1 ring-white/10 shadow-2xl w-[860px] max-w-[94vw] max-h-[84vh] flex flex-col overflow-hidden"
            >
                <div className="grid grid-cols-[auto_1fr_auto] items-center gap-3 px-5 h-11 border-b border-white/5 bg-white/[0.02]">
                    <div className="flex items-center gap-2">
                        <Box className="h-4 w-4 text-emerald-300" />
                        <span className="text-sm text-white font-medium">{snap.label}</span>
                    </div>
                    <span className="text-[11px] uppercase tracking-wider justify-self-center text-white/55">
                        {Object.keys(snap.items || {}).length} / {slots} slots
                    </span>
                    <button onClick={onClose}
                        className="h-7 w-7 inline-flex items-center justify-center rounded ring-1 ring-white/25 text-white/70 hover:text-red-200 hover:bg-red-500/15">
                        <X className="h-4 w-4" />
                    </button>
                </div>

                <div className="flex-1 overflow-hidden grid grid-cols-2 gap-4 p-5">
                    <Grid title={snap.label} accent="emerald" gridId="storage">
                        {storageSlots.map((it, idx) => {
                            const slot = idx + 1;
                            return (
                                <Slot
                                    key={`s-${slot}`}
                                    slotId={`storage:${slot}`}
                                    item={it}
                                    image={it ? imageFor(it.name) : ""}
                                    onPointerDown={(e) => {
                                        if (it) startDrag({ side: "storage", slot, item: it }, e);
                                    }}
                                />
                            );
                        })}
                    </Grid>

                    <Grid title="Your Inventory" accent="sky" gridId="player">
                        {(snap.player || []).map((it) => {
                            const item: StorageItem = {
                                name: it.name, label: it.label,
                                count: it.count, metadata: it.metadata,
                            };
                            return (
                                <Slot
                                    key={`p-${it.slot}-${it.name}`}
                                    slotId={`player:${it.slot}`}
                                    item={item}
                                    image={imageFor(it.name)}
                                    onPointerDown={(e) =>
                                        startDrag({ side: "player", slot: it.slot, item }, e)
                                    }
                                />
                            );
                        })}
                        {(snap.player || []).length === 0 && (
                            <div className="col-span-full text-[11px] italic text-white/40 px-1">
                                Your inventory is empty.
                            </div>
                        )}
                    </Grid>
                </div>
            </div>

            {drag && (
                <DragGhost
                    x={drag.x}
                    y={drag.y}
                    image={drag.image}
                    item={drag.source.item}
                    level={drag.level}
                    count={countAtLevel(drag.source.item.count, drag.level)}
                />
            )}
        </div>
    );
}

function Grid({
    title, accent, gridId, children,
}: {
    title: string;
    accent: "emerald" | "sky";
    gridId: "storage" | "player";
    children: React.ReactNode;
}) {
    const ring = accent === "emerald" ? "ring-emerald-400/30" : "ring-sky-400/30";
    const dot  = accent === "emerald" ? "bg-emerald-300" : "bg-sky-300";
    return (
        <div
            data-grid={gridId}
            className={`flex flex-col rounded-lg bg-white/[0.03] ring-1 ${ring} overflow-hidden`}
        >
            <div className="flex items-center gap-2 px-3 h-9 border-b border-white/5 bg-white/[0.02]">
                <span className={`h-1.5 w-1.5 rounded-full ${dot}`} />
                <span className="text-[12px] tracking-wide text-white/85">{title}</span>
            </div>
            <div data-grid={gridId} className="flex-1 overflow-y-auto p-3">
                <div data-grid={gridId} className="grid grid-cols-5 gap-2">
                    {children}
                </div>
            </div>
        </div>
    );
}

function Slot({
    slotId, item, image, onPointerDown,
}: {
    slotId: string;
    item: StorageItem | null;
    image: string;
    onPointerDown: (e: React.PointerEvent) => void;
}) {
    const empty = !item;
    const [imgFailed, setImgFailed] = useState(false);
    useEffect(() => { setImgFailed(false); }, [image]);
    return (
        <div
            {...{ [SLOT_ATTR]: slotId }}
            onPointerDown={onPointerDown}
            className={
                "relative aspect-square rounded-md ring-1 flex flex-col items-center justify-end p-1.5 select-none overflow-hidden " +
                (empty
                    ? "bg-white/[0.02] ring-white/5"
                    : "bg-white/[0.06] ring-white/15 cursor-grab active:cursor-grabbing")
            }
            title={item ? `${prettyName(item.name, item.label)} ×${item.count}` : ""}
        >
            {item && (
                <>
                    {image && !imgFailed ? (
                        <img
                            src={image}
                            alt={item.name}
                            draggable={false}
                            onError={() => setImgFailed(true)}
                            className="absolute inset-0 m-auto max-h-[70%] max-w-[70%] object-contain pointer-events-none"
                        />
                    ) : (
                        <div className="flex-1 w-full flex items-center justify-center text-[10px] text-center text-white/85 leading-tight break-words pointer-events-none">
                            {prettyName(item.name, item.label)}
                        </div>
                    )}
                    <div className="absolute bottom-1 right-1.5 text-[10px] tabular-nums text-white/85 drop-shadow pointer-events-none">
                        ×{item.count}
                    </div>
                </>
            )}
        </div>
    );
}

function DragGhost({
    x, y, image, item, level, count,
}: {
    x: number; y: number; image: string; item: StorageItem;
    level: number; count: number;
}) {
    const [imgFailed, setImgFailed] = useState(false);
    return (
        <div
            className="fixed z-50 pointer-events-none rounded-md ring-1 ring-emerald-300/60 bg-black/80 shadow-xl flex flex-col items-center"
            style={{
                left: x - 36, top: y - 36,
                width: 72,
            }}
        >
            <div className="relative w-full aspect-square overflow-hidden rounded-md">
                {image && !imgFailed ? (
                    <img
                        src={image}
                        alt={item.name}
                        draggable={false}
                        onError={() => setImgFailed(true)}
                        className="absolute inset-0 m-auto max-h-[70%] max-w-[70%] object-contain"
                    />
                ) : (
                    <div className="absolute inset-0 flex items-center justify-center text-[10px] text-center text-white/85 leading-tight break-words px-1">
                        {prettyName(item.name, item.label)}
                    </div>
                )}
                <div className="absolute bottom-1 right-1.5 text-[10px] tabular-nums text-white/90 drop-shadow">
                    ×{count}
                </div>
            </div>
            <div className="mt-1 mb-1 px-1.5 py-0.5 rounded bg-black/80 ring-1 ring-emerald-300/40 text-[9px] tabular-nums text-emerald-100 inline-flex items-center gap-1">
                <span>{level}/{MAX_LEVEL}</span>
                <Mouse className="h-3 w-3" />
            </div>
        </div>
    );
}
