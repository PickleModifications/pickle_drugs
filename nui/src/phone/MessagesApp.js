import { jsx as _jsx, jsxs as _jsxs } from "react/jsx-runtime";
import { useEffect, useMemo, useState } from "react";
import { ChevronLeft, MessageSquare, Check, X, Handshake } from "lucide-react";
import { fetchNui, useNuiEvent } from "@/lib/nui";
export function MessagesApp({ onBack }) {
    const [snapshot, setSnapshot] = useState({
        deals: [], zones: {}, customers: {},
    });
    const [openDealId, setOpenDealId] = useState(null);
    // Initial fetch — subsequent updates come via dealingMessages pushes.
    useEffect(() => {
        let cancelled = false;
        (async () => {
            const data = (await fetchNui("dealingListMyDeals", {}));
            if (cancelled || !data)
                return;
            setSnapshot(data);
        })();
        return () => { cancelled = true; };
    }, []);
    useNuiEvent("dealingMessages", (d) => { if (d)
        setSnapshot(d); });
    const deals = useMemo(() => [...snapshot.deals].sort((a, b) => b.created_at - a.created_at), [snapshot.deals]);
    const openDeal = openDealId ? deals.find((d) => d.id === openDealId) : null;
    const customerName = (cid) => {
        const c = snapshot.customers[cid];
        return c ? `${c.first_name} ${c.last_name}`.trim() : "Customer";
    };
    return (_jsxs("div", { className: "absolute inset-0 flex flex-col bg-gradient-to-b from-zinc-900 to-zinc-950 text-white pt-6 pb-5", children: [_jsxs("div", { className: "grid grid-cols-[1fr_auto_1fr] items-center px-3 pt-2 pb-3 border-b border-white/5", children: [_jsxs("button", { onClick: openDeal ? () => setOpenDealId(null) : onBack, className: "flex items-center gap-1 text-amber-400 active:text-amber-300 active:scale-95 transition-transform justify-self-start", children: [_jsx(ChevronLeft, { className: "w-5 h-5", strokeWidth: 2.5 }), _jsx("span", { className: "text-[13px]", children: openDeal ? "Inbox" : "Home" })] }), _jsx("div", { className: "text-[13px] font-semibold truncate", children: openDeal ? customerName(openDeal.customer_id) : "Messages" }), _jsx("div", { "aria-hidden": true })] }), openDeal ? (_jsx(DealConversation, { deal: openDeal, customerName: customerName(openDeal.customer_id), zoneLabel: snapshot.zones[openDeal.zone_id]?.label ?? "Unknown zone" })) : (_jsx("div", { className: "phone-scroll flex-1 overflow-y-auto", children: deals.length === 0 ? (_jsxs("div", { className: "px-3 py-12 text-center text-[12px] text-white/40", children: [_jsx(MessageSquare, { className: "w-8 h-8 mx-auto mb-2 opacity-50" }), "No messages yet. Hold some product and someone will reach out."] })) : (deals.map((d, i) => (_jsxs("button", { onClick: () => setOpenDealId(d.id), className: "w-full text-left px-3 py-2.5 border-b border-white/5 hover:bg-white/[0.03] active:bg-white/[0.06] flex items-start gap-2 animate-in fade-in slide-in-from-bottom-1 fill-mode-both", style: { animationDelay: `${i * 25}ms` }, children: [_jsx("div", { className: "flex-none w-8 h-8 rounded-full bg-gradient-to-br from-amber-400 to-amber-600 ring-1 ring-white/15 flex items-center justify-center text-[11px] font-bold", children: (snapshot.customers[d.customer_id]?.first_name ?? "?")[0] }), _jsxs("div", { className: "min-w-0 flex-1", children: [_jsxs("div", { className: "flex items-baseline gap-2", children: [_jsx("span", { className: "text-[13px] font-semibold truncate", children: customerName(d.customer_id) }), _jsx("span", { className: "ml-auto text-[10px] text-white/35 tabular-nums", children: timeAgo(d.created_at) })] }), _jsx("div", { className: "text-[11px] text-white/55 truncate", children: previewLine(d) })] }), _jsx(StateChip, { state: d.state })] }, d.id)))) }))] }));
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
