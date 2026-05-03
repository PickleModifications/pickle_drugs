import { useEffect, useMemo, useState } from "react";
import { ChevronLeft, MessageSquare, Check, X, Handshake, Phone as PhoneIcon, Briefcase, Package, type LucideIcon } from "lucide-react";

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

// Personalised dealer slot — every player has their own randomised
// name + model per admin slot, and the `hired` flag is per-player too.
// Sharing across players is gone, so there's only one list now.
type DealerSlot = {
    id: string;
    first_name: string;
    last_name: string;
    model: string;
    zone_id: string;
    hired?: boolean;
    inventory?: Record<string, number>;
    cut_pct?: number;
};

type ThreadKey =
    | { kind: "deal"; id: string }
    | { kind: "dealer"; id: string };

export function MessagesApp({ onBack }: { onBack: () => void }) {
    const [snapshot, setSnapshot] = useState<MessagesPayload>({
        deals: [], zones: {}, customers: {},
    });
    // Personalised view of every admin slot. Each entry has the player's
    // own name/model and a `hired` flag controlling which conversation
    // panel renders.
    const [myDealers, setMyDealers] = useState<Record<string, DealerSlot>>({});
    // slotId → true when a meetup is currently scheduled. Pushed live by
    // the dealers client whenever a summoned ped is created/destroyed.
    const [summoned, setSummoned] = useState<Record<string, boolean>>({});
    const [openThread, setOpenThread] = useState<ThreadKey | null>(null);

    useEffect(() => {
        let cancelled = false;
        (async () => {
            const data = (await fetchNui("dealingListMyDeals", {})) as
                | { deals: Deal[]; zones: Record<string, Zone>; customers: Record<string, Customer> }
                | undefined;
            if (cancelled || !data) return;
            setSnapshot(data);
        })();
        (async () => {
            const mine = (await fetchNui("dealerListMine", {})) as DealerSlot[] | undefined;
            if (mine && !cancelled) setMyDealers(Object.fromEntries(mine.map((s) => [s.id, s])));
            const states = (await fetchNui("dealerSummonStates", {})) as string[] | undefined;
            if (states && !cancelled) {
                setSummoned(Object.fromEntries(states.map((id) => [id, true])));
            }
        })();
        return () => { cancelled = true; };
    }, []);

    useNuiEvent<MessagesPayload>("dealingMessages", (d) => { if (d) setSnapshot(d); });
    useNuiEvent<DealerSlot>("dealerSlotUpdate", (s) => {
        if (!s?.id) return;
        setMyDealers((p) => ({ ...p, [s.id]: s }));
    });
    useNuiEvent<string>("dealerSlotRemoved", (id) => {
        if (!id) return;
        setMyDealers((p) => { const n = { ...p }; delete n[id]; return n; });
        setOpenThread((t) => (t && t.kind === "dealer" && t.id === id ? null : t));
    });
    useNuiEvent<string>("dealerOwnerRemoved", () => {
        // Server has flipped our hired flag off; the dealerSlotUpdate
        // ack will land alongside this. No extra state to clear.
    });
    useNuiEvent<{ id: string; summoned: boolean }>("dealerSummonState", (d) => {
        if (!d?.id) return;
        setSummoned((p) => {
            if (d.summoned) return { ...p, [d.id]: true };
            const n = { ...p }; delete n[d.id]; return n;
        });
    });

    const deals = useMemo(
        () => [...snapshot.deals].sort((a, b) => b.created_at - a.created_at),
        [snapshot.deals],
    );

    // Personalised list — every admin slot has a row here. Sort hired
    // first so the player's existing dealers cluster at the top.
    const dealerList = useMemo(() => {
        const out = Object.values(myDealers).slice();
        out.sort((a, b) => {
            if (!!a.hired !== !!b.hired) return a.hired ? -1 : 1;
            return `${a.first_name} ${a.last_name}`.localeCompare(`${b.first_name} ${b.last_name}`);
        });
        return out;
    }, [myDealers]);

    const openDeal = openThread?.kind === "deal" ? deals.find((d) => d.id === openThread.id) : null;
    const openDealerSlot: DealerSlot | null = openThread?.kind === "dealer"
        ? (myDealers[openThread.id] ?? null)
        : null;
    const openDealerIsMine = !!openDealerSlot?.hired;

    // Resolve a dealer's single zone id into its label. Unknown ids fall
    // back to a short "?<id>" tag so a mid-edit zone delete is still
    // visible (vs silently dropped).
    const zoneLabelFor = (id: string): string =>
        snapshot.zones[id]?.label ?? `?${id.slice(0, 6)}`;

    const customerName = (cid: string) => {
        const c = snapshot.customers[cid];
        return c ? `${c.first_name} ${c.last_name}`.trim() : "Customer";
    };

    const headerTitle = openDeal
        ? customerName(openDeal.customer_id)
        : openDealerSlot
            ? `${openDealerSlot.first_name} ${openDealerSlot.last_name}`.trim()
            : "Messages";

    return (
        <div className="absolute inset-0 flex flex-col bg-gradient-to-b from-zinc-900 to-zinc-950 text-white pt-6 pb-5">
            <div className="grid grid-cols-[1fr_auto_1fr] items-center px-3 pt-2 pb-3 border-b border-white/5">
                <button
                    onClick={openThread ? () => setOpenThread(null) : onBack}
                    className="flex items-center gap-1 text-amber-400 active:text-amber-300 active:scale-95 transition-transform justify-self-start"
                >
                    <ChevronLeft className="w-5 h-5" strokeWidth={2.5} />
                    <span className="text-[13px]">{openThread ? "Inbox" : "Home"}</span>
                </button>
                <div className="text-[13px] font-semibold truncate">{headerTitle}</div>
                <div aria-hidden />
            </div>

            {openDeal ? (
                <DealConversation
                    deal={openDeal}
                    customerName={customerName(openDeal.customer_id)}
                    zoneLabel={snapshot.zones[openDeal.zone_id]?.label ?? "Unknown zone"}
                />
            ) : openDealerSlot ? (
                openDealerIsMine
                    ? <DealerConversation dealer={openDealerSlot} zoneLabel={zoneLabelFor(openDealerSlot.zone_id)} summoned={!!summoned[openDealerSlot.id]} />
                    : <HireDealerPrompt dealer={openDealerSlot} zoneLabel={zoneLabelFor(openDealerSlot.zone_id)} />
            ) : (
                <div className="phone-scroll flex-1 overflow-y-auto">
                    {dealerList.length > 0 && (
                        <div className="px-3 py-1.5 text-[10px] uppercase tracking-wider text-white/35 bg-white/[0.02]">
                            Dealers
                        </div>
                    )}
                    {dealerList.map((d) => {
                        const mine = !!d.hired;
                        const stock = mine
                            ? Object.values(d.inventory ?? {}).reduce((a, n) => a + (Number(n) || 0), 0)
                            : 0;
                        return (
                            <button
                                key={d.id}
                                onClick={() => setOpenThread({ kind: "dealer", id: d.id })}
                                className="w-full text-left px-3 py-2.5 border-b border-white/5 hover:bg-white/[0.03] active:bg-white/[0.06] flex items-start gap-2"
                            >
                                <div className={
                                    "flex-none w-8 h-8 rounded-full ring-1 ring-white/15 flex items-center justify-center " +
                                    (mine
                                        ? "bg-gradient-to-br from-emerald-400 to-emerald-600"
                                        : "bg-gradient-to-br from-zinc-500 to-zinc-700")
                                }>
                                    <Briefcase className="w-4 h-4 text-white" />
                                </div>
                                <div className="min-w-0 flex-1">
                                    <div className="flex items-baseline gap-2">
                                        <span className="text-[13px] font-semibold truncate">
                                            {d.first_name} {d.last_name}
                                        </span>
                                        {mine ? (
                                            <span className="ml-auto text-[10px] text-white/35 tabular-nums inline-flex items-center gap-1">
                                                <Package className="w-3 h-3" />{stock}
                                            </span>
                                        ) : (
                                            <span className="ml-auto text-[9px] uppercase tracking-wider px-1.5 py-0.5 rounded bg-amber-500/20 text-amber-200 ring-1 ring-amber-400/40">
                                                Available
                                            </span>
                                        )}
                                    </div>
                                    <div className="text-[11px] text-white/55 truncate">
                                        {mine
                                            ? (stock > 0
                                                ? `Carrying ${stock} item${stock === 1 ? "" : "s"}.`
                                                : "Standing by — give me product to start dealing.")
                                            : `Looking for work · ${zoneLabelFor(d.zone_id)}`}
                                    </div>
                                </div>
                            </button>
                        );
                    })}

                    {deals.length > 0 && (
                        <div className="px-3 py-1.5 text-[10px] uppercase tracking-wider text-white/35 bg-white/[0.02]">
                            Customers
                        </div>
                    )}
                    {dealerList.length === 0 && deals.length === 0 ? (
                        <div className="px-3 py-12 text-center text-[12px] text-white/40">
                            <MessageSquare className="w-8 h-8 mx-auto mb-2 opacity-50" />
                            No messages yet. Hire a dealer or hold some product and someone will reach out.
                        </div>
                    ) : (
                        deals.map((d, i) => (
                            <button
                                key={d.id}
                                onClick={() => setOpenThread({ kind: "deal", id: d.id })}
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

function HireDealerPrompt({ dealer, zoneLabel }: { dealer: DealerSlot; zoneLabel: string }) {
    const cut = Math.round((dealer.cut_pct ?? 0.10) * 100);
    return (
        <div className="phone-scroll flex-1 overflow-y-auto px-3 py-3 flex flex-col gap-2">
            <Bubble side="them" name={`${dealer.first_name} ${dealer.last_name}`}>
                Heard you need a hand. I work around <b>{zoneLabel}</b>. I'll close any deal that comes through while you stay clean.
            </Bubble>
            <Bubble side="them" name={`${dealer.first_name}`}>
                I take a <b>{cut}%</b> cut. The rest is yours.
            </Bubble>
            <div className="mt-auto pt-2 sticky bottom-0">
                <button
                    onClick={() => fetchNui("dealerHire", { id: dealer.id })}
                    className="w-full inline-flex items-center justify-center gap-1.5 rounded-md bg-amber-500/30 ring-1 ring-amber-400/60 text-amber-50 py-2 text-[13px] font-semibold active:scale-[0.98] transition-transform"
                >
                    <Handshake className="w-4 h-4" /> Hire {dealer.first_name}
                </button>
            </div>
        </div>
    );
}

function DealerConversation({ dealer, zoneLabel, summoned }: { dealer: DealerSlot; zoneLabel: string; summoned: boolean }) {
    const stock = Object.entries(dealer.inventory ?? {}).filter(([, n]) => (Number(n) || 0) > 0);
    const total = stock.reduce((a, [, n]) => a + (Number(n) || 0), 0);

    return (
        <div className="phone-scroll flex-1 overflow-y-auto px-3 py-3 flex flex-col gap-2">
            <Bubble side="them" name={`${dealer.first_name} ${dealer.last_name}`}>
                On call. I'll handle anyone who hits up <b>{zoneLabel}</b> for you.
            </Bubble>
            {total > 0 ? (
                <Bubble side="them" name={`${dealer.first_name}`}>
                    Carrying:
                    <ul className="mt-1 ml-3 list-disc">
                        {stock.map(([item, n]) => (
                            <li key={item} className="tabular-nums">
                                {item} <span className="text-white/55">× {n}</span>
                            </li>
                        ))}
                    </ul>
                </Bubble>
            ) : (
                <Bubble side="them" name={`${dealer.first_name}`}>
                    I'm out of product. Summon me and hand some over.
                </Bubble>
            )}
            <div className="mt-auto pt-2 sticky bottom-0">
                {summoned ? (
                    <button
                        onClick={() => fetchNui("dealerCancelSummon", { id: dealer.id })}
                        className="w-full inline-flex items-center justify-center gap-1.5 rounded-md bg-rose-500/25 ring-1 ring-rose-400/60 text-rose-50 py-2 text-[13px] font-semibold active:scale-[0.98] transition-transform"
                    >
                        <X className="w-4 h-4" /> Cancel Meetup
                    </button>
                ) : (
                    <button
                        onClick={() => fetchNui("dealerSummon", { id: dealer.id })}
                        className="w-full inline-flex items-center justify-center gap-1.5 rounded-md bg-emerald-500/25 ring-1 ring-emerald-400/60 text-emerald-50 py-2 text-[13px] font-semibold active:scale-[0.98] transition-transform"
                    >
                        <PhoneIcon className="w-4 h-4" /> Schedule Meetup
                    </button>
                )}
            </div>
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
