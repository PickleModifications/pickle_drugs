-- Last-resort fallback. Loaded last (alphabetically); the other framework
-- bridges early-return when their framework isn't active, so this only
-- populates when none of them have.
Admin = Admin or {}
Framework = Framework or {}

if not Admin.IsAdmin then
    function Admin.IsAdmin(source)
        if not source or source == 0 then return true end
        return IsPlayerAceAllowed(source, "command")
    end
end

if not Framework.RegisterUsableItem then
    Framework.RegisterUsableItem = function() end
end

if not Framework.GetCitizenId then
    -- Standalone has no concept of identities; use the source directly
    -- so per-player keys at least don't collide between players in one
    -- session. Persistence across reconnects isn't meaningful here.
    function Framework.GetCitizenId(source)
        if not source then return nil end
        return ("standalone:%d"):format(tonumber(source) or 0)
    end
end

if not Framework.AddMoney then
    function Framework.AddMoney(source, amount, account)
        print(("[pickle_drugs standalone] would credit src=%s %s$%s")
            :format(tostring(source), account or "cash", tostring(amount)))
        return false
    end
end
