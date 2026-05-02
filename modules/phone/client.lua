-- Phone shell. /dealerphone opens the NUI phone frame; the only app
-- shipped today is "Help" — a static getting-started guide. Everything
-- happens client-side; no server file needed.

local PhoneOpen = false

local function OpenPhone()
    if PhoneOpen then return end
    PhoneOpen = true
    SetNuiFocus(true, true)
    SendNUIMessage({ action = "openPhone" })
end

local function ClosePhone()
    if not PhoneOpen then return end
    PhoneOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = "closePhone" })
end

RegisterCommand("dealerphone", function()
    OpenPhone()
end, false)

-- Closing is driven by the NUI (Escape key, on-frame close button, or
-- click-outside). The callback releases focus + acks; we don't push
-- another closePhone message back to the NUI since it already knows.
RegisterNUICallback("phoneClose", function(_, cb)
    PhoneOpen = false
    SetNuiFocus(false, false)
    cb({ ok = true })
end)

AddEventHandler("onResourceStop", function(rn)
    if rn ~= GetCurrentResourceName() then return end
    if PhoneOpen then SetNuiFocus(false, false) end
end)
