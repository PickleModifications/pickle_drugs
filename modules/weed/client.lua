-- Weed-specific client glue. Currently a thin sanity check — the generic
-- grow/cutting/watering modules already pull every parameter from
-- Config.Drugs.weed. Drug-specific overrides (custom particles, alternate
-- harvest anims, etc.) would live here.

CreateThread(function()
    Wait(0)
    local cfg = Config.Drugs and Config.Drugs.weed
    if not cfg then
        print("[pickle_drugs] weed: Config.Drugs.weed missing — was config/weed.lua loaded?")
        return
    end
    local harvest = Grow.HarvestStage(cfg)
    if not cfg.stages or not cfg.stages[harvest] or not cfg.stages[harvest].buds then
        print(("[pickle_drugs] weed: stage %d buds missing in config"):format(harvest))
    end
end)
