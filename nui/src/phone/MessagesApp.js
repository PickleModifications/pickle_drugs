import { jsx as _jsx, jsxs as _jsxs, Fragment as _Fragment } from "react/jsx-runtime";
import { useEffect, useMemo, useState } from "react";
import { ChevronLeft, MessageSquare, Check, X, Handshake, Phone as PhoneIcon, Briefcase, Package } from "lucide-react";
import { fetchNui, useNuiEvent } from "@/lib/nui";
export function MessagesApp({ onBack }) {
    const [snapshot, setSnapshot] = useState({
        deals: [], zones: {}, customers: {},
    });
    // Two stores so we can tell "my owned slot" apart from "public slot
    // someone else hired" — the latter is hidden from the inbox so the
    // list only shows actionable threads.
    const [publicDealers, setPublicDealers] = useState({});
    const [ownedDealers, setOwnedDealers] = useState({});
    // slotId → true when a meetup is currently scheduled. Pushed live by
    // the dealers client whenever a summoned ped is created/destroyed.
    const [summoned, setSummoned] = useState({});
    const [openThread, setOpenThread] = useState(null);
    useEffect(() => {
        let cancelled = false;
        (async () => {
            const data = (await fetchNui("dealingListMyDeals", {}));
            if (cancelled || !data)
                return;
            setSnapshot(data);
        })();
        (async () => {
            const pub = (await fetchNui("dealerListPublic", {}));
            if (pub && !cancelled)
                setPublicDealers(Object.fromEntries(pub.map((s) => [s.id, s])));
            const mine = (await fetchNui("dealerListMine", {}));
            if (mine && !cancelled)
                setOwnedDealers(Object.fromEntries(mine.map((s) => [s.id, s])));
            const states = (await fetchNui("dealerSummonStates", {}));
            if (states && !cancelled) {
                setSummoned(Object.fromEntries(states.map((id) => [id, true])));
            }
        })();
        return () => { cancelled = true; };
    }, []);
    useNuiEvent("dealingMessages", (d) => { if (d)
        setSnapshot(d); });
    useNuiEvent("dealerSlotUpdate", (s) => {
        if (!s?.id)
            return;
        setPublicDealers((p) => ({ ...p, [s.id]: s }));
    });
    useNuiEvent("dealerSlotRemoved", (id) => {
        if (!id)
            return;
        setPublicDealers((p) => { const n = { ...p }; delete n[id]; return n; });
        setOwnedDealers((p) => { const n = { ...p }; delete n[id]; return n; });
        setOpenThread((t) => (t && t.kind === "dealer" && t.id === id ? null : t));
    });
    useNuiEvent("dealerOwnerUpdate", (s) => {
        if (!s?.id)
            return;
        setOwnedDealers((p) => ({ ...p, [s.id]: s }));
    });
    useNuiEvent("dealerOwnerRemoved", (id) => {
        if (!id)
            return;
        setOwnedDealers((p) => { const n = { ...p }; delete n[id]; return n; });
    });
    useNuiEvent("dealerSummonState", (d) => {
        if (!d?.id)
            return;
        setSummoned((p) => {
            if (d.summoned)
                return { ...p, [d.id]: true };
            const n = { ...p };
            delete n[d.id];
            return n;
        });
    });
    const deals = useMemo(() => [...snapshot.deals].sort((a, b) => b.created_at - a.created_at), [snapshot.deals]);
    // Visible threads = (a) every dealer I own, (b) every unhired dealer.
    // Dealers hired by other players are hidden — the inbox is for
    // actionable threads only.
    const dealerList = useMemo(() => {
        const out = [];
        const seen = {};
        for (const s of Object.values(ownedDealers)) {
            out.push(s);
            seen[s.id] = true;
        }
        for (const s of Object.values(publicDealers)) {
            if (seen[s.id])
                continue;
            if (!s.hired)
                out.push(s);
        }
        out.sort((a, b) => `${a.first_name} ${a.last_name}`.localeCompare(`${b.first_name} ${b.last_name}`));
        return out;
    }, [publicDealers, ownedDealers]);
    const openDeal = openThread?.kind === "deal" ? deals.find((d) => d.id === openThread.id) : null;
    const openDealerSlot = openThread?.kind === "dealer"
        ? (ownedDealers[openThread.id] ?? publicDealers[openThread.id] ?? null)
        : null;
    const openDealerIsMine = openDealerSlot ? !!ownedDealers[openDealerSlot.id] : false;
    // Resolve a dealer's zone-id list into the labels stored in
    // snapshot.zones. Unknown ids fall back to a short "?<id>" tag so a
    // mid-edit zone delete is still visible (vs silently dropped).
    const zoneLabelsFor = (ids) => ids.map((id) => snapshot.zones[id]?.label ?? `?${id.slice(0, 6)}`);
    const customerName = (cid) => {
        const c = snapshot.customers[cid];
        return c ? `${c.first_name} ${c.last_name}`.trim() : "Customer";
    };
    const headerTitle = openDeal
        ? customerName(openDeal.customer_id)
        : openDealerSlot
            ? `${openDealerSlot.first_name} ${openDealerSlot.last_name}`.trim()
            : "Messages";
    return (_jsxs("div", { className: "absolute inset-0 flex flex-col bg-gradient-to-b from-zinc-900 to-zinc-950 text-white pt-6 pb-5", children: [_jsxs("div", { className: "grid grid-cols-[1fr_auto_1fr] items-center px-3 pt-2 pb-3 border-b border-white/5", children: [_jsxs("button", { onClick: openThread ? () => setOpenThread(null) : onBack, className: "flex items-center gap-1 text-amber-400 active:text-amber-300 active:scale-95 transition-transform justify-self-start", children: [_jsx(ChevronLeft, { className: "w-5 h-5", strokeWidth: 2.5 }), _jsx("span", { className: "text-[13px]", children: openThread ? "Inbox" : "Home" })] }), _jsx("div", { className: "text-[13px] font-semibold truncate", children: headerTitle }), _jsx("div", { "aria-hidden": true })] }), openDeal ? (_jsx(DealConversation, { deal: openDeal, customerName: customerName(openDeal.customer_id), zoneLabel: snapshot.zones[openDeal.zone_id]?.label ?? "Unknown zone" })) : openDealerSlot ? (openDealerIsMine
                ? _jsx(DealerConversation, { dealer: openDealerSlot, zoneLabels: zoneLabelsFor(openDealerSlot.zones), summoned: !!summoned[openDealerSlot.id] })
                : _jsx(HireDealerPrompt, { dealer: openDealerSlot, zoneLabels: zoneLabelsFor(openDealerSlot.zones) })) : (_jsxs("div", { className: "phone-scroll flex-1 overflow-y-auto", children: [dealerList.length > 0 && (_jsx("div", { className: "px-3 py-1.5 text-[10px] uppercase tracking-wider text-white/35 bg-white/[0.02]", children: "Dealers" })), dealerList.map((d) => {
                        const mine = !!ownedDealers[d.id];
                        const stock = mine
                            ? Object.values(d.inventory ?? {}).reduce((a, n) => a + (Number(n) || 0), 0)
                            : 0;
                        return (_jsxs("button", { onClick: () => setOpenThread({ kind: "dealer", id: d.id }), className: "w-full text-left px-3 py-2.5 border-b border-white/5 hover:bg-white/[0.03] active:bg-white/[0.06] flex items-start gap-2", children: [_jsx("div", { className: "flex-none w-8 h-8 rounded-full ring-1 ring-white/15 flex items-center justify-center " +
                                        (mine
                                            ? "bg-gradient-to-br from-emerald-400 to-emerald-600"
                                            : "bg-gradient-to-br from-zinc-500 to-zinc-700"), children: _jsx(Briefcase, { className: "w-4 h-4 text-white" }) }), _jsxs("div", { className: "min-w-0 flex-1", children: [_jsxs("div", { className: "flex items-baseline gap-2", children: [_jsxs("span", { className: "text-[13px] font-semibold truncate", children: [d.first_name, " ", d.last_name] }), mine ? (_jsxs("span", { className: "ml-auto text-[10px] text-white/35 tabular-nums inline-flex items-center gap-1", children: [_jsx(Package, { className: "w-3 h-3" }), stock] })) : (_jsx("span", { className: "ml-auto text-[9px] uppercase tracking-wider px-1.5 py-0.5 rounded bg-amber-500/20 text-amber-200 ring-1 ring-amber-400/40", children: "Available" }))] }), _jsx("div", { className: "text-[11px] text-white/55 truncate", children: mine
                                                ? (stock > 0
                                                    ? `Carrying ${stock} item${stock === 1 ? "" : "s"}.`
                                                    : "Standing by — give me product to start dealing.")
                                                : (d.zones.length > 0
                                                    ? `Looking for work · ${zoneLabelsFor(d.zones).join(", ")}`
                                                    : "Looking for work · no zones assigned") })] })] }, d.id));
                    }), deals.length > 0 && (_jsx("div", { className: "px-3 py-1.5 text-[10px] uppercase tracking-wider text-white/35 bg-white/[0.02]", children: "Customers" })), dealerList.length === 0 && deals.length === 0 ? (_jsxs("div", { className: "px-3 py-12 text-center text-[12px] text-white/40", children: [_jsx(MessageSquare, { className: "w-8 h-8 mx-auto mb-2 opacity-50" }), "No messages yet. Hire a dealer or hold some product and someone will reach out."] })) : (deals.map((d, i) => (_jsxs("button", { onClick: () => setOpenThread({ kind: "deal", id: d.id }), className: "w-full text-left px-3 py-2.5 border-b border-white/5 hover:bg-white/[0.03] active:bg-white/[0.06] flex items-start gap-2 animate-in fade-in slide-in-from-bottom-1 fill-mode-both", style: { animationDelay: `${i * 25}ms` }, children: [_jsx("div", { className: "flex-none w-8 h-8 rounded-full bg-gradient-to-br from-amber-400 to-amber-600 ring-1 ring-white/15 flex items-center justify-center text-[11px] font-bold", children: (snapshot.customers[d.customer_id]?.first_name ?? "?")[0] }), _jsxs("div", { className: "min-w-0 flex-1", children: [_jsxs("div", { className: "flex items-baseline gap-2", children: [_jsx("span", { className: "text-[13px] font-semibold truncate", children: customerName(d.customer_id) }), _jsx("span", { className: "ml-auto text-[10px] text-white/35 tabular-nums", children: timeAgo(d.created_at) })] }), _jsx("div", { className: "text-[11px] text-white/55 truncate", children: previewLine(d) })] }), _jsx(StateChip, { state: d.state })] }, d.id))))] }))] }));
}
function HireDealerPrompt({ dealer, zoneLabels }) {
    const cut = Math.round((dealer.cut_pct ?? 0.10) * 100);
    return (_jsxs("div", { className: "phone-scroll flex-1 overflow-y-auto px-3 py-3 flex flex-col gap-2", children: [_jsxs(Bubble, { side: "them", name: `${dealer.first_name} ${dealer.last_name}`, children: ["Heard you need a hand. I work ", zoneLabels.length > 0
                        ? _jsxs(_Fragment, { children: ["around ", _jsx("b", { children: zoneLabels.join(", ") })] })
                        : "wherever you point me", ". I'll close any deal that comes through while you stay clean."] }), _jsxs(Bubble, { side: "them", name: `${dealer.first_name}`, children: ["I take a ", _jsxs("b", { children: [cut, "%"] }), " cut. The rest is yours."] }), _jsx("div", { className: "mt-auto pt-2 sticky bottom-0", children: _jsxs("button", { onClick: () => fetchNui("dealerHire", { id: dealer.id }), className: "w-full inline-flex items-center justify-center gap-1.5 rounded-md bg-amber-500/30 ring-1 ring-amber-400/60 text-amber-50 py-2 text-[13px] font-semibold active:scale-[0.98] transition-transform", children: [_jsx(Handshake, { className: "w-4 h-4" }), " Hire ", dealer.first_name] }) })] }));
}
function DealerConversation({ dealer, zoneLabels, summoned }) {
    const stock = Object.entries(dealer.inventory ?? {}).filter(([, n]) => (Number(n) || 0) > 0);
    const total = stock.reduce((a, [, n]) => a + (Number(n) || 0), 0);
    return (_jsxs("div", { className: "phone-scroll flex-1 overflow-y-auto px-3 py-3 flex flex-col gap-2", children: [_jsxs(Bubble, { side: "them", name: `${dealer.first_name} ${dealer.last_name}`, children: ["On call. I'll handle anyone who hits up ", zoneLabels.length > 0
                        ? _jsx("b", { children: zoneLabels.join(", ") })
                        : "the zones you assign me", " for you."] }), total > 0 ? (_jsxs(Bubble, { side: "them", name: `${dealer.first_name}`, children: ["Carrying:", _jsx("ul", { className: "mt-1 ml-3 list-disc", children: stock.map(([item, n]) => (_jsxs("li", { className: "tabular-nums", children: [item, " ", _jsxs("span", { className: "text-white/55", children: ["\u00D7 ", n] })] }, item))) })] })) : (_jsx(Bubble, { side: "them", name: `${dealer.first_name}`, children: "I'm out of product. Summon me and hand some over." })), _jsx("div", { className: "mt-auto pt-2 sticky bottom-0", children: summoned ? (_jsxs("button", { onClick: () => fetchNui("dealerCancelSummon", { id: dealer.id }), className: "w-full inline-flex items-center justify-center gap-1.5 rounded-md bg-rose-500/25 ring-1 ring-rose-400/60 text-rose-50 py-2 text-[13px] font-semibold active:scale-[0.98] transition-transform", children: [_jsx(X, { className: "w-4 h-4" }), " Cancel Meetup"] })) : (_jsxs("button", { onClick: () => fetchNui("dealerSummon", { id: dealer.id }), className: "w-full inline-flex items-center justify-center gap-1.5 rounded-md bg-emerald-500/25 ring-1 ring-emerald-400/60 text-emerald-50 py-2 text-[13px] font-semibold active:scale-[0.98] transition-transform", children: [_jsx(PhoneIcon, { className: "w-4 h-4" }), " Schedule Meetup"] })) })] }));
}
function StateChip({ state }) {
    const tone = state === "accepted"
        ? "bg-emerald-500/20 text-emerald-200 ring-emerald-400/40"
        : state === "negotiating"
            ? "bg-amber-500/20 text-amber-200 ring-amber-400/40"
            : "bg-white/10 text-white/60 ring-white/20";
    return (_jsx("span", { className: `text-[9px] uppercase tracking-wider px-1.5 py-0.5 rounded ring-1 ${tone}`, children: state }));
}
function previewLine(d) {
    if (d.state === "accepted")
        return `On it · ${d.qty} for $${d.qty * d.unit_price}`;
    if (d.state === "negotiating") {
        if (d.countered_by === "customer_agreed")
            return "They agreed to your terms.";
        if (d.countered_by === "customer")
            return `Counter offer: $${d.unit_price}/ea × ${d.qty}`;
    }
    return `Need ${d.qty}x ${d.drug} · $${d.unit_price}/ea`;
}
function DealConversation({ deal, customerName, zoneLabel, }) {
    const [counterQty, setCounterQty] = useState(deal.qty);
    const [counterUnit, setCounterUnit] = useState(deal.unit_price);
    const [showCounter, setShowCounter] = useState(false);
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
    return (_jsxs("div", { className: "phone-scroll flex-1 overflow-y-auto px-3 py-3 flex flex-col gap-2", children: [_jsxs(Bubble, { side: "them", name: customerName, children: ["Need ", _jsxs("b", { children: [deal.original_qty, "\u00D7 ", deal.drug] }), ". Meet me in ", _jsx("b", { children: zoneLabel }), ". I can do ", _jsxs("b", { children: ["$", deal.original_unit, "/ea"] }), " \u2014 that's ", _jsxs("b", { children: ["$", origTotal] }), " total."] }), deal.state === "negotiating" && deal.countered_by === "customer" && (_jsxs(Bubble, { side: "them", name: customerName, children: ["Best I can do: ", _jsxs("b", { children: ["$", deal.unit_price, "/ea \u00D7 ", deal.qty] }), " = ", _jsxs("b", { children: ["$", askTotal] }), "."] })), deal.state === "negotiating" && deal.countered_by === "customer_agreed" && (_jsxs(Bubble, { side: "them", name: customerName, children: ["Alright, your terms: ", _jsxs("b", { children: ["$", deal.unit_price, "/ea \u00D7 ", deal.qty] }), " = ", _jsxs("b", { children: ["$", askTotal] }), ". Tap Accept to lock it in."] })), deal.state === "accepted" && (_jsx(Bubble, { side: "me", children: "Accepted \u2014 heading there now." })), interactive && (_jsxs("div", { className: "mt-auto pt-2 sticky bottom-0 flex flex-col gap-2", children: [showCounter && (_jsxs("div", { className: "rounded-lg bg-white/[0.04] ring-1 ring-white/10 p-2 flex flex-col gap-2", children: [_jsxs("div", { className: "flex items-center gap-2", children: [_jsxs("label", { className: "flex-1 flex items-center gap-1 bg-black/30 ring-1 ring-white/10 rounded px-1.5 py-1 text-[11px]", children: [_jsx("span", { className: "text-white/45 w-7", children: "Qty" }), _jsx("input", { type: "number", min: 1, max: deal.original_qty, value: counterQty, onChange: (e) => setCounterQty(Math.max(1, parseInt(e.target.value) || 1)), className: "bg-transparent w-full outline-none tabular-nums" })] }), _jsxs("label", { className: "flex-1 flex items-center gap-1 bg-black/30 ring-1 ring-white/10 rounded px-1.5 py-1 text-[11px]", children: [_jsx("span", { className: "text-white/45 w-7", children: "$/ea" }), _jsx("input", { type: "number", min: 1, value: counterUnit, onChange: (e) => setCounterUnit(Math.max(1, parseInt(e.target.value) || 1)), className: "bg-transparent w-full outline-none tabular-nums" })] })] }), _jsxs("div", { className: "flex items-center justify-between text-[10px] text-white/55", children: [_jsxs("span", { children: ["Total ", _jsxs("b", { className: "text-white/85 tabular-nums", children: ["$", total] })] }), _jsxs("span", { children: ["Ask was ", _jsxs("b", { className: "text-white/85 tabular-nums", children: ["$", origTotal] })] })] }), _jsx("button", { onClick: () => fetchNui("dealingCounter", { dealId: deal.id, qty: counterQty, unitPrice: counterUnit }), className: "w-full rounded-md bg-amber-500/30 ring-1 ring-amber-400/60 text-amber-50 py-1.5 text-[12px] font-semibold active:scale-[0.98] transition-transform", children: "Send counter" })] })), _jsxs("div", { className: "grid grid-cols-3 gap-1.5", children: [_jsx(ActionButton, { tone: "rose", icon: X, label: "Reject", onClick: () => fetchNui("dealingReject", { dealId: deal.id }) }), _jsx(ActionButton, { tone: "amber", icon: Handshake, label: "Negotiate", onClick: () => setShowCounter((s) => !s) }), _jsx(ActionButton, { tone: "emerald", icon: Check, label: "Accept", onClick: () => fetchNui("dealingAccept", { dealId: deal.id }) })] })] }))] }));
}
function ActionButton({ tone, icon: Icon, label, onClick, }) {
    const map = {
        rose: "bg-rose-500/20 ring-rose-400/40 text-rose-100",
        amber: "bg-amber-500/20 ring-amber-400/40 text-amber-100",
        emerald: "bg-emerald-500/20 ring-emerald-400/40 text-emerald-100",
    };
    return (_jsxs("button", { onClick: onClick, className: `flex items-center justify-center gap-1 rounded-md ring-1 py-1.5 text-[11px] font-semibold active:scale-95 transition-transform ${map[tone]}`, children: [_jsx(Icon, { className: "w-3.5 h-3.5", strokeWidth: 2.5 }), label] }));
}
function Bubble({ side, name, children }) {
    const me = side === "me";
    return (_jsxs("div", { className: `max-w-[80%] ${me ? "ml-auto" : ""}`, children: [!me && name && _jsx("div", { className: "text-[10px] text-white/40 mb-0.5 ml-1", children: name }), _jsx("div", { className: "px-3 py-2 rounded-2xl text-[12px] leading-snug " +
                    (me
                        ? "bg-amber-500/20 ring-1 ring-amber-400/30 rounded-br-sm text-white"
                        : "bg-white/[0.06] ring-1 ring-white/10 rounded-bl-sm text-white/90"), children: children })] }));
}
function timeAgo(epochMs) {
    const dt = Math.max(0, Date.now() - epochMs);
    const m = Math.floor(dt / 60000);
    if (m < 1)
        return "now";
    if (m < 60)
        return `${m}m`;
    const h = Math.floor(m / 60);
    if (h < 24)
        return `${h}h`;
    return `${Math.floor(h / 24)}d`;
}
