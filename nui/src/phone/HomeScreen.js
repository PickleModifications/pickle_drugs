import { jsx as _jsx, jsxs as _jsxs } from "react/jsx-runtime";
import { useRef } from "react";
import { LifeBuoy, MessageSquare } from "lucide-react";
export function HomeScreen({ onOpenHelp, onOpenMessages, messagesUnread, }) {
    const apps = [
        {
            id: "help",
            label: "Help",
            icon: LifeBuoy,
            tone: "from-sky-400 to-sky-600",
            onOpen: onOpenHelp,
        },
        {
            id: "messages",
            label: "Messages",
            icon: MessageSquare,
            tone: "from-amber-400 to-amber-600",
            badge: messagesUnread > 0 ? messagesUnread : undefined,
            onOpen: onOpenMessages,
        },
    ];
    return (
    // Full-bleed wallpaper — extends behind the status bar so
    // there's no black band at the top. Top padding (pt-7)
    // reserves the status-bar area for the icon grid below; the
    // gradient still draws behind it.
    _jsxs("div", { className: "absolute inset-0 flex flex-col bg-[radial-gradient(circle_at_50%_120%,rgba(59,130,246,0.18),transparent_60%),linear-gradient(to_bottom,#0a0d14,#05070b)] text-white pt-7", children: [_jsx("div", { className: "flex-1" }), _jsx("div", { className: "grid grid-cols-4 gap-x-3 gap-y-5 px-5 pt-4 pb-8", children: apps.map((app) => (_jsx(AppIcon, { app: app }, app.id))) })] }));
}
function AppIcon({ app }) {
    const tileRef = useRef(null);
    const Icon = app.icon;
    const handleClick = () => {
        const el = tileRef.current;
        if (!el)
            return;
        // Pass the icon-tile rect so the Phone can morph from this
        // exact position. Apple's app-open is anchored to the icon —
        // matching that requires the live DOMRect, not a guess.
        app.onOpen(el.getBoundingClientRect());
    };
    return (_jsxs("button", { onClick: handleClick, className: "flex flex-col items-center gap-1.5 active:scale-90 transition-transform duration-150", children: [_jsxs("div", { ref: tileRef, className: `relative w-12 h-12 rounded-2xl bg-gradient-to-br ${app.tone} ring-1 ring-white/15 shadow-lg shadow-black/40 flex items-center justify-center`, children: [_jsx(Icon, { className: "w-6 h-6 text-white", strokeWidth: 2.2 }), app.badge !== undefined && (_jsx("span", { className: "absolute -top-1 -right-1 min-w-[16px] h-[16px] px-1 rounded-full bg-red-500 ring-2 ring-zinc-950 text-[9px] font-bold text-white flex items-center justify-center tabular-nums", children: app.badge > 9 ? "9+" : app.badge }))] }), _jsx("div", { className: "text-[10px] text-white/85 font-medium", children: app.label })] }));
}
