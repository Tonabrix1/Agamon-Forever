local ADDON, TT = ...

local ENERGY_PER_SEC = 10
--vanilla's numbers, used only until the client has shown us its own
local MELEE_GCD = 1.0
local SPELL_GCD = 1.5
local MAX_TARGETS = 5 --fallback when the tooltip does not say how many it hits
local MIN_OVER_SHARE = 0.25 --below this the over-time part is incidental and its ramp is noise
local HEAL_SCHOOL = 2
local AUTO_ATTACK = 6603

--reading spell cooldowns on a timer leaks secret values into Blizzard's own action button code, so this one is told to us
function TT.Gcd(powerType)
	local set = TT.db and TT.db.gcd
	if set and set > 0 then return set end
	return (powerType == Enum.PowerType.Energy or powerType == Enum.PowerType.Rage) and MELEE_GCD or SPELL_GCD
end

local POWER_NAMES = {
	[Enum.PowerType.Mana] = "mana",
	[Enum.PowerType.Rage] = "rage",
	[Enum.PowerType.Focus] = "focus",
	[Enum.PowerType.Energy] = "energy",
}

local function baseCooldown(spellID)
	local ms = C_Spell.GetSpellBaseCooldown and C_Spell.GetSpellBaseCooldown(spellID)
	if not ms and GetSpellBaseCooldown then ms = GetSpellBaseCooldown(spellID) end
	return (ms or 0) / 1000
end

local function primaryCost(spellID)
	local costs = C_Spell.GetSpellPowerCost(spellID)
	if not costs then return nil end
	for _, cost in ipairs(costs) do
		if cost.cost and cost.cost > 0 then return cost end
	end
	return nil
end

--every crit number comes from the cache, so the tooltip path never calls a unit api itself
local function critChance(school)
	local stats = TT.Stats()
	if not stats then return 0 end
	if school and school > 1 and stats.spellCrit and stats.spellCrit[school] then
		return stats.spellCrit[school] / 100
	end
	return (stats.crit or 0) / 100
end

function TT.ComboPoints()
	local points
	if GetComboPoints then points = GetComboPoints("player", "target")
	elseif UnitPower then points = UnitPower("player", Enum.PowerType.ComboPoints) end
	if not TT.Readable(points) then return 0 end
	return points + 0
end

local function instantOf(part)
	if not part then return 0 end
	local total = 0
	if part.direct then total = total + (part.direct.low + part.direct.high) / 2 end
	if part.weaponPct then
		local stats = TT.Stats()
		if not stats then return total + (part.weaponFlat or 0) end
		if stats.low < 0 or stats.high < 0 then return total + (part.weaponFlat or 0) end
		total = total + ((stats.low + stats.high) / 2) * part.weaponPct * stats.percent + (part.weaponFlat or 0)
	end
	return total
end

local function overOf(part)
	if not part or not part.over then return 0, 0 end
	return part.over.total, part.over.duration
end

--a cast is the instant portion of both the spell and its combo-point entry, plus whatever ticks afterwards
local function combine(scan, part)
	local instant = instantOf(scan) + instantOf(part)
	local scanOver, scanDur = overOf(scan)
	local partOver, partDur = overOf(part)
	return {
		instant = instant,
		over = scanOver + partOver,
		duration = math.max(scanDur, partDur),
		total = instant + scanOver + partOver,
	}
end

local function round(value)
	return math.floor(value + 0.5)
end

local function uptimeRow(cast, perUnit, label)
	--kind is what the options menu switches on
	if cast.duration <= 0 or cast.over <= 0 then return nil end
	if cast.over / cast.total < MIN_OVER_SHARE then return nil end
	local entries, seen = {}, {}
	local stops = {}
	if cast.instant > 0 then stops[#stops + 1] = 0 end
	for i = 1, 3 do stops[#stops + 1] = cast.duration * i / 3 end
	for _, stop in ipairs(stops) do
		local at = round(stop)
		if not seen[at] then
			seen[at] = true
			local realized = cast.instant + cast.over * math.min(stop, cast.duration) / cast.duration
			entries[#entries + 1] = { key = at .. "s", value = perUnit(realized) }
		end
	end
	if #entries < 2 then return nil end
	entries[#entries].best = true
	return { kind = "uptime", label = label, entries = entries }
end

local function targetRow(value, perUnit, label, cap)
	local entries = {}
	for count = 1, cap or MAX_TARGETS do
		entries[#entries + 1] = { key = tostring(count), value = perUnit(value * count) }
	end
	return { label = label, entries = entries }
end

function TT.IsAutoAttack(spellID)
	return spellID == AUTO_ATTACK
end

--auto attack carries no numbers in its tooltip, so it is read straight off the character sheet instead
function TT.Melee()
	local stats = TT.Stats()
	if not stats then return nil, "no readable attack stats yet" end

	local percent = stats.percent
	local crit = stats.crit / 100
	local critScale = 1 + crit * (TT.db.critMultiplier - 1)
	local main
	local rate, total, cycle = 0, 0, nil
	if stats.speed > 0 and stats.low >= 0 and stats.high > 0 then
		main = { low = stats.low * percent, high = stats.high * percent, speed = stats.speed }
		local avg = (main.low + main.high) / 2
		rate = rate + avg * critScale / stats.speed
		total = total + avg
		cycle = stats.speed
	end

	local off
	if stats.offSpeed and stats.offSpeed > 0 and stats.offLow >= 0 and stats.offHi > 0 then
		off = { low = stats.offLow * percent, high = stats.offHi * percent, speed = stats.offSpeed }
		local avg = (off.low + off.high) / 2
		rate = rate + avg * critScale / stats.offSpeed
		total = total + avg
		cycle = math.min(cycle or stats.offSpeed, stats.offSpeed)
	end
	if not cycle then return nil, "no valid weapon damage yet" end

	return {
		kind = "damage",
		spellID = AUTO_ATTACK,
		crit = crit,
		critTotal = total * critScale,
		cast = { instant = total, over = 0, duration = 0, total = total },
		cycle = cycle,
		refresh = cycle,
		swing = main,
		offSwing = off,
		rate = rate,
		rows = {},
	}
end

--what a percentage of your damage is a percentage of: the fight the simulator just ran, not one ability off it
function TT.PhysicalBaseline()
	local rotation = TT.RotationDps()
	if rotation and rotation > 0 then return { dps = rotation, source = "rotation" } end

	local melee = TT.Melee()
	local dps = melee and melee.rate or 0
	local best = TT.char and TT.char.bestPhysical
	local source = "swing"
	if best and best.rate and best.rate > 0 then
		dps = dps + best.rate
		source = "swing + " .. best.name
	end
	return { dps = dps, source = source }
end

--a form's auto attack dps is the weapon's on this client, so a change in weapon dps is that change in swing dps
function TT.WeaponDps(delta)
	if not delta or delta == 0 then return 0 end
	local stats = TT.Stats()
	if not stats then return 0 end
	local critScale = 1 + (stats.crit or 0) / 100 * (TT.db.critMultiplier - 1)
	return delta * (stats.percent or 1) * critScale
end

--a builder is only comparable to another builder, so bests are kept per resource and per role
local function record(spellID, scan, result)
	if not TT.char or scan.kind ~= "damage" or scan.school ~= 1 then return end
	local info = C_Spell.GetSpellInfo(spellID)
	local name = info and info.name
	if not name then return end
	local function known(id)
		if IsPlayerSpell then
			local playerSpell = TT.Safely(IsPlayerSpell, id)
			if playerSpell == true then return true end
		end
		if IsSpellKnown then
			local spell = TT.Safely(IsSpellKnown, id)
			if spell ~= nil then return spell == true end
		end
		return nil
	end
	if known(spellID) ~= true then return end

	if not scan.aoe and not result.levels and result.rate > 0 then
		local best = TT.char.bestPhysical
		if not best or result.rate > best.rate or best.name == name then
			TT.char.bestPhysical = { name = name, rate = result.rate }
		end
	end

	local value = result.best and result.best.perResource or result.perResource
	if not value or not result.powerName then return end

	--an over-time ability and a direct hit are not alternatives to each other, whatever their per resource numbers say
	local shape = (result.cast.over > result.cast.instant) and "over" or "direct"
	local role = (result.levels and "spender" or "builder") .. ":" .. shape
	TT.char.roles = TT.char.roles or {}
	TT.char.roles[result.powerName] = TT.char.roles[result.powerName] or {}
	local bucket = TT.char.roles[result.powerName][role] or {}
	TT.char.roles[result.powerName][role] = bucket
	bucket[name] = { spellID = spellID, value = value }

	local rivalName, rivalValue
	for other, saved in pairs(bucket) do
		if other ~= name then
			local amount, rivalID
			if type(saved) == "table" then amount, rivalID = saved.value, saved.spellID
			elseif type(saved) == "number" then
				amount = saved
				local rivalInfo = C_Spell.GetSpellInfo(other)
				rivalID = rivalInfo and rivalInfo.spellID
			end
			if rivalID and known(rivalID) == true and amount and (not rivalValue or amount > rivalValue) then
				rivalName, rivalValue = other, amount
			elseif rivalID and known(rivalID) == false then
				bucket[other] = nil
			end
		end
	end
	if rivalName and rivalValue > 0 then
		result.versus = { name = rivalName, ratio = value / rivalValue - 1 }
	end
end

function TT.Calc(spellID, scan)
	local info = C_Spell.GetSpellInfo(spellID)
	if not info then return nil, "no spell info" end

	local healing = scan.kind == "heal"
	local cost = primaryCost(spellID)
	local powerType = cost and cost.type
	local gcd = TT.Gcd(powerType)
	local cast = (info.castTime or 0) / 1000
	local cooldown = baseCooldown(spellID)
	local school = healing and (scan.school or HEAL_SCHOOL) or scan.school
	local crit = critChance(school)
	local multiplier = healing and TT.db.healCritMultiplier or TT.db.critMultiplier
	local critScale = 1 + crit * (multiplier - 1)

	local levels, best, active = nil, nil, nil
	if scan.combo then
		levels = {}
		for points = 1, 5 do
			local part = scan.combo[points]
			if part then
				local level = { points = points, cast = combine(scan, part) }
				level.critTotal = level.cast.total * critScale
				if cost then level.perResource = level.critTotal / cost.cost end
				levels[#levels + 1] = level
				if not best or (level.perResource or level.critTotal) > (best.perResource or best.critTotal) then best = level end
			end
		end
		if #levels == 0 then levels = nil end
	end

	if levels then
		local current = TT.ComboPoints()
		active = levels[#levels]
		for _, level in ipairs(levels) do
			if level.points == current then active = level end
		end
	end

	local total = active and active.cast or combine(scan, nil)
	if total.total <= 0 then return nil, "no amounts parsed" end

	local cycle, limiter = math.max(cast, gcd), cast > gcd and "cast" or "gcd"
	local stats = TT.Stats()
	if scan.nextSwing and stats then cycle, limiter = stats.speed, "swing" end
	if cooldown > cycle then cycle, limiter = cooldown, "cooldown" end

	--ticks land at their own pace no matter how fast you recast, so the over-time part is rated over its duration
	local refresh = cycle
	if total.over >= total.instant and total.duration > cycle then
		refresh = total.duration
		if total.instant / total.total < MIN_OVER_SHARE then limiter = "over" end
	end

	local result = {
		kind = scan.kind,
		spellID = spellID,
		crit = crit,
		critTotal = total.total * critScale,
		cast = total,
		cycle = cycle,
		refresh = refresh,
		limiter = limiter,
		aoe = scan.aoe,
		levels = levels,
		active = active,
		best = best,
		rows = {},
	}
	result.rate = (total.instant * critScale) / cycle
	if total.duration > 0 then result.rate = result.rate + (total.over * critScale) / total.duration end

	local perUnit = function(amount) return amount * critScale end
	if cost then
		result.cost = cost.cost
		result.powerName = POWER_NAMES[powerType] or (cost.name and cost.name:lower()) or "power"
		result.perResource = result.critTotal / cost.cost
		perUnit = function(amount) return amount * critScale / cost.cost end
		if powerType == Enum.PowerType.Energy then
			--spamming an energy ability is gated by regen, not the gcd, so that is the honest rate
			local capped = result.perResource * ENERGY_PER_SEC
			if capped < result.rate then result.rate, result.capped = capped, true end
		elseif powerType == Enum.PowerType.Mana then
			--the mana you have is what decides how many more of these you get, not the pool you could have
			local state = TT.ManaState()
			if state then
				result.oomCasts = math.floor(state.current / cost.cost)
				result.oomTime = result.oomCasts * refresh
				result.oomFull = math.floor(state.max / cost.cost)
				--the pool is the limit, not the global cooldown, the same way regen limits an energy ability
				local fight = TT.FightLength and TT.FightLength()
				if fight and fight > 0 and cost.cost > 0 then
					local affordable = (state.current + (state.perSecond or 0) * fight) / cost.cost
					local capped = affordable * result.critTotal / fight
					if capped < result.rate then result.rate, result.capped = capped, true end
				end
			end
			result.manaVerdict = TT.ManaVerdict(cost.cost)
		end
	end

	local unit = cost and ("Per " .. result.powerName) or (healing and "Healing" or "Damage")

	if levels then
		local entries = {}
		for _, level in ipairs(levels) do
			entries[#entries + 1] = {
				key = tostring(level.points),
				value = level.perResource or level.critTotal,
				best = level == best,
				current = level == active,
			}
		end
		result.rows[#result.rows + 1] = { kind = "cp", label = unit .. " by " .. TT.ComboMark(), entries = entries }
	end

	local ramp = uptimeRow(total, perUnit, unit .. " by uptime")
	if ramp then result.rows[#result.rows + 1] = ramp end

	if scan.aoe then
		result.rows[#result.rows + 1] = targetRow(total.total, perUnit, unit .. " by targets", scan.maxTargets)
	end

	--only flagged here; pricing it asks the rotation, and the rotation is what asks for this
	result.forms = scan.forms
	result.wrongForm = TT.WrongForm(scan.forms, result.powerName)

	record(spellID, scan, result)
	return result
end
