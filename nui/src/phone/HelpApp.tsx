import {
    Home,
    Sprout,
    Mountain,
    Leaf,
    Droplet,
    Scissors,
    Archive,
    Users,
    ChevronLeft,
    type LucideIcon,
} from "lucide-react";

type Tip = {
    icon: LucideIcon;
    title: string;
    body: string;
    tone: string; // tailwind gradient classes for the icon tile
};

const TIPS: Tip[] = [
    {
        icon: Home,
        title: "Find a place to grow",
        body: "Start by securing a property — your operation lives inside a house. Speak to a landlord or check the property doors around the city.",
        tone: "from-sky-500/40 to-sky-500/10 text-sky-200",
    },
    {
        icon: Sprout,
        title: "Drop a planter",
        body: "Pick up an empty planter, then use it from your inventory while inside your property to start placing a pot on the floor grid.",
        tone: "from-emerald-500/40 to-emerald-500/10 text-emerald-200",
    },
    {
        icon: Mountain,
        title: "Add soil",
        body: "Interact with the empty pot and choose Add Soil. You'll need a bag of soil in your inventory to fill it.",
        tone: "from-amber-500/40 to-amber-500/10 text-amber-200",
    },
    {
        icon: Leaf,
        title: "Plant a seed",
        body: "Once soiled, interact with the pot again to plant a seed. Different drugs use different seeds — buy whichever variety you want to grow.",
        tone: "from-lime-500/40 to-lime-500/10 text-lime-200",
    },
    {
        icon: Droplet,
        title: "Keep it watered",
        body: "Plants drink slowly while they grow. Pick up a watering pitcher (it doesn't get used up) and refill the reservoir before it runs dry.",
        tone: "from-blue-500/40 to-blue-500/10 text-blue-200",
    },
    {
        icon: Scissors,
        title: "Harvest the buds",
        body: "When a plant matures, interact with it and choose Harvest. You'll need trimming scissors to cut each bud off the plant.",
        tone: "from-rose-500/40 to-rose-500/10 text-rose-200",
    },
    {
        icon: Archive,
        title: "Store the haul",
        body: "Place a storage locker the same way you placed the pot. Open a plot's settings and assign that locker as its output to auto-route harvests.",
        tone: "from-violet-500/40 to-violet-500/10 text-violet-200",
    },
    {
        icon: Users,
        title: "Hire help (optional)",
        body: "Once your operation is humming, an admin can spawn an employee for you. Assign them plots and they'll soil, plant, water, and harvest on their own.",
        tone: "from-fuchsia-500/40 to-fuchsia-500/10 text-fuchsia-200",
    },
];

export function HelpApp({ onBack }: { onBack: () => void }) {
    return (
        // pt-6 + pb-5 reserves the iPhone-style "safe area": clear of
        // the notch up top and the home indicator bar below. The
        // status bar is short enough that a tighter top inset still
        // keeps the header text out from under the notch.
        <div className="absolute inset-0 flex flex-col bg-gradient-to-b from-zinc-900 to-zinc-950 text-white pt-6 pb-5">
            {/* Header — three equal-width columns so the title is
                truly centered regardless of the back button's text
                width. (Previous flex-1 + pr-12 pushed the title off
                whenever the back label changed length.) */}
            <div className="grid grid-cols-[1fr_auto_1fr] items-center px-3 pt-2 pb-3 border-b border-white/5">
                <button
                    onClick={onBack}
                    className="flex items-center gap-1 text-sky-400 active:text-sky-300 active:scale-95 transition-transform justify-self-start"
                >
                    <ChevronLeft className="w-5 h-5" strokeWidth={2.5} />
                    <span className="text-[13px]">Home</span>
                </button>
                <div className="text-[13px] font-semibold">Help</div>
                <div aria-hidden />
            </div>

            {/* Tips */}
            <div className="phone-scroll flex-1 overflow-y-auto px-3 py-3 space-y-2">
                <div className="px-1 pb-1">
                    <div className="text-[11px] uppercase tracking-[0.14em] text-white/40">
                        Getting started
                    </div>
                    <div className="text-[10px] text-white/30 mt-0.5">
                        Follow these in order — each step unlocks the next.
                    </div>
                </div>
                {TIPS.map((tip, i) => (
                    <TipCard key={i} tip={tip} index={i} />
                ))}
                <div className="h-2" />
            </div>
        </div>
    );
}

function TipCard({ tip, index }: { tip: Tip; index: number }) {
    const Icon = tip.icon;
    return (
        <div
            className="flex items-start gap-3 rounded-xl bg-white/[0.04] ring-1 ring-white/5 p-3 animate-in fade-in slide-in-from-bottom-2 duration-300 fill-mode-both"
            style={{ animationDelay: `${index * 35}ms` }}
        >
            <div
                className={`flex-none w-9 h-9 rounded-lg bg-gradient-to-br ${tip.tone} ring-1 ring-white/10 flex items-center justify-center`}
            >
                <Icon className="w-4 h-4" strokeWidth={2} />
            </div>
            <div className="min-w-0 flex-1 pt-0.5">
                <div className="flex items-baseline gap-2">
                    <span className="text-[10px] font-mono text-white/30 tabular-nums">
                        {String(index + 1).padStart(2, "0")}
                    </span>
                    <div className="text-[13px] font-semibold leading-tight">
                        {tip.title}
                    </div>
                </div>
                <div className="text-[11.5px] text-white/60 leading-snug mt-1">
                    {tip.body}
                </div>
            </div>
        </div>
    );
}
