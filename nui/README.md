# pickle_drugs NUI

Vite + React + Tailwind + shadcn/ui base.

## Setup

```bash
cd nui
npm install
npm run build
```

`npm run build` outputs to `nui/dist/`, which is what `fxmanifest.lua` serves
to CEF via `ui_page`. Re-run after every change, or use `npm run dev` plus a
browser preview while iterating on layout.

## Adding shadcn components

```bash
npx shadcn@latest add dialog
```

Components land in `src/components/ui/`. The `components.json` config is
already wired up with the `@/` alias and `new-york` style.

## NUI bridge

- `fetchNui(name, data)` — POSTs to a `RegisterNUICallback(name, ...)` on the Lua side.
- `useNuiEvent(action, handler)` — subscribes to `SendNUIMessage({ action, data })`.
