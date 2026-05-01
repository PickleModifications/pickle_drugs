-- =============================================
--  pickle_dealerships | bridge/alt_currencies/registry/server.lua
--  Alternative payment currencies (pickle_store coins, item currencies, etc.)
--
--  Each entry exposes a uniform interface so the sales flow can stay agnostic:
--      def = { label, type, valuePerUnit, get(source), remove(source, n), add(source, n) }
-- =============================================

AltCurrencies = AltCurrencies or {}

--- Registers an alt currency. No-ops if inputs are malformed. Safe to call from
--- any bridge file; the last registration wins.
function RegisterAltCurrency(key, def)
    if type(key) ~= "string" or key == "" or type(def) ~= "table" then return end
    if type(def.get) ~= "function" or type(def.remove) ~= "function" then return end
    def.key = key
    def.label = def.label or key
    def.type = def.type or "custom"
    def.valuePerUnit = tonumber(def.valuePerUnit) or 1
    if def.valuePerUnit <= 0 then def.valuePerUnit = 1 end
    -- UI presentation fields (all optional). Defaults match the legacy
    -- behaviour where only `label` was available.
    def.iconUrl  = type(def.iconUrl)  == "string" and def.iconUrl  or ""
    def.singular = type(def.singular) == "string" and def.singular or nil
    def.plural   = type(def.plural)   == "string" and def.plural   or nil
    AltCurrencies[key] = def
end

function GetAltCurrency(key)
    if not key then return nil end
    return AltCurrencies[key]
end

--- Converts a dollar price into the native amount of this currency, rounded up.
function AltCurrencyNativeAmount(def, dollarPrice)
    if not def then return 0 end
    local per = def.valuePerUnit or 1
    return math.ceil((tonumber(dollarPrice) or 0) / per)
end

--- Returns all registered currencies with the fields needed to render them in
--- the NUI: key/label/type/valuePerUnit plus optional iconUrl / singular /
--- plural used by the client-side formatter.
function ListAltCurrencies()
    local out = {}
    for key, def in pairs(AltCurrencies) do
        out[#out + 1] = {
            key = key,
            label = def.label,
            type = def.type,
            valuePerUnit = def.valuePerUnit,
            iconUrl = def.iconUrl or "",
            singular = def.singular,
            plural = def.plural,
        }
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

-- ─── Built-in: pickle_store coins ─────────────────────────────────────────
CreateThread(function()
    local cfg = Config.AltCurrencies and Config.AltCurrencies.pickle_store
    if not cfg or not cfg.enabled then return end

    -- Wait up to ~15s for pickle_store to come online, in case its start order
    -- is after this resource. Previously we only waited 500ms and bailed,
    -- which silently dropped the currency on most dev setups.
    local deadline = GetGameTimer() + 15000
    while GetResourceState("pickle_store") ~= "started" and GetGameTimer() < deadline do
        Wait(500)
    end
    if GetResourceState("pickle_store") ~= "started" then
        print("[pickle_dealerships] AltCurrency 'pickle_store' enabled in config but pickle_store resource didn't start within 15s — skipping registration.")
        return
    end

    RegisterAltCurrency("pickle_store", {
        label        = cfg.label or "Store Coins",
        type         = "pickle_store",
        valuePerUnit = tonumber(cfg.valuePerUnit) or 1,
        iconUrl      = cfg.iconUrl,
        singular     = cfg.singular,
        plural       = cfg.plural,
        get = function(source)
            local ok, coins = pcall(function() return exports["pickle_store"]:GetCoins(source) end)
            return ok and tonumber(coins) or 0
        end,
        remove = function(source, amount)
            local ok = pcall(function() exports["pickle_store"]:RemoveCoins(source, amount, "pickle_dealerships") end)
            return ok
        end,
        add = function(source, amount)
            pcall(function() exports["pickle_store"]:AddCoins(source, amount, "pickle_dealerships refund") end)
        end,
    })
    debugPrint("[pickle_dealerships] Registered alt currency: pickle_store")
end)

-- ─── Built-in: item currencies ────────────────────────────────────────────
CreateThread(function()
    -- Same rationale as pickle_store above — wait for the inventory bridge to
    -- be ready before probing. Item currencies silently failed on first boot
    -- if ox_inventory/qb-inventory hadn't exposed their globals yet.
    local deadline = GetGameTimer() + 15000
    while not Inventory and GetGameTimer() < deadline do Wait(500) end
    if not Config.AltCurrencies then return end

    for key, cfg in pairs(Config.AltCurrencies) do
        if cfg.type == "item" and cfg.enabled and type(cfg.item) == "string" and cfg.item ~= "" then
            local itemName = cfg.item
            RegisterAltCurrency(key, {
                label        = cfg.label or key,
                type         = "item",
                item         = itemName,
                valuePerUnit = tonumber(cfg.valuePerUnit) or 1,
                iconUrl      = cfg.iconUrl,
                singular     = cfg.singular,
                plural       = cfg.plural,
                get = function(source)
                    if Inventory and Inventory.GetItemCount then
                        return tonumber(Inventory.GetItemCount(source, itemName)) or 0
                    end
                    return 0
                end,
                remove = function(source, amount)
                    if Inventory and Inventory.RemoveItem then
                        Inventory.RemoveItem(source, itemName, amount)
                        return true
                    end
                    return false
                end,
                add = function(source, amount)
                    if Inventory and Inventory.AddItem then
                        Inventory.AddItem(source, itemName, amount)
                    end
                end,
            })
            debugPrint(("[pickle_dealerships] Registered alt currency: %s (item=%s)"):format(key, itemName))
        end
    end
end)
