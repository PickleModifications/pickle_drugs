import { useEffect, useState } from "react";
import { Handshake, Hourglass, Inbox } from "lucide-react";

// Persistent right-side HUD listing the player's offered + accepted deals.
// Pure visualization — driven entirely by `dealsHudUpdate` events from
// dealing/client.lua. Pointer-events none on the outer container so it
// never intercepts gameplay input; the cards are purely informational.

type Deal = {
    id: string;
    drug: string;
    qty: number;
    unit_price: number;
    state: "offered" | "negotiating" | "accepted";
    accepted_at: number;
    expires_at: number;
};

export type DealsHudData = Deal[];

export function DealsHud({ data }: { data: DealsHudData }) {
    if (!data || data.length === 0) return null;
    // Newest at top; cap visually at 4 to keep the HUD compact.
    const items = [...data]
        .sort((a, b) => (b.accepted_at || b.expires_at) - (a.accepted_at || a.expires_at))
        .slice(0, 4);
    return (
        <div className="fixed right-3 top-1/3 -translate-y-1/2 pointer-events-none flex flex-col gap-1.5 z-40">
            {items.map((d) => (
                <DealCard key={d.id} d={d} />
            ))}
        </div>
    );
}

function DealCard({ d }: { d: Deal }) {
    const accepted = d.state === "accepted";
    const total = d.qty * d.unit_price;
    return (
        <div className="rounded-lg bg-black/85 ring-1 ring-white/15 backdrop-blur px-2.5 py-1.5 min-w-[180px] flex items-center gap-2">
            <div className={
                "w-7 h-7 rounded-md flex items-center justify-center ring-1 " +
                (accepted
                    ? "bg-emerald-500/20 ring-emerald-400/40 text-emerald-200"
                    : "bg-amber-500/20 ring-amber-400/40 text-amber-200")
            }>
                {accepted ? <Handshake className="w-4 h-4" /> : <Inbox className="w-4 h-4" />}
            </div>
            <div className="min-w-0 flex-1">
                <div className="text-[11px] text-white truncate">
                    {d.qty}× {d.drug} <span className="text-white/45">· ${total}</span>
                </div>
                <div className="text-[10px] text-white/55 flex items-center gap-1 tabular-nums">
                    {accepted
                        ? <><Hourglass className="w-2.5 h-2.5" /> <Countdown to={d.expires_at} /></>
                        : <span className="capitalize">{d.state}</span>}
                </div>
            </div>
        </div>
    );
}

// Client-side ticker so the HUD doesn't need a 1Hz server push.
function Countdown({ to }: { to: number }) {
    const [now, setNow] = useState(() => Date.now());
    useEffect(() => {
        const id = window.setInterval(() => setNow(Date.now()), 500);
        return () => window.clearInterval(id);
    }, []);
    const ms = Math.max(0, to - now);
    const m = Math.floor(ms / 60000);
    const s = Math.floor((ms % 60000) / 1000);
    return <span>{m}:{s.toString().padStart(2, "0")}</span>;
}
