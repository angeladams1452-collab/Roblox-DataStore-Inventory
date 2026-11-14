-- Written by CANINUHINUBUH (xeno_Oblivion) | Discord: thasmydawg / angel4o2392

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local InventoryStore = DataStoreService:GetDataStore("PlayerInventory_v1")

-- Config
local MAX_SLOTS = 24
local AUTO_SAVE_TIME = 120
local SAVE_RETRIES = 3

-- Remotes setup (keeps everything self-contained)
local RemotesFolder = Instance.new("Folder")
RemotesFolder.Name = "InventoryRemotes"
RemotesFolder.Parent = ReplicatedStorage

local UpdateEvent = Instance.new("RemoteEvent")
UpdateEvent.Name = "InventoryUpdated"
UpdateEvent.Parent = RemotesFolder

local ActionFunc = Instance.new("RemoteFunction")
ActionFunc.Name = "InventoryAction"
ActionFunc.Parent = RemotesFolder

-- Basic item definitions so the script can validate items on the server
local ItemRegistry = {
	["WoodenSword"] = { MaxStack = 1, Equippable = true },
	["HealthPotion"] = { MaxStack = 10, Equippable = false },
	["IronOre"] = { MaxStack = 50, Equippable = false },
	["GoldCoin"] = { MaxStack = 999, Equippable = false },
}

-- Active player data cache
local SessionData = {}
local SavingLocks = {}

local function getDefaultData()
	return {
		Items = {}, -- Format: { [slotIndex] = { Id = "ItemName", Amount = 1 } }
		EquippedSlot = nil,
	}
end

local function loadData(player)
	local key = "Player_" .. player.UserId
	local success, result

	for attempt = 1, SAVE_RETRIES do
		success, result = pcall(function()
			return InventoryStore:GetAsync(key)
		end)

		if success then
			break
		end
		task.wait(1)
	end

	if not success then
		warn("Failed to load inventory for " .. player.Name .. ": " .. tostring(result))
		player:Kick("Data failed to load. Please rejoin to protect your items.")
		return
	end

	local data = result or getDefaultData()
	if not data.Items then
		data.Items = {}
	end

	SessionData[player.UserId] = data
	UpdateEvent:FireClient(player, data)
end

local function saveData(player)
	local userId = player.UserId
	local data = SessionData[userId]

	if not data or SavingLocks[userId] then
		return
	end

	SavingLocks[userId] = true
	local key = "Player_" .. userId

	for attempt = 1, SAVE_RETRIES do
		local success, err = pcall(function()
			InventoryStore:UpdateAsync(key, function(oldData)
				return data
			end)
		end)

		if success then
			break
		else
			warn("Save attempt " .. attempt .. " failed for " .. player.Name .. ": " .. tostring(err))
			task.wait(1.5)
		end
	end

	SavingLocks[userId] = nil
end

-- Core Inventory Functions
local Inventory = {}

function Inventory.AddItem(player, itemId, amount)
	local data = SessionData[player.UserId]
	local itemInfo = ItemRegistry[itemId]

	if not data or not itemInfo or amount <= 0 then
		return false
	end

	local remaining = amount

	-- First pass: fill existing stacks
	for slot = 1, MAX_SLOTS do
		local entry = data.Items[slot]
		if entry and entry.Id == itemId and entry.Amount < itemInfo.MaxStack then
			local space = itemInfo.MaxStack - entry.Amount
			local toAdd = math.min(space, remaining)
			entry.Amount += toAdd
			remaining -= toAdd

			if remaining <= 0 then
				break
			end
		end
	end

	-- Second pass: put leftovers in empty slots
	if remaining > 0 then
		for slot = 1, MAX_SLOTS do
			if not data.Items[slot] then
				local toAdd = math.min(itemInfo.MaxStack, remaining)
				data.Items[slot] = {
					Id = itemId,
					Amount = toAdd,
				}
				remaining -= toAdd

				if remaining <= 0 then
					break
				end
			end
		end
	end

	UpdateEvent:FireClient(player, data)
	return remaining == 0
end

function Inventory.RemoveItem(player, slot, amount)
	local data = SessionData[player.UserId]
	if not data or not data.Items[slot] or amount <= 0 then
		return false
	end

	local entry = data.Items[slot]
	if entry.Amount < amount then
		return false
	end

	entry.Amount -= amount
	if entry.Amount <= 0 then
		data.Items[slot] = nil
		if data.EquippedSlot == slot then
			data.EquippedSlot = nil
		end
	end

	UpdateEvent:FireClient(player, data)
	return true
end

function Inventory.SwapSlots(player, slotA, slotB)
	local data = SessionData[player.UserId]
	if not data then
		return false
	end

	if slotA < 1 or slotA > MAX_SLOTS or slotB < 1 or slotB > MAX_SLOTS or slotA == slotB then
		return false
	end

	local itemA = data.Items[slotA]
	local itemB = data.Items[slotB]

	-- Stack together if they are the same item
	if itemA and itemB and itemA.Id == itemB.Id then
		local maxStack = ItemRegistry[itemA.Id].MaxStack
		local space = maxStack - itemB.Amount

		if space > 0 then
			local transfer = math.min(space, itemA.Amount)
			itemB.Amount += transfer
			itemA.Amount -= transfer

			if itemA.Amount <= 0 then
				data.Items[slotA] = nil
			end

			UpdateEvent:FireClient(player, data)
			return true
		end
	end

	-- Otherwise just swap positions
	data.Items[slotA] = itemB
	data.Items[slotB] = itemA

	-- Keep equipped slot synced if an equipped item moved
	if data.EquippedSlot == slotA then
		data.EquippedSlot = slotB
	elseif data.EquippedSlot == slotB then
		data.EquippedSlot = slotA
	end

	UpdateEvent:FireClient(player, data)
	return true
end

function Inventory.ToggleEquip(player, slot)
	local data = SessionData[player.UserId]
	if not data or not data.Items[slot] then
		return false
	end

	local itemInfo = ItemRegistry[data.Items[slot].Id]
	if not itemInfo or not itemInfo.Equippable then
		return false
	end

	if data.EquippedSlot == slot then
		data.EquippedSlot = nil
	else
		data.EquippedSlot = slot
	end

	UpdateEvent:FireClient(player, data)
	return true
end

-- Client request handler
ActionFunc.OnServerInvoke = function(player, action, ...)
	if not SessionData[player.UserId] then
		return false
	end

	local args = { ... }

	if action == "GetInventory" then
		return SessionData[player.UserId]
	elseif action == "Swap" and typeof(args[1]) == "number" and typeof(args[2]) == "number" then
		return Inventory.SwapSlots(player, math.floor(args[1]), math.floor(args[2]))
	elseif action == "Drop" and typeof(args[1]) == "number" and typeof(args[2]) == "number" then
		return Inventory.RemoveItem(player, math.floor(args[1]), math.floor(args[2]))
	elseif action == "Equip" and typeof(args[1]) == "number" then
		return Inventory.ToggleEquip(player, math.floor(args[1]))
	end

	return false
end

-- Player connections
Players.PlayerAdded:Connect(function(player)
	loadData(player)

	-- Starter items for new players with empty inventories
	local data = SessionData[player.UserId]
	if data and next(data.Items) == nil then
		Inventory.AddItem(player, "WoodenSword", 1)
		Inventory.AddItem(player, "HealthPotion", 3)
	end
end)

Players.PlayerRemoving:Connect(function(player)
	saveData(player)
	SessionData[player.UserId] = nil
end)

-- Auto-save loop
task.spawn(function()
	while true do
		task.wait(AUTO_SAVE_TIME)
		for _, player in ipairs(Players:GetPlayers()) do
			task.spawn(saveData, player)
		end
	end
end)

-- Save everyone on server shutdown
game:BindToClose(function()
	if RunService:IsStudio() then
		task.wait(2)
		return
	end

	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(saveData, player)
	end
	task.wait(3)
end)
