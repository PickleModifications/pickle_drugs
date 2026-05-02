import { jsx as _jsx, jsxs as _jsxs, Fragment as _Fragment } from "react/jsx-runtime";
import { useEffect, useState } from "react";
import { Handshake, Hourglass, Inbox } from "lucide-react";
export function DealsHud({ data }) {
    if (!data || data.length === 0)
        return null;
    // Newest at top; cap visually at 4 to keep the HUD compact.
    const items = [...data]
        .sort((a, b) => (b.accepted_at || b.expires_at) - (a.accepted_at || a.expires_at))
        .slice(0, 4);
    return (_jsx("div", { className: "fixed right-3 top-1/3 -translate-y-1/2 pointer-events-none flex flex-col gap-1.5 z-40", children: items.map((d) => (_jsx(DealCard, { d: d }, d.id))) }));
}
function DealCard({ d }) {
    const accepted = d.state === "accepted";
    const total = d.qty * d.unit_price;
    return (_jsxs("div", { className: "rounded-lg bg-black/85 ring-1 ring-white/15 backdrop-blur px-2.5 py-1.5 min-w-[180px] flex items-center gap-2", children: [_jsx("div", { className: "w-7 h-7 rounded-md flex items-center justify-center ring-1 " +
                    (accepted
                        ? "bg-emerald-500/20 ring-emerald-400/40 text-emerald-200"
                        : "bg-amber-500/20 ring-amber-400/40 text-amber-200"), children: accepted ? _jsx(Handshake, { className: "w-4 h-4" }) : _jsx(Inbox, { className: "w-4 h-4" }) }), _jsxs("div", { className: "min-w-0 flex-1", children: [_jsxs("div", { className: "text-[11px] text-white truncate", children: [d.qty, "\u00D7 ", d.drug, " ", _jsxs("span", { className: "text-white/45", children: ["\u00B7 $", total] })] }), _jsx("div", { className: "text-[10px] text-white/55 flex items-center gap-1 tabular-nums", children: accepted
                            ? _jsxs(_Fragment, { children: [_jsx(Hourglass, { className: "w-2.5 h-2.5" }), " ", _jsx(Countdown, { to: d.expires_at })] })
                            : _jsx("span", { className: "capitalize", children: d.state }) })] })] }));
}
// Client-side ticker so the HUD doesn't need a 1Hz server push.
function Countdown({ to }) {
    const [now, setNow] = useState(() => Date.now());
    useEffect(() => {
        const id = window.setInterval(() => setNow(Date.now()), 500);
        return () => window.clearInterval(id);
    }, []);
    const ms = Math.max(0, to - now);
    const m = Math.floor(ms / 60000);
    const s = Math.floor((ms % 60000) / 1000);
    return _jsxs("span", { children: [m, ":", s.toString().padStart(2, "0")] });
}
