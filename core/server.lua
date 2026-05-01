-- Debug shortcut. Opens the cutting view on the first stage-3 plot the
-- server can find for the calling player. Real entry is via ox_target on
-- the plot itself; this command is just for testing.
RegisterCommand(Config.Command, function(source)
    if source == 0 then return end
    TriggerClientEvent("pickle_drugs:debugOpenCutting", source)
end, false)

-- Drugs Admin. Admin-only. Opens the bottom-anchored housing panel
-- (Properties + Interiors tabs). Plots are no longer managed standalone —
-- they live inside a Property's zones.
RegisterCommand("drugs", function(source)
    if Admin and Admin.IsAdmin and not Admin.IsAdmin(source) then return end
    TriggerClientEvent("pickle_drugs:openHousing", source, "houses")
end, false)

-- NPC Employee manager. Admin-only. Opens the roster UI where admins
-- create / move / delete persistent worker peds. Plot assignment runs
-- through ox_target on the ped itself.
RegisterCommand("employees", function(source)
    if Admin and Admin.IsAdmin and not Admin.IsAdmin(source) then return end
    TriggerClientEvent("pickle_drugs:openEmployees", source)
end, false)

