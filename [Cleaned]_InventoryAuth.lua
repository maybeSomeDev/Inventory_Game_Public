local canUseDataStore = script:GetAttribute("UseDataStore")
local S_ReplicatedStorage = game:GetService("ReplicatedStorage")
local S_DataStore = canUseDataStore and game:GetService("DataStoreService") or nil
local S_Http = game:GetService("HttpService")
local S_Players = game:GetService("Players")
local inventoryDataStore = canUseDataStore and S_DataStore:GetDataStore("inventory") or nil
local remote = require(game.ReplicatedStorage.RemoteEvents)
local listofItems = require(S_ReplicatedStorage.ListOfItems)
local stored = require(script.Parent.PlayersInventories)
local playersInventories = stored.inventorieslocal MAX_INVENTORY_SLOTS = 40
local MAX_HOTBAR_SLOTS = 10
local MAX_GRAB_DISTANCE = 20
local PROPERTIES_TO_SAVE = {
	["id"] = true,
	["index"] = true,
}
local PROPERTIES_TO_Load = {
	["name"] = true,
	["usable"] = true,
}
type inventory = { listofItems.item }local isValidPlayer = {
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
local isValidItem = {
	validPart = function(itemPart: Part): boolean
		if not itemPart or not itemPart.Parent then
			return false
		end
		return true
	end,
	correctID = function(itemPart: Part): number
		local itemID = itemPart:GetAttribute("id")
		if not listofItems[itemID] then
			return false
		end
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
function newInventory(player: Player)
	if not playersInventories[player.UserId] then
		playersInventories[player.UserId] = {}
	end
	player:SetAttribute("maxInventorySlots", MAX_INVENTORY_SLOTS)
	player:SetAttribute("maxHotbarSlots", MAX_HOTBAR_SLOTS)
end
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
function getItemOriginalCopy(itemID: number)
	return listofItems[itemID]
end
function findEmptySlot(myInventory: inventory, oneSlot: boolean, limitTo: number?): number | { number }
	local combinedCapacity = limitTo or (MAX_HOTBAR_SLOTS + MAX_INVENTORY_SLOTS)
	local fullSlots = {}
	local emptySlots = {}
	for _, item in myInventory do
		fullSlots[item.index] = true
	end	
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
	else 
		newItem.CFrame = newCFrame
		mainPart = newItem
	end
	task.delay(2, function()
		newItem:AddTag("item")
		mainPart:SetAttribute("id", item.id)
		mainPart:AddTag("item")
	end)
end
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
function removeItemFromInventory(inventory: inventory, index: number)
	for tableIndex, item in inventory do
		if item.index == index then
			table.remove(inventory, tableIndex)
		end
	end
end
function grabItem(player: Player, itemPart: Part)
	if not itemPart:HasTag("item") then return end
	if itemPart:GetAttribute("taken") then return end
	if not fullyValidatePlayer(player) or not fullyValidateItem(itemPart, player) then return end
	local itemID = isValidItem.correctID(itemPart) 
	itemPart:SetAttribute("taken", true)
	itemPart:SetAttribute("owner", player.UserId)
	giveItem(player, itemID)
	local parentModel = itemPart:FindFirstAncestorOfClass("Model")
	if parentModel and parentModel:HasTag("item") then
		parentModel:Destroy()
		return
	end
	itemPart:Destroy()
end
function useItem(player: Player, itemIndex: number)
	if not fullyValidatePlayer(player) then return end
	local myInventory = getInventory(player)
	local item = findItemByIndex(myInventory, itemIndex)
	if not item then return end
	item = getItemOriginalCopy(item.id)
	item.Use(player)
end
function dropItem(player: Player, itemIndex: number)
	if not fullyValidatePlayer(player) then return end
	local myInventory = getInventory(player)
	local item = findItemByIndex(myInventory, itemIndex)
	if not item then return end
	local originialItem = getItemOriginalCopy(item.id)
	removeItemFromInventory(myInventory, itemIndex)
	remote.updateInventory:FireClient(player, myInventory)
	local playerPrimPart = player.Character.PrimaryPart
	local itemSpawnPos = playerPrimPart.Position + (playerPrimPart.CFrame.LookVector * 4) + Vector3.new(0, 2, 0)
	spawnItemFromID(originialItem, itemSpawnPos)
end
function switchedItems(player: Player, newInventory: inventory)
	local myInventory = getInventory(player)
	local sameItemsCount = false
	local sameItems = false
	if #myInventory == #newInventory then
		sameItemsCount = true
	end
	if not sameItemsCount then
		remote.updateInventory:FireClient(player, myInventory)
		return
	end
	for index, item in newInventory do
		if not (myInventory[index].id == item.id) then
			return
		end
	end
	sameItems = true
	setPlayerInventoryTo(player, newInventory)
end
function loadData(player: Player)
	newInventory(player)
	if not canUseDataStore then return end
	local success, errorMsg = pcall(function()
		return inventoryDataStore:GetAsync(player.UserId)
	end)
	if success and errorMsg then
		local newInventory = errorMsg
		for itemIndex, item in newInventory do
			local itemOriginalData = getItemOriginalCopy(item.id)
			if not itemOriginalData then
				warn("deleted item with invalid id: "..item.id)
				newInventory[itemIndex] = nil
				continue
			end
			for propertyName, _ in PROPERTIES_TO_Load do
				item[propertyName] = itemOriginalData[propertyName] 
			end
		end
		playersInventories[player.UserId] = newInventory
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
			if PROPERTIES_TO_SAVE[propertyName] then
				continue
			end
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
remote.grab.OnServerEvent:Connect(grabItem)
remote.use.OnServerEvent:Connect(useItem) 
remote.drop.OnServerEvent:Connect(dropItem) 
remote.switchedItems.OnServerEvent:Connect(switchedItems)
S_Players.PlayerAdded:Connect(function(player: Player)
	loadData(player)
end)
S_Players.PlayerRemoving:Connect(function(player: Player)
	saveData(player)
	if playersInventories[player.UserId] then
		playersInventories[player.UserId] = nil
	end
end)