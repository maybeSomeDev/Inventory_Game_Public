-- to enable or disable the DataStore... Useful for debugging
local canUseDataStore = script:GetAttribute("UseDataStore")

-- services / globals / libraries
-- "S_" for easier/faster access to Roblox services
local S_ReplicatedStorage = game:GetService("ReplicatedStorage")
local S_DataStore = canUseDataStore and game:GetService("DataStoreService") or nil
local S_Http = game:GetService("HttpService")
local S_Players = game:GetService("Players")

local inventoryDataStore = canUseDataStore and S_DataStore:GetDataStore("inventory") or nil

-- a module to setup and store Remote Events
-- when accessed for the second time it'll return the previously created remote event
local remote = require(game.ReplicatedStorage.RemoteEvents) -- a container for all remote events in the game

-- a module script that stores all items info
-- the module script itself only loads the item data from its children module scripts
-- every child module script has its own item data and assets ( name, functions, images, object/part/model of the item)
local listofItems = require(S_ReplicatedStorage.ListOfItems)

-- a module script that stores/exposes all players inventories
local stored = require(script.Parent.PlayersInventories)

--[[================================================================]]
-- privates / constants

-- there may be other varibles or data types in the module
-- here we only want the raw inventories and nothing else
local playersInventories = stored.inventories

local MAX_INVENTORY_SLOTS = 40
local MAX_HOTBAR_SLOTS = 10

local MAX_GRAB_DISTANCE = 20

-- inventory data which is going to be saved in the DataStores
local PROPERTIES_TO_SAVE = {
	-- the only way to identify/differentiate between items
	["id"] = true,
	-- where's the item stored in the player inventory UI ( slot number )
	["index"] = true,
}

-- data that'll be loaded and stored in the client-side inventory copy
local PROPERTIES_TO_Load = {
	["name"] = true,
	["usable"] = true,
}

--[[================================================================]]
-- types

type inventory = { listofItems.item }

--[[================================================================]]
-- Validate

-- a collection of functions to validate the player's actions, to ensure that there're no small bugs (E.G. where the player can pick up items even after death)
-- return FALSE if the action is invalid, otherwise return the instance that was validated or true no instance is involved/we already have it
-- returning the instance allows these functions to have a second use case: that's to search for an instance while still keeping it's basic checks
-- E.G if we're trying to grab the player humanoid, then most likely we'll not want the humanoid/player to be dead
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

-- what's the difference? the passed args, and what's being validated
local isValidItem = {
	validPart = function(itemPart: Part): boolean
		if not itemPart or not itemPart.Parent then
			return false
		end
		return true
	end,

	-- returns the item ID
	canTakeItem = function(itemPart: Part, player: Player): number
		local itemID = itemPart:GetAttribute("id")

		if not listofItems[itemID] then
			return false
		end

		-- no need to make another functions to check for the same thing
		local isItemTaken = itemPart:GetAttribute("taken")
		if isItemTaken then
			return false
		end

		-- the player inventory is already full
		local myInventory = getInventory(player)
		if #myInventory >= ( MAX_HOTBAR_SLOTS + MAX_INVENTORY_SLOTS ) then
			return false
		end

		return itemID
	end,

	distance = function(itemPart: Part, player: Player, givenDistance): boolean
		local primaryPart = player.Character.PrimaryPart
		-- if no distance is provided, default to MAX_GRAB_DISTANCE
		-- this allows the function to be used in an auto mode where only the item and player are given
		givenDistance = givenDistance or MAX_GRAB_DISTANCE
		if (primaryPart.Position - itemPart.Position).Magnitude > givenDistance then
			return false
		end

		return true
	end,
}

-- auto mode, to validate everything
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

-- making place for the player inventory so we can add/load the items into it
-- and giving the player any other data they need/inventory config
function newInventory(player: Player)
	if not playersInventories[player.UserId] then
		playersInventories[player.UserId] = {}
	end

	-- set inventory limits on the player
	-- there's another limit on the client side for how many items the UI can fit at once
	-- 42 for the inventory
	-- 10 for the hotbar
	-- if we tried to set MAX_INVENTORY_SLOTS to 90 the client will ignore and hide any items after the 42 slot
	player:SetAttribute("maxInventorySlots", MAX_INVENTORY_SLOTS)
	player:SetAttribute("maxHotbarSlots", MAX_HOTBAR_SLOTS)
end

function getInventory(player: Player): inventory
	return playersInventories[player.UserId]
end

-- search the player invenotry for an item with the same index
function findItemByIndex(inventory: inventory, index: number): listofItems.item
	for _, item in inventory do
		if item.index == index then
			return item
		end
	end
	return false
end

-- for every item there're two copies of it: server-side(full version/OriginalCopy) and client-side(lighter one)
-- the client-side version will only have data that the player can change (index) or data that they'll need (item name and icon)
-- another use case: is to check if an item exist with this id
function getItemOriginalCopy(itemID: number)
	return listofItems[itemID]
end

-- loop trough the inventory to find which slot is empty
-- the items will be stored in the inventory in this scheme
--[[
{
	[1] = {index = 3}
	[2] = {index = 5}
	[3] = {index = 1}
}
]]
function findEmptySlot(myInventory: inventory, oneSlot: boolean, limitTo: number?): number | { number }

	-- search a limited number of slots, and if not specified, search through all the inventory
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

	-- allowed item body types:
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

	-- delay tagging for two seconds to prevent the player who just dropped the item (or any other player)
	-- from grabbing it immediately
	task.delay(2, function()
		-- tag the item and its parent model (if one exists)
		-- we're tagging the parent model to easily clean it when trying to destroy its item part without destroying any unrelated model
		newItem:AddTag("item")
		mainPart:SetAttribute("id", item.id)
		mainPart:AddTag("item")
	end)
end

-- give item to a player... can be used for ( loot, gifts, admin giveItem command, and so on without checking for anything)
function giveItem(player: Player, itemID: number)
	local myInventory = getInventory(player)
	local newItem = table.clone(listofItems[itemID])

	local emptySlot = findEmptySlot(myInventory, true)
	newItem.index = emptySlot

	table.insert(myInventory, newItem)
	remote.updateInventory:FireClient(player, myInventory)
end

-- fully replace the player inventory to a new version or another inventory
-- overwrites/removes the previous inventory version
-- can be used when loading inventory from the DataStore
function setPlayerInventoryTo(player: Player, newInventory: inventory)
	playersInventories[player.UserId] = newInventory
	remote.updateInventory:FireClient(player, newInventory)
end

-- remove the item with the given index from the player inventory
--[[ a small reminder to what's the player inventory looks like, to see the difference between tableIndex and ItemIndex
{
	-- 1 = tableIndex
	-- 3 = item index (which inventory slot the items is stored in)
	[1] = {index = 3}
}
]]
function removeItemFromInventory(inventory: inventory, index: number)
	for tableIndex, item in inventory do
		if item.index == index then
			table.remove(inventory, tableIndex)
		end
	end
end

-- player is trying to pick up an item
function grabItem(player: Player, itemPart: Part)
	-- not an item
	if not itemPart:HasTag("item") then return end
	-- prevent multiple players from grabbing the same item
	if itemPart:GetAttribute("taken") then return end

	if not fullyValidatePlayer(player) or not fullyValidateItem(itemPart, player) then return end

	-- getting the item id
	local itemID = isValidItem.canTakeItem(itemPart,player)

	itemPart:SetAttribute("taken", true)
	-- this attribute isn't being used for now but may be useful for adding effects logic in the future.
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

-- only accept the itemIndex from the client
-- this is a bit of a sensitive function, that's why we're only trusting the data
function useItem(player: Player, itemIndex: number)
	-- player died or left after they tried to use the item
	if not fullyValidatePlayer(player) then return end

	local myInventory = getInventory(player)
	local item = findItemByIndex(myInventory, itemIndex)
	-- player is trying to use an empty slot
	if not item then return end

	-- check if there's an item with this id
	-- and get the original to use its function later
	local originalItem = getItemOriginalCopy(item.id)

	if not originalItem then return end

	-- the Use function isn't stored on the client item copy
	-- but the original one, that is stored in a module script
	originalItem.Use(player)
end

function dropItem(player: Player, itemIndex: number)
	if not fullyValidatePlayer(player) then return end

	local myInventory = getInventory(player)
	local item = findItemByIndex(myInventory, itemIndex)
	if not item then return end

	local originialItem = getItemOriginalCopy(item.id)
	if not originialItem then return end

	removeItemFromInventory(myInventory, itemIndex)

	remote.updateInventory:FireClient(player, myInventory)

	local playerPrimPart = player.Character.PrimaryPart

	-- make the spawn position in front and a bit above the player
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

	-- player has an extra unauthorized item, or is missing one
	-- either way don't accept the player inventory and tell them to use the one stored on the server
	if not sameItemsCount then
		remote.updateInventory:FireClient(player, myInventory)
		return
	end

	-- the player only changed the item.index. Therefore the item table index should be the same
	for index, item in newInventory do
		-- looking in the server inventory to see if the items are different or not
		if not (myInventory[index].id == item.id) then
			return
		end
	end

	sameItems = true

	-- everything is clear
	setPlayerInventoryTo(player, newInventory)
end

---[[================================================================]]
-- simple DataStore
-- this script/project is more focused on making the inventory
-- if we need a better data store, then we'll have to make its own module script for it

function loadData(player: Player)
	if not canUseDataStore then return end

	local success, errorMsg = pcall(function()
		return inventoryDataStore:GetAsync(player.UserId)
	end)

	if success and errorMsg then
		local newInventory = errorMsg
		-- get every item in the player inventory
		for itemIndex, item in newInventory do
			local itemOriginalData = getItemOriginalCopy(item.id)
			-- item id is not valid, item was deleted from the game, or some other reason
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

		setPlayerInventoryTo(player,newInventory)
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
			-- if set to save this value, then keep them
			if PROPERTIES_TO_SAVE[propertyName] then
				continue
			end
			-- otherwise delete them
			item[propertyName] = nil
		end
	end
	local success, errorMsg = pcall(function()
		return inventoryDataStore:SetAsync(player.UserId, myInventory)
	end)

	if not success then
		warn("Player data was lost")
	end
end

--[[================================================================]]
-- events / entry point


remote.grab.OnServerEvent:Connect(grabItem)
remote.use.OnServerEvent:Connect(useItem)
remote.drop.OnServerEvent:Connect(dropItem)

remote.switchedItems.OnServerEvent:Connect(switchedItems)

S_Players.PlayerAdded:Connect(function(player: Player)
	newInventory(player)
	loadData(player)
end)

S_Players.PlayerRemoving:Connect(function(player: Player)
	saveData(player)

	-- clear memory to prevent memory leak
	if playersInventories[player.UserId] then
		playersInventories[player.UserId] = nil
	end
end)
