import { useEffect, useRef, useState } from "react";
import { Wifi, BatteryFull, Signal } from "lucide-react";
import { HomeScreen } from "./HomeScreen";
import { HelpApp } from "./HelpApp";
import { MessagesApp } from "./MessagesApp";

type AppId = "help" | "messages";
type AppPhase = "opening" | "open" | "closing";
type AppState = {
    id: AppId;
    // Position + size of the icon at click time, in viewport coords.
    iconRect: DOMRect;
    // Position + size of the inner phone screen at click time. Stored
    // alongside iconRect so the morph math is stable even if the page
    // reflows mid-animation.
    screenRect: DOMRect;
    phase: AppPhase;
};

const APP_TRANSITION_MS = 380;
const FRAME_TRANSITION_MS = 280;

// Apple-flavoured spring approximation. Subtle ease-out with the fast
// settle that matches iOS spring transitions reasonably well via a
// stock cubic-bezier (no real spring math needed for this small a UI).
const APP_EASE = "cubic-bezier(0.32, 0.72, 0, 1)";

export function Phone({
    onClose,
    messagesUnread,
}: {
    onClose: () => void;
    // Lifted to App.tsx so the badge count survives close/reopen of
    // the phone — the Phone component re-mounts each time it opens,
    // which would otherwise lose any messagesUnread events that fired
    // while it was closed.
    messagesUnread: number;
}) {
    const [entered, setEntered] = useState(false);
    const closingRef = useRef(false);
    const screenRef = useRef<HTMLDivElement>(null);
    const [appState, setAppState] = useState<AppState | null>(null);

    // Frame slide-up on mount.
    useEffect(() => {
        const id = requestAnimationFrame(() => setEntered(true));
        return () => cancelAnimationFrame(id);
    }, []);

    const beginClose = () => {
        if (closingRef.current) return;
        closingRef.current = true;
        setEntered(false);
        window.setTimeout(() => onClose(), FRAME_TRANSITION_MS - 40);
    };

    // Launch an app from the home screen with the icon morph. Pattern:
    //   render at iconRect (phase=opening) → next frame flip to phase=
    //   open which kicks the CSS transition to the full-screen target.
    const launchApp = (id: AppId, iconRect: DOMRect) => {
        if (appState || !screenRef.current) return;
        const screenRect = screenRef.current.getBoundingClientRect();
        setAppState({ id, iconRect, screenRect, phase: "opening" });
        // Two RAFs: the first commits the "opening" style; the second
        // schedules the transition target. Without the double-RAF some
        // browsers batch the state changes and skip the animation.
        requestAnimationFrame(() => {
            requestAnimationFrame(() => {
                setAppState((prev) =>
                    prev ? { ...prev, phase: "open" } : prev,
                );
            });
        });
    };

    const dismissApp = () => {
        setAppState((prev) => {
            if (!prev || prev.phase === "closing") return prev;
            // Refresh iconRect against the live home screen so the
            // morph lands on the icon's current position even if the
            // home screen has shifted (e.g. window resize while open).
            return { ...prev, phase: "closing" };
        });
        window.setTimeout(() => setAppState(null), APP_TRANSITION_MS);
    };

    // Window-level Escape: pop the open app first, otherwise close.
    useEffect(() => {
        const onKey = (e: KeyboardEvent) => {
            if (e.key !== "Escape") return;
            if (appState && appState.phase !== "closing") {
                dismissApp();
                return;
            }
            if (!appState) beginClose();
        };
        window.addEventListener("keydown", onKey);
        return () => window.removeEventListener("keydown", onKey);
    }, [appState]);

    // Compute the inverse-morph transform: scale + translate from
    // iconRect to the inner-screen origin. transform-origin top-left
    // makes the math straightforward (no center compensation needed).
    const appTransform = (() => {
        if (!appState) return "";
        const dx = appState.iconRect.left - appState.screenRect.left;
        const dy = appState.iconRect.top - appState.screenRect.top;
        const scale = appState.iconRect.width / appState.screenRect.width;
        return `translate(${dx}px, ${dy}px) scale(${scale})`;
    })();

    const appOpening =
        appState !== null && appState.phase === "opening";
    const appOpen = appState !== null && appState.phase === "open";
    const appClosing = appState !== null && appState.phase === "closing";
    const appActive = appOpen; // controls home-screen depth fade

    return (
        // Outer overlay: NOT a backdrop. Pointer-events:none so clicks
        // outside the phone frame fall through visually (the player
        // sees the world unobscured behind the frame). Click-outside-
        // to-close still works via the explicit closer dot below.
        <div className="fixed inset-0 z-50 pointer-events-none flex items-end justify-end">
            <div
                className="relative pointer-events-auto m-4 w-[300px] h-[620px] rounded-[42px] bg-black p-[3px] ring-1 ring-white/15"
                style={{
                    transform: entered
                        ? "translateY(0px) scale(1)"
                        : "translateY(40px) scale(0.96)",
                    opacity: entered ? 1 : 0,
                    transition: `transform ${FRAME_TRANSITION_MS}ms ${APP_EASE}, opacity ${FRAME_TRANSITION_MS - 80}ms ease-out`,
                    transformOrigin: "bottom right",
                    // Thin shadow only — keeps the phone visually
                    // anchored without the wide black halo that
                    // previously read as a backdrop.
                    boxShadow: "0 6px 18px -6px rgba(0,0,0,0.5)",
                }}
            >
                {/* Inner screen — bezel above provides the phone
                    border; this layer is the actual display. */}
                <div
                    ref={screenRef}
                    className="relative w-full h-full rounded-[39px] overflow-hidden bg-zinc-950"
                >
                    <StatusBar />

                    {/* Home screen — pushes back when an app opens.
                        Full-bleed (inset-0, no top offset) so the
                        wallpaper extends behind the status bar; the
                        icon grid handles its own top inset. */}
                    <div
                        className="absolute inset-0"
                        style={{
                            transform: appActive
                                ? "scale(0.92)"
                                : "scale(1)",
                            opacity: appOpen ? 0.35 : 1,
                            transition: `transform ${APP_TRANSITION_MS}ms ${APP_EASE}, opacity ${APP_TRANSITION_MS - 60}ms ease-out`,
                            transformOrigin: "center 60%",
                            // Disable pointer events while an app is up
                            // so the home icons aren't accidentally
                            // tappable through the app overlay.
                            pointerEvents: appState ? "none" : "auto",
                        }}
                    >
                        <HomeScreen
                            onOpenHelp={(rect) => launchApp("help", rect)}
                            onOpenMessages={(rect) => launchApp("messages", rect)}
                            messagesUnread={messagesUnread}
                        />
                    </div>

                    {/* App overlay — only mounted while an app is up. */}
                    {appState && (
                        <div
                            className="absolute inset-0 rounded-[39px] overflow-hidden"
                            style={{
                                transform:
                                    appOpening || appClosing
                                        ? appTransform
                                        : "translate(0px, 0px) scale(1)",
                                opacity: appOpening
                                    ? 0
                                    : appClosing
                                      ? 0
                                      : 1,
                                transformOrigin: "top left",
                                transition: `transform ${APP_TRANSITION_MS}ms ${APP_EASE}, opacity ${APP_TRANSITION_MS - 80}ms ease-out`,
                                willChange: "transform, opacity",
                            }}
                        >
                            {appState.id === "help" && (
                                <HelpApp onBack={dismissApp} />
                            )}
                            {appState.id === "messages" && (
                                <MessagesApp onBack={dismissApp} />
                            )}
                        </div>
                    )}

                    {/* Notch */}
                    <div className="pointer-events-none absolute top-0 left-1/2 -translate-x-1/2 w-24 h-5 bg-black rounded-b-2xl" />

                    {/* Home indicator — also doubles as a close-app
                        affordance: tapping it from inside an app
                        dismisses (mirrors iPhone swipe-up behaviour). */}
                    <button
                        onClick={() => {
                            if (appState) dismissApp();
                            else beginClose();
                        }}
                        className="absolute bottom-1.5 left-1/2 -translate-x-1/2 h-1 w-24 rounded-full bg-white/45 hover:bg-white/70 transition-colors"
                        aria-label={appState ? "Close app" : "Close phone"}
                    />
                </div>
            </div>
        </div>
    );
}

function StatusBar() {
    const [time, setTime] = useState(() => formatTime(new Date()));
    useEffect(() => {
        const id = window.setInterval(
            () => setTime(formatTime(new Date())),
            10_000,
        );
        return () => window.clearInterval(id);
    }, []);
    return (
        <div className="absolute top-0 left-0 right-0 h-7 px-6 flex items-center justify-between text-[11px] font-semibold text-white/90 z-20">
            <div className="tabular-nums">{time}</div>
            <div className="flex items-center gap-1.5 text-white/85">
                <Signal className="w-3 h-3" strokeWidth={2.5} />
                <Wifi className="w-3 h-3" strokeWidth={2.5} />
                <BatteryFull className="w-4 h-4" strokeWidth={2.2} />
            </div>
        </div>
    );
}

function formatTime(d: Date) {
    const h = d.getHours();
    const m = d.getMinutes();
    const hh = h % 12 === 0 ? 12 : h % 12;
    return `${hh}:${m.toString().padStart(2, "0")}`;
}
