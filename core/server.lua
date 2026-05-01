-- Debug shortcut. Opens the cutting view on the first stage-3 plot the
-- server can find for the calling player. Real entry is via ox_target on
-- the plot itself; this command is just for testing.
RegisterCommand(Config.Command, function(source)
    if source == 0 then return end
    TriggerClientEvent("pickle_drugs:debugOpenCutting", source)
end, false)

-- Plot creator UI. Admin-only. Opens the NUI plot manager where admins
-- CRUD plot locations (drug type + coordinates) using the placement
-- gizmo. The admin check resolves through the active framework bridge.
RegisterCommand("drugs", function(source)
    if Admin and Admin.IsAdmin and not Admin.IsAdmin(source) then return end
    TriggerClientEvent("pickle_drugs:openCreator", source)
end, false)

-- NPC Employee manager. Admin-only. Opens the roster UI where admins
-- create / move / delete persistent worker peds. Plot assignment runs
-- through ox_target on the ped itself.
RegisterCommand("employees", function(source)
    if Admin and Admin.IsAdmin and not Admin.IsAdmin(source) then return end
    TriggerClientEvent("pickle_drugs:openEmployees", source)
end, false)
