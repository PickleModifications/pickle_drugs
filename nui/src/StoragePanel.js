import { jsx as _jsx, jsxs as _jsxs, Fragment as _Fragment } from "react/jsx-runtime";
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
const MAX_LEVEL = 10;
function countAtLevel(stack, level) {
    return Math.max(1, Math.min(stack, Math.round(stack * level / MAX_LEVEL)));
}
const SLOT_ATTR = "data-slot-id";
function prettyName(name, label) {
    if (label && label.trim())
        return label;
    return name.replace(/_/g, " ");
}
export function StoragePanel({ data, onClose, }) {
    const [snap, setSnap] = useState(data);
    const [drag, setDrag] = useState(null);
    const dragRef = useRef(null);
    dragRef.current = drag;
    // Dealer storage requires a confirm step before close so the player
    // can't accidentally end the meetup mid-handoff. ESC + the X button
    // both route through `requestClose`; lockers close immediately,
    // dealers raise the in-panel modal.
    const isDealer = typeof snap.id === "string" && snap.id.startsWith("dealer:");
    const [confirmingClose, setConfirmingClose] = useState(false);
    useEffect(() => { setSnap(data); }, [data]);
    useNuiEvent("storageContents", (d) => {
        if (d && d.id === data.id)
            setSnap(d);
    });
    const requestClose = () => {
        if (isDealer)
            setConfirmingClose(true);
        else
            onClose();
    };
    // ESC routes through requestClose so the dealer confirm modal can
    // intercept. Native keydown listener — IsDisabledControlJust* on the
    // Lua side doesn't fire reliably while NUI owns focus.
    useEffect(() => {
        const onKey = (e) => {
            if (e.key === "Escape") {
                e.preventDefault();
                if (confirmingClose)
                    setConfirmingClose(false);
                else
                    requestClose();
            }
        };
        window.addEventListener("keydown", onKey);
        return () => window.removeEventListener("keydown", onKey);
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [onClose, isDealer, confirmingClose]);
    const slots = Math.max(1, snap.slots || 0);
    const storageSlots = [];
    for (let i = 1; i <= slots; i++) {
        storageSlots.push(snap.items?.[String(i)] || snap.items?.[i] || null);
    }
    const imagesPath = (snap.imagesPath || "").replace(/\/+$/, "");
    const imageFor = (name) => imagesPath ? `${imagesPath}/${name}.png` : "";
    const finishDrop = (target) => {
        const cur = dragRef.current;
        if (!cur)
            return;
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
            }
            else if (src.side === "storage" && target.slot && src.slot !== target.slot) {
                // Wheel-level lets the player split a partial out of the
                // source stack into another slot (or merge onto an existing
                // same-item pile).
                fetchNui("storageTransfer", {
                    direction: "rearrange",
                    fromSlot: src.slot,
                    toSlot: target.slot,
                    count,
                });
            }
        }
        else if (target.side === "player") {
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
        if (!drag)
            return;
        const onMove = (e) => {
            setDrag((d) => (d ? { ...d, x: e.clientX, y: e.clientY } : d));
        };
        const onUp = (e) => {
            // Hit-test the element under the pointer for either a slot
            // (data-slot-id="storage:N" / "player:N") or a grid container
            // (data-grid="storage" / "player") so dropping in whitespace
            // also works.
            const stack = document.elementsFromPoint(e.clientX, e.clientY);
            let resolved = null;
            for (const el of stack) {
                const slotId = el.getAttribute?.(SLOT_ATTR);
                if (slotId) {
                    const [side, slotStr] = slotId.split(":");
                    if (side === "storage" || side === "player") {
                        resolved = { side, slot: parseInt(slotStr, 10) };
                        break;
                    }
                }
                const grid = el.getAttribute?.("data-grid");
                if (grid === "storage" || grid === "player") {
                    resolved = { side: grid, slot: null };
                    break;
                }
            }
            if (resolved)
                finishDrop(resolved);
            setDrag(null);
        };
        const onWheel = (e) => {
            e.preventDefault();
            const dir = e.deltaY > 0 ? -1 : 1;
            setDrag((d) => {
                if (!d)
                    return d;
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
    const startDrag = (source, e) => {
        // Accept primary (left, button 0) or secondary (right, button 2)
        // — right-drag is an ergonomic alternative when the player is
        // already palming the mouse for in-world right-aim controls.
        if (e.button !== 0 && e.button !== 2)
            return;
        e.preventDefault();
        setDrag({
            source,
            image: imageFor(source.item.name),
            x: e.clientX,
            y: e.clientY,
            level: MAX_LEVEL,
        });
    };
    return (_jsxs("div", { className: "fixed inset-0 flex items-center justify-center pointer-events-none", children: [_jsxs("div", { onContextMenu: (e) => e.preventDefault(), className: "relative pointer-events-auto rounded-2xl bg-black/95 ring-1 ring-white/10 shadow-2xl w-[860px] max-w-[94vw] max-h-[84vh] flex flex-col overflow-hidden", children: [_jsxs("div", { className: "grid grid-cols-[auto_1fr_auto] items-center gap-3 px-5 h-11 border-b border-white/5 bg-white/[0.02]", children: [_jsxs("div", { className: "flex items-center gap-2", children: [_jsx(Box, { className: "h-4 w-4 text-emerald-300" }), _jsx("span", { className: "text-sm text-white font-medium", children: snap.label })] }), _jsxs("span", { className: "text-[11px] uppercase tracking-wider justify-self-center text-white/55", children: [Object.keys(snap.items || {}).length, " / ", slots, " slots"] }), _jsx("button", { onClick: requestClose, className: "h-7 w-7 inline-flex items-center justify-center rounded ring-1 ring-white/25 text-white/70 hover:text-red-200 hover:bg-red-500/15", children: _jsx(X, { className: "h-4 w-4" }) })] }), _jsxs("div", { className: "flex-1 overflow-hidden grid grid-cols-2 gap-4 p-5", children: [_jsx(Grid, { title: snap.label, accent: "emerald", gridId: "storage", children: storageSlots.map((it, idx) => {
                                    const slot = idx + 1;
                                    return (_jsx(Slot, { slotId: `storage:${slot}`, item: it, image: it ? imageFor(it.name) : "", onPointerDown: (e) => {
                                            if (it)
                                                startDrag({ side: "storage", slot, item: it }, e);
                                        } }, `s-${slot}`));
                                }) }), _jsxs(Grid, { title: "Your Inventory", accent: "sky", gridId: "player", children: [(snap.player || []).map((it) => {
                                        const item = {
                                            name: it.name, label: it.label,
                                            count: it.count, metadata: it.metadata,
                                        };
                                        return (_jsx(Slot, { slotId: `player:${it.slot}`, item: item, image: imageFor(it.name), onPointerDown: (e) => startDrag({ side: "player", slot: it.slot, item }, e) }, `p-${it.slot}-${it.name}`));
                                    }), (snap.player || []).length === 0 && (_jsx("div", { className: "col-span-full text-[11px] italic text-white/40 px-1", children: "Your inventory is empty." }))] })] }), confirmingClose && (_jsx("div", { className: "absolute inset-0 z-20 flex items-center justify-center bg-black/70 backdrop-blur-sm", children: _jsxs("div", { className: "rounded-xl bg-zinc-950 ring-1 ring-amber-400/30 shadow-2xl w-[360px] p-4 flex flex-col gap-3", children: [_jsxs("div", { className: "flex items-center gap-2", children: [_jsx("span", { className: "h-2 w-2 rounded-full bg-amber-400" }), _jsx("span", { className: "text-sm font-semibold text-amber-100", children: "End the meetup?" })] }), _jsxs("p", { className: "text-[12px] text-white/65 leading-snug", children: ["Closing this will wrap up the handoff with ", snap.label, ". They'll pocket whatever's been left and walk away. You can summon them again from your phone."] }), _jsxs("div", { className: "flex items-center justify-end gap-2 pt-1", children: [_jsx("button", { onClick: () => setConfirmingClose(false), className: "px-3 py-1.5 rounded ring-1 ring-white/15 text-white/75 hover:bg-white/[0.06] text-xs", children: "Stay" }), _jsx("button", { onClick: () => { setConfirmingClose(false); onClose(); }, className: "px-3 py-1.5 rounded ring-1 ring-amber-400/50 bg-amber-500/20 text-amber-50 hover:bg-amber-500/35 text-xs font-semibold", children: "End meetup" })] })] }) }))] }), drag && (_jsx(DragGhost, { x: drag.x, y: drag.y, image: drag.image, item: drag.source.item, level: drag.level, count: countAtLevel(drag.source.item.count, drag.level) }))] }));
}
function Grid({ title, accent, gridId, children, }) {
    const ring = accent === "emerald" ? "ring-emerald-400/30" : "ring-sky-400/30";
    const dot = accent === "emerald" ? "bg-emerald-300" : "bg-sky-300";
    return (_jsxs("div", { "data-grid": gridId, className: `flex flex-col rounded-lg bg-white/[0.03] ring-1 ${ring} overflow-hidden`, children: [_jsxs("div", { className: "flex items-center gap-2 px-3 h-9 border-b border-white/5 bg-white/[0.02]", children: [_jsx("span", { className: `h-1.5 w-1.5 rounded-full ${dot}` }), _jsx("span", { className: "text-[12px] tracking-wide text-white/85", children: title })] }), _jsx("div", { "data-grid": gridId, className: "flex-1 overflow-y-auto p-3", children: _jsx("div", { "data-grid": gridId, className: "grid grid-cols-5 gap-2", children: children }) })] }));
}
function Slot({ slotId, item, image, onPointerDown, }) {
    const empty = !item;
    const [imgFailed, setImgFailed] = useState(false);
    useEffect(() => { setImgFailed(false); }, [image]);
    return (_jsx("div", { [SLOT_ATTR]: slotId, onPointerDown: onPointerDown, className: "relative aspect-square rounded-md ring-1 flex flex-col items-center justify-end p-1.5 select-none overflow-hidden " +
            (empty
                ? "bg-white/[0.02] ring-white/5"
                : "bg-white/[0.06] ring-white/15 cursor-grab active:cursor-grabbing"), title: item ? `${prettyName(item.name, item.label)} ×${item.count}` : "", children: item && (_jsxs(_Fragment, { children: [image && !imgFailed ? (_jsx("img", { src: image, alt: item.name, draggable: false, onError: () => setImgFailed(true), className: "absolute inset-0 m-auto max-h-[70%] max-w-[70%] object-contain pointer-events-none" })) : (_jsx("div", { className: "flex-1 w-full flex items-center justify-center text-[10px] text-center text-white/85 leading-tight break-words pointer-events-none", children: prettyName(item.name, item.label) })), _jsxs("div", { className: "absolute bottom-1 right-1.5 text-[10px] tabular-nums text-white/85 drop-shadow pointer-events-none", children: ["\u00D7", item.count] })] })) }));
}
function DragGhost({ x, y, image, item, level, count, }) {
    const [imgFailed, setImgFailed] = useState(false);
    return (_jsxs("div", { className: "fixed z-50 pointer-events-none rounded-md ring-1 ring-emerald-300/60 bg-black/80 shadow-xl flex flex-col items-center", style: {
            left: x - 36, top: y - 36,
            width: 72,
        }, children: [_jsxs("div", { className: "relative w-full aspect-square overflow-hidden rounded-md", children: [image && !imgFailed ? (_jsx("img", { src: image, alt: item.name, draggable: false, onError: () => setImgFailed(true), className: "absolute inset-0 m-auto max-h-[70%] max-w-[70%] object-contain" })) : (_jsx("div", { className: "absolute inset-0 flex items-center justify-center text-[10px] text-center text-white/85 leading-tight break-words px-1", children: prettyName(item.name, item.label) })), _jsxs("div", { className: "absolute bottom-1 right-1.5 text-[10px] tabular-nums text-white/90 drop-shadow", children: ["\u00D7", count] })] }), _jsxs("div", { className: "mt-1 mb-1 px-1.5 py-0.5 rounded bg-black/80 ring-1 ring-emerald-300/40 text-[9px] tabular-nums text-emerald-100 inline-flex items-center gap-1", children: [_jsxs("span", { children: [level, "/", MAX_LEVEL] }), _jsx(Mouse, { className: "h-3 w-3" })] })] }));
}
