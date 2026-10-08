local ADDON, TT = ...

local MAIN_BAR_SLOTS = 12
local BONUS_BAR_BASE = 72
local LAST_BAR_SLOT = 72
local LAST_ACTION_SLOT = 180

--the bars you can actually see: the main bar as the current form pages it, plus the side and bottom bars
local function barSlots()
	local slots = {}
	local offset = GetBonusBarOffset and GetBonusBarOffset() or 0
	local page = GetActionBarPage and GetActionBarPage() or 1
	local base = offset > 0 and (BONUS_BAR_BASE + (offset - 1) * MAIN_BAR_SLOTS) or ((page - 1) * MAIN_BAR_SLOTS)
	for i = 1, MAIN_BAR_SLOTS do slots[#slots + 1] = base + i end
	for slot = MAIN_BAR_SLOTS + 1, LAST_BAR_SLOT do slots[#slots + 1] = slot end
	return slots
end

local function spellOfSlot(slot)
	local kind, id = GetActionInfo(slot)
	if kind == "spell" then return id end
	if kind == "macro" then
		local resolved = TT.MacroSpellID(id, nil)
		if resolved then return resolved end
		if not TT.Readable(id) then return nil end
		local info = TT.Safely(C_Spell.GetSpellInfo, id)
		return info and info.spellID or nil
	end
	return nil
end

function TT.SpellLines(spellID)
	if not C_TooltipInfo or not C_TooltipInfo.GetSpellByID then return nil end
	local data = TT.Safely(C_TooltipInfo.GetSpellByID, spellID)
	if not data or not data.lines then return nil end
	if TooltipUtil and TooltipUtil.SurfaceArgs then TooltipUtil.SurfaceArgs(data) end
	local lines = {}
	for _, line in ipairs(data.lines) do
		if TooltipUtil and TooltipUtil.SurfaceArgs then TooltipUtil.SurfaceArgs(line) end
		--half a tooltip prices wrong, so one secret line drops the whole ability
		if not TT.SplitText(lines, line.leftText) then return nil end
	end
	return lines
end

local function costOf(spellID)
	local costs = C_Spell.GetSpellPowerCost(spellID)
	for _, cost in ipairs(costs or {}) do
		if cost.cost and cost.cost > 0 then return cost end
	end
	return nil
end

--an ability that converts mana to energy or rage (Shifting Power style)
local function buildConversion(spellID, lines)
	local effect = TT.ParseEffect(lines)
	if not effect then return nil end
	local parsed = TT.Parse(lines)
	local grant = effect.shiftEnergy or effect.energy
	local grantKind = grant and "energy" or nil
	if not grant then
		grant = effect.shiftRage or effect.rage
		grantKind = grant and "rage" or nil
	end
	if not grant or grant <= 0 then return nil end

	local info = C_Spell.GetSpellInfo(spellID)
	local cost = costOf(spellID)
	local manaCost = cost and cost.type == Enum.PowerType.Mana and cost.cost or 0
	if manaCost <= 0 then return nil end
	local cooldown = C_Spell.GetSpellBaseCooldown and C_Spell.GetSpellBaseCooldown(spellID)
	if not cooldown and GetSpellBaseCooldown then cooldown = GetSpellBaseCooldown(spellID) end
	local seconds = TT.Readable(cooldown) and cooldown / 1000 or 0
	local spellName = info and TT.ReadableText(info.name) and info.name or ""
	local cooldownCut = TT.CooldownCuts and TT.CooldownCuts()[spellName:lower()] or 0
	if cooldownCut > 0 then seconds = math.max(1.5, seconds - cooldownCut) end

	return {
		id = spellID,
		name = info and info.name or tostring(spellID),
		cost = manaCost,
		power = "mana",
		gcd = 1.5,
		cooldown = seconds,
		talentCooldownApplied = cooldownCut > 0 or nil,
		forms = parsed and parsed.forms,
		conversion = { kind = grantKind, amount = grant },
	}
end

--a debuff that strips armor is part of the rotation even though it does no damage itself
local function buildDebuff(spellID, lines)
	local effect = TT.ParseEffect(lines)
	if not effect or not effect.armorReduce then return nil end
	local parsed = TT.Parse(lines)
	TT.LearnArmorDebuff(spellID, effect.armorReduce)
	local gain = TT.ArmorGain(effect.armorReduce)
	if gain <= 0 then return nil end

	local info = C_Spell.GetSpellInfo(spellID)
	local cost = costOf(spellID)
	local energy = cost and cost.type == Enum.PowerType.Energy and cost.cost or 0
	return {
		id = spellID,
		name = info and info.name or tostring(spellID),
		cost = energy,
		power = cost and cost.type == Enum.PowerType.Energy and "energy" or nil,
		gcd = energy > 0 and 1.0 or 1.5,
		forms = parsed and parsed.forms,
		debuff = { gain = gain, duration = effect.duration or 30 },
	}
end

--a cooldown that generates rage or energy without costing mana (Enrage, Tiger's Fury)
local function buildResourceCooldown(spellID, lines)
	local effect = TT.ParseEffect(lines)
	if not effect then return nil end
	local grant = effect.rage or effect.energy
	local grantKind = effect.rage and "rage" or effect.energy and "energy" or nil
	if not grant or grant <= 0 then return nil end

	local cooldown = C_Spell.GetSpellBaseCooldown and C_Spell.GetSpellBaseCooldown(spellID)
	if not cooldown and GetSpellBaseCooldown then cooldown = GetSpellBaseCooldown(spellID) end
	cooldown = TT.Readable(cooldown) and cooldown / 1000 or 0
	if cooldown <= 0 then return nil end

	local info = C_Spell.GetSpellInfo(spellID)
	local cost = costOf(spellID)
	local parsed = TT.Parse(lines)
	return {
		id = spellID,
		name = info and info.name or tostring(spellID),
		cost = cost and cost.cost or 0,
		power = cost and cost.type == Enum.PowerType.Rage and "rage" or cost and cost.type == Enum.PowerType.Energy and "energy" or nil,
		gcd = 1.5,
		cooldown = cooldown,
		forms = parsed and parsed.forms,
		resourceGrant = { kind = grantKind, amount = grant },
	}
end

--a debuff that reduces enemy attack power (Demoralizing Roar)
local function buildToughnessCooldown(spellID, lines)
	local effect = TT.ParseEffect(lines)
	if not effect or not effect.enemyAp then return nil end

	local cooldown = C_Spell.GetSpellBaseCooldown and C_Spell.GetSpellBaseCooldown(spellID)
	if not cooldown and GetSpellBaseCooldown then cooldown = GetSpellBaseCooldown(spellID) end
	cooldown = TT.Readable(cooldown) and cooldown / 1000 or 0

	local info = C_Spell.GetSpellInfo(spellID)
	local cost = costOf(spellID)
	local parsed = TT.Parse(lines)
	return {
		id = spellID,
		name = info and info.name or tostring(spellID),
		cost = cost and cost.cost or 0,
		power = cost and cost.type == Enum.PowerType.Rage and "rage" or cost and cost.type == Enum.PowerType.Energy and "energy" or nil,
		gcd = 1.5,
		cooldown = cooldown,
		duration = effect.duration or 30,
		enemyApReduction = -effect.enemyAp,
		forms = parsed and parsed.forms,
	}
end

local function buildControl(spellID, lines)
	local parsed = TT.Parse(lines)
	if not parsed or not parsed.control and not parsed.taunt then return nil end
	local effect = TT.ParseEffect(lines) or {}
	if not parsed.taunt and (not effect.duration or effect.duration <= 0) then return nil end

	local cooldown = C_Spell.GetSpellBaseCooldown and C_Spell.GetSpellBaseCooldown(spellID)
	if not cooldown and GetSpellBaseCooldown then cooldown = GetSpellBaseCooldown(spellID) end
	cooldown = TT.Readable(cooldown) and cooldown / 1000 or 0

	local info = C_Spell.GetSpellInfo(spellID)
	local cost = costOf(spellID)
	return {
		id = spellID,
		name = info and info.name or tostring(spellID),
		cost = cost and cost.cost or 0,
		power = cost and cost.type == Enum.PowerType.Mana and "mana"
			or cost and cost.type == Enum.PowerType.Rage and "rage"
			or cost and cost.type == Enum.PowerType.Energy and "energy" or nil,
		gcd = 1.5,
		cooldown = cooldown,
		control = parsed.controlType,
		controlDuration = effect.duration,
		taunt = parsed.taunt,
		castTime = (info and info.castTime or 0) / 1000,
		forms = parsed.forms,
	}
end

local function build(spellID)
	local lines = TT.SpellLines(spellID)
	if not lines then return nil end
	local scan = TT.Parse(lines)
	if scan and scan.kind == "heal" then
		local result = TT.Calc(spellID, scan)
		if not result then return nil end
		local info = C_Spell.GetSpellInfo(spellID)
		return {
			id = spellID,
			name = info and info.name or tostring(spellID),
			healing = result.critTotal,
			healRate = result.rate,
			healDirect = result.cast.instant * result.critTotal / result.cast.total,
			healOver = result.cast.over * result.critTotal / result.cast.total,
			healDuration = result.cast.duration,
			healCycle = result.cycle,
			healCastTime = (info and info.castTime or 0) / 1000,
			healPerResource = result.perResource,
			cost = result.cost or 0,
			power = result.powerName,
			gcd = result.cycle,
			cooldown = result.limiter == "cooldown" and result.cycle or 0,
			heal = true,
			aoe = scan.aoe,
			maxTargets = scan.maxTargets,
		}
	end
	if not scan or scan.kind ~= "damage" then
		return buildConversion(spellID, lines) or buildDebuff(spellID, lines)
			or buildResourceCooldown(spellID, lines) or buildToughnessCooldown(spellID, lines)
			or buildControl(spellID, lines)
	end

	local result = TT.Calc(spellID, scan)
	if not result then return nil end

	local info = C_Spell.GetSpellInfo(spellID)
	local ability = {
		id = spellID,
		name = info and info.name or tostring(spellID),
		cost = result.cost or 0,
		power = result.powerName,
		cast = math.max((info and info.castTime or 0) / 1000, 0),
		gcd = result.cycle,
		cooldown = result.limiter == "cooldown" and result.cycle or 0,
		awards = scan.awards,
		nextSwing = scan.nextSwing,
		positional = scan.positional,
		forms = scan.forms,
		aoe = scan.aoe,
		maxTargets = scan.maxTargets,
		minRange = scan.minRange,
		maxRange = scan.maxRange,
		--a minimum range is a gap to close, so it cannot be cast from melee and is one cast at the pull rather than a cadence
		openerOnly = (scan.minRange or 0) > 0 or nil,
		requiresAttackingTarget = info and info.name and info.name:lower():find("feral charge", 1, true) ~= nil
			and scan.minRange == 8 and scan.maxRange == 25 or nil,
		--a damage-over-time that names no magic school is physical, which is what a bleed is
		bleed = (scan.school or 1) == 1 and (result.cast.duration or 0) > 0 and (result.cast.over or 0) > 0,
	}
	if scan.control then
		local effect = TT.ParseEffect(lines)
		ability.control, ability.controlDuration = scan.controlType, effect and effect.duration
		ability.castTime = (info and info.castTime or 0) / 1000
	end

	if result.levels then
		ability.levels = {}
		for _, level in ipairs(result.levels) do
			ability.levels[level.points] = { instant = level.cast.instant, over = level.cast.over, duration = level.cast.duration }
		end
		ability.finisher = true
	else
		ability.instant = result.cast.instant
		ability.over = result.cast.over
		ability.duration = result.cast.duration
	end

	--crit is already folded into the per-cast numbers the calculator returned
	local scale = result.critTotal / math.max(result.cast.total, 1)
	ability.scale = scale
	return ability
end

function TT.AbilityByName(name)
	local info = C_Spell.GetSpellInfo(name)
	if not info or not TT.Readable(info.spellID) then return nil end
	local playerSpell = IsPlayerSpell and TT.ReadableBool(TT.Safely(IsPlayerSpell, info.spellID))
	local knownSpell = IsSpellKnown and TT.ReadableBool(TT.Safely(IsSpellKnown, info.spellID))
	if playerSpell ~= true and knownSpell ~= true and (playerSpell == false or knownSpell == false) then return nil end
	return build(info.spellID)
end

--the whole chain as one action: what it costs, what it does and how long it takes
function TT.ChainValue(ids)
	local chain = { damage = 0, cost = 0, time = 0, count = #ids }
	for _, id in ipairs(ids) do
		local ability = build(id)
		if not ability then return nil end
		local part = ability.levels and (ability.levels[5] or ability.levels[1]) or ability
		chain.damage = chain.damage + ((part.instant or 0) + (part.over or 0)) * (ability.scale or 1)
		chain.cost = chain.cost + (ability.cost or 0)
		chain.time = chain.time + math.max(ability.gcd or 1, ability.cast or 0)
		chain.power = chain.power or ability.power
	end
	return chain
end

--a mana spell is a caster spell unless this client lets you cast it in form, which its tooltip never says
local ANY_FORM_NAMES = { "faerie fire" }

local function namedAnyForm(name)
	if not name then return false end
	local lower = name:lower()
	for _, known in ipairs(ANY_FORM_NAMES) do
		if lower:find(known, 1, true) then return true end
	end
	return false
end

--the client only calls a spell usable, or usable but for mana, in a form that can actually cast it, so standing
--in one is the evidence the tooltip withholds; only ever recorded as a yes, since a no has a dozen other causes
local function observeAnyForm(spellID)
	if not IsUsableSpell or not TT.char then return end
	local form = TT.CurrentForm and TT.CurrentForm()
	if not form or not (form:find("cat", 1, true) or form:find("bear", 1, true)) then return end
	local usable, noMana = TT.Safely(IsUsableSpell, spellID)
	usable, noMana = TT.ReadableBool(usable), TT.ReadableBool(noMana)
	if usable ~= true and noMana ~= true then return end
	TT.char.anyForm = TT.char.anyForm or {}
	TT.char.anyForm[spellID] = true
end

local function buildForProfile(spellID, stats)
	local ability
	if stats and TT.WithStats then ability = TT.WithStats(stats, build, spellID)
	else ability = build(spellID) end
	if ability and ability.power == "mana" and not ability.forms then
		observeAnyForm(spellID)
		if namedAnyForm(ability.name) or (TT.char and TT.char.anyForm and TT.char.anyForm[spellID]) then
			ability.anyForm = true
		end
	end
	return ability
end

local function collectAbility(slot, seen, abilities, stats, profileForm)
	local spellID = spellOfSlot(slot)
	if not spellID or seen[spellID] then return end
	seen[spellID] = true
	local ability = buildForProfile(spellID, stats)
	if ability then
		ability.profileForm = profileForm
		abilities[#abilities + 1] = ability
	end
end

local function collectAbilities(slots, seen, abilities, stats, profileForm)
	for _, slot in ipairs(slots) do collectAbility(slot, seen, abilities, stats, profileForm) end
end

function TT.ActionReport()
	local out = {}
	for slot = 1, LAST_ACTION_SLOT do
		local kind, id = GetActionInfo(slot)
		if kind then
			local spellID = spellOfSlot(slot)
			if not spellID then
				out[#out + 1] = string.format("slot %d: %s %s (not resolved)", slot, tostring(kind), tostring(id))
			else
				local info = C_Spell.GetSpellInfo(spellID)
				local lines = TT.SpellLines(spellID)
				local scan = lines and TT.Parse(lines)
				local ability = lines and build(spellID)
				if ability then
					local abilityKind = ability.conversion and "conversion" or ability.debuff and "debuff" or "damage"
					out[#out + 1] = string.format("slot %d: %s %d %s [%s, %d %s]",
						slot, tostring(kind), spellID, info and info.name or "?", abilityKind,
						ability.cost or 0, ability.power or "free")
				elseif not lines then
					out[#out + 1] = string.format("slot %d: %s %d %s [no readable tooltip]",
						slot, tostring(kind), spellID, info and info.name or "?")
				elseif scan then
					out[#out + 1] = string.format("slot %d: %s %d %s [parsed %s, not rotation damage]",
						slot, tostring(kind), spellID, info and info.name or "?", scan.kind or "unknown")
				else
					out[#out + 1] = string.format("slot %d: %s %d %s [no damage parsed: %s]",
						slot, tostring(kind), spellID, info and info.name or "?", table.concat(lines, " / "):sub(1, 120))
				end
			end
		end
	end
	if #out == 0 then out[1] = string.format("no actions returned by GetActionInfo in slots 1-%d", LAST_ACTION_SLOT) end
	return out
end

function TT.Abilities()
	local seen, abilities = {}, {}
	local profileForm = TT.FormProfileKey and TT.FormProfileKey()
	collectAbilities(barSlots(), seen, abilities, nil, profileForm)
	local usableInForm = false
	for _, ability in ipairs(abilities) do
		if not ability.debuff and ((ability.instant or 0) > 0 or (ability.over or 0) > 0 or ability.levels)
			and not TT.WrongForm(ability.forms, ability.power) then
			usableInForm = true
			break
		end
	end
	if not usableInForm then
		for slot = 1, LAST_ACTION_SLOT do collectAbility(slot, seen, abilities, nil, profileForm) end
	end
	return abilities
end

local function allAbilities(stats, profileForm)
	local seen, abilities = {}, {}
	collectAbilities(barSlots(), seen, abilities, stats, profileForm)
	for slot = 1, LAST_ACTION_SLOT do collectAbility(slot, seen, abilities, stats, profileForm) end
	local modernSpellBook = C_SpellBook
		and C_SpellBook.GetNumSpellBookSkillLines and C_SpellBook.GetSpellBookSkillLineInfo
		and C_SpellBook.GetSpellBookItemType
	local numTabs
	if modernSpellBook then numTabs = TT.Safely(C_SpellBook.GetNumSpellBookSkillLines)
	elseif GetNumSpellTabs then numTabs = TT.Safely(GetNumSpellTabs) end
	if not TT.Readable(numTabs) then return abilities end
	for tab = 1, numTabs do
		local offset, numSpells
		if modernSpellBook then
			local skillLine = TT.Safely(C_SpellBook.GetSpellBookSkillLineInfo, tab)
			offset, numSpells = skillLine and skillLine.itemIndexOffset, skillLine and skillLine.numSpellBookItems
		elseif GetSpellTabInfo then
			local _
			_, _, offset, numSpells = TT.Safely(GetSpellTabInfo, tab)
		end
		if TT.Readable(offset) and TT.Readable(numSpells) then
			for i = 1, numSpells do
				local id
				if modernSpellBook then
					local bank = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
					local _, _, spellID = TT.Safely(C_SpellBook.GetSpellBookItemType, offset + i, bank)
					id = spellID
				elseif GetSpellBookItemInfo then
					local kind, spellID = TT.Safely(GetSpellBookItemInfo, offset + i, "spell")
					if TT.ReadableText(kind) and kind == "SPELL" then id = spellID end
				end
				if TT.Readable(id) and not seen[id] then
					seen[id] = true
					local ability = buildForProfile(id, stats)
					if ability then
						ability.profileForm = profileForm
						abilities[#abilities + 1] = ability
					end
				end
			end
		end
	end
	return abilities
end

function TT.AllAbilities()
	return allAbilities(nil, TT.FormProfileKey and TT.FormProfileKey())
end

function TT.AllAbilitiesForForm(form)
	local stats = TT.FormStats and TT.FormStats(form)
	if not stats or not TT.WithStats then return nil end
	return allAbilities(stats, form)
end
