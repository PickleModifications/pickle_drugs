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
    if not cfg.stages or not cfg.stages[3] or not cfg.stages[3].buds then
        print("[pickle_drugs] weed: stage 3 buds missing in config")
    end
end)
