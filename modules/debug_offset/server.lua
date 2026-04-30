-- Persists bud offsets back into config.lua. Locates the right drug's
-- `buds = { ... offsets = { ... } ... }` block by scanning for the
-- `Config.Drugs.<drug>` table header, then replaces just the offsets body.

local function formatOffsets(offsets)
    if #offsets == 0 then
        return "offsets = {\n\n            },"
    end
    local lines = { "offsets = {" }
    for _, o in ipairs(offsets) do
        lines[#lines + 1] = ("                { x = %.4f, y = %.4f, z = %.4f },")
            :format(o.x or 0.0, o.y or 0.0, o.z or 0.0)
    end
    lines[#lines + 1] = "            },"
    return table.concat(lines, "\n")
end

--- Returns `i, j` for the balanced `{...}` starting at `openIdx` (which must
--- point at the `{`). Lua patterns can't do this on their own.
local function matchBalancedBraces(src, openIdx)
    local depth = 0
    local i = openIdx
    while i <= #src do
        local c = src:sub(i, i)
        if c == "{" then depth = depth + 1
        elseif c == "}" then
            depth = depth - 1
            if depth == 0 then return openIdx, i end
        end
        i = i + 1
    end
    return nil
end

--- Replaces the `offsets = { ... }` block inside the `buds = { ... }` block
--- of `Config.Drugs.<drug>`. Returns (newSource, err).
local function rewriteOffsets(src, drug, offsets)
    local header = "Config.Drugs%." .. drug
    local headStart = src:find(header)
    if not headStart then return nil, "drug header not found" end

    -- Find `buds = {` after the header.
    local budsKey = src:find("buds%s*=%s*{", headStart, false)
    if not budsKey then return nil, "buds block not found" end
    local budsOpen = src:find("{", budsKey, true)
    local _, budsClose = matchBalancedBraces(src, budsOpen)
    if not budsClose then return nil, "buds block braces unbalanced" end

    -- Find `offsets = {` inside that range.
    local offsetsKey = src:find("offsets%s*=%s*{", budsOpen, false)
    if not offsetsKey or offsetsKey > budsClose then
        return nil, "offsets block not found"
    end
    local offOpen = src:find("{", offsetsKey, true)
    local _, offClose = matchBalancedBraces(src, offOpen)
    if not offClose then return nil, "offsets block braces unbalanced" end

    -- Replace `offsets = {...},` (include trailing comma if present).
    local replaceFrom = offsetsKey
    local replaceTo = offClose
    if src:sub(offClose + 1, offClose + 1) == "," then
        replaceTo = offClose + 1
    end
    return src:sub(1, replaceFrom - 1)
        .. formatOffsets(offsets)
        .. src:sub(replaceTo + 1)
end

RegisterNetEvent("pickle_drugs:saveBudOffsets", function(drug, offsets)
    if not Config or not Config.Debug then return end
    if type(drug) ~= "string" or type(offsets) ~= "table" then return end
    if not Config.Drugs[drug] then return end

    local resource = GetCurrentResourceName()
    local src = LoadResourceFile(resource, "config.lua")
    if not src then
        print("[pickle_drugs] saveBudOffsets: failed to read config.lua")
        return
    end

    local out, err = rewriteOffsets(src, drug, offsets)
    if not out then
        print(("[pickle_drugs] saveBudOffsets: %s"):format(err))
        TriggerClientEvent("chat:addMessage", source, {
            args = { "[pickle_drugs]", "save failed: " .. err },
        })
        return
    end

    local ok = SaveResourceFile(resource, "config.lua", out, -1)
    local msg = ok
        and ("saved %d offsets for %s — restart resource to apply"):format(#offsets, drug)
        or "save failed: SaveResourceFile returned false"
    print("[pickle_drugs] " .. msg)
    TriggerClientEvent("chat:addMessage", source, {
        args = { "[pickle_drugs]", msg },
    })
end)
