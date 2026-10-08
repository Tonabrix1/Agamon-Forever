local ADDON, TT = ...

local ARMOR_CONSTANT = 400
local ARMOR_PER_LEVEL = 85
local ARMOR_DR_CAP = 0.75
local ARMOR_PER_MOB_LEVEL = 50
local BOSS_LEVEL_OFFSET = 3

--vanilla mob armor is not exposed to addons, so these are the commonly cited values for the top end
local ARMOR_BY_LEVEL = {
	[61] = 3200, [62] = 3400, [63] = 3731,
}

local ELITE_BONUS = {
	elite = 1.1,
	rareelite = 1.1,
	worldboss = 1.1,
}

local function estimatedArmor(level, classification)
	local armor = ARMOR_BY_LEVEL[level] or (level * ARMOR_PER_MOB_LEVEL)
	return math.floor(armor * (ELITE_BONUS[classification] or 1))
end

local function reduction(armor, attackerLevel)
	if armor <= 0 then return 0 end
	return math.min(ARMOR_DR_CAP, armor / (armor + ARMOR_CONSTANT + ARMOR_PER_LEVEL * attackerLevel))
end

local known = {}

local function plainGUID(unit)
	local guid = UnitGUID(unit)
	return TT.ReadableText(guid) and guid or nil
end

--every one of these returns can be a secret boolean, and testing one taints the whole execution, pcall or not
local function attackableUnit(unit)
	if not TT.ReadableText(unit) then return false end
	if TT.ReadableBool(UnitExists(unit)) ~= true then return false end
	return TT.ReadableBool(UnitCanAttack("player", unit)) == true
end

local function livingUnit(unit)
	return attackableUnit(unit) and TT.ReadableBool(UnitIsDead(unit)) ~= true
end

local function remember(unit)
	if not attackableUnit(unit) then return end
	local guid = plainGUID(unit)
	if not guid then return end
	local entry = known[guid] or {}
	local level = UnitLevel(unit)
	if TT.Readable(level) then entry.level = level + 0 end
	local classification = UnitClassification(unit)
	if TT.ReadableText(classification) then entry.classification = classification end
	known[guid] = entry
	if entry.max then
		local stats = TT.Stats()
		TT.NoteUnitHealth(guid, entry, stats and stats.level or 60)
	end
end

local function cachedUnit(unit)
	if not TT.ReadableText(unit) then return nil end
	local guid = plainGUID(unit)
	return guid and known[guid] or nil
end

local watcher = CreateFrame("Frame")
TT.OnInit(function()
	TT.Listen(watcher, "UPDATE_MOUSEOVER_UNIT")
	TT.Listen(watcher, "PLAYER_TARGET_CHANGED")
	TT.Listen(watcher, "UNIT_HEALTH")
end)
watcher:SetScript("OnEvent", function(self, event, unit)
	if event == "UPDATE_MOUSEOVER_UNIT" then
		remember("mouseover")
	elseif event == "PLAYER_TARGET_CHANGED" then
		remember("target")
	elseif unit == "mouseover" or unit == "target" then
		remember(unit)
	end
	if event == "PLAYER_TARGET_CHANGED" then TT.InvalidateRotation() end
	--the only two events that can mean a target just died, which is the whole of the kill timer's input
	if TT.PollKill and (event == "PLAYER_TARGET_CHANGED" or unit == "target") then TT.PollKill() end
end)

--health bar values can be secret, so only text the UI already rendered is considered
local function parseHealthText(text)
	local clean = text:gsub(",", "")
	local current, maximum = clean:match("(%d+)%s*/%s*(%d+)")
	if current and tonumber(maximum) > 0 then return tonumber(maximum), tonumber(current) end
	local value, percent = clean:match("(%d+)%D-(%d+)%%")
	if value and tonumber(percent) > 0 then return tonumber(value) / (tonumber(percent) / 100), tonumber(value) end
	return nil
end

--census counts what was there but unreadable, because a missing font string and a secret one look identical otherwise
local function collectText(frame, depth, out, census)
	if not frame or not frame.GetRegions then return end
	for _, region in ipairs({ frame:GetRegions() }) do
		local getter = region and region.GetText
		if getter then
			if census then census.strings = census.strings + 1 end
			local text = TT.Safely(getter, region)
			if TT.ReadableText(text) then
				out[#out + 1] = text
			elseif census then
				census.secret = census.secret + 1
			end
		end
	end
	if depth <= 0 or not frame.GetChildren then return end
	for _, child in ipairs({ frame:GetChildren() }) do collectText(child, depth - 1, out, census) end
end

--a replacement nameplate draws its own number on a frame beside the Blizzard one, not inside it, so the scan starts at the plate
local PLATE_TEXT_DEPTH = 4

local function healthFromPlateText(plate)
	local texts = {}
	TT.Safely(collectText, plate, PLATE_TEXT_DEPTH, texts)
	for _, text in ipairs(texts) do
		local maximum, current = parseHealthText(text)
		if maximum then return maximum, current end
	end
	return nil
end

local function readNameplate(plate, wantedName)
	local frame = plate and plate.UnitFrame
	if not frame then return nil end
	if wantedName then
		local label = frame.name
		local plateName = TT.Safely(function() return label and label.GetText and label:GetText() end)
		if not TT.ReadableText(plateName) or plateName ~= wantedName then return nil end
	end
	return healthFromPlateText(plate)
end

local function healthFromNameplate(name, unit)
	if not C_NamePlate then return nil end
	--the unit lookup already names the plate, so a secret name label must not veto it
	if TT.ReadableText(unit) and C_NamePlate.GetNamePlateForUnit then
		local direct = TT.Safely(C_NamePlate.GetNamePlateForUnit, unit)
		if direct then
			local maximum, current = readNameplate(direct, nil)
			if maximum and maximum > 0 then return maximum, current end
		end
	end
	if not C_NamePlate.GetNamePlates then return nil end

	local plates = TT.Safely(C_NamePlate.GetNamePlates)
	if not plates then return nil end
	--by name where the labels are readable, else by being the only plate that answers at all
	local passes = name and { name, false } or { false }
	for _, wanted in ipairs(passes) do
		local found
		for _, plate in ipairs(plates) do
			local maximum, current = readNameplate(plate, wanted or nil)
			if maximum then
				if found then found = nil break end
				found = { maximum, current }
			end
		end
		if found then return found[1], found[2] end
	end
	return nil
end

--the client prints what a thing is on its own tooltip, so the type is read rather than looked up
local CREATURE_TYPES = {
	beast = true, humanoid = true, undead = true, demon = true, elemental = true,
	mechanical = true, dragonkin = true, giant = true, critter = true, aberration = true,
}

local function creatureTypeFromLines(lines)
	for _, line in ipairs(lines or {}) do
		local word = line:lower():gsub("^%s*(.-)%s*$", "%1")
		if CREATURE_TYPES[word] then return word end
	end
	return nil
end

--nothing bleeds that is not made of flesh, and being told to open with a bleed on one of these is just wrong
function TT.BleedImmune(lines, unit)
	local kind = creatureTypeFromLines(lines)
	if not kind and TT.ReadableText(unit) then
		local shown = TT.Safely(UnitCreatureType, unit)
		kind = TT.ReadableText(shown) and shown:lower() or nil
	end
	if not kind then return false, nil end
	return (TT.db.bleedImmune or {})[kind] == true, kind
end

local function unitNameFromLines(lines)
	for _, line in ipairs(lines or {}) do
		local lower = line:lower()
		if not lower:find("^level%s+") and lower ~= "beast" and lower ~= "humanoid" then return line end
	end
	return nil
end

--says exactly which of the three ways of getting a mob's health works on this client, since guessing has cost enough rounds
function TT.HealthReport(unit)
	unit = unit or "target"
	if not TT.ReadableText(unit) then return { "unit unavailable" } end
	local say = TT.Describe
	local out = {}
	out[#out + 1] = "unit " .. unit .. ", exists " .. say(UnitExists(unit))

	out[#out + 1] = "numeric unit health and status-bar values are not read by the addon"

	local guid = plainGUID(unit)
	local entry = guid and known[guid]
	out[#out + 1] = "cached for " .. say(guid) .. ": " ..
		(entry and ("max=" .. say(entry.max) .. " current=" .. say(entry.current) .. " level=" .. say(entry.level)) or "nothing")
	return out
end

--says which part of a nameplate this client lets us read, since the health bar and its label fail independently
function TT.PlateReport(unit)
	unit = unit or "target"
	local say = TT.Describe
	local out = {}
	if not C_NamePlate then return { "no C_NamePlate on this client" } end

	local plates = TT.Safely(C_NamePlate.GetNamePlates) or {}
	local direct = TT.ReadableText(unit) and C_NamePlate.GetNamePlateForUnit and TT.Safely(C_NamePlate.GetNamePlateForUnit, unit)
	out[#out + 1] = "plates " .. #plates .. ", plate for " .. unit .. ": " .. say(direct ~= nil)

	local index = 0
	for _, plate in ipairs(plates) do
		index = index + 1
		local frame = plate.UnitFrame
		out[#out + 1] = "plate " .. index .. (plate == direct and " (this unit)" or "") .. " UnitFrame " .. say(frame ~= nil)
		if frame then
			local label = frame.name
			out[#out + 1] = "  name -> " .. say(TT.Safely(function() return label and label.GetText and label:GetText() end))
			local texts = {}
			TT.Safely(collectText, frame, PLATE_TEXT_DEPTH, texts)
			out[#out + 1] = "  rendered health text: " .. (#texts > 0 and table.concat(texts, " | ") or "none")
		end
		local wide, census = {}, { strings = 0, secret = 0 }
		TT.Safely(collectText, plate, PLATE_TEXT_DEPTH, wide, census)
		out[#out + 1] = "  whole plate text: " .. (#wide > 0 and table.concat(wide, " | ") or "none")
		out[#out + 1] = string.format("  %d font strings on the plate, %d of them secret", census.strings, census.secret)
		local drawn, drawnCurrent = healthFromPlateText(plate)
		if drawn then out[#out + 1] = "  parsed from the plate -> max=" .. say(drawn) .. " current=" .. say(drawnCurrent) end
		if census.secret > 0 then
			out[#out + 1] = "  the health number is one of the secret ones, so no addon can read it here"
		end
	end
	local maximum, current = healthFromNameplate(nil, unit)
	out[#out + 1] = "healthFromNameplate -> max=" .. say(maximum) .. " current=" .. say(current)
	return out
end

--how big the pull actually is, counted off the plates the client drew, since nothing else tells an addon this
local ENEMY_CACHE_SECONDS = 1
local MAX_NAMEPLATES = 40
local enemyCount, enemyCountedAt = nil, 0

local function hostilePlateUnit(unit)
	if TT.ReadableBool(UnitIsPlayer(unit)) == true then return false end
	return livingUnit(unit) and TT.ReadableBool(UnitAffectingCombat(unit)) == true
end

local function plateUnit(plate)
	local unit = plate and plate.namePlateUnitToken
	if not TT.ReadableText(unit) then
		local frame = plate and plate.UnitFrame
		unit = frame and frame.unit
	end
	return TT.ReadableText(unit) and unit or nil
end

function TT.EnemiesInCombat()
	--the cache is checked before anything is read, so a hot caller never touches the api at all
	if enemyCount and GetTime() - enemyCountedAt < ENEMY_CACHE_SECONDS then return enemyCount end

	local count, seen = 0, {}
	local function add(unit)
		if not unit or TT.Safely(hostilePlateUnit, unit) ~= true then return end
		local guid = UnitGUID and plainGUID(unit)
		local key = guid or unit
		if not seen[key] then
			seen[key] = true
			count = count + 1
		end
	end
	local plates = C_NamePlate and C_NamePlate.GetNamePlates and TT.Safely(C_NamePlate.GetNamePlates)
	for _, plate in ipairs(plates or {}) do add(plateUnit(plate)) end
	if plates then for index = 1, MAX_NAMEPLATES do add("nameplate" .. index) end end
	add("target")
	if count == 0 then
		enemyCount, enemyCountedAt = nil, 0
		return nil
	end
	enemyCount, enemyCountedAt = count, GetTime()
	return count
end

--health is unreadable here, so a kill is timed from engaging a unit to that unit reading dead, with no numbers involved
local engaged = nil

local function targetState()
	if TT.ReadableBool(UnitExists("target")) ~= true then return nil end
	if TT.ReadableBool(UnitCanAttack("player", "target")) ~= true then return nil end
	if TT.ReadableBool(UnitIsDead("target")) == true then return "dead" end
	return "alive"
end

local function pollKill()
	local guid = plainGUID("target")
	local state = guid and TT.Safely(targetState)

	if engaged and engaged.guid == guid and state == "dead" then
		TT.NoteKill(engaged.bucket, GetTime() - engaged.start)
		engaged = nil
		return
	end
	--a target you swapped off is not a kill, so it is dropped rather than timed
	if not guid or state ~= "alive" then
		if not engaged or engaged.guid ~= guid then engaged = nil end
		return
	end
	if engaged and engaged.guid == guid then return end
	if TT.ReadableBool(UnitAffectingCombat("player")) ~= true then return end

	local stats = TT.Stats()
	local level = TT.Readable(UnitLevel("target")) and UnitLevel("target") or nil
	engaged = {
		guid = guid,
		start = GetTime(),
		bucket = TT.KillBucket(level, UnitClassification("target"), stats and stats.level or 60),
	}
end

--driven by the events that already fire rather than a timer, because every tick is another chance to touch a secret
TT.PollKill = pollKill

--armour the target has already had stripped, so the estimate reflects the debuffs actually on it
local function armorOff(unit)
	if not C_UnitAuras or not C_UnitAuras.GetAuraDataByIndex then return 0, nil end
	local total, names = 0, {}
	for index = 1, 40 do
		local aura = TT.Safely(C_UnitAuras.GetAuraDataByIndex, unit, index, "HARMFUL")
		if not aura then break end
		local amount = TT.Readable(aura.spellId) and TT.KnownArmorDebuff(aura.spellId)
		if amount then
			total = total + amount
			names[#names + 1] = TT.ReadableText(aura.name) and aura.name or tostring(aura.spellId)
		end
	end
	return total, #names > 0 and table.concat(names, ", ") or nil
end

--the client printed the level on the tooltip it just drew, which is readable when UnitLevel is a secret number
local function levelFromLines(lines)
	for _, line in ipairs(lines or {}) do
		local shown = line:lower():match("level%s+(%d+)")
		if shown then return tonumber(shown) end
	end
	return nil
end

local function classificationFromLines(lines)
	for _, line in ipairs(lines or {}) do
		local lower = line:lower()
		for _, classification in ipairs({ "worldboss", "rareelite", "elite", "rare" }) do
			if lower:find(classification, 1, true) then return classification end
		end
	end
	return "normal"
end

--the client fills its rendered text after the tooltip callback, so inspect that text a tick later
local NAMEPLATE_READ_DELAY = 0.1

local function readNameplateForUnit(unit)
	if not GameTooltip or not GameTooltip.IsShown or not GameTooltip:IsShown() then return end
	local _, shown = GameTooltip:GetUnit()
	if not TT.ReadableText(unit) or not TT.ReadableText(shown) or shown ~= unit then return end
	local maximum, current = healthFromNameplate(nil, unit)
	if not maximum then return end
	local guid = plainGUID(unit)
	if not guid then return end
	local entry = known[guid] or {}
	entry.max, entry.current = maximum, current
	local lvl = UnitLevel(unit)
	entry.level = entry.level or (TT.Readable(lvl) and lvl or nil)
	entry.classification = entry.classification or UnitClassification(unit)
	known[guid] = entry
	local stats = TT.Stats()
	TT.NoteUnitHealth(guid, entry, stats and stats.level or 60)
end

function TT.ScheduleNameplateRead(unit)
	if not C_Timer or not C_Timer.After then return end
	C_Timer.After(NAMEPLATE_READ_DELAY, function() readNameplateForUnit(unit) end)
end

function TT.CalcUnit(unit, lines)
	local readableUnit = TT.ReadableText(unit)
	if readableUnit and not livingUnit(unit) then return nil end

	local stats = TT.Stats()
	local playerLevel = stats and stats.level or 60
	local entry = readableUnit and cachedUnit(unit)
	local health = entry and entry.max
	local current = entry and entry.current
	if not health then health, current = healthFromNameplate(unitNameFromLines(lines), unit) end
	local level = levelFromLines(lines) or (entry and entry.level)
	local isBoss = false
	if not level or level < 0 then
		level, isBoss = playerLevel + BOSS_LEVEL_OFFSET, true
	end

	local live = readableUnit and UnitClassification(unit)
	if not TT.ReadableText(live) then live = nil end
	local classification = entry and entry.classification or live or classificationFromLines(lines)
	local armor = TT.db.targetArmor or estimatedArmor(level, classification)
	local stripped, debuffs = 0, nil
	if readableUnit then stripped, debuffs = armorOff(unit) end
	armor = math.max(0, armor - stripped)
	local mitigation = 1 - reduction(armor, playerLevel)
	local physical = TT.PhysicalBaseline()

	if health and health > 0 then
		local guid = readableUnit and plainGUID(unit)
		if guid then TT.NoteUnitHealth(guid, { max = health, current = current, level = level, classification = classification }, playerLevel) end
	end

	local result = { kind = "effect", lines = {}, rows = {} }
	local pinned = TT.db.targetArmor and "" or " (est)"
	result.lines[#result.lines + 1] = { isBoss and not TT.db.targetArmor and "Armor (boss est)" or ("Armor" .. pinned), tostring(armor), true }
	result.lines[#result.lines + 1] = { "Mitigation", string.format("-%.0f%%", (1 - mitigation) * 100), true }
	if debuffs then
		result.lines[#result.lines + 1] = { "Already stripped", string.format("-%d by %s", stripped, debuffs), true }
	end

	if health then
		result.lines[#result.lines + 1] = { "Effective HP", string.format("%.0f", health / mitigation), true }
	end

	if physical.dps > 0 then
		local effective = physical.dps * mitigation
		result.lines[#result.lines + 1] = { "Expected DPS", string.format("%.0f", effective) }
		result.lines[#result.lines + 1] = { "Before armor", string.format("%.0f dps (%s)", physical.dps, physical.source), true }
		if health then
			local left = current or health
			local label = left < health and string.format("TTK (%.0f%% HP)", left / health * 100) or "TTK (full HP)"
			result.lines[#result.lines + 1] = { label, string.format("%.0fs", left / effective), true }
		else
			--nothing drew a health bar, so the honest figure is how long these have actually taken you
			local measured, sure = TT.KillTime(TT.KillBucket(level, classification, playerLevel))
			if measured then
				result.lines[#result.lines + 1] = { "TTK (observed)", string.format("%.0fs", measured), true }
				result.lines[#result.lines + 1] = { "Confidence", string.format("%.0f%%", (sure or 0) * 100), true }
			else
				result.lines[#result.lines + 1] = { "TTK / 1k HP", string.format("%.1fs", 1000 / effective), true }
			end
		end
	end

	return result
end

--the one mob we are actually fighting, which is what the simulator should be pricing against
function TT.TargetFight()
	local entry = cachedUnit("target")
	if not entry or not entry.max or entry.max <= 0 then return nil end
	local stats = TT.Stats()
	local playerLevel = stats and stats.level or 60
	local bucket = TT.KillBucket(entry.level, entry.classification, playerLevel)
	local physical = TT.PhysicalBaseline()
	if not physical or physical.dps <= 0 then return nil, bucket end

	local armor = TT.db.targetArmor or estimatedArmor(entry.level or playerLevel, entry.classification)
	local effective = physical.dps * (1 - reduction(armor, playerLevel))
	if effective <= 0 then return nil, bucket end
	return (entry.current or entry.max) / effective, bucket
end

--a dot whose state cannot be read is not the same as a dot that is down, so an unreadable aura list answers nil
function TT.AuraUp(spellID)
	if not spellID or not UnitExists then return nil end
	if TT.ReadableBool(UnitExists("target")) ~= true then return nil end
	if not C_UnitAuras or not C_UnitAuras.GetAuraDataByIndex then return nil end

	local readable = false
	for index = 1, 40 do
		local aura = TT.Safely(C_UnitAuras.GetAuraDataByIndex, "target", index, "HARMFUL|PLAYER")
		if not aura then break end
		if TT.Readable(aura.spellId) then
			readable = true
			if aura.spellId == spellID then return true end
		end
	end
	if not readable then return nil end
	return false
end

--the only case where a positional ability is genuinely impossible is the mob facing you
function TT.Tanking()
	if not UnitIsUnit or TT.ReadableBool(UnitExists("target")) ~= true then return false end
	return TT.ReadableBool(UnitIsUnit("targettarget", "player")) == true
end
