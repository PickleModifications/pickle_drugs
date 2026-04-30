-- =============================================
--  pickle_dealerships | bridge/credit_score/tgg_banking/server.lua
--  Credit-score provider backed by tgg-banking.
--
--  API:
--     exports['tgg-banking']:GetCreditScore(identifier) -> number|nil (300-850)
--
--  Registers itself only when enabled in Config.CreditScore AND selected as
--  the active provider. Waits for tgg-banking to start before binding, same
--  pattern as bridge/alt_currencies. If tgg-banking never starts, the
--  default no-op stays in place and GetPlayerCreditScore returns nil.
-- =============================================

if not Config.CreditScore or not Config.CreditScore.enabled then return end
if Config.CreditScore.provider ~= "tgg-banking" then return end

CreateThread(function()
    local deadline = GetGameTimer() + 15000
    while GetResourceState("tgg-banking") ~= "started" and GetGameTimer() < deadline do
        Wait(500)
    end
    if GetResourceState("tgg-banking") ~= "started" then
        print("[pickle_dealerships] CreditScore provider 'tgg-banking' is configured but the tgg-banking resource didn't start within 15s — credit checks will fail closed (score = nil).")
        return
    end

    CreditScoreProvider = {
        name = "tgg-banking",
        get  = function(identifier)
            -- pcall the export so a breaking change in tgg-banking can't
            -- take the financing flow down with it; nil falls through to a
            -- "credit unavailable" deny in the consumer.
            local ok, score = pcall(function()
                return exports["tgg-banking"]:GetCreditScore(identifier)
            end)
            if not ok then return nil end
            return tonumber(score)
        end,
    }
end)
