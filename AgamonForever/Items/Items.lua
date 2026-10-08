local ADDON, TT = ...

local SLOT_OF_EQUIP_LOC = {
	INVTYPE_HEAD = { 1 }, INVTYPE_NECK = { 2 }, INVTYPE_SHOULDER = { 3 }, INVTYPE_BODY = { 4 },
	INVTYPE_CHEST = { 5 }, INVTYPE_ROBE = { 5 }, INVTYPE_WAIST = { 6 }, INVTYPE_LEGS = { 7 },
	INVTYPE_FEET = { 8 }, INVTYPE_WRIST = { 9 }, INVTYPE_HAND = { 10 },
	INVTYPE_FINGER = { 11, 12 }, INVTYPE_TRINKET = { 13, 14 }, INVTYPE_CLOAK = { 15 },
	INVTYPE_WEAPON = { 16, 17 }, INVTYPE_2HWEAPON = { 16 }, INVTYPE_WEAPONMAINHAND = { 16 },
	INVTYPE_WEAPONOFFHAND = { 17 }, INVTYPE_SHIELD = { 17 }, INVTYPE_HOLDABLE = { 17 },
	INVTYPE_RANGED = { 18 }, INVTYPE_RANGEDRIGHT = { 18 }, INVTYPE_THROWN = { 18 },
}
local EQUIP_LOC_SLOTS = {
	INVTYPE_HEAD = "Head", INVTYPE_NECK = "Neck", INVTYPE_SHOULDER = "Shoulder",
	INVTYPE_BODY = "Shirt", INVTYPE_CHEST = "Chest", INVTYPE_ROBE = "Chest",
	INVTYPE_WAIST = "Waist", INVTYPE_LEGS = "Legs", INVTYPE_FEET = "Feet",
	INVTYPE_WRIST = "Wrist", INVTYPE_HAND = "Hands", INVTYPE_FINGER = "Finger",
	INVTYPE_TRINKET = "Trinket", INVTYPE_CLOAK = "Back", INVTYPE_WEAPON = "One-Hand",
	INVTYPE_2HWEAPON = "Two-Hand", INVTYPE_WEAPONMAINHAND = "Main Hand",
	INVTYPE_WEAPONOFFHAND = "Off Hand", INVTYPE_SHIELD = "Off Hand",
	INVTYPE_HOLDABLE = "Off Hand", INVTYPE_RANGED = "Ranged",
	INVTYPE_RANGEDRIGHT = "Ranged", INVTYPE_THROWN = "Ranged",
}
local BIS_MODE_LABELS = { dps = "Max DPS", weighted = "Weighted", total = "Max Total" }
local BIS_TOP_COUNT = 3
local BIS_SLOT_ORDER = {
	"Head", "Neck", "Shoulder", "Back", "Chest", "Wrist", "Hands", "Waist", "Legs",
	"Feet", "Finger", "Trinket", "One-Hand", "Two-Hand", "Main Hand", "Off Hand", "Ranged",
}
local INVENTORY_EQUIPMENT_SLOTS = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19 }

local STAT_KEYS = {
	str = "ITEM_MOD_STRENGTH_SHORT",
	agi = "ITEM_MOD_AGILITY_SHORT",
	stam = "ITEM_MOD_STAMINA_SHORT",
	ap = "ITEM_MOD_ATTACK_POWER_SHORT",
	armor = "RESISTANCE0_NAME",
	int = "ITEM_MOD_INTELLECT_SHORT",
	spirit = "ITEM_MOD_SPIRIT_SHORT",
	mana = "ITEM_MOD_MANA_SHORT",
}

local SET_STATS = {
	["attack power"] = "ap", strength = "str", agility = "agi",
	stamina = "stam", intellect = "int", spirit = "spirit",
}

local EFFECT_STAT_KEYS = { "str", "agi", "stam", "ap", "crit", "armorGain", "health", "int", "spirit" }
local EFFECT_PART_KEYS = { str = "str", agi = "agi", stam = "stam", ap = "ap", crit = "crit",
	armorGain = "armor", health = "health", int = "int", spirit = "spirit" }
local EFFECT_DETAIL_KEYS = {
	abilityDamage = true, armorPerLevel = true, armorPercent = true, autoAttackDamagePercent = true,
	critDamage = true, dodge = true, formStats = true, healthPercent = true, itemArmorPercent = true,
}

local function preciseGearDetail(value)
	local function twoDecimals(sign, number)
		local amount = tonumber(number)
		if sign == "-" then amount = -amount end
		return string.format(sign == "" and "%.2f" or "%+.2f", amount)
	end
	value = value:gsub("([+-]?)(%d+%.?%d*)%%", function(sign, number)
		return twoDecimals(sign, number) .. "%"
	end)
	value = value:gsub("([+-]?)(%d+%.?%d*)%s+([dD][pP][sS])", function(sign, number, unit)
		return twoDecimals(sign, number) .. " " .. unit
	end)
	value = value:gsub("([+-]?)(%d+%.?%d*)%s+([eE][hH][pP])", function(sign, number, unit)
		return twoDecimals(sign, number) .. " " .. unit
	end)
	value = value:gsub("([dD][pP][sS] of )([+-]?)(%d+%.?%d*)", function(prefix, sign, number)
		return prefix .. twoDecimals(sign, number)
	end)
	return value:gsub("([eE][hH][pP] of )([+-]?)(%d+%.?%d*)", function(prefix, sign, number)
		return prefix .. twoDecimals(sign, number)
	end)
end

local ITEM_CLASS_WEAPON, ITEM_CLASS_ARMOR = 2, 4
local WEAPON_SUBCLASS = { axe1h = 0, axe2h = 1, bow = 2, gun = 3, mace1h = 4, mace2h = 5, polearm = 6,
	sword1h = 7, sword2h = 8, staff = 10, fist = 13, dagger = 15, thrown = 16, crossbow = 18, wand = 19 }
local ARMOR_SUBCLASS = { misc = 0, cloth = 1, leather = 2, mail = 3, plate = 4, shield = 6, libram = 7, idol = 8, totem = 9 }
--misc armor is every ring, neck and trinket, so each class carries it; a class left out of this table is simply not filtered
local PROFICIENCY = {
	DRUID = { "mace1h mace2h polearm staff fist dagger", "misc cloth leather idol" },
	WARRIOR = { "axe1h axe2h bow crossbow dagger fist gun mace1h mace2h polearm staff sword1h sword2h thrown", "misc cloth leather mail plate shield" },
	PALADIN = { "axe1h axe2h mace1h mace2h polearm sword1h sword2h", "misc cloth leather mail plate shield libram" },
	HUNTER = { "axe1h axe2h bow crossbow dagger fist gun polearm staff sword1h sword2h thrown", "misc cloth leather mail" },
	ROGUE = { "bow crossbow dagger fist gun mace1h sword1h thrown", "misc cloth leather" },
	SHAMAN = { "axe1h axe2h dagger fist mace1h mace2h staff", "misc cloth leather mail shield totem" },
	PRIEST = { "dagger mace1h staff wand", "misc cloth" },
	MAGE = { "dagger staff sword1h wand", "misc cloth" },
	WARLOCK = { "dagger staff sword1h wand", "misc cloth" },
}
for class, lists in pairs(PROFICIENCY) do
	local weapons, armor = {}, {}
	for name in lists[1]:gmatch("%S+") do weapons[WEAPON_SUBCLASS[name]] = true end
	for name in lists[2]:gmatch("%S+") do armor[ARMOR_SUBCLASS[name]] = true end
	PROFICIENCY[class] = { weapons = weapons, armor = armor }
end
local SHOPPING_ROWS = 10 --what fits in chat without being a wall
local VENDOR_MARGIN = 1.2 --an auction that barely clears the vendor price is not worth the bag slot
local ITEM_STAT_FIELDS = {
	"health", "low", "high", "offLow", "offHi", "percent", "speed", "offSpeed", "crit",
	"ap", "baseArmor", "armor", "level", "str", "agi", "stam", "int", "spi", "defense", "dodge",
}
local ITEM_PRICE_SETTINGS = { "critMultiplier", "healCritMultiplier" }
local SHOPPING_CACHE_VERSION = 3
local UPGRADE_CACHE_VERSION = 3
local BIS_ROWS_CACHE_VERSION = 2
local unpackValues = unpack or table.unpack
local bisRowsCache, shoppingRowsCache = {}, nil
local itemInfoCache, itemInstantCache, itemStatsCache, itemLinesCache, itemPartsCache = {}, {}, {}, {}, {}
local upgradePricingContext, itemUpgradeCache
local requestedItemData = {}
local itemDataRevision = 0
local bisRowsStale = false
local pricingContextKey, itemUpgradeCacheFor, upgradeResultFor

local function rowNeedsItem(rows, itemID, count)
	if not rows then return false end
	local unread = rows.unreadItems
	if type(unread) == "table" then return unread[itemID] == true end
	return count and count > 0 or false
end

local function cacheKey(link)
	if TT.ReadableText(link) then
		local hyperlink = link:match("|H(item:[^|]+)|h")
		link = hyperlink or link
		local itemID, suffix = link:match("^item:(%d+)(.*)$")
		if itemID and (suffix == "" or suffix:match("^(:0*)+$")) then return "item:" .. itemID end
		return link
	end
	local itemID = TT.ReadableNumber(link)
	return itemID and ("item:" .. itemID) or nil
end

function TT.ItemInfo(link)
	local key = cacheKey(link)
	if key and itemInfoCache[key] then return unpackValues(itemInfoCache[key], 1, itemInfoCache[key].n) end
	if not C_Item or not C_Item.GetItemInfo then return end
	local name, itemLink, quality, itemLevel, minLevel, itemType, itemSubType, stackCount,
		equipLoc, icon, sellPrice, classID, subclassID, bindType, expansionID, setID, reagent =
		C_Item.GetItemInfo(link)
	if key and TT.ReadableText(name) then
		itemInfoCache[key] = { name, itemLink, quality, itemLevel, minLevel, itemType, itemSubType,
			stackCount, equipLoc, icon, sellPrice, classID, subclassID, bindType, expansionID, setID, reagent, n = 17 }
	end
	return name, itemLink, quality, itemLevel, minLevel, itemType, itemSubType, stackCount,
		equipLoc, icon, sellPrice, classID, subclassID, bindType, expansionID, setID, reagent
end

function TT.ItemInfoInstant(link)
	local key = cacheKey(link)
	if key and itemInstantCache[key] then return unpackValues(itemInstantCache[key], 1, itemInstantCache[key].n) end
	if not C_Item or not C_Item.GetItemInfoInstant then return end
	local itemID, itemType, itemSubType, equipLoc, icon, classID, subclassID, bindType =
		C_Item.GetItemInfoInstant(link)
	if key and TT.Readable(itemID) then
		itemInstantCache[key] = { itemID, itemType, itemSubType, equipLoc, icon, classID, subclassID, bindType, n = 8 }
	end
	return itemID, itemType, itemSubType, equipLoc, icon, classID, subclassID, bindType
end

local function requestItemData(link)
	if not C_Item or not C_Item.RequestLoadItemDataByID then return end
	local key = cacheKey(link)
	local itemID = key and tonumber(key:match("^item:(%d+)"))
	if not itemID or requestedItemData[itemID] then return end
	requestedItemData[itemID] = "pending"
	C_Item.RequestLoadItemDataByID(itemID)
end

function TT.ItemVendorInfo(link)
	local name, itemLink, quality = TT.ItemInfo(link)
	return name, itemLink, quality, select(11, TT.ItemInfo(link))
end

function TT.ItemIcon(link)
	return select(5, TT.ItemInfoInstant(link))
end

function TT.ItemStats(link)
	local key = cacheKey(link)
	if key and itemStatsCache[key] then return itemStatsCache[key] end
	if not C_Item or not C_Item.GetItemStats then return end
	local stats = C_Item.GetItemStats(link)
	if key and TT.Readable(stats) and type(stats) == "table" then itemStatsCache[key] = stats end
	return stats
end

local function clearItemDataCache()
	itemInfoCache, itemInstantCache, itemStatsCache, itemLinesCache, itemPartsCache = {}, {}, {}, {}, {}
end

function TT.InvalidateItemRows(clearSaved)
	bisRowsCache, shoppingRowsCache = {}, nil
	if clearSaved ~= false and TT.char then TT.char.shoppingRows, TT.char.bisRows = nil, nil end
end

function TT.PrepareBisRows()
	if not bisRowsStale then return end
	bisRowsCache = {}
	bisRowsStale = false
end

function TT.InvalidateItemData()
	clearItemDataCache()
	TT.InvalidateItemRows()
	upgradePricingContext, itemUpgradeCache = nil, nil
	if TT.char then TT.char.itemUpgradeCache = nil end
end

function TT.ToggleItemScanFast()
	TT.db.itemScanFast = not TT.db.itemScanFast
	return TT.db.itemScanFast
end

local WEAPON_SLOTS = {
	INVTYPE_WEAPON = true, INVTYPE_2HWEAPON = true, INVTYPE_WEAPONMAINHAND = true,
	INVTYPE_WEAPONOFFHAND = true, INVTYPE_RANGED = true, INVTYPE_RANGEDRIGHT = true, INVTYPE_THROWN = true,
}

--the client usually prints a weapon's dps outright, but the line can arrive secret, so the range and speed are a way back
local function weaponDps(lines)
	local low, high, speed
	for _, line in ipairs(lines or {}) do
		local dps = line:match("%(([%d%.]+) damage per second%)")
		if dps then return tonumber(dps) end
		local from, to = line:match("(%d+)%s*%-%s*(%d+)%s+[Dd]amage")
		if from then low, high = tonumber(from), tonumber(to) end
		local pace = line:match("[Ss]peed%s+([%d%.]+)")
		if pace then speed = tonumber(pace) end
	end
	if low and speed and speed > 0 then return (low + high) / 2 / speed end
	return nil
end

--every set bonus on a tooltip, with the piece count that earns it
local function setBonuses(lines)
	local equipped, bonuses, blank = nil, {}, {}

	for _, line in ipairs(lines or {}) do
		local lower = line:lower()
		local have = lower:match("%((%d+)/%d+%)")
		if have then equipped = tonumber(have) end

		local needed, body = lower:match("^%((%d+)%)%s*set:%s*(.+)$")
		if not body then body = lower:match("^set:%s*(.+)$") end

		if body then
			local parts, any = {}, false
			for amount, stat in body:gmatch("%+(%d+)%s+([%a%s]-)%s*[%.,]") do
				local key = SET_STATS[stat]
				if key then
					parts[key] = (parts[key] or 0) + tonumber(amount)
					any = true
				end
			end
			if any then
				local bonus = { pieces = tonumber(needed), parts = parts }
				bonuses[#bonuses + 1] = bonus
				if not bonus.pieces then blank[#blank + 1] = bonus end
			end
		end
	end

	--this client prints the bonuses you have already earned without their piece count, so they are the lowest ones
	if #blank > 0 then
		local lowest
		for _, bonus in ipairs(bonuses) do
			if bonus.pieces and (not lowest or bonus.pieces < lowest) then lowest = bonus.pieces end
		end
		local first = lowest and (lowest - #blank) or 2
		for index, bonus in ipairs(blank) do bonus.pieces = first + index - 1 end
	end

	return bonuses, equipped
end

--a set bonus belongs to the whole set, so one piece carries its share: the bonus divided by the pieces it takes to earn
local function setShare(lines)
	local bonuses = setBonuses(lines)
	local parts, from, any = {}, {}, false

	for _, bonus in ipairs(bonuses) do
		if bonus.pieces and bonus.pieces > 0 then
			for key, amount in pairs(bonus.parts) do
				parts[key] = (parts[key] or 0) + amount / bonus.pieces
				from[#from + 1] = string.format("%d %s over %d pieces", amount, key, bonus.pieces)
				any = true
			end
		end
	end

	if not any then return nil end
	return parts, table.concat(from, ", ")
end

--taking a set piece off drops you a piece, and any bonus that needed exactly the count you had stops paying in full
local function setLoss(lines)
	local bonuses, equipped = setBonuses(lines)
	if not equipped then return nil end

	local parts, from, any = {}, {}, false
	for _, bonus in ipairs(bonuses) do
		if bonus.pieces == equipped then
			for key, amount in pairs(bonus.parts) do
				parts[key] = (parts[key] or 0) + amount
				from[#from + 1] = string.format("%d %s", amount, key)
				any = true
			end
		end
	end

	if not any then return nil end
	return parts, table.concat(from, ", "), equipped
end

--vanilla puts crit on gear as plain tooltip text rather than a stat the api reports
local function critFromText(lines)
	for _, line in ipairs(lines or {}) do
		local pct = line:lower():match("critical strike by (%d+%.?%d*)%%") or line:lower():match("critical hit[^%d]-by (%d+%.?%d*)%%")
		if pct then return tonumber(pct) / 100 end
	end
	return 0
end

--a random enchant that has not rolled yet prints its range, and the api answers nothing for it, so the printed line is the stat
local function rolledStats(lines)
	local low, spread
	for _, line in ipairs(lines or {}) do
		local from, to, name = line:match("^%+(%d+)%s*%-%s*(%d+)%s+([%a%s]-)%s*$")
		local field = name and SET_STATS[name:lower()]
		if field then
			low = low or {}
			spread = spread or {}
			low[field] = (low[field] or 0) + tonumber(from)
			spread[field] = (spread[field] or 0) + (tonumber(to) - tonumber(from))
		end
	end
	return low, spread
end

local function tooltipStats(lines)
	local parts = {}
	for _, line in ipairs(lines or {}) do
		local text = line:lower():gsub("^%s*equip:%s*", "")
		local amount, name = text:match("^%s*%+(%d+)%s+([%a%s]-)[%.,]?%s*$")
		local field = name and SET_STATS[name:gsub("%s+$", "")]
		if field then parts[field] = (parts[field] or 0) + tonumber(amount) end
	end
	return parts
end

local function equippedEffects(lines)
	local parts, details = {}, {}
	for _, line in ipairs(lines or {}) do
		local body = line:match("^%s*[Ee]quip:%s*(.+)$")
		if body then
			local effect = TT.ParseEffect({ body })
			if effect then
				for _, key in ipairs(EFFECT_STAT_KEYS) do
					local partKey, amount = EFFECT_PART_KEYS[key], effect[key]
					if amount then parts[partKey] = (parts[partKey] or 0) + amount end
				end
				local stats = TT.Stats and TT.Stats()
				if stats then
					for key, stat in pairs({ strPercent = "str", agiPercent = "agi", stamPercent = "stam", intPercent = "int" }) do
						if effect[key] and stats[stat] then
							local partKey = stat == "int" and "int" or stat
							parts[partKey] = (parts[partKey] or 0) + effect[key] * stats[stat]
						end
					end
					if effect.apPercent and stats.ap then parts.ap = (parts.ap or 0) + effect.apPercent * stats.ap end
					if effect.armorPercent and stats.armor then parts.armor = (parts.armor or 0) + effect.armorPercent * stats.armor end
					if effect.healthPercent and stats.health then parts.health = (parts.health or 0) + effect.healthPercent * stats.health end
				end
				if effect.apPerLevel then parts.ap = (parts.ap or 0) + effect.apPerLevel * TT.PlayerLevel() end
				for key in pairs(EFFECT_DETAIL_KEYS) do
					if effect[key] then
						local result = TT.CalcEffect(nil, effect)
						for _, detail in ipairs(result.lines) do
							local damageDetail = detail[1] == "Damage" or detail[1] == "Damage from"
							if (not damageDetail or effect.abilityDamage or effect.autoAttackDamagePercent)
								and detail[1] ~= "Toughness" and detail[1] ~= "Toughness from" then
								details[#details + 1] = { detail[1], preciseGearDetail(detail[2]), detail[3] }
							end
						end
						break
					end
				end
			end
		end
	end
	return parts, details
end

local function copyTable(source)
	if not source then return nil end
	local copy = {}
	for key, value in pairs(source) do copy[key] = value end
	return copy
end

local function partsContextKey()
	local parts = {
		tostring(TT.char and TT.char.spec or ""),
		tostring(TT.PlayerLevel and TT.PlayerLevel() or ""),
		tostring(TT.CurrentForm and TT.CurrentForm() or ""),
		TT.FormStatsKey and TT.FormStatsKey() or "",
	}
	local stats = TT.Stats and TT.Stats()
	for _, field in ipairs(ITEM_STAT_FIELDS) do
		local value = stats and stats[field]
		parts[#parts + 1] = TT.Readable(value) and tostring(value) or ""
	end
	for _, setting in ipairs(ITEM_PRICE_SETTINGS) do
		parts[#parts + 1] = tostring(TT.db and TT.db[setting] or "")
	end
	return table.concat(parts, "|")
end

local function partsOf(link, lines)
	if not link then return nil end
	local normalizedLink = cacheKey(link)
	local cacheID = normalizedLink and (normalizedLink .. "\001" .. table.concat(lines or {}, "\n")
		.. "\001" .. partsContextKey())
	local cached = cacheID and itemPartsCache[cacheID]
	if cached then
		if cached.parts == false then return nil end
		return copyTable(cached.parts), copyTable(cached.spread), cached.details
	end
	local stats = TT.ItemStats(link)
	local parts = { crit = critFromText(lines) }
	local any = parts.crit > 0
	local visible = tooltipStats(lines)
	for field, key in pairs(STAT_KEYS) do
		local value = stats and stats[key]
		if TT.Readable(value) and value ~= 0 then
			parts[field] = value
			any = true
		elseif visible[field] then
			parts[field] = visible[field]
			any = true
		end
	end
	local effects, details = equippedEffects(lines)
	for field, value in pairs(effects) do
		parts[field] = (parts[field] or 0) + value
		any = true
	end
	--the printed range wins over the api, which reports an unrolled enchant as nothing at all
	local rolled, spread = rolledStats(lines)
	for field, value in pairs(rolled or {}) do
		parts[field] = value
		any = true
	end
	local share, from = setShare(lines)
	if share then
		for key, value in pairs(share) do parts[key] = (parts[key] or 0) + value end
		parts.setFrom = from
		any = true
	end

	if not any then
		if cacheID then itemPartsCache[cacheID] = { parts = false } end
		return nil
	end
	if cacheID then itemPartsCache[cacheID] = { parts = copyTable(parts), spread = copyTable(spread), details = details } end
	return parts, spread, details
end

local function equipLocOf(link)
	if not link then return nil end
	local _, _, _, equipLoc = TT.ItemInfoInstant(link)
	return TT.ReadableText(equipLoc) and equipLoc or nil
end

local function itemIdOf(link)
	if not link then return nil end
	local itemID = TT.ItemInfoInstant(link)
	if TT.Readable(itemID) then return itemID end
	return link:match("item:(%d+)")
end

local function rememberBisItem(link)
	if not TT.char or not TT.ReadableText(link) or not equipLocOf(link) then return end
	local itemID = itemIdOf(link)
	if not itemID then return end
	TT.char.bisItems = TT.char.bisItems or {}
	TT.char.bisItems[itemID] = link
end

--the equipped item's own tooltip, which is where its set membership and bonuses are written
local function itemLines(link)
	local key = cacheKey(link)
	if key and itemLinesCache[key] then return itemLinesCache[key] end
	if not C_TooltipInfo or not C_TooltipInfo.GetHyperlink then return nil end
	local data = TT.Safely(C_TooltipInfo.GetHyperlink, link)
	if not data or not data.lines then return nil end
	if TooltipUtil and TooltipUtil.SurfaceArgs then TooltipUtil.SurfaceArgs(data) end
	local lines = {}
	for _, line in ipairs(data.lines) do
		if TooltipUtil and TooltipUtil.SurfaceArgs then TooltipUtil.SurfaceArgs(line) end
		--half a tooltip prices a set bonus wrong, so a secret left side drops the item; the right side is only ever extra
		if not TT.SplitText(lines, line.leftText) then return nil end
		TT.SplitText(lines, line.rightText)
	end
	if key then itemLinesCache[key] = lines end
	return lines
end

--what taking this piece off actually costs: its own stats, plus any set bonus that stops paying without it
local function removalValue(link, sameSet)
	local lines = itemLines(link)
	local parts = partsOf(link, lines) or {}
	local lostFrom

	if not sameSet then
		local lost, from = setLoss(lines)
		if lost then
			for key, amount in pairs(lost) do parts[key] = (parts[key] or 0) + amount end
			lostFrom = from
		end
	end

	return TT.StatDps(parts), TT.StatEhp(parts), lostFrom, weaponDps(lines)
end

local function equippedValue(link, lines)
	local equipLoc = equipLocOf(link)
	local slots = equipLoc and SLOT_OF_EQUIP_LOC[equipLoc]
	if not slots then return nil end

	--replacing a set piece with another piece of the same set breaks nothing, so the bonus is not charged against it
	local candidate = setBonuses(lines)
	local sameSet = candidate and #candidate > 0

	--a weapon is worth far more than its stats here, so the one you would really replace is the weakest once its dps counts
	local worst, worstTotal
	for _, slot in ipairs(slots) do
		local equipped = GetInventoryItemLink("player", slot)
		if equipped then
			local dps, ehp, lostFrom, weapon = removalValue(equipped, sameSet)
			local total = dps + TT.WeaponDps(weapon or 0)
			if not worst or total < worstTotal then
				worst = { dps = dps, ehp = ehp, link = equipped, lostFrom = lostFrom, weaponDps = weapon }
				worstTotal = total
			end
		end
	end
	return worst
end

--mana on gear, and the intellect that makes more of it, is only worth what the chosen spec can spend it on
--spirit is regen rather than pool, so it only counts for as long as the fight the simulator priced everything else over
local function manaValue(parts)
	local fight = TT.FightLength()
	local regen = TT.ManaFromSpirit(parts.spirit, fight) or 0
	local pool = (parts.mana or 0) + TT.ManaFromIntellect(parts.int)
	local poolDamage, poolWhy
	if pool ~= 0 then
		local spec = TT.Spec()
		if spec and not spec.caster and TT.ManaPoolWorth then
			poolDamage, poolWhy = TT.ManaPoolWorth(pool)
		else
			poolDamage, poolWhy = TT.PriceMana(pool, false)
		end
	end
	local spiritDamage
	if parts.spirit and parts.spirit ~= 0 then
		spiritDamage = TT.SpiritWorth(parts.spirit)
	end
	local damage = (poolDamage or 0) + (spiritDamage or 0)
	if not poolDamage and not spiritDamage then damage = nil end
	return damage, pool, regen, poolWhy, fight
end

local BOUND_WORDS = { "soulbound", "binds when picked up", "quest item" }

local function bound(lines)
	for _, line in ipairs(lines or {}) do
		local lower = line:lower()
		for _, word in ipairs(BOUND_WORDS) do
			if lower:find(word, 1, true) then return true end
		end
	end
	return false
end

--what someone else would pay, against what a vendor pays, headlined by what the whole stack is worth
local function sellValue(link, lines, count)
	if bound(lines) then return nil end
	local itemID = TT.ItemInfoInstant(link)
	local price, seen = TT.AuctionPrice(itemID)
	local vendor = select(11, TT.ItemInfo(link))
	count = count or 1
	local stacked = count > 1
	if not price and not (stacked and vendor and vendor > 0) then return nil end

	--a stack is a decision about the whole stack, so that is the headline, and shift asks the other question instead
	local each = stacked and TT.PerItem and TT.PerItem()
	local out = {}
	local multiple = each and 1 or count
	local total = price and price * multiple or nil
	local vendorTotal = vendor and vendor > 0 and vendor * multiple or nil
	local label = stacked and (each and "Auction (each)" or "Auction") or "Auction"
	if price and vendor and vendor > 0 then
		local over = (price / vendor - 1) * 100
		if price <= vendor * VENDOR_MARGIN then
			out[#out + 1] = { "Vendor trash", string.format("%s at auction against %s from a vendor", TT.Money(total), TT.Money(vendorTotal)), nil, "auction" }
		else
			out[#out + 1] = { label, string.format("%s, %s%%", TT.Money(total), (over >= 0 and "+" or "") .. TT.FormatNumber(over)), nil, "auction" }
		end
	elseif price then
		out[#out + 1] = { label, TT.Money(total), nil, "auction" }
	elseif stacked and vendorTotal then
		out[#out + 1] = { each and "Vendor (each)" or "Vendor", TT.Money(vendorTotal), nil, "auction" }
	end

	--how old the price is decides whether to trust it, which is a question you ask rather than one asked of you
	if price then out[#out + 1] = { "Last seen", TT.PriceAge(seen), true } end
	if stacked then
		--the headline answered one of the two questions, so the detail answers the other one
		local other = each and count or 1
		local parts = {}
		if price then parts[#parts + 1] = TT.Money(price * other) .. " at auction" end
		if vendor and vendor > 0 then parts[#parts + 1] = TT.Money(vendor * other) .. " to a vendor" end
		out[#out + 1] = { each and "Whole stack" or "Each", table.concat(parts, ", "), true }
	elseif price and vendor and vendor > 0 then
		out[#out + 1] = { "Vendor pays", TT.Money(vendor), true }
	end
	return out
end

--what it costs to make one, against what one sells for, because a recipe is only worth knowing when the gap is positive
local function craftValue(link)
	if not TT.CraftCost then return nil end
	local itemID = TT.ItemInfoInstant(link)
	local cost, unpriced, parts, makes = TT.CraftCost(itemID)
	if not cost then return nil end
	local sells = TT.AuctionPrice(itemID)
	local out = {}

	--a reagent nobody has seen at auction is not free, so the total says it is a floor rather than quietly understating
	local label = unpriced > 0 and "Reagents at least" or "Reagents"
	out[#out + 1] = { label, TT.Money(cost), nil, "auction" }
	if sells then
		local profit = sells * makes - cost
		local made = makes > 1 and string.format(" for %d", makes) or ""
		if unpriced > 0 then
			out[#out + 1] = { "Profit at most", string.format("%s%s", TT.Money(profit), made) }
		elseif profit > 0 and cost > 0 then
			out[#out + 1] = { "Profit", string.format("%s%s, %+d%%", TT.Money(profit), made, profit / cost * 100) }
		elseif profit > 0 then
			out[#out + 1] = { "Profit", TT.Money(profit) .. made }
		else
			out[#out + 1] = { "Costs more than it sells for", TT.Money(-profit) .. " down" }
		end
	end

	local detail = {}
	for _, part in ipairs(parts) do
		local name = part.name or ("item " .. part.id)
		local each = part.price and TT.Money(part.price) or "never seen"
		detail[#detail + 1] = string.format("%s%s %s", part.count > 1 and (part.count .. "x ") or "", name, each)
	end
	out[#out + 1] = { "Which is", table.concat(detail, ", "), true }
	if unpriced > 0 then
		out[#out + 1] = { "Not fully priced", string.format("%d of %d reagents have never been seen at auction", unpriced, #parts), true }
	end
	return out
end

local UPGRADE = "|cff40ff40%s|r"
local DOWNGRADE = "|cffff6060%s|r"

--what the swap does to the character, as a percentage, because a flat delta says nothing about whether it matters
local function swing(delta, baseline, unit)
	if not baseline or baseline <= 0 then return string.format("%+.2f %s", delta, unit) end
	local text = string.format("%+.2f%% %s", delta / baseline * 100, unit)
	return string.format(delta < 0 and DOWNGRADE or UPGRADE, text)
end

--an unrolled item is a range, and naming only one end of it would be inventing the roll
local function spanVerdict(low, high, baseline, unit)
	if not baseline or baseline <= 0 then
		if high and high ~= low then return string.format("%+.2f to %+.2f %s", low, high, unit) end
		return string.format("%+.2f %s", low, unit)
	end
	local verdict = string.format("%+.2f%%", low / baseline * 100)
	local working = string.format("%+.2f %s of %.2f", low, unit, baseline)
	if high and high ~= low then
		verdict = verdict .. string.format(" to %+.2f%%", high / baseline * 100)
		working = string.format("%+.2f to %+.2f %s of %.2f", low, high, unit, baseline)
	end
	return verdict, working
end

local function spanSwing(low, high, baseline, unit)
	if high and high ~= low then return swing(low, baseline, unit) .. " to " .. swing(high, baseline, unit) end
	return swing(low, baseline, unit)
end

local function nameOf(link)
	return link and link:match("%[(.-)%]") or nil
end

local function itemName(name, itemLink, link)
	if TT.ReadableText(name) and name ~= "" and not name:match("^item:%d+") then return name end
	if TT.ReadableText(itemLink) then
		local linkedName = nameOf(itemLink)
		if linkedName and linkedName ~= "" and not linkedName:match("^item:%d+") then return linkedName end
	end
	if TT.ReadableText(link) then
		local linkedName = nameOf(link)
		if linkedName and linkedName ~= "" and not linkedName:match("^item:%d+") then return linkedName end
	end
end

local function invalidateItemCacheEntries(cache, prefix)
	for key in pairs(cache) do
		if key == prefix or key:sub(1, #prefix + 1) == prefix .. ":" or key:sub(1, #prefix + 1) == prefix .. "\001" then
			cache[key] = nil
		end
	end
end

local function invalidateItemDataEntry(itemID)
	itemID = TT.ReadableNumber(itemID)
	if not itemID then return end
	local prefix = "item:" .. itemID
	for _, cache in ipairs({ itemInfoCache, itemInstantCache, itemStatsCache, itemLinesCache, itemPartsCache }) do
		invalidateItemCacheEntries(cache, prefix)
	end
	local saved = TT.char and TT.char.itemUpgradeCache
	if saved and type(saved.items) == "table" then invalidateItemCacheEntries(saved.items, prefix) end
end

pricingContextKey = function()
	local parts = { tostring(TT.char and TT.char.spec or "") }
	parts[#parts + 1] = tostring(TT.PlayerLevel and TT.PlayerLevel() or "")
	parts[#parts + 1] = tostring(TT.CurrentForm and TT.CurrentForm() or "")
	local stats = TT.Stats and TT.Stats()
	for _, field in ipairs(ITEM_STAT_FIELDS) do
		local value = stats and stats[field]
		parts[#parts + 1] = TT.Readable(value) and tostring(value) or ""
	end
	for _, setting in ipairs(ITEM_PRICE_SETTINGS) do parts[#parts + 1] = tostring(TT.db and TT.db[setting] or "") end
	parts[#parts + 1] = tostring(TT.db and TT.db.autoTargets or "")
	parts[#parts + 1] = tostring(TT.db and TT.db.targets or "")
	local form = TT.RotationContext and TT.RotationContext() or ""
	parts[#parts + 1] = form
	parts[#parts + 1] = TT.FormStatsKey and TT.FormStatsKey() or ""
	local extras = {}
	for _, spec in ipairs(TT.ExtraSpecs and TT.ExtraSpecs() or {}) do extras[#extras + 1] = spec.key end
	table.sort(extras)
	parts[#parts + 1] = table.concat(extras, ",")
	if GetInventoryItemLink then
		for _, slot in ipairs(INVENTORY_EQUIPMENT_SLOTS) do
			local link = GetInventoryItemLink("player", slot)
			parts[#parts + 1] = TT.ReadableText(link) and link or ""
		end
	end
	return table.concat(parts, "|")
end

itemUpgradeCacheFor = function(context)
	if upgradePricingContext == context and itemUpgradeCache then return itemUpgradeCache end
	local saved = TT.char and TT.char.itemUpgradeCache
	if saved and saved.version == UPGRADE_CACHE_VERSION and saved.context == context and type(saved.items) == "table" then
		itemUpgradeCache = saved.items
	else
		itemUpgradeCache = {}
		if TT.char then
			TT.char.itemUpgradeCache = { version = UPGRADE_CACHE_VERSION, context = context, items = itemUpgradeCache }
		end
	end
	upgradePricingContext = context
	return itemUpgradeCache
end

upgradeResultFor = function(metrics, ranking, dpsWeight, ehpWeight)
	local best
	for _, spec in ipairs(metrics.specs) do
		local share = math.max(spec.dps, spec.ehp)
		local score = share
		if ranking == "weighted" then
			local weightTotal = (dpsWeight or 0) + (ehpWeight or 0)
			score = weightTotal > 0 and ((dpsWeight or 0) * spec.dps + (ehpWeight or 0) * spec.ehp) / weightTotal or 0
		elseif ranking == "total" then
			score = spec.dps * metrics.baselineDps + spec.ehp * metrics.baseEhp
		elseif ranking == "dps" then
			score = spec.dps
		end
		if not best or score > best.score then
			best = {
				score = score, share = share, dps = spec.dps, ehp = spec.ehp,
				dpsGain = spec.dps * metrics.baselineDps, ehpGain = spec.ehp * metrics.baseEhp,
				spec = spec.spec, replaces = spec.replaces,
			}
		end
	end
	return best
end

local function evaluationKey(prices)
	local parts = { pricingContextKey() }
	local saved = {}
	for id, link in pairs(TT.char and TT.char.bisItems or {}) do
		if TT.ReadableText(link) then saved[#saved + 1] = tostring(id) .. "=" .. link end
	end
	table.sort(saved)
	for _, entry in ipairs(saved) do parts[#parts + 1] = entry end
	table.sort(prices, function(left, right) return tostring(left.id) < tostring(right.id) end)
	for _, entry in ipairs(prices) do
		parts[#parts + 1] = table.concat({ tostring(entry.id), tostring(entry.price) }, "=")
	end
	return table.concat(parts, "|")
end

--pricing reads off the chosen spec, so another spec's numbers come from standing in its shoes for the one call
local function withSpec(spec, fn, ...)
	local chosen = TT.Spec()
	TT.char.spec = spec.key
	local a, b, c, d = fn(...)
	TT.char.spec = chosen and chosen.key or nil
	return a, b, c, d
end

local function priceFor(spec, parts)
	local dps, ehp, mana = withSpec(spec, function()
		return (TT.StatDps(parts)), (TT.StatEhp(parts)), manaValue(parts)
	end)
	if not spec.melee then dps = 0 end
	return dps + (mana or 0), ehp
end

--what the swap does to one spec, with both sides priced in that spec's terms rather than the chosen one's
local function swapLine(spec, parts, topRoll, link, lines, weapon, baseline)
	local theirs = withSpec(spec, equippedValue, link, lines)
	local theirDps = theirs and (theirs.dps + TT.WeaponDps(theirs.weaponDps or 0)) or 0
	local theirEhp = theirs and theirs.ehp or 0

	local carried = weapon and TT.WeaponDps(weapon) or 0
	local dps, ehp = priceFor(spec, parts)
	dps = dps + carried
	local highDps, highEhp
	if topRoll then
		highDps, highEhp = priceFor(spec, topRoll)
		highDps = highDps + carried
	end

	local out = {}
	if spec.melee then
		out[#out + 1] = spanSwing(dps - theirDps, highDps and highDps - theirDps, baseline.dps, "dps")
	end
	out[#out + 1] = spanSwing(ehp - theirEhp, highEhp and highEhp - theirEhp, TT.BaseEhp(), "ehp")
	return table.concat(out, "  ")
end

--says exactly what the client handed us for one item, because a line that arrives secret looks the same as one that is absent
--what your class may not equip is not something to go shopping for, whatever its stats say. the red line the client
--draws over such an item is not in the tooltip data an addon can read, so the item's own class and subclass answer instead
local function cannotUse(link)
	if not C_Item or not C_Item.GetItemInfoInstant then return false end
	local _, _, _, _, _, classID, subclassID = TT.ItemInfoInstant(link)
	local _, class = UnitClass("player")
	local allowed = class and PROFICIENCY[class]
	if not allowed or not classID then return false end
	if classID == ITEM_CLASS_WEAPON then return not allowed.weapons[subclassID] end
	if classID == ITEM_CLASS_ARMOR then return not allowed.armor[subclassID] end
	return false
end

function TT.CannotEquip(link)
	return cannotUse(link)
end

--what a candidate would do to you, in whichever of your specs it helps most, since cat gear and bear gear are different questions
local function upgradeFor(link, ranking, dpsWeight, ehpWeight, context)
	local cacheID = cacheKey(link)
	context = context or pricingContextKey()
	local cache = itemUpgradeCacheFor(context)
	local metrics = cacheID and cache[cacheID]
	if metrics then return upgradeResultFor(metrics, ranking, dpsWeight, ehpWeight) end

	local equipLoc = equipLocOf(link)
	if not equipLoc or not SLOT_OF_EQUIP_LOC[equipLoc] then return nil, "not gear" end
	local lines = itemLines(link)
	if not lines then return nil, "unread" end
	local parts = partsOf(link, lines)
	local weapon = WEAPON_SLOTS[equipLoc] and (weaponDps(lines) or 0) or nil
	if not parts and not weapon then return nil end
	parts = parts or {}

	local baseline = TT.PhysicalBaseline()
	local baseEhp = TT.BaseEhp()
	local specs = {}
	local chosen = TT.Spec()
	if chosen then specs[#specs + 1] = chosen end
	for _, other in ipairs(TT.ExtraSpecs()) do specs[#specs + 1] = other end

	local pricedSpecs = {}
	for _, spec in ipairs(specs) do
		local theirs = withSpec(spec, equippedValue, link, lines)
		local theirDps = theirs and (theirs.dps + TT.WeaponDps(theirs.weaponDps or 0)) or 0
		local theirEhp = theirs and theirs.ehp or 0
		local dps, ehp = priceFor(spec, parts)
		if weapon then dps = dps + TT.WeaponDps(weapon) end
		local dpsShare = baseline.dps > 0 and (dps - theirDps) / baseline.dps or 0
		local ehpShare = baseEhp > 0 and (ehp - theirEhp) / baseEhp or 0
		pricedSpecs[#pricedSpecs + 1] = {
			dps = dpsShare, ehp = ehpShare, spec = spec.name, replaces = theirs and theirs.link,
		}
	end
	if #pricedSpecs == 0 then return nil end
	metrics = { baselineDps = baseline.dps, baseEhp = baseEhp, specs = pricedSpecs }
	if cacheID then cache[cacheID] = metrics end
	return upgradeResultFor(metrics, ranking, dpsWeight, ehpWeight)
end

function TT.BisRows(ranking, dpsWeight, ehpWeight, readyOnly, onProgress)
	ranking = BIS_MODE_LABELS[ranking] and ranking or "dps"
	local prices = TT.KnownPrices()
	local pricingContext = pricingContextKey()
	local context = evaluationKey(prices)
	local key = context
	local cached = bisRowsCache[key]
	local level = TT.PlayerLevel()
	local function selectRows(cache)
		local viewKey = table.concat({ ranking, tostring(dpsWeight), tostring(ehpWeight), tostring(readyOnly) }, "|")
		if cache.views[viewKey] then return cache.views[viewKey], cache.skipped end
		local groups = cache.groups
		local wornScores = {}
		for slot, group in pairs(groups) do
			for _, item in ipairs(group) do
				item.upgrade = upgradeResultFor(item.metrics, ranking, dpsWeight, ehpWeight)
				item.score = item.upgrade.score
				if item.equipped and (not wornScores[slot] or item.score > wornScores[slot]) then
					wornScores[slot] = item.score
				end
			end
			table.sort(group, function(left, right)
				if left.score == right.score then return left.name < right.name end
				return left.score > right.score
			end)
		end
		local rows = {}
		for _, slot in ipairs(BIS_SLOT_ORDER) do
			local group = groups[slot]
			if group then
				for _, item in ipairs(group) do
					item.dimmed = not item.equipped and wornScores[slot] and item.score < wornScores[slot] - 0.0005 or false
				end
				local rank = 0
				for _, item in ipairs(group) do
					if not readyOnly or not (level and item.needs and item.needs > level) then
						rank = rank + 1
						if rank <= BIS_TOP_COUNT or item.equipped then
							rows[#rows + 1] = { slot = slot, rank = rank, item = copyTable(item) }
						end
					end
				end
			end
		end
		cache.views[viewKey] = rows
		return rows, cache.skipped
	end
	local function refreshSightings(cache)
		local seenByID = {}
		for _, entry in ipairs(prices) do seenByID[entry.id] = entry.seen end
		for _, group in pairs(cache.groups) do
			for _, item in ipairs(group) do item.seen = seenByID[item.id] end
		end
		for _, rows in pairs(cache.views) do
			for _, row in ipairs(rows) do row.item.seen = seenByID[row.item.id] end
		end
	end
	if cached then
		refreshSightings(cached)
		return selectRows(cached)
	end
	local saved = TT.char and TT.char.bisRows
	if saved and saved.version == BIS_ROWS_CACHE_VERSION and saved.key == key
		and type(saved.groups) == "table" and type(saved.skipped) == "table" then
		local valid = true
		for _, group in pairs(saved.groups) do
			for _, item in ipairs(group) do
				if not item.metrics then valid = false; break end
			end
			if not valid then break end
		end
		if valid then
			cached = { groups = saved.groups, skipped = saved.skipped, views = {} }
			bisRowsCache[key] = cached
			refreshSightings(cached)
			return selectRows(cached)
		end
	end
	local scanRevision = itemDataRevision
	local groups, skipped = {}, { unusable = 0, unread = 0, unreadItems = {} }
	local candidates, byID, wornBySlot = {}, {}, {}
	for _, entry in ipairs(prices) do
		local candidate = { id = entry.id, link = "item:" .. entry.id, seen = entry.seen }
		candidates[#candidates + 1] = candidate
		byID[entry.id] = candidate
	end
	for itemID, link in pairs(TT.char.bisItems or {}) do
		if TT.ReadableText(link) then
			local id = itemIdOf(link) or itemID
			if not byID[id] then
				local candidate = { id = id, link = link }
				candidates[#candidates + 1] = candidate
				byID[id] = candidate
			end
		end
	end
	if GetInventoryItemLink then
		for _, inventorySlot in ipairs(INVENTORY_EQUIPMENT_SLOTS) do
			local link = GetInventoryItemLink("player", inventorySlot)
			if TT.ReadableText(link) then
				local itemID = itemIdOf(link)
				local equipLoc = equipLocOf(link)
				local slot = equipLoc and EQUIP_LOC_SLOTS[equipLoc]
				if itemID and slot then
					local candidate = byID[itemID]
					if not candidate then
						candidate = { id = itemID, link = link }
						byID[itemID] = candidate
						candidates[#candidates + 1] = candidate
					else
						candidate.link = link
					end
					candidate.equipped = true
					local worn = wornBySlot[slot] or {}
					wornBySlot[slot] = worn
					worn[#worn + 1] = candidate
				end
			end
		end
	end
	local usableCandidates, eligible = {}, {}
	for _, entry in ipairs(candidates) do
		if cannotUse(entry.link) then
			skipped.unusable = skipped.unusable + 1
		else
			usableCandidates[#usableCandidates + 1] = entry
			eligible[entry] = true
		end
	end
	candidates = usableCandidates
	for slot, wornItems in pairs(wornBySlot) do
		local usableWorn = {}
		for _, item in ipairs(wornItems) do if eligible[item] then usableWorn[#usableWorn + 1] = item end end
		wornBySlot[slot] = usableWorn
	end
	local wornScores = {}
	local wornCount = 0
	for _, wornItems in pairs(wornBySlot) do wornCount = wornCount + #wornItems end
	local workTotal, workDone = #candidates + wornCount, 0
	local function progress(label)
		if onProgress then onProgress(workDone, workTotal, label) end
	end
	progress("Scoring equipped gear")
	for slot, wornItems in pairs(wornBySlot) do
		for _, item in ipairs(wornItems) do
			local upgrade = upgradeFor(item.link, ranking, dpsWeight, ehpWeight, pricingContext)
			if upgrade and (not wornScores[slot] or upgrade.score > wornScores[slot]) then
				wornScores[slot] = upgrade.score
			end
			workDone = workDone + 1
			progress("Scoring equipped gear")
		end
	end
	for _, entry in ipairs(candidates) do
		local link = entry.link
		local name, itemLink, quality, _, needs = TT.ItemInfo(link)
		name = itemName(name, itemLink, link)
		if not name or name == "" then
			requestItemData(link)
			skipped.unread = skipped.unread + 1
			skipped.unreadItems[entry.id] = true
		else
			local upgrade, why = upgradeFor(link, ranking, dpsWeight, ehpWeight, pricingContext)
			if why == "unread" then
				requestItemData(link)
				skipped.unread = skipped.unread + 1
				skipped.unreadItems[entry.id] = true
			else
				local _, _, _, _, icon = TT.ItemInfoInstant(link)
				local equipLoc = equipLocOf(link)
				local slot = EQUIP_LOC_SLOTS[equipLoc or ""]
				needs = TT.ReadableNumber(needs)
				if upgrade and slot then
					local group = groups[slot] or {}
					groups[slot] = group
					group[#group + 1] = {
						id = entry.id, link = itemLink or link, name = name,
						icon = icon, quality = quality, needs = needs, seen = entry.seen,
						equipped = entry.equipped, upgrade = upgrade, score = upgrade.score,
						metrics = itemUpgradeCacheFor(pricingContext)[cacheKey(link)],
						dimmed = not entry.equipped and wornScores[slot] and upgrade.score < wornScores[slot] - 0.0005 or false,
					}
				end
			end
		end
		workDone = workDone + 1
		progress("Scoring known items")
	end
	for _, slot in ipairs(BIS_SLOT_ORDER) do
		local group = groups[slot]
		if group then
			table.sort(group, function(left, right)
				if left.score == right.score then return left.name < right.name end
				return left.score > right.score
			end)
		end
	end
	local result = { groups = groups, skipped = skipped, views = {} }
	if itemDataRevision == scanRevision then bisRowsCache[key] = result end
	if TT.char and itemDataRevision == scanRevision then
		local savedGroups = {}
		for slot, group in pairs(groups) do
			savedGroups[slot] = {}
			for _, item in ipairs(group) do
				savedGroups[slot][#savedGroups[slot] + 1] = {
					id = item.id, link = item.link, name = item.name, icon = item.icon,
					quality = item.quality, needs = item.needs, seen = item.seen, equipped = item.equipped,
					metrics = item.metrics,
				}
			end
		end
		TT.char.bisRows = { version = BIS_ROWS_CACHE_VERSION, key = key, groups = savedGroups, skipped = skipped }
	end
	return selectRows(result)
end

local function shoppingVerdict(upgrade)
	local parts = {}
	if upgrade.dps > 0.0005 then parts[#parts + 1] = string.format("%+.2f%% dps", upgrade.dps * 100) end
	if upgrade.ehp > 0.0005 then parts[#parts + 1] = string.format("%+.2f%% ehp", upgrade.ehp * 100) end
	return table.concat(parts, ", ")
end

--the ten biggest upgrades the auction house has had, listed cheapest first, because the order you buy them in is by price
--everything the price memory holds that would upgrade you, with what each one is worth, for whatever wants to draw it
function TT.ShoppingRows(onProgress)
	local prices = TT.KnownPrices()
	local pricingContext = pricingContextKey()
	local key = evaluationKey(prices)
	local function refreshSightings(rows)
		local byID = {}
		for _, entry in ipairs(prices) do byID[entry.id] = entry end
		for _, row in ipairs(rows) do
			local entry = byID[row.id]
			if entry then
				row.price, row.seen = entry.price, entry.seen
				row.rank = row.upgrade.share * TT.PriceWeight(entry.seen)
			end
		end
		table.sort(rows, function(left, right) return left.rank > right.rank end)
		return rows
	end
	if shoppingRowsCache and shoppingRowsCache.key == key then
		shoppingRowsCache.rows = refreshSightings(shoppingRowsCache.rows)
		return shoppingRowsCache.rows
	end
	local saved = TT.char and TT.char.shoppingRows
	if saved and saved.version == SHOPPING_CACHE_VERSION and saved.key == key and type(saved.rows) == "table" then
		shoppingRowsCache = { key = key, rows = saved.rows }
		return refreshSightings(saved.rows)
	end
	local scanRevision = itemDataRevision
	local rows = { unusable = 0, unread = 0, unreadItems = {} }
	local candidates = {}
	for _, entry in ipairs(prices) do
		if cannotUse("item:" .. entry.id) then
			rows.unusable = rows.unusable + 1
		else
			candidates[#candidates + 1] = entry
		end
	end
	local count = #candidates
	if onProgress then onProgress(0, count, "Scoring known items") end
	for index, entry in ipairs(candidates) do
		local link = "item:" .. entry.id
		local name, itemLink, quality, _, needs = TT.ItemInfo(link)
		name = itemName(name, itemLink, link)
		if not name or name == "" then
			requestItemData(link)
			rows.unread = rows.unread + 1
			rows.unreadItems[entry.id] = true
		else
			local upgrade, why = upgradeFor(link, nil, nil, nil, pricingContext)
			if why == "unread" then
				requestItemData(link)
				rows.unread = rows.unread + 1
				rows.unreadItems[entry.id] = true
			elseif upgrade and upgrade.share > 0.0005 then
				local _, _, _, _, icon = TT.ItemInfoInstant(link)
				rows[#rows + 1] = {
					id = entry.id, link = itemLink or link, name = name, icon = icon, quality = quality,
					price = entry.price, seen = entry.seen, upgrade = upgrade, needs = TT.ReadableNumber(needs),
					rank = upgrade.share * TT.PriceWeight(entry.seen),
				}
			end
		end
		if onProgress then onProgress(index, count, "Scoring known items") end
	end
	table.sort(rows, function(a, b) return a.rank > b.rank end)
	if itemDataRevision == scanRevision then
		shoppingRowsCache = { key = key, rows = rows }
		if TT.char then TT.char.shoppingRows = { version = SHOPPING_CACHE_VERSION, key = key, rows = rows } end
	end
	return rows
end

--what each row says about itself, shared by the window and the copyable report so they can never disagree
function TT.ShoppingVerdict(upgrade)
	return shoppingVerdict(upgrade)
end

function TT.ShoppingSkipped(rows)
	local notes = {}
	if rows.unusable > 0 then notes[#notes + 1] = string.format("%d your class cannot equip", rows.unusable) end
	if rows.unread > 0 then notes[#notes + 1] = string.format("%d the client has not cached", rows.unread) end
	return #notes > 0 and ("skipped " .. table.concat(notes, ", ")) or nil
end

function TT.ShoppingList()
	if #TT.KnownPrices() == 0 then
		return { "no auction prices remembered yet: browse the auction house once and they are learned as they are drawn" }
	end
	local rows = TT.ShoppingRows()
	local out = {}
	if #rows == 0 then
		out[1] = "nothing remembered would upgrade you"
		out[2] = TT.ShoppingSkipped(rows) and ("  " .. TT.ShoppingSkipped(rows)) or nil
		return out
	end

	local listed = {}
	for index = 1, math.min(#rows, SHOPPING_ROWS) do listed[index] = rows[index] end
	table.sort(listed, function(a, b) return a.price < b.price end)

	local level = TT.PlayerLevel()
	out[#out + 1] = "the biggest upgrades the auction house has had, cheapest first"
	for index, row in ipairs(listed) do
		local late = row.needs and level and row.needs > level and string.format(", needs %d", row.needs) or ""
		out[#out + 1] = string.format("  %d. %-24s %s", index, row.name, TT.Money(row.price))
		out[#out + 1] = string.format("       %s as %s, seen %s%s",
			shoppingVerdict(row.upgrade), row.upgrade.spec, TT.PriceAge(row.seen), late)
	end
	local skipped = TT.ShoppingSkipped(rows)
	out[#out + 1] = skipped and ("  " .. skipped) or nil
	return out
end

function TT.ItemReport(link)
	local out = {}
	if not link then
		local _, hovered = GameTooltip and GameTooltip.GetItem and GameTooltip:GetItem()
		link = hovered or TT.LastItem()
	end
	if not link then return { "no item seen yet: hover one, then run this, or paste a link after the command" } end

	local _, _, _, equipLoc = TT.ItemInfoInstant(link)
	out[#out + 1] = "link " .. tostring(link:match("%[(.-)%]") or link)
	out[#out + 1] = "slot " .. tostring(equipLoc) .. ", weapon " .. tostring(WEAPON_SLOTS[equipLoc or ""] == true)

	local lines = itemLines(link)
	if not lines then
		out[#out + 1] = "its own tooltip came back unreadable, a line was secret"
	else
		out[#out + 1] = "lines its own tooltip gave us:"
		for index, line in ipairs(lines) do out[#out + 1] = string.format("  %d %s", index, line) end
		out[#out + 1] = "weapon dps read as " .. tostring(weaponDps(lines))
	end

	local baseline = TT.PhysicalBaseline()
	out[#out + 1] = string.format("baseline %.2f dps (%s)", baseline.dps, baseline.source)

	--a ranged roll is two sets of stats, so both are printed with what each one priced to
	local parts, spread = partsOf(link, lines)
	if parts then
		local function dump(set)
			local fields = {}
			for key, value in pairs(set) do
				if type(value) == "number" and value ~= 0 then fields[#fields + 1] = string.format("%s=%g", key, value) end
			end
			table.sort(fields)
			return table.concat(fields, " ")
		end
		out[#out + 1] = "stats read: " .. dump(parts)
		if spread then
			local top = {}
			for key, value in pairs(parts) do top[key] = value end
			for key, value in pairs(spread) do top[key] = (top[key] or 0) + value end
			out[#out + 1] = "  top of roll: " .. dump(top)
			out[#out + 1] = string.format("  dps %.2f at the low roll, %.2f at the top", (TT.StatDps(parts)), (TT.StatDps(top)))
			out[#out + 1] = string.format("  ehp %.2f at the low roll, %.2f at the top", (TT.StatEhp(parts)), (TT.StatEhp(top)))
			out[#out + 1] = "  the tooltip prints the low roll first, so these should read left to right the same way"
		end
	end

	local result = TT.CalcItem(link, lines)
	if not result then
		out[#out + 1] = "priced as nothing"
	else
		for _, line in ipairs(result.lines) do
			out[#out + 1] = string.format("  %-18s %s%s", line[1], line[2], line[3] and "   [alt]" or "")
		end
	end
	return out
end

function TT.CalcItem(link, lines, count)
	rememberBisItem(link)
	local parts, spread, effectDetails = partsOf(link, lines)
	local equipLoc = equipLocOf(link)
	--the hovered tooltip can hand us a secret line where the dps was, so the item's own tooltip is asked as well
	local mine = WEAPON_SLOTS[equipLoc or ""] and (weaponDps(lines) or weaponDps(itemLines(link))) or nil
	local worth = sellValue(link, lines, count)
	local crafted = craftValue(link)
	if not parts and not mine then
		if not worth and not crafted then return nil end
		worth = worth or {}
		local only = { kind = "effect", lines = {}, rows = {} }
		for _, line in ipairs(worth) do only.lines[#only.lines + 1] = line end
		for _, line in ipairs(crafted or {}) do only.lines[#only.lines + 1] = line end
		return only
	end
	parts = parts or {}

	local dps, breakdown = TT.StatDps(parts)
	local ehp, ehpFrom = TT.StatEhp(parts)
	local mana, manaPool, manaRegen, manaWhy, manaFight = manaValue(parts)
	local current = equippedValue(link, lines)

	local dpsHigh, ehpHigh, topRoll
	if spread then
		topRoll = {}
		for key, value in pairs(parts) do topRoll[key] = value end
		for key, value in pairs(spread) do topRoll[key] = (topRoll[key] or 0) + value end
		dpsHigh, ehpHigh = TT.StatDps(topRoll), TT.StatEhp(topRoll)
	end

	--what the item is worth to you, not what swapping it would change: its whole weapon dps counts, because losing it loses all of it
	if mine then
		dps = dps + TT.WeaponDps(mine)
		if dpsHigh then dpsHigh = dpsHigh + TT.WeaponDps(mine) end
		local note = string.format("%.2f weapon dps", mine)
		breakdown = breakdown ~= "" and (breakdown .. ", " .. note) or note
	end

	if breakdown == "" and ehpFrom == "" and not mana and manaPool == 0 and manaRegen == 0
		and not worth and not crafted then return nil end

	local spec = TT.Spec()
	local baseline = TT.PhysicalBaseline()
	local result = { kind = "effect", lines = {}, rows = {} }
	for _, line in ipairs(worth or {}) do result.lines[#result.lines + 1] = line end
	for _, line in ipairs(crafted or {}) do result.lines[#result.lines + 1] = line end
	for _, line in ipairs(effectDetails or {}) do result.lines[#result.lines + 1] = line end

	--the share of your damage is the answer; the flat dps and what it came from are the working
	if breakdown ~= "" then
		local verdict, working = spanVerdict(dps, dpsHigh, baseline.dps, "dps")
		result.lines[#result.lines + 1] = { "Damage", verdict }
		result.lines[#result.lines + 1] = { "Damage from", string.format("%s, %s (%s)", breakdown, working or "no baseline yet", baseline.source), true }
	end
	if ehpFrom ~= "" then
		local verdict, working = spanVerdict(ehp, ehpHigh, TT.BaseEhp(), "ehp")
		result.lines[#result.lines + 1] = { "Toughness", verdict }
		result.lines[#result.lines + 1] = { "Toughness from", string.format("%s, %s", ehpFrom, working or "no pool yet"), true }
	end
	if spec then
		result.lines[#result.lines + 1] = { "Priced for", spec.name, true }
	end

	local intellectMana = TT.ManaFromIntellect(parts.int)
	if parts.int and parts.int ~= 0 then
		result.lines[#result.lines + 1] = { "Intellect", string.format("%+d (%+d mana)", parts.int, intellectMana), true }
	end
	if parts.mana and parts.mana ~= 0 then
		result.lines[#result.lines + 1] = { "Mana pool", string.format("%+d", parts.mana), true }
	end
	if manaRegen ~= 0 then
		result.lines[#result.lines + 1] = {
			"Mana regen",
			string.format("%+.0f over %.0fs", manaRegen, manaFight),
			true,
		}
	end
	if mana then
		result.lines[#result.lines + 1] = { "Mana to damage", string.format("%+.0f dmg", mana), true }
	elseif manaPool ~= 0 or manaRegen ~= 0 then
		result.lines[#result.lines + 1] = { "Mana to damage", manaWhy or "not priced for this spec", true }
	end
	local extras = TT.ExtraSpecs()
	if current and current.link and current.link ~= link then
		local label = "vs " .. (nameOf(current.link) or "equipped")
		if #extras > 0 and spec then
			--an item is routinely an upgrade for one spec and a downgrade for another, so each one answers for itself
			result.lines[#result.lines + 1] = { label, "" }
			local specs = { spec }
			for _, other in ipairs(extras) do specs[#specs + 1] = other end
			for _, each in ipairs(specs) do
				result.lines[#result.lines + 1] = { "  " .. each.name, swapLine(each, parts, topRoll, link, lines, mine, baseline) }
			end
		else
			local deltas = {}
			--both sides counted the same way, weapon dps included, or the swap would be a comparison of different things
			local theirs = current.dps + TT.WeaponDps(current.weaponDps or 0)
			if breakdown ~= "" then
				deltas[#deltas + 1] = spanSwing(dps - theirs, dpsHigh and dpsHigh - theirs, baseline.dps, "dps")
			end
			if ehpFrom ~= "" then
				deltas[#deltas + 1] = spanSwing(ehp - (current.ehp or 0), ehpHigh and ehpHigh - (current.ehp or 0), TT.BaseEhp(), "ehp")
			end
			if #deltas > 0 then
				result.lines[#result.lines + 1] = { label, table.concat(deltas, "  ") }
			end
		end
		if current.lostFrom then
			result.lines[#result.lines + 1] = { "Breaks a set bonus", "loses " .. current.lostFrom, true }
		end
	elseif #extras > 0 then
		for _, other in ipairs(extras) do
			local otherDps, otherEhp = priceFor(other, parts)
			result.lines[#result.lines + 1] = { other.name, string.format("%+.2f dps, %+.2f ehp", otherDps, otherEhp), true }
		end
	end

	return result
end

local itemFrame = CreateFrame("Frame")
TT.OnInit(function()
	for _, event in ipairs({
		"ITEM_DATA_LOAD_RESULT", "PLAYER_EQUIPMENT_CHANGED", "ACTIONBAR_SLOT_CHANGED",
		"SPELLS_CHANGED", "LEARNED_SPELL_IN_TAB", "PLAYER_TALENT_UPDATE", "PLAYER_TARGET_CHANGED",
	}) do TT.Listen(itemFrame, event) end
end)
itemFrame:SetScript("OnEvent", function(_, event, itemID, success)
	if event == "ITEM_DATA_LOAD_RESULT" then
		itemID = TT.ReadableNumber(itemID)
		if not itemID or requestedItemData[itemID] ~= "pending" then return end
		success = TT.ReadableBool(success)
		if success == true then requestedItemData[itemID] = nil else requestedItemData[itemID] = "failed" end
		if success == true then
			invalidateItemDataEntry(itemID)
			itemDataRevision = itemDataRevision + 1
			local savedBis = TT.char and TT.char.bisRows
			local savedShopping = TT.char and TT.char.shoppingRows
			local bisNeedsRefresh = rowNeedsItem(savedBis and savedBis.skipped, itemID, savedBis and savedBis.skipped and savedBis.skipped.unread)
			local shoppingNeedsRefresh = rowNeedsItem(savedShopping and savedShopping.rows, itemID,
				savedShopping and savedShopping.rows and savedShopping.rows.unread)
			for _, cached in pairs(bisRowsCache) do
				if rowNeedsItem(cached.skipped, itemID, cached.skipped and cached.skipped.unread) then bisNeedsRefresh = true; break end
			end
			local cachedShopping = shoppingRowsCache and shoppingRowsCache.rows
			if rowNeedsItem(cachedShopping, itemID, cachedShopping and cachedShopping.unread) then shoppingNeedsRefresh = true end
			if bisNeedsRefresh then
				bisRowsStale, bisRowsCache = true, {}
				if TT.char then TT.char.bisRows = nil end
			end
			if shoppingNeedsRefresh then
				shoppingRowsCache = nil
				if TT.char then TT.char.shoppingRows = nil end
			end
		end
		return
	end
	if event ~= "PLAYER_EQUIPMENT_CHANGED" then
		upgradePricingContext, itemUpgradeCache = nil, nil
		if TT.char then TT.char.itemUpgradeCache = nil end
		bisRowsStale = true
		TT.InvalidateItemRows()
		return
	end
	TT.InvalidateItemRows(false)
end)
