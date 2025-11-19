-- Automated trade: wait for incoming request from target player, then accept, add pets, message, and ready.
-- Settings
local TARGET_PLAYER_NAME = "289012SPJ12" -- exact username of the player who should request you
local PET_NAME = "Huge Zombie Pig"            -- pet display name to add
local DESIRED_RARITY_STRING = nil        -- e.g. "Mythical" or nil to ignore rarity check
local VARIANT = {                        -- variant filters (set nil for "don't care")
    shiny = false,     -- true / false / nil
    golden = false,
    rainbow = false,
    gargantuan = false,
    titanic = false,
    huge = true,
}
local TRADE_PET_TOTAL = 1                -- total number of that pet to add to trade
local DONE_MESSAGE = "Done — added pets and ready." -- message to send in trade chat when finished
local REQUEST_CHECK_POLL_INTERVAL = 0.6  -- seconds to poll GetAllRequests (fallback)
local REQUEST_DETECT_TIMEOUT = 120        -- seconds to wait for incoming request before giving up

-- Services & libraries
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Library = ReplicatedStorage:WaitForChild("Library")
local Network = ReplicatedStorage:WaitForChild("Network")

local InventoryCmds = require(Library.Client.InventoryCmds)
local Types = require(Library.Items.Types)
local TradingCmds = require(Library.Client.TradingCmds)

-- Optional rarity directory (best-effort). If missing, rarity checks will be skipped.
local RarityDir
local function tryLoadRarityDirectory()
    local ok, mod = pcall(function() return require(Library.Directory.Rarity) end)
    if ok and type(mod) == "table" then
        RarityDir = mod
    else
        RarityDir = nil
    end
end
pcall(tryLoadRarityDirectory)

-- Utility: get Player object from username
local function getPlayerByName(name)
    if not name then return nil end
    return Players:FindFirstChild(name)
end

-- Variant match (nil = don't care)
local function variantMatches(pet)
    if VARIANT.shiny ~= nil and (pcall(function() return pet:IsShiny() end) and pet:IsShiny() or false) ~= VARIANT.shiny then return false end
    if VARIANT.golden ~= nil and (pcall(function() return pet:IsGolden() end) and pet:IsGolden() or false) ~= VARIANT.golden then return false end
    if VARIANT.rainbow ~= nil and (pcall(function() return pet:IsRainbow() end) and pet:IsRainbow() or false) ~= VARIANT.rainbow then return false end
    if VARIANT.gargantuan ~= nil and (pcall(function() return pet:IsGargantuan() end) and pet:IsGargantuan() or false) ~= VARIANT.gargantuan then return false end
    if VARIANT.titanic ~= nil and (pcall(function() return pet:IsTitanic() end) and pet:IsTitanic() or false) ~= VARIANT.titanic then return false end
    if VARIANT.huge ~= nil and (pcall(function() return pet:IsHuge() end) and pet:IsHuge() or false) ~= VARIANT.huge then return false end
    return true
end

-- Optional rarity match: returns true if pet:GetRarity() equals desired rarity object
local function rarityMatches(pet)
    if not DESIRED_RARITY_STRING then return true end
    if not RarityDir then
        -- Rarity module not found; fail-safe is to allow (or you can return false to require directory)
        return true
    end
    local desiredObj = RarityDir[DESIRED_RARITY_STRING]
    if not desiredObj then
        -- unknown requested rarity -> treat as non-matching
        return false
    end
    local ok, petRarity = pcall(function() return pet:GetRarity() end)
    if not ok or not petRarity then
        return false
    end
    return petRarity == desiredObj
end

-- Find matching pet stacks in inventory: returns array of { uid, amount, pet }
local function findMatchingPetStacks()
    local container = InventoryCmds.Container()
    if not container then return {} end
    local all = container:All(Types.Pet)
    local out = {}
    for uid, pet in pairs(all) do
        if pet and pet:IsA and pet:IsA("Pet") then
            local name = nil
            local okDir, dir = pcall(function() return pet:Directory() end)
            if okDir and dir and dir.name then
                name = dir.name
            else
                local okId, id = pcall(function() return pet:GetId() end)
                if okId and id then name = id end
            end
            if name == PET_NAME and variantMatches(pet) and rarityMatches(pet) then
                local okAmt, amt = pcall(function() return pet:GetAmount() end)
                if not okAmt then amt = 1 end
                table.insert(out, { uid = uid, amount = tonumber(amt) or 1, pet = pet })
            end
        end
    end
    return out
end

-- Add pets to trade using TradingCmds.SetItem (client module)
local function addPetsToTrade(stacks, totalToAdd)
    local added = 0
    if not stacks or #stacks == 0 then return 0 end
    for _, entry in ipairs(stacks) do
        if added >= totalToAdd then break end
        local toTake = math.min(totalToAdd - added, entry.amount)
        local ok, res = pcall(function() return TradingCmds.SetItem("Pet", entry.uid, toTake) end)
        if ok and res then
            added = added + toTake
            print(("[AutoTrade] Added %d x %s (UID %s)"):format(toTake, PET_NAME, entry.uid))
        else
            warn("[AutoTrade] Failed to add UID", entry.uid, ":", tostring(res))
        end
        task.wait(0.12) -- small delay to reduce rate issues
    end
    return added
end

-- Send trade chat message using Remote
local function sendTradeMessage(tradeId, msg)
    if not tradeId or not msg then return end
    pcall(function()
        Network["Server: Trading: Message"]:InvokeServer(tradeId, msg)
    end)
end

-- Set ready using Remote (uses trade counter)
local function setTradeReady(tradeState)
    if not tradeState then return end
    local id = tradeState._id
    local counter = tradeState._counter or 1
    pcall(function()
        Network["Server: Trading: Set Ready"]:InvokeServer(id, true, counter)
    end)
end

-- Accept (request) back to create the trade after they request you
local function acceptRequestByRequestingBack(targetPlayer)
    if not targetPlayer then return false end
    local ok, res = pcall(function()
        return Network["Server: Trading: Request"]:InvokeServer(targetPlayer)
    end)
    if not ok then
        warn("[AutoTrade] Failed to invoke Request remote:", tostring(res))
        return false
    end
    return true
end

-- Detect incoming request from target. First try event, then fallback to polling GetAllRequests
local function waitForRequestFromTarget(timeout)
    local t0 = tick()
    local targetPlayer = getPlayerByName(TARGET_PLAYER_NAME)
    if not targetPlayer then
        warn("[AutoTrade] Target player not in Players list. Waiting for them to appear...")
        -- wait for target to join
        targetPlayer = Players:WaitForChild(TARGET_PLAYER_NAME, timeout or 10)
        if not targetPlayer then
            warn("[AutoTrade] Target player never appeared.")
            return false
        end
    end

    -- Try event hook
    local eventConnected = false
    local resolved = false
    if TradingCmds and TradingCmds.TradeRequested and type(TradingCmds.TradeRequested.Connect) == "function" then
        eventConnected = true
        local conn
        conn = TradingCmds.TradeRequested:Connect(function(a, b, c)
            -- Common signature: (fromPlayer, toPlayer, data) but might vary. We attempt to detect.
            if resolved then return end
            local function isPlayer(x) return typeof(x) == "Instance" and x:IsA("Player") end
            local fromP, toP = nil, nil
            if isPlayer(a) and isPlayer(b) then
                fromP, toP = a, b
            elseif isPlayer(a) and type(b) == "table" and b.Player then
                fromP = a toP = b.Player
            else
                -- fallback: check any arg equal to target player
                for _, v in ipairs({a,b,c}) do
                    if isPlayer(v) and v == targetPlayer then
                        -- assume this is either from or to; if targetPlayer is the requester, we still want it
                        -- we will accept when targetPlayer has an outgoing request that includes us (fallback poll)
                        resolved = true
                        conn:Disconnect()
                        return
                    end
                end
            end
            if fromP and toP then
                if (toP == Players.LocalPlayer and fromP == targetPlayer) or (toP == targetPlayer and fromP == Players.LocalPlayer) then
                    -- incoming request: from target -> localplayer
                    if toP == Players.LocalPlayer and fromP == targetPlayer then
                        resolved = true
                        conn:Disconnect()
                        return
                    end
                end
            end
        end)
    end

    -- Polling fallback (and also use it to confirm event detection)
    while (not resolved) and tick() - t0 < (timeout or REQUEST_DETECT_TIMEOUT) do
        -- Check requests table: TradingCmds.GetAllRequests() -> returns table of requests
        local ok, allReq = pcall(function() return TradingCmds.GetAllRequests() end)
        if ok and allReq then
            -- allReq is a table keyed by Player instances or names; see if there's a request from target to us
            for fromPlayer, t in pairs(allReq) do
                -- ensure fromPlayer is Player instance or compare name
                local matchFrom = false
                if typeof(fromPlayer) == "Instance" and fromPlayer:IsA("Player") then
                    matchFrom = (fromPlayer == targetPlayer)
                elseif type(fromPlayer) == "string" then
                    matchFrom = (fromPlayer == TARGET_PLAYER_NAME)
                end
                if matchFrom then
                    -- t should be a table of requests keyed by target players; check for LocalPlayer
                    if type(t) == "table" then
                        for toPlayer, _ in pairs(t) do
                            local matchesLocal = false
                            if typeof(toPlayer) == "Instance" and toPlayer:IsA("Player") then
                                matchesLocal = (toPlayer == Players.LocalPlayer)
                            elseif type(toPlayer) == "string" then
                                matchesLocal = (toPlayer == Players.LocalPlayer.Name)
                            end
                            if matchesLocal then
                                resolved = true
                                break
                            end
                        end
                    end
                end
                if resolved then break end
            end
        end
        if resolved then break end
        task.wait(REQUEST_CHECK_POLL_INTERVAL)
    end

    return resolved
end

-- Top-level orchestration
coroutine.wrap(function()
    print("[AutoTrade] Waiting for incoming trade request from:", TARGET_PLAYER_NAME)
    local got = waitForRequestFromTarget(REQUEST_DETECT_TIMEOUT)
    if not got then
        warn("[AutoTrade] No incoming request detected from", TARGET_PLAYER_NAME, "within timeout.")
        return
    end
    print("[AutoTrade] Detected request from target. Accepting by invoking Request back...")

    local targetPlayer = getPlayerByName(TARGET_PLAYER_NAME)
    if not targetPlayer then
        warn("[AutoTrade] Target player disappeared before accept.")
        return
    end

    local ok = acceptRequestByRequestingBack(targetPlayer)
    if not ok then
        warn("[AutoTrade] Failed to accept (invoke Request).")
        return
    end

    -- wait for trade state to exist
    local function waitForTradeState(timeout)
        local t0 = tick()
        while tick() - t0 < (timeout or 8) do
            local st = TradingCmds.GetState()
            if st then return st end
            task.wait(0.12)
        end
        return nil
    end

    local tradeState = waitForTradeState(12)
    if not tradeState then
        warn("[AutoTrade] Trade state did not appear after accepting.")
        return
    end

    print("[AutoTrade] Trade opened (id):", tradeState._id)

    -- Find matching stacks and add pets
    local stacks = findMatchingPetStacks()
    if #stacks == 0 then
        sendTradeMessage(tradeState._id, "No matching pets found to add.")
        warn("[AutoTrade] No matching pet stacks found.")
        return
    end

    local added = addPetsToTrade(stacks, TRADE_PET_TOTAL)
    if added > 0 then
        sendTradeMessage(tradeState._id, ("Added %d %s to trade."):format(added, PET_NAME))
    else
        sendTradeMessage(tradeState._id, "Failed to add the requested pets.")
    end

    -- Ready
    setTradeReady(tradeState)
    sendTradeMessage(tradeState._id, DONE_MESSAGE)
    print("[AutoTrade] Completed flow: added=", added, "and readied.")
end)()
