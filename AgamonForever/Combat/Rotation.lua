local ADDON, TT = ...

local DEFAULT_FIGHT = 15 --what a pull costs when nothing has been measured yet
local MIN_FIGHT = 4
local MAX_FIGHT = 120
local ENERGY_PER_SEC = 10
local ENERGY_MAX = 100
local MAX_COMBO = 5
local STEP = 0.1
local SEQUENCE_RUNS = 5 --five icons is what fits the panel width
local CACHE_SECONDS = 20
local FIVE_SECOND_RULE = 5
local FORM_ORDER = { "cat", "bear", "caster" }

local cached, cachedAt, cachedContext, attemptedAt, attemptedContext = nil, 0, nil, nil, nil
--the form model and the full simulation are defined further down, but the rotation above them has to reach them
local simulateVariantFull, simulationForm, formAllows, shiftTargetForm, currentSimulationForm

local function contextKey(includeStats)
	local form = TT.CurrentForm and TT.CurrentForm()
	local formName = type(form) == "string"
	if TT.ReadableText then formName = TT.ReadableText(form) end
	--the target's type is in the key because what it is immune to changes which rotation is right
	local kind = TT.BleedImmune and select(2, TT.BleedImmune(nil, "target")) or ""
	local parts = { formName and form or "", GetActionBarPage and GetActionBarPage() or 1,
		GetBonusBarOffset and GetBonusBarOffset() or 0, TT.Targets(), kind or "" }
	if includeStats ~= false then parts[#parts + 1] = TT.FormStatsKey and TT.FormStatsKey() or "" end
	if TT.CooldownCuts then
		local cuts = {}
		for name, amount in pairs(TT.CooldownCuts()) do cuts[#cuts + 1] = name .. ":" .. amount end
		table.sort(cuts)
		parts[#parts + 1] = table.concat(cuts, ",")
	end
	return table.concat(parts, ":")
end

function TT.RotationContext()
	return contextKey()
end

function TT.SimulationContext()
	return contextKey(false)
end

local function crit(ability, amount)
	return amount * (ability.scale or 1)
end

--the pack the simulation is running against, which decides what an aoe ability is actually worth
local simTargets = 1

local MAX_TARGETS = 40

--the pull counts itself unless you pinned a number, because the size of it is the one thing the fight already knows
function TT.Targets()
	if TT.db.autoTargets then
		local seen = TT.EnemiesInCombat and TT.EnemiesInCombat()
		return seen and seen > 0 and math.min(MAX_TARGETS, seen) or 1
	end
	return math.max(1, math.min(MAX_TARGETS, TT.db.targets or 1))
end

local function hits(ability)
	if simTargets <= 1 or not ability.aoe then return 1 end
	return math.min(simTargets, ability.maxTargets or simTargets)
end

--a dot runs on every target at once, so a pack is the same dot applied again rather than one bigger hit,
--bounded by how many you can reach before the first one falls off
local function dotCopies(ability, targetLimit)
	if simTargets <= 1 or ability.aoe then return 1 end
	local duration, gcd = ability.duration or 0, ability.gcd or 1.5
	if duration <= 0 or gcd <= 0 then return 1 end
	return math.max(1, math.min(simTargets, targetLimit or simTargets, math.floor(duration / gcd)))
end

--which target still needs it, so a dot is only recast when one of them has actually run out
local function freeSlot(expiry, ability, now, targetLimit)
	for slot = 1, dotCopies(ability, targetLimit) do
		if (expiry[ability.name .. "#" .. slot] or 0) <= now then return slot end
	end
	return nil
end

local function value(ability, points)
	local part = ability.levels and ability.levels[points or MAX_COMBO] or ability
	if not part then return 0, 0, 0 end
	local struck = hits(ability)
	return crit(ability, ((part.instant or 0) + (part.over or 0)) * struck), crit(ability, (part.instant or 0) * struck), part.duration or 0
end

--a global cooldown pays part of its own cost back in regen, so a cheap fast ability is cheaper than the number on it
local function netCost(ability)
	local cost = ability.cost or 0
	if cost <= 0 or ability.power ~= "energy" then return cost end
	return math.max(cost - (ability.gcd or 1) * ENERGY_PER_SEC, 1)
end

local function perEnergy(ability, points)
	local cost = netCost(ability)
	if cost <= 0 then return 0 end
	local total = value(ability, points)
	if ability.over and ability.over > 0 and not ability.aoe then total = total * dotCopies(ability) end
	return total / cost
end

local function classify(abilities)
	local builders, finishers, dots, best, debuff = {}, {}, {}, nil, nil
	local conversions, cooldowns = {}, {}
	for _, ability in ipairs(abilities) do
		if ability.conversion then
			conversions[#conversions + 1] = ability
		elseif ability.debuff then
			if not debuff or ability.debuff.gain > debuff.debuff.gain then debuff = ability end
		elseif ability.resourceGrant or ability.enemyApReduction then
			cooldowns[#cooldowns + 1] = ability
		elseif (ability.power == "energy" or ability.power == "rage") and (ability.cost or 0) > ENERGY_MAX then
			--nothing you cannot afford at a full bar belongs in a sustained rotation
		elseif ability.finisher then
			finishers[#finishers + 1] = ability
		elseif ability.openerOnly then
			builders[#builders + 1] = ability
		else
			local _, _, duration = value(ability)
			if duration > 0 and (ability.over or 0) >= (ability.instant or 0) then
				dots[#dots + 1] = ability
			elseif ability.awards or (ability.instant or 0) > 0 then
				builders[#builders + 1] = ability
				if (ability.cooldown or 0) <= 0 and (not best or perEnergy(ability) > perEnergy(best)) then best = ability end
				if (ability.cooldown or 0) > 0 then cooldowns[#cooldowns + 1] = ability end
			end
		end
	end
	return builders, finishers, dots, best, debuff, conversions, cooldowns
end

--what a whole build-and-spend cycle earns per second, which is the only honest way to compare spending now with spending later
local function cycleRate(finisher, filler, points)
	local perBuilder = TT.ComboPerBuilder()
	local casts = points / perBuilder
	local span = casts * (filler.gcd or 1) + (finisher.gcd or 1)
	local energy = casts * netCost(filler) + netCost(finisher)
	local seconds = math.max(span, energy / ENERGY_PER_SEC)

	local total, instant, duration = value(finisher, points)
	--a dot refreshed before it runs out never pays its tail, so a short cycle collects only the part it had time for
	local over = total - instant
	if duration > 0 and over > 0 then over = over * math.min(1, seconds / duration) end
	return (casts * (value(filler)) + instant + over) / seconds
end

--the point count worth spending at: the one whose cycle beats every other, not the first one that beats the filler
local function comboBreakpoint(finisher, filler)
	if not finisher or not filler or not finisher.levels then return nil end
	local best, bestRate
	for points = 1, MAX_COMBO do
		if finisher.levels[points] then
			local rate = cycleRate(finisher, filler, points)
			if not bestRate or rate > bestRate then best, bestRate = points, rate end
		end
	end
	return best
end

local function pickBest(list, points)
	local best
	for _, ability in ipairs(list) do
		if not ability.openerOnly and (not best or perEnergy(ability, points) > perEnergy(best, points)) then best = ability end
	end
	return best
end

--a greedy energy and combo point rotation: keep the worthwhile dots up, spend at five points, fill with the best builder
local function simulateEnergyVariant(abilities, melee, horizon, targetLimit, disableDot)
	local builders, finishers, dots, filler, debuff = classify(abilities)
	if not filler then return nil end
	--conversions are mana-based so they may be filtered out by usable(); get them from raw abilities
	local _, _, _, _, _, rawConversions = classify(TT.Abilities())
	local conversion = rawConversions and rawConversions[1] or nil

	local finisher = pickBest(finishers, MAX_COMBO)
	local dot = not disableDot and pickBest(dots) or nil
	local fillerValue = perEnergy(filler)
	if dot and perEnergy(dot) <= fillerValue then dot = nil end
	if finisher and perEnergy(finisher, MAX_COMBO) <= fillerValue then finisher = nil end

	local breakpoint = comboBreakpoint(finisher, filler)

	local energy, time, damage = ENERGY_MAX, 0, 0
	local combo, onTarget = 0, 1
	local expiry, used = {}, {}
	local guard = 0
	local multiplier = 1
	local perBuilder = TT.ComboPerBuilder()
	local manaState = TT.ManaState and TT.ManaState()
	local mana = manaState and manaState.current or 0
	local manaRegen = manaState and manaState.perSecond or 0
	local nextConversionAt = 0

	local function endgame(at)
		if not finisher then return false end
		local perCast = math.max(filler.gcd or 1, netCost(filler) / ENERGY_PER_SEC)
		return at + perCast + (finisher.gcd or 1) > horizon
	end
	local casts = {}
	local spent, abilityDamage, finisherDamage, comboSpent = 0, 0, 0, 0
	local byName = {}

	while time < horizon do
		guard = guard + 1
		if guard > 1000 then break end
		local choice
		local slot = dot and freeSlot(expiry, dot, time, targetLimit) or nil
		local dotWorth = slot and (horizon - time) >= (dot.duration or 0) * 0.5
		if debuff and (expiry[debuff.name] or 0) <= time then
			choice = debuff
		elseif finisher and combo >= (breakpoint or MAX_COMBO) then
			choice = finisher
		elseif slot and dotWorth then
			choice = dot
			onTarget = slot
		elseif finisher and combo >= 1 and endgame(time) then
			choice = finisher
		else
			choice = filler
		end

		if choice ~= conversion and energy < (choice.cost or 0) and conversion
			and time >= nextConversionAt and mana >= (conversion.cost or 0)
			and energy <= ENERGY_MAX - (conversion.conversion.amount or 0) then choice = conversion end

		if choice ~= conversion and energy < choice.cost then
			local wait = (choice.cost - energy) / ENERGY_PER_SEC
			time = time + wait
			energy = math.min(ENERGY_MAX, energy + wait * ENERGY_PER_SEC)
			mana = math.min(manaState and manaState.max or math.huge, mana + wait * manaRegen)
			if time >= horizon then break end
		end

		local points = choice.finisher and math.min(combo, MAX_COMBO) or nil
		if choice.debuff then
			multiplier = 1 + choice.debuff.gain
			expiry[choice.name] = time + choice.debuff.duration
		elseif choice == conversion then
			mana = mana - (conversion.cost or 0)
			energy = math.min(ENERGY_MAX, energy + (conversion.conversion.amount or 0))
			nextConversionAt = time + math.max(conversion.cooldown or 0, conversion.gcd or 1.5)
		else
			local total, instant, duration = value(choice, points)
			local overTotal = total - instant
			local landed = instant * multiplier
			damage = damage + landed
			if duration > 0 and overTotal > 0 then
				local ticking = math.min(duration, horizon - time) / duration
				landed = landed + overTotal * ticking * multiplier
				damage = damage + overTotal * ticking * multiplier
				expiry[choice.name .. "#" .. (slot or 1)] = time + duration
			end
			abilityDamage = abilityDamage + landed
			byName[choice.name] = (byName[choice.name] or 0) + landed
			if choice.finisher then
				finisherDamage = finisherDamage + landed
				comboSpent = comboSpent + (points or 0)
				combo = 0
			else
				combo = math.min(MAX_COMBO, combo + (choice.awards or 1) * perBuilder)
			end
		end

		local shown = points and math.floor(points + 0.5) or nil
		local step = math.max(choice.gcd or 1, STEP)
		local span = choice.finisher and 0 or ((choice.debuff and choice.debuff.duration) or choice.duration or 0)
		local previous = casts[#casts]
		casts[#casts + 1] = { id = choice.id, name = choice.name, points = shown, time = time,
			step = step, span = span, target = onTarget, tab = previous ~= nil and previous.target ~= onTarget,
			--the mob it lands on is part of what the cast is, or four rakes on four targets look like one rake repeated
			key = choice.id .. ":" .. tostring(shown) .. ":" .. onTarget }

		if choice ~= conversion then energy = energy - choice.cost; spent = spent + choice.cost end
		used[choice.name] = (used[choice.name] or 0) + 1

		time = time + step
		energy = math.min(ENERGY_MAX, energy + step * ENERGY_PER_SEC)
		mana = math.min(manaState and manaState.max or math.huge, mana + step * manaRegen)
	end

	damage = damage + (melee or 0) * horizon * multiplier

	if TT.db.debug then
		TT.Print(string.format("sim: %dt %.1fs, ability=%.0f melee=%.0f total=%.0f dps=%.0f",
			simTargets, horizon, abilityDamage, (melee or 0) * horizon, damage, damage / horizon))
		local castList = {}
		for name, count in pairs(used) do castList[#castList + 1] = name .. "x" .. count end
		TT.Print("  casts: " .. table.concat(castList, ", "))
		for name, dmg in pairs(byName) do TT.Print(string.format("  %s: %.0f (%.0f%%)", name, dmg, dmg / damage * 100)) end
	end

	local priority = {}
	if debuff then priority[#priority + 1] = debuff.name .. " (keep up)" end
	if dot then priority[#priority + 1] = dot.name .. " (keep up)" end
	if finisher then priority[#priority + 1] = finisher.name .. " at 5 " .. TT.ComboMark() end
	priority[#priority + 1] = filler.name .. " (fill)"

	--swing damage is left out of the numerator because no resource bought it
	local worth = {}
	if spent > 0 then worth.energy = abilityDamage / spent end
	if comboSpent > 0 then worth.combo = finisherDamage / comboSpent end

	local opener, loop, loopTime = TT.SplitCycle(casts)

	return {
		dps = damage / horizon,
		priority = priority,
		casts = used,
		damageByName = byName,
		damageTotal = damage,
		filler = filler.name,
		opener = opener and TT.Compress(opener) or nil,
		loop = loop and TT.Compress(loop) or nil,
		loopTime = loopTime,
		sequence = TT.Compress(casts, 2, #casts),
		perBuilder = perBuilder,
		value = worth,
		model = "energy",
		--the same classification the simulation ran on, so the live call is the same decision against your real state
		plan = { debuff = debuff, dot = dot, finisher = finisher, filler = filler, breakpoint = breakpoint, conversion = conversion },
	}
end

local function simulateEnergy(abilities, melee, horizon)
	local best = simulateEnergyVariant(abilities, melee, horizon, nil, true)
	for limit = 1, simTargets do
		local result = simulateEnergyVariant(abilities, melee, horizon, limit, false)
		if result and (not best or result.dps > best.dps) then best = result end
	end
	return best
end

local function rageConversion(level)
	return 0.0091107836 * level * level + 3.225598133 * level + 4.2652911
end

local function ragePerSecond()
	local stats = TT.Stats()
	if not stats or stats.speed <= 0 then return 0, {} end
	local level = stats.level or 60
	local conversion = rageConversion(level)
	local crit = (stats.crit or 0) / 100
	local critMultiplier = TT.db.critMultiplier or 2
	local function perWeapon(low, high, speed, offhand)
		if not speed or speed <= 0 or not low or low < 0 or not high or high <= 0 then return 0, nil end
		local average = (low + high) / 2 * (stats.percent or 1)
		local expected = average * (1 + crit * (critMultiplier - 1))
		local normalSpeed = offhand and speed * 1.75 / 2.4 or speed * 3.5 / 2.25
		local criticalSpeed = offhand and speed * 3.5 / 2.25 or speed * 7.5 / 2.25
		local speedPart = normalSpeed * (1 - crit) + criticalSpeed * crit
		return (expected / conversion * 7.5 / 1.075 + speedPart), speed
	end
	local mainRage, mainSpeed = perWeapon(stats.low, stats.high, stats.speed, false)
	local offRage, offSpeed = perWeapon(stats.offLow, stats.offHi, stats.offSpeed, true)
	local swings = {}
	if mainSpeed then swings[#swings + 1] = { rage = mainRage, speed = mainSpeed, at = mainSpeed } end
	if offSpeed then swings[#swings + 1] = { rage = offRage, speed = offSpeed, at = offSpeed } end
	return (mainSpeed and mainRage / mainSpeed or 0) + (offSpeed and offRage / offSpeed or 0), swings
end

TT.RagePerSecond = ragePerSecond

function TT.RageFromDamage(damage)
	local stats = TT.Stats()
	return 2.5 * damage / rageConversion(stats and stats.level or 60)
end

local function simulateRage(abilities, melee, horizon)
	local builders, finishers, dots, filler, debuff = classify(abilities)
	if not filler then return nil end

	local dot = pickBest(dots)
	local fillerValue = perEnergy(filler)
	if dot and perEnergy(dot) <= fillerValue then dot = nil end
	local generation, swings = ragePerSecond()
	if generation <= 0 then return nil, "waiting for valid weapon damage to model Rage generation" end

	local rage, kind = TT.FormResource()
	if kind ~= "rage" then rage = 0 end
	rage = rage or 0
	local time, damage, spent, abilityDamage = 0, 0, 0, 0
	local expiry, used, casts, byName = {}, {}, {}, {}
	local guard, multiplier = 0, 1
	local function nextSwing()
		local selected
		for _, swing in ipairs(swings) do
			if not selected or swing.at < selected.at then selected = swing end
		end
		return selected
	end
	local function advance(target)
		while true do
			local swing = nextSwing()
			if not swing or swing.at > target then break end
			casts[#casts + 1] = { id = 6603, name = "Auto Attack", time = swing.at, step = swing.speed, key = "auto" }
			used["Auto Attack"] = (used["Auto Attack"] or 0) + 1
			rage = math.min(ENERGY_MAX, rage + swing.rage)
			swing.at = swing.at + swing.speed
		end
		time = target
	end
	while time < horizon do
		guard = guard + 1
		if guard > 1000 then break end
		local choice
		local slot = dot and freeSlot(expiry, dot, time) or nil
		if debuff and (expiry[debuff.name] or 0) <= time then choice = debuff
		elseif slot then choice = dot
		else choice = filler end

		while rage < (choice.cost or 0) and time < horizon do
			local swing = nextSwing()
			if not swing then break end
			advance(swing.at)
		end
		if rage < (choice.cost or 0) or time >= horizon then break end

		if choice.debuff then
			multiplier = 1 + choice.debuff.gain
			expiry[choice.name] = time + choice.debuff.duration
		else
			local total, instant, duration = value(choice)
			local over = total - instant
			local landed = instant * multiplier
			if duration > 0 and over > 0 then
				local fraction = math.min(duration, horizon - time) / duration
				landed = landed + over * fraction * multiplier
				expiry[choice.name .. "#" .. (slot or 1)] = time + duration
			end
			damage = damage + landed
			abilityDamage = abilityDamage + landed
			byName[choice.name] = (byName[choice.name] or 0) + landed
		end

		local step = math.max(choice.gcd or 1.5, STEP)
		casts[#casts + 1] = { id = choice.id, name = choice.name, time = time, step = step,
			span = choice.debuff and choice.debuff.duration or choice.duration or 0, key = tostring(choice.id) }
		rage = math.min(ENERGY_MAX, rage - (choice.cost or 0))
		spent = spent + (choice.cost or 0)
		used[choice.name] = (used[choice.name] or 0) + 1
		advance(time + step)
	end

	damage = damage + (melee or 0) * horizon * multiplier
	local priority = {}
	if debuff then priority[#priority + 1] = debuff.name .. " (keep up)" end
	if dot then priority[#priority + 1] = dot.name .. " (keep up)" end
	priority[#priority + 1] = filler.name .. " (spend rage)"
	local opener, loop, loopTime = TT.SplitCycle(casts)
	return {
		dps = damage / horizon, priority = priority, casts = used, damageByName = byName,
		damageTotal = damage, filler = filler.name, opener = opener and TT.Compress(opener) or nil,
		loop = loop and TT.Compress(loop) or nil, loopTime = loopTime,
		sequence = TT.Compress(casts, 2, #casts), value = spent > 0 and { rage = abilityDamage / spent } or {},
		model = "rage", resourcePerSecond = generation,
		plan = { debuff = debuff, dot = dot, filler = filler },
	}
end

--without a resource that refills on a clock, the best we can say is: keep the dots up and fill with the strongest cast
--how often you can actually press it: a cooldown of zero is not a cooldown, and zero is truthy here
local function cadence(ability)
	local floor = TT.Gcd and TT.Gcd() or 1.5
	local gap = (ability.cooldown or 0) > 0 and ability.cooldown or ability.gcd or floor
	return math.max(gap, floor)
end

local function simulateSimple(abilities, melee, horizon)
	local dots, filler, byName = {}, nil, {}
	for _, ability in ipairs(abilities) do
		local total, instant, duration = value(ability)
		local rate = total / cadence(ability)
		if not ability.debuff and not ability.finisher and total > 0 and duration > 0 and (total - instant) >= instant then
			--two ranks of one spell are one debuff on the target, so only the better of them is ever ticking
			--the cast buys its direct hit as well as its ticks, and both are paid for by the one global
			local entry = { ability = ability, dps = total / duration }
			local already = byName[ability.name]
			if not already then
				dots[#dots + 1] = entry
				byName[ability.name] = entry
			elseif entry.dps > already.dps then
				already.ability, already.dps = ability, entry.dps
			end
		elseif not ability.debuff and not ability.finisher and total > 0 and (not filler or rate > filler.rate) then
			filler = { ability = ability, rate = rate }
		end
	end
	if not filler and #dots == 0 then return nil end

	local spellDps, priority, spent, manaSpentPerSecond = 0, {}, 0, 0
	local opener, loop, sequence = {}, {}, {}
	--the best dot fills the pack first, because a global cooldown spent on a worse one is one the better one never gets
	table.sort(dots, function(a, b) return a.dps > b.dps end)
	for _, entry in ipairs(dots) do
		local share = (entry.ability.gcd or 1.5) / math.max(entry.ability.duration or horizon, 1)
		local copies = dotCopies(entry.ability)
		--you only have so many global cooldowns a second, so a pack takes as many of them as are left
		if share > 0 then copies = math.min(copies, math.max(0, (1 - spent) / share)) end
		--and a global spent on a dot is one the filler does not get, so a copy has to earn more than that
		if filler and entry.dps <= filler.rate * share then copies = 0 end
		if entry.dps > 0 and copies > 0 then
			spellDps = spellDps + entry.dps * copies
			spent = spent + share * copies
			if entry.ability.power == "mana" then
				manaSpentPerSecond = manaSpentPerSecond + (entry.ability.cost or 0) / math.max(entry.ability.duration or horizon, 1) * copies
			end
			local on = math.floor(copies + 0.5)
			priority[#priority + 1] = on >= 2 and string.format("%s (keep up on %d)", entry.ability.name, on) or (entry.ability.name .. " (keep up)")
			local run = { id = entry.ability.id, name = entry.ability.name, count = math.max(1, on), spread = on > 1 }
			opener[#opener + 1] = run
			sequence[#sequence + 1] = run
		end
	end
	if filler then
		spellDps = spellDps + filler.rate * math.max(0, 1 - spent)
		if filler.ability.power == "mana" then
			manaSpentPerSecond = manaSpentPerSecond + (filler.ability.cost or 0) / cadence(filler.ability) * math.max(0, 1 - spent)
		end
		priority[#priority + 1] = filler.ability.name .. " (fill)"
		local run = { id = filler.ability.id, name = filler.ability.name, count = 1 }
		loop[#loop + 1] = run
		sequence[#sequence + 1] = run
	end

	local manaFactor = 1
	if manaSpentPerSecond > 0 and TT.ManaState then
		local state = TT.ManaState()
		if state then
			manaFactor = math.min(1, (state.current / horizon + (state.perSecond or 0)) / manaSpentPerSecond)
			if manaFactor < 1 then priority[#priority + 1] = string.format("mana limits cast uptime to %.0f%%", manaFactor * 100) end
		end
	end
	spellDps = spellDps * manaFactor

	--the filler is what a point of its resource actually buys here, since it is what repeats
	local worth = {}
	if filler and (filler.ability.cost or 0) > 0 and filler.ability.power then
		worth[filler.ability.power] = value(filler.ability) / filler.ability.cost
	end

	return {
		dps = (melee or 0) + spellDps, priority = priority, value = worth,
		model = manaSpentPerSecond > 0 and "mana" or "estimate", manaUptime = manaFactor,
		filler = filler and filler.ability.name, opener = #opener > 0 and opener or nil, loop = loop, sequence = sequence,
	}
end

--the signature of a stretch of casts, so two windows can be told apart by what they actually do
local function signature(casts, first, last)
	local keys = {}
	for index = first, last do keys[#keys + 1] = casts[index].key end
	return table.concat(keys, ",")
end

--the repeating unit of a rotation: the finisher window you spend most of the fight in, or the shortest block that repeats
function TT.FindCycle(casts)
	local n = #casts
	if n == 0 then return nil end

	local marks = {}
	for index = 1, n do
		if casts[index].points then marks[#marks + 1] = index end
	end

	if #marks >= 2 then
		--the window you repeat most is the rotation; the odd one out is the opener or the scramble at the end
		local counts, firstSeen, best = {}, {}, nil
		for slot = 1, #marks - 1 do
			local from, to = marks[slot] + 1, marks[slot + 1]
			local key = signature(casts, from, to)
			counts[key] = (counts[key] or 0) + 1
			if not firstSeen[key] then firstSeen[key] = slot end
			if not best or counts[key] > counts[best] or (counts[key] == counts[best] and firstSeen[key] < firstSeen[best]) then
				best = key
			end
		end
		local slot = firstSeen[best]
		return marks[slot] + 1, marks[slot + 1]
	end

	if #marks == 1 then return 1, marks[1] end

	local bestFirst, bestPeriod, bestCoverage, bestRepeats
	for first = 1, n - 1 do
		for period = 1, math.floor((n - first + 1) / 2) do
			local repeats = 1
			while first + (repeats + 1) * period - 1 <= n do
				local matches = true
				for offset = 0, period - 1 do
					if casts[first + offset].key ~= casts[first + repeats * period + offset].key then matches = false break end
				end
				if not matches then break end
				repeats = repeats + 1
			end
			local coverage = repeats * period
			if repeats > 1 and (not bestCoverage or coverage > bestCoverage
				or coverage == bestCoverage and (first < bestFirst or first == bestFirst and repeats > bestRepeats)) then
				bestFirst, bestPeriod, bestCoverage, bestRepeats = first, period, coverage, repeats
			end
		end
	end
	if bestFirst then return bestFirst, bestFirst + bestPeriod - 1 end

	--nothing repeats inside the fight, so the whole of it is the rotation
	return 1, n
end

--anything that outlasts the cycle is not part of it, so a forty second debuff moves to the opener and off the loop's clock
function TT.SplitCycle(casts)
	local first, stop = TT.FindCycle(casts)
	if not first then return nil end

	--measured to the moment the cycle comes round again, so the energy you wait on is part of what it costs
	local period = stop - first + 1
	local repeated = casts[first + period]
	local startTime, stopTime = casts[first].time, casts[stop].time
	local span
	if repeated and type(repeated.time) == "number" and type(startTime) == "number" then
		span = repeated.time - startTime
	elseif type(stopTime) == "number" and type(casts[stop].step) == "number" and type(startTime) == "number" then
		span = stopTime + casts[stop].step - startTime
	end

	--anything outlasting the window belongs to the opener, measured against the window as it was, not as carrying shrinks it
	local window = span
	local loop, carried = {}, {}
	for index = first, stop do
		local cast = casts[index]
		--a tabbed cast repeats every global even though each one lasts for ages, so it is loop, not opener
		if window and (cast.span or 0) > window and not cast.tab and type(cast.step) == "number" then
			carried[#carried + 1] = cast
			span = span - cast.step
		else
			loop[#loop + 1] = cast
		end
	end

	--keyed on the cast's own key, because a form change is a step in the rotation that may have no spell icon behind it
	local opener, seen = {}, {}
	for index = 1, first - 1 do
		opener[#opener + 1] = casts[index]
		if casts[index].key then seen[casts[index].key] = true end
	end
	for _, cast in ipairs(carried) do
		if not cast.key or not seen[cast.key] then opener[#opener + 1] = cast end
	end

	--an opener that names nothing the loop does not already name is telling you the same thing twice
	local inLoop = {}
	for _, cast in ipairs(loop) do if cast.key then inLoop[cast.key] = true end end
	local novel = false
	for _, cast in ipairs(opener) do
		if not cast.key or not inLoop[cast.key] then novel = true break end
	end
	if not novel then opener = {} end

	return opener, loop, span
end

--consecutive repeats collapse into one entry, so a rotation reads as a short strip rather than a cast log
function TT.Compress(casts, first, last, limit)
	local runs = {}
	limit = limit or SEQUENCE_RUNS
	for index = first or 1, math.min(last or #casts, #casts) do
		local cast = casts[index]
		local previous = runs[#runs]
		if previous and previous.id == cast.id and not cast.points and not previous.points then
			previous.count = previous.count + 1
			--a run of one ability over several mobs is a tab, not the same mob hit again
			if cast.tab then previous.spread = true end
		else
			runs[#runs + 1] = { id = cast.id, name = cast.name, count = 1, points = cast.points, tab = cast.tab }
		end
		if #runs > limit then
			table.remove(runs)
			runs.truncated = true
			break
		end
	end
	return runs
end

--what you can actually press right now: nothing that needs another form, and nothing positional while the mob faces you
--a bar belongs to a form, so a rotation spending rage is a rotation you have to be a bear to run
local POWER_FORM = { energy = "cat", rage = "bear" }

local function matchesSpec(ability)
	local spec = TT.Spec and TT.Spec()
	if not spec or not spec.form then return true end
	if ability.forms then
		for form in pairs(ability.forms) do
			if form:find(spec.form, 1, true) or spec.form:find(form, 1, true) then return true end
		end
		return false
	end
	local required = POWER_FORM[ability.power or ""]
	return not required or required == spec.form
end

local function availableInSpec(ability)
	if not matchesSpec(ability) then return false end
	local immune = TT.BleedImmune and TT.BleedImmune(nil, "target")
	if immune and ability.bleed then return false end
	return not (TT.Tanking() and ability.positional)
end

local function usable(abilities, allowFormChanges)
	local tanking = TT.Tanking()
	--a bleed on something that does not bleed is a wasted global, so it never enters the rotation at all
	local immune = TT.BleedImmune and TT.BleedImmune(nil, "target")
	local kept = {}
	for _, ability in ipairs(abilities) do
		local wrongForm = not allowFormChanges and TT.WrongForm(ability.forms, ability.power)
		if not wrongForm and not (immune and ability.bleed) and not (tanking and ability.positional) then
			kept[#kept + 1] = ability
		end
	end
	return kept
end

--every ability ranked by what a point of its resource buys, with the point where a spender overtakes your filler
function TT.Efficiency()
	local abilities = usable(TT.Abilities())
	if #abilities == 0 then return nil, "no damaging abilities on your visible bars" end

	local _, _, _, filler = classify(abilities)
	local fillerValue = filler and perEnergy(filler) or 0
	local entries = {}

	for _, ability in ipairs(abilities) do
		if not ability.debuff and (ability.cost or 0) > 0 then
			local entry = { name = ability.name, cost = ability.cost, power = ability.power }
			if ability.levels then
				entry.value = perEnergy(ability, MAX_COMBO)
				entry.spender = true
				if filler and perEnergy(ability, MAX_COMBO) > fillerValue then
					entry.breakpoint = comboBreakpoint(ability, filler)
				end
			else
				entry.value = perEnergy(ability)
			end
			if entry.value > 0 then entries[#entries + 1] = entry end
		end
	end

	table.sort(entries, function(a, b) return a.value > b.value end)
	return entries, filler and filler.name
end

--how long the next pull actually lasts: this target if we have one, else what this kind of mob has been taking
function TT.FightLength()
	local measured, bucket = TT.TargetFight()
	local source = "this target"
	if not measured then
		local rolling, confidence = TT.KillTime(bucket)
		measured, source = rolling, confidence and confidence > 0 and "your kills" or nil
	end
	if not measured then return DEFAULT_FIGHT, "no kills measured yet" end
	return math.max(MIN_FIGHT, math.min(MAX_FIGHT, measured)), source
end

--the explorer reads the raw cast list and the names it picked; the panel reads compressed runs, so the live path adapts
local function adaptFull(result)
	if not result then return nil end
	local opener, loop, loopTime = TT.SplitCycle(result.sequence)
	local adapted = {}
	for key, value in pairs(result) do adapted[key] = value end
	adapted.full = result.sequence
	adapted.opener = opener and TT.Compress(opener) or nil
	adapted.loop = loop and TT.Compress(loop) or nil
	adapted.loopTime = loopTime
	adapted.sequence = TT.Compress(result.sequence)
	return adapted
end

--one simulation at one fight length, with an ability optionally taken away, which is how a debuff is priced against itself
local function simulateAt(abilities, horizon, targetCount)
	local previous = simTargets
	simTargets = math.max(1, targetCount or 1)
	local melee = TT.Melee()
	local spec = TT.Spec and TT.Spec()
	local formPower = TT.FormPower and select(1, TT.FormPower())
	local meleeForm = formPower == "rage" or formPower == "energy"
	local meleeDps = (not (spec and spec.caster) or meleeForm) and melee and melee.rate or 0

	--the simple models hold one form's bar at a time, so they are only ever given what this form can actually cast
	local form = currentSimulationForm()
	local inForm, needsShift = {}, false
	for _, ability in ipairs(abilities) do
		if formAllows(ability, form) then inForm[#inForm + 1] = ability else needsShift = true end
	end

	local energyBased, rageBased = false, false
	for _, ability in ipairs(inForm) do
		if ability.power == "energy" then energyBased = true end
		if ability.power == "rage" then rageBased = true end
	end

	local result, why
	if rageBased then result, why = simulateRage(inForm, meleeDps, horizon) end
	if not result and energyBased then result, why = simulateEnergy(inForm, meleeDps, horizon) end
	if not result and not rageBased then result, why = simulateSimple(inForm, meleeDps, horizon) end

	--changing form costs mana, a global and whatever the bar you leave was holding, so it has to beat standing still
	if needsShift then
		local full, fullWhy = simulateVariantFull({ fight = horizon, targets = simTargets }, abilities)
		local shifted = adaptFull(full)
		if shifted and (not result or shifted.dps > result.dps) then result, why = shifted, nil
		elseif not result then why = why or fullWhy end
	end
	if result then result.melee = meleeDps end
	simTargets = previous
	return result, why
end

local function simulate(abilities, horizon)
	return simulateAt(abilities, horizon, TT.Targets())
end

--the fight lengths a debuff is asked about, coarse at the top because nothing changes its mind past a minute
local BREAK_EVEN_STEPS = { 4, 6, 8, 10, 12, 15, 20, 30, 45, 60, 90, 120 }

local worth, worthContext = {}, nil

--what the whole rotation does with and without one spell in it, at the fight you are in and at every length we check
local function debuffStudy(spellID)
	local context = contextKey()
	if worthContext ~= context then worth, worthContext = {}, context end
	if worth[spellID] then return worth[spellID] end

	local abilities = usable(TT.Abilities())
	local without, found = {}, nil
	for _, ability in ipairs(abilities) do
		if ability.id == spellID then found = ability else without[#without + 1] = ability end
	end

	local study = {}
	if not found then
		study.why = "it is not on your visible bars"
	elseif #without == 0 then
		study.why = "it is the only thing on your bars"
	else
		local horizon = TT.FightLength()
		local count = TT.Targets()
		local with, plain = simulateAt(abilities, horizon, count), simulateAt(without, horizon, count)
		if not with or not plain then
			study.why = "the rotation would not build both ways"
		else
			study.delta, study.with, study.without, study.fight = with.dps - plain.dps, with.dps, plain.dps, horizon
			local deltas = {}
			for index, length in ipairs(BREAK_EVEN_STEPS) do
				local a, b = simulateAt(abilities, length, count), simulateAt(without, length, count)
				deltas[index] = (a and b) and (a.dps - b.dps) or nil
			end
			--a break even is where it starts paying and keeps paying, not one length that happened to land well
			for index = #BREAK_EVEN_STEPS, 1, -1 do
				if (deltas[index] or 0) > 0 then study.breakEven = BREAK_EVEN_STEPS[index] else break end
			end
		end
	end
	worth[spellID] = study
	return study
end

--a discount can change which ability you fill with, so it is priced by simulating the rotation it would create
--a rotation the panel draws in place of yours while you hold alt over what would cause it
local preview, previewLabel

function TT.SetPreview(result, label)
	preview, previewLabel = result, label
end

function TT.Preview()
	return preview, previewLabel
end

function TT.CostCutWorth(name, kind, amount)
	local context = contextKey()
	if worthContext ~= context then worth, worthContext = {}, context end
	local key = "cut:" .. name:lower() .. ":" .. kind .. ":" .. amount
	if worth[key] then
		local study = worth[key]
		return study.delta, study.with, study.without, study.fight, study.name, study.filler, study.why, study.result
	end

	local abilities = usable(TT.Abilities())
	local current
	for _, ability in ipairs(abilities) do
		if ability.name:lower() == name:lower() and (kind == "any" or ability.power == kind) then current = ability break end
	end
	if not current and TT.AbilityByName then
		local candidate = TT.AbilityByName(name)
		if candidate and availableInSpec(candidate) and (kind == "any" or candidate.power == kind) then
			current = candidate
			abilities[#abilities + 1] = candidate
		end
	end
	local cheaper, found = {}, nil
	for _, ability in ipairs(abilities) do
		if ability.name:lower() == name:lower() and (kind == "any" or ability.power == kind) then
			found = ability
			local copy = {}
			for field, value in pairs(ability) do copy[field] = value end
			copy.cost = math.max(0, (ability.cost or 0) - amount)
			cheaper[#cheaper + 1] = copy
		else
			cheaper[#cheaper + 1] = ability
		end
	end

	local study = {}
	if not found then
		study.why = "not on your bars in this form"
	else
		study.name = found.name
		local horizon = TT.FightLength()
		local count = TT.Targets()
		local plain, with = simulateAt(abilities, horizon, count), simulateAt(cheaper, horizon, count)
		if not plain or not with then
			study.why = "the rotation would not build both ways"
		else
			study.delta, study.with, study.without, study.fight = with.dps - plain.dps, with.dps, plain.dps, horizon
			--the point of a discount is often that it promotes the ability over whatever you fill with now
			if with.filler == found.name and plain.filler and plain.filler ~= found.name then study.filler = plain.filler end
			--kept whole so the panel can draw the rotation this talent would give you, rather than describe it
			with.fight, with.fightSource, with.targets, with.count = horizon, "preview", count, #abilities
			if with.filler ~= plain.filler or with.dps ~= plain.dps then study.result = with end
		end
	end
	worth[key] = study
	return study.delta, study.with, study.without, study.fight, study.name, study.filler, study.why, study.result
end

function TT.CostCutsWorth(cuts)
	local context = contextKey()
	if worthContext ~= context then worth, worthContext = {}, context end
	local keys = {}
	for _, cut in ipairs(cuts) do keys[#keys + 1] = cut.name:lower() .. ":" .. cut.kind .. ":" .. cut.amount end
	table.sort(keys)
	local key = "cuts:" .. table.concat(keys, "|")
	if worth[key] then
		local study = worth[key]
		return study.delta, study.with, study.without, study.fight, study.result
	end

	local abilities = usable(TT.Abilities())
	local seen = {}
	for _, ability in ipairs(abilities) do seen[ability.name:lower()] = true end
	for _, cut in ipairs(cuts) do
		local name = cut.name:lower()
		if not seen[name] and TT.AbilityByName then
			local candidate = TT.AbilityByName(cut.name)
			if candidate and availableInSpec(candidate) and (cut.kind == "any" or candidate.power == cut.kind) then
				abilities[#abilities + 1] = candidate
				seen[name] = true
			end
		end
	end

	local cheaper = {}
	for _, ability in ipairs(abilities) do
		local copy = {}
		for field, value in pairs(ability) do copy[field] = value end
		for _, cut in ipairs(cuts) do
			if ability.name:lower() == cut.name:lower() and (cut.kind == "any" or ability.power == cut.kind) then
				copy.cost = math.max(0, (copy.cost or 0) - cut.amount)
			end
		end
		cheaper[#cheaper + 1] = copy
	end

	local study = {}
	if #abilities == 0 then
		study.why = "no abilities to simulate in this spec"
	else
		local horizon, count = TT.FightLength(), TT.Targets()
		local plain, with = simulateAt(abilities, horizon, count), simulateAt(cheaper, horizon, count)
		if plain and with then
			study.delta, study.with, study.without, study.fight = with.dps - plain.dps, with.dps, plain.dps, horizon
			with.fight, with.fightSource, with.targets, with.count = horizon, "preview", count, #abilities
			if study.delta ~= 0 then study.result = with end
		else
			study.why = "the rotation would not build both ways"
		end
	end
	worth[key] = study
	return study.delta, study.with, study.without, study.fight, study.result
end

function TT.DebuffWorth(spellID)
	local study = debuffStudy(spellID)
	return study.delta, study.with, study.without, study.fight, study.why
end

--the shortest fight at which casting it starts paying for the global it costs
function TT.DebuffBreakEven(spellID)
	local study = debuffStudy(spellID)
	if not study.delta then return nil, study.why end
	if not study.breakEven then return nil, "it never pays for its global, at any fight we checked" end
	return study.breakEven
end

function TT.Rotation()
	local abilities = usable(TT.Abilities())
	if #abilities == 0 then return nil, "no damaging abilities on your visible bars" end

	local horizon, source = TT.FightLength()
	local result, why = simulate(abilities, horizon)
	if not result then return nil, why or "could not build a rotation from these abilities" end
	result.count = #abilities
	result.targets = TT.Targets()
	result.fight = horizon
	result.fightSource = source
	cached, cachedAt = result, GetTime()
	cachedContext = contextKey()
	attemptedAt, attemptedContext = nil, nil
	return result
end

--tooltips ask for these constantly and a sixty second simulation is not a per draw cost, so a failed one waits too
local function current()
	local context = contextKey()
	if cached and cachedContext ~= context or attemptedAt and attemptedContext ~= context then TT.InvalidateRotation() end
	if cached and (GetTime() - cachedAt) < CACHE_SECONDS then return cached end
	if attemptedAt and (GetTime() - attemptedAt) < CACHE_SECONDS then return nil end
	attemptedAt, attemptedContext = GetTime(), context
	return (TT.Rotation())
end

function TT.Worth()
	local result = current()
	return result and result.value or {}
end

function TT.ResourceValue(kind)
	return TT.Worth()[kind]
end

--what share of the fight a named set of abilities actually accounts for, which is what a damage modifier is worth
function TT.AbilityShare(names)
	local result = current()
	if not result or not result.damageByName or (result.damageTotal or 0) <= 0 then return nil end

	local lowered = {}
	for _, name in ipairs(names) do lowered[name:lower()] = true end

	local counted, seen, found, missing = 0, {}, {}, {}
	for name, damage in pairs(result.damageByName) do
		if lowered[name:lower()] then
			counted = counted + damage
			seen[name:lower()] = true
			found[#found + 1] = name
		end
	end
	table.sort(found)
	for _, name in ipairs(names) do
		if not seen[name:lower()] then missing[#missing + 1] = name end
	end

	return counted / result.damageTotal, found, missing
end

--what share of the simulated damage came from abilities rather than from swings, since a talent naming abilities lifts only those
function TT.AbilityDamageShare()
	local result = current()
	if not result or not result.damageByName or (result.damageTotal or 0) <= 0 then return nil end
	local abilities = 0
	for name, damage in pairs(result.damageByName) do
		if name ~= "Auto Attack" then abilities = abilities + damage end
	end
	return math.min(1, abilities / result.damageTotal)
end

--why the simulation chose what it chose, because a missing finisher looks the same as one that was never on the bars
function TT.ClassifyReport()
	local abilities = TT.Abilities()
	local builders, finishers, dots, filler, debuff = classify(abilities)
	local out = {}
	out[#out + 1] = string.format("%d abilities, %d builders, %d finishers, %d dots", #abilities, #builders, #finishers, #dots)
	out[#out + 1] = string.format("global cooldown %.2fs (%s)", TT.Gcd(),
		TT.db.gcd and "yours, set with /agf gcd" or "assumed vanilla, set it with /agf gcd <n>")
	out[#out + 1] = "filler " .. (filler and string.format("%s at %.2f per energy", filler.name, perEnergy(filler)) or "none, so no rotation")
	out[#out + 1] = "debuff " .. (debuff and debuff.name or "none")

	local fillerValue = filler and perEnergy(filler) or 0
	for _, ability in ipairs(finishers) do
		local at5 = perEnergy(ability, MAX_COMBO)
		out[#out + 1] = string.format("finisher %s: %.2f per energy at 5, cost %d, %s",
			ability.name, at5, ability.cost or 0, at5 > fillerValue and "kept" or "dropped, it loses to the filler")
		local points = {}
		for level = 1, MAX_COMBO do
			if ability.levels and ability.levels[level] then
				points[#points + 1] = string.format("%d:%.2f", level, perEnergy(ability, level))
			end
		end
		out[#out + 1] = "  per point " .. (#points > 0 and table.concat(points, " ") or "no levels parsed, so it has no breakpoint")
	end
	for _, ability in ipairs(dots) do
		local rate = perEnergy(ability)
		out[#out + 1] = string.format("dot %s: %.2f per energy, %s", ability.name, rate, rate > fillerValue and "kept" or "dropped, it loses to the filler")
	end

	local result = current()
	if result then
		out[#out + 1] = string.format("simulated %.0fs (%s), plan: finisher %s at %s points, dot %s",
			result.fight or 0, result.fightSource or "assumed",
			result.plan and result.plan.finisher and result.plan.finisher.name or "none",
			result.plan and result.plan.breakpoint or MAX_COMBO,
			result.plan and result.plan.dot and result.plan.dot.name or "none")
		local pressed = {}
		for name, count in pairs(result.casts or {}) do pressed[#pressed + 1] = string.format("%s x%d", name, count) end
		table.sort(pressed)
		out[#out + 1] = "pressed: " .. table.concat(pressed, ", ")
	end
	return out
end

--an aoe ability is never in the single target rotation, so it is priced in its own pass against a pack this size
local AOE_TARGETS = 3

--spamming one ability as fast as its resource allows, which is the only honest reading of an aoe button
function TT.AoeValue(names)
	local wanted = {}
	for _, name in ipairs(names) do wanted[name:lower()] = true end

	local best
	for _, ability in ipairs(TT.Abilities()) do
		if ability.aoe and wanted[ability.name:lower()] then
			local perTarget = ((ability.instant or 0) + (ability.over or 0)) * (ability.scale or 1)
			local targets = math.min(AOE_TARGETS, ability.maxTargets or AOE_TARGETS)
			local regen = ability.power == "rage" and (current() or {}).resourcePerSecond or ENERGY_PER_SEC
			local step = math.max(ability.gcd or 1, ability.cast or 0)
			if (ability.cost or 0) > 0 and regen and regen > 0 then step = math.max(step, ability.cost / regen) end
			local dps = perTarget * targets / step
			if perTarget > 0 and (not best or dps > best.dps) then
				best = { name = ability.name, dps = dps, targets = targets, perCast = perTarget * targets, step = step }
			end
		end
	end
	return best
end

function TT.AoeTargets()
	return AOE_TARGETS
end

--how often the simulated fight actually presses one ability, which is what a per cast saving is multiplied by
function TT.AbilityCasts(name)
	local result = current()
	if not result or not result.casts then return nil end
	for cast, count in pairs(result.casts) do
		if cast:lower() == name:lower() then return count, result.fight end
	end
	return nil, result.fight
end

--the same choice the simulator makes sixty times a fight, made once against the state you are actually in
function TT.NextCast()
	local result = current()
	local plan = result and result.plan
	if not plan or not plan.filler then return nil, "no rotation yet" end
	--the simulation opens with a form change when one is worth paying for, and that is as much the next press as a spell
	local first = result.full and result.full[1]
	if first and first.shift then
		return { id = first.id, name = first.name, form = first.shift }, first.name, 0
	end

	local power, resourceKind = TT.FormResource()
	power = power or 0
	local combo = TT.ComboPoints()
	local why = {}

	local function pick(ability, reason)
		why[#why + 1] = reason
		return ability
	end

	local choice
	--points at the cap are lost by building another one, so a full bar outranks keeping a dot up
	if plan.finisher and combo >= MAX_COMBO then
		choice = pick(plan.finisher, combo .. " points banked")
	elseif plan.debuff and TT.AuraUp(plan.debuff.id) ~= true then
		choice = pick(plan.debuff, plan.debuff.name .. " is off the target")
	elseif plan.dot and TT.AuraUp(plan.dot.id) ~= true then
		choice = pick(plan.dot, plan.dot.name .. " is off the target")
	elseif plan.finisher and combo >= (plan.breakpoint or MAX_COMBO) then
		choice = pick(plan.finisher, combo .. " points banked")
	elseif plan.finisher and plan.breakpoint and combo >= plan.breakpoint and (result.fight or 0) <= (plan.finisher.gcd or 1) * 2 then
		choice = pick(plan.finisher, "the fight ends before five points")
	else
		choice = pick(plan.filler, combo .. " points, building")
	end

	--an ability you cannot pay for is not the next thing you press, whatever the priority says
	local cost = choice.cost or 0
	if cost > power then
		--if we're short on energy and have a conversion ability, suggest it instead
		if plan.conversion and plan.conversion.conversion then
			local manaState = TT.ManaState and TT.ManaState()
			local manaCost = plan.conversion.cost or 0
			if manaState and (manaState.current or 0) >= manaCost then
				return plan.conversion, plan.conversion.name .. " for +" .. (plan.conversion.conversion.amount or 0) .. " " .. (plan.conversion.conversion.kind or "energy"), 0
			end
		end
		local regen = resourceKind == "rage" and result.resourcePerSecond or ENERGY_PER_SEC
		local wait = (cost - power) / regen
		why[#why + 1] = string.format("%.0f short, %.1fs away", cost - power, wait)
		return choice, table.concat(why, ", "), wait
	end

	why[#why + 1] = string.format("%.0f %s", power, choice.power or "resource")
	return choice, table.concat(why, ", "), 0
end

--what every percentage of your damage is a percentage of
function TT.RotationDps()
	local result = current()
	return result and result.dps or nil
end

function TT.InvalidateRotation()
	cached, cachedAt, cachedContext, attemptedAt, attemptedContext = nil, 0, nil, nil, nil
end

local function simulateVariant(abilities, config)
	local builders, finishers, dots, filler, debuff = classify(abilities)
	if not filler then return nil end
	local finisher = pickBest(finishers)
	local fillerValue = perEnergy(filler)
	local dot = config.keepDot and pickBest(dots) or nil
	if dot and perEnergy(dot) <= fillerValue * (config.dotThreshold or 1) then dot = nil end
	local breakpoint = config.breakpoint or MAX_COMBO
	local fight = config.fight or 15
	local casts, sequence, time, damage = {}, {}, 0, 0
	local combo, energy, lastFinisher = 0, ENERGY_MAX, 0
	local expiry = {}
	while time < fight do
		local gcd = filler.gcd or 1.5
		local regen = ENERGY_PER_SEC * gcd
		energy = math.min(ENERGY_MAX, energy + regen)
		local choice, cost = nil, 0
		if finisher and combo >= breakpoint then
			choice, cost = finisher, finisher.cost or 0
			local total = value(finisher, combo)
			damage = damage + total
			combo = 0
			lastFinisher = time
		elseif dot and freeSlot(expiry, dot, time) then
			choice, cost = dot, dot.cost or 0
			local slot = freeSlot(expiry, dot, time)
			expiry[dot.name .. "#" .. slot] = time + (dot.duration or 0)
			damage = damage + value(dot)
		elseif energy >= (filler.cost or 0) then
			choice, cost = filler, filler.cost or 0
			damage = damage + value(filler)
			combo = math.min(MAX_COMBO, combo + 1)
		end
		if choice then
			energy = energy - cost
			casts[choice.name] = (casts[choice.name] or 0) + 1
			sequence[#sequence + 1] = { name = choice.name, id = choice.id }
		end
		time = time + gcd
	end
	return { dps = damage / fight, config = config, casts = casts, sequence = sequence, fight = fight }
end

function TT.Simulate(duration)
	local abilities = usable(TT.Abilities())
	if #abilities == 0 then return nil, "no damaging abilities on your bars" end
	local results = {}
	local variants = {
		{ keepDot = false, breakpoint = 5, label = "no dot, 5cp" },
		{ keepDot = true, breakpoint = 5, label = "with dot, 5cp" },
		{ keepDot = true, breakpoint = 4, label = "with dot, 4cp" },
		{ keepDot = true, breakpoint = 5, dotThreshold = 0.8, label = "dot if 80%+ of filler" },
	}
	for _, config in ipairs(variants) do
		config.fight = duration or 15
		local result = simulateVariant(abilities, config)
		if result then results[#results + 1] = result end
	end
	table.sort(results, function(a, b) return a.dps > b.dps end)
	if TT.char then
		TT.char.simulations = TT.char.simulations or {}
		TT.char.simulations[contextKey()] = { results = results, at = GetTime and GetTime() or 0 }
	end
	return results
end

function TT.SimulationReport()
	local results, err = TT.Simulate()
	if not results then return { err or "simulation failed" } end
	local lines = {}
	lines[#lines + 1] = string.format("simulated %d variants over %.0fs:", #results, results[1] and results[1].fight or 0)
	for i, r in ipairs(results) do
		local mark = i == 1 and "|cff40ff40best|r " or ""
		lines[#lines + 1] = string.format("  %s%.0f dps: %s", mark, r.dps, r.config.label)
	end
	return lines
end

local function findByName(list, name)
	if not name or not list then return nil end
	for _, item in ipairs(list) do
		if item.name == name or tostring(item.id) == tostring(name) then return item end
	end
	return nil
end

--every form an ability can be cast in, as a set, because one listing cat and bear is castable in either
--and picking whichever key pairs reached first is how a cat ability came back as a bear one
function simulationForm(ability)
	local allowed
	for form in pairs(ability.forms or {}) do
		local name = form:lower()
		local key = name:find("cat", 1, true) and "cat"
			or name:find("bear", 1, true) and "bear"
			or name:find("moonkin", 1, true) and "caster" or nil
		if key then
			allowed = allowed or {}
			allowed[key] = true
		end
	end
	if allowed then return allowed end
	if not UnitClass then return nil end
	local _, class = UnitClass("player")
	if class ~= "DRUID" then return nil end
	--spending a form's own bar proves the form, and a mana spell is a caster spell unless it is one of the few
	--the client lets you cast anywhere, which is a thing we observe rather than assume
	if ability.power == "energy" then return { cat = true }
	elseif ability.power == "rage" then return { bear = true }
	elseif ability.power == "mana" and not ability.anyForm then return { caster = true } end
	return nil
end

function TT.SimulationForms(ability)
	return simulationForm(ability)
end

--no set at all means the ability names no form, so every form can cast it
function formAllows(ability, form, allowedForms)
	if allowedForms and allowedForms[form] ~= true then return false end
	local allowed = simulationForm(ability)
	return not allowed or allowed[form] == true
end

--the one form to shift into for an ability that allows several, preferring the one you are already standing in
function shiftTargetForm(ability, currentForm, allowedForms)
	local allowed = simulationForm(ability)
	if not allowed then return currentForm end
	if currentForm and allowed[currentForm] and (not allowedForms or allowedForms[currentForm]) then return currentForm end
	for _, form in ipairs(FORM_ORDER) do
		if allowed[form] and (not allowedForms or allowedForms[form]) then return form end
	end
	return currentForm
end

--standing in no form is standing in caster form, which is the distinction the rotation used to lose
function currentSimulationForm()
	local form = TT.CurrentForm and TT.CurrentForm()
	if not form then return "caster" end
	if form:find("cat", 1, true) then return "cat"
	elseif form:find("bear", 1, true) then return "bear"
	elseif form:find("moonkin", 1, true) then return "caster" end
	return nil
end

local function profileMatches(ability, profileForm)
	if not ability.profileForm then return true end
	local allowed = simulationForm(ability)
	if allowed then return allowed[ability.profileForm] == true end
	return not profileForm or ability.profileForm == profileForm
end

local function profiledAbilities(abilities, profileForm)
	local out = {}
	for _, ability in ipairs(abilities) do
		if profileMatches(ability, profileForm) then out[#out + 1] = ability end
	end
	return out
end

--the full simulation, including form changes and resource conversions, and what the live rotation runs on
function simulateVariantFull(config, abilityPool)
	config = config or {}
	local previous = simTargets
	simTargets = math.max(1, config.targets or 1)
	local abilities = usable(abilityPool or (TT.AllAbilities and TT.AllAbilities() or TT.Abilities()), true)
	local allowedForms = config.allowedForms
	if allowedForms then
		local filtered = {}
		for _, ability in ipairs(abilities) do
			local abilityForms = simulationForm(ability)
			local permitted
			if not abilityForms then
				permitted = true
			else
				local forms = {}
				for form in pairs(allowedForms) do
					if abilityForms[form] then forms[form] = true end
				end
				if next(forms) then
					local restricted = {}
					for key, value in pairs(ability) do restricted[key] = value end
					restricted.forms = forms
					ability = restricted
					permitted = true
				end
			end
			if permitted then filtered[#filtered + 1] = ability end
		end
		abilities = filtered
	end
	local activeProfileForm = TT.FormProfileKey and TT.FormProfileKey()
	local profileForm = config.startForm or currentSimulationForm() or activeProfileForm
	abilities = profiledAbilities(abilities, profileForm)
	if #abilities == 0 then
		simTargets = previous
		return nil
	end

	local builders, finishers, dots, filler, debuff = classify(abilities)
	local selectedFiller = config.filler and findByName(builders, config.filler) or nil
	filler = selectedFiller and not selectedFiller.openerOnly and selectedFiller or filler
	if not filler then
		simTargets = previous
		return nil
	end

	local fight = config.fight or 15
	local targets = config.targets or 1
	local breakpoint = config.breakpoint or MAX_COMBO
	local dotThreshold = config.dotThreshold or 1

	local finisher
	if config.finisher ~= false then finisher = config.finisher and findByName(finishers, config.finisher) or pickBest(finishers) end
	local fillerValue = perEnergy(filler)
	local dot
	if config.dot ~= false then dot = config.dot and findByName(dots, config.dot) or pickBest(dots) end
	if dot and perEnergy(dot) <= fillerValue * dotThreshold then dot = nil end

	local opener = config.opener and findByName(builders, config.opener) or nil
	if opener and opener.requiresAttackingTarget and not config.targetAttacking then opener = nil end
	local conversion = config.conversion and findByName(abilities, config.conversion) or nil

	local casts, sequence, time, damage, spent = {}, {}, 0, 0, 0
	local byName, damageBy, spentBy = {}, {}, {}
	local comboSpent, finisherDamage = 0, 0
	local combo, energy = 0, 0
	local onTarget = 1
	local rage, mana = 0, math.huge
	local manaState = TT.ManaState and TT.ManaState()
	local manaPoolBonus = config.manaPoolBonus or 0
	if manaState then
		mana = math.max(0, math.min(manaState.max + manaPoolBonus, manaState.current + manaPoolBonus))
	end
	local manaRegen = manaState and manaState.perSecond or 0
	local manaRegenBonus = config.manaRegenBonus or 0
	local manaRegenReady = math.max(0, FIVE_SECOND_RULE - (manaState and manaState.paused or FIVE_SECOND_RULE))
	local rageRates, rageSwingSets = {}, {}
	local meleeRates = {}
	local fallbackRageRate, fallbackRageSwings = ragePerSecond()
	if TT.FormStats and TT.WithStats then
		for _, form in ipairs({ "cat", "bear", "caster" }) do
			local stats = TT.FormStats(form)
			if stats then
				local data = TT.WithStats(stats, function()
					local rate, swings = ragePerSecond()
					return { rate = rate, swings = swings }
				end)
				rageRates[form], rageSwingSets[form] = data.rate, data.swings
				local melee = TT.WithStats(stats, TT.Melee)
				meleeRates[form] = melee and melee.rate or 0
			end
		end
	end
	--a rage rotation modelled on weapon damage we do not trust is not a rotation, the same refusal the rage model makes
	if filler.power == "rage" and (rageRates.bear or 0) <= 0 and fallbackRageRate <= 0 then
		simTargets = previous
		return nil, "waiting for valid weapon damage to model Rage generation"
	end
	local _, class = UnitClass("player")
	--without a captured profile for the form we shift into, its swing is the one we can measure, never nothing
	local baseMelee = TT.Melee and TT.Melee()
	baseMelee = baseMelee and baseMelee.rate or 0
	local currentForm = config.startForm or currentSimulationForm() or activeProfileForm or shiftTargetForm(filler, nil, allowedForms)
	if currentForm and not meleeRates[currentForm] and TT.Melee then
		local melee = TT.Melee()
		meleeRates[currentForm] = melee and melee.rate or 0
	end
	local rageSwingStates
	local function setForm(form)
		currentForm = form
		rageSwingStates = nil
		if form == "bear" or class ~= "DRUID" and filler.power == "rage" then
			rageSwingStates = {}
			for _, swing in ipairs(rageSwingSets[form] or fallbackRageSwings) do
				if swing.speed > 0 then
					rageSwingStates[#rageSwingStates + 1] = { rage = swing.rage, speed = swing.speed, at = time + swing.speed }
				end
			end
		end
	end
	setForm(currentForm)
	if currentForm == "cat" or class ~= "DRUID" and filler.power == "energy" then energy = ENERGY_MAX end
	local shiftCost = TT.ShiftCost and (TT.ShiftCost() or 0) or 0
	local expiry = {}
	local usedOpener = false
	local nextConversionAt = 0
	local guard = 0
	local multiplier = 1 --an armour debuff lifts everything cast after it, so damage is recorded through it
	--a builder with no stated award still awards a point, which is the rate the tuned models count in
	local perBuilder = TT.ComboPerBuilder and TT.ComboPerBuilder() or 1
	local function advance(target)
		while time < target do
			local finish = target
			for _, swing in ipairs(rageSwingStates or {}) do if swing.at < finish then finish = swing.at end end
			local elapsed = finish - time
			local melee = (currentForm == "cat" or currentForm == "bear") and (meleeRates[currentForm] or baseMelee) or 0
			damage = damage + melee * math.max(0, math.min(finish, fight) - time)
			if currentForm == "cat" or class ~= "DRUID" and filler.power == "energy" then
				energy = math.min(ENERGY_MAX, energy + ENERGY_PER_SEC * elapsed)
			end
			local regenStart = math.max(time, manaRegenReady)
			mana = math.min(manaState and (manaState.max + manaPoolBonus) or math.huge,
				mana + math.max(0, finish - regenStart) * (manaRegen + manaRegenBonus))
			time = finish
			for _, swing in ipairs(rageSwingStates or {}) do
				if swing.at <= time then
					rage = math.min(ENERGY_MAX, rage + swing.rage)
					swing.at = swing.at + swing.speed
				end
			end
		end
	end
	local function canPay(ability)
		local cost = ability.cost or 0
		if not formAllows(ability, currentForm, allowedForms) then
			if ability.power == "energy" and conversion and time >= nextConversionAt
				and mana >= shiftCost + (conversion.cost or 0) and energy < cost then return false end
			return mana >= shiftCost + (ability.power == "mana" and cost or 0)
		end
		if ability.power == "energy" then return energy >= cost
		elseif ability.power == "rage" then return rage >= cost
		elseif ability.power == "mana" then return mana >= cost end
		return true
	end
	local function pay(ability)
		local cost = ability.cost or 0
		if ability.power == "energy" then energy = energy - cost
		elseif ability.power == "rage" then rage = rage - cost
		elseif ability.power == "mana" then mana = mana - cost end
		if ability.power and cost > 0 then spentBy[ability.power] = (spentBy[ability.power] or 0) + cost end
		return cost
	end
	--damage is kept per ability name and per resource, so a talent naming one can be priced off what it really did
	local function record(ability, amount)
		amount = amount * multiplier
		damage = damage + amount
		byName[ability.name] = (byName[ability.name] or 0) + amount
		if ability.power then damageBy[ability.power] = (damageBy[ability.power] or 0) + amount end
	end
	local function realizedDamage(ability, points, at)
		local total, instant, duration = value(ability, points)
		if duration <= 0 then return total end
		local over = total - instant
		return instant + over * math.min(1, math.max(0, fight - at) / duration)
	end

	while time < fight do
		guard = guard + 1
		if guard > 2000 then break end

		local gcd = filler.gcd or 1.5

		local choice

		local slot = dot and freeSlot(expiry, dot, time, config.dotTargetLimit) or nil
		local dotWorth = slot and (fight - time) >= (dot.duration or 0) * 0.5
		--an armour debuff pays for everything after it, so it goes up before anything is spent through it
		if debuff and (expiry[debuff.name] or 0) <= time and canPay(debuff) then
			choice = debuff
		elseif opener and not usedOpener and canPay(opener) then
			choice = opener
		elseif finisher and combo >= breakpoint and canPay(finisher) then
			choice = finisher
		elseif finisher and combo >= breakpoint then
			--at the breakpoint you wait for the finisher: spending the bar on another builder is how it never lands
			choice = nil
		elseif slot and dotWorth and canPay(dot) then
			choice = dot
		elseif conversion and time >= nextConversionAt and canPay(conversion)
			and ((conversion.conversion.kind == "energy" and energy <= ENERGY_MAX - conversion.conversion.amount)
				or (conversion.conversion.kind == "rage" and rage <= ENERGY_MAX - conversion.conversion.amount)) then
			choice = conversion
		elseif canPay(filler) then
			choice = filler
		end

		if choice and not formAllows(choice, currentForm, allowedForms)
			and shiftTargetForm(choice, currentForm, allowedForms) == "caster" then
			if currentForm == "cat" then energy, combo = 0, 0
			elseif currentForm == "bear" then rage = 0 end
			setForm("caster")
		end

		if choice then
			if not formAllows(choice, currentForm, allowedForms) then
				local target = shiftTargetForm(choice, currentForm, allowedForms)
				if mana < shiftCost then
					advance(time + gcd)
				else
					local started, leaving = time, currentForm
					local shiftDuration = math.max(gcd, 1.5)
					mana = mana - shiftCost
					spent = spent + shiftCost
					spentBy.mana = (spentBy.mana or 0) + shiftCost
					manaRegenReady = time + FIVE_SECOND_RULE
					advance(time + shiftDuration)
					if currentForm == "cat" then energy, combo = 0, 0
					elseif currentForm == "bear" then rage = 0 end
					setForm(target)
					--you leave a form by pressing its own button again, so a shift back to caster draws the form you are in
					local formID, formName
					if TT.FormByName then
						if target == "caster" then
							local id, name = TT.FormByName(leaving)
							formID, formName = id, name and ("Cancel " .. name) or nil
						else
							formID, formName = TT.FormByName(target)
						end
					end
					local label = formName or (target == "caster" and "Cancel form" or ("Shift to " .. target))
					sequence[#sequence + 1] = {
						name = label, id = formID, target = onTarget, shift = target,
						time = started, gcd = shiftDuration, step = shiftDuration, key = "shift:" .. target,
					}
					casts[label] = (casts[label] or 0) + 1
				end
			else
				spent = spent + pay(choice)
				if choice.power == "mana" and (choice.cost or 0) > 0 then
					manaRegenReady = time + FIVE_SECOND_RULE
				end
				casts[choice.name] = (casts[choice.name] or 0) + 1
				if choice == dot then onTarget = slot end
				local previous = sequence[#sequence]
				--a spend at three points is a different step from a spend at five, so the points are part of its identity
				local points = choice == finisher and combo or nil
				sequence[#sequence + 1] = {
					name = choice.name, id = choice.id, target = onTarget, form = currentForm,
					tab = previous ~= nil and previous.target ~= onTarget, time = time, points = points,
					key = choice.id .. ":" .. tostring(points) .. ":" .. onTarget,
				}
				if choice == debuff then
					multiplier = 1 + choice.debuff.gain
					expiry[choice.name] = time + choice.debuff.duration
				elseif choice == conversion then
					if conversion.conversion.kind == "energy" then
						energy = math.min(ENERGY_MAX, energy + conversion.conversion.amount)
					else
						rage = math.min(ENERGY_MAX, rage + conversion.conversion.amount)
					end
					nextConversionAt = time + math.max(conversion.cooldown or 0, choice.gcd or gcd)
				elseif choice == opener then
					usedOpener = true
					record(choice, realizedDamage(choice, nil, time))
					combo = math.min(MAX_COMBO, combo + (choice.awards or perBuilder))
				elseif choice == finisher then
					local landed = realizedDamage(choice, combo, time) * multiplier
					record(choice, realizedDamage(choice, combo, time))
					comboSpent = comboSpent + combo
					finisherDamage = finisherDamage + landed
					combo = 0
				elseif choice == dot then
					expiry[dot.name .. "#" .. slot] = time + (dot.duration or 0)
					record(choice, realizedDamage(choice, nil, time))
				else
					record(choice, realizedDamage(choice, nil, time))
					combo = math.min(MAX_COMBO, combo + (choice.awards or perBuilder))
				end
				local step = math.max(choice.gcd or gcd, choice.cast or choice.castTime or 0, STEP)
				sequence[#sequence].gcd = step
				sequence[#sequence].step = step
				sequence[#sequence].span = choice.debuff and choice.debuff.duration or choice.duration or 0
				advance(time + step)
			end
		else
			advance(time + gcd)
		end
	end

	simTargets = previous

	local efficiency = spent > 0 and damage / spent or 0
	local worth = {}
	for power, outlay in pairs(spentBy) do
		if outlay > 0 and (damageBy[power] or 0) > 0 then worth[power] = damageBy[power] / outlay end
	end
	if comboSpent > 0 then worth.combo = finisherDamage / comboSpent end
	local priority = {}
	if debuff then priority[#priority + 1] = debuff.name .. " (keep up)" end
	if dot then priority[#priority + 1] = dot.name .. " (keep up)" end
	if finisher then priority[#priority + 1] = string.format("%s (spend at %d)", finisher.name, breakpoint) end
	priority[#priority + 1] = filler.name .. " (fill)"
	local model = filler.power == "rage" and "rage" or filler.power == "energy" and "energy"
		or filler.power == "mana" and "mana" or "estimate"
	local label = {}
	if opener then label[#label + 1] = "open " .. opener.name end
	label[#label + 1] = filler.name
	if finisher then label[#label + 1] = finisher.name end
	if conversion then label[#label + 1] = conversion.name end
	label[#label + 1] = breakpoint .. "cp"
	if dot then label[#label + 1] = "dot" end
	if config.startForm then label[#label + 1] = config.startForm end
	label[#label + 1] = targets .. "t"
	label[#label + 1] = fight .. "s"

	return {
		dps = damage / fight,
		efficiency = efficiency,
		spent = spent,
		manaSpent = spentBy.mana or 0,
		config = config,
		casts = casts,
		sequence = sequence,
		targetedSequence = true,
		fight = fight,
		targets = targets,
		label = table.concat(label, ", "),
		opener = opener and opener.name or nil,
		filler = filler.name,
		finisher = finisher and finisher.name or nil,
		conversion = conversion and conversion.name or nil,
		breakpoint = breakpoint,
		hasDot = dot ~= nil,
		--what the live call, the tooltips and the resource pricing read, so this can stand in for the simpler models
		damageByName = byName,
		damageTotal = damage,
		value = worth,
		priority = priority,
		model = model,
		resourcePerSecond = model == "rage" and (rageRates.bear or fallbackRageRate) or ENERGY_PER_SEC,
		startForm = config.startForm or currentSimulationForm(),
		plan = { debuff = debuff, dot = dot, filler = filler, finisher = finisher,
			breakpoint = breakpoint, conversion = conversion },
	}
end

function TT.SimulateVariantFull(config, abilityPool)
	config = config or {}
	local targets = math.max(1, config.targets or 1)
	local best
	if config.dot ~= nil then
		best = simulateVariantFull(config, abilityPool)
	elseif config.dot == nil then
		local noDot = {}
		for key, value in pairs(config) do noDot[key] = value end
		noDot.dot = false
		best = simulateVariantFull(noDot, abilityPool)
		for limit = 1, targets do
			local variant = {}
			for key, value in pairs(config) do variant[key] = value end
			variant.dot = nil
			variant.dotTargetLimit = limit
			local result = simulateVariantFull(variant, abilityPool)
			if result and (not best or result.dps > best.dps) then
				result.config = config
				best = result
			end
		end
	end
	return best
end

local activeCooldownAbilities

function TT.CooldownCutWorth(name, amount)
	local context = contextKey()
	if worthContext ~= context then worth, worthContext = {}, context end
	local key = "cooldown:" .. name:lower() .. ":" .. amount
	if worth[key] then
		local study = worth[key]
		return study.delta, study.with, study.without, study.fight, study.name, study.why, study.result
	end

	local abilities = TT.Abilities()
	local current
	for _, ability in ipairs(abilities) do
		if ability.name:lower() == name:lower() and ability.conversion then current = ability break end
	end
	if not current and TT.AbilityByName then
		local candidate = TT.AbilityByName(name)
		if candidate and candidate.conversion then
			current = candidate
			abilities[#abilities + 1] = candidate
		end
	end
	if not current and TT.AllAbilities then
		abilities = TT.AllAbilities()
		for _, ability in ipairs(abilities) do
			if ability.name:lower() == name:lower() and ability.conversion then current = ability break end
		end
	end
	abilities = activeCooldownAbilities(abilities)
	current = nil
	for _, ability in ipairs(abilities) do
		if ability.name:lower() == name:lower() and ability.conversion then current = ability break end
	end

	local study = {}
	if not current then
		study.why = "not available in the current form"
	else
		study.name = current.name
		local cooldown = current.cooldown or 0
		local gcd = current.gcd or 1.5
		if cooldown <= gcd then
			study.why = "its cooldown is already limited by the global cooldown"
		else
			local faster = {}
			for _, ability in ipairs(abilities) do
				if ability == current then
					local copy = {}
					for field, value in pairs(ability) do copy[field] = value end
					copy.cooldown = math.max(gcd, cooldown - amount)
					faster[#faster + 1] = copy
				else
					faster[#faster + 1] = ability
				end
			end
			local fight = TT.FightLength()
			local config = { fight = fight, targets = TT.Targets(), conversion = current.name,
				startForm = currentSimulationForm() }
			local plain = TT.SimulateVariantFull(config, abilities)
			local with = TT.SimulateVariantFull(config, faster)
			if not plain or not with then
				study.why = "the rotation would not build both ways"
			else
				study.delta, study.with, study.without, study.fight = with.dps - plain.dps, with.dps, plain.dps, fight
				if study.delta ~= 0 then study.result = with end
			end
		end
	end
	worth[key] = study
	return study.delta, study.with, study.without, study.fight, study.name, study.why, study.result
end

local spiritWorthCache, spiritWorthContext = {}, nil
local manaPoolWorthCache, manaPoolWorthContext = {}, nil

activeCooldownAbilities = function(abilities)
	local cuts = TT.CooldownCuts and TT.CooldownCuts() or {}
	if not next(cuts) then return abilities end
	local adjusted = {}
	for _, ability in ipairs(abilities) do
		local amount = cuts[ability.name:lower()]
		if amount and not ability.talentCooldownApplied and (ability.cooldown or 0) > 0 then
			local copy = {}
			for field, value in pairs(ability) do copy[field] = value end
			copy.cooldown = math.max(ability.gcd or 1.5, ability.cooldown - amount)
			copy.talentCooldownApplied = true
			adjusted[#adjusted + 1] = copy
		else
			adjusted[#adjusted + 1] = ability
		end
	end
	return adjusted
end

local function manaValueSimulations(config, bonusKey, bonus)
	local abilities = activeCooldownAbilities(TT.Abilities())
	local conversion
	for _, ability in ipairs(abilities) do
		if ability.conversion then conversion = ability break end
	end
	if not conversion and TT.AllAbilities then
		abilities = activeCooldownAbilities(TT.AllAbilities())
		for _, ability in ipairs(abilities) do
			if ability.conversion then conversion = ability break end
		end
	end

	if conversion then config.conversion = conversion.name end
	local plain = TT.SimulateVariantFull(config, abilities)
	config[bonusKey] = bonus
	local with = TT.SimulateVariantFull(config, abilities)
	return plain, with, conversion
end

function TT.SpiritWorth(spirit)
	if not TT.ManaFromSpirit then return nil end
	local fight = TT.FightLength()
	local mana = TT.ManaFromSpirit(spirit, fight)
	if not mana then return nil end
	local state = TT.ManaState and TT.ManaState() or nil
	local context = table.concat({ contextKey(), spirit, fight, state and state.current or "",
		state and state.max or "", state and state.perSecond or "", state and state.paused or "" }, ":")
	if spiritWorthContext ~= context then spiritWorthCache, spiritWorthContext = {}, context end
	if spiritWorthCache[spirit] then
		local study = spiritWorthCache[spirit]
		return study.damage, study.mana, study.spent, study.fight, study.conversion
	end

	local study = { mana = mana, fight = fight }
	local rate = TT.ManaFromSpirit(spirit, 2) / 2
	local config = { fight = fight, targets = TT.Targets(), startForm = currentSimulationForm() }
	local plain, with, conversion = manaValueSimulations(config, "manaRegenBonus", rate)
	if plain and with then
		study.damage = with.damageTotal - plain.damageTotal
		study.spent = math.max(0, (with.manaSpent or 0) - (plain.manaSpent or 0))
		study.conversion = conversion and conversion.name or "mana rotation"
	end
	spiritWorthCache[spirit] = study
	return study.damage, study.mana, study.spent, study.fight, study.conversion
end

function TT.ManaPoolWorth(mana)
	if not mana or mana == 0 then return nil end
	local fight = TT.FightLength()
	local state = TT.ManaState and TT.ManaState() or nil
	if not state then return nil, "no readable mana pool" end
	local context = table.concat({ contextKey(), mana, fight, state.current or "", state.max or "",
		state.perSecond or "", state.paused or "" }, ":")
	if manaPoolWorthContext ~= context then
		manaPoolWorthCache, manaPoolWorthContext = {}, context
	end
	if manaPoolWorthCache[mana] ~= nil then return manaPoolWorthCache[mana] end

	local config = { fight = fight, targets = TT.Targets(), startForm = currentSimulationForm() }
	local plain, with = manaValueSimulations(config, "manaPoolBonus", mana)
	local damage = plain and with and (with.damageTotal - plain.damageTotal) or nil
	manaPoolWorthCache[mana] = damage
	return damage, damage == nil and "the rotation could not price extra mana" or nil
end

--list available choices for the explorer UI
function TT.SimulationChoices()
	local all = TT.AllAbilities and TT.AllAbilities() or TT.Abilities()
	if TT.FormProfileKeys and TT.AllAbilitiesForForm then
		local seenProfiles = {}
		for _, ability in ipairs(all) do
			seenProfiles[tostring(ability.id) .. ":" .. tostring(ability.profileForm)] = true
		end
		for _, form in ipairs(TT.FormProfileKeys()) do
			for _, ability in ipairs(TT.AllAbilitiesForForm(form) or {}) do
				local key = tostring(ability.id) .. ":" .. tostring(ability.profileForm)
				if not seenProfiles[key] then
					seenProfiles[key] = true
					all[#all + 1] = ability
				end
			end
		end
	end
	all = profiledAbilities(all)
	local abilities = usable(all, true)
	local builders, finishers, dots, filler, debuff, conversions, cooldowns = classify(abilities)
	local rawDebuff, rawConversions, rawCooldowns = nil, {}, {}
	for _, ability in ipairs(all) do
		if ability.conversion then
			rawConversions[#rawConversions + 1] = ability
		elseif ability.debuff then
			if not rawDebuff or ability.debuff.gain > rawDebuff.debuff.gain then rawDebuff = ability end
		elseif ability.resourceGrant or ability.enemyApReduction then
			rawCooldowns[#rawCooldowns + 1] = ability
		end
	end
	local heals, controls = {}, {}
	for _, ability in ipairs(all) do
		if ability.heal then heals[#heals + 1] = ability end
		if ability.control or ability.taunt then controls[#controls + 1] = ability end
	end
	local forms, seenForms = {}, {}
	for _, ability in ipairs(abilities) do
		for form in pairs(simulationForm(ability) or {}) do
			if not seenForms[form] then
				seenForms[form] = true
				forms[#forms + 1] = form
			end
		end
	end
	local currentForm = currentSimulationForm()
	if currentForm and not seenForms[currentForm] then forms[#forms + 1] = currentForm end
	return {
		abilities = abilities,
		openers = builders,
		finishers = finishers,
		dots = dots,
		filler = filler,
		heals = heals,
		controls = controls,
		forms = forms,
		utility = rawDebuff or debuff,
		conversions = #rawConversions > 0 and rawConversions or conversions,
		cooldowns = #rawCooldowns > 0 and rawCooldowns or cooldowns,
	}
end
