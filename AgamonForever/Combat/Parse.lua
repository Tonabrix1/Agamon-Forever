local ADDON, TT = ...

local MIN_WEAPON_PCT = 50 --below this a percentage is a debuff clause, not weapon scaling

local SCHOOLS = {
	["holy"] = 2, ["fire"] = 3, ["nature"] = 4, ["frost"] = 5, ["shadow"] = 6, ["arcane"] = 7,
}

local AOE_PHRASES = {
	"nearby enem", "all enem", "enemies in", "nearby group", "party members", "nearby allies",
	"nearby raid", "all party", "targets in", "nearby targets",
}

local TARGET_COUNT_PATTERNS = {
	"(%d+) nearby enem", "(%d+) nearby target", "(%d+) nearby all", "(%d+) nearby group",
	"(%d+) party members", "(%d+) group members", "(%d+) raid members", "up to (%d+)",
}

local TICK_PATTERNS = {
	"(%d+)%s*[%a]*%s*damage[%a%s]-every (%d+) sec for (%d+) sec",
	"(%d+)%s*[%a]*%s*damage[%a%s]-every (%d+) sec",
}

local OVER_PATTERNS = {
	"(%d+)%s*[%a]*%s*damage over (%d+) sec",
}

local WEAPON_PATTERNS = {
	{ "melee damage by (%d+)", true, 100 },
	{ "(%d+)%%%s*[%a ]-damage plus (%d+)", true },
	{ "(%d+)%%%s*[%a ]-damage", false },
}

local RANGE_PATTERNS = {
	"(%d+)%s*%-%s*(%d+)%s*[%a]*%s*damage",
	"(%d+) to (%d+)%s*[%a]*%s*damage",
}

local RANGE_LIMIT_PATTERNS = {
	"(%d+)%s*%-%s*(%d+)%s*yds?%s*range",
	"range%s+(%d+)%s*%-%s*(%d+)%s*yds?",
	"(%d+)%s+to%s+(%d+)%s*yds?",
}

local FLAT_PATTERNS = {
	"(%d+)%s*[%a]+%s*damage",
	"(%d+)%s*damage",
}

local HEAL_OVER_PATTERNS = {
	"(%d+)%s*health over (%d+) sec",
	"(%d+) over (%d+) sec",
}

local HEAL_RANGE_PATTERNS = {
	"for (%d+) to (%d+)",
	"(%d+) to (%d+)%s*health",
}

local HEAL_FLAT_PATTERNS = {
	"for (%d+)%s*health",
	"for (%d+)",
}

local IGNORE_LINE = {
	"requires", "cooldown", "range", "cast time", "instant", "channeled", "next melee",
}

local NOT_YOUR_DAMAGE = { "to attackers", "when hit", "damage taken", "damage done by" }
local CONTROL_PATTERNS = {
	{ "stun", "stun" }, { "root", "root" }, { "immobil", "root" },
	{ "fear", "fear" }, { "incapacitat", "incapacitate" }, { "sleep", "incapacitate" },
	{ "silence", "silence" }, { "unable to act", "incapacitate" },
}

local function cut(line, s, e)
	return line:sub(1, s - 1) .. " " .. line:sub(e + 1)
end

local function skipLine(lower, keyword)
	for _, word in ipairs(IGNORE_LINE) do
		if lower:find(word, 1, true) and not lower:find(keyword, 1, true) then return true end
	end
	return false
end

local function school(lower)
	for word, index in pairs(SCHOOLS) do
		if lower:find(word .. " damage", 1, true) then return index end
	end
	return nil
end

local function targetCount(lower)
	for _, pat in ipairs(TARGET_COUNT_PATTERNS) do
		local count = lower:match(pat)
		if count and tonumber(count) > 1 then return tonumber(count) end
	end
	return nil
end

local function isAoe(lower)
	for _, phrase in ipairs(AOE_PHRASES) do
		if lower:find(phrase, 1, true) then return true end
	end
	return false
end

local function findOver(text, patterns)
	for _, pat in ipairs(patterns) do
		local s, e, total, duration = text:find(pat)
		if s and tonumber(duration) > 0 then
			return { total = tonumber(total), duration = tonumber(duration) }, cut(text, s, e)
		end
	end
	return nil, text
end

local function findRange(text, patterns)
	for _, pat in ipairs(patterns) do
		local s, e, low, high = text:find(pat)
		if s and tonumber(high) >= tonumber(low) then
			return { low = tonumber(low), high = tonumber(high) }, cut(text, s, e)
		end
	end
	return nil, text
end

local function findFlat(text, patterns)
	for _, pat in ipairs(patterns) do
		local s, e, value = text:find(pat)
		if s then
			return { low = tonumber(value), high = tonumber(value) }, cut(text, s, e)
		end
	end
	return nil, text
end

--pulls every damage shape out of one line, removing each match so a later pattern cannot reuse its digits
local function extractDamage(text)
	local got, found = {}, false

	for _, pat in ipairs(TICK_PATTERNS) do
		local s, e, perTick, interval, duration = text:find(pat)
		if s then
			duration = tonumber(duration) or tonumber(text:match("lasts (%d+) sec"))
			interval = tonumber(interval)
			if duration and interval and interval > 0 then
				local ticks = math.floor(duration / interval)
				if ticks > 0 then got.over = { total = tonumber(perTick) * ticks, duration = duration } end
			end
			text = cut(text, s, e)
			found = found or got.over ~= nil
			break
		end
	end

	if not got.over then
		got.over, text = findOver(text, OVER_PATTERNS)
		found = found or got.over ~= nil
	end

	for _, entry in ipairs(WEAPON_PATTERNS) do
		local s, e, pct, flat = text:find(entry[1])
		if s then
			if entry[3] then pct, flat = entry[3], pct end
			pct = tonumber(pct)
			if pct >= MIN_WEAPON_PCT then
				got.weaponPct = pct / 100
				got.weaponFlat = entry[2] and tonumber(flat) or 0
				text, found = cut(text, s, e), true
				break
			end
		end
	end

	got.direct, text = findRange(text, RANGE_PATTERNS)
	if not got.direct then got.direct, text = findFlat(text, FLAT_PATTERNS) end
	found = found or got.direct ~= nil

	return found and got or nil
end

local function extractHeal(text)
	local got = {}
	got.over, text = findOver(text, HEAL_OVER_PATTERNS)
	got.direct, text = findRange(text, HEAL_RANGE_PATTERNS)
	if not got.direct then got.direct, text = findFlat(text, HEAL_FLAT_PATTERNS) end
	if not got.over and not got.direct then return nil end
	return got
end

local function merge(out, got)
	if got.direct and not out.direct then out.direct = got.direct end
	if got.over and not out.over then out.over = got.over end
	if got.weaponPct and not out.weaponPct then
		out.weaponPct, out.weaponFlat = got.weaponPct, got.weaponFlat
	end
end

--parses the tooltip body the client actually rendered, so rank and talent scaling come along for free
function TT.Parse(lines)
	local out = { school = 1, kind = nil }
	local heal = { school = 2 }
	local foundDamage, foundHeal = false, false

	for _, raw in ipairs(lines) do
		local lower = (raw or ""):lower()
		for _, pattern in ipairs(RANGE_LIMIT_PATTERNS) do
			local minimum, maximum = lower:match(pattern)
			if minimum and maximum then
				out.minRange, out.maxRange = tonumber(minimum), tonumber(maximum)
				break
			end
		end
		if lower:find("next melee", 1, true) then out.nextSwing = true end
		if lower:find("melee damage by", 1, true) then out.nextSwing = true end
		if lower:find("taunt", 1, true) or lower:find("forces the target to attack you", 1, true) then out.taunt = true end
		if lower:find("behind the target", 1, true) or lower:find("behind your target", 1, true) then out.positional = true end
		for _, pattern in ipairs(CONTROL_PATTERNS) do
			if lower:find(pattern[1], 1, true) then
				out.control, out.controlType = true, pattern[2]
				break
			end
		end
		if lower:find("^requires ") and lower:find("form", 1, true) then
			out.forms = out.forms or {}
			for part in (lower:gsub("^requires%s+", "")):gmatch("[^,]+") do
				out.forms[(part:gsub("^%s*(.-)%s*%.?$", "%1"))] = true
			end
		end
		if isAoe(lower) then
			out.aoe = true
			out.maxTargets = out.maxTargets or targetCount(lower)
		end

		local awards = lower:match("awards (%d+) combo point")
		if awards then out.awards = tonumber(awards) end

		local points, rest = lower:match("^%s*(%d+)%s*points?%s*:%s*(.+)$")
		local body = points and rest or lower
		local healing = body:find("heal", 1, true) ~= nil
		local keyword = healing and "heal" or "damage"

		local foreign = false
		for _, phrase in ipairs(NOT_YOUR_DAMAGE) do
			if body:find(phrase, 1, true) then foreign = true end
		end

		if (healing or body:find("damage", 1, true)) and not foreign and not skipLine(body, keyword) then
			local got = healing and extractHeal(body) or extractDamage(body)
			if got then
				local target = healing and heal or out
				if points then
					target.combo = target.combo or {}
					target.combo[tonumber(points)] = got
				else
					merge(target, got)
				end
				if healing then
					foundHeal = true
				else
					foundDamage = true
					out.school = out.school > 1 and out.school or (school(body) or 1)
				end
			end
		end
	end

	if foundDamage then
		out.kind = "damage"
		return out
	end
	if foundHeal then
		heal.kind, heal.aoe, heal.maxTargets, heal.nextSwing = "heal", out.aoe, out.maxTargets, nil
		return heal
	end
	if out.forms or out.control then return out end
	return nil
end
