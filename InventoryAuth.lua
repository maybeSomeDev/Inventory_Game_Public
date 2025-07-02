-- Sorry sometimes I tend to overexplain

-- Script Config
-- I use this to debug, and to easily disable saving/loading.
local canUseDataStore = script:GetAttribute("UseDataStore")

-- services / globals / libraries
-- "S_" so I can easily access it, without the need to type ...Serivce every time
-- and to make autocomplete not suggest playersService when trying to use the "player" varible ( without S_, the service name will be Players)
local S_ReplicatedStorage = game:GetService("ReplicatedStorage")
local S_DataStore = canUseDataStore and game:GetService("DataStoreService") or nil
local S_Http = game:GetService("HttpService")
local S_Players = game:GetService("Players")

local inventoryDataStore = canUseDataStore and S_DataStore:GetDataStore("inventory") or nil

-- fast/simple remote even creator
--[[
local public = {}

local new = require(script.newRemote)

public.updateInventory = new("updateInventory") -- of course new will check if the remote already exist before creating it
public.grab = new("grab")
public.use = new("use")
public.drop = new("drop")
public.switchedItems = new("switched")

return public
]]
local remote = require(game.ReplicatedStorage.RemoteEvents) -- a container for all remote events in the game
-- a module script that stores all items info
-- the module script itself only loads the item data from its children module scripts
--[[
local allItems = {}

export type item = {
	["id"]: string | number,
	["name"]: string,
	["index"]: number,
	["body"]: Part | Model, -- can't be wrong...

	["usable"]: boolean,

	Use: (player: Player) -> (),
}

for _,item: ModuleScript in script:GetChildren() do
	allItems[item.Name] = require(item)
end

return table.freeze(allItems)
]]
local listofItems = require(S_ReplicatedStorage.ListOfItems)
-- empty module script, to share the inventories for other server scripts ( if needed )
local stored = require(script.Parent.PlayersInventories)

--[[================================================================]]
-- privates / constants

local playersInventories = stored.inventories

local MAX_INVENTORY_SLOTS = 40
local MAX_HOTBAR_SLOTS = 10

local MAX_GRAB_DISTANCE = 20

-- to keep when saving to the datastore
local PROPERTIES_TO_SAVE = {
	["id"] = true,
	["index"] = true,
}

-- to load it from the datastore, when loading the player inventory for the first time
-- these are properties that the player will need to display it in the inventory UI
local PROPERTIES_TO_Load = {
	["name"] = true,
	["usable"] = true,
}

--[[================================================================]]
-- types

type inventory = { listofItems.item }

--[[================================================================]]
-- Validate ...

-- returning the instance, so I can reuse the same function to get the instance, while still making sure that it's valid
local isValidPlayer = {
	player = function(player: Player)
		if not player or not player.Parent then
			return false
		end
		return true
	end,

	character = function(player: Player)
		local character: Model = player.Character
		if not character then
			return false
		end

		return character
	end,

	humanoid = function(player: Player)
		local humanoid: Humanoid = player.Character:FindFirstChild("Humanoid")
		if not humanoid then
			return false
		end

		if humanoid.Health < 1 then
			return false
		end

		return humanoid
	end,
}

-- What's the differnce? the passed args
local isValidItem = {
	validPart = function(itemPart: Part): boolean
		if not itemPart or not itemPart.Parent then
			return false
		end
		return true
	end,

	correctID = function(itemPart: Part): number
		local itemID = itemPart:GetAttribute("id")

		-- it's habit I have. "( cond )" so i can easily ignore "~" or "not" and see the main condition before reversing it
		-- only if the condition is a bit big, hard to read.
		if not listofItems[itemID] then
			return false
		end

		-- no need to make another functions to check for the same thing
		local isItemTaken = itemPart:GetAttribute("taken")
		if isItemTaken then
			return false
		end

		return itemID
	end,

	distance = function(itemPart: Part, player: Player): boolean
		local primaryPart = player.Character.PrimaryPart

		if (primaryPart.Position - itemPart.Position).Magnitude > MAX_GRAB_DISTANCE then
			return false
		end

		return true
	end,
}

function fullyValidatePlayer(player: Player): boolean
	for _, getResult: (Player?) -> boolean? in isValidPlayer do
		if not getResult(player) then
			return false
		end
	end
	return true
end

function fullyValidateItem(itemPart: Part, player: Player): boolean
	for _, getResult: (Part, Player) -> boolean? in isValidItem do
		if not getResult(itemPart, player) then
			return false
		end
	end
	return true
end

--[[================================================================]]
-- inventory Functions

-- make place for the player inventory and create any config/attributes neede
function newInventory(player: Player)
	if not playersInventories[player.UserId] then
		playersInventories[player.UserId] = {}
	end

	player:SetAttribute("maxInventorySlots", MAX_INVENTORY_SLOTS)
	player:SetAttribute("maxHotbarSlots", MAX_HOTBAR_SLOTS)
end

-- I had to write this a lot, that's why I made a function for it
function getInventory(player: Player): inventory
	return playersInventories[player.UserId]
end

function findItemByIndex(inventory: inventory, index: number): listofItems.item
	for _, item in inventory do
		if item.index == index then
			return item
		end
	end
	return false
end

-- for every item there's a copy for the client and a copy for the server
-- the "OriginalCopy" is for the server copy, this will have the item functions and some other info
function getItemOriginalCopy(itemID: number)
	return listofItems[itemID]
end
--[[ find which slot is empty to put the item in it
	
	Example
	{2,4,6,9}
	
	returns
	{1,3,5,7,8}
]]
function findEmptySlot(myInventory: inventory, oneSlot: boolean, limitTo: number?): number | { number }
	--myInventory = { -- testing it
	--	{index = 2},
	--	{index = 4},
	--	{index = 6},
	--	{index = 9},
	--}

	-- search a limited number of slots, if not specified, then search through all the inventory
	local combinedCapacity = limitTo or (MAX_HOTBAR_SLOTS + MAX_INVENTORY_SLOTS)

	local fullSlots = {}
	local emptySlots = {}

	for _, item in myInventory do
		fullSlots[item.index] = true
	end

	-- search all full slots from the start (1) and return whatever you don't find  (i.e. empty)
	for emptyIndex = 1, combinedCapacity do
		if not fullSlots[emptyIndex] then
			if oneSlot then
				return emptyIndex
			end

			table.insert(emptySlots, emptyIndex)
		end
	end

	return emptySlots :: { number }
end

function spawnItemFromID(item: item, position: Vector3)
	local body = item.body
	local mainPart: Part

	if not body:IsA("Part") and not body:IsA("MeshPart") and not body:IsA("Model") then return end

	local newCFrame = CFrame.new(position) * CFrame.identity

	local newItem: Part & Model = body:Clone()

	newItem.Parent = workspace

	if body:IsA("Model") then
		newItem:PivotTo(newCFrame)
		mainPart = newItem.PrimaryPart
	else -- is a part
		newItem.CFrame = newCFrame
		mainPart = newItem
	end

	-- a cooldown, so the player doesn't pick the item right after dropping it
	--[[
		-- I could've add a black list function: that stops 1 player from picking the item for a few seconds
		-- but that's just an extra, not needed complexity. it's simple to make but not very urgent
	]]
	task.delay(2, function()
		-- adding tag twice, because if the item is a model we'll be adding the tag to the maing model, Primary Part
		-- tagging the model, to destroy it when grabbing the item. and not leave it empty just sitting there
		newItem:AddTag("item")
		mainPart:SetAttribute("id", item.id)
		mainPart:AddTag("item")
	end)
end

-- outside of "grabItem" function, so I can use it for other cases ( loot, gifts, admin giveItem command, and so on without checking for anything)
-- this will bypass all checks.
function giveItem(player: Player, itemID: number)
	local myInventory = getInventory(player)
	local newItem = table.clone(listofItems[itemID])

	local emptySlot = findEmptySlot(myInventory, true)
	newItem.index = emptySlot

	table.insert(myInventory, newItem)
	remote.updateInventory:FireClient(player, myInventory)
end

function setPlayerInventoryTo(player: Player, newInventory: inventory)
	playersInventories[player.UserId] = newInventory
	remote.updateInventory:FireClient(player, newInventory)
end

-- this will bypass all checks, use it carefully
function removeItemFromInventory(inventory: inventory, index: number)
	for tableIndex, item in inventory do
		if item.index == index then
			table.remove(inventory, tableIndex)
		end
	end
end

-- I don't think I need to comment on these three functions right? ( Their names kind of explain everything )
function grabItem(player: Player, itemPart: Part)
	-- not an item...
	if not itemPart:HasTag("item") then return end
	-- prevent multiple players from grabbing the same item
	if itemPart:GetAttribute("taken") then return end

	if not fullyValidatePlayer(player) or not fullyValidateItem(itemPart, player) then return end

	local itemID = isValidItem.correctID(itemPart) -- getting the id, not validating it again

	itemPart:SetAttribute("taken", true)
	-- this one isn't really needed, but I'm adding it for feature me to make some effects using it
	itemPart:SetAttribute("owner", player.UserId)

	giveItem(player, itemID)

	local parentModel = itemPart:FindFirstAncestorOfClass("Model")
	-- destroy the itemPart model ( if it has one )
	if parentModel and parentModel:HasTag("item") then
		parentModel:Destroy()
		return
	end

	-- if not, then destroy the part normally
	itemPart:Destroy()
end

function useItem(player: Player, itemIndex: number)
	-- player died or left after they tried to use the item
	if not fullyValidatePlayer(player) then return end

	local myInventory = getInventory(player)
	local item = findItemByIndex(myInventory, itemIndex)
	if not item then return end

	-- the Use function isn't stored on the client item copy
	-- but the original one, that is stored in a module script
	item = getItemOriginalCopy(item.id)

	item.Use(player)
end

function dropItem(player: Player, itemIndex: number)
	if not fullyValidatePlayer(player) then return end

	local myInventory = getInventory(player)
	local item = findItemByIndex(myInventory, itemIndex)
	if not item then return end

	-- read the function comment
	local originialItem = getItemOriginalCopy(item.id)

	removeItemFromInventory(myInventory, itemIndex)

	-- I'm updating it here and not in "removeItemFromInventory" or in "spawnItemFromID"
	-- beacuse both of them don't accept player in their args
	remote.updateInventory:FireClient(player, myInventory)

	local playerPrimPart = player.Character.PrimaryPart
	-- make the spawn postion in front the player
	local itemSpawnPos = playerPrimPart.Position + (playerPrimPart.CFrame.LookVector * 4) + Vector3.new(0, 2, 0)
	spawnItemFromID(originialItem, itemSpawnPos)
end

-- player rearranged their items, validate action and save the new inventory
function switchedItems(player: Player, newInventory: inventory)
	local myInventory = getInventory(player)
	-- things to check for
	local sameItemsCount = false
	local sameItems = false

	if #myInventory == #newInventory then
		sameItemsCount = true
	end

	-- player has an extra unauthorized item, or is missing one.
	-- either way don't accept the player inventory and tell them to use the one stored on the server
	if not sameItemsCount then
		remote.updateInventory:FireClient(player, myInventory)
		return
	end

	-- I only changed item.index. Therefore the item table index is the same
	for index, item in newInventory do
		-- looking in the server inventory to see if the items are different or not
		if not (myInventory[index].id == item.id) then
			return
		end
	end
	sameItems = true

	-- everything is clear, update the inventory
	setPlayerInventoryTo(player, newInventory)
end

---[[================================================================]]
-- DataStore

function loadData(player: Player)
	newInventory(player)
	if not canUseDataStore then return end

	local success, errorMsg = pcall(function()
		return inventoryDataStore:GetAsync(player.UserId)
	end)

	if success and errorMsg then
		local newInventory = errorMsg
		-- get every item in the player inventory
		for itemIndex, item in newInventory do
			local itemOriginalData = getItemOriginalCopy(item.id)
			-- item id is not valid, item was deleted from the game, or some other reason.
			if not itemOriginalData then
				warn("deleted item with invalid id: "..item.id)
				newInventory[itemIndex] = nil
				continue
			end
			-- and add everything in PROPERTIES_TO_Load
			for propertyName, _ in PROPERTIES_TO_Load do
				item[propertyName] = itemOriginalData[propertyName] -- getting the value from the original copy
			end
		end
		playersInventories[player.UserId] = newInventory
		--playersInventories[player.UserId] = {}
		remote.updateInventory:FireClient(player, playersInventories[player.UserId])
	else
		player:Kick("Roblox Datastores are down, come back tomorrow. " .. errorMsg)
		warn(errorMsg)
	end
end

function saveData(player: Player)
	if not canUseDataStore then return end

	local myInventory = getInventory(player)

	for _, item in myInventory do
		for propertyName, _ in item do
			-- if set to save this value, the skip
			if PROPERTIES_TO_SAVE[propertyName] then
				continue
			end
			-- if not then delete it, no need to save it
			item[propertyName] = nil
		end
	end
	local success, errorMsg = pcall(function()
		return inventoryDataStore:SetAsync(player.UserId, myInventory)
	end)

	if not success then
		warn("Player data was lost")
		-- anyway this is supposed to be an invetnroy with simple datastore
		-- I'm not going to fill it with more lines on how handle Roblox errors... in a portfolio project
	end
end

--[[================================================================]]
-- events / entry point
--
remote.grab.OnServerEvent:Connect(grabItem)
remote.use.OnServerEvent:Connect(useItem) -- only hotbar items
remote.drop.OnServerEvent:Connect(dropItem) --  only hotbar items
-- I'll later work on making these work for the main inventory. The code is mostly client sided, which is why it doesn't matter here much

remote.switchedItems.OnServerEvent:Connect(switchedItems)

S_Players.PlayerAdded:Connect(function(player: Player)
	loadData(player)
end)

S_Players.PlayerRemoving:Connect(function(player: Player)
	saveData(player)

	-- clear memory to pervent memory leak
	if playersInventories[player.UserId] then
		playersInventories[player.UserId] = nil
	end
end)
