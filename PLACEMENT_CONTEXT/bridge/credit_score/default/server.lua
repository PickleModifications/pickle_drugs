-- =============================================
--  pickle_dealerships | bridge/credit_score/default/server.lua
--  No-op credit-score provider + dispatcher.
--
--  A real provider (e.g. tgg-banking) replaces `CreditScoreProvider` during
--  its own resource-ready thread. Consumers call GetPlayerCreditScore — it
--  always returns nil when Config.CreditScore.enabled is false, so callers
--  never need to branch on the feature flag themselves.
-- =============================================

CreditScoreProvider = CreditScoreProvider or {
    name = "none",
    get  = function(_) return nil end,
}

--- Returns the player's credit score (typically 300-850) or nil if the
--- feature is disabled, the provider is missing, or the identifier is not
--- recognised by the provider.
---@param identifier string
---@return number|nil
function GetPlayerCreditScore(identifier)
    if not Config.CreditScore or not Config.CreditScore.enabled then return nil end
    if not identifier or identifier == "" then return nil end
    if type(CreditScoreProvider) ~= "table" or type(CreditScoreProvider.get) ~= "function" then return nil end
    return tonumber(CreditScoreProvider.get(identifier))
end

--- True when the credit-score feature is enabled AND a concrete provider is
--- wired up. Callers use this to distinguish "feature off" (skip the check
--- entirely) from "feature on but provider missing" (fail safe).
function IsCreditScoreProviderActive()
    if not Config.CreditScore or not Config.CreditScore.enabled then return false end
    return type(CreditScoreProvider) == "table" and CreditScoreProvider.name ~= "none"
end
