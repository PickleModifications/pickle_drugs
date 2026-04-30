-- Debug shortcut: server hits this; we open the cutting scene on the first
-- stage-3 plot we know about (or print why we can't).
RegisterNetEvent("pickle_drugs:debugOpenCutting", function()
    for _, id in ipairs(GetAllPlotIds() or {}) do
        local plot = GetPlotState(id)
        if plot and plot.stage == 3 then
            OpenCuttingScene(id)
            return
        end
    end
    print("[pickle_drugs] /growop: no stage-3 plot available")
end)
