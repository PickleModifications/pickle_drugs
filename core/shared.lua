function debugPrint(...)
    if Config and Config.Debug then
        print("[pickle_drugs]", ...)
    end
end

-- ─── Entity framework ─────────────────────────────────────────────────────
-- Shared registry for placed entity kinds (plots, storage lockers, future
-- types). The renderer (core/client.lua) and the broadcasters
-- (core/server.lua) both consume this. A "kind" handler registers spawn /
-- despawn / update / heal callbacks here; the dispatcher in core/client
-- routes incoming entityUpdate events through the right handler.
-- `PickleEntity` (not `Entity`) — `Entity` is a CitizenFX built-in
-- (entity wrapper function) so any global named `Entity` collides with
-- the runtime and produces "attempt to index a function value" on the
-- first .field access.
PickleEntity = PickleEntity or { kinds = {} }

function PickleEntity.RegisterKind(kind, handlers)
    if type(kind) ~= "string" or type(handlers) ~= "table" then return end
    PickleEntity.kinds[kind] = handlers
end

function PickleEntity.GetKind(kind) return PickleEntity.kinds[kind] end

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
