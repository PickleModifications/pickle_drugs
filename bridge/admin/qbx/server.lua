if GetResourceState("qbx_core") ~= "started" then return end
if Admin and Admin.IsAdmin then return end

Admin = Admin or {}

function Admin.IsAdmin(source)
    if not source or source == 0 then return true end
    -- qbx exposes lib.checkPlayerPermission via ox_lib's CheckPlayerPermission;
    -- the simplest and most-portable check is the qb-style HasPermission proxy
    -- under exports.qbx_core, plus the ace fallback.
    local ok, result = pcall(function()
        return exports.qbx_core:HasPermission(source, "admin")
            or exports.qbx_core:HasPermission(source, "god")
    end)
    if ok and result then return true end
    return IsPlayerAceAllowed(source, "command")
end
