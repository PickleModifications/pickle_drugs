import { useEffect, useMemo, useRef, useState } from "react";
import {
    ChevronDown,
    Droplet,
    Eye,
    Leaf,
    Mountain,
    Scissors,
    Sprout,
    X,
} from "lucide-react";

import { fetchNui, useNuiEvent } from "@/lib/nui";

// ─── Types ────────────────────────────────────────────────────────────────

type ActionId =
    | "menu"
    | "soiling"
    | "planting"
    | "watering"
    | "cutting"
    | "inspect";

type StatusKey =
    | "needs_soil"
    | "ready_plant"
    | "needs_water"
    | "ready_harvest"
    | "growing";

type ActionEntry = {
    id: ActionId;
    label: string;
    icon: string;
    available: boolean;
    reason?: string;
};

type SceneStatus = {
    drug: string;
    statusKey: StatusKey;
    stage: number;
    stageMax: number;
    growProgress: number;
    waterProgress: number;
    showWater: boolean;
    budsLeft: number;
    etaMs?: number | null;
    activeAction: ActionId;
    actions: ActionEntry[];
};

// ─── SmoothBar ────────────────────────────────────────────────────────────

function SmoothBar({
    target,
    className,
    speed = 6,
}: {
    target: number;
    className?: string;
    speed?: number;
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
            const a = 1 - Math.exp(-speed * dt);
            const next =
                valueRef.current +
                (targetRef.current - valueRef.current) * a;
            valueRef.current =
                Math.abs(next - targetRef.current) < 0.0005
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
                className={"h-full " + (className ?? "bg-white/70")}
                style={{ width: `${value * 100}%` }}
            />
        </div>
    );
}

// ─── Helpers ─────────────────────────────────────────────────────────────

const STATUS_LABEL: Record<StatusKey, string> = {
    needs_soil: "Needs Soil",
    ready_plant: "Needs Seed",
    needs_water: "Needs Water — growth paused",
    ready_harvest: "Ready to Harvest",
    growing: "Growing",
};

const STATUS_ACCENT: Record<StatusKey, string> = {
    needs_soil: "bg-orange-500",
    ready_plant: "bg-emerald-400",
    needs_water: "bg-amber-400",
    ready_harvest: "bg-fuchsia-400",
    growing: "bg-emerald-500",
};

function formatEta(ms: number | null | undefined): string | null {
    if (ms == null) return null;
    if (ms <= 0) return "ready";
    const s = Math.ceil(ms / 1000);
    if (s < 60) return `${s}s`;
    const m = Math.floor(s / 60);
    const rem = s % 60;
    return `${m}m ${rem}s`;
}

const ICON_MAP: Record<string, React.ElementType> = {
    mound: Mountain,
    sprout: Sprout,
    droplet: Droplet,
    scissors: Scissors,
    eye: Eye,
};

function ActionIcon({ name, className }: { name: string; className?: string }) {
    const Comp = ICON_MAP[name] ?? Sprout;
    return <Comp className={className ?? "h-5 w-5"} />;
}

// Per-action tone tokens. Resting state is neutral white; `hover` previews
// the action's color so the player can feel the affordance, and `active`
// shipps that color when the action is currently running.
const NEUTRAL_ENABLED =
    "text-white/90 bg-white/[0.06] ring-white/30 ";

const TONES: Record<ActionId, { hover: string; active: string }> = {
    soiling: {
        hover:
            "hover:bg-orange-500/25 hover:ring-orange-400/70 hover:text-orange-50 hover:shadow-[0_0_14px_-6px_rgba(251,146,60,0.7)]",
        active:
            "bg-orange-500/30 ring-orange-400/70 text-orange-50 shadow-[0_0_18px_-6px_rgba(251,146,60,0.75)]",
    },
    planting: {
        hover:
            "hover:bg-emerald-500/25 hover:ring-emerald-400/70 hover:text-emerald-50 hover:shadow-[0_0_14px_-6px_rgba(52,211,153,0.7)]",
        active:
            "bg-emerald-500/30 ring-emerald-400/70 text-emerald-50 shadow-[0_0_18px_-6px_rgba(52,211,153,0.75)]",
    },
    watering: {
        hover:
            "hover:bg-sky-500/25 hover:ring-sky-400/70 hover:text-sky-50 hover:shadow-[0_0_14px_-6px_rgba(56,189,248,0.7)]",
        active:
            "bg-sky-500/30 ring-sky-400/70 text-sky-50 shadow-[0_0_18px_-6px_rgba(56,189,248,0.75)]",
    },
    cutting: {
        hover:
            "hover:bg-fuchsia-500/25 hover:ring-fuchsia-400/70 hover:text-fuchsia-50 hover:shadow-[0_0_14px_-6px_rgba(232,121,249,0.7)]",
        active:
            "bg-fuchsia-500/30 ring-fuchsia-400/70 text-fuchsia-50 shadow-[0_0_18px_-6px_rgba(232,121,249,0.75)]",
    },
    inspect: {
        hover:
            "hover:bg-violet-500/25 hover:ring-violet-400/70 hover:text-violet-50 hover:shadow-[0_0_14px_-6px_rgba(167,139,250,0.7)]",
        active:
            "bg-violet-500/30 ring-violet-400/70 text-violet-50 shadow-[0_0_18px_-6px_rgba(167,139,250,0.75)]",
    },
    menu: { hover: "", active: "" },
};

// ─── Status section ──────────────────────────────────────────────────────

function StatusSection({ status }: { status: SceneStatus }) {
    const eta = formatEta(status.etaMs);
    const dryWarn =
        status.statusKey !== "needs_soil" &&
        status.statusKey !== "ready_plant" &&
        status.waterProgress < 0.2 &&
        status.showWater;

    return (
        <div className="px-5 py-3 flex items-center gap-5">
            <div className="flex items-center gap-2 min-w-0">
                <div className="h-9 w-9 rounded-lg bg-emerald-500/15 ring-1 ring-emerald-500/30 flex items-center justify-center shrink-0">
                    <Leaf className="h-5 w-5 text-emerald-300" />
                </div>
                <div className="flex flex-col leading-tight min-w-0">
                    <span className="text-sm font-medium text-white truncate">
                        {status.drug}
                    </span>
                    <span className="text-[10px] uppercase tracking-wider text-white/50 tabular-nums">
                        Stage {status.stage} / {status.stageMax}
                    </span>
                </div>
            </div>

            <div className="w-[280px] flex flex-col gap-1.5">
                <div className="space-y-1 min-w-0">
                    <div className="flex items-center justify-between text-[11px]">
                        <span className="text-white/60 truncate">
                            {STATUS_LABEL[status.statusKey]}
                        </span>
                        <span className="text-white/60 tabular-nums shrink-0 ml-2">
                            {status.statusKey === "growing"
                                ? `${Math.round(status.growProgress * 100)}%`
                                : status.statusKey === "ready_harvest"
                                    ? `${status.budsLeft} buds`
                                    : ""}
                        </span>
                    </div>
                    <SmoothBar
                        target={
                            status.statusKey === "growing"
                                ? status.growProgress
                                : 1
                        }
                        className={STATUS_ACCENT[status.statusKey]}
                    />
                </div>

                {status.showWater && (
                    <div className="space-y-1 min-w-0">
                        <div className="flex items-center justify-between text-[11px]">
                            <span className="text-white/60 flex items-center gap-1">
                                <Droplet className="h-3 w-3 text-sky-400" />
                                Water
                            </span>
                            <span className="text-white/60 tabular-nums">
                                {Math.round(status.waterProgress * 100)}%
                            </span>
                        </div>
                        <SmoothBar
                            target={status.waterProgress}
                            className={dryWarn ? "bg-red-500" : "bg-sky-400"}
                        />
                    </div>
                )}

                {eta && status.statusKey === "growing" && (
                    <div className="flex items-center justify-between text-[11px] tabular-nums">
                        <span className="text-white/50">Next stage in</span>
                        <span className="text-white/70">{eta}</span>
                    </div>
                )}
                {dryWarn && (
                    <div className="text-[11px] text-red-300">
                        Reservoir nearly empty — growth pauses when dry.
                    </div>
                )}
            </div>
        </div>
    );
}

// ─── Actions section ─────────────────────────────────────────────────────

function ActionsSection({
    actions,
    activeAction,
    onSelect,
    onCancelAction,
    onClose,
}: {
    actions: ActionEntry[];
    activeAction: ActionId;
    onSelect: (id: ActionId) => void;
    onCancelAction: () => void;
    onClose: () => void;
}) {
    const inAction = activeAction !== "menu";

    return (
        <div className="px-3 py-3 flex items-center gap-2">
            <div className="flex items-center gap-1.5">
                {actions.map((a) => {
                    const isActive = activeAction === a.id;
                    const disabled = !a.available || (inAction && !isActive);
                    const tone = TONES[a.id] ?? TONES.menu;
                    return (
                        <button
                            key={a.id}
                            disabled={disabled}
                            onClick={() =>
                                isActive ? onCancelAction() : onSelect(a.id)
                            }
                            title={a.reason ?? a.label}
                            className={
                                "group relative flex flex-col items-center justify-center gap-1 rounded-lg px-3 py-2 min-w-[68px] ring-1 transition-all " +
                                (isActive
                                    ? tone.active + " "
                                    : disabled
                                        ? "text-white/25 cursor-not-allowed bg-white/[0.02] ring-white/20 "
                                        : NEUTRAL_ENABLED + tone.hover + " ")
                            }
                        >
                            <ActionIcon name={a.icon} className="h-5 w-5" />
                            <span className="text-[10px] font-medium leading-none">
                                {a.label}
                            </span>
                            {!a.available && a.reason && (
                                <span className="absolute -top-7 left-1/2 -translate-x-1/2 text-[10px] text-white/70 bg-black/80 px-2 py-0.5 rounded whitespace-nowrap opacity-0 group-hover:opacity-100 transition-opacity pointer-events-none ring-1 ring-white/10">
                                    {a.reason}
                                </span>
                            )}
                        </button>
                    );
                })}
            </div>

            <div className="h-10 w-px bg-white/10 mx-1" />
            {/* Single trailing button toggles between Close (in menu) and
                Back (while in a sub-action). Always present so the console
                width is constant. */}
            {inAction ? (
                <button
                    onClick={onCancelAction}
                    className="flex flex-col items-center justify-center gap-1 rounded-lg px-3 py-2 min-w-[68px] bg-amber-500/15 ring-1 ring-amber-400/50 text-amber-200 hover:bg-amber-500/25 hover:ring-amber-400/70 transition-colors"
                    title="Back to menu"
                >
                    <ChevronDown className="h-5 w-5 rotate-90" />
                    <span className="text-[10px] font-medium leading-none">
                        Back
                    </span>
                </button>
            ) : (
                <button
                    onClick={onClose}
                    className="flex flex-col items-center justify-center gap-1 rounded-lg px-3 py-2 min-w-[68px] bg-white/[0.06] ring-1 ring-white/30 text-white/80 hover:bg-red-500/20 hover:text-red-100 hover:ring-red-400/60 transition-colors"
                    title="Close"
                >
                    <X className="h-5 w-5" />
                    <span className="text-[10px] font-medium leading-none">
                        Close
                    </span>
                </button>
            )}
        </div>
    );
}

// ─── Action hint ─────────────────────────────────────────────────────────

function ActionHintInline({ activeAction }: { activeAction: ActionId }) {
    if (activeAction === "menu") {
        return (
            <span className="text-[11px] text-white/50 italic">
                Pick an action to begin
            </span>
        );
    }
    let content: React.ReactNode = null;
    if (activeAction === "cutting") {
        content = (
            <>
                Hold <Kbd>A</Kbd> / <Kbd>D</Kbd> to rotate · click a bud to cut
            </>
        );
    } else if (activeAction === "watering") {
        content = (
            <>
                Move the cursor to position the pitcher · hold <Kbd>A</Kbd> /{" "}
                <Kbd>D</Kbd> to tilt and pour
            </>
        );
    } else if (activeAction === "soiling") {
        content = (
            <>
                Hold left-click and drag to rip the bag · then move it over the pot
                and tilt with <Kbd>A</Kbd> / <Kbd>D</Kbd> to pour
            </>
        );
    } else if (activeAction === "planting") {
        content = (
            <>
                Click the cap to pop it · grab the capsule and tilt with{" "}
                <Kbd>A</Kbd> / <Kbd>D</Kbd> to drop the seed · click each rubble
                pile to bury
            </>
        );
    } else if (activeAction === "inspect") {
        content = (
            <>
                Inspecting your plant — press <Kbd>Esc</Kbd> or Back to return
            </>
        );
    }
    return (
        <span className="text-[11px] text-white/80 truncate">{content}</span>
    );
}

function Kbd({ children }: { children: React.ReactNode }) {
    // h-[18px] + leading-none + align-middle keeps the chip from pushing the
    // surrounding line height — its visual size is independent of its layout
    // contribution.
    return (
        <kbd className="inline-flex items-center align-middle h-[18px] px-1.5 mx-0.5 rounded bg-white/10 ring-1 ring-white/15 text-[11px] font-mono leading-none">
            {children}
        </kbd>
    );
}

// ─── Watering meters (separate floater while in watering action) ─────────

function WateringMeters({
    pitcher,
    plantLevel,
    showPlant,
}: {
    pitcher: number;
    plantLevel: number;
    showPlant: boolean;
}) {
    return (
        <div className="absolute top-6 right-6 pointer-events-none">
            <div className="rounded-xl bg-black/60 ring-1 ring-white/10  px-4 py-3 w-[200px]">
                <div className="flex items-center gap-2 mb-2">
                    <Droplet className="h-4 w-4 text-sky-400" />
                    <span className="text-xs text-white/60">Pitcher</span>
                    <span className="ml-auto text-xs tabular-nums text-white/80">
                        {Math.round(pitcher * 100)}%
                    </span>
                </div>
                <SmoothBar target={pitcher} className="bg-sky-400" speed={10} />
                {showPlant && (
                    <>
                        <div className="flex items-center gap-2 mt-3 mb-2">
                            <Sprout className="h-4 w-4 text-emerald-400" />
                            <span className="text-xs text-white/60">Plant</span>
                            <span className="ml-auto text-xs tabular-nums text-white/80">
                                {Math.round(plantLevel * 100)}%
                            </span>
                        </div>
                        <SmoothBar
                            target={plantLevel}
                            className="bg-emerald-400"
                        />
                    </>
                )}
            </div>
        </div>
    );
}

// ─── App ─────────────────────────────────────────────────────────────────

function App() {
    const [open, setOpen] = useState(false);
    const [status, setStatus] = useState<SceneStatus | null>(null);

    const [pitcherLevel, setPitcherLevel] = useState(1.0);
    const [plantWaterLevel, setPlantWaterLevel] = useState(0.0);
    const [showPlantWater, setShowPlantWater] = useState(false);

    const rootRef = useRef<HTMLDivElement | null>(null);
    const heldRef = useRef<Set<string>>(new Set());
    const cursorRef = useRef({ x: 0.5, y: 0.5 });

    useNuiEvent<{ plotId: string; drug: string }>("openPlantScene", () => {
        setOpen(true);
        requestAnimationFrame(() => rootRef.current?.focus());
    });
    useNuiEvent<void>("closePlantScene", () => {
        setOpen(false);
        setStatus(null);
        heldRef.current.clear();
    });

    useNuiEvent<SceneStatus>("plantSceneStatus", (data) => {
        if (data) setStatus(data);
    });

    useNuiEvent<{ level: number }>("wateringLevel", (data) => {
        if (data?.level !== undefined) setPitcherLevel(data.level);
    });
    useNuiEvent<{ level: number; show?: boolean }>(
        "wateringPlantLevel",
        (data) => {
            if (data?.level !== undefined) setPlantWaterLevel(data.level);
            if (data?.show !== undefined) setShowPlantWater(data.show);
        },
    );

    useEffect(() => {
        if (!open) return;
        rootRef.current?.focus();
    }, [open]);

    const activeAction = status?.activeAction ?? "menu";

    useEffect(() => {
        if (!open || activeAction === "menu" || activeAction === "inspect") return;
        const tick = window.setInterval(() => {
            const payload = {
                cursorX: cursorRef.current.x,
                cursorY: cursorRef.current.y,
                heldKeys: [...heldRef.current],
            };
            if (activeAction === "cutting") {
                if (heldRef.current.has("KeyA")) fetchNui("rotate", { delta: 2.5 });
                if (heldRef.current.has("KeyD")) fetchNui("rotate", { delta: -2.5 });
                fetchNui("cuttingInput", {
                    cursorX: payload.cursorX,
                    cursorY: payload.cursorY,
                });
            } else if (activeAction === "watering") {
                fetchNui("wateringInput", payload);
            } else if (activeAction === "planting") {
                fetchNui("plantingInput", payload);
            } else if (activeAction === "soiling") {
                fetchNui("soilingInput", payload);
            }
        }, 16);
        return () => window.clearInterval(tick);
    }, [open, activeAction]);

    const onSelect = (id: ActionId) => fetchNui("plantSceneSelect", { action: id });
    const onCancelAction = () => fetchNui("plantSceneCancelAction");
    const onClose = () => fetchNui("plantSceneClose");

    const onMouseMove = (e: React.MouseEvent<HTMLDivElement>) => {
        cursorRef.current.x = e.clientX / window.innerWidth;
        cursorRef.current.y = e.clientY / window.innerHeight;
    };
    const onKeyDown = (e: React.KeyboardEvent<HTMLDivElement>) => {
        if (e.code === "Escape") {
            if (activeAction === "menu") onClose();
            else onCancelAction();
            return;
        }
        if (e.code === "KeyA" || e.code === "KeyD") heldRef.current.add(e.code);
    };
    const onKeyUp = (e: React.KeyboardEvent<HTMLDivElement>) => {
        heldRef.current.delete(e.code);
    };
    const onClick = (e: React.MouseEvent<HTMLDivElement>) => {
        if (activeAction !== "cutting") return;
        const x = e.clientX / window.innerWidth;
        const y = e.clientY / window.innerHeight;
        fetchNui("clickAt", { x, y });
    };
    const onMouseDown = (e: React.MouseEvent<HTMLDivElement>) => {
        if (e.button !== 0) return;
        const x = e.clientX / window.innerWidth;
        const y = e.clientY / window.innerHeight;
        if (activeAction === "planting") {
            fetchNui("plantingClick", { x, y, pressed: true });
        } else if (activeAction === "soiling") {
            fetchNui("soilingClick", { x, y, pressed: true });
        }
    };
    const onMouseUp = (e: React.MouseEvent<HTMLDivElement>) => {
        if (e.button !== 0) return;
        const x = e.clientX / window.innerWidth;
        const y = e.clientY / window.innerHeight;
        if (activeAction === "planting") {
            fetchNui("plantingClick", { x, y, pressed: false });
        } else if (activeAction === "soiling") {
            fetchNui("soilingClick", { x, y, pressed: false });
        }
    };

    const actions = useMemo<ActionEntry[]>(
        () => status?.actions ?? [],
        [status?.actions],
    );

    if (!open) return null;

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
            className="fixed inset-0 outline-none"
        >
            {activeAction === "watering" && (
                <WateringMeters
                    pitcher={pitcherLevel}
                    plantLevel={plantWaterLevel}
                    showPlant={showPlantWater}
                />
            )}

            {/* Bottom plant console — centered, fully rounded */}
            {status && (
                <div className="absolute left-1/2 -translate-x-1/2 bottom-4 pointer-events-auto rounded-2xl bg-black/95 ring-1 ring-white/10 shadow-2xl overflow-hidden w-fit">
                    {/* Header: label (left) · live tip (center). Fixed height so
                        the container never grows when tips contain Kbd chips. */}
                    <div className="grid grid-cols-[auto_1fr_auto] items-center gap-4 px-5 h-9 border-b border-white/5 bg-white/[0.02]">
                        <span className="text-[10px] uppercase tracking-[0.18em] text-white/45 whitespace-nowrap">
                            Plant Console
                        </span>
                        <div className="flex justify-center items-center min-w-0 px-2 h-full">
                            <ActionHintInline activeAction={activeAction} />
                        </div>
                        <span className="w-0" aria-hidden />
                    </div>

                    <div className="flex items-stretch divide-x divide-white/5">
                        <ActionsSection
                            actions={actions}
                            activeAction={activeAction}
                            onSelect={onSelect}
                            onCancelAction={onCancelAction}
                            onClose={onClose}
                        />
                        <StatusSection status={status} />
                    </div>
                </div>
            )}
        </div>
    );
}

export default App;
