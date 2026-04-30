-- =============================================
--  pickle_dealerships | modules/conversion/server.lua
--  Admin-gated callbacks that expose the conversion bridge registry to the
--  Import tab on the admin panel.
-- =============================================

lib.callback.register("pickle_dealerships:conversionListResources", function(source)
    if not IsPlayerAdmin(source) then DenyAccess(source, "admin_no_permission") return nil end
    return ListConversionResources()
end)

lib.callback.register("pickle_dealerships:conversionListEntity", function(source, data)
    if not IsPlayerAdmin(source) then
        return { success = false, message = _L("admin_no_permission") }
    end
    local resource = data and data.resource
    local version = data and data.version
    local entity = data and data.entity
    if not resource or not version or not entity then
        return { success = false, message = _L("import_unknown_adapter") }
    end
    local rows = ListConversionEntity(resource, version, entity)
    if rows == nil then
        return { success = false, message = _L("import_unknown_adapter") }
    end
    return { success = true, rows = rows }
end)

lib.callback.register("pickle_dealerships:conversionRun", function(source, data)
    if not IsPlayerAdmin(source) then
        return { success = false, message = _L("admin_no_permission") }
    end
    local resource = data and data.resource
    local version = data and data.version
    if not resource or not version then
        return { success = false, message = _L("import_unknown_adapter") }
    end
    local selections = data.selections or {}
    local options = data.options or {}

    local startedAt = os.time()
    local res = RunConversionImport(resource, version, selections, options)
    if not res.success then
        return res
    end

    -- Refresh cached dealerships so newly imported rows go live without a restart.
    if LoadDealerships then pcall(LoadDealerships) end

    local elapsed = os.time() - startedAt
    local adminName = GetPlayerCharacterName and (GetPlayerCharacterName(source) or GetPlayerName(source)) or GetPlayerName(source)
    print(("[pickle_dealerships][conversion] %s/%s imported in %ds by %s"):format(resource, version, elapsed, adminName or source))

    -- Build a per-entity breakdown for the log so a reviewer can see at a
    -- glance how many rows each adapter pulled in.
    local breakdown = {}
    if type(res.results) == "table" then
        for entity, result in pairs(res.results) do
            breakdown[#breakdown + 1] = {
                name = entity,
                value = ("inserted %d / skipped %d"):format(tonumber(result.inserted) or 0, tonumber(result.skipped) or 0),
                inline = true,
            }
        end
    end

    LogDiscord("stock", {
        title = "Conversion Import",
        actor = source,
        fields = (function()
            local fields = {
                { name = "Resource", value = tostring(resource), inline = true },
                { name = "Version", value = tostring(version), inline = true },
                { name = "Elapsed", value = tostring(elapsed) .. "s", inline = true },
            }
            for _, f in ipairs(breakdown) do fields[#fields + 1] = f end
            return fields
        end)(),
    })

    res.elapsed = elapsed
    return res
end)
