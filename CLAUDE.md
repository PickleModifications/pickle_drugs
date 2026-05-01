# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this resource is

`pickle_drugs` is a FiveM resource (txAdmin server-data layout, escrow-ignored) that implements a player-grown drug cultivation system. It's a Lua resource with a React/Vite NUI surface for in-game panels and HUDs.

## Build / dev

There is no Lua build step — Lua files are loaded directly by `fxmanifest.lua`. The only build is the NUI bundle:

```bash
cd nui
npm install         # first time
npm run build       # tsc -b && vite build → outputs to nui/dist/
npm run dev         # vite dev server for layout iteration
```

`fxmanifest.lua` serves `nui/dist/index.html` via `ui_page`, so **after any change under `nui/src/` (or NUI config), `npm run build` must be re-run** before the change is visible in-game.

There is no test suite, linter, or formatter wired up in this repo.

## Architecture

### Lua module layout

`fxmanifest.lua` globs all modules with these load orders, which the code relies on:

- `shared_scripts`: `@ox_lib/init.lua` → `config.lua` → `core/shared.lua` → `modules/**/shared.lua`
- `client_scripts`: `bridge/**/client.lua` → `core/client.lua` → `modules/plant_creator/gizmo.lua` → `modules/**/client.lua`
- `server_scripts`: `@oxmysql/lib/MySQL.lua` → `bridge/**/server.lua` → `core/server.lua` → `modules/**/server.lua`

Bridges load before core/modules so `Inventory.*`, `Admin.*`, etc. are available globally by the time module code executes. Modules read `Config` (defined in `config.lua`) and call helpers from `core/shared.lua` (`debugPrint`, `lerp`, `LoadModel`).

### Modules

Each `modules/<name>/{client,server,shared}.lua` is a self-contained feature. The non-trivial ones:

- `grow` — plot state machine. **Lazy** stage advancement: never ticked; stage is computed on demand from elapsed wall-clock + water count and persisted by callers (`Grow.HarvestStage`, `Grow.NewPlot`, `Grow.WaterCapacityMs`, `Grow.WaterLevel` in `modules/grow/shared.lua`).
- `housing` + `housing_admin` — properties contain zones containing plots. `modules/housing/shared.lua` is pure math (zone-local grid, `CellToWorld` / `WorldToCell`, `FootprintFromSize`, `CanPlaceAt`, `BuildOccupancy`, `BucketFor`). The server is the authority for `CanPlaceAt`; the client uses the same helpers for placement preview. Houses get a routing bucket derived from `Housing.HashId(id)` so each house instance is isolated; MLO houses stay in bucket 0.
- `plant_scene`, `soiling`, `planting`, `watering`, `cutting` — the per-plot interaction surfaces. Entered via ox_target on the plot. The bottom "Plant Console" in `nui/src/App.tsx` drives action selection; per-action sub-modes (`cuttingInput`, `wateringInput`, `plantingInput`, `soilingInput`) are pumped at ~60Hz from the NUI to Lua via `fetchNui`.
- `plant_creator` — admin tool. `gizmo.lua` is a translate/rotate gizmo loaded explicitly before `modules/**/client.lua` because other modules reference it.
- `employees` — persistent NPC workers, admin-managed via `/employees`. Walk/work timing tuned in `Config.Employees`.

### NUI surface

Single React app in `nui/src/App.tsx` that toggles between several panels and HUDs based on `useNuiEvent` messages from Lua:

- `CreatorPanel`, `EmployeesPanel`, `AssignerPanel`, `EmployeeInfoPanel` — admin/management panels.
- `HousingPanel`, `HouseManagePanel` — admin housing surface and player house management.
- `HousePlacementHud`, `ZonePickerHud` — in-world placement / zone picker overlays.
- The bottom "Plant Console" — the per-plot action menu (soil / plant / water / cut / inspect).

NUI ↔ Lua bridge: `fetchNui(name, data)` (NUI → Lua `RegisterNUICallback`) and `useNuiEvent(action, handler)` (Lua `SendNUIMessage({ action, data })` → NUI). Helpers live in `nui/src/lib/nui.ts`.

In-world placement and zone-picking flows are NUI HUDs, not native `BeginTextCommandDisplayHelp` text.

### Bridges

Two bridge namespaces, each loaded by glob pattern so the active framework is auto-detected:

- `bridge/<inventory>/server.lua` — `ox_inventory`, `qb-inventory`, `qs-inventory`, `standalone` populate `Inventory.AddItem` / `RemoveItem` / `GetItemCount`. Each real bridge early-returns if its inventory isn't active; `standalone` is the fallback (last alphabetically) and only initialises if nothing else populated `Inventory.AddItem`.
- `bridge/admin/<framework>/` — `esx`, `qb`, `qbx`, `standalone` populate `Admin.IsAdmin(source)`, used by `/drugs` and `/employees` commands in `core/server.lua`.

When adding a new framework, mirror the early-return pattern so the standalone stubs continue to work as a fallback.

### Entry points / commands

- `/<Config.Command>` (default `growop`) — debug shortcut, opens the cutting view on the first stage-3 plot found.
- `/drugs` — admin housing panel (Properties + Interiors).
- `/employees` — admin NPC roster.
- Real player entry is via ox_target on plots and on employee peds.

### Streamed assets

`stream/weed/pickle_weed.ytyp` is registered as a `DLC_ITYP_REQUEST` data file. The asset itself lives in `stream/`.

## Conventions worth knowing

- `Config.Debug = true` enables `debugPrint(...)` from `core/shared.lua`.
- IDs (zone id, interior id, house id, plot id) are server-authoritative — admin UIs must not let an admin pick or set them.
- Plot/grow state is computed on demand from timestamps + water count; never write a tick that advances stages.
