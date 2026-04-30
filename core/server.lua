-- Debug shortcut. Opens the cutting view on the first stage-3 plot the
-- server can find for the calling player. Real entry is via ox_target on
-- the plot itself; this command is just for testing.
RegisterCommand(Config.Command, function(source)
    if source == 0 then return end
    TriggerClientEvent("pickle_drugs:debugOpenCutting", source)
end, false)
