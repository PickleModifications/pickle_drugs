Templates = {}

function lerp(a, b, t) return a + (b-a) * t end

function v3(coords) return vec3(coords.x, coords.y, coords.z), coords.w end

function GetRandomInt(min, max, exclude)
    for i=1, 1000 do
        local int = math.random(min, max)
        if exclude == nil or exclude ~= int then
            return int
        end
    end
end

function debugPrint(...)
    if Config.Debug then
        print(...)
    end
end

function NumberWithCommas(x, noCurrency)
    local left, num, right = string.match(x, '^([^%d]*%d)(%d*)(.-)$')
    return (not noCurrency and "$" or "") .. left..(num:reverse():gsub('(%d%d%d)','%1,'):reverse())
end

function tolower(str)
    return string.lower(str)
end

function toupper(str)
    return string.upper(str)
end

function GetItemLabel(name)
    if Inventory and Inventory.Items and Inventory.Items[name] then
        return Inventory.Items[name].label
    elseif Inventory and Inventory.Items and Inventory.Items[toupper(name)] then
        return Inventory.Items[toupper(name)].label
    end
    return name
end

function GetCurrencyString(amount)
    return NumberWithCommas(amount)
end

-- Renders Config.PlateFormat into a concrete plate string. See config.lua
-- for the pattern syntax (A = letter, 1 = digit, ? = either, else literal).
-- Falls back to "AAAA1111" if the config is empty/malformed so a typo in
-- the format string can't produce blank plates at sale time.
local PLATE_LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
function GeneratePlate()
    local pattern = Config and Config.PlateFormat
    if type(pattern) ~= "string" or pattern == "" then
        pattern = "AAAA1111"
    end
    local plate = {}
    for i = 1, #pattern do
        local c = pattern:sub(i, i)
        if c == "A" then
            local idx = math.random(1, #PLATE_LETTERS)
            plate[#plate + 1] = PLATE_LETTERS:sub(idx, idx)
        elseif c == "1" then
            plate[#plate + 1] = tostring(math.random(0, 9))
        elseif c == "?" then
            -- Letter or digit, 50/50. Useful when a garage wants a fixed
            -- length but doesn't care about the letter/digit split.
            if math.random(1, 2) == 1 then
                local idx = math.random(1, #PLATE_LETTERS)
                plate[#plate + 1] = PLATE_LETTERS:sub(idx, idx)
            else
                plate[#plate + 1] = tostring(math.random(0, 9))
            end
        else
            plate[#plate + 1] = c
        end
    end
    return table.concat(plate)
end

-- Note: HasTierFeature / CanAccessCatalogTier / GetCatalogForDealership were
-- removed when catalog access switched from a 4-level tier hierarchy to flat
-- many-to-many groups. Catalog visibility is now driven by SQL joins on the
-- pickle_catalog_vehicle_groups + pickle_dealership_groups junction tables;
-- see modules/stock/server.lua. Financing — the only feature that was tier-
-- gated — is now available to every dealership.

function WeightedRandom(weights)
    local total = 0
    for _, w in pairs(weights) do total = total + w end
    local roll = math.random() * total
    local cumulative = 0
    for key, w in pairs(weights) do
        cumulative = cumulative + w
        if roll <= cumulative then return key end
    end
    local last
    for key in pairs(weights) do last = key end
    return last
end
