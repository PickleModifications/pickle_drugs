import { jsx as _jsx, jsxs as _jsxs, Fragment as _Fragment } from "react/jsx-runtime";
import { useEffect, useMemo, useRef, useState } from "react";
import { ChevronDown, Droplet, Leaf, Mountain, Move, Package, Scissors, Settings as SettingsIcon, Sprout, Trash2, X, } from "lucide-react";
import { fetchNui, useNuiEvent } from "@/lib/nui";
import { CreatorPanel } from "./CreatorPanel";
import { HousingPanel } from "./HousingPanel";
import { HouseManagePanel } from "./HouseManagePanel";
import { HousePlacementHud } from "./HousePlacementHud";
import { WorkerPickerHud } from "./WorkerPickerHud";
import { StoragePanel } from "./StoragePanel";
import { ZonePickerHud } from "./ZonePickerHud";
import { Phone } from "./phone/Phone";
import { DealsHud } from "./DealsHud";
// ─── SmoothBar ────────────────────────────────────────────────────────────
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
            const a = 1 - Math.exp(-speed * dt);
            const next = valueRef.current +
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
    return (_jsx("div", { className: "h-1.5 rounded-full bg-white/10 overflow-hidden", children: _jsx("div", { className: "h-full " + (className ?? "bg-white/70"), style: { width: `${value * 100}%` } }) }));
}
// ─── Helpers ─────────────────────────────────────────────────────────────
const STATUS_LABEL = {
    needs_soil: "Needs Soil",
    ready_plant: "Needs Seed",
    needs_water: "Needs Water — growth paused",
    ready_harvest: "Ready to Harvest",
    growing: "Growing",
};
const STATUS_ACCENT = {
    needs_soil: "bg-orange-500",
    ready_plant: "bg-emerald-400",
    needs_water: "bg-amber-400",
    ready_harvest: "bg-fuchsia-400",
    growing: "bg-emerald-500",
};
function formatEta(ms) {
    if (ms == null)
        return null;
    if (ms <= 0)
        return "ready";
    const s = Math.ceil(ms / 1000);
    if (s < 60)
        return `${s}s`;
    const m = Math.floor(s / 60);
    const rem = s % 60;
    return `${m}m ${rem}s`;
}
const ICON_MAP = {
    mound: Mountain,
    sprout: Sprout,
    droplet: Droplet,
    scissors: Scissors,
    move: Move,
    trash: Trash2,
    package: Package,
    gear: SettingsIcon,
};
function ActionIcon({ name, className }) {
    const Comp = ICON_MAP[name] ?? Sprout;
    return _jsx(Comp, { className: className ?? "h-5 w-5" });
}
// Per-action tone tokens. Resting state is neutral white; `hover` previews
// the action's color so the player can feel the affordance, and `active`
// shipps that color when the action is currently running.
const NEUTRAL_ENABLED = "text-white/90 bg-white/[0.06] ring-white/30 ";
const TONES = {
    soiling: {
        hover: "hover:bg-orange-500/25 hover:ring-orange-400/70 hover:text-orange-50 hover:shadow-[0_0_14px_-6px_rgba(251,146,60,0.7)]",
        active: "bg-orange-500/30 ring-orange-400/70 text-orange-50 shadow-[0_0_18px_-6px_rgba(251,146,60,0.75)]",
    },
    planting: {
        hover: "hover:bg-emerald-500/25 hover:ring-emerald-400/70 hover:text-emerald-50 hover:shadow-[0_0_14px_-6px_rgba(52,211,153,0.7)]",
        active: "bg-emerald-500/30 ring-emerald-400/70 text-emerald-50 shadow-[0_0_18px_-6px_rgba(52,211,153,0.75)]",
    },
    watering: {
        hover: "hover:bg-sky-500/25 hover:ring-sky-400/70 hover:text-sky-50 hover:shadow-[0_0_14px_-6px_rgba(56,189,248,0.7)]",
        active: "bg-sky-500/30 ring-sky-400/70 text-sky-50 shadow-[0_0_18px_-6px_rgba(56,189,248,0.75)]",
    },
    cutting: {
        hover: "hover:bg-fuchsia-500/25 hover:ring-fuchsia-400/70 hover:text-fuchsia-50 hover:shadow-[0_0_14px_-6px_rgba(232,121,249,0.7)]",
        active: "bg-fuchsia-500/30 ring-fuchsia-400/70 text-fuchsia-50 shadow-[0_0_18px_-6px_rgba(232,121,249,0.75)]",
    },
    move: {
        hover: "hover:bg-amber-500/25 hover:ring-amber-400/70 hover:text-amber-50 hover:shadow-[0_0_14px_-6px_rgba(251,191,36,0.7)]",
        active: "bg-amber-500/30 ring-amber-400/70 text-amber-50 shadow-[0_0_18px_-6px_rgba(251,191,36,0.75)]",
    },
    remove: {
        hover: "hover:bg-red-500/25 hover:ring-red-400/70 hover:text-red-50 hover:shadow-[0_0_14px_-6px_rgba(248,113,113,0.7)]",
        active: "bg-red-500/30 ring-red-400/70 text-red-50 shadow-[0_0_18px_-6px_rgba(248,113,113,0.75)]",
    },
    output: {
        hover: "hover:bg-cyan-500/25 hover:ring-cyan-400/70 hover:text-cyan-50 hover:shadow-[0_0_14px_-6px_rgba(34,211,238,0.7)]",
        active: "bg-cyan-500/30 ring-cyan-400/70 text-cyan-50 shadow-[0_0_18px_-6px_rgba(34,211,238,0.75)]",
    },
    menu: { hover: "", active: "" },
};
// ─── Status section ──────────────────────────────────────────────────────
function StatusSection({ status }) {
    const eta = formatEta(status.etaMs);
    const dryWarn = status.statusKey !== "needs_soil" &&
        status.statusKey !== "ready_plant" &&
        status.waterProgress < 0.2 &&
        status.showWater;
    return (_jsxs("div", { className: "px-5 py-3 flex items-center gap-5", children: [_jsxs("div", { className: "flex items-center gap-2 min-w-0", children: [_jsx("div", { className: "h-9 w-9 rounded-lg bg-emerald-500/15 ring-1 ring-emerald-500/30 flex items-center justify-center shrink-0", children: _jsx(Leaf, { className: "h-5 w-5 text-emerald-300" }) }), _jsxs("div", { className: "flex flex-col leading-tight min-w-0", children: [_jsx("span", { className: "text-sm font-medium text-white truncate", children: status.drug }), _jsxs("span", { className: "text-[10px] uppercase tracking-wider text-white/50 tabular-nums", children: ["Stage ", status.stage, " / ", status.stageMax] })] })] }), _jsxs("div", { className: "w-[280px] flex flex-col gap-1.5", children: [_jsxs("div", { className: "space-y-1 min-w-0", children: [_jsxs("div", { className: "flex items-center justify-between text-[11px]", children: [_jsx("span", { className: "text-white/60 truncate", children: STATUS_LABEL[status.statusKey] }), _jsx("span", { className: "text-white/60 tabular-nums shrink-0 ml-2", children: status.statusKey === "growing"
                                            ? `${Math.round(status.growProgress * 100)}%`
                                            : status.statusKey === "ready_harvest"
                                                ? `${status.budsLeft} buds`
                                                : "" })] }), _jsx(SmoothBar, { target: status.statusKey === "growing"
                                    ? status.growProgress
                                    : 1, className: STATUS_ACCENT[status.statusKey] })] }), status.showWater && (_jsxs("div", { className: "space-y-1 min-w-0", children: [_jsxs("div", { className: "flex items-center justify-between text-[11px]", children: [_jsxs("span", { className: "text-white/60 flex items-center gap-1", children: [_jsx(Droplet, { className: "h-3 w-3 text-sky-400" }), "Water"] }), _jsxs("span", { className: "text-white/60 tabular-nums", children: [Math.round(status.waterProgress * 100), "%"] })] }), _jsx(SmoothBar, { target: status.waterProgress, className: dryWarn ? "bg-red-500" : "bg-sky-400" })] })), eta && status.statusKey === "growing" && (_jsxs("div", { className: "flex items-center justify-between text-[11px] tabular-nums", children: [_jsx("span", { className: "text-white/50", children: "Next stage in" }), _jsx("span", { className: "text-white/70", children: eta })] })), dryWarn && (_jsx("div", { className: "text-[11px] text-red-300", children: "Reservoir nearly empty \u2014 growth pauses when dry." }))] })] }));
}
// ─── Actions section ─────────────────────────────────────────────────────
function ActionsSection({ actions, activeAction, onSelect, onCancelAction, onClose, }) {
    const inAction = activeAction !== "menu";
    const mainActions = actions.filter((a) => !a.settings);
    const settingsActions = actions.filter((a) => a.settings);
    const [settingsOpen, setSettingsOpen] = useState(false);
    // Close the popover whenever the player drops into a sub-action so
    // the floating menu doesn't linger over the active scene.
    useEffect(() => {
        if (inAction)
            setSettingsOpen(false);
    }, [inAction]);
    const renderActionButton = (a) => {
        const isActive = activeAction === a.id;
        const disabled = !a.available || (inAction && !isActive);
        const tone = TONES[a.id] ?? TONES.menu;
        return (_jsxs("button", { disabled: disabled, onClick: () => {
                setSettingsOpen(false);
                isActive ? onCancelAction() : onSelect(a.id);
            }, title: a.reason ?? a.label, className: "group relative flex flex-col items-center justify-center gap-1 rounded-lg px-3 py-2 min-w-[68px] ring-1 transition-all " +
                (isActive
                    ? tone.active + " "
                    : disabled
                        ? "text-white/25 cursor-not-allowed bg-white/[0.02] ring-white/20 "
                        : NEUTRAL_ENABLED + tone.hover + " "), children: [_jsx(ActionIcon, { name: a.icon, className: "h-5 w-5" }), _jsx("span", { className: "text-[10px] font-medium leading-none", children: a.label }), !a.available && a.reason && (_jsx("span", { className: "absolute -top-7 left-1/2 -translate-x-1/2 text-[10px] text-white/70 bg-black/80 px-2 py-0.5 rounded whitespace-nowrap opacity-0 group-hover:opacity-100 transition-opacity pointer-events-none ring-1 ring-white/10", children: a.reason }))] }, a.id));
    };
    const settingsDisabled = inAction || settingsActions.length === 0;
    return (_jsxs("div", { className: "px-3 py-3 flex items-center gap-2", children: [_jsxs("div", { className: "flex items-center gap-1.5", children: [mainActions.map(renderActionButton), settingsActions.length > 0 && (_jsxs("div", { className: "relative", children: [_jsxs("button", { disabled: settingsDisabled, onClick: () => setSettingsOpen((o) => !o), title: "Settings", className: "flex flex-col items-center justify-center gap-1 rounded-lg px-3 py-2 min-w-[68px] ring-1 transition-all " +
                                    (settingsDisabled
                                        ? "text-white/25 cursor-not-allowed bg-white/[0.02] ring-white/20 "
                                        : settingsOpen
                                            ? "bg-white/[0.12] ring-white/40 text-white "
                                            : NEUTRAL_ENABLED + "hover:bg-white/[0.10] hover:ring-white/40 "), children: [_jsx(ActionIcon, { name: "gear", className: "h-5 w-5" }), _jsx("span", { className: "text-[10px] font-medium leading-none", children: "Settings" })] }), settingsOpen && (_jsx("div", { className: "absolute left-1/2 -translate-x-1/2 bottom-[calc(100%+8px)] z-10 rounded-xl bg-black/95 ring-1 ring-white/15 shadow-2xl p-2 flex items-center gap-1.5", children: settingsActions.map(renderActionButton) }))] }))] }), _jsx("div", { className: "h-10 w-px bg-white/10 mx-1" }), inAction ? (_jsxs("button", { onClick: onCancelAction, className: "flex flex-col items-center justify-center gap-1 rounded-lg px-3 py-2 min-w-[68px] bg-amber-500/15 ring-1 ring-amber-400/50 text-amber-200 hover:bg-amber-500/25 hover:ring-amber-400/70 transition-colors", title: "Back to menu", children: [_jsx(ChevronDown, { className: "h-5 w-5 rotate-90" }), _jsx("span", { className: "text-[10px] font-medium leading-none", children: "Back" })] })) : (_jsxs("button", { onClick: onClose, className: "flex flex-col items-center justify-center gap-1 rounded-lg px-3 py-2 min-w-[68px] bg-white/[0.06] ring-1 ring-white/30 text-white/80 hover:bg-red-500/20 hover:text-red-100 hover:ring-red-400/60 transition-colors", title: "Close", children: [_jsx(X, { className: "h-5 w-5" }), _jsx("span", { className: "text-[10px] font-medium leading-none", children: "Close" })] }))] }));
}
// ─── Action hint ─────────────────────────────────────────────────────────
function ActionHintInline({ activeAction }) {
    if (activeAction === "menu") {
        return (_jsx("span", { className: "text-[11px] text-white/50 italic", children: "Pick an action to begin" }));
    }
    let content = null;
    if (activeAction === "cutting") {
        content = (_jsxs(_Fragment, { children: ["Hold ", _jsx(Kbd, { children: "A" }), " / ", _jsx(Kbd, { children: "D" }), " to rotate \u00B7 click a bud to cut"] }));
    }
    else if (activeAction === "watering") {
        content = (_jsxs(_Fragment, { children: ["Move the cursor to position the pitcher \u00B7 hold ", _jsx(Kbd, { children: "A" }), " /", " ", _jsx(Kbd, { children: "D" }), " to tilt and pour"] }));
    }
    else if (activeAction === "soiling") {
        content = (_jsxs(_Fragment, { children: ["Hold left-click and drag to rip the bag \u00B7 then move it over the pot and tilt with ", _jsx(Kbd, { children: "A" }), " / ", _jsx(Kbd, { children: "D" }), " to pour"] }));
    }
    else if (activeAction === "planting") {
        content = (_jsxs(_Fragment, { children: ["Click the cap to pop it \u00B7 grab the capsule and tilt with", " ", _jsx(Kbd, { children: "A" }), " / ", _jsx(Kbd, { children: "D" }), " to drop the seed \u00B7 click each rubble pile to bury"] }));
    }
    return (_jsx("span", { className: "text-[11px] text-white/80 truncate", children: content }));
}
function GizmoHelpBar({ frozen, enableCancel, }) {
    return (_jsx("div", { className: "fixed inset-x-0 bottom-6 flex justify-center pointer-events-none", children: _jsxs("div", { className: "rounded-2xl bg-black/85 ring-1 ring-white/15 shadow-2xl px-4 py-2.5 flex items-center gap-3 text-[12px] text-white/85", children: [_jsx("span", { className: "text-[10px] uppercase tracking-[0.18em] text-white/45", children: "Placement" }), _jsx("span", { className: "h-4 w-px bg-white/10" }), _jsxs("span", { className: "flex items-center gap-1.5", children: [_jsx(Kbd, { children: "G" }), frozen ? "Unfreeze" : "Freeze"] }), frozen && (_jsxs(_Fragment, { children: [_jsxs("span", { className: "flex items-center gap-1.5", children: [_jsx(Kbd, { children: "W" }), _jsx(Kbd, { children: "A" }), _jsx(Kbd, { children: "S" }), _jsx(Kbd, { children: "D" }), "Move"] }), _jsxs("span", { className: "flex items-center gap-1.5", children: [_jsx(Kbd, { children: "A" }), _jsx(Kbd, { children: "D" }), "Rotate"] }), _jsxs("span", { className: "flex items-center gap-1.5", children: [_jsx(Kbd, { children: "Shift" }), "Faster"] })] })), _jsxs("span", { className: "flex items-center gap-1.5", children: [_jsx(Kbd, { children: "E" }), _jsx("span", { className: "text-emerald-200/90", children: "Save" })] }), enableCancel && (_jsxs("span", { className: "flex items-center gap-1.5", children: [_jsx(Kbd, { children: "Esc" }), _jsx("span", { className: "text-red-200/90", children: "Cancel" })] }))] }) }));
}
function Kbd({ children }) {
    // h-[18px] + leading-none + align-middle keeps the chip from pushing the
    // surrounding line height — its visual size is independent of its layout
    // contribution.
    return (_jsx("kbd", { className: "inline-flex items-center align-middle h-[18px] px-1.5 mx-0.5 rounded bg-white/10 ring-1 ring-white/15 text-[11px] font-mono leading-none", children: children }));
}
// ─── Watering meters (separate floater while in watering action) ─────────
function WateringMeters({ pitcher, plantLevel, showPlant, }) {
    return (_jsx("div", { className: "absolute top-6 right-6 pointer-events-none", children: _jsxs("div", { className: "rounded-xl bg-black/60 ring-1 ring-white/10  px-4 py-3 w-[200px]", children: [_jsxs("div", { className: "flex items-center gap-2 mb-2", children: [_jsx(Droplet, { className: "h-4 w-4 text-sky-400" }), _jsx("span", { className: "text-xs text-white/60", children: "Pitcher" }), _jsxs("span", { className: "ml-auto text-xs tabular-nums text-white/80", children: [Math.round(pitcher * 100), "%"] })] }), _jsx(SmoothBar, { target: pitcher, className: "bg-sky-400", speed: 10 }), showPlant && (_jsxs(_Fragment, { children: [_jsxs("div", { className: "flex items-center gap-2 mt-3 mb-2", children: [_jsx(Sprout, { className: "h-4 w-4 text-emerald-400" }), _jsx("span", { className: "text-xs text-white/60", children: "Plant" }), _jsxs("span", { className: "ml-auto text-xs tabular-nums text-white/80", children: [Math.round(plantLevel * 100), "%"] })] }), _jsx(SmoothBar, { target: plantLevel, className: "bg-emerald-400" })] }))] }) }));
}
// ─── App ─────────────────────────────────────────────────────────────────
function App() {
    const [open, setOpen] = useState(false);
    const [status, setStatus] = useState(null);
    const [creatorOpen, setCreatorOpen] = useState(false);
    const [creatorDrugs, setCreatorDrugs] = useState([]);
    const [creatorPlots, setCreatorPlots] = useState([]);
    const [creatorHidden, setCreatorHidden] = useState(false);
    const [gizmoHelp, setGizmoHelp] = useState(null);
    // Housing admin
    const [housingOpen, setHousingOpen] = useState(false);
    const [housingHidden, setHousingHidden] = useState(false);
    const [housingPanel, setHousingPanel] = useState("houses");
    const [housingInitial, setHousingInitial] = useState({ interiors: [], houses: [] });
    // Player house management
    const [houseManageOpen, setHouseManageOpen] = useState(false);
    const [houseManageHidden, setHouseManageHidden] = useState(false);
    const [houseManageData, setHouseManageData] = useState(null);
    // Placement HUD
    const [placementHud, setPlacementHud] = useState(null);
    const [workerPickerHud, setWorkerPickerHud] = useState(null);
    // Storage locker panel
    const [storageData, setStorageData] = useState(null);
    // Zone picker HUD (admin in-world zone bounds picker)
    const [zonePickerHud, setZonePickerHud] = useState(null);
    const [phoneOpen, setPhoneOpen] = useState(false);
    // Unread messages count — lifted to App so it survives Phone
    // mount/unmount. Otherwise the badge reset to 0 every time the
    // phone closed (no events would fire to repopulate it before
    // the user re-opened it).
    const [messagesUnread, setMessagesUnread] = useState(0);
    // DealsHud is a true world HUD — visible whenever the player has any
    // active/scheduled deals, regardless of which (if any) panel is open.
    const [dealsHud, setDealsHud] = useState([]);
    const [pitcherLevel, setPitcherLevel] = useState(1.0);
    const [plantWaterLevel, setPlantWaterLevel] = useState(0.0);
    const [showPlantWater, setShowPlantWater] = useState(false);
    const rootRef = useRef(null);
    const heldRef = useRef(new Set());
    const cursorRef = useRef({ x: 0.5, y: 0.5 });
    useNuiEvent("openPlantScene", () => {
        setOpen(true);
        requestAnimationFrame(() => rootRef.current?.focus());
    });
    useNuiEvent("openCreator", (data) => {
        setCreatorDrugs(data?.drugs ?? []);
        setCreatorPlots(data?.plots ?? []);
        setCreatorHidden(false);
        setCreatorOpen(true);
    });
    useNuiEvent("closeCreator", () => setCreatorOpen(false));
    useNuiEvent("creatorPlots", (data) => {
        if (data?.plots)
            setCreatorPlots(data.plots);
    });
    useNuiEvent("creatorMinimize", () => setCreatorHidden(true));
    useNuiEvent("creatorRestore", (data) => {
        setCreatorHidden(false);
        if (data?.plots)
            setCreatorPlots(data.plots);
    });
    useNuiEvent("gizmoHelp", (data) => {
        if (!data || !data.visible) {
            setGizmoHelp(null);
        }
        else {
            setGizmoHelp({
                visible: true,
                frozen: !!data.frozen,
                enableCancel: !!data.enableCancel,
            });
        }
    });
    // Housing admin events
    useNuiEvent("openHousing", (data) => {
        if (!data)
            return;
        setHousingPanel(data.panel ?? "houses");
        setHousingInitial({ interiors: data.interiors ?? [], houses: data.houses ?? [] });
        setHousingHidden(false);
        setHousingOpen(true);
    });
    useNuiEvent("closeHousing", () => setHousingOpen(false));
    useNuiEvent("housingMinimize", () => setHousingHidden(true));
    useNuiEvent("housingRestore", (d) => {
        setHousingHidden(false);
        if (d?.panel)
            setHousingPanel(d.panel);
    });
    // House manage panel
    useNuiEvent("openHouseManage", (data) => {
        if (!data)
            return;
        setHouseManageData(data);
        setHouseManageHidden(false);
        setHouseManageOpen(true);
    });
    useNuiEvent("closeHouseManage", () => {
        setHouseManageOpen(false);
        setHouseManageData(null);
        setHouseManageHidden(false);
    });
    // Mid-flow visibility toggle. While a placement / move flow is running
    // we hide the panel (instead of unmounting it) so it pops back into
    // the same tab/state when the placement completes.
    useNuiEvent("houseManageMinimize", () => setHouseManageHidden(true));
    useNuiEvent("houseManageRestore", () => setHouseManageHidden(false));
    // Placement HUD
    useNuiEvent("openPlacementHud", (data) => setPlacementHud(data ?? null));
    useNuiEvent("closePlacementHud", () => setPlacementHud(null));
    // Worker plot-picker HUD (raycast pick a plot to assign to a worker)
    useNuiEvent("openWorkerPickerHud", (data) => setWorkerPickerHud(data ?? null));
    useNuiEvent("closeWorkerPickerHud", () => setWorkerPickerHud(null));
    // Storage locker panel
    useNuiEvent("openStoragePanel", (data) => setStorageData(data ?? null));
    useNuiEvent("closeStoragePanel", () => setStorageData(null));
    // Phone (in-game device — currently just hosts the Help app)
    useNuiEvent("openPhone", () => setPhoneOpen(true));
    useNuiEvent("closePhone", () => setPhoneOpen(false));
    useNuiEvent("messagesUnread", (n) => {
        if (typeof n === "number")
            setMessagesUnread(n);
    });
    // Active/scheduled deals push (from dealing/client.lua).
    useNuiEvent("dealsHudUpdate", (d) => setDealsHud(d ?? []));
    // Zone picker HUD
    useNuiEvent("openZonePickerHud", (data) => setZonePickerHud(data ?? null));
    useNuiEvent("updateZonePickerHud", (data) => {
        if (data)
            setZonePickerHud(data);
    });
    useNuiEvent("closeZonePickerHud", () => setZonePickerHud(null));
    useNuiEvent("closePlantScene", () => {
        setOpen(false);
        setStatus(null);
        heldRef.current.clear();
    });
    useNuiEvent("plantSceneStatus", (data) => {
        if (data)
            setStatus(data);
    });
    useNuiEvent("wateringLevel", (data) => {
        if (data?.level !== undefined)
            setPitcherLevel(data.level);
    });
    useNuiEvent("wateringPlantLevel", (data) => {
        if (data?.level !== undefined)
            setPlantWaterLevel(data.level);
        if (data?.show !== undefined)
            setShowPlantWater(data.show);
    });
    useEffect(() => {
        if (!open)
            return;
        rootRef.current?.focus();
    }, [open]);
    const activeAction = status?.activeAction ?? "menu";
    useEffect(() => {
        if (!open || activeAction === "menu")
            return;
        const tick = window.setInterval(() => {
            const payload = {
                cursorX: cursorRef.current.x,
                cursorY: cursorRef.current.y,
                heldKeys: [...heldRef.current],
            };
            if (activeAction === "cutting") {
                if (heldRef.current.has("KeyA"))
                    fetchNui("rotate", { delta: 2.5 });
                if (heldRef.current.has("KeyD"))
                    fetchNui("rotate", { delta: -2.5 });
                fetchNui("cuttingInput", {
                    cursorX: payload.cursorX,
                    cursorY: payload.cursorY,
                });
            }
            else if (activeAction === "watering") {
                fetchNui("wateringInput", payload);
            }
            else if (activeAction === "planting") {
                fetchNui("plantingInput", payload);
            }
            else if (activeAction === "soiling") {
                fetchNui("soilingInput", payload);
            }
        }, 16);
        return () => window.clearInterval(tick);
    }, [open, activeAction]);
    const onSelect = (id) => fetchNui("plantSceneSelect", { action: id });
    const onCancelAction = () => fetchNui("plantSceneCancelAction");
    const onClose = () => fetchNui("plantSceneClose");
    const onMouseMove = (e) => {
        cursorRef.current.x = e.clientX / window.innerWidth;
        cursorRef.current.y = e.clientY / window.innerHeight;
    };
    const onKeyDown = (e) => {
        if (e.code === "Escape") {
            if (activeAction === "menu")
                onClose();
            else
                onCancelAction();
            return;
        }
        if (e.code === "KeyA" || e.code === "KeyD")
            heldRef.current.add(e.code);
    };
    const onKeyUp = (e) => {
        heldRef.current.delete(e.code);
    };
    const onClick = (e) => {
        if (activeAction !== "cutting")
            return;
        const x = e.clientX / window.innerWidth;
        const y = e.clientY / window.innerHeight;
        fetchNui("clickAt", { x, y });
    };
    const onMouseDown = (e) => {
        if (e.button !== 0)
            return;
        const x = e.clientX / window.innerWidth;
        const y = e.clientY / window.innerHeight;
        if (activeAction === "planting") {
            fetchNui("plantingClick", { x, y, pressed: true });
        }
        else if (activeAction === "soiling") {
            fetchNui("soilingClick", { x, y, pressed: true });
        }
    };
    const onMouseUp = (e) => {
        if (e.button !== 0)
            return;
        const x = e.clientX / window.innerWidth;
        const y = e.clientY / window.innerHeight;
        if (activeAction === "planting") {
            fetchNui("plantingClick", { x, y, pressed: false });
        }
        else if (activeAction === "soiling") {
            fetchNui("soilingClick", { x, y, pressed: false });
        }
    };
    const actions = useMemo(() => status?.actions ?? [], [status?.actions]);
    const anyOpen = open ||
        creatorOpen ||
        housingOpen ||
        houseManageOpen ||
        phoneOpen ||
        !!storageData ||
        !!placementHud ||
        !!workerPickerHud ||
        !!zonePickerHud ||
        !!gizmoHelp;
    // The DealsHud is a true HUD: present whenever the player has any
    // active or scheduled deals, regardless of which (if any) panel is
    // up. Rendered as a sibling to whatever else the App returns.
    const hudOverlay = dealsHud.length > 0 ? _jsx(DealsHud, { data: dealsHud }) : null;
    if (!anyOpen)
        return hudOverlay;
    // Compute which panel surface to show via the existing cascade. Wrap
    // it in an IIFE so the DealsHud can sit as a sibling without edits
    // to every individual `return` branch.
    const panelEl = (() => {
        if (phoneOpen && !open) {
            return (_jsx(Phone, { messagesUnread: messagesUnread, onClose: () => {
                    setPhoneOpen(false);
                    fetchNui("phoneClose");
                } }));
        }
        if (housingOpen && !open) {
            return (_jsxs(_Fragment, { children: [_jsx(HousingPanel, { initial: housingInitial, panel: housingPanel, hidden: housingHidden, onClose: () => fetchNui("housingClose") }), gizmoHelp && _jsx(GizmoHelpBar, { ...gizmoHelp }), zonePickerHud && _jsx(ZonePickerHud, { data: zonePickerHud })] }));
        }
        if (houseManageOpen && houseManageData && !open) {
            return (_jsxs(_Fragment, { children: [_jsx(HouseManagePanel, { data: houseManageData, hidden: houseManageHidden, onClose: () => fetchNui("houseManageClose") }), placementHud && _jsx(HousePlacementHud, { data: placementHud }), workerPickerHud && _jsx(WorkerPickerHud, { data: workerPickerHud })] }));
        }
        if (storageData && !open) {
            return (_jsx(StoragePanel, { data: storageData, onClose: () => fetchNui("storageClose") }));
        }
        if (placementHud && !open) {
            return _jsx(HousePlacementHud, { data: placementHud });
        }
        if (workerPickerHud && !open) {
            return _jsx(WorkerPickerHud, { data: workerPickerHud });
        }
        if (zonePickerHud && !open) {
            return _jsx(ZonePickerHud, { data: zonePickerHud });
        }
        if (creatorOpen && !open) {
            return (_jsxs(_Fragment, { children: [_jsx(CreatorPanel, { drugs: creatorDrugs, plots: creatorPlots, hidden: creatorHidden, onClose: () => fetchNui("creatorClose") }), gizmoHelp && _jsx(GizmoHelpBar, { ...gizmoHelp })] }));
        }
        if (!open && gizmoHelp) {
            return _jsx(GizmoHelpBar, { ...gizmoHelp });
        }
        return (_jsxs("div", { ref: rootRef, tabIndex: 0, autoFocus: true, onKeyDown: onKeyDown, onKeyUp: onKeyUp, onClick: onClick, onMouseDown: onMouseDown, onMouseUp: onMouseUp, onMouseMove: onMouseMove, onBlur: () => requestAnimationFrame(() => rootRef.current?.focus()), className: "fixed inset-0 outline-none", children: [activeAction === "watering" && (_jsx(WateringMeters, { pitcher: pitcherLevel, plantLevel: plantWaterLevel, showPlant: showPlantWater })), status && (_jsxs("div", { className: "absolute left-1/2 -translate-x-1/2 bottom-4 pointer-events-auto rounded-2xl bg-black/95 ring-1 ring-white/10 shadow-2xl w-fit", children: [_jsxs("div", { className: "grid grid-cols-[auto_1fr_auto] items-center gap-4 px-5 h-9 border-b border-white/5 bg-white/[0.02]", children: [_jsx("span", { className: "text-[10px] uppercase tracking-[0.18em] text-white/45 whitespace-nowrap", children: "Plant Console" }), _jsx("div", { className: "flex justify-center items-center min-w-0 px-2 h-full", children: _jsx(ActionHintInline, { activeAction: activeAction }) }), _jsx("span", { className: "w-0", "aria-hidden": true })] }), _jsxs("div", { className: "flex items-stretch divide-x divide-white/5", children: [_jsx(ActionsSection, { actions: actions, activeAction: activeAction, onSelect: onSelect, onCancelAction: onCancelAction, onClose: onClose }), _jsx(StatusSection, { status: status })] })] }))] }));
    })();
    return _jsxs(_Fragment, { children: [panelEl, hudOverlay] });
}
export default App;
