local ADDON, TT = ...

local REFRESH_EVENTS = {
	"PLAYER_ENTERING_WORLD", "UNIT_DAMAGE", "UNIT_ATTACK_SPEED", "UNIT_ATTACK_POWER",
	"UNIT_STATS", "UNIT_AURA", "PLAYER_EQUIPMENT_CHANGED", "UPDATE_SHAPESHIFT_FORM",
	"PLAYER_LEVEL_UP",
}
local STAT_FIELDS = { "low", "high", "offLow", "offHi", "percent", "speed", "offSpeed", "crit", "dodge", "ap", "level" }
local STAT_EVENTS = {
	PLAYER_ENTERING_WORLD = true, UNIT_DAMAGE = true, UNIT_ATTACK_SPEED = true, UNIT_ATTACK_POWER = true,
	UNIT_STATS = true, UNIT_AURA = true,
}
local cache
local statsOverride
local lastProfileKey

--this client hands tainted code "secret" numbers it may not compare or do math on.
--asking the engine is free; provoking an error to find out is not, so we never do that in a loop.
local HAS_SECRET_API = (issecret ~= nil) or (issecretvalue ~= nil)

--the secret check comes first: comparing a secret value to nil is itself the thing that errors
function TT.Readable(value)
	if issecret then return not issecret(value) and value ~= nil end
	if issecretvalue then return not issecretvalue(value) and value ~= nil end
	return type(value) == "number"
end

--a secret boolean may not be tested, and a pcall around the test does not undo the taint it already spread
function TT.ReadableBool(value)
	if issecret and issecret(value) then return nil end
	if issecretvalue and issecretvalue(value) then return nil end
	if type(value) ~= "boolean" then return nil end
	return value
end

--a frame's own measurements come back secret on some tooltips, and `x or 0` on one is itself the test that taints
function TT.ReadableNumber(value)
	if issecret and issecret(value) then return nil end
	if issecretvalue and issecretvalue(value) then return nil end
	if type(value) ~= "number" then return nil end
	return value
end

--some of this client's state apis answer 1 or nil where the modern signature promises true or false
function TT.ReadableFlag(value)
	if issecret and issecret(value) then return nil end
	if issecretvalue and issecretvalue(value) then return nil end
	local kind = type(value)
	if kind == "boolean" then return value end
	if kind == "number" then return value ~= 0 end
	if kind == "nil" then return false end
	return nil
end

--wraps one whole read, so a secret value costs a single failure rather than one per field
function TT.Safely(fn, ...)
	local ok, a, b, c, d, e, f, g = pcall(fn, ...)
	if not ok then return nil end
	return a, b, c, d, e, f, g
end

function TT.HasSecretAPI()
	return HAS_SECRET_API
end

local function number(value, fallback)
	if TT.Readable(value) then return value + 0 end
	return fallback
end

local function defenseSkill()
	if not UnitDefense then return nil end
	local base, modifier, positive, negative = TT.Safely(UnitDefense, "player")
	if not TT.Readable(base) then return nil end
	local total = base + 0
	if TT.Readable(modifier) then total = total + modifier end
	if TT.Readable(positive) then total = total + positive end
	if TT.Readable(negative) then total = total + negative end
	return total
end

--`x or 0` is a boolean test and `x + 0` is arithmetic, and a secret takes neither, so every field is asked about first
local function read()
	local low, high, offLow, offHi, _, _, percent = UnitDamage("player")
	local speed, offSpeed = UnitAttackSpeed("player")
	if not TT.Readable(low) or not TT.Readable(high) or not TT.Readable(speed) then return nil end

	local schools = {}
	for school = 2, 7 do
		schools[school] = number(GetSpellCritChance and GetSpellCritChance(school), 0)
	end

	local baseArmor, armor = 0, 0
	if UnitArmor then
		local base, effective = UnitArmor("player")
		baseArmor, armor = number(base, 0), number(effective, 0)
	end

	return {
		health = number(UnitHealthMax and UnitHealthMax("player"), 0),
		low = low + 0,
		high = high + 0,
		offLow = number(offLow, 0),
		offHi = number(offHi, 0),
		percent = number(percent, 1),
		speed = speed + 0,
		offSpeed = TT.Readable(offSpeed) and offSpeed + 0 or nil,
		crit = number(GetCritChance and GetCritChance(), 0),
		dodge = number(GetDodgeChance and GetDodgeChance(), 0),
		spellCrit = schools,
		ap = number(UnitAttackPower and UnitAttackPower("player"), 0),
		baseArmor = baseArmor,
		armor = armor,
		level = number(UnitLevel("player"), 60),
		str = number(UnitStat and UnitStat("player", 1), 0),
		agi = number(UnitStat and UnitStat("player", 2), 0),
		stam = number(UnitStat and UnitStat("player", 3), 0),
		int = number(UnitStat and UnitStat("player", 4), 0),
		spi = number(UnitStat and UnitStat("player", 5), 0),
		defense = defenseSkill(),
	}
end

local function profileKey()
	local form = TT.CurrentForm and TT.CurrentForm()
	if type(form) == "string" then
		form = form:lower()
		if form:find("cat", 1, true) then return "cat" end
		if form:find("bear", 1, true) then return "bear" end
		if form:find("moonkin", 1, true) then return "caster" end
		return nil
	end
	local _, class = UnitClass("player")
	return class == "DRUID" and "caster" or nil
end

local function changed(previous, fresh)
	if not previous then return true end
	for _, field in ipairs(STAT_FIELDS) do if previous[field] ~= fresh[field] then return true end end
	for school = 2, 7 do
		if previous.spellCrit and fresh.spellCrit and previous.spellCrit[school] ~= fresh.spellCrit[school] then return true end
	end
	return false
end

--reads outside the tooltip path usually come back plain, so a good read is kept and reused when a later one is secret
local function refresh(event)
	local fresh = TT.Safely(read)
	if not fresh then return false end
	local previous, key = cache, profileKey()
	cache = fresh
	if TT.char then
		TT.char.stats = fresh
		if event == "PLAYER_EQUIPMENT_CHANGED" or event == "PLAYER_LEVEL_UP"
			or key == lastProfileKey and STAT_EVENTS[event] and changed(previous, fresh) then TT.char.formStats = {} end
		if key then
			TT.char.formStats = TT.char.formStats or {}
			TT.char.formStats[key] = fresh
		end
	end
	lastProfileKey = key
	return true
end

function TT.Stats()
	if statsOverride then return statsOverride end
	if not cache and TT.char then cache = TT.char.stats end
	return cache
end

function TT.FormProfileKey()
	return profileKey()
end

function TT.FormStats(form)
	return TT.char and TT.char.formStats and TT.char.formStats[form] or nil
end

function TT.FormProfileKeys()
	local profiles = TT.char and TT.char.formStats or {}
	local keys = {}
	for _, form in ipairs({ "cat", "bear", "caster" }) do
		if profiles[form] then keys[#keys + 1] = form end
	end
	return keys
end

function TT.FormStatsKey()
	local parts = {}
	for _, form in ipairs(TT.FormProfileKeys()) do
		local stats = TT.FormStats(form)
		parts[#parts + 1] = form
		for _, key in ipairs({ "health", "low", "high", "offLow", "offHi", "percent", "crit", "dodge", "speed", "offSpeed", "ap", "baseArmor", "armor", "level" }) do
			parts[#parts + 1] = string.format("%.4f", stats[key] or 0)
		end
		for school = 2, 7 do parts[#parts + 1] = string.format("%.4f", stats.spellCrit and stats.spellCrit[school] or 0) end
	end
	return table.concat(parts, ":")
end

function TT.WithStats(stats, fn, ...)
	local previous = statsOverride
	statsOverride = stats
	local ok, result = pcall(fn, ...)
	statsOverride = previous
	if not ok then error(result, 0) end
	return result
end

--the cache is the only place anything reads your level from, so no caller ever risks a raw unit read
function TT.PlayerLevel()
	local stats = TT.Stats()
	return stats and stats.level or 60
end

function TT.RefreshStats()
	return refresh()
end

local frame = CreateFrame("Frame")
TT.OnInit(function()
	for _, event in ipairs(REFRESH_EVENTS) do TT.Listen(frame, event) end
	refresh()
end)
frame:SetScript("OnEvent", function(self, event, unit)
	if event:find("^UNIT_") and unit and unit ~= "player" then return end
	refresh(event)
end)
