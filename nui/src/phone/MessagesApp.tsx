import { useEffect, useMemo, useState } from "react";
import { ChevronLeft, MessageSquare, Check, X, Handshake, type LucideIcon } from "lucide-react";

import { fetchNui, useNuiEvent } from "@/lib/nui";

// Mirrors the Lua row shape pushed by dealing/server.lua.
type Deal = {
    id: string;
    customer_id: string;
    zone_id: string;
    deal_point: number;
    citizenid: string;
    drug: string;
    qty: number;
    unit_price: number;
    original_qty: number;
    original_unit: number;
    state: "offered" | "negotiating" | "accepted" | "completed" | "failed";
    accepted_at: number;
    expires_at: number;
    created_at: number;
    countered_by?: "player" | "customer" | "customer_agreed" | null;
};

type Customer = {
    id: string;
    first_name: string;
    last_name: string;
    model: string;
};

type Zone = { id: string; label: string };

type MessagesPayload = {
    deals: Deal[];
    zones: Record<string, Zone>;
    customers: Record<string, Customer>;
};

export function MessagesApp({ onBack }: { onBack: () => void }) {
    const [snapshot, setSnapshot] = useState<MessagesPayload>({
        deals: [], zones: {}, customers: {},
    });
    const [openDealId, setOpenDealId] = useState<string | null>(null);

    // Initial fetch — subsequent updates come via dealingMessages pushes.
    useEffect(() => {
        let cancelled = false;
        (async () => {
            const data = (await fetchNui("dealingListMyDeals", {})) as
                | { deals: Deal[]; zones: Record<string, Zone>; customers: Record<string, Customer> }
                | undefined;
            if (cancelled || !data) return;
            setSnapshot(data);
        })();
        return () => { cancelled = true; };
    }, []);

    useNuiEvent<MessagesPayload>("dealingMessages", (d) => { if (d) setSnapshot(d); });

    const deals = useMemo(
        () => [...snapshot.deals].sort((a, b) => b.created_at - a.created_at),
        [snapshot.deals],
    );
    const openDeal = openDealId ? deals.find((d) => d.id === openDealId) : null;

    const customerName = (cid: string) => {
        const c = snapshot.customers[cid];
        return c ? `${c.first_name} ${c.last_name}`.trim() : "Customer";
    };

    return (
        <div className="absolute inset-0 flex flex-col bg-gradient-to-b from-zinc-900 to-zinc-950 text-white pt-6 pb-5">
            <div className="grid grid-cols-[1fr_auto_1fr] items-center px-3 pt-2 pb-3 border-b border-white/5">
                <button
                    onClick={openDeal ? () => setOpenDealId(null) : onBack}
                    className="flex items-center gap-1 text-amber-400 active:text-amber-300 active:scale-95 transition-transform justify-self-start"
                >
                    <ChevronLeft className="w-5 h-5" strokeWidth={2.5} />
                    <span className="text-[13px]">{openDeal ? "Inbox" : "Home"}</span>
                </button>
                <div className="text-[13px] font-semibold truncate">
                    {openDeal ? customerName(openDeal.customer_id) : "Messages"}
                </div>
                <div aria-hidden />
            </div>

            {openDeal ? (
                <DealConversation
                    deal={openDeal}
                    customerName={customerName(openDeal.customer_id)}
                    zoneLabel={snapshot.zones[openDeal.zone_id]?.label ?? "Unknown zone"}
                />
            ) : (
                <div className="phone-scroll flex-1 overflow-y-auto">
                    {deals.length === 0 ? (
                        <div className="px-3 py-12 text-center text-[12px] text-white/40">
                            <MessageSquare className="w-8 h-8 mx-auto mb-2 opacity-50" />
                            No messages yet. Hold some product and someone will reach out.
                        </div>
                    ) : (
                        deals.map((d, i) => (
                            <button
                                key={d.id}
                                onClick={() => setOpenDealId(d.id)}
                                className="w-full text-left px-3 py-2.5 border-b border-white/5 hover:bg-white/[0.03] active:bg-white/[0.06] flex items-start gap-2 animate-in fade-in slide-in-from-bottom-1 fill-mode-both"
                                style={{ animationDelay: `${i * 25}ms` }}
                            >
                                <div className="flex-none w-8 h-8 rounded-full bg-gradient-to-br from-amber-400 to-amber-600 ring-1 ring-white/15 flex items-center justify-center text-[11px] font-bold">
                                    {(snapshot.customers[d.customer_id]?.first_name ?? "?")[0]}
                                </div>
                                <div className="min-w-0 flex-1">
                                    <div className="flex items-baseline gap-2">
                                        <span className="text-[13px] font-semibold truncate">
                                            {customerName(d.customer_id)}
                                        </span>
                                        <span className="ml-auto text-[10px] text-white/35 tabular-nums">
                                            {timeAgo(d.created_at)}
                                        </span>
                                    </div>
                                    <div className="text-[11px] text-white/55 truncate">
                                        {previewLine(d)}
                                    </div>
                                </div>
                                <StateChip state={d.state} />
                            </button>
                        ))
                    )}
                </div>
            )}
        </div>
    );
}

function StateChip({ state }: { state: Deal["state"] }) {
    const tone = state === "accepted"
        ? "bg-emerald-500/20 text-emerald-200 ring-emerald-400/40"
        : state === "negotiating"
            ? "bg-amber-500/20 text-amber-200 ring-amber-400/40"
            : "bg-white/10 text-white/60 ring-white/20";
    return (
        <span className={`text-[9px] uppercase tracking-wider px-1.5 py-0.5 rounded ring-1 ${tone}`}>
            {state}
        </span>
    );
}

function previewLine(d: Deal) {
    if (d.state === "accepted") return `On it · ${d.qty} for $${d.qty * d.unit_price}`;
    if (d.state === "negotiating") {
        if (d.countered_by === "customer_agreed") return "They agreed to your terms.";
        if (d.countered_by === "customer") return `Counter offer: $${d.unit_price}/ea × ${d.qty}`;
    }
    return `Need ${d.qty}x ${d.drug} · $${d.unit_price}/ea`;
}

function DealConversation({
    deal, customerName, zoneLabel,
}: {
    deal: Deal;
    customerName: string;
    zoneLabel: string;
}) {
    const [counterQty, setCounterQty]     = useState(deal.qty);
    const [counterUnit, setCounterUnit]   = useState(deal.unit_price);
    const [showCounter, setShowCounter]   = useState(false);

    // Reset counter inputs when a new server reply lands.
    useEffect(() => {
        setCounterQty(deal.qty);
        setCounterUnit(deal.unit_price);
        setShowCounter(false);
    }, [deal.qty, deal.unit_price, deal.state, deal.countered_by]);

    const total = counterQty * counterUnit;
    const askTotal = deal.qty * deal.unit_price;
    const origTotal = deal.original_qty * deal.original_unit;

    const interactive = deal.state === "offered" || deal.state === "negotiating";

    return (
        <div className="phone-scroll flex-1 overflow-y-auto px-3 py-3 flex flex-col gap-2">
            <Bubble side="them" name={customerName}>
                Need <b>{deal.original_qty}× {deal.drug}</b>. Meet me in <b>{zoneLabel}</b>.
                I can do <b>${deal.original_unit}/ea</b> — that's <b>${origTotal}</b> total.
            </Bubble>

            {deal.state === "negotiating" && deal.countered_by === "customer" && (
                <Bubble side="them" name={customerName}>
                    Best I can do: <b>${deal.unit_price}/ea × {deal.qty}</b> = <b>${askTotal}</b>.
                </Bubble>
            )}
            {deal.state === "negotiating" && deal.countered_by === "customer_agreed" && (
                <Bubble side="them" name={customerName}>
                    Alright, your terms: <b>${deal.unit_price}/ea × {deal.qty}</b> = <b>${askTotal}</b>. Tap Accept to lock it in.
                </Bubble>
            )}

            {deal.state === "accepted" && (
                <Bubble side="me">Accepted — heading there now.</Bubble>
            )}

            {/* Action area */}
            {interactive && (
                <div className="mt-auto pt-2 sticky bottom-0 flex flex-col gap-2">
                    {showCounter && (
                        <div className="rounded-lg bg-white/[0.04] ring-1 ring-white/10 p-2 flex flex-col gap-2">
                            <div className="flex items-center gap-2">
                                <label className="flex-1 flex items-center gap-1 bg-black/30 ring-1 ring-white/10 rounded px-1.5 py-1 text-[11px]">
                                    <span className="text-white/45 w-7">Qty</span>
                                    <input
                                        type="number"
                                        min={1}
                                        max={deal.original_qty}
                                        value={counterQty}
                                        onChange={(e) => setCounterQty(Math.max(1, parseInt(e.target.value) || 1))}
                                        className="bg-transparent w-full outline-none tabular-nums"
                                    />
                                </label>
                                <label className="flex-1 flex items-center gap-1 bg-black/30 ring-1 ring-white/10 rounded px-1.5 py-1 text-[11px]">
                                    <span className="text-white/45 w-7">$/ea</span>
                                    <input
                                        type="number"
                                        min={1}
                                        value={counterUnit}
                                        onChange={(e) => setCounterUnit(Math.max(1, parseInt(e.target.value) || 1))}
                                        className="bg-transparent w-full outline-none tabular-nums"
                                    />
                                </label>
                            </div>
                            <div className="flex items-center justify-between text-[10px] text-white/55">
                                <span>Total <b className="text-white/85 tabular-nums">${total}</b></span>
                                <span>Ask was <b className="text-white/85 tabular-nums">${origTotal}</b></span>
                            </div>
                            <button
                                onClick={() => fetchNui("dealingCounter", { dealId: deal.id, qty: counterQty, unitPrice: counterUnit })}
                                className="w-full rounded-md bg-amber-500/30 ring-1 ring-amber-400/60 text-amber-50 py-1.5 text-[12px] font-semibold active:scale-[0.98] transition-transform"
                            >
                                Send counter
                            </button>
                        </div>
                    )}
                    <div className="grid grid-cols-3 gap-1.5">
                        <ActionButton
                            tone="rose"
                            icon={X}
                            label="Reject"
                            onClick={() => fetchNui("dealingReject", { dealId: deal.id })}
                        />
                        <ActionButton
                            tone="amber"
                            icon={Handshake}
                            label="Negotiate"
                            onClick={() => setShowCounter((s) => !s)}
                        />
                        <ActionButton
                            tone="emerald"
                            icon={Check}
                            label="Accept"
                            onClick={() => fetchNui("dealingAccept", { dealId: deal.id })}
                        />
                    </div>
                </div>
            )}
        </div>
    );
}

function ActionButton({
    tone, icon: Icon, label, onClick,
}: {
    tone: "rose" | "amber" | "emerald";
    icon: LucideIcon;
    label: string;
    onClick: () => void;
}) {
    const map = {
        rose:    "bg-rose-500/20 ring-rose-400/40 text-rose-100",
        amber:   "bg-amber-500/20 ring-amber-400/40 text-amber-100",
        emerald: "bg-emerald-500/20 ring-emerald-400/40 text-emerald-100",
    } as const;
    return (
        <button
            onClick={onClick}
            className={`flex items-center justify-center gap-1 rounded-md ring-1 py-1.5 text-[11px] font-semibold active:scale-95 transition-transform ${map[tone]}`}
        >
            <Icon className="w-3.5 h-3.5" strokeWidth={2.5} />
            {label}
        </button>
    );
}

function Bubble({ side, name, children }: { side: "me" | "them"; name?: string; children: React.ReactNode }) {
    const me = side === "me";
    return (
        <div className={`max-w-[80%] ${me ? "ml-auto" : ""}`}>
            {!me && name && <div className="text-[10px] text-white/40 mb-0.5 ml-1">{name}</div>}
            <div className={
                "px-3 py-2 rounded-2xl text-[12px] leading-snug " +
                (me
                    ? "bg-amber-500/20 ring-1 ring-amber-400/30 rounded-br-sm text-white"
                    : "bg-white/[0.06] ring-1 ring-white/10 rounded-bl-sm text-white/90")
            }>
                {children}
            </div>
        </div>
    );
}

function timeAgo(epochMs: number) {
    const dt = Math.max(0, Date.now() - epochMs);
    const m = Math.floor(dt / 60000);
    if (m < 1) return "now";
    if (m < 60) return `${m}m`;
    const h = Math.floor(m / 60);
    if (h < 24) return `${h}h`;
    return `${Math.floor(h / 24)}d`;
}
