import { jsx as _jsx, jsxs as _jsxs, Fragment as _Fragment } from "react/jsx-runtime";
import { useEffect, useRef, useState } from "react";
import { Droplet, Leaf, Sprout } from "lucide-react";
import { Card, CardContent } from "@/components/ui/card";
import { fetchNui, useNuiEvent } from "@/lib/nui";
/**
 * Bar that rAF-lerps its visible width toward the target value, so jumpy
 * inputs (Lua bursts, percentages leaping in one tick) animate smoothly
 * instead of snapping. `target` is 0..1.
 */
function SmoothBar({ target, className, speed = 6, }) {
    const [value, setValue] = useState(target);
    const valueRef = useRef(target);
    const targetRef = useRef(target);
    const lastTsRef = useRef(null);
    useEffect(() => {
        targetRef.current = Math.max(0, Math.min(1, target));
    }, [target]);
    useEffect(() => {
        let raf = 0;
        const tick = (ts) => {
            const last = lastTsRef.current ?? ts;
            const dt = Math.min(0.05, (ts - last) / 1000);
            lastTsRef.current = ts;
            const a = 1 - Math.exp(-speed * dt); // exponential approach
            const next = valueRef.current + (targetRef.current - valueRef.current) * a;
            valueRef.current = Math.abs(next - targetRef.current) < 0.0005
                ? targetRef.current
                : next;
            setValue(valueRef.current);
            raf = requestAnimationFrame(tick);
        };
        raf = requestAnimationFrame(tick);
        return () => cancelAnimationFrame(raf);
    }, [speed]);
    return (_jsx("div", { className: "h-1.5 rounded-full bg-white/10 overflow-hidden", children: _jsx("div", { className: "h-full " + (className ?? "bg-primary"), style: { width: `${value * 100}%` } }) }));
}
const TOP_BAR_LABELS = {
    ready_plant: "Ready to Plant",
    needs_water: "Needs Water",
    ready_harvest: "Ready to Harvest",
    growing: "Total grow progress",
};
function App() {
    const [mode, setMode] = useState("idle");
    const [heading, setHeading] = useState(0);
    const [waterLevel, setWaterLevel] = useState(1.0);
    const [plantWaterLevel, setPlantWaterLevel] = useState(0.0);
    const [showPlantWater, setShowPlantWater] = useState(false);
    const [plotStatus, setPlotStatus] = useState(null);
    useNuiEvent("plotStatus", (data) => {
        if (!data || !data.visible) {
            setPlotStatus(null);
        }
        else {
            setPlotStatus(data);
        }
    });
    const rootRef = useRef(null);
    const heldRef = useRef(new Set());
    // ─── NUI events from Lua ───────────────────────────────────────────────
    useNuiEvent("openCutting", (data) => {
        setHeading(data?.plantHeading ?? 0);
        setMode("cutting");
        requestAnimationFrame(() => rootRef.current?.focus());
    });
    useNuiEvent("closeCutting", () => {
        setMode("idle");
        heldRef.current.clear();
    });
    useNuiEvent("openWatering", (data) => {
        setWaterLevel(data?.level ?? 1.0);
        setMode("watering");
        requestAnimationFrame(() => rootRef.current?.focus());
    });
    useNuiEvent("closeWatering", () => {
        setMode("idle");
        heldRef.current.clear();
    });
    useNuiEvent("wateringLevel", (data) => {
        if (data?.level !== undefined)
            setWaterLevel(data.level);
    });
    useNuiEvent("wateringPlantLevel", (data) => {
        if (data?.level !== undefined)
            setPlantWaterLevel(data.level);
        if (data?.show !== undefined)
            setShowPlantWater(data.show);
    });
    useNuiEvent("openPlanting", () => {
        setMode("planting");
        requestAnimationFrame(() => rootRef.current?.focus());
    });
    useNuiEvent("closePlanting", () => {
        setMode("idle");
        heldRef.current.clear();
    });
    useEffect(() => {
        rootRef.current?.focus();
    }, []);
    // ─── Cutting tick: forward A/D rotation + cursor stream ────────────────
    useEffect(() => {
        if (mode !== "cutting")
            return;
        const ROTATE_PER_TICK = 2.5;
        const tick = window.setInterval(() => {
            if (heldRef.current.has("KeyA")) {
                fetchNui("rotate", { delta: ROTATE_PER_TICK }).then((r) => r?.heading !== undefined && setHeading(r.heading));
            }
            if (heldRef.current.has("KeyD")) {
                fetchNui("rotate", { delta: -ROTATE_PER_TICK }).then((r) => r?.heading !== undefined && setHeading(r.heading));
            }
            // Stream cursor coords for the cursor-driven scissors prop.
            fetchNui("cuttingInput", {
                cursorX: cursorRef.current.x,
                cursorY: cursorRef.current.y,
            });
        }, 16);
        return () => window.clearInterval(tick);
    }, [mode]);
    // ─── Watering tick: forward cursor + held keys at 60Hz ─────────────────
    useEffect(() => {
        if (mode !== "watering")
            return;
        const tick = window.setInterval(() => {
            fetchNui("wateringInput", {
                cursorX: cursorRef.current.x,
                cursorY: cursorRef.current.y,
                heldKeys: [...heldRef.current],
            });
        }, 16);
        return () => window.clearInterval(tick);
    }, [mode]);
    // ─── Planting tick: same stream shape as watering (cursor + A/D) ──────
    useEffect(() => {
        if (mode !== "planting")
            return;
        const tick = window.setInterval(() => {
            fetchNui("plantingInput", {
                cursorX: cursorRef.current.x,
                cursorY: cursorRef.current.y,
                heldKeys: [...heldRef.current],
            });
        }, 16);
        return () => window.clearInterval(tick);
    }, [mode]);
    const cursorRef = useRef({ x: 0.5, y: 0.5 });
    const onMouseMove = (e) => {
        cursorRef.current.x = e.clientX / window.innerWidth;
        cursorRef.current.y = e.clientY / window.innerHeight;
    };
    const onKeyDown = (e) => {
        if (e.code === "Escape") {
            if (mode === "cutting") {
                fetchNui("close");
                setMode("idle");
            }
            else if (mode === "watering") {
                fetchNui("wateringClose");
                setMode("idle");
            }
            else if (mode === "planting") {
                fetchNui("plantingClose");
                setMode("idle");
            }
            return;
        }
        if (e.code === "KeyA" || e.code === "KeyD") {
            heldRef.current.add(e.code);
        }
    };
    const onKeyUp = (e) => {
        heldRef.current.delete(e.code);
    };
    // Cutting fires on click (single-shot snip). Planting needs press +
    // release: pressing on the capsule grabs it, releasing lets go, so
    // forward both edges with a `pressed` flag for Lua to route.
    const onClick = (e) => {
        if (mode !== "cutting")
            return;
        const x = e.clientX / window.innerWidth;
        const y = e.clientY / window.innerHeight;
        fetchNui("clickAt", { x, y });
    };
    const onMouseDown = (e) => {
        if (mode !== "planting" || e.button !== 0)
            return;
        const x = e.clientX / window.innerWidth;
        const y = e.clientY / window.innerHeight;
        fetchNui("plantingClick", { x, y, pressed: true });
    };
    const onMouseUp = (e) => {
        if (mode !== "planting" || e.button !== 0)
            return;
        const x = e.clientX / window.innerWidth;
        const y = e.clientY / window.innerHeight;
        fetchNui("plantingClick", { x, y, pressed: false });
    };
    return (_jsxs("div", { ref: rootRef, tabIndex: 0, autoFocus: true, onKeyDown: onKeyDown, onKeyUp: onKeyUp, onClick: onClick, onMouseDown: onMouseDown, onMouseUp: onMouseUp, onMouseMove: onMouseMove, onBlur: () => requestAnimationFrame(() => rootRef.current?.focus()), className: "dark fixed inset-0 outline-none", children: [plotStatus && plotStatus.visible && plotStatus.x != null && plotStatus.y != null && (_jsx("div", { className: "absolute pointer-events-none", style: {
                    left: `${plotStatus.x * 100}%`,
                    top: `${plotStatus.y * 100}%`,
                    transform: "translate(-50%, -100%)",
                    // Smooth out the projection-frame steps from Lua's
                    // 30Hz tick. Linear so the motion tracks the
                    // underlying world position without easing curves.
                    transition: "left 50ms linear, top 50ms linear",
                    willChange: "left, top",
                }, children: _jsx(Card, { className: "bg-black/55 border-white/10 min-w-[220px]", children: _jsxs(CardContent, { className: "py-2.5 px-3 space-y-2", children: [_jsxs("div", { className: "flex items-center gap-2", children: [_jsx(Sprout, { className: "h-4 w-4 text-primary" }), _jsx("span", { className: "text-sm font-medium", children: plotStatus.drug })] }), _jsxs("div", { className: "space-y-1", children: [_jsxs("div", { className: "flex items-center justify-between text-[11px] tabular-nums", children: [_jsx("span", { className: "text-muted-foreground", children: plotStatus.status ? TOP_BAR_LABELS[plotStatus.status] : "—" }), plotStatus.status === "growing" && (_jsxs("span", { className: "text-muted-foreground", children: [Math.round((plotStatus.growProgress ?? 0) * 100), "%"] })), plotStatus.status === "ready_harvest" && plotStatus.budsLeft !== undefined && (_jsxs("span", { className: "text-muted-foreground", children: [plotStatus.budsLeft, " buds"] }))] }), _jsx(SmoothBar, { target: plotStatus.status === "growing"
                                            ? plotStatus.growProgress ?? 0
                                            : plotStatus.status === "ready_harvest"
                                                ? 1
                                                : plotStatus.status === "needs_water"
                                                    ? 1
                                                    : plotStatus.status === "ready_plant"
                                                        ? 1
                                                        : 0, className: plotStatus.status === "needs_water"
                                            ? "bg-amber-400"
                                            : plotStatus.status === "ready_plant"
                                                ? "bg-emerald-400"
                                                : "bg-primary" })] }), plotStatus.showWater && (_jsxs("div", { className: "space-y-1", children: [_jsxs("div", { className: "flex items-center justify-between text-[11px] tabular-nums", children: [_jsxs("span", { className: "text-muted-foreground flex items-center gap-1", children: [_jsx(Droplet, { className: "h-3 w-3 text-sky-400" }), "Water"] }), _jsxs("span", { className: "text-muted-foreground", children: [Math.round((plotStatus.waterProgress ?? 0) * 100), "%"] })] }), _jsx(SmoothBar, { target: plotStatus.waterProgress ?? 0, className: "bg-sky-400" })] }))] }) }) })), mode === "cutting" && (_jsx("div", { className: "absolute inset-x-0 bottom-10 flex justify-center pointer-events-none", children: _jsx(Card, { className: "w-[460px] bg-black/55 border-white/10", children: _jsxs(CardContent, { className: "flex items-center justify-between gap-4 py-3", children: [_jsxs("div", { className: "flex items-center gap-2", children: [_jsx(Leaf, { className: "h-4 w-4 text-primary" }), _jsxs("span", { className: "text-sm", children: ["Hold ", _jsx("kbd", { className: "px-1 rounded bg-muted text-xs", children: "A" }), " /", " ", _jsx("kbd", { className: "px-1 rounded bg-muted text-xs", children: "D" }), " to rotate \u00B7 click a bud to cut"] })] }), _jsxs("span", { className: "text-xs text-muted-foreground tabular-nums", children: [heading.toFixed(0), "\u00B0"] })] }) }) })), mode === "watering" && (_jsxs(_Fragment, { children: [_jsx("div", { className: "absolute top-6 right-6 pointer-events-none", children: _jsx(Card, { className: "bg-black/55 border-white/10 w-[180px]", children: _jsxs(CardContent, { className: "py-3 px-4", children: [_jsxs("div", { className: "flex items-center gap-2 mb-2", children: [_jsx(Droplet, { className: "h-4 w-4 text-sky-400" }), _jsx("span", { className: "text-xs text-muted-foreground", children: "Water" }), _jsxs("span", { className: "ml-auto text-xs tabular-nums", children: [Math.round(waterLevel * 100), "%"] })] }), _jsx(SmoothBar, { target: waterLevel, className: "bg-sky-400", speed: 10 })] }) }) }), _jsxs("div", { className: "absolute inset-x-0 bottom-10 flex flex-col items-center gap-3 pointer-events-none", children: [showPlantWater && (_jsx(Card, { className: "w-[280px] bg-black/55 border-white/10", children: _jsxs(CardContent, { className: "py-3 px-4", children: [_jsxs("div", { className: "flex items-center gap-2 mb-2", children: [_jsx(Sprout, { className: "h-4 w-4 text-emerald-400" }), _jsx("span", { className: "text-xs text-muted-foreground", children: "Plant Water" }), _jsxs("span", { className: "ml-auto text-xs tabular-nums", children: [Math.round(plantWaterLevel * 100), "%"] })] }), _jsx(SmoothBar, { target: plantWaterLevel, className: "bg-emerald-400" })] }) })), _jsx(Card, { className: "w-[520px] bg-black/55 border-white/10", children: _jsxs(CardContent, { className: "flex items-center gap-3 py-3", children: [_jsx(Droplet, { className: "h-4 w-4 text-sky-400" }), _jsxs("span", { className: "text-sm", children: ["Move the cursor to position the pitcher \u00B7 hold", " ", _jsx("kbd", { className: "px-1 rounded bg-muted text-xs", children: "A" }), " /", " ", _jsx("kbd", { className: "px-1 rounded bg-muted text-xs", children: "D" }), " to tilt and pour \u00B7", " ", _jsx("kbd", { className: "px-1 rounded bg-muted text-xs", children: "Esc" }), " to finish"] })] }) })] })] }))] }));
}
export default App;
