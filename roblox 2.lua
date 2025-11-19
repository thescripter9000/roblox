-- SETTINGS -- CHANGE THESE!
local targetPlayerName = "289012SPJ12"      -- Trading partner's Roblox username
local desiredPetName = "Huge Zombie Pig"         -- Name of the pet you want to trade
local desiredVariant = {                    -- Set desired variant, only fill in what you want. Example below gets Golden pets
    shiny = false, 
    golden = false, 
    rainbow = false,
    gargantuan = false, 
    titanic = false,
    huge = true
}
local petsToAddCount = 5                    -- How many to add to the trade

-----------------------------------------------------------------

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Library = ReplicatedStorage:WaitForChild("Library")
local InventoryCmds = require(Library.Client.InventoryCmds)
local Types = require(Library.Items.Types)
local Network = ReplicatedStorage:WaitForChild("Network")
local TradingCmds = require(Library.Client.TradingCmds)

local function isPetMatchingVariant(pet, variantTable)
	local pass = true
	if variantTable.shiny ~= nil then
		pass = pass and (pet:IsShiny() == variantTable.shiny)
	end
	if variantTable.golden ~= nil then
		pass = pass and (pet:IsGolden() == variantTable.golden)
	end
	if variantTable.rainbow ~= nil then
		pass = pass and (pet:IsRainbow() == variantTable.rainbow)
	end
	if variantTable.gargantuan ~= nil then
		pass = pass and (pet:IsGargantuan() == variantTable.gargantuan)
	end
	if variantTable.titanic ~= nil then
		pass = pass and (pet:IsTitanic() == variantTable.titanic)
	end
	if variantTable.huge ~= nil then
		pass = pass and (pet:IsHuge() == variantTable.huge)
	end
	return pass
end

local function getAllPetUIDsByNameAndVariant(petName, variantTable)
	local container = InventoryCmds.Container()
	if not container then return {} end

	local pets = container:All(Types.Pet)
	local matches = {}

	for uid, pet in pairs(pets) do
		if pet then
			local name = nil
			local dirSuccess, dir = pcall(function() return pet:Directory() end)
			if dirSuccess and dir and dir.name then
				name = dir.name
			else
				local idSuccess, id = pcall(function() return pet:GetId() end)
				if idSuccess and id then
					name = id
				end
			end
			
			if name and name == petName and isPetMatchingVariant(pet, variantTable) then
				table.insert(matches, {
					uid = uid,
					amount = (pcall(function() return pet:GetAmount() end) and pet:GetAmount()) or 1,
					pet = pet
				})
			end
		end
	end

	return matches
end

local function acceptTrade()
	local otherPlayer = Players:FindFirstChild(targetPlayerName)
	if not otherPlayer then
		warn("Trading partner not found: " .. tostring(targetPlayerName))
		return false
	end
	Network["Server: Trading: Request"]:InvokeServer(otherPlayer)
	wait(0.2)
	return true
end

local function waitForTrade()
	for i = 1,20 do -- Up to ~2 seconds
		local state = TradingCmds.GetState()
		if state then return state end
		wait(0.1)
	end
	return nil
end

local function addPetsToTradeByUID(uidList, amountToAdd)
	local addedCount = 0
	local state = TradingCmds.GetState()
	if not state then
		print("No active trade found. Cannot add pets.")
		return 0
	end

	for _, entry in ipairs(uidList) do
		local addAmount = math.min(amountToAdd - addedCount, entry.amount)
		if addAmount <= 0 then break end

		local ok, err = TradingCmds.SetItem("Pet", entry.uid, addAmount)
		if ok then
			addedCount = addedCount + addAmount
			print(string.format("✅ Added %d x %s | UID %s", addAmount, desiredPetName, entry.uid))
		else
			print(string.format("❌ Failed to add UID %s | Error: %s", entry.uid, tostring(err)))
		end

		wait(0.15) -- avoid rate limiting
		if addedCount >= amountToAdd then break end
	end

	return addedCount
end

local function sendTradeMessage(msg)
	local state = TradingCmds.GetState()
	if not state then return end
	Network["Server: Trading: Message"]:InvokeServer(state._id, msg)
	wait(0.1)
end

local function setTradeReady()
	local state = TradingCmds.GetState()
	if not state then return end
	local tradeId = state._id
	local readyBool = true
	local counter = state._counter or 1
	Network["Server: Trading: Set Ready"]:InvokeServer(tradeId, readyBool, counter)
end

-- === MAIN RUNNER ===
print("[Automated Trade Script] Accepting trade...")
acceptTrade()
local currentTradeState = waitForTrade()
if not currentTradeState then
	warn("Trade did not start!")
	return
end
print("Trade started with:", targetPlayerName, "| Trade id:", currentTradeState._id)

local petsToAdd = getAllPetUIDsByNameAndVariant(desiredPetName, desiredVariant)
if #petsToAdd == 0 then
	sendTradeMessage("No matching pets found to trade!")
	warn("No matching pets found for name/variant.")
	return
end

print("Found", #petsToAdd, "matching pet stack(s). Attempting to add up to", petsToAddCount)
local actuallyAdded = addPetsToTradeByUID(petsToAdd, petsToAddCount)

if actuallyAdded > 0 then
	sendTradeMessage(("Added %d %s to trade. Ready!"):format(actuallyAdded, desiredPetName))
else
	sendTradeMessage("Could not add any pets to the trade.")
end

setTradeReady()
print("Done, trade ready.")
