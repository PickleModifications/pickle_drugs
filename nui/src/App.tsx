import { useEffect, useRef, useState } from "react";
import { Droplet, Leaf, Sprout } from "lucide-react";

import { Card, CardContent } from "@/components/ui/card";
import { fetchNui, useNuiEvent } from "@/lib/nui";

type CuttingPayload = { plantHeading?: number };
type WateringPayload = { plotId: string; level?: number };

type PlotStatus = {
    visible: boolean;
    x?: number;        // 0..1 normalised screen X
    y?: number;        // 0..1 normalised screen Y
    drug?: string;
    status?: "ready_plant" | "needs_water" | "ready_harvest" | "growing";
    growProgress?: number;   // 0..1
    waterProgress?: number;  // 0..1 reservoir level
    showWater?: boolean;
    budsLeft?: number;
};

type Mode = "idle" | "cutting" | "watering" | "planting";

type PlantingPayload = { plotId: string };

/**
 * Bar that rAF-lerps its visible width toward the target value, so jumpy
 * inputs (Lua bursts, percentages leaping in one tick) animate smoothly
 * instead of snapping. `target` is 0..1.
 */
function SmoothBar({
    target,
    className,
    speed = 6,
}: {
    target: number;
    className?: string;
    speed?: number; // higher = snappier, lower = smoother
}) {
    const [value, setValue] = useState(target);
    const valueRef = useRef(target);
    const targetRef = useRef(target);
    const lastTsRef = useRef<number | null>(null);

    useEffect(() => {
        targetRef.current = Math.max(0, Math.min(1, target));
    }, [target]);

    useEffect(() => {
        let raf = 0;
        const tick = (ts: number) => {
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

    return (
        <div className="h-1.5 rounded-full bg-white/10 overflow-hidden">
            <div
                className={"h-full " + (className ?? "bg-primary")}
                style={{ width: `${value * 100}%` }}
            />
        </div>
    );
}

const TOP_BAR_LABELS: Record<NonNullable<PlotStatus["status"]>, string> = {
    ready_plant:   "Ready to Plant",
    needs_water:   "Needs Water",
    ready_harvest: "Ready to Harvest",
    growing:       "Total grow progress",
};

function App() {
    const [mode, setMode] = useState<Mode>("idle");
    const [heading, setHeading] = useState(0);
    const [waterLevel, setWaterLevel] = useState(1.0);
    const [plantWaterLevel, setPlantWaterLevel] = useState(0.0);
    const [showPlantWater, setShowPlantWater] = useState(false);
    const [plotStatus, setPlotStatus] = useState<PlotStatus | null>(null);

    useNuiEvent<PlotStatus>("plotStatus", (data) => {
        if (!data || !data.visible) {
            setPlotStatus(null);
        } else {
            setPlotStatus(data);
        }
    });

    const rootRef = useRef<HTMLDivElement | null>(null);
    const heldRef = useRef<Set<string>>(new Set());

    // ─── NUI events from Lua ───────────────────────────────────────────────
    useNuiEvent<CuttingPayload>("openCutting", (data) => {
        setHeading(data?.plantHeading ?? 0);
        setMode("cutting");
        requestAnimationFrame(() => rootRef.current?.focus());
    });
    useNuiEvent<void>("closeCutting", () => {
        setMode("idle");
        heldRef.current.clear();
    });

    useNuiEvent<WateringPayload>("openWatering", (data) => {
        setWaterLevel(data?.level ?? 1.0);
        setMode("watering");
        requestAnimationFrame(() => rootRef.current?.focus());
    });
    useNuiEvent<void>("closeWatering", () => {
        setMode("idle");
        heldRef.current.clear();
    });
    useNuiEvent<{ level: number }>("wateringLevel", (data) => {
        if (data?.level !== undefined) setWaterLevel(data.level);
    });
    useNuiEvent<{ level: number; show?: boolean }>("wateringPlantLevel", (data) => {
        if (data?.level !== undefined) setPlantWaterLevel(data.level);
        if (data?.show !== undefined) setShowPlantWater(data.show);
    });

    useNuiEvent<PlantingPayload>("openPlanting", () => {
        setMode("planting");
        requestAnimationFrame(() => rootRef.current?.focus());
    });
    useNuiEvent<void>("closePlanting", () => {
        setMode("idle");
        heldRef.current.clear();
    });

    useEffect(() => {
        rootRef.current?.focus();
    }, []);

    // ─── Cutting tick: forward A/D rotation + cursor stream ────────────────
    useEffect(() => {
        if (mode !== "cutting") return;
        const ROTATE_PER_TICK = 2.5;
        const tick = window.setInterval(() => {
            if (heldRef.current.has("KeyA")) {
                fetchNui<{ heading: number }>("rotate", { delta: ROTATE_PER_TICK }).then(
                    (r) => r?.heading !== undefined && setHeading(r.heading),
                );
            }
            if (heldRef.current.has("KeyD")) {
                fetchNui<{ heading: number }>("rotate", { delta: -ROTATE_PER_TICK }).then(
                    (r) => r?.heading !== undefined && setHeading(r.heading),
                );
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
        if (mode !== "watering") return;
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
        if (mode !== "planting") return;
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
    const onMouseMove = (e: React.MouseEvent<HTMLDivElement>) => {
        cursorRef.current.x = e.clientX / window.innerWidth;
        cursorRef.current.y = e.clientY / window.innerHeight;
    };

    const onKeyDown = (e: React.KeyboardEvent<HTMLDivElement>) => {
        if (e.code === "Escape") {
            if (mode === "cutting") {
                fetchNui("close");
                setMode("idle");
            } else if (mode === "watering") {
                fetchNui("wateringClose");
                setMode("idle");
            } else if (mode === "planting") {
                fetchNui("plantingClose");
                setMode("idle");
            }
            return;
        }
        if (e.code === "KeyA" || e.code === "KeyD") {
            heldRef.current.add(e.code);
        }
    };

    const onKeyUp = (e: React.KeyboardEvent<HTMLDivElement>) => {
        heldRef.current.delete(e.code);
    };

    // Cutting fires on click (single-shot snip). Planting needs press +
    // release: pressing on the capsule grabs it, releasing lets go, so
    // forward both edges with a `pressed` flag for Lua to route.
    const onClick = (e: React.MouseEvent<HTMLDivElement>) => {
        if (mode !== "cutting") return;
        const x = e.clientX / window.innerWidth;
        const y = e.clientY / window.innerHeight;
        fetchNui("clickAt", { x, y });
    };
    const onMouseDown = (e: React.MouseEvent<HTMLDivElement>) => {
        if (mode !== "planting" || e.button !== 0) return;
        const x = e.clientX / window.innerWidth;
        const y = e.clientY / window.innerHeight;
        fetchNui("plantingClick", { x, y, pressed: true });
    };
    const onMouseUp = (e: React.MouseEvent<HTMLDivElement>) => {
        if (mode !== "planting" || e.button !== 0) return;
        const x = e.clientX / window.innerWidth;
        const y = e.clientY / window.innerHeight;
        fetchNui("plantingClick", { x, y, pressed: false });
    };

    return (
        <div
            ref={rootRef}
            tabIndex={0}
            autoFocus
            onKeyDown={onKeyDown}
            onKeyUp={onKeyUp}
            onClick={onClick}
            onMouseDown={onMouseDown}
            onMouseUp={onMouseUp}
            onMouseMove={onMouseMove}
            onBlur={() => requestAnimationFrame(() => rootRef.current?.focus())}
            className="dark fixed inset-0 outline-none"
        >
            {/* Floating plot status — projected screen coords from Lua. The
                pointer-events-none wrapper lets clicks pass through to game. */}
            {plotStatus && plotStatus.visible && plotStatus.x != null && plotStatus.y != null && (
                <div
                    className="absolute pointer-events-none"
                    style={{
                        left: `${plotStatus.x * 100}%`,
                        top: `${plotStatus.y * 100}%`,
                        transform: "translate(-50%, -100%)",
                        // Smooth out the projection-frame steps from Lua's
                        // 30Hz tick. Linear so the motion tracks the
                        // underlying world position without easing curves.
                        transition: "left 50ms linear, top 50ms linear",
                        willChange: "left, top",
                    }}
                >
                    <Card className="bg-black/55 border-white/10 min-w-[220px]">
                        <CardContent className="py-2.5 px-3 space-y-2">
                            <div className="flex items-center gap-2">
                                <Sprout className="h-4 w-4 text-primary" />
                                <span className="text-sm font-medium">{plotStatus.drug}</span>
                            </div>

                            {/* Top bar — label changes with status; bar fills only in
                                "growing". The other states are pure status text. */}
                            <div className="space-y-1">
                                <div className="flex items-center justify-between text-[11px] tabular-nums">
                                    <span className="text-muted-foreground">
                                        {plotStatus.status ? TOP_BAR_LABELS[plotStatus.status] : "—"}
                                    </span>
                                    {plotStatus.status === "growing" && (
                                        <span className="text-muted-foreground">
                                            {Math.round((plotStatus.growProgress ?? 0) * 100)}%
                                        </span>
                                    )}
                                    {plotStatus.status === "ready_harvest" && plotStatus.budsLeft !== undefined && (
                                        <span className="text-muted-foreground">
                                            {plotStatus.budsLeft} buds
                                        </span>
                                    )}
                                </div>
                                <SmoothBar
                                    target={
                                        plotStatus.status === "growing"
                                            ? plotStatus.growProgress ?? 0
                                            : plotStatus.status === "ready_harvest"
                                            ? 1
                                            : plotStatus.status === "needs_water"
                                            ? 1
                                            : plotStatus.status === "ready_plant"
                                            ? 1
                                            : 0
                                    }
                                    className={
                                        plotStatus.status === "needs_water"
                                            ? "bg-amber-400"
                                            : plotStatus.status === "ready_plant"
                                            ? "bg-emerald-400"
                                            : "bg-primary"
                                    }
                                />
                            </div>

                            {/* Bottom bar — water progress as a live percentage. Hidden
                                when the plot has no water requirement (stage 0/3). */}
                            {plotStatus.showWater && (
                                <div className="space-y-1">
                                    <div className="flex items-center justify-between text-[11px] tabular-nums">
                                        <span className="text-muted-foreground flex items-center gap-1">
                                            <Droplet className="h-3 w-3 text-sky-400" />
                                            Water
                                        </span>
                                        <span className="text-muted-foreground">
                                            {Math.round((plotStatus.waterProgress ?? 0) * 100)}%
                                        </span>
                                    </div>
                                    <SmoothBar
                                        target={plotStatus.waterProgress ?? 0}
                                        className="bg-sky-400"
                                    />
                                </div>
                            )}
                        </CardContent>
                    </Card>
                </div>
            )}

            {mode === "cutting" && (
                <div className="absolute inset-x-0 bottom-10 flex justify-center pointer-events-none">
                    <Card className="w-[460px] bg-black/55 border-white/10">
                        <CardContent className="flex items-center justify-between gap-4 py-3">
                            <div className="flex items-center gap-2">
                                <Leaf className="h-4 w-4 text-primary" />
                                <span className="text-sm">
                                    Hold <kbd className="px-1 rounded bg-muted text-xs">A</kbd> /{" "}
                                    <kbd className="px-1 rounded bg-muted text-xs">D</kbd> to rotate · click a bud to cut
                                </span>
                            </div>
                            <span className="text-xs text-muted-foreground tabular-nums">
                                {heading.toFixed(0)}°
                            </span>
                        </CardContent>
                    </Card>
                </div>
            )}

            {mode === "watering" && (
                <>
                    {/* Top-right water meter */}
                    <div className="absolute top-6 right-6 pointer-events-none">
                        <Card className="bg-black/55 border-white/10 w-[180px]">
                            <CardContent className="py-3 px-4">
                                <div className="flex items-center gap-2 mb-2">
                                    <Droplet className="h-4 w-4 text-sky-400" />
                                    <span className="text-xs text-muted-foreground">Water</span>
                                    <span className="ml-auto text-xs tabular-nums">
                                        {Math.round(waterLevel * 100)}%
                                    </span>
                                </div>
                                <SmoothBar target={waterLevel} className="bg-sky-400" speed={10} />
                            </CardContent>
                        </Card>
                    </div>
                    {/* Bottom: plant water reservoir + hint. The reservoir card
                        only shows when there's actually a plant to water — the
                        server rejects pours pre-stage-1 anyway. */}
                    <div className="absolute inset-x-0 bottom-10 flex flex-col items-center gap-3 pointer-events-none">
                        {showPlantWater && (
                            <Card className="w-[280px] bg-black/55 border-white/10">
                                <CardContent className="py-3 px-4">
                                    <div className="flex items-center gap-2 mb-2">
                                        <Sprout className="h-4 w-4 text-emerald-400" />
                                        <span className="text-xs text-muted-foreground">Plant Water</span>
                                        <span className="ml-auto text-xs tabular-nums">
                                            {Math.round(plantWaterLevel * 100)}%
                                        </span>
                                    </div>
                                    <SmoothBar target={plantWaterLevel} className="bg-emerald-400" />
                                </CardContent>
                            </Card>
                        )}
                        <Card className="w-[520px] bg-black/55 border-white/10">
                            <CardContent className="flex items-center gap-3 py-3">
                                <Droplet className="h-4 w-4 text-sky-400" />
                                <span className="text-sm">
                                    Move the cursor to position the pitcher · hold{" "}
                                    <kbd className="px-1 rounded bg-muted text-xs">A</kbd> /{" "}
                                    <kbd className="px-1 rounded bg-muted text-xs">D</kbd> to tilt and pour ·{" "}
                                    <kbd className="px-1 rounded bg-muted text-xs">Esc</kbd> to finish
                                </span>
                            </CardContent>
                        </Card>
                    </div>
                </>
            )}
        </div>
    );
}

export default App;
