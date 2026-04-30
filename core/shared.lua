function debugPrint(...)
    if Config and Config.Debug then
        print("[pickle_drugs]", ...)
    end
end

function lerp(a, b, t) return a + (b-a) * t end

--- Loads a model and waits up to `timeoutMs` for it to stream in.
---@param model string|number
---@param timeoutMs number|nil
---@return number|nil hash
function LoadModel(model, timeoutMs)
    local hash = type(model) == "string" and joaat(model) or model
    if not IsModelInCdimage(hash) then
        debugPrint("model not in cdimage:", model)
        return nil
    end
    RequestModel(hash)
    local deadline = GetGameTimer() + (timeoutMs or 10000)
    while not HasModelLoaded(hash) and GetGameTimer() < deadline do
        Wait(0)
    end
    if not HasModelLoaded(hash) then
        debugPrint("model failed to load:", model)
        return nil
    end
    return hash
end
