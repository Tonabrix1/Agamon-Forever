local ADDON, TT = ...

local EVENTS = { "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED" }
local CRAFT_ROWS_VERSION = 1
local craftRowsCache, craftRowsCacheKey

local function store()
	if not TT.craftDB then
		TT.craftDB = AgamonForeverCraftDB or {}
		AgamonForeverCraftDB = TT.craftDB
	end
	return TT.craftDB
end

local function itemIdFrom(link)
	if not TT.ReadableText(link) then return nil end
	return tonumber(link:match("item:(%d+)"))
end

--the client offers three generations of this api at once, so each shape is tried and the returns are picked by type
local function schematicReagents(recipeID)
	if not C_TradeSkillUI or not C_TradeSkillUI.GetRecipeSchematic then return nil end
	local schematic = TT.Safely(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
	if type(schematic) ~= "table" or type(schematic.reagentSlotSchematics) ~= "table" then return nil end
	local reagents = {}
	for _, slot in ipairs(schematic.reagentSlotSchematics) do
		local first = type(slot.reagents) == "table" and slot.reagents[1]
		local id = type(first) == "table" and first.itemID
		if type(id) == "number" then reagents[#reagents + 1] = { id = id, count = slot.quantityRequired or 1 } end
	end
	if #reagents == 0 then return nil end
	return reagents, type(schematic.outputItemID) == "number" and schematic.outputItemID or nil, schematic.quantityMin
end

local function listedReagents(recipeID)
	if not C_TradeSkillUI or not C_TradeSkillUI.GetRecipeNumReagents then return nil end
	local count = TT.Safely(C_TradeSkillUI.GetRecipeNumReagents, recipeID)
	if type(count) ~= "number" or count <= 0 then return nil end
	local reagents = {}
	for index = 1, count do
		local link = TT.Safely(C_TradeSkillUI.GetRecipeReagentItemLink, recipeID, index)
		local _, _, needed = TT.Safely(C_TradeSkillUI.GetRecipeReagentInfo, recipeID, index)
		local id = itemIdFrom(link)
		if id then reagents[#reagents + 1] = { id = id, count = type(needed) == "number" and needed or 1 } end
	end
	if #reagents == 0 then return nil end
	return reagents
end

local function classicReagents(index)
	if not GetTradeSkillNumReagents then return nil end
	local count = TT.Safely(GetTradeSkillNumReagents, index)
	if type(count) ~= "number" or count <= 0 then return nil end
	local reagents = {}
	for slot = 1, count do
		local link = TT.Safely(GetTradeSkillReagentItemLink, index, slot)
		local _, _, needed = TT.Safely(GetTradeSkillReagentInfo, index, slot)
		local id = itemIdFrom(link)
		if id then reagents[#reagents + 1] = { id = id, count = type(needed) == "number" and needed or 1 } end
	end
	if #reagents == 0 then return nil end
	return reagents
end

local function remember(itemID, reagents, makes, name)
	if not itemID or not reagents or #reagents == 0 then return false end
	local known = store()
	known[itemID] = { reagents = reagents, makes = makes and makes > 1 and makes or nil, name = name }
	return true
end

--a profession window is the only place the client will list a recipe, so what it lists is written down while it is open
function TT.LearnRecipes()
	local learned = 0
	if C_TradeSkillUI and C_TradeSkillUI.GetAllRecipeIDs then
		for _, recipeID in ipairs(TT.Safely(C_TradeSkillUI.GetAllRecipeIDs) or {}) do
			local info = C_TradeSkillUI.GetRecipeInfo and TT.Safely(C_TradeSkillUI.GetRecipeInfo, recipeID)
			--an unlearned recipe is one you cannot make, so it is not something to price
			if type(info) ~= "table" or info.learned ~= false then
				local reagents, output, makes = schematicReagents(recipeID)
				reagents = reagents or listedReagents(recipeID)
				output = output or itemIdFrom(TT.Safely(C_TradeSkillUI.GetRecipeItemLink, recipeID))
				local name = type(info) == "table" and TT.ReadableText(info.name) and info.name or nil
				if remember(output, reagents, makes or (type(info) == "table" and info.quantityMin), name) then learned = learned + 1 end
			end
		end
	end
	if learned == 0 and GetNumTradeSkills then
		for index = 1, (TT.Safely(GetNumTradeSkills) or 0) do
			local output = itemIdFrom(TT.Safely(GetTradeSkillItemLink, index))
			local name = TT.Safely(GetTradeSkillInfo, index)
			if remember(output, classicReagents(index), nil, TT.ReadableText(name) and name or nil) then learned = learned + 1 end
		end
	end
	return learned
end

function TT.KnownRecipe(itemID)
	local known = store()
	return known and itemID and known[itemID] or nil
end

function TT.KnownRecipes()
	local out = {}
	for itemID, recipe in pairs(store() or {}) do out[#out + 1] = { id = itemID, recipe = recipe } end
	return out
end

--what the reagents would cost at auction, and how much of that figure is missing, because a price nobody has seen is not zero
function TT.CraftCost(itemID)
	local recipe = TT.KnownRecipe(itemID)
	if not recipe then return nil end
	local cost, unpriced, parts = 0, 0, {}
	for _, reagent in ipairs(recipe.reagents) do
		local price = TT.AuctionPrice(reagent.id)
		local name = C_Item and C_Item.GetItemInfo and (C_Item.GetItemInfo("item:" .. reagent.id))
		parts[#parts + 1] = { id = reagent.id, count = reagent.count, price = price, name = name }
		if price then cost = cost + price * reagent.count else unpriced = unpriced + 1 end
	end
	return cost, unpriced, parts, recipe.makes or 1
end

--what making one and selling it would leave you, which is only a real number when every reagent has a price
function TT.CraftProfit(itemID)
	local cost, unpriced, parts, makes = TT.CraftCost(itemID)
	if not cost then return nil end
	local sells = TT.AuctionPrice(itemID)
	if not sells then return nil, cost, unpriced, parts, makes end
	return sells * makes - cost, cost, unpriced, parts, makes, sells
end

--everything you know how to make that the price memory can put a number on, for whatever wants to rank it
local function rowsKey(knownRecipes)
	local keys = {}
	for _, known in ipairs(knownRecipes) do
		local recipe = known.recipe
		local parts = { tostring(known.id), tostring(recipe.makes or 1), tostring(TT.AuctionPrice(known.id) or "") }
		for _, reagent in ipairs(recipe.reagents) do
			parts[#parts + 1] = table.concat({
				tostring(reagent.id), tostring(reagent.count), tostring(TT.AuctionPrice(reagent.id) or ""),
			}, ":")
		end
		keys[#keys + 1] = table.concat(parts, "=")
	end
	table.sort(keys)
	return table.concat(keys, "|")
end

function TT.CraftRows(onProgress)
	local knownRecipes = TT.KnownRecipes()
	local key = rowsKey(knownRecipes)
	if craftRowsCache and craftRowsCacheKey == key then return craftRowsCache end
	local saved = TT.char and TT.char.craftRows
	if saved and saved.version == CRAFT_ROWS_VERSION and saved.key == key and type(saved.rows) == "table" then
		craftRowsCache, craftRowsCacheKey = saved.rows, key
		return craftRowsCache
	end
	local rows = { unpriced = 0 }
	if onProgress then onProgress(0, #knownRecipes, "Pricing recipes") end
	for index, known in ipairs(knownRecipes) do
		local link = "item:" .. known.id
		local cost, unpriced, parts, makes = TT.CraftCost(known.id)
		local sells = TT.AuctionPrice(known.id)
		if cost and sells then
			local name, itemLink, quality = C_Item.GetItemInfo(link)
			local _, _, _, _, icon = C_Item.GetItemInfoInstant(link)
			if unpriced > 0 then rows.unpriced = rows.unpriced + 1 end
			rows[#rows + 1] = {
				id = known.id, link = itemLink or link, name = name or known.recipe.name or link,
				icon = icon, quality = quality, makes = makes,
				profit = sells * makes - cost, cost = cost, sells = sells * makes,
				partial = unpriced > 0, parts = parts,
			}
		end
		if onProgress then onProgress(index, #knownRecipes, "Pricing recipes") end
	end
	table.sort(rows, function(a, b) return a.profit > b.profit end)
	craftRowsCache, craftRowsCacheKey = rows, key
	if TT.char then TT.char.craftRows = { version = CRAFT_ROWS_VERSION, key = key, rows = rows } end
	return rows
end

local frame = CreateFrame("Frame")
TT.OnInit(function()
	for _, event in ipairs(EVENTS) do TT.Listen(frame, event) end
end)
frame:SetScript("OnEvent", function() TT.LearnRecipes() end)
