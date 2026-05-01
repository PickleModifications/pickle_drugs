-- Plot creator client. Opens the NUI plot manager (via /drugs server
-- command), serves drug + plot lists, and runs the placement gizmo for
-- create / move flows. Confirmed placements fire admin-gated server
-- events; the resulting plotUpdate / plotRemoved broadcasts are handled
-- by modules/grow/client so the world entities re-render automatically.

local CreatorOpen = false
local Drugs = {}        -- cached { { id, label }, ... } from server callback

-- ─── Helpers ──────────────────────────────────────────────────────────────

local function listPlotsForUI()
    local out = {}
    for _, id in ipairs(GetAllPlotIds() or {}) do
        local plot = GetPlotState(id)
        local spot = GetPlotSpot(id)
        if plot and spot and spot.coords then
            out[#out + 1] = {
                id    = id,
                drug  = plot.drug,
                stage = plot.stage,
                x     = spot.coords.x,
                y     = spot.coords.y,
                z     = spot.coords.z,
                w     = spot.coords.w or 0.0,
            }
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

local function pushPlotList()
    SendNUIMessage({
        action = "creatorPlots",
        data   = { plots = listPlotsForUI() },
    })
end

-- ─── NUI open / close ──────────────────────────────────────────────────────

local function openCreator()
    if CreatorOpen then return end
    if not Drugs or #Drugs == 0 then
        Drugs = lib.callback.await("pickle_drugs:listDrugs", false) or {}
    end
    CreatorOpen = true
    SetNuiFocus(true, true)
    SendNUIMessage({
        action = "openCreator",
        data   = { drugs = Drugs, plots = listPlotsForUI() },
    })
end

local function closeCreator()
    if not CreatorOpen then return end
    CreatorOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = "closeCreator" })
end

-- Hides/shows the creator NUI without changing CreatorOpen state — used
-- while the gizmo is active so the placement camera/HUD has the screen
-- to itself, then we restore on confirm/cancel.
local function minimizeForGizmo()
    SetNuiFocus(false, false)
    SendNUIMessage({ action = "creatorMinimize" })
end

local function restoreFromGizmo()
    if not CreatorOpen then return end
    SetNuiFocus(true, true)
    SendNUIMessage({
        action = "creatorRestore",
        data   = { plots = listPlotsForUI() },
    })
end

RegisterNetEvent("pickle_drugs:openCreator", function()
    openCreator()
end)

-- Tab-switcher integration: when the housing admin tab swaps away from
-- "plots", it sends a closeCreator NUI message but our local CreatorOpen
-- flag is still set — guard the next open against the early-return.
AddEventHandler("pickle_drugs:resetCreatorState", function()
    CreatorOpen = false
end)

-- Plot list refresh after a server-side mutation. plotUpdate is broadcast
-- on every gameplay state change too, so we debounce by simply re-sending
-- the (cheap) list snapshot whenever the creator is open.
RegisterNetEvent("pickle_drugs:plotUpdate", function()
    if CreatorOpen then pushPlotList() end
end)
RegisterNetEvent("pickle_drugs:plotRemoved", function()
    if CreatorOpen then pushPlotList() end
end)

-- ─── Gizmo flows ───────────────────────────────────────────────────────────

local function placeNewPlot(drug)
    if not drug then return end
    minimizeForGizmo()
    local result = StartGizmoEditor({
        model        = "pickle_pot_01",
        enableCancel = true,
        deleteEntity = true,
    })
    restoreFromGizmo()
    if not result or not result.position then return end
    TriggerServerEvent("pickle_drugs:createPlot",
        drug,
        result.position.x, result.position.y, result.position.z,
        (result.rotation and result.rotation.z) or 0.0)
end

local function moveExistingPlot(plotId)
    if not plotId then return end
    local plot = GetPlotState(plotId)
    local spot = GetPlotSpot(plotId)
    if not plot or not spot then return end
    minimizeForGizmo()
    -- Hide the world prop set during the move so the gizmo's preview pot
    -- doesn't double up with the live one. Re-shown on cancel/confirm
    -- (plotUpdate respawns at the new coords on confirm anyway).
    if SetPlotVisible then SetPlotVisible(plotId, false) end
    local result = StartGizmoEditor({
        model        = "pickle_pot_01",
        coords       = vector3(spot.coords.x, spot.coords.y, spot.coords.z),
        rotation     = vector3(0.0, 0.0, spot.coords.w or 0.0),
        enableCancel = true,
        deleteEntity = true,
    })
    if SetPlotVisible then SetPlotVisible(plotId, true) end
    restoreFromGizmo()
    if not result or not result.position then return end
    TriggerServerEvent("pickle_drugs:updatePlotCoords",
        plotId,
        result.position.x, result.position.y, result.position.z,
        (result.rotation and result.rotation.z) or 0.0)
end

-- ─── NUI callbacks ─────────────────────────────────────────────────────────

RegisterNUICallback("creatorClose", function(_, cb)
    closeCreator()
    cb({ ok = true })
end)

RegisterNUICallback("creatorPlace", function(data, cb)
    cb({ ok = true })
    -- Run async so the NUI fetch resolves before the gizmo loop kicks in.
    CreateThread(function() placeNewPlot(data and data.drug) end)
end)

RegisterNUICallback("creatorMove", function(data, cb)
    cb({ ok = true })
    CreateThread(function() moveExistingPlot(data and data.plotId) end)
end)

RegisterNUICallback("creatorDelete", function(data, cb)
    if data and data.plotId then
        TriggerServerEvent("pickle_drugs:deletePlot", data.plotId)
    end
    cb({ ok = true })
end)

AddEventHandler("onResourceStop", function(rn)
    if rn ~= GetCurrentResourceName() then return end
    if CreatorOpen then SetNuiFocus(false, false) end
end)
