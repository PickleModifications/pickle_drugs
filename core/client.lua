-- Debug shortcut: server hits this; we open the cutting scene on the first
-- stage-3 plot we know about (or print why we can't).
RegisterNetEvent("pickle_drugs:debugOpenCutting", function()
    for _, id in ipairs(GetAllPlotIds() or {}) do
        local plot = GetPlotState(id)
        local drugCfg = plot and Config.Drugs[plot.drug]
        if plot and drugCfg and plot.stage == Grow.HarvestStage(drugCfg) then
            OpenCuttingScene(id)
            return
        end
    end
    print("[pickle_drugs] /growop: no harvestable plot available")
end)
