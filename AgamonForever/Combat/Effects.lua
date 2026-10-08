local ADDON, TT = ...

local ARMOR_CONSTANT = 400
local ARMOR_PER_LEVEL = 85
local ARMOR_DR_CAP = 0.75
local AP_PER_DPS = 14
local HEALTH_PER_STAMINA = 10
local ARMOR_PER_AGILITY = 2
--the client reports 113 Agility as +10.1% dodge at level 30
local DRUID_AGI_PER_DODGE_AT_30 = 11.2
local DRUID_AGI_PER_DODGE_AT_60 = 20
local SAMPLE_ARMOR = { 2000, 3500, 5000 }
local DEFAULT_ARMOR = 3500
local SAMPLE_SWINGS = { 30, 60, 90 }

local AP_FROM_STAT = {
	DRUID = { str = 2, agi = 0 },
	WARRIOR = { str = 2, agi = 0 },
	PALADIN = { str = 2, agi = 0 },
	SHAMAN = { str = 2, agi = 0 },
	ROGUE = { str = 1, agi = 1 },
	HUNTER = { str = 1, agi = 1 },
}

local AGI_PER_CRIT = {
	DRUID = 20, WARRIOR = 20, PALADIN = 20, SHAMAN = 20,
	ROGUE = 29, HUNTER = 53, MAGE = 59.5, PRIEST = 59.5, WARLOCK = 60.6,
}

local REDUCE_WORDS = { "reduc", "decreas", "lower", "sunder", "remov" }
local PERCENT_STATS = { strength = "strPercent", agility = "agiPercent", stamina = "stamPercent" }

function TT.AttackPowerDps(attackPower)
	return attackPower / AP_PER_DPS
end

local function isReduction(text)
	for _, word in ipairs(REDUCE_WORDS) do
		if text:find(word, 1, true) then return true end
	end
	return false
end

--"increases your strength by 4" and "strength increased by 4" are the same buff worded two ways, and neither is a percentage
local function flatStat(text, word)
	local amount, trailing = text:match(word .. "[^%.]-by (%d+)(.?)")
	if not amount or trailing == "%" then return nil end
	return tonumber(amount)
end

local function firstNumber(text, patterns)
	for _, pat in ipairs(patterns) do
		local value = text:match(pat)
		if value then return tonumber(value) end
	end
	return nil
end

function TT.ParseEffect(lines)
	local effect = {}
	for _, raw in ipairs(lines) do
		local lower = (raw or ""):lower()

		--a share of armor is handled below, and your own armor is not the target's, so neither may read as stripping them
		local armor, trailingArmor
		if lower:find("armor", 1, true) then
			for _, pattern in ipairs({ "armor of the target by (%d+)(.?)", "armor by (%d+)(.?)", "armor[^%.]-by (%d+)(.?)" }) do
				armor, trailingArmor = lower:match(pattern)
				if armor then break end
			end
			if trailingArmor == "%" then armor = nil end
		end
		if armor then
			local theirs = lower:find("of the target", 1, true) or lower:find("target's", 1, true) or lower:find("enem", 1, true)
			if not theirs then
				effect.armorGain = isReduction(lower) and -tonumber(armor) or tonumber(armor)
			elseif isReduction(lower) then
				effect.armorReduce = tonumber(armor)
			else
				effect.armorGain = tonumber(armor)
			end
		end
		local armorPerLevel = lower:match("(%d+) additional base armor per level")
		if armorPerLevel then
			effect.armorPerLevel = tonumber(armorPerLevel)
			local extra, threshold = lower:match("another ([%d%.]+) base armor for each point of defense skill beyond (%d+) times your level")
			if not threshold and lower:find("beyond five times your level", 1, true) then extra, threshold = lower:match("another ([%d%.]+) base armor for each point of defense skill"), "5" end
			if extra then effect.armorPerDefense, effect.defenseLevelFactor = tonumber(extra), tonumber(threshold) end
			local forms = lower:match("while in (.-), you gain")
			if forms then
				effect.armorForms = {}
				for _, form in ipairs({ "dire bear", "bear", "cat", "moonkin" }) do
					if forms:find(form .. " form", 1, true) then effect.armorForms[form] = true end
				end
			end
		end

		--the forms a passive names are a comma list, so the gap up to "by" may cross commas, but never another figure
		local ofLevel = lower:find("attack power", 1, true) and lower:match("attack power[%a%s,]-by (%d+)%% of your level")
		if ofLevel then effect.apPerLevel = tonumber(ofLevel) / 100 end

		local ofAp = lower:find("attack power", 1, true) and lower:match("attack power[%a%s,]-by (%d+)%%")
		if ofAp and not ofLevel then effect.apPercent = tonumber(ofAp) / 100 end

		local ap, trailing
		if not ofLevel and not ofAp then
			for _, pat in ipairs({ "attack power by (%d+)(.?)", "attack power of[^,%.]-by (%d+)(.?)", "attack power[%a%s,]-by (%d+)(.?)","attack power[^,%.]-by (%d+)(.?)" }) do
				ap, trailing = lower:match(pat)
				if ap then break end
			end
			--a number followed by a percent sign is a share of something, never a flat amount
			if trailing == "%" then ap = nil end
			ap = tonumber(ap)
		end
		if ap then
			local signed = isReduction(lower) and -ap or ap
			--an enemy's attack power is their damage, not yours
			if lower:find("enem", 1, true) or (lower:find("target", 1, true) and not lower:find("friendly", 1, true)) then
				effect.enemyAp = signed
			else
				effect.ap = signed
			end
		end

		--a share of a stat is resolved against the stat you actually have, so nothing needs a per spell rule
		local allPercent = firstNumber(lower, { "all stats by (%d+)%%", "all attributes by (%d+)%%", "stats by (%d+)%%", "attributes by (%d+)%%" })
		if allPercent then
			local share = (isReduction(lower) and -allPercent or allPercent) / 100
			effect.strPercent, effect.agiPercent, effect.stamPercent = share, share, share
		end
		for stat, key in pairs(PERCENT_STATS) do
			local share = not allPercent and lower:match(stat .. " by (%d+)%%")
			if share then effect[key] = (isReduction(lower) and -tonumber(share) or tonumber(share)) / 100 end
		end
		local intellectPercent = lower:match("intellect by (%d+)%%")
		if intellectPercent then effect.intPercent = tonumber(intellectPercent) / 100 end
		local movementForm, formMovement = lower:match("movement speed while in ([%a]+) form[^%.]-by (%d+)%%")
		if movementForm then
			effect.formMoveSpeed = effect.formMoveSpeed or {}
			effect.formMoveSpeed[movementForm] = isReduction(lower) and -tonumber(formMovement) or tonumber(formMovement)
		end
		local formText = lower:gsub(" and while in ", ". while in ")
		for clause in formText:gmatch("while in [^%.]+") do
			local form = clause:match("while in ([%a]+) form")
			if form then
				local movement = clause:match("movement speed[^%.]-by (%d+)%%")
				if movement then
					effect.formMoveSpeed = effect.formMoveSpeed or {}
					effect.formMoveSpeed[form] = tonumber(movement)
				end
				for stat, key in pairs(PERCENT_STATS) do
					local share = clause:match(stat .. " is increased by (%d+)%%") or clause:match(stat .. " by (%d+)%%")
					if share then
						effect.formStats = effect.formStats or {}
						effect.formStats[form] = effect.formStats[form] or {}
						effect.formStats[form][key] = tonumber(share) / 100
					end
				end
			end
		end
		local movement = lower:match("movement speed[^%.]-by (%d+)%%")
		if movement and not effect.formMoveSpeed then effect.moveSpeed = isReduction(lower) and -tonumber(movement) or tonumber(movement) end
		local dodge = firstNumber(lower, { "chance to dodge[^%.]-by (%d+)%%", "dodge[^%.]-by (%d+)%%" })
		if dodge then effect.dodge = isReduction(lower) and -dodge or dodge end
		local armorPercent = lower:find("armor", 1, true) and lower:match("armor by (%d+)%%")
		if armorPercent then effect.armorPercent = (isReduction(lower) and -tonumber(armorPercent) or tonumber(armorPercent)) / 100 end
		local itemArmorPercent = lower:match("armor contribution from items by (%d+)%%")
		if itemArmorPercent then effect.itemArmorPercent = tonumber(itemArmorPercent) / 100 end

		local health, trailingHealth = lower:match("health[^%.]-by (%d+)(.?)")
		if health then
			if trailingHealth == "%" then effect.healthPercent = tonumber(health) / 100
			else effect.health = tonumber(health) end
		end

		local autoAttackDamage = lower:match("auto%-?attack damage[^%.]-by (%d+)%%")
		if autoAttackDamage then effect.autoAttackDamagePercent = tonumber(autoAttackDamage) / 100 end

		if lower:find("shapeshift into bear form", 1, true) then effect.form = "bear"
		elseif lower:find("shapeshift into cat form", 1, true) then effect.form = "cat" end

		local stats = not allPercent and firstNumber(lower, { "all stats by (%d+)", "all attributes by (%d+)" })
		if stats then effect.str, effect.agi, effect.stam = stats, stats, stats end
		local stam = flatStat(lower, "stamina")
		if stam then effect.stam = isReduction(lower) and -stam or stam end
		local str = flatStat(lower, "strength")
		if str then effect.str = isReduction(lower) and -str or str end
		local agi = flatStat(lower, "agility")
		if agi then effect.agi = isReduction(lower) and -agi or agi end
		local intellect = flatStat(lower, "intellect")
		if intellect then effect.int = isReduction(lower) and -intellect or intellect end
		local spirit = flatStat(lower, "spirit")
		if spirit then effect.spirit = isReduction(lower) and -spirit or spirit end

		local duration = firstNumber(lower, { "for up to (%d+) sec", "up to (%d+) sec", "for (%d+) sec", "lasts (%d+) sec" })
		local minutes = firstNumber(lower, { "for (%d+) min", "lasts (%d+) min" })
		if minutes then duration = minutes * 60 end
		if duration then effect.duration = math.max(effect.duration or 0, duration) end

		--a chance at an extra point or extra rage on a crit is worth exactly what the rotation pays for those
		local comboChance = lower:match("(%d+)%% chance to [%a%s]-an? a?d?ditional combo point")
			or lower:match("(%d+)%% chance to [%a%s]-an extra combo point")
		if comboChance then effect.comboChance = tonumber(comboChance) / 100 end

		local rageChance, rageAmount = lower:match("(%d+)%% chance to gain an additional (%d+) rage")
		if rageChance then
			effect.rageChance, effect.rageOnCrit = tonumber(rageChance) / 100, tonumber(rageAmount)
		end

		--the size of a crit, not how often one lands: reading one as the other sells a tenth of your crits as a tenth of your damage
		local critDamage = lower:match("critical strike damage[^%.]-by ([%d%.]+)%%")
			or lower:match("critical damage[^%.]-by ([%d%.]+)%%")
			or lower:match("critical strike[^%.]-damage bonus[^%.]-by ([%d%.]+)%%")
		if critDamage then
			effect.critDamage = tonumber(critDamage) / 100
			effect.critDamageAbilities = lower:find("abilit", 1, true) ~= nil
		end

		--an aura worded for your party is not worth crit to you: Leader of the Pack moves nobody's own character sheet
		local party = lower:find("party member", 1, true) or lower:find("raid member", 1, true)
			or lower:find("group member", 1, true)
		local partyCrit = party and firstNumber(lower, {
			"critical strike chance[^%.]-by ([%d%.]+)%%",
			"chance to critically hit[^%.]-by ([%d%.]+)%%",
		})
		if partyCrit then effect.partyCrit = partyCrit end

		--a crit passive is worded around the forms it applies in, so the forms are skipped and the number is not
		local crit = not critDamage and not partyCrit and firstNumber(lower, {
			"critical strike chance[^%.]-by ([%d%.]+)%%",
			"chance to critically hit[^%.]-by ([%d%.]+)%%",
			"critical strike[^%.]-by ([%d%.]+)%%",
		})
		if crit then effect.crit = (isReduction(lower) and -crit or crit) / 100 end

		--a modifier that names its abilities is worth whatever share of the fight those abilities are
		local named, amount = lower:match("damage caused by your ([%a%s,]-) abilit[%a]- by (%d+)%%")
		if not named then named, amount = lower:match("damage done by your ([%a%s,]-) abilit[%a]- by (%d+)%%") end
		if named then
			local names = {}
			for part in named:gsub("%sand%s", ", "):gmatch("[^,]+") do
				local word = part:gsub("^%s*(.-)%s*$", "%1")
				if word ~= "" then names[#names + 1] = word end
			end
			if #names > 0 then effect.abilityDamage = { pct = tonumber(amount) / 100, names = names } end
		end

		local thorns = firstNumber(lower, { "(%d+)%s*[%a]*%s*damage to attackers", "damage to attackers[^%d]*(%d+)" })
		if thorns then effect.thorns = thorns end

		--resources granted outright, and resources granted by shapeshifting, are priced differently
		local shiftEnergy = lower:find("shapeshift", 1, true) and firstNumber(lower, { "(%d+) energy" })
		local shiftRage = lower:find("shapeshift", 1, true) and firstNumber(lower, { "(%d+) rage" })
		if shiftEnergy then effect.shiftEnergy = shiftEnergy end
		if shiftRage then effect.shiftRage = shiftRage end

		--"20 Energy" on its own is what the spell charges you, not what it hands back, and reading it as a grant
		--is how Cower came to be worth damage for lowering your threat
		local costOnly = lower:match("^%s*%d+%s+%a+%s*$") ~= nil
		if not shiftEnergy and not shiftRage and not costOnly then
			local energy = firstNumber(lower, { "restores (%d+) energy", "gain (%d+) energy", "grants (%d+) energy", "(%d+) energy" })
			local rage = firstNumber(lower, { "restores (%d+) rage", "generates (%d+) rage", "(%d+) rage" })
			local mana = firstNumber(lower, { "restores (%d+) mana", "(%d+) mana" })
			if energy and lower:find("energy", 1, true) and not lower:find("energy cost", 1, true) then effect.energy = energy end
			--a chance at rage on a crit is not a flat grant, and counting both would pay for it twice
			if rage and not effect.rageChance and lower:find("rage", 1, true) and not lower:find("rage cost", 1, true) then effect.rage = rage end
			if mana and lower:find("restore", 1, true) then effect.mana = mana end
		end

		--a talent that names the ability it discounts is worth what that ability is cast, not what the bar holds
		for kind, named, amount in lower:gmatch("(%a+) cost of your ([%a%s]-) abilit[%a]- by (%d+)") do
			if kind == "energy" or kind == "rage" or kind == "mana" then
				effect.costCuts = effect.costCuts or {}
				effect.costCuts[#effect.costCuts + 1] = { kind = kind, name = named:gsub("^%s*(.-)%s*$", "%1"), amount = tonumber(amount) }
			end
		end
		for _, suffix in ipairs({ "spell", "ability" }) do
			for named, amount in lower:gmatch("cooldown of your ([%a%s]-) " .. suffix .. " by (%d+%.?%d*) sec") do
				effect.cooldownCuts = effect.cooldownCuts or {}
				effect.cooldownCuts[#effect.cooldownCuts + 1] = {
					name = named:gsub("^%s*(.-)%s*$", "%1"), amount = tonumber(amount),
					perRank = lower:find("per rank", 1, true) ~= nil or lower:find("for each rank", 1, true) ~= nil,
				}
			end
		end
		local names, sharedCost = lower:match("reduces? the cost of your (.-) abilities by (%d+) rage or energy")
		if names then
			names = names:gsub("%s+and%s+", ", ")
			effect.costCuts = effect.costCuts or {}
			for name in names:gmatch("[^,]+") do
				effect.costCuts[#effect.costCuts + 1] = {
					kind = "any", name = name:gsub("^%s*(.-)%s*$", "%1"), amount = tonumber(sharedCost),
				}
			end
		end

		local namedMana = false
		for _, cut in ipairs(effect.costCuts or {}) do
			if cut.kind == "mana" then namedMana = true end
		end
		local flatCost = not namedMana and firstNumber(lower, { "costs? (%d+) less mana", "mana cost[^%.]-by (%d+)", "(%d+) less mana" })
		if flatCost then
			effect.manaSaved = flatCost
			effect.manaSavedOnShift = lower:find("shapeshift", 1, true) ~= nil or lower:find("form", 1, true) ~= nil
		end
		local pctCost = lower:match("mana cost[^%.]-by (%d+)%%")
		if pctCost then effect.manaSavedPercent = tonumber(pctCost) / 100 end
	end
	if not next(effect) then return nil end
	return effect
end

local function reduction(armor, level)
	if armor <= 0 then return 0 end
	return math.min(ARMOR_DR_CAP, armor / (armor + ARMOR_CONSTANT + ARMOR_PER_LEVEL * level))
end

--armor is worth a percentage of whatever physical damage you already do, so it is priced against the target's armor
local function physicalGain(armorDelta, targetArmor, level)
	local before = 1 - reduction(targetArmor, level)
	local after = 1 - reduction(math.max(0, targetArmor - armorDelta), level)
	if before <= 0 then return 0 end
	return after / before - 1
end

--a druid turns agility into attack power in cat form, so the spec being priced decides it, not the form you happen to be in
local function statAp(str, agi)
	local _, class = UnitClass("player")
	local coefficients = AP_FROM_STAT[class]
	if not coefficients then return nil end
	local agiAp = coefficients.agi
	local spec = TT.Spec()
	if class == "DRUID" and spec and spec.form == "cat" then agiAp = 1 end
	return (str or 0) * coefficients.str + (agi or 0) * agiAp
end

local function critFromAgi(agi)
	local _, class = UnitClass("player")
	local per = AGI_PER_CRIT[class]
	if not per or not agi then return 0 end
	return agi / per / 100
end

local function dodgeFromAgi(agi, level)
	local _, class = UnitClass("player")
	if class ~= "DRUID" or not agi then return 0 end
	local perPercent = DRUID_AGI_PER_DODGE_AT_30
		+ (DRUID_AGI_PER_DODGE_AT_60 - DRUID_AGI_PER_DODGE_AT_30) * (level - 30) / 30
	return agi / perPercent
end

local function damageMod()
	local stats = TT.Stats()
	return stats and stats.percent or 1
end

--what each armour debuff takes off, learned the first time we parse one, so the enemy tooltip can account for it later
function TT.LearnArmorDebuff(spellID, amount)
	if not spellID or not amount or amount <= 0 or not TT.char then return end
	TT.char.armorDebuffs = TT.char.armorDebuffs or {}
	TT.char.armorDebuffs[spellID] = amount
end

function TT.KnownArmorDebuff(spellID)
	local known = TT.char and TT.char.armorDebuffs
	return known and known[spellID] or nil
end

--shared with the rotation model so a debuff is priced the same whether you hover it or simulate it
function TT.ArmorGain(armorReduce)
	local level = TT.PlayerLevel()
	return physicalGain(armorReduce, TT.db.targetArmor or DEFAULT_ARMOR, level)
end

--one place that turns stats into dps, shared by talents, buffs and gear
function TT.StatDps(parts)
	local physical = TT.PhysicalBaseline()
	local level = TT.PlayerLevel()
	local ap = (parts.ap or 0) + (statAp(parts.str, parts.agi) or 0)
	if parts.apPerLevel then ap = ap + parts.apPerLevel * level end
	local stats = TT.Stats()
	if parts.apPercent then ap = ap + parts.apPercent * (stats and stats.ap or 0) end
	local crit = (parts.crit or 0) + critFromAgi(parts.agi)

	local dps = ap / AP_PER_DPS * damageMod() + physical.dps * crit * (TT.db.critMultiplier - 1)
	local breakdown = {}
	if ap ~= 0 then breakdown[#breakdown + 1] = string.format("%+.0f AP", ap) end
	if crit ~= 0 then breakdown[#breakdown + 1] = string.format("%+.1f%% crit", crit * 100) end
	return dps, table.concat(breakdown, ", "), physical.source
end

--armor and stamina are worth whatever they add to the health pool you already have, after your own mitigation
function TT.StatEhp(parts)
	local stats = TT.Stats()
	--a cache saved by an older version may not carry every field yet
	local health = stats and stats.health or 0
	if health <= 0 and stats then health = (stats.stam or 0) * HEALTH_PER_STAMINA end
	local armor = stats and stats.armor or 0
	local dodge = stats and stats.dodge or 0
	local level = stats and stats.level or TT.PlayerLevel()
	if health <= 0 then return 0, "" end

	local armorGain = (parts.armor or 0) + (parts.agi or 0) * ARMOR_PER_AGILITY
	local healthGain = (parts.health or 0) + (parts.stam or 0) * HEALTH_PER_STAMINA
	local dodgeGain = (parts.dodge or 0) + dodgeFromAgi(parts.agi, level)
	if armorGain == 0 and healthGain == 0 and dodgeGain == 0 then return 0, "" end

	local before = health / ((1 - reduction(armor, level)) * (1 - dodge / 100))
	local after = (health + healthGain)
		/ ((1 - reduction(armor + armorGain, level)) * (1 - (dodge + dodgeGain) / 100))

	local breakdown = {}
	if healthGain ~= 0 then breakdown[#breakdown + 1] = string.format("%+.0f hp", healthGain) end
	if armorGain ~= 0 then breakdown[#breakdown + 1] = string.format("%+.0f armor", armorGain) end
	if dodgeGain ~= 0 then breakdown[#breakdown + 1] = string.format("%+.2f%% dodge", dodgeGain) end
	return after - before, table.concat(breakdown, ", "), before
end

--the effective health you already have, which is what a gear change is a percentage of
function TT.BaseEhp()
	local stats = TT.Stats()
	local health = stats and stats.health or 0
	if health <= 0 and stats then health = (stats.stam or 0) * HEALTH_PER_STAMINA end
	if health <= 0 then return 0 end
	local armor = stats and stats.armor or 0
	local dodge = stats and stats.dodge or 0
	local level = stats and stats.level or TT.PlayerLevel()
	return health / ((1 - reduction(armor, level)) * (1 - dodge / 100))
end

--a flat number means nothing without what it is a share of, so every gain says both
function TT.Share(delta, baseline)
	if not baseline or baseline <= 0 then return "" end
	return string.format(" (%+.1f%%)", delta / baseline * 100)
end

--the share is the answer and the flat number is the working, so the verdict is the percentage when there is one
function TT.Verdict(delta, baseline, unit)
	if not baseline or baseline <= 0 then
		return string.format("%+.2f %s", delta, unit), nil
	end
	return string.format("%+.2f%%", delta / baseline * 100), string.format("%+.2f %s of %.2f", delta, unit, baseline)
end

--a share of a stat only means something against the stat you have, so it becomes a flat gain here and is priced like any other
local function resolve(effect)
	local stats = TT.Stats()
	if not stats then return effect, nil end

	local parts, from = {}, {}
	for key, value in pairs(effect) do parts[key] = value end

	local function share(key, fraction, have, label)
		if not fraction or not have then return end
		local gained = fraction * have
		parts[key] = (parts[key] or 0) + gained
		from[#from + 1] = string.format("%+.0f %s", gained, label)
	end

	share("str", effect.strPercent, stats.str, "str")
	share("agi", effect.agiPercent, stats.agi, "agi")
	share("stam", effect.stamPercent, stats.stam, "stam")
	share("armor", effect.armorPercent, stats.armor, "armor")
	share("int", effect.intPercent, stats.int, "int")
	local spec = TT.Spec()
	local formStats = effect.formStats and spec and effect.formStats[spec.form]
	for key, fraction in pairs(formStats or {}) do
		local stat = key == "strPercent" and "str" or key == "agiPercent" and "agi" or "stam"
		share(stat, fraction, stats[stat], stat)
	end

	return parts, #from > 0 and table.concat(from, ", ") or nil
end

function TT.CalcEffect(spellID, effect)
	local parts, resolved = resolve(effect)
	local stats = TT.Stats()
	local level = stats and stats.level or TT.PlayerLevel()
	local physical = TT.PhysicalBaseline()
	local result = { kind = "effect", lines = {}, rows = {} }

	if effect.armorReduce then
		TT.LearnArmorDebuff(spellID, effect.armorReduce)
		local gain = physicalGain(effect.armorReduce, DEFAULT_ARMOR, level)
		result.lines[#result.lines + 1] = { "Physical damage", string.format("+%.1f%%", gain * 100) }
		if physical.dps > 0 then
			local added = physical.dps * gain
			local verdict, working = TT.Verdict(added, physical.dps, "dps")
			result.lines[#result.lines + 1] = { "Damage", verdict }
			result.lines[#result.lines + 1] = { "Which is", string.format("%s (%s)", working or "unpriced", physical.source), true }
		end
		local entries = {}
		for _, armor in ipairs(SAMPLE_ARMOR) do
			local at = physicalGain(effect.armorReduce, armor, level)
			entries[#entries + 1] = {
				key = string.format("%.1fk", armor / 1000),
				text = string.format("+%.1f%%", at * 100),
				current = armor == DEFAULT_ARMOR,
			}
		end
		result.rows[#result.rows + 1] = { label = "Physical by target armor", entries = entries }

		--the armour it strips is not the question; whether the global it costs buys more than the global it replaces is
		local delta, withIt, withoutIt, fight, why = TT.DebuffWorth(spellID)
		if delta and withoutIt and withoutIt > 0 then
			local share = delta / withoutIt * 100
			if delta > 0 then
				result.lines[#result.lines + 1] = { "Worth casting", string.format("%+.1f%% over a %.0fs fight", share, fight) }
			else
				local at, never = TT.DebuffBreakEven(spellID)
				result.lines[#result.lines + 1] = { "Not worth casting", string.format("%.1f%% on a %.0fs fight", share, fight) }
				result.lines[#result.lines + 1] = { "Worth it from", at and string.format("about %ds", at) or (never or "never") }
			end
			result.lines[#result.lines + 1] = { "With and without it", string.format("%.2f against %.2f dps", withIt, withoutIt), true }
		elseif why then
			result.lines[#result.lines + 1] = { "Not priced", why }
		end
	end

	if effect.armorGain then
		local stats = TT.Stats()
		local own = stats and stats.armor or 0
		if own > 0 then
			local before = reduction(own, level)
			local after = reduction(math.max(0, own + effect.armorGain), level)
			--armour you gain is damage you stop taking, so the sign is flipped and armour you lose reads as the cost it is
			result.lines[#result.lines + 1] = { "Physical taken", string.format("%+.1f%%", -(after - before) / (1 - before) * 100) }
		else
			result.lines[#result.lines + 1] = { "Armor", string.format("%+d", effect.armorGain) }
		end
	end

	local formArmor, formHealth
	local casterStats = TT.FormStats and TT.FormStats("caster")
	local bearStats = effect.form == "bear" and TT.FormStats and TT.FormStats("bear")
	if casterStats and bearStats and casterStats.health and bearStats.health then
		formArmor = (bearStats.armor or 0) - (casterStats.armor or 0)
		formHealth = bearStats.health - casterStats.health
	end
	if effect.form == "bear" or effect.health or effect.healthPercent or effect.itemArmorPercent then
		local reference = casterStats or stats or {}
		local baseline = reference
		local armor = effect.armorGain or 0
		local health = effect.health or 0
		if formArmor and formHealth then
			armor, health = formArmor, formHealth
		elseif not casterStats and effect.form == "bear" and TT.FormProfileKey and TT.FormProfileKey() == "bear" and stats then
			baseline = {}
			for key, value in pairs(reference) do baseline[key] = value end
			local itemArmor = math.max(0, (reference.armor or 0) - (reference.baseArmor or 0))
				/ (1 + (effect.itemArmorPercent or 0))
			baseline.armor = (reference.baseArmor or 0) + itemArmor
			baseline.health = math.max(0, ((reference.health or 0) - (effect.health or 0))
				/ (1 + (effect.healthPercent or 0)))
			armor = (reference.armor or 0) - baseline.armor
			health = (reference.health or 0) - baseline.health
		else
			armor = armor + (effect.armorPercent or 0) * (reference.armor or 0)
			local itemArmor = math.max(0, (reference.armor or 0) - (reference.baseArmor or 0))
			armor = armor + itemArmor * (effect.itemArmorPercent or 0)
			health = health + (effect.healthPercent or 0) * (reference.health or 0)
		end
		local toughness
		if baseline and TT.WithStats then toughness = TT.WithStats(baseline, TT.StatEhp, { armor = armor, health = health })
		else toughness = TT.StatEhp({ armor = armor, health = health }) end
		if toughness and toughness ~= 0 then
			result.lines[#result.lines + 1] = { "Toughness", TT.Verdict(toughness, TT.WithStats and baseline and TT.WithStats(baseline, TT.BaseEhp) or TT.BaseEhp(), "ehp") }
			if armor ~= 0 then
				local armorLine
				local baselineArmor = baseline.armor or 0
				local function taken()
					local before = reduction(baselineArmor, level)
					local after = reduction(math.max(0, baselineArmor + armor), level)
					return -(after - before) / (1 - before) * 100
				end
				armorLine = reference and TT.WithStats and TT.WithStats(reference, taken) or taken()
				result.lines[#result.lines + 1] = { "Physical taken", string.format("%+.1f%%", armorLine) }
			end
		end
	end
	if effect.armorPerLevel then
		local stats = TT.Stats()
		local level = stats and stats.level or TT.PlayerLevel()
		local armor = effect.armorPerLevel * level
		local extraDefense = 0
		if stats and stats.defense and effect.armorPerDefense then
			extraDefense = math.max(0, stats.defense - effect.defenseLevelFactor * level) * effect.armorPerDefense
			armor = armor + extraDefense
		end
		local forms = {}
		for form in pairs(effect.armorForms or {}) do
			forms[#forms + 1] = form:gsub("^%l", string.upper):gsub(" (%l)", function(letter) return " " .. letter:upper() end)
		end
		table.sort(forms)
		result.lines[#result.lines + 1] = { "Base armor per point", string.format("+%.1f", armor) }
		if #forms > 0 then result.lines[#result.lines + 1] = { "Applies in", table.concat(forms, ", "), true } end
		local ehp = TT.StatEhp({ armor = armor })
		if ehp and ehp > 0 then result.lines[#result.lines + 1] = { "Effective health before form multiplier", string.format("+%.0f", ehp), true } end
		if effect.armorPerDefense and (not stats or not stats.defense) then
			result.lines[#result.lines + 1] = { "Defense scaling", string.format("+%.2f per skill above %dx level", effect.armorPerDefense, effect.defenseLevelFactor), true }
		elseif effect.armorPerDefense and extraDefense > 0 then
			result.lines[#result.lines + 1] = { "From defense", string.format("+%.1f base armor", extraDefense), true }
		end
		result.lines[#result.lines + 1] = { "Form multipliers", "not included in the base armor figure", true }
	end

	if effect.dodge then
		local baseEhp = TT.BaseEhp()
		local dodgeFrac = effect.dodge / 100
		if baseEhp > 0 then
			local stats = TT.Stats()
			local baseDodge = stats and stats.dodge or 0
			local gain = baseEhp * dodgeFrac / (1 - (baseDodge / 100) - dodgeFrac)
			local verdict, working = TT.Verdict(gain, baseEhp, "ehp")
			--named apart from the armour and stamina toughness line, because avoidance is not mitigation
			result.lines[#result.lines + 1] = { "Toughness from dodge", verdict }
			result.lines[#result.lines + 1] = { "Which is", string.format("%+.0f%% dodge, %s", effect.dodge, working or ""), true }
		else
			--no baseline to price it against, so the bonus is stated in the form it is known in
			result.lines[#result.lines + 1] = { "Dodge chance", string.format("%+.0f%%", effect.dodge) }
		end
	end

	--a bigger crit is only worth what your crits are: the share of your damage that is crits, lifted by that much
	if effect.critDamage then
		local crit = (stats and stats.crit or 0) / 100
		local bonus = TT.db.critMultiplier - 1
		local fromCrits = crit * bonus / (1 + crit * bonus)
		local share = effect.critDamageAbilities and TT.AbilityDamageShare and TT.AbilityDamageShare() or 1
		local gain = fromCrits * effect.critDamage * (share or 1)
		if crit <= 0 then
			result.lines[#result.lines + 1] = { "Crit damage", string.format("%+.0f%%", effect.critDamage * 100) }
			result.lines[#result.lines + 1] = { "Not priced", "no crit chance read off your character yet" }
		elseif physical.dps > 0 then
			local verdict, working = TT.Verdict(physical.dps * gain, physical.dps, "dps")
			result.lines[#result.lines + 1] = { "Damage", verdict }
			result.lines[#result.lines + 1] = { "Which is", string.format("%+.0f%% bigger crits at %.1f%% crit, %s (%s)",
				effect.critDamage * 100, crit * 100,
				effect.critDamageAbilities and string.format("on the %.0f%% of your damage that is abilities", (share or 1) * 100)
					or "on all of your damage", working or physical.source), true }
		else
			result.lines[#result.lines + 1] = { "Crit damage", string.format("%+.0f%%", effect.critDamage * 100) }
		end
	end

	--stated in the form it is known in, because the bonus is real even though none of it lands on you
	if effect.partyCrit then
		result.lines[#result.lines + 1] = { "Party crit", string.format("+%.0f%%", effect.partyCrit) }
		result.lines[#result.lines + 1] = { "None of it is yours", "the aura reads on their character sheet, not on yours", true }
	end

	if effect.abilityDamage then
		local share, found, missing = TT.AbilityShare(effect.abilityDamage.names)
		if share and share > 0 then
			local gain = physical.dps * share * effect.abilityDamage.pct
			result.lines[#result.lines + 1] = { "Damage", (TT.Verdict(gain, physical.dps, "dps")) }
			result.lines[#result.lines + 1] = { "Those abilities are", string.format("%.0f%% of your damage (%s)", share * 100, table.concat(found, ", ")), true }
			if #missing > 0 then
				result.lines[#result.lines + 1] = { "Not on your bars", table.concat(missing, ", "), true }
			end
		else
			--an aoe ability is absent from a single target rotation by design, so it gets its own figure rather than a shrug
			local aoe = TT.AoeValue(effect.abilityDamage.names)
			if aoe then
				local gain = aoe.dps * effect.abilityDamage.pct
				result.lines[#result.lines + 1] = { string.format("Damage vs %d targets", aoe.targets), string.format("%+.0f dps", gain) }
				result.lines[#result.lines + 1] = { aoe.name .. " spam", string.format("%.0f dps at %d targets, %.0f per cast", aoe.dps, aoe.targets, aoe.perCast), true }
				result.lines[#result.lines + 1] = { "Not in your single target dps", "this is a separate pack figure", true }
			else
				result.lines[#result.lines + 1] = { "Not priced", "none of those abilities are in your rotation" }
			end
		end
	end

	if resolved then
		result.lines[#result.lines + 1] = { "Which is", resolved, true }
	end

	local gain, breakdown, physicalSource = TT.StatDps(parts)
	if effect.autoAttackDamagePercent then
		local weaponStats = casterStats or stats
		local melee = weaponStats and TT.WithStats and TT.WithStats(weaponStats, TT.Melee) or TT.Melee()
		if melee and melee.rate then
			local rate = melee.rate
			if not casterStats and effect.form == "cat" and TT.FormProfileKey and TT.FormProfileKey() == "cat" then
				rate = rate / (1 + effect.autoAttackDamagePercent)
			end
			gain = gain + rate * effect.autoAttackDamagePercent
			breakdown = breakdown ~= "" and (breakdown .. ", ") or ""
			breakdown = breakdown .. string.format("%+.0f auto-attack dps", rate * effect.autoAttackDamagePercent)
		end
	end
	if breakdown ~= "" then
		local verdict, working = TT.Verdict(gain, physical.dps, "dps")
		result.lines[#result.lines + 1] = { "Damage", verdict }
		result.lines[#result.lines + 1] = { "Damage from", string.format("%s, %s (%s)", breakdown, working or "no baseline yet", physicalSource or physical.source), true }
	elseif (parts.str or parts.agi) then
		result.lines[#result.lines + 1] = { "Stats", string.format("%+.0f", parts.str or parts.agi) }
	end

	if effect.enemyAp then
		result.lines[#result.lines + 1] = { "Enemy attack power", string.format("%+.0f", effect.enemyAp) }
	end

	local ehp, ehpFrom, ehpBase = TT.StatEhp(parts)
	if ehp ~= 0 then
		result.lines[#result.lines + 1] = { "Toughness", (TT.Verdict(ehp, ehpBase, "ehp")) }
		result.lines[#result.lines + 1] = { "Toughness from", ehpFrom, true }
	end

	for _, kind in ipairs({ "energy", "rage", "mana" }) do
		local amount = effect[kind]
		if amount and kind ~= "mana" then
			local damage, rate = TT.PriceResource(kind, amount)
			if damage then
				local form = TT.ResourceForm(kind)
				result.lines[#result.lines + 1] = { string.format("%+d %s is worth%s", amount, kind, form and (" in " .. form) or ""),
					string.format("%+.0f dmg", damage) }
				result.lines[#result.lines + 1] = { "Each " .. kind, string.format("%.2f dmg", rate), true }
			end
		end
	end

	local shiftKind = (effect.shiftEnergy and "energy") or (effect.shiftRage and "rage") or nil
	if shiftKind then
		local amount = effect.shiftEnergy or effect.shiftRage
		local damage = TT.PriceResource(shiftKind, amount)
		result.lines[#result.lines + 1] = { string.format("%+d %s per shift", amount, shiftKind), damage and string.format("%+.0f dmg", damage) or "" }
	end

	if effect.costCuts and TT.CostCutsWorth then
		local _, _, _, _, rotation = TT.CostCutsWorth(effect.costCuts)
		if rotation then TT.SetPreview(rotation, "with " .. (TT.SpellName(spellID) or "talent")) end
	end
	for _, cut in ipairs(effect.costCuts or {}) do
		local delta, withIt, withoutIt, fight, name, filler, why, rotation = TT.CostCutWorth(cut.name, cut.kind, cut.amount)
		local shown = name or (cut.name:gsub("^%l", string.upper))
		local resource = cut.kind == "any" and "rage or energy" or cut.kind
		local label = string.format("%s costs %d less %s", shown, cut.amount, resource)
		if delta and withoutIt and withoutIt > 0 then
			result.lines[#result.lines + 1] = { label, (TT.Verdict(delta, withoutIt, "dps")) }
			--a discount that changes what you fill with is worth more than its own arithmetic says
			if filler then
				result.lines[#result.lines + 1] = { "Makes it your filler", string.format("over %s", filler), true }
			end
			result.lines[#result.lines + 1] = { "With and without it", string.format("%.2f against %.2f dps over %.0fs", withIt, withoutIt, fight), true }
		else
			if why == "not on your bars in this form" then
				result.lines[#result.lines + 1] = { label, string.format("%d %s saved per cast", cut.amount, resource) }
				result.lines[#result.lines + 1] = { "DPS not priced", why, true }
			else
				result.lines[#result.lines + 1] = { label, why or "nothing to compare against" }
			end
		end
	end

	for _, cut in ipairs(effect.cooldownCuts or {}) do
		local delta, withIt, withoutIt, fight, name, why, rotation = TT.CooldownCutWorth(cut.name, cut.amount)
		local shown = name or cut.name:gsub("^%l", string.upper)
		local label = string.format("%s cooldown", shown)
		if delta and withoutIt and withoutIt > 0 then
			result.lines[#result.lines + 1] = { label, string.format("%+.0f sec", -cut.amount) }
			result.lines[#result.lines + 1] = { "Worth", TT.Verdict(delta, withoutIt, "dps") }
			result.lines[#result.lines + 1] = { "With and without it", string.format("%.2f against %.2f dps over %.0fs", withIt, withoutIt, fight), true }
			if rotation then TT.SetPreview(rotation, "with " .. (TT.SpellName(spellID) or "talent")) end
		else
			result.lines[#result.lines + 1] = { label, why or "not enough simulation data to price it" }
		end
	end

	if effect.spirit then
		local fight = TT.FightLength()
		local mana = TT.ManaFromSpirit(effect.spirit, fight)
		if mana then
			result.lines[#result.lines + 1] = { string.format("Mana over %.0fs", fight), string.format("%+.0f", mana) }
			local damage, _, spendable, _, conversion = TT.SpiritWorth(effect.spirit)
			if damage then
				result.lines[#result.lines + 1] = { "Worth", string.format("%+.0f dmg", damage) }
				if conversion then
					result.lines[#result.lines + 1] = { "Used by " .. conversion, string.format("%.0f extra mana spent", spendable or 0), true }
					result.lines[#result.lines + 1] = { "Regeneration", "five second rule and mana pool limits are simulated", true }
				else
					result.lines[#result.lines + 1] = { "Which is", "estimated from your mana resource value", true }
					result.lines[#result.lines + 1] = { "Mana estimate", "spend timing is not modeled", true }
				end
			else
				result.lines[#result.lines + 1] = { "Worth", "nothing your spec spends mana on" }
			end
		end
	end

	--intellect buys mana and nothing else, and mana only becomes damage through whatever your spec spends it on
	if parts.int then
		local mana = TT.ManaFromIntellect(parts.int)
		result.lines[#result.lines + 1] = { "Mana pool", string.format("%+d", mana) }
		local damage, how = TT.PriceMana(mana, false)
		if damage then
			result.lines[#result.lines + 1] = { "Worth", string.format("%+.0f dmg", damage) }
			result.lines[#result.lines + 1] = { "Which is", how or "", true }
		else
			result.lines[#result.lines + 1] = { "Worth", how or "nothing your spec spends mana on" }
		end
		result.lines[#result.lines + 1] = { "No damage", "intellect does not scale anything you hit with", true }
	end

	if effect.manaSaved then
		local damage, how, shifts = TT.PriceMana(effect.manaSaved, effect.manaSavedOnShift)
		local where = effect.manaSavedOnShift and " per shift" or ""
		result.lines[#result.lines + 1] = { "Saves" .. where, string.format("%d mana", effect.manaSaved) }
		if damage then
			result.lines[#result.lines + 1] = { how or "Worth", string.format("%+.0f dmg", damage) }
			if shifts then
				result.lines[#result.lines + 1] = { "Extra shifts (mana permitting)", string.format("+%.1f per shift", shifts), true }
			end
		elseif how then
			result.lines[#result.lines + 1] = { "Not priced", how }
		end
	end

	--per crit, because that is the event the talent keys off, and the crit chance is already in the stat cache
	if effect.comboChance or effect.rageChance then
		local crit = (stats and stats.crit or 0) / 100
		if effect.comboChance then
			local extra = effect.comboChance * crit
			result.lines[#result.lines + 1] = { "Extra " .. TT.ComboMark() .. " per builder", string.format("%+.2f", extra) }
			local worth = TT.PriceResource("combo", extra)
			if worth then
				result.lines[#result.lines + 1] = { "Which is worth", string.format("%+.1f dmg per builder", worth) }
			end
		end
		if effect.rageChance and effect.rageOnCrit then
			local extra = effect.rageChance * crit * effect.rageOnCrit
			result.lines[#result.lines + 1] = { "Extra rage per crit", string.format("%+.2f", extra) }
			local worth = TT.PriceResource("rage", extra)
			if worth then
				result.lines[#result.lines + 1] = { "Which is worth", string.format("%+.1f dmg per crit", worth) }
			end
		end
	end

	if effect.thorns then
		--the meter already measured what this did, and dividing it by the per hit damage is how often you are actually hit
		local measured, confidence = TT.SpellRate(spellID)
		if measured and measured > 0 then
			result.lines[#result.lines + 1] = { string.format("Measured (%.0f%% sure)", (confidence or 0) * 100), string.format("%.2f dps", measured) }
			result.lines[#result.lines + 1] = { "Which is you being hit", string.format("%.1f times a second", measured / effect.thorns), true }
		else
			local entries = {}
			for _, swings in ipairs(SAMPLE_SWINGS) do
				entries[#entries + 1] = { key = swings .. "/min", value = effect.thorns * swings / 60 }
			end
			result.rows[#result.rows + 1] = { label = "DPS by attacks taken", entries = entries }
		end
	end

	if #result.lines == 0 and #result.rows == 0 then return nil, "nothing to value" end
	return result
end
