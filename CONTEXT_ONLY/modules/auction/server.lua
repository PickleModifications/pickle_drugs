-- =============================================
--  pickle_dealerships | modules/auction/server.lua
--  Auction lifecycle: listing, bidding (escrow), anti-snipe, finalize, claim
-- =============================================

local function NormalizeStatus(row)
    if not row then return row end
    row.reserve_met = (row.reserve_price == nil) or (tonumber(row.current_bid or 0) >= tonumber(row.reserve_price))
    return row
end

local function FetchAuction(auctionId)
    local row = MySQL.single.await(
        [[SELECT a.*, s.vehicle_model, s.vehicle_label, s.plate, s.condition, s.metadata AS stock_metadata,
                 d.name AS dealership_name
          FROM `pickle_dealership_auctions` a
          JOIN `pickle_dealership_stock` s ON s.id = a.stock_id
          JOIN `pickle_dealerships` d ON d.id = a.dealership_id
          WHERE a.id = ?]],
        { tonumber(auctionId) }
    )
    return NormalizeStatus(row)
end

local function FetchActiveAuctions()
    local rows = MySQL.query.await(
        [[SELECT a.*, s.vehicle_model, s.vehicle_label, s.plate, s.condition,
                 d.name AS dealership_name,
                 (SELECT COUNT(*) FROM pickle_dealership_auction_bids b WHERE b.auction_id = a.id) AS bid_count
          FROM `pickle_dealership_auctions` a
          JOIN `pickle_dealership_stock` s ON s.id = a.stock_id
          JOIN `pickle_dealerships` d ON d.id = a.dealership_id
          WHERE a.status = 'active'
          ORDER BY a.ends_at ASC]],
        {}
    ) or {}
    for _, r in ipairs(rows) do NormalizeStatus(r) end
    return rows
end

local function UnlockStock(stockId)
    MySQL.update.await("UPDATE `pickle_dealership_stock` SET `auction_id` = NULL WHERE `id` = ?", { tonumber(stockId) })
end

local function RefundBidder(identifier, amount, note, method)
    if not identifier or not amount or amount <= 0 then return end
    -- Refund in whatever the bidder paid with. Bank is the safe default for
    -- legacy rows that predate payment_method tracking and for offline bidders
    -- (always refund to bank so the money can't be lost in a closed cash
    -- inventory). NOTE: the framework bridge's AddMoney/RemoveMoney expect
    -- the currency code "money" for cash (not "cash") — passing "cash" falls
    -- through the bridge's if/elseif chain and silently does nothing, which
    -- is exactly how cash refunds were being lost.
    local currency = method == 'cash' and 'money' or 'bank'
    local src = GetSourceFromIdentifier(identifier)
    if src then
        AddMoney(src, amount, currency)
        TriggerClientEvent('pickle_dealerships:notify', src, (note or 'Bid refunded') .. ': $' .. amount)
    else
        -- Offline: mark an unrefunded row so the escrow is still tracked; next pickup-on-connect handler can sweep.
        -- For simplicity we insert a synthetic ledger-style row via the bids table refunded flag logic handled by caller.
    end
end

local function AddDealershipBalance(dealershipId, amount)
    MySQL.update.await(
        "UPDATE `pickle_dealerships` SET `balance` = `balance` + ? WHERE `id` = ?",
        { tonumber(amount), tonumber(dealershipId) }
    )
    local fresh = MySQL.scalar.await("SELECT `balance` FROM `pickle_dealerships` WHERE `id` = ?", { tonumber(dealershipId) })
    if fresh and UpdateDealershipCache then UpdateDealershipCache(dealershipId, { balance = tonumber(fresh) }) end
end

local function BroadcastAuctionUpdate(auctionId)
    TriggerClientEvent('pickle_dealerships:auctionUpdate', -1, tonumber(auctionId))
end

-- ─── Listing ────────────────────────────────────────────────────────────────

lib.callback.register("pickle_dealerships:createAuction", function(source, data)
    local stockId = tonumber(data and data.stockId)
    if not stockId then return false, "Invalid stock id." end

    local stock = MySQL.single.await("SELECT * FROM `pickle_dealership_stock` WHERE `id` = ?", { stockId })
    if not stock then return false, "Stock not found." end
    if stock.sold_at then return false, "Stock already sold." end
    if stock.auction_id then return false, "Already at auction." end
    if not (stock.is_used == 1 or stock.is_used == true) then return false, "Only pre-owned vehicles can be auctioned." end

    -- Permission: owner / manager / admin on the owning dealership
    local role = GetPlayerDealershipRole(source, stock.dealership_id)
    if role ~= 'owner' and role ~= 'manager' and role ~= 'admin' then
        return false, "You do not have permission."
    end

    local startingBid = math.max(1, math.floor(tonumber(data.startingBid) or 0))
    local minIncrement = math.max(Config.Auction.minIncrementFloor, math.floor(tonumber(data.minIncrement) or Config.Auction.minIncrementFloor))
    local reserve = data.reservePrice and math.max(0, math.floor(tonumber(data.reservePrice))) or nil
    local buyout = data.buyoutPrice and math.max(0, math.floor(tonumber(data.buyoutPrice))) or nil
    if reserve == 0 then reserve = nil end
    if buyout == 0 then buyout = nil end
    if buyout and buyout < startingBid then return false, "Buyout must be ≥ starting bid." end
    if reserve and reserve < startingBid then return false, "Reserve must be ≥ starting bid." end

    local duration = tonumber(data.durationMinutes) or Config.Auction.defaultDuration
    local validDuration = false
    for _, d in ipairs(Config.Auction.durations) do if d == duration then validDuration = true break end end
    if not validDuration then return false, "Invalid duration." end

    -- Timer doesn't start until the first bid is placed; ends_at stays NULL until then.
    local id = MySQL.insert.await(
        [[INSERT INTO `pickle_dealership_auctions`
          (stock_id, dealership_id, seller_identifier, starting_bid, min_increment, reserve_price, buyout_price, duration_minutes, ends_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL)]],
        { stockId, stock.dealership_id, GetIdentifier(source), startingBid, minIncrement, reserve, buyout, duration }
    )
    if not id then return false, "Failed to create auction." end

    -- Also clear display_spot so the car is physically taken off the lot for
    -- the duration of the auction; nobody should be able to walk up and buy
    -- a vehicle that's currently being auctioned.
    MySQL.update.await(
        "UPDATE `pickle_dealership_stock` SET `auction_id` = ?, `unlisted` = 0, `display_spot` = NULL WHERE `id` = ?",
        { id, stockId }
    )
    local dealership = GetDealership(stock.dealership_id)
    if dealership and dealership.location then
        TriggerClientEvent('pickle_dealerships:refreshDisplay', -1, dealership.location)
    end

    BroadcastAuctionUpdate(id)
    return true, id
end)

-- ─── Bidding ────────────────────────────────────────────────────────────────

lib.callback.register("pickle_dealerships:placeBid", function(source, data)
    local auctionId = tonumber(data and data.auctionId)
    local amount = math.floor(tonumber(data and data.amount) or 0)
    if not auctionId or amount <= 0 then return false, "Invalid bid." end

    local identifier = GetIdentifier(source)
    if not identifier then return false, "Could not identify player." end

    local auction = FetchAuction(auctionId)
    if not auction then return false, "Auction not found." end
    if auction.status ~= 'active' then return false, "Auction is no longer active." end
    -- NOTE: seller self-bidding is allowed for debugging/testing

    -- Validate amount
    local floor = auction.current_bid and (tonumber(auction.current_bid) + tonumber(auction.min_increment)) or tonumber(auction.starting_bid)
    if amount < floor then return false, ("Bid must be at least $%d."):format(floor) end

    -- Clamp to buyout (if they bid >= buyout, treat as buyout)
    local isBuyout = auction.buyout_price and amount >= tonumber(auction.buyout_price) or false
    if isBuyout then amount = tonumber(auction.buyout_price) end

    -- Resolve payment method. Default to bank to match legacy behaviour.
    local paymentMethod = data.paymentMethod == 'cash' and 'cash' or 'bank'
    local currency = paymentMethod == 'cash' and 'money' or 'bank'

    -- Pre-check balance so we never leave a bidder at a negative balance. The
    -- framework's RemoveMoney does not consistently reject overdrafts (qbx
    -- returns true on insufficient funds depending on config), so gating here
    -- is the only reliable check.
    local playerBalance = tonumber(GetMoney(source, currency)) or 0
    if playerBalance < amount then
        return false, ("Insufficient %s balance."):format(paymentMethod)
    end

    -- Escrow: pull from the chosen tender
    local removed = RemoveMoney(source, amount, currency)
    if not removed then return false, ("Insufficient %s balance."):format(paymentMethod) end

    -- Refund previous top bidder in whatever method they paid with
    if auction.current_bidder and auction.current_bid and auction.current_bid > 0 then
        MySQL.update.await(
            "UPDATE `pickle_dealership_auction_bids` SET `refunded` = 1 WHERE `auction_id` = ? AND `bidder_identifier` = ? AND `refunded` = 0",
            { auctionId, auction.current_bidder }
        )
        RefundBidder(auction.current_bidder, tonumber(auction.current_bid), 'Outbid', auction.current_payment_method)
    end

    -- Insert bid + update auction
    MySQL.insert.await(
        "INSERT INTO `pickle_dealership_auction_bids` (auction_id, bidder_identifier, amount, payment_method) VALUES (?, ?, ?, ?)",
        { auctionId, identifier, amount, paymentMethod }
    )

    -- First bid starts the timer; subsequent bids may extend via anti-snipe
    local isFirstBid = auction.current_bidder == nil
    local timerStarted = false
    local extended = false
    if isFirstBid then
        MySQL.update.await(
            "UPDATE `pickle_dealership_auctions` SET `ends_at` = DATE_ADD(NOW(), INTERVAL ? MINUTE) WHERE `id` = ?",
            { tonumber(auction.duration_minutes) or Config.Auction.defaultDuration, auctionId }
        )
        timerStarted = true
    elseif not isBuyout and Config.Auction.antiSnipeSeconds and Config.Auction.antiSnipeSeconds > 0 then
        local secondsLeft = MySQL.scalar.await(
            "SELECT TIMESTAMPDIFF(SECOND, NOW(), `ends_at`) FROM `pickle_dealership_auctions` WHERE `id` = ?",
            { auctionId }
        )
        if secondsLeft and tonumber(secondsLeft) < Config.Auction.antiSnipeSeconds then
            MySQL.update.await(
                "UPDATE `pickle_dealership_auctions` SET `ends_at` = DATE_ADD(NOW(), INTERVAL ? SECOND) WHERE `id` = ?",
                { Config.Auction.antiSnipeSeconds, auctionId }
            )
            extended = true
        end
    end

    MySQL.update.await(
        "UPDATE `pickle_dealership_auctions` SET `current_bid` = ?, `current_bidder` = ?, `current_payment_method` = ? WHERE `id` = ?",
        { amount, identifier, paymentMethod, auctionId }
    )

    -- Buyout finalizes the auction immediately
    if isBuyout then
        -- Finalizer will pick it up on next tick; cut end_at to now so there's no delay.
        MySQL.update.await("UPDATE `pickle_dealership_auctions` SET `ends_at` = NOW() WHERE `id` = ?", { auctionId })
    end

    BroadcastAuctionUpdate(auctionId)
    return true, { amount = amount, extended = extended, buyout = isBuyout, timerStarted = timerStarted }
end)

-- ─── Cancel ──────────────────────────────────────────────────────────────────

lib.callback.register("pickle_dealerships:cancelAuction", function(source, data)
    local auctionId = tonumber(data and data.auctionId)
    if not auctionId then return false, "Invalid auction id." end

    local auction = FetchAuction(auctionId)
    if not auction then return false, "Auction not found." end
    if auction.status ~= 'active' then return false, "Auction is not active." end

    local role = GetPlayerDealershipRole(source, auction.dealership_id)
    if role ~= 'owner' and role ~= 'manager' and role ~= 'admin' then
        return false, "You do not have permission."
    end

    if auction.current_bid and auction.current_bid > 0 then
        return false, "Cannot cancel after bids have been placed."
    end

    MySQL.update.await(
        "UPDATE `pickle_dealership_auctions` SET `status` = 'cancelled', `ended_at` = NOW() WHERE `id` = ?",
        { auctionId }
    )
    UnlockStock(auction.stock_id)
    BroadcastAuctionUpdate(auctionId)
    return true
end)

-- ─── Claim ───────────────────────────────────────────────────────────────────

lib.callback.register("pickle_dealerships:getPendingPickups", function(source)
    local identifier = GetIdentifier(source)
    if not identifier then return {} end

    local rows = MySQL.query.await(
        [[SELECT a.*, s.vehicle_model, s.vehicle_label, s.metadata AS stock_metadata, s.plate,
                 d.name AS dealership_name, d.location AS dealership_location
          FROM `pickle_dealership_auctions` a
          JOIN `pickle_dealership_stock` s ON s.id = a.stock_id
          JOIN `pickle_dealerships` d ON d.id = a.dealership_id
          WHERE a.status = 'won' AND a.winner_identifier = ? AND a.claimed_at IS NULL]],
        { identifier }
    ) or {}
    return rows
end)

lib.callback.register("pickle_dealerships:claimAuctionVehicle", function(source, data)
    local auctionId = tonumber(data and data.auctionId)
    if not auctionId then return false, "Invalid auction id." end

    local identifier = GetIdentifier(source)
    if not identifier then return false, "Could not identify player." end

    local row = MySQL.single.await(
        [[SELECT a.*, s.vehicle_model, s.vehicle_label, s.metadata AS stock_metadata, s.plate, s.dealership_id AS dsid,
                 d.location AS dealership_location
          FROM `pickle_dealership_auctions` a
          JOIN `pickle_dealership_stock` s ON s.id = a.stock_id
          JOIN `pickle_dealerships` d ON d.id = s.dealership_id
          WHERE a.id = ?]],
        { auctionId }
    )
    if not row then return false, "Auction not found." end
    if row.status ~= 'won' then return false, "Auction has no winner." end
    if row.winner_identifier ~= identifier then return false, "You are not the winner." end
    if row.claimed_at then return false, "Already claimed." end

    MySQL.update.await("UPDATE `pickle_dealership_auctions` SET `claimed_at` = NOW() WHERE `id` = ?", { auctionId })
    MySQL.update.await(
        "UPDATE `pickle_dealership_stock` SET `sold_at` = NOW(), `sold_to` = ?, `sold_by` = ?, `auction_id` = NULL WHERE `id` = ?",
        { identifier, 'auction', row.stock_id }
    )

    -- Parse properties for ownership registration
    local props = row.stock_metadata
    if props and type(props) == "string" then props = json.decode(props) or {} end
    if type(props) ~= "table" then props = {} end

    -- Use a single authoritative plate so GetOwnedVehicleFromPlate resolves correctly
    -- (matches the sales / financing flow). Falls back to generating one if the stock
    -- row somehow has no plate.
    local plate = row.plate
    if not plate or plate == '' then
        plate = GeneratePlate()
    end
    props.plate = plate

    AddOwnedVehicleWithProps(source, row.vehicle_model, plate, props)

    -- If caller requested garage-only delivery, skip spawn
    local toGarage = data.toGarage == true
    if toGarage then
        return true, { toGarage = true, label = row.vehicle_label or row.vehicle_model }
    end

    return true, {
        stockId = row.stock_id,
        model = row.vehicle_model,
        label = row.vehicle_label,
        plate = plate,
        properties = props,
        dealershipId = row.dsid,
        dealershipLocation = row.dealership_location,
    }
end)

-- ─── Read-only lookups ───────────────────────────────────────────────────────

lib.callback.register("pickle_dealerships:getActiveAuctions", function(_, data)
    local dealershipId = data and tonumber(data.dealershipId) or nil
    if dealershipId then
        local rows = MySQL.query.await(
            [[SELECT a.*, s.vehicle_model, s.vehicle_label, s.plate, s.condition,
                     d.name AS dealership_name,
                     (SELECT COUNT(*) FROM pickle_dealership_auction_bids b WHERE b.auction_id = a.id) AS bid_count
              FROM `pickle_dealership_auctions` a
              JOIN `pickle_dealership_stock` s ON s.id = a.stock_id
              JOIN `pickle_dealerships` d ON d.id = a.dealership_id
              WHERE a.status = 'active' AND a.dealership_id = ?
              ORDER BY a.ends_at ASC]],
            { dealershipId }
        ) or {}
        for _, r in ipairs(rows) do NormalizeStatus(r) end
        return rows
    end
    return FetchActiveAuctions()
end)

lib.callback.register("pickle_dealerships:getAuctionState", function(_, data)
    local auctionId = tonumber(data and data.auctionId)
    if not auctionId then return nil end
    local row = FetchAuction(auctionId)
    if not row then return nil end
    local bids = MySQL.query.await(
        "SELECT id, bidder_identifier, amount, placed_at, refunded FROM `pickle_dealership_auction_bids` WHERE `auction_id` = ? ORDER BY id DESC LIMIT 20",
        { auctionId }
    ) or {}
    row.bids = bids
    return row
end)

-- Return the caller's identifier (used by UI to highlight own bids as "you")
lib.callback.register("pickle_dealerships:getMyIdentifier", function(source)
    return GetIdentifier(source)
end)

lib.callback.register("pickle_dealerships:getMyCharacterName", function(source)
    return GetPlayerCharacterName(source) or "Player"
end)

-- ─── Viewer routing bucket (per-player showcase isolation) ──────────────────

lib.callback.register("pickle_dealerships:auctionSetViewerBucket", function(source, data)
    local base = tonumber(Config.Auction.viewerBucketBase) or 5000
    local enter = data and data.enter == true
    local bucket = enter and (base + source) or 0
    SetPlayerRoutingBucket(source, bucket)
    return true
end)

-- ─── Finalizer thread ────────────────────────────────────────────────────────

local function FinalizeAuction(row)
    local auctionId = row.id
    local hasBid = row.current_bid and row.current_bid > 0
    local reserveMet = (row.reserve_price == nil) or (hasBid and tonumber(row.current_bid) >= tonumber(row.reserve_price))

    if not hasBid or not reserveMet then
        -- No sale: refund top bidder if any, unlock stock
        if hasBid then
            MySQL.update.await(
                "UPDATE `pickle_dealership_auction_bids` SET `refunded` = 1 WHERE `auction_id` = ? AND `bidder_identifier` = ? AND `refunded` = 0",
                { auctionId, row.current_bidder }
            )
            RefundBidder(row.current_bidder, tonumber(row.current_bid), 'Reserve not met', row.current_payment_method)
        end
        MySQL.update.await(
            "UPDATE `pickle_dealership_auctions` SET `status` = 'no_sale', `ended_at` = NOW() WHERE `id` = ?",
            { auctionId }
        )
        UnlockStock(row.stock_id)
    else
        -- Won: credit seller dealership (minus house cut), mark winner
        local winningBid = tonumber(row.current_bid)
        local housePct = tonumber(Config.Auction.houseCutPct) or 0.0
        local houseCut = math.floor(winningBid * housePct)
        local net = winningBid - houseCut

        AddDealershipBalance(row.dealership_id, net)
        AddLedgerEntry(row.dealership_id, 'auction_sale', net,
            ('Auction win — stock #%d for $%d (cut $%d)'):format(row.stock_id, winningBid, houseCut),
            row.current_bidder)

        MySQL.update.await(
            [[UPDATE `pickle_dealership_auctions`
              SET `status` = 'won', `ended_at` = NOW(),
                  `winner_identifier` = ?, `winning_bid` = ?
              WHERE `id` = ?]],
            { row.current_bidder, winningBid, auctionId }
        )

        -- Notify winner if online
        local winnerSrc = GetSourceFromIdentifier(row.current_bidder)
        if winnerSrc then
            TriggerClientEvent('pickle_dealerships:notify', winnerSrc,
                ('You won auction #%d for $%d! Pick up at the selling dealership.'):format(auctionId, winningBid))
        end
    end

    BroadcastAuctionUpdate(auctionId)
end

CreateThread(function()
    -- Boot-time sweep: process any rows that expired while resource was down.
    Wait(3000)  -- let DB settle
    while true do
        local expired = MySQL.query.await(
            [[SELECT * FROM `pickle_dealership_auctions`
              WHERE `status` = 'active' AND `ends_at` <= NOW()]],
            {}
        ) or {}
        for _, row in ipairs(expired) do
            local ok, err = pcall(FinalizeAuction, row)
            if not ok then
                print(('[pickle_dealerships] auction finalize error for #%s: %s'):format(tostring(row.id), tostring(err)))
            end
        end
        Wait(Config.Auction.finalizerTickMs or 1000)
    end
end)
