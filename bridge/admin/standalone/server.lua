-- Last-resort fallback. Loaded last (alphabetically); the other admin
-- bridges early-return when their framework isn't active, so this only
-- populates when none of them have.
if Admin and Admin.IsAdmin then return end

Admin = Admin or {}

function Admin.IsAdmin(source)
    if not source or source == 0 then return true end
    return IsPlayerAceAllowed(source, "command")
end
