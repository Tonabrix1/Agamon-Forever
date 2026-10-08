local ADDON, TT = ...

local CATEGORY_HEIGHT = 34
local PROGRESS_HEIGHT = 16
local FOOTER_HEIGHT = 150
local DEFAULT_DURATION = 10
local LOG_ICON_SIZE = 28
local LOG_ROW_HEIGHT = 136
local LOG_SHORT_ROW_HEIGHT = 96
local LOG_STRIP_LIFT = 22
local LOG_CONTENT_LIFT = 11
local LOG_METRIC_WIDTH = 142
local LOG_SEQUENCE_LEFT = 250
local LOG_BADGE_WIDTH = 30
local LOG_BADGE_HEIGHT = 22
local LOG_MAX_BADGES = 4
local LOG_MAX_ICONS = 256
local CATEGORY_ICON_SIZE = 22
local CATEGORY_MAX_ICONS = 6
local CATEGORY_ICON_GAP = 2
local CACHE_MAX_ENTRIES = 512
local SIMULATION_VERSION = "4"
local MAX_SIM_FIGHT = 1200
local DEFAULT_MAX_SIM_FIGHT = 120
local HEAL_HORIZONS = { 30, 60, 120 }
local HEAL_MANA_REGEN_DELAY = 5
local HEAL_RANK_LIMIT = 8
local HEAL_CANDIDATE_LIMIT = 8
local HEAL_SURVIVAL_LIMIT = 8
local HEAL_CHAIN_DEPTH = 3
--other addons do their own work on their own OnUpdate, and a scan that takes every frame is what trips their
--"exceeded its execution time limit" watchdog, so the scan stands down entirely for a moment now and then
local BREATHE_EVERY = 20
local BREATHE_FOR = 1.5
local WORK_BUDGET_MS = 2

local frame, categorySlots, logScroll, progressBar, statusText, scanTotalsText, durationBox, startBtn, searchingText, checkingText, discoveryLabel
local advancedButton, advancedFrame, advancedFields, advancedForms, advancedScenarios, advancedMessage
local roleButton
local weightsCustomized = false
local eventRefreshId = 0
local logRows = {}
local running, co, startTime, duration, variantsChecked, cacheHits
local panelHeight
local logRowHeight
local breatheAt, breatheUntil, breathed = nil, nil, 0
local bestByCategory = {}
local elitePool, eliteKeys = {}, {}
local discoveryResults = {}
local discoveryPools = {}
local scanBaseSeconds = 0
local displayContext
local populateFromCache
local scoreImmediateAbilities
local refreshTankingScenario
local runExplorer
local activeOptions
local resultInScope
local simulationAbilitiesById = {}
local choicesCache, choicesCachedAt

local function scanStats()
	if not TT.db then return { permutations = 0, seconds = 0 } end
	TT.db.simScanStats = TT.db.simScanStats or { permutations = 0, seconds = 0 }
	local stats = TT.db.simScanStats
	stats.permutations, stats.seconds, stats.uniques = stats.permutations or 0, stats.seconds or 0, nil
	return stats
end

local function simulationChoices()
	local now = GetTime and GetTime() or 0
	if choicesCache and now - choicesCachedAt < 1 then return choicesCache end
	choicesCache = TT.SimulationChoices()
	choicesCachedAt = now
	return choicesCache
end

local function resetScanStats()
	if TT.db then TT.db.simScanStats = { permutations = 0, seconds = 0 } end
	scanBaseSeconds = 0
	if startTime then startTime = GetTime() end
end

local function formatDuration(seconds)
	seconds = math.floor(seconds or 0)
	return string.format("%02d:%02d:%02d", math.floor(seconds / 3600), math.floor(seconds / 60) % 60, seconds % 60)
end

local function scaleFont(text, scale)
	if text and text.GetFont and text.SetFont then
		local font, size, flags = text:GetFont()
		if font and type(size) == "number" then text:SetFont(font, size * scale, flags) end
	end
end

local function getCache()
	if not TT.db then return {} end
	TT.db.simCache = TT.db.simCache or {}
	return TT.db.simCache
end

local function saveCache()
	if not TT.db then return end
	TT.db.simCache = getCache()
end

local CATEGORIES = {
	{ key = "st_burst", label = "Single Target Burst" },
	{ key = "boss_burst", label = "Boss Burst" },
	{ key = "aoe_burst", label = "AoE Burst" },
	{ key = "tanking", label = "Tanking" },
	{ key = "heal_hps", label = "Healing Burst" },
	{ key = "heal_efficiency", label = "Healing Efficiency" },
	{ key = "pvp", label = "PvP" },
}

local DISCOVERY_SLOTS = {
	{ key = "burst_4", label = "Best 4s burst" },
	{ key = "burst_8", label = "Best 8s burst" },
	{ key = "sustain_30", label = "Best 30s rotation" },
	{ key = "sustain_60", label = "Best 60s rotation" },
	{ key = "sustain_120", label = "Best 120s rotation" },
	{ key = "tab_dot_30", label = "Best 30s tab-dot rotation" },
	{ key = "heal_hps", label = "Best healing burst" },
	{ key = "heal_efficiency", label = "Best healing efficiency" },
	{ key = "heal_sustain_30", label = "Best 30s healing" },
	{ key = "heal_sustain_60", label = "Best 60s healing" },
	{ key = "heal_sustain_120", label = "Best 120s healing" },
	{ key = "heal_chain_30", label = "Best 30s healing chain" },
	{ key = "heal_chain_60", label = "Best 60s healing chain" },
	{ key = "heal_chain_120", label = "Best 120s healing chain" },
	{ key = "heal_tab_30", label = "Best 30s tab HoTs" },
	{ key = "heal_tab_60", label = "Best 60s tab HoTs" },
	{ key = "heal_tab_120", label = "Best 120s tab HoTs" },
	{ key = "heal_aoe_30", label = "Best 30s AoE healing" },
	{ key = "heal_aoe_60", label = "Best 60s AoE healing" },
	{ key = "heal_aoe_120", label = "Best 120s AoE healing" },
	{ key = "cooldown_damage", label = "Best cooldown damage" },
	{ key = "tanking", label = "Bear tank survival" },
	{ key = "survival_boss", label = "Boss survival" },
	{ key = "survival_mobs", label = "Mob pack survival" },
	{ key = "survival_pvp", label = "PvP survival" },
	{ key = "optimal_st", label = "Peak DPS ST" },
	{ key = "optimal_aoe", label = "Peak DPS AoE" },
}
local ROTATION_DISCOVERY_SLOTS = {
	{ key = "burst_4", label = "4s ST" },
	{ key = "burst_8", label = "8s ST" },
	{ key = "sustain_30", label = "30s ST" },
	{ key = "sustain_60", label = "60s ST" },
	{ key = "sustain_120", label = "120s ST" },
	{ key = "tab_dot_30", label = "30s tab dots" },
	{ key = "optimal_st", label = "peak ST" },
	{ key = "optimal_aoe", label = "peak AoE" },
}
for targets = 3, 40 do
	DISCOVERY_SLOTS[#DISCOVERY_SLOTS + 1] = { key = "aoe_" .. targets, label = "Best " .. targets .. "-target" }
	ROTATION_DISCOVERY_SLOTS[#ROTATION_DISCOVERY_SLOTS + 1] = { key = "aoe_" .. targets, label = targets .. "t AoE" }
end
local DISCOVERY_POOL_LIMIT = 16
local LOG_MAX_ROWS = #DISCOVERY_SLOTS
local CATEGORY_DISCOVERY_SLOTS = {
	{ key = "tanking", label = "Bear tanking" },
	{ key = "heal_hps", label = "Healing burst" },
	{ key = "heal_efficiency", label = "Healing efficiency" },
	{ key = "heal_sustain_30", label = "30s healing" },
	{ key = "heal_sustain_60", label = "60s healing" },
	{ key = "heal_sustain_120", label = "120s healing" },
	{ key = "heal_chain_30", label = "30s healing chain" },
	{ key = "heal_chain_60", label = "60s healing chain" },
	{ key = "heal_chain_120", label = "120s healing chain" },
	{ key = "heal_tab_30", label = "30s tab HoTs" },
	{ key = "heal_tab_60", label = "60s tab HoTs" },
	{ key = "heal_tab_120", label = "120s tab HoTs" },
	{ key = "heal_aoe_30", label = "30s AoE healing" },
	{ key = "heal_aoe_60", label = "60s AoE healing" },
	{ key = "heal_aoe_120", label = "120s AoE healing" },
	{ key = "cooldown_damage", label = "Cooldown damage" },
	{ key = "survival_boss", label = "Boss survival" },
	{ key = "survival_mobs", label = "Mob pack survival" },
	{ key = "survival_pvp", label = "PvP survival" },
}

local FIGHTS = {
	4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 20, 25, 30, 40, 50, 60, 75, 90, 105, 120, 150, 180,
	240, 300, 360, 420, 480, 540, 600, 720, 900, 1200,
}
local AOE_FIGHT_SECONDS_PER_MOB = { 5, 10, 15, 20, 25, 30 }
local FORM_ORDER = { "cat", "bear", "caster" }
--one button for the whole question the scan is answering, because form and scenario are the same choice asked twice
local ROLE_PRESETS = {
	{ key = "caster", label = "Caster dps", forms = { caster = true },
		scenarios = { singleTarget = true, healing = false, tanking = false } },
	{ key = "melee", label = "Melee dps", forms = { cat = true },
		scenarios = { singleTarget = true, healing = false, tanking = false } },
	{ key = "tank", label = "Tank", forms = { bear = true },
		scenarios = { singleTarget = false, healing = false, tanking = true } },
	{ key = "healer", label = "Healer", forms = { caster = true },
		scenarios = { singleTarget = false, healing = true, tanking = false } },
	{ key = "all", label = "All roles", forms = { cat = true, bear = true, caster = true },
		scenarios = { singleTarget = true, healing = true, tanking = true } },
}
local MAX_ROTATION_RUNS = 10 --the set-up and the loop together: more buttons than this is not a rotation anyone plays
local TIDY_ROTATION_RUNS = 6 --past this it is usually a long way of saying a shorter one, so it has to be clearly better
local MAX_OPENER_RUNS = 5 --you rarely get to set up more than this before the fight is on you
local TIDY_OPENER_RUNS = 3
local LOG_RUN_LIMIT = 40 --what the log will compress into runs before it gives up and draws an ellipsis
local LONG_LOOP_PENALTY = 0.9 --per cast past the tidy length, for the loop and for the set-up before it alike
local SCENARIO_OPTIONS = {
	{ key = "singleTarget", label = "Damage rotations" },
	{ key = "healing", label = "Healing" },
	{ key = "tanking", label = "Tanking" },
}
local ROLE_WEIGHTS = {
	singleTarget = { dps = 70, healing = 10, survival = 10, utility = 10 },
	healing = { dps = 10, healing = 70, survival = 10, utility = 10 },
	tanking = { dps = 10, healing = 10, survival = 70, utility = 10 },
}
local STAT_PROFILE_FIELDS = {
	"low", "high", "offLow", "offHi", "percent", "crit", "speed", "offSpeed",
	"ap", "baseArmor", "armor", "level",
}
local BREAKPOINTS = { 3, 4, 5 }
local SURVIVAL_PROFILES = {
	{ key = "survival_boss", label = "boss 10%/5s", duration = 60, interval = 5, hitPercent = 0.10, attackers = 1 },
	{ key = "survival_mobs", label = "3 mobs 5%/3s", duration = 30, interval = 3, hitPercent = 0.05, attackers = 3 },
	{ key = "survival_pvp", label = "PvP 15%/s x3", duration = 30, interval = 1, burstSeconds = 3, burstPercent = 0.15, steadyPercent = 0.03, attackers = 1 },
}

local function validAoeDuration(fight, targets)
	return targets < 3 or fight >= targets * 5 and fight <= targets * 30
end

local function categoryKey(result)
	if result.category == "survival_pvp" then return "pvp" end
	if result.category then return result.category end
	local targets, fight = result.targets or 1, result.fight or 0
	if not validAoeDuration(fight, targets) then return nil end
	if targets >= 3 then return "aoe_burst" end
	if targets == 1 and fight >= 6 and fight <= 12 then return "st_burst" end
	if targets == 1 and fight >= 30 and fight <= 90 then return "boss_burst" end
end

local function configKey(config)
	local parts = {
		tostring(config.fight or 15), tostring(config.targets or 1), tostring(config.breakpoint or 5),
		tostring(config.dot or "-"), tostring(config.opener or "-"), tostring(config.finisher or "-"),
		tostring(config.filler or "-"), tostring(config.startForm or "-"), tostring(config.conversion or "-"),
	}
	if config.allowedForms then
		local forms = {}
		for _, form in ipairs(FORM_ORDER) do if config.allowedForms[form] then forms[#forms + 1] = form end end
		parts[#parts + 1] = table.concat(forms, ",")
	end
	return table.concat(parts, ":")
end

local function simulationKey(config, context)
	return context .. "|" .. configKey(config)
end

local function copyStatProfile(stats)
	if not stats then return nil end
	local copy = {}
	for _, key in ipairs(STAT_PROFILE_FIELDS) do copy[key] = stats[key] end
	return copy
end

local function currentStatBasis()
	local profiles = {}
	for _, form in ipairs(FORM_ORDER) do
		profiles[form] = copyStatProfile(TT.FormStats and TT.FormStats(form))
	end
	local active = TT.Stats and copyStatProfile(TT.Stats())
	local activeForm = TT.FormProfileKey and TT.FormProfileKey()
	if active and activeForm and not profiles[activeForm] then profiles[activeForm] = active end
	return profiles
end

local function statBasisFromKey(key)
	local tokens = {}
	for token in (key .. ":"):gmatch("(.-):") do tokens[#tokens + 1] = token end
	local profiles, index = {}, 1
	while index <= #tokens do
		local form = tokens[index]
		index = index + 1
		if not form or form == "" then break end
		local profile = {}
		for _, field in ipairs(STAT_PROFILE_FIELDS) do
			profile[field] = tonumber(tokens[index])
			index = index + 1
		end
		for _ = 2, 7 do index = index + 1 end
		profiles[form] = profile
	end
	return next(profiles) and profiles or nil
end

local function normalizeSavedContext(context)
	local version, rotation, ids = context:match("^([^|]+)|(.*)|([^|]*)$")
	if not version then return context end
	local base, statsKey = rotation:match("^([^:]*:[^:]*:[^:]*:[^:]*:[^:]*):(.*)$")
	if not base then return context end
	return version .. "|" .. base .. "|" .. ids, statBasisFromKey(statsKey)
end

local function statRating(profile)
	if not profile then return nil end
	local speed = profile.speed or 0
	if speed <= 0 then return nil end
	local weaponDps = ((profile.low or 0) + (profile.high or 0)) * 0.5
		* (profile.percent or 1) / speed
	local critMultiplier = TT.db and TT.db.critMultiplier or 2
	local critFactor = 1 + (profile.crit or 0) * 0.01 * (critMultiplier - 1)
	return (math.max(0, profile.ap or 0) + weaponDps * 14) * critFactor
end

local function estimateStatAdjustedDps(result, currentBasis)
	local previousBasis = result.statBasis
	if not previousBasis then return nil end
	local weights = {}
	for _, cast in ipairs(result.sequence or {}) do
		if cast.form and not cast.shift then weights[cast.form] = (weights[cast.form] or 0) + 1 end
	end
	if not next(weights) then
		local form = result.startForm or (result.config and result.config.startForm)
		if form then weights[form] = 1 end
	end
	local weightedPrevious, weightedCurrent = 0, 0
	local active = TT.Stats and copyStatProfile(TT.Stats())
	for form, weight in pairs(weights) do
		local oldRating = statRating(previousBasis[form])
		local newProfile = currentBasis[form] or active
		if newProfile and previousBasis[form] and not currentBasis[form] then
			newProfile = copyStatProfile(newProfile)
			newProfile.percent = previousBasis[form].percent
		end
		local newRating = statRating(newProfile)
		if not oldRating or oldRating <= 0 or not newRating then return nil end
		weightedPrevious = weightedPrevious + oldRating * weight
		weightedCurrent = weightedCurrent + newRating * weight
	end
	return weightedPrevious > 0 and weightedCurrent / weightedPrevious or nil
end

local function updateStatEstimate(result, currentBasis)
	result._baseDps = result._baseDps or result.dps
	local ratio = estimateStatAdjustedDps(result, currentBasis)
	if ratio then
		result.dps = result._baseDps * ratio
		result.statAdjusted = math.abs(ratio - 1) > 0.0001
	else
		result.dps = result._baseDps
		result.statAdjusted = nil
	end
end

local function migrateCacheContext(cache, context)
	local currentBasis, moves = currentStatBasis(), {}
	for key, result in pairs(cache) do
		if result.context ~= context then
			local normalized, basis = normalizeSavedContext(result.context or "")
			if normalized == context and result.config then
				result.statBasis = result.statBasis or basis or currentBasis
				result._baseDps = result._baseDps or result.dps
				updateStatEstimate(result, currentBasis)
				moves[#moves + 1] = { oldKey = key, newKey = simulationKey(result.config, context), result = result }
			end
		elseif result.config then
			result.statBasis = result.statBasis or currentBasis
			updateStatEstimate(result, currentBasis)
		end
	end
	for _, move in ipairs(moves) do
		local existing = cache[move.newKey]
		if not existing or (move.result.dps or 0) > (existing.dps or 0) then cache[move.newKey] = move.result end
		cache[move.oldKey] = nil
		move.result.context = context
	end
	return currentBasis
end

local function categoryKeys(result)
	if result.healScenario then return {} end
	if result.category == nil and result.targets == 2 then return {} end
	if result.category == nil and (result.targets or 1) >= 3
		and not validAoeDuration(result.fight or 0, result.targets) then return {} end
	if result.category == nil and (result.targets or 1) == 1
		and result.fight and result.fight >= 30 and result.fight <= 90 then
		return { "boss_burst" }
	end
	local key = categoryKey(result)
	return key and { key } or {}
end

local logChild, logContainerWidth, panelContentWidth, panelContentLeft, panelFontScale, panelMaxHeight
local rotationProfile, similarRotation, discoveryScore

local function showAbilityTooltip(button)
	if not GameTooltip then return end
	GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
	if button.spellID and not button.missingTexture and GameTooltip.SetSpellByID then
		GameTooltip:SetSpellByID(button.spellID)
		--the spell's own tooltip has already drawn and sized itself, so anything added after it has to make its own room
		local drawn = GameTooltip.NumLines and GameTooltip:NumLines() or nil
		if button.tab then GameTooltip:AddLine("Tab to another target", 1, 0.82, 0) end
		if button.castTime then GameTooltip:AddLine(string.format("Cast at %.1fs", button.castTime), 0.7, 0.7, 0.7) end
		TT.FitAddedLines(GameTooltip, drawn)
		return
	end
	if GameTooltip.ClearLines then GameTooltip:ClearLines() end
	GameTooltip:AddLine(button.abilityName or "Unknown ability")
	if button.tab then GameTooltip:AddLine("Tab to another target", 1, 0.82, 0) end
	if button.spellID then GameTooltip:AddLine("Spell ID: " .. button.spellID, 0.7, 0.7, 0.7) end
	if button.castTime then GameTooltip:AddLine(string.format("Cast at %.1fs", button.castTime), 0.7, 0.7, 0.7) end
	GameTooltip:Show()
end

local function hideOwnedTooltip(button)
	if GameTooltip and GameTooltip.IsOwned and GameTooltip:IsOwned(button) then GameTooltip:Hide() end
end

local function showScenarioTooltip(button)
	if not GameTooltip then return end
	GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
	if GameTooltip.ClearLines then GameTooltip:ClearLines() end
	GameTooltip:AddLine(button.scenarioLabel, 1, 0.82, 0)
	GameTooltip:AddLine(button.scenarioDescription, 0.8, 0.8, 0.8)
	GameTooltip:Show()
end

local function scenarioBadgeInfo(label, result)
	local seconds = label:match("^(%d+)s ST$")
	if seconds then return seconds .. "s", seconds .. "-second rotation against 1 enemy" end
	local targets = label:match("^(%d+)t AoE$")
	if targets then
		local fight = result.fight or 0
		return targets .. "t", string.format("%d-target AoE over %.0f seconds (%.1f seconds per mob)",
			tonumber(targets), fight, tonumber(targets) > 0 and fight / tonumber(targets) or 0)
	end
	seconds = label:match("^(%d+)s peak ST$")
	if seconds then return seconds .. "s", seconds .. "-second peak rotation against 1 enemy" end
	seconds = label:match("^(%d+)s peak AoE$")
	if seconds then return seconds .. "s", seconds .. "-second peak multi-target rotation" end
	if label == "30s tab dots" then return "Tab", "30-second rotation spreading damage-over-time effects across targets" end
	if label:find("Weighted recommendation:", 1, true) then return "Best", label end
	if label == "boss 10%/5s" then return "Boss", "Boss survival against a hit for 10% health every 5 seconds" end
	if label == "3 mobs 5%/3s" then return "3x", "Mob-pack survival against 3 attackers, each hitting for 5% health every 3 seconds" end
	if label == "PvP 15%/s x3" then return "PvP", "PvP survival against 3 hits per second for 15% health each" end
	seconds = label:match("^(%d+)s healing$")
	if seconds then return "Heal", seconds .. "-second healing chain" end
	seconds = label:match("^(%d+)s tab HoTs$")
	if seconds then return "Tab", seconds .. "-second HoT rotation across " .. (result.targets or 1) .. " injured allies" end
	seconds = label:match("^(%d+)s AoE healing$")
	if seconds then return "AoE", seconds .. "-second AoE healing rotation affecting up to "
		.. (result.effectiveTargets or result.targets or 1) .. " injured allies per cast" end
	if label:lower():find("healing", 1, true) then return "Heal", label end
	if label:lower():find("tanking", 1, true) then return "Tank", label end
	if label:lower():find("survival", 1, true) then return "Live", label end
	if label:lower():find("pvp", 1, true) then return "PvP", label end
	return label:sub(1, 3), label
end

local function createScenarioBadge(parent)
	local button = CreateFrame("Button", nil, parent)
	button:SetSize(LOG_BADGE_WIDTH * panelFontScale, LOG_BADGE_HEIGHT * panelFontScale)
	button:EnableMouse(true)
	button.background = button:CreateTexture(nil, "BACKGROUND")
	button.background:SetAllPoints()
	button.background:SetColorTexture(0.12, 0.10, 0.08, 0.95)
	button.text = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	button.text:SetPoint("CENTER")
	button.text:SetWordWrap(false)
	button.text:SetTextColor(TT.skin.gold[1], TT.skin.gold[2], TT.skin.gold[3])
	scaleFont(button.text, panelFontScale)
	button:SetScript("OnEnter", showScenarioTooltip)
	button:SetScript("OnLeave", hideOwnedTooltip)
	return button
end

local function showFormTooltip(button)
	if not GameTooltip then return end
	GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
	if GameTooltip.ClearLines then GameTooltip:ClearLines() end
	GameTooltip:AddLine("Starts in " .. (button.formLabel or "no form"))
	GameTooltip:AddLine("Standing in it already, so no shift is charged", 0.7, 0.7, 0.7)
	GameTooltip:Show()
end

local function setAbilityIcon(button, cast)
	local spellID = cast and cast.id
	local texture = spellID and C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(spellID)
	button.spellID = spellID
	button.abilityName = cast and cast.name
	button.tab = cast and cast.tab
	button.castTime = cast and cast.time
	button.missingTexture = not texture
	button.iconTexture:SetTexture(texture or "Interface\\Icons\\INV_Misc_QuestionMark")
	local repeated = cast and cast.count and cast.count > 1 and cast.count
	if button.repeats then
		button.repeats:SetText(repeated and (cast.spread and ("x" .. repeated) or (repeated .. "x")) or "")
		local shade = cast and cast.spread and TT.skin.gold or TT.skin.text
		button.repeats:SetTextColor(shade[1], shade[2], shade[3])
	end
	button.spread = cast and cast.spread
	button:Show()
end

local function createAbilityIcon(parent, size)
	local button = CreateFrame("Button", nil, parent)
	button:SetSize(size, size)
	button:EnableMouse(true)
	button.iconTexture = button:CreateTexture(nil, "ARTWORK")
	button.iconTexture:SetAllPoints()
	--a run of the same button is one icon with a count on it, the way the panel draws it, rather than the same icon over again
	button.repeats = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	button.repeats:SetPoint("TOPLEFT", 1, -1)
	button:SetScript("OnEnter", showAbilityTooltip)
	button:SetScript("OnLeave", hideOwnedTooltip)
	return button
end

local function startingFormTexture(form)
	if form == "cat" then return TT.FormTexture and TT.FormTexture(form) or C_Spell.GetSpellTexture(768) end
	if form == "bear" then return TT.FormTexture and TT.FormTexture(form) or C_Spell.GetSpellTexture(5487) end
end

local function createFormIcon(parent, size)
	local button = CreateFrame("Button", nil, parent)
	button:SetSize(size, size)
	button:EnableMouse(true)
	button.iconTexture = button:CreateTexture(nil, "ARTWORK")
	button.iconTexture:SetAllPoints()
	button.iconTexture:SetVertexColor(0.55, 0.55, 0.55)
	button:SetScript("OnEnter", showFormTooltip)
	button:SetScript("OnLeave", hideOwnedTooltip)
	button:Hide()
	return button
end

local function setStartingForm(icon, form)
	local texture = startingFormTexture(form)
	if not texture then
		icon.form = nil
		icon:Hide()
		return nil
	end
	local _, formName = TT.FormByName and TT.FormByName(form)
	icon.form = form
	icon.formLabel = formName and formName:lower() or (form .. " form")
	icon.iconTexture:SetTexture(texture)
	icon:Show()
	return texture
end

local function abilityStartForm(ability)
	local forms = TT.SimulationForms and TT.SimulationForms(ability)
	if forms then
		if ability.power == "rage" and forms.bear then return "bear" end
		if ability.power == "energy" and forms.cat then return "cat" end
		for _, form in ipairs(FORM_ORDER) do if forms[form] then return form end end
	end
	if ability.power == "rage" then return "bear"
	elseif ability.power == "energy" then return "cat" end
end

local function abilityAllowedInForm(ability, form)
	local forms = TT.SimulationForms and TT.SimulationForms(ability)
	return not forms or forms[form] == true
end

local function rotationUsesFormAbility(result, form)
	for _, cast in ipairs(result.sequence or {}) do
		if cast.form == form and cast.id and not cast.shift then
			for _, ability in ipairs(simulationAbilitiesById[tostring(cast.id)] or {}) do
				local forms = TT.SimulationForms and TT.SimulationForms(ability)
				if forms and forms[form] then return true end
				if ability.power == "rage" and form == "bear" or ability.power == "energy" and form == "cat" then
					return true
				end
			end
		end
	end
	return false
end

local function weightedDiscovery()
	if not activeOptions or not activeOptions.enabled then return nil end
	local candidates, seen = {}, {}
	local function add(result)
		if result and not seen[result] and resultInScope(result, activeOptions) then
			seen[result] = true
			candidates[#candidates + 1] = result
		end
	end
	for _, result in pairs(bestByCategory) do add(result) end
	for _, result in pairs(discoveryResults) do add(result) end
	for _, pool in pairs(discoveryPools) do for _, result in ipairs(pool) do add(result) end end
	local function metric(result)
		if result.category == "heal_efficiency" then return "healing-efficiency", result.score or 0, "Healing"
		elseif result.healScenario or result.category == "heal_hps"
			or result.category and result.category:match("^heal_sustain_") then
			return "healing-rate", result.score or 0, "Healing"
		elseif result.category and result.category:match("^survival_") then
			return "survival", result.score or 0, "Survival"
		elseif result.category == "utility" or result.category == "cooldown_damage"
			or result.category == "cooldown_toughness" then return "utility", result.score or 0, "Utility"
		elseif not result.category and result.dps then return "dps", result.dps, "DPS" end
	end
	local maxima = {}
	for _, result in ipairs(candidates) do
		local group, value = metric(result)
		if group then maxima[group] = math.max(maxima[group] or 0, value) end
	end
	local groupWeights = {
		dps = activeOptions.weights.dps,
		["healing-efficiency"] = activeOptions.weights.healing,
		["healing-rate"] = activeOptions.weights.healing,
		survival = activeOptions.weights.survival,
		utility = activeOptions.weights.utility,
	}
	local best
	for _, result in ipairs(candidates) do
		local group, value, label = metric(result)
		local maximum, weight = group and maxima[group], group and groupWeights[group]
		local score = maximum and maximum > 0 and weight * value / maximum or 0
		if score > 0 and (not best or score > best.score) then best = { result = result, score = score, label = label } end
	end
	return best
end

--one run of icons with the arrows between them, centred in its own container, cut off with an ellipsis when it will not fit
local function drawStrip(strip, casts, formOffset)
	casts = casts or {}
	local totalWidth = formOffset
	for index = 1, #casts do
		if index > 1 then totalWidth = totalWidth + (casts[index].tab and 32 or 18) * panelFontScale end
		totalWidth = totalWidth + LOG_ICON_SIZE + 2
	end
	local truncated = totalWidth > logContainerWidth
	local limit = logContainerWidth - (truncated and 26 * panelFontScale or 0)
	local shown, measuredX = 0, formOffset
	for index = 1, #casts do
		local arrowWidth = index > 1 and (casts[index].tab and 32 or 18) * panelFontScale or 0
		local nextX = measuredX + arrowWidth + LOG_ICON_SIZE + 2
		if nextX > limit then break end
		shown, measuredX = index, nextX
	end
	if truncated and shown == #casts then truncated = false end
	--left aligned, so the set-up and the loop line up under each other and sit next to the captions that name them
	local x = formOffset
	for j = 1, shown do
		if j > 1 then
			local tabbing = casts[j].tab
			local arrow = strip.arrows[j - 1]
			if not arrow then
				arrow = strip.container:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
				arrow:SetJustifyH("CENTER")
				scaleFont(arrow, panelFontScale)
				strip.arrows[j - 1] = arrow
			end
			local arrowWidth = (tabbing and 32 or 18) * panelFontScale
			arrow:ClearAllPoints()
			arrow:SetPoint("LEFT", strip.container, "LEFT", x, 0)
			arrow:SetWidth(arrowWidth)
			arrow:SetText(tabbing and "tab" or ">")
			local tint = tabbing and TT.skin.gold or TT.skin.goldDim
			arrow:SetTextColor(tint[1], tint[2], tint[3])
			arrow:Show()
			x = x + arrowWidth
		end
		local icon = strip.icons[j]
		if not icon then
			icon = createAbilityIcon(strip.container, LOG_ICON_SIZE)
			strip.icons[j] = icon
		end
		icon:ClearAllPoints()
		icon:SetPoint("LEFT", strip.container, "LEFT", x, 0)
		setAbilityIcon(icon, casts[j])
		x = x + LOG_ICON_SIZE + 2
	end
	for j = shown + 1, #strip.icons do strip.icons[j]:Hide() end
	for j = math.max(1, shown), #strip.arrows do strip.arrows[j]:Hide() end
	if truncated then
		strip.ellipsis:SetText("...")
		strip.ellipsis:ClearAllPoints()
		strip.ellipsis:SetPoint("LEFT", strip.container, "LEFT", x + 2, 0)
	else
		strip.ellipsis:SetText("")
	end
end

local function refreshLog()
	if #logRows == 0 then return end
	local entries, rotations, aoeRotations = {}, {}, {}
	local function addLabel(entry, label)
		for _, current in ipairs(entry.labels) do if current == label then return end end
		entry.labels[#entry.labels + 1] = label
	end
	local function addRotation(slot, result)
		local profile = rotationProfile(result)
		for _, entry in ipairs(rotations) do
			if similarRotation(profile, entry.profile)
				and (slot.key ~= "tab_dot_30" or profile.hasTab == entry.profile.hasTab) then
				if discoveryScore(result, slot.key) > discoveryScore(entry.result, slot.key) then entry.result = result end
				if slot.key:match("^aoe_%d+$") then
					local hasTargetLabel = false
					for _, label in ipairs(entry.labels) do if label:match("^%d+t AoE$") then hasTargetLabel = true end end
					if not hasTargetLabel then addLabel(entry, slot.label) end
				else
					addLabel(entry, slot.label)
				end
				return
			end
		end
		local entry = { result = result, profile = profile, labels = { slot.label } }
		rotations[#rotations + 1] = entry
	end
	for _, slot in ipairs(ROTATION_DISCOVERY_SLOTS) do
		local pool = discoveryPools[slot.key]
		if pool and pool[1] then
			local label = slot.key == "optimal_st" and string.format("%.0fs peak ST", pool[1].fight or 0)
				or slot.key == "optimal_aoe" and string.format("%.0fs peak AoE", pool[1].fight or 0)
				or slot.label
			local single = discoveryPools.optimal_st and discoveryPools.optimal_st[1]
			local profile = rotationProfile(pool[1])
			local singleProfile = single and rotationProfile(single)
			local duplicatesSingle = (slot.key == "optimal_aoe" or slot.key:match("^aoe_%d+$"))
				and singleProfile and profile.key == singleProfile.key
			if not duplicatesSingle then addRotation({ key = slot.key, label = label }, pool[1]) end
		end
	end
	for _, entry in ipairs(rotations) do
		local hasAoe, hasTab = false, false
		for _, label in ipairs(entry.labels) do
			if label:match("^%d+t AoE$") then hasAoe = true end
			if label == "30s tab dots" then hasTab = true end
		end
		local target = hasAoe and not hasTab and aoeRotations or entries
		target[#target + 1] = entry
	end

	local categoryEntries = {}
	for _, slot in ipairs(CATEGORY_DISCOVERY_SLOTS) do
		local result = discoveryResults[slot.key]
		if result then
			local ids, seen = {}, {}
			for _, cast in ipairs(result.sequence or {}) do
				if cast.id and not seen[cast.id] then
					seen[cast.id] = true
					ids[#ids + 1] = tostring(cast.id)
				end
			end
			local id = #ids > 0 and table.concat(ids, ">") or tostring(result.id or slot.key)
			if result.healScenario then id = id .. ":" .. (result.healMode or "single") end
			if slot.key:find("^survival_") then id = id .. ":" .. slot.key end
			local entry = categoryEntries[id]
			if not entry then
				entry = { result = result, labels = {}, categoryKeys = {} }
				categoryEntries[id] = entry
				entries[#entries + 1] = entry
			end
			entry.categoryKeys[slot.key] = result
			addLabel(entry, slot.key:find("^survival_") and result.label or slot.label)
		end
	end
	for _, entry in ipairs(aoeRotations) do entries[#entries + 1] = entry end
	--the runner up for a slot only ever differs in trivia, so the second rotation worth a row is the one a
	--different form would run; at most one per form, named by the form rather than called an alternative
	local shownForms = {}
	for _, entry in ipairs(rotations) do
		local form = entry.result.config and entry.result.config.startForm
		if form and rotationUsesFormAbility(entry.result, form) then shownForms[form] = true end
	end
	for _, slot in ipairs(ROTATION_DISCOVERY_SLOTS) do
		for _, result in ipairs(discoveryPools[slot.key] or {}) do
			local form = result.config and result.config.startForm
			if form and not shownForms[form] and rotationUsesFormAbility(result, form) then
				shownForms[form] = true
				local entry = { result = result, profile = rotationProfile(result),
					labels = { form .. " " .. slot.label } }
				rotations[#rotations + 1] = entry
				entries[#entries + 1] = entry
			end
		end
	end
	local weighted = weightedDiscovery()
	if weighted then
		local profile = rotationProfile(weighted.result)
		for index, entry in ipairs(entries) do
			local matches = entry.result == weighted.result
			for _, result in pairs(entry.categoryKeys or {}) do
				if result == weighted.result then matches = true break end
			end
			if not matches and entry.profile then matches = similarRotation(profile, entry.profile) end
			if matches then
				table.remove(entries, index)
				addLabel(entry, "Weighted recommendation: " .. weighted.label)
				table.insert(entries, 1, entry)
				break
			end
		end
	end

	local visibleRank, rowTop = 0, 0
	for i = 1, LOG_MAX_ROWS do
		local row = logRows[i]
		local entry = entries[i]
		if entry then
			visibleRank = visibleRank + 1
			local r = entry.result
			row.rank:SetText(string.format("|cff40ff40%d.|r", visibleRank))
			local hps = entry.categoryKeys and entry.categoryKeys.heal_hps
			local healEfficiency = entry.categoryKeys and entry.categoryKeys.heal_efficiency
			local sustained = {}
			for _, horizon in ipairs(HEAL_HORIZONS) do
				local result = entry.categoryKeys and (entry.categoryKeys["heal_sustain_" .. horizon]
					or entry.categoryKeys["heal_chain_" .. horizon])
				if result then sustained[#sustained + 1] = string.format("%.0f", result.score) end
			end
			local multiHealing = entry.categoryKeys and (entry.categoryKeys.heal_tab_30 or entry.categoryKeys.heal_aoe_30
				or entry.categoryKeys.heal_tab_60 or entry.categoryKeys.heal_aoe_60
				or entry.categoryKeys.heal_tab_120 or entry.categoryKeys.heal_aoe_120)
			local value = #sustained > 0 and table.concat(sustained, "/") .. " hp/s"
				or multiHealing and string.format("%.0f total hp/s x%d", multiHealing.score, multiHealing.targets or 1)
				or hps and healEfficiency and string.format("%.0f/s %.1f/%s", hps.score, healEfficiency.score, healEfficiency.power or "res")
				or hps and string.format("%.0f hp/s", hps.score)
				or healEfficiency and string.format("%.1f hp/%s", healEfficiency.score, healEfficiency.power or "resource")
				or r.display
				or string.format("%s%.0f", r.statAdjusted and "~" or "", r.dps or 0)
			row.dps:SetText(value)
			local seq = r.sequence or (r.id and { { id = r.id, name = r.label } }) or {}
			local form = r.startForm or (r.config and r.config.startForm) or nil
			setStartingForm(row.startForm, form)
			--the set-up and the part you repeat are different things, so they are drawn as different strips
			local opener, loop, loopTime = TT.SplitCycle(seq)
			if not loop or #loop == 0 then opener, loop, loopTime = nil, seq, nil end
			--a set-up that is only the shapeshift is not a set-up
			local pressed = 0
			for _, cast in ipairs(opener or {}) do if not cast.shift then pressed = pressed + 1 end end
			if pressed == 0 then opener = nil end
			local openerRuns = opener and TT.Compress(opener, 1, #opener, LOG_RUN_LIMIT) or nil
			local loopRuns = TT.Compress(loop, 1, #loop, LOG_RUN_LIMIT)
			drawStrip(row.opener, openerRuns, 0)
			drawStrip(row.loop, loopRuns, 0)
			local hasOpener = openerRuns and #openerRuns > 0
			row.opener.caption:SetText(hasOpener and "open" or "")
			row.loop.caption:SetText(hasOpener and (loopTime and string.format("loop %.1fs", loopTime) or "loop") or "")
			row.opener.container:ClearAllPoints()
			row.opener.container:SetPoint("LEFT", LOG_SEQUENCE_LEFT * panelFontScale,
				(LOG_CONTENT_LIFT + LOG_STRIP_LIFT) * panelFontScale)
			row.loop.container:ClearAllPoints()
			row.loop.container:SetPoint("LEFT", LOG_SEQUENCE_LEFT * panelFontScale,
				(LOG_CONTENT_LIFT - (hasOpener and LOG_STRIP_LIFT or 0)) * panelFontScale)
			row.rank:ClearAllPoints()
			row.rank:SetPoint("LEFT", 0, LOG_CONTENT_LIFT * panelFontScale)
			row.dps:ClearAllPoints()
			row.dps:SetPoint("LEFT", 34 * panelFontScale, LOG_CONTENT_LIFT * panelFontScale)
			local badgeCount = math.min(#entry.labels, LOG_MAX_BADGES)
			local badgeWidth = LOG_BADGE_WIDTH * panelFontScale
			local badgeGap = 3 * panelFontScale
			for index, label in ipairs(entry.labels) do
				local badge = row.categoryIcons[index]
				if not badge then
					badge = createScenarioBadge(row.frame)
					row.categoryIcons[index] = badge
				end
				if index <= badgeCount then
					badge:ClearAllPoints()
					badge:SetPoint("TOPRIGHT", row.frame, "TOPRIGHT",
						-8 * panelFontScale - (index - 1) * (badgeWidth + badgeGap),
						-(LOG_CONTENT_LIFT + 10) * panelFontScale)
					if #entry.labels > LOG_MAX_BADGES and index == LOG_MAX_BADGES then
						badge.scenarioLabel = "+" .. (#entry.labels - LOG_MAX_BADGES + 1)
						local descriptions = {}
						for labelIndex = LOG_MAX_BADGES, #entry.labels do
							local _, description = scenarioBadgeInfo(entry.labels[labelIndex], r)
							descriptions[#descriptions + 1] = description
						end
						badge.scenarioDescription = table.concat(descriptions, ", ")
					else
						badge.scenarioLabel, badge.scenarioDescription = scenarioBadgeInfo(label, r)
					end
					badge.text:SetText(badge.scenarioLabel)
					badge:Show()
				else
					badge:Hide()
				end
			end
			for index = #entry.labels + 1, #row.categoryIcons do row.categoryIcons[index]:Hide() end
			--a row only reserves the height it uses, since most rotations go straight into their loop
			local height = hasOpener and LOG_ROW_HEIGHT or LOG_SHORT_ROW_HEIGHT
			row.frame:SetHeight(height)
			row.frame:ClearAllPoints()
			row.frame:SetPoint("TOPLEFT", 0, -rowTop)
			row.frame:SetPoint("RIGHT")
			rowTop = rowTop + height
			row.frame:Show()
		else
			row.frame:Hide()
		end
	end
	local visibleRows = math.max(1, math.min(#entries, LOG_MAX_ROWS))
	local y = -36
	for _, category in ipairs(CATEGORIES) do
		local slot = categorySlots[category.key]
		slot.row:ClearAllPoints()
		slot.row:SetPoint("TOP", frame, "TOP", 0, y)
		y = y - CATEGORY_HEIGHT
	end
	y = y - 8
	discoveryLabel:ClearAllPoints()
	discoveryLabel:SetPoint("TOP", frame, "TOP", 0, y)
	y = y - 18
	checkingText:ClearAllPoints()
	checkingText:SetPoint("TOP", frame, "TOP", 0, y)
	y = y - 14
	logScroll:ClearAllPoints()
	logScroll:SetPoint("TOP", frame, "TOP", 0, y)
	local logHeight = math.max(logRowHeight, rowTop)
	panelHeight = math.min(panelMaxHeight, -y + logHeight + FOOTER_HEIGHT)
	frame:SetHeight(panelHeight)
	local scrollHeight = math.min(logHeight, math.max(logRowHeight, panelHeight + y - FOOTER_HEIGHT))
	logScroll:SetSize(panelContentWidth, scrollHeight)
	if logChild then logChild:SetHeight(logHeight) end
end

rotationProfile = function(result)
	if result._profile and result._profile.version == 4 then return result._profile end
	local tokens, abilities, pairsSeen, abilityNames = {}, {}, {}, {}
	local hasTab = false
	for _, cast in ipairs(result.sequence or {}) do
		local token = tostring(cast.id or cast.name or "?") .. (cast.points and (":" .. cast.points) or "")
		if cast.tab then token, hasTab = token .. ":tab", true end
		if tokens[#tokens] ~= token then tokens[#tokens + 1] = token end
		local ability = tostring(cast.id or cast.name or "?")
		abilities[ability] = true
	end
	for index = 1, #tokens - 1 do pairsSeen[tokens[index] .. ">" .. tokens[index + 1]] = true end
	for ability in pairs(abilities) do abilityNames[#abilityNames + 1] = ability end
	table.sort(abilityNames)
	return {
		key = table.concat(tokens, ">"),
		abilityKey = table.concat(abilityNames, ","),
		abilities = abilities,
		pairs = pairsSeen,
		hasTab = hasTab,
		version = 4,
	}
end

local function overlap(left, right)
	local common, total = 0, 0
	for value in pairs(left) do
		total = total + 1
		if right[value] then common = common + 1 end
	end
	for value in pairs(right) do if not left[value] then total = total + 1 end end
	return total > 0 and common / total or 1
end

similarRotation = function(left, right)
	return left and right and (left.abilityKey == right.abilityKey or left.key == right.key
		or overlap(left.abilities, right.abilities) >= 0.75 and overlap(left.pairs, right.pairs) >= 0.6)
end

--one icon per run of the same ability, which is what the strip draws, so the count and the picture can never disagree
local function runsOf(casts)
	if type(casts) ~= "table" or #casts == 0 then return {} end
	return TT.Compress(casts, 1, #casts, LOG_RUN_LIMIT)
end

--a cooldown comes round on its own clock rather than being part of the cadence, so it is not one of the buttons
local function countRuns(runs)
	local count = 0
	for _, run in ipairs(runs or {}) do
		local known = simulationAbilitiesById and simulationAbilitiesById[tostring(run.id)]
		local ability = known and known[1]
		if not ability or (ability.cooldown or 0) <= 0 then count = count + 1 end
	end
	return count
end

--the set-up you only get to do once, the part you repeat, and the two of them together, which is what the limit is on
local function shape(result)
	if not result then return { loop = 0, opener = 0, total = 0 } end
	if result._shape then return result._shape end
	local casts = result.sequence
	if result.category or result.healScenario or type(casts) ~= "table" or type(casts[1]) ~= "table" or not casts[1].key then
		result._shape = { loop = 0, opener = 0, total = 0 }
		return result._shape
	end
	local opener, loop = TT.SplitCycle(casts)
	local openerRuns, loopRuns = countRuns(runsOf(opener)), countRuns(runsOf(loop or casts))
	result._shape = { loop = loopRuns, opener = openerRuns, total = openerRuns + loopRuns }
	return result._shape
end

function TT.LoopCasts(result)
	return shape(result).loop
end

function TT.OpenerCasts(result)
	return shape(result).opener
end

function TT.RotationRuns(result)
	return shape(result).total
end

--a rambling rotation or a long set-up is nearly always a variation of a tidier one, so it is pushed down rather than celebrated
local function loopFactor(result)
	local counts = shape(result)
	local factor = 1
	if counts.total > TIDY_ROTATION_RUNS then factor = factor * LONG_LOOP_PENALTY ^ (counts.total - TIDY_ROTATION_RUNS) end
	if counts.opener > TIDY_OPENER_RUNS then factor = factor * LONG_LOOP_PENALTY ^ (counts.opener - TIDY_OPENER_RUNS) end
	return factor
end

function TT.LoopFactor(result)
	return loopFactor(result)
end

function TT.RotationTooLong(result)
	local counts = shape(result)
	return counts.total > MAX_ROTATION_RUNS or counts.opener > MAX_OPENER_RUNS
end

local function rememberElite(result, key)
	if not result.config or eliteKeys[key] then return end
	local profile = rotationProfile(result)
	for index, entry in ipairs(elitePool) do
		if similarRotation(profile, entry.result._profile or rotationProfile(entry.result)) then
			if result.dps > entry.result.dps then
				eliteKeys[entry.key] = nil
				result._profile = profile
				elitePool[index] = { result = result, key = key }
				eliteKeys[key] = true
				table.sort(elitePool, function(a, b) return a.result.dps > b.result.dps end)
			end
			return
		end
	end
	result._profile = profile
	eliteKeys[key] = true
	elitePool[#elitePool + 1] = { result = result, key = key }
	table.sort(elitePool, function(a, b) return a.result.dps > b.result.dps end)
	while #elitePool > 32 do
		local removed = table.remove(elitePool)
		eliteKeys[removed.key] = nil
	end
end

discoveryScore = function(result, key)
	if key == "heal_hps" or key == "heal_efficiency" or result.healScenario then return result.score or 0 end
	return (result.dps or 0) * loopFactor(result)
end

local function trackDiscovery(result)
	--every path into the log comes through here, including the one that reloads a finished scan from the cache
	if TT.RotationTooLong(result) then return end
	local slots = {}
	if result.category == nil and not result.healScenario and result.targets == 2 then return end
	if result.healScenario then
		local prefix = result.healMode == "tab" and "heal_tab_"
			or result.healMode == "aoe" and "heal_aoe_"
			or result.healChain and "heal_chain_" or "heal_sustain_"
		slots[1] = prefix .. result.fight
	elseif result.category == "heal_hps" or result.category == "heal_efficiency"
		or result.category == "cooldown_damage" or result.category == "utility"
		or result.category == "tanking"
		or result.category == "survival_boss" or result.category == "survival_mobs"
		or result.category == "survival_pvp" then
		slots[1] = result.category
	elseif result.targets == 1 and result.fight == 4 then
		slots[1] = "burst_4"
	elseif result.targets == 1 and result.fight == 8 then
		slots[1] = "burst_8"
	elseif result.targets == 1 and result.fight == 30 then
		slots[1] = "sustain_30"
	elseif result.targets == 1 and result.fight == 60 then
		slots[1] = "sustain_60"
	elseif result.targets == 1 and result.fight == 120 then
		slots[1] = "sustain_120"
	elseif result.targets and result.targets >= 3 and validAoeDuration(result.fight or 0, result.targets) then
		slots[1] = "aoe_" .. result.targets
	end
	if result.category == nil and not result.healScenario and result.targets then
		slots[#slots + 1] = result.targets == 1 and "optimal_st" or "optimal_aoe"
	end
	if result.category == nil and result.targets and result.targets >= 3 and result.fight == 30 then
		for _, cast in ipairs(result.sequence or {}) do
			if cast.tab then slots[#slots + 1] = "tab_dot_30" break end
		end
	end
	for _, key in ipairs(slots) do
		local previous = discoveryResults[key]
		if not previous or discoveryScore(result, key) > discoveryScore(previous, key) then
			discoveryResults[key] = result
		end
		if result.category == nil and not result.healScenario then
			local pool = discoveryPools[key] or {}
			discoveryPools[key] = pool
			local profile = rotationProfile(result)
			local matched
			for index, candidate in ipairs(pool) do
				if similarRotation(profile, rotationProfile(candidate)) then matched = index break end
			end
			if matched then
				if discoveryScore(result, key) > discoveryScore(pool[matched], key) then pool[matched] = result end
			else
				pool[#pool + 1] = result
			end
			table.sort(pool, function(left, right) return discoveryScore(left, key) > discoveryScore(right, key) end)
			while #pool > DISCOVERY_POOL_LIMIT do table.remove(pool) end
		end
	end
end

local function formatDps(result)
	return string.format("%s%.0f", result.statAdjusted and "~" or "", result.dps or 0)
end

local function updateCategory(cat, result)
	local slot = categorySlots[cat.key]
	if not slot then return end
	if cat.key == "tanking" then
		slot.dps:SetText(result.display or "Bear survival")
		local detail = result.detail or "Bear only"
		if bestByCategory.taunt then detail = detail .. ", taunt" end
		slot.detail:SetText(detail)
	elseif result.display then
		slot.dps:SetText(result.display)
	elseif cat.key == "heal_hps" then
		slot.dps:SetText(string.format("%.0f hp/s", result.score))
	elseif cat.key == "heal_efficiency" then
		slot.dps:SetText(string.format("%.1f hp/%s", result.score, result.power or "resource"))
	else
		slot.dps:SetText(formatDps(result) .. " dps")
	end

	if cat.key ~= "tanking" then
		local label = result.category and (result.label or "") or string.format("%dt %ds", result.targets or 1, result.fight or 15)
		if #label > 16 then label = label:sub(1, 13) .. "..." end
		slot.detail:SetText(label)
	end
	local sequence = {}
	for _, cast in ipairs(result.sequence or (result.id and { { id = result.id } }) or {}) do sequence[#sequence + 1] = cast end
	if cat.key == "tanking" then
		local taunt = bestByCategory.taunt
		if taunt then sequence[#sequence + 1] = { id = taunt.id, name = taunt.name } end
	end
	local form = result.startForm or (result.config and result.config.startForm)
		or abilityStartForm((result.sequence and result.sequence[1]) or result)
	local formTexture = setStartingForm(slot.formMarker, form)
	local startX = slot.iconStartX + (formTexture and CATEGORY_ICON_SIZE + CATEGORY_ICON_GAP or 0)
	local shown = math.min(#sequence, CATEGORY_MAX_ICONS - (formTexture and 1 or 0))
	for i = 1, shown do
		local icon = slot.icons[i]
		if not icon then
			icon = createAbilityIcon(slot.row, CATEGORY_ICON_SIZE)
			slot.icons[i] = icon
		end
		icon:ClearAllPoints()
		icon:SetPoint("LEFT", startX + (i - 1) * (CATEGORY_ICON_SIZE + CATEGORY_ICON_GAP), 0)
		setAbilityIcon(icon, sequence[i])
	end
	for i = shown + 1, #slot.icons do slot.icons[i]:Hide() end
end

local function resultScore(result, key)
	if result.category then return result.score or result.dps or 0 end
	return (result.dps or 0) * loopFactor(result)
end

local function refreshAoeCategories()
	local category, baseline = "aoe_burst", bestByCategory.st_burst
	local result, slot = bestByCategory[category], categorySlots[category]
	local profile, baselineProfile = result and rotationProfile(result), baseline and rotationProfile(baseline)
	if result and baselineProfile and profile.key == baselineProfile.key then
		slot.dps:SetText("—")
		slot.detail:SetText("")
		for _, icon in ipairs(slot.icons) do icon:Hide() end
	elseif result then
		for _, item in ipairs(CATEGORIES) do if item.key == category then updateCategory(item, result) end end
	end
end

local function pruneCache(cache)
	local byResult, entries, keep = {}, {}, {}
	for key, result in pairs(cache) do
		byResult[result] = key
		entries[#entries + 1] = { key = key, result = result }
	end
	if #entries <= CACHE_MAX_ENTRIES then return #entries end

	local function retain(result)
		local key = byResult[result]
		if key and not keep[key] then keep[key] = true end
	end
	for _, result in pairs(bestByCategory) do retain(result) end
	for _, result in pairs(discoveryResults) do retain(result) end
	for _, pool in pairs(discoveryPools) do for _, result in ipairs(pool) do retain(result) end end
	for _, elite in ipairs(elitePool) do retain(elite.result) end

	local retained = 0
	for _ in pairs(keep) do retained = retained + 1 end
	table.sort(entries, function(a, b) return (a.result.dps or a.result.score or 0) > (b.result.dps or b.result.score or 0) end)
	for _, entry in ipairs(entries) do
		if retained >= CACHE_MAX_ENTRIES then break end
		if not keep[entry.key] then
			keep[entry.key] = true
			retained = retained + 1
		end
	end
	retained = 0
	for key, result in pairs(cache) do
		if keep[key] then
			result._profile, result._shape = nil, nil
			retained = retained + 1
		else
			cache[key] = nil
		end
	end
	return retained
end

--time spent standing down is not time spent scanning, so neither the deadline nor the totals are charged for it
local function scanElapsed()
	if not startTime then return 0 end
	local now = GetTime()
	local pausing = breatheUntil and (math.min(now, breatheUntil) - (breatheUntil - BREATHE_FOR)) or 0
	return math.max(0, now - startTime - breathed - math.max(0, pausing))
end

local function roleWeights(scenarios)
	local weights, selected = { dps = 0, healing = 0, survival = 0, utility = 0 }, 0
	for scenario, enabled in pairs(scenarios) do
		local defaults = enabled and ROLE_WEIGHTS[scenario]
		if defaults then
			selected = selected + 1
			for key, value in pairs(defaults) do weights[key] = weights[key] + value end
		end
	end
	if selected == 0 then return nil end
	for key, value in pairs(weights) do weights[key] = math.floor(value / selected + 0.5) end
	return weights
end

local function advancedOptions()
	local saved = TT.db and TT.db.simAdvanced or {}
	local function bounded(key, default, low, high)
		return math.max(low, math.min(high, math.floor(tonumber(saved[key]) or default)))
	end
	local forms, savedSelection = {}, false
	for _, form in ipairs(FORM_ORDER) do
		if saved.forms and saved.forms[form] then
			forms[form], savedSelection = true, true
		elseif saved.forms == nil then
			forms[form] = true
		end
	end
	if saved.forms and not savedSelection then
		for _, form in ipairs(FORM_ORDER) do forms[form] = true end
	end
	if not next(forms) then for _, form in ipairs(FORM_ORDER) do forms[form] = true end end
	local weights = saved.weights or {}
	local scenarios = {
		singleTarget = saved.scenarios == nil or saved.scenarios.singleTarget ~= false,
		healing = saved.scenarios == nil or saved.scenarios.healing ~= false,
		tanking = saved.scenarios == nil or saved.scenarios.tanking ~= false,
	}
	local defaults = roleWeights(scenarios) or { dps = 30, healing = 30, survival = 30, utility = 10 }
	local selectedWeights = saved.weightsCustom and weights or defaults
	local fightMax = bounded("fightMax", DEFAULT_MAX_SIM_FIGHT, 4, MAX_SIM_FIGHT)
	if saved.fightMax == MAX_SIM_FIGHT and saved.fightMaxCustom ~= true then
		fightMax = DEFAULT_MAX_SIM_FIGHT
	end
	return {
		enabled = saved.enabled == true,
		fightMin = bounded("fightMin", 4, 4, MAX_SIM_FIGHT),
		fightMax = fightMax,
		targetMin = bounded("targetMin", 1, 1, 40),
		targetMax = bounded("targetMax", 40, 1, 40),
		forms = forms,
		scenarios = scenarios,
		weights = {
			dps = math.max(0, math.min(100, tonumber(selectedWeights.dps) or defaults.dps)),
			healing = math.max(0, math.min(100, tonumber(selectedWeights.healing) or defaults.healing)),
			survival = math.max(0, math.min(100, tonumber(selectedWeights.survival) or defaults.survival)),
			utility = math.max(0, math.min(100, tonumber(selectedWeights.utility) or defaults.utility)),
		},
	}
end

local function sequenceInScope(sequence, options, requireForm)
	if not sequence or #sequence == 0 then return not requireForm end
	for _, cast in ipairs(sequence) do
		local usedForm = cast.form or cast.shift
		if usedForm and options.forms[usedForm] ~= true then return false end
		if requireForm and not usedForm then return false end
		local forms = TT.SimulationForms and TT.SimulationForms(cast)
		if forms then
			local allowed = false
			for form in pairs(forms) do if options.forms[form] == true then allowed = true break end end
			if not allowed then return false end
		end
	end
	return true
end

resultInScope = function(result, options)
	local targets = result.config and result.config.targets or result.targets or 1
	local fight = result.config and result.config.fight or result.fight or 0
	local healing = result.healScenario or result.category == "heal_hps" or result.category == "heal_efficiency"
	local tanking = result.category == "tanking" or result.category == "cooldown_toughness"
		or result.category and result.category:match("^survival_") ~= nil
	if result.category == nil and not result.healScenario and not validAoeDuration(fight, targets) then return false end
	if result.config and not healing and not tanking and options and options.scenarios
		and not options.scenarios.singleTarget then return false end
	if healing and options and options.scenarios and not options.scenarios.healing then return false end
	if tanking and options and options.scenarios and not options.scenarios.tanking then return false end
	if not options or not options.enabled then return true end
	if (healing or tanking) and not sequenceInScope(result.sequence, options, false) then return false end
	if result.config then
		local form = result.startForm or result.config.startForm
		if fight < options.fightMin or fight > options.fightMax
			or targets ~= 1 and (targets < options.targetMin or targets > options.targetMax)
			or targets == 2 or form == nil or options.forms[form] ~= true then return false end
		return sequenceInScope(result.sequence, options, true)
	end
	if result.healScenario then
		local fight = result.fight or 0
		return fight >= options.fightMin and fight <= options.fightMax
	end
	if result.category and result.category:match("^survival_") then
		local fight, targets = result.fight or 0, result.targets or 1
		return fight >= options.fightMin and fight <= options.fightMax
			and targets >= options.targetMin and targets <= options.targetMax
	end
	return true
end

local function updateProgress()
	if not progressBar then return end
	local elapsed = scanElapsed()
	local pct = duration and duration > 0 and math.min(elapsed / duration, 1) or 0
	progressBar:SetValue(pct)
	local stats = scanStats()
	stats.seconds = scanBaseSeconds + elapsed
	statusText:SetText(string.format("%s / %s, %d new, %d cached",
		formatDuration(elapsed), formatDuration(duration), variantsChecked, cacheHits))
	if scanTotalsText then
		scanTotalsText:SetText(string.format("All scans: %d simulations, %s invested",
			stats.permutations, formatDuration(stats.seconds)))
	end
end

local function restrictionSummary(options)
	if not options or not options.enabled then return "Search limits: unrestricted" end
	local forms = {}
	for _, form in ipairs(FORM_ORDER) do if options.forms[form] then forms[#forms + 1] = form end end
	local targets = options.targetMin == options.targetMax and tostring(options.targetMin)
		or options.targetMin .. "-" .. options.targetMax
	local scenarios = {}
	for _, scenario in ipairs(SCENARIO_OPTIONS) do
		if options.scenarios[scenario.key] then scenarios[#scenarios + 1] = scenario.label end
	end
	return string.format("Limits: %ds-%ds, %s target%s | Forms: %s | Tests: %s | DPS/Heal/Survival/Utility: %d/%d/%d/%d",
		options.fightMin, options.fightMax, targets, options.targetMin == options.targetMax and "" or "s",
		table.concat(forms, ", "), table.concat(scenarios, ", "), options.weights.dps, options.weights.healing,
		options.weights.survival, options.weights.utility)
end

local function finishScan()
	if not startTime then return end
	local stats = scanStats()
	stats.seconds = scanBaseSeconds + scanElapsed()
	scanBaseSeconds = stats.seconds
	startTime = nil
	breatheAt, breatheUntil, breathed = nil, nil, 0
	if scanTotalsText then
		scanTotalsText:SetText(string.format("All scans: %d simulations, %s invested",
			stats.permutations, formatDuration(stats.seconds)))
	end
end

local function buildAdvancedFrame()
	advancedFrame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
	advancedFrame:SetSize(420, 430)
	advancedFrame:SetPoint("CENTER")
	advancedFrame:SetFrameStrata("FULLSCREEN_DIALOG")
	advancedFrame:SetToplevel(true)
	advancedFrame:SetMovable(true)
	advancedFrame:EnableMouse(true)
	advancedFrame:RegisterForDrag("LeftButton")
	advancedFrame:SetScript("OnDragStart", advancedFrame.StartMoving)
	advancedFrame:SetScript("OnDragStop", advancedFrame.StopMovingOrSizing)
	TT.SkinPanel(advancedFrame)
	local opaqueBackground = advancedFrame:CreateTexture(nil, "BACKGROUND", nil, 2)
	opaqueBackground:SetAllPoints()
	opaqueBackground:SetColorTexture(0.08, 0.06, 0.04, 1)
	advancedFrame:Hide()

	local title = advancedFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 14, -12)
	title:SetText("Advanced Simulation")
	title:SetTextColor(TT.skin.gold[1], TT.skin.gold[2], TT.skin.gold[3])

	local function addRange(key, label, y, lowDefault, highDefault)
		local text = advancedFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		text:SetPoint("TOPLEFT", 16, y)
		text:SetText(label)
		local minLabel = advancedFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		minLabel:SetPoint("TOPLEFT", 190, y)
		minLabel:SetText("Min")
		local minBox = CreateFrame("EditBox", nil, advancedFrame, "InputBoxTemplate")
		minBox:SetPoint("TOPLEFT", 214, y)
		minBox:SetSize(50, 22)
		minBox:SetNumeric(true)
		minBox:SetMaxLetters(4)
		minBox.settingKey = key .. "Min"
		local maxLabel = advancedFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		maxLabel:SetPoint("TOPLEFT", 278, y)
		maxLabel:SetText("Max")
		local maxBox = CreateFrame("EditBox", nil, advancedFrame, "InputBoxTemplate")
		maxBox:SetPoint("TOPLEFT", 302, y)
		maxBox:SetSize(50, 22)
		maxBox:SetNumeric(true)
		maxBox:SetMaxLetters(4)
		maxBox.settingKey = key .. "Max"
		advancedFields[key .. "Min"], advancedFields[key .. "Max"] = minBox, maxBox
		minBox:SetText(tostring(lowDefault))
		maxBox:SetText(tostring(highDefault))
	end

	advancedFields, advancedForms = {}, {}
	addRange("fight", "Fight duration (sec)", -48, 4, DEFAULT_MAX_SIM_FIGHT)
	addRange("target", "Enemy count", -82, 1, 40)

	local formsLabel = advancedFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	formsLabel:SetPoint("TOPLEFT", 16, -124)
	formsLabel:SetText("Allowed forms for the whole rotation")
	for index, form in ipairs(FORM_ORDER) do
		local check = CreateFrame("CheckButton", nil, advancedFrame, "UICheckButtonTemplate")
		check:SetPoint("TOPLEFT", 12 + (index - 1) * 104, -146)
		check:SetSize(24, 24)
		check:SetChecked(true)
		check.form = form
		check.label = check:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		check.label:SetPoint("LEFT", check, "RIGHT", 2, 0)
		check.label:SetText(form)
		advancedForms[form] = check
	end

	local scenariosLabel = advancedFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	scenariosLabel:SetPoint("TOPLEFT", 16, -174)
	scenariosLabel:SetText("Scenario types")
	advancedScenarios = {}
	for index, scenario in ipairs(SCENARIO_OPTIONS) do
		local check = CreateFrame("CheckButton", nil, advancedFrame, "UICheckButtonTemplate")
		check:SetPoint("TOPLEFT", 12 + (index - 1) * 132, -194)
		check:SetSize(24, 24)
		check:SetChecked(true)
		check.scenario = scenario.key
		check.label = check:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		check.label:SetPoint("LEFT", check, "RIGHT", 2, 0)
		check.label:SetText(scenario.label)
		advancedScenarios[scenario.key] = check
		check:SetScript("OnClick", function()
			local selected = {}
			for key, roleCheck in pairs(advancedScenarios) do selected[key] = roleCheck:GetChecked() == true end
			local weights = roleWeights(selected)
			if weights then
				for key, value in pairs(weights) do advancedFields[key .. "Weight"]:SetText(tostring(value)) end
				weightsCustomized = false
			end
		end)
	end

	local weightsLabel = advancedFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	weightsLabel:SetPoint("TOPLEFT", 16, -224)
	weightsLabel:SetText("Preferred outcome weights")
	for index, item in ipairs({
		{ "dps", "DPS" }, { "healing", "Healing" }, { "survival", "Survivability" }, { "utility", "Utility" },
	}) do
		local y = -250 - (index - 1) * 27
		local text = advancedFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		text:SetPoint("TOPLEFT", 18, y)
		text:SetText(item[2])
		local box = CreateFrame("EditBox", nil, advancedFrame, "InputBoxTemplate")
		box:SetPoint("TOPLEFT", 190, y)
		box:SetSize(50, 22)
		box:SetNumeric(true)
		box:SetMaxLetters(3)
		box.settingKey = item[1] .. "Weight"
		box:SetText(({ dps = 40, healing = 20, survival = 30, utility = 10 })[item[1]])
		box:SetScript("OnTextChanged", function(_, _, userInput)
			if userInput then weightsCustomized = true end
		end)
		advancedFields[item[1] .. "Weight"] = box
	end
	local note = advancedFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	note:SetPoint("BOTTOMLEFT", 16, 46)
	note:SetText("Defaults average the selected roles; manual weights remain until role selection changes.")
	note:SetTextColor(0.7, 0.7, 0.7)
	advancedMessage = advancedFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	advancedMessage:SetPoint("BOTTOMLEFT", 16, 30)
	advancedMessage:SetTextColor(1, 0.3, 0.3)

	local cancel = CreateFrame("Button", nil, advancedFrame, "UIPanelButtonTemplate")
	cancel:SetPoint("BOTTOMRIGHT", -104, 10)
	cancel:SetSize(84, 24)
	cancel:SetText("Cancel")
	cancel:SetScript("OnClick", function() advancedFrame:Hide() end)
	local defaults = CreateFrame("Button", nil, advancedFrame, "UIPanelButtonTemplate")
	defaults:SetPoint("BOTTOMLEFT", 12, 10)
	defaults:SetSize(84, 24)
	defaults:SetText("Defaults")
	defaults:SetScript("OnClick", function()
		advancedFields.fightMin:SetText("4")
		advancedFields.fightMax:SetText(tostring(DEFAULT_MAX_SIM_FIGHT))
		advancedFields.targetMin:SetText("1")
		advancedFields.targetMax:SetText("40")
		for key, check in pairs(advancedForms) do check:SetChecked(true) end
		for _, check in pairs(advancedScenarios) do check:SetChecked(true) end
		for key, value in pairs(roleWeights({ singleTarget = true, healing = true, tanking = true })) do
			advancedFields[key .. "Weight"]:SetText(tostring(value))
		end
		weightsCustomized = false
		advancedMessage:SetText("")
	end)
	local resimulate = CreateFrame("Button", nil, advancedFrame, "UIPanelButtonTemplate")
	resimulate:SetPoint("BOTTOMLEFT", 104, 10)
	resimulate:SetSize(124, 24)
	resimulate:SetText("Resim cached")
	resimulate:SetScript("OnClick", function()
		if running then
			advancedMessage:SetText("Stop the current search before resimulating.")
			return
		end
		advancedFrame:Hide()
		startBtn:SetText("Stop")
		runExplorer(true)
	end)
	local apply = CreateFrame("Button", nil, advancedFrame, "UIPanelButtonTemplate")
	apply:SetPoint("BOTTOMRIGHT", -12, 10)
	apply:SetSize(84, 24)
	apply:SetText("Apply")
	apply:SetScript("OnClick", function()
		local function readInteger(key, low, high)
			local value = tonumber(advancedFields[key]:GetText())
			if not value or value % 1 ~= 0 or value < low or value > high then return nil end
			return value
		end
		local fightMin, fightMax = readInteger("fightMin", 4, MAX_SIM_FIGHT), readInteger("fightMax", 4, MAX_SIM_FIGHT)
		local targetMin, targetMax = readInteger("targetMin", 1, 40), readInteger("targetMax", 1, 40)
		local weights, weightTotal = {}, 0
		for _, name in ipairs({ "dps", "healing", "survival", "utility" }) do
			weights[name] = tonumber(advancedFields[name .. "Weight"]:GetText())
			if not weights[name] or weights[name] < 0 or weights[name] > 100 then
				advancedMessage:SetText("Weights must be between 0 and 100.")
				return
			end
			weightTotal = weightTotal + weights[name]
		end
		local forms = {}
		for form, check in pairs(advancedForms) do if check:GetChecked() then forms[form] = true end end
		local scenarios = {}
		for scenario, check in pairs(advancedScenarios) do scenarios[scenario] = check:GetChecked() == true end
		local defaults = roleWeights(scenarios) or { dps = 30, healing = 30, survival = 30, utility = 10 }
		weightsCustomized = false
		for key, value in pairs(weights) do if value ~= defaults[key] then weightsCustomized = true break end end
		if not fightMin or not fightMax or fightMin > fightMax then
			advancedMessage:SetText("Enter a valid fight-duration range from 4 to 1200 seconds.")
			return
		elseif not targetMin or not targetMax or targetMin > targetMax or targetMin == 2 and targetMax == 2 then
			advancedMessage:SetText("Enter a valid enemy range from 1 to 40; 2-target breakpoints are skipped.")
			return
		elseif not next(forms) then
			advancedMessage:SetText("Select at least one allowed form.")
			return
		elseif weightTotal <= 0 then
			advancedMessage:SetText("At least one outcome weight must be greater than zero.")
			return
		end
		TT.db.simAdvanced = {
			enabled = true,
			fightMin = fightMin, fightMax = fightMax,
			fightMaxCustom = fightMax ~= DEFAULT_MAX_SIM_FIGHT,
			targetMin = targetMin, targetMax = targetMax,
			forms = forms, scenarios = scenarios, weights = weights, weightsCustom = weightsCustomized,
		}
		activeOptions = advancedOptions()
		displayContext = nil
		advancedMessage:SetText("")
		advancedFrame:Hide()
		populateFromCache()
		scoreImmediateAbilities()
	end)
end

local function checkResult(result, fromCache, key, choices, knownConfig)
	if not result or not resultInScope(result, activeOptions) then return end
	if TT.RotationTooLong(result) then return end
	if fromCache and choices and result.targets and result.targets > 1 and result.config and not result.targetedSequence then
		local refreshed = TT.SimulateVariantFull(result.config, choices.abilities)
		if refreshed then
			result.sequence = refreshed.sequence
			result.targetedSequence = refreshed.targetedSequence
		end
	end
	if fromCache then cacheHits = cacheHits + 1
	elseif result.config and not knownConfig then
	end
	if result.config then rememberElite(result, key) end

	for _, cat in ipairs(categoryKeys(result)) do
		local prev = bestByCategory[cat]
		local dominated = not prev or resultScore(result, cat) > resultScore(prev, cat)
		if dominated then
			bestByCategory[cat] = result
			for _, c in ipairs(CATEGORIES) do
				if c.key == cat then updateCategory(c, result) end
			end
		end
	end
	refreshAoeCategories()
	trackDiscovery(result)
	refreshLog()
	updateProgress()
end

local function gcd(a, b)
	while b ~= 0 do a, b = b, a % b end
	return a
end

local function configsFor(choices, options)
	local openers, finishers, fillers, dots, forms, conversions = { false }, { false }, {}, { false }, {}, { false }
	local targets, scenarios = {}, {}
	local function abilityAllowed(ability)
		if not options.enabled then return true end
		local abilityForms = TT.SimulationForms and TT.SimulationForms(ability)
		if not abilityForms then return true end
		for form in pairs(options.forms) do if abilityForms[form] then return true end end
		return false
	end
	if options.scenarios.singleTarget then
		if options.targetMin <= 1 and options.targetMax >= 1 then targets[#targets + 1] = 1 end
		for target = math.max(3, options.targetMin), options.targetMax do targets[#targets + 1] = target end
	end
	local function addScenario(fight, target)
		if fight >= options.fightMin and fight <= options.fightMax then
			scenarios[#scenarios + 1] = { fight = fight, targets = target }
		end
	end
	for _, target in ipairs(targets) do
		if target == 1 then
			local count = #scenarios
			for _, fight in ipairs(FIGHTS) do addScenario(fight, target) end
			if #scenarios == count then addScenario(options.fightMin, target) end
		else
			for _, secondsPerMob in ipairs(AOE_FIGHT_SECONDS_PER_MOB) do
				addScenario(target * secondsPerMob, target)
			end
		end
	end
	if #scenarios == 0 then return 0, function() return nil end, function() return nil end,
		function() return nil end, 0 end
	local seenOpeners, seenFinishers, seenFillers, seenDots, seenForms, seenConversions = {}, {}, {}, {}, {}, {}
	for _, ability in ipairs(choices.openers or {}) do
		if abilityAllowed(ability) and not seenOpeners[ability.id] then
			seenOpeners[ability.id] = true
			openers[#openers + 1] = ability.id
		end
		if abilityAllowed(ability) and not ability.openerOnly and not seenFillers[ability.id] then
			seenFillers[ability.id] = true
			fillers[#fillers + 1] = ability.id
		end
	end
	for _, ability in ipairs(choices.finishers or {}) do
		if abilityAllowed(ability) and not seenFinishers[ability.id] then
			seenFinishers[ability.id] = true
			finishers[#finishers + 1] = ability.id
		end
	end
	for _, ability in ipairs(choices.dots or {}) do
		if abilityAllowed(ability) and not seenDots[ability.id] then
			seenDots[ability.id] = true
			dots[#dots + 1] = ability.id
		end
	end
	if options.enabled then
		for _, form in ipairs(FORM_ORDER) do
			if options.forms[form] and not seenForms[form] then
				seenForms[form] = true
				forms[#forms + 1] = form
			end
		end
	elseif not choices.forms or #choices.forms == 0 then forms = { false }
	else
		for _, form in ipairs(choices.forms) do
			if not seenForms[form] then
				seenForms[form] = true
				forms[#forms + 1] = form
			end
		end
	end
	if #forms == 0 then return 0, function() return nil end, function() return nil end, function() return nil end, 0
	end
	for _, ability in ipairs(choices.conversions or {}) do
		if abilityAllowed(ability) and not seenConversions[ability.id] then
			seenConversions[ability.id] = true
			conversions[#conversions + 1] = ability.id
		end
	end
	local dimensions = { #scenarios, #BREAKPOINTS, #openers, #finishers, #fillers, #dots, #forms, #conversions }
	local total = 1
	for _, size in ipairs(dimensions) do total = total * size end
	local stride = math.floor(math.random() * total) + 1
	while gcd(stride, total) ~= 1 do stride = stride % total + 1 end
	local value = math.floor(math.random() * total) - stride
	local seeds = {}
	local function addSeed(form, filler, fight, targets, dot)
		seeds[#seeds + 1] = {
			fight = fight, targets = targets, breakpoint = 5, dot = dot or false,
			opener = false, finisher = false, filler = filler,
			startForm = form, allowedForms = options.enabled and options.forms or nil, conversion = false,
		}
	end
	local seedFights = { [4] = true, [8] = true, [30] = true, [60] = true, [120] = true }
	for _, scenario in ipairs(scenarios) do
		local isSeed = scenario.targets == 1 and seedFights[scenario.fight]
		if scenario.targets >= 3 then
			isSeed = scenario.fight == scenario.targets * 5 or scenario.fight == scenario.targets * 30
		end
		if isSeed then
		for _, form in ipairs(forms) do
			for _, filler in ipairs(fillers) do addSeed(form, filler, scenario.fight, scenario.targets) end
		end
		end
	end
	for _, fight in ipairs({ 30, 60, 120 }) do
		if fight >= options.fightMin and fight <= options.fightMax then for _, target in ipairs({ 1, 3, 5, 10, 20, 40 }) do
			if target >= options.targetMin and target <= options.targetMax and validAoeDuration(fight, target) then for _, dot in ipairs(dots) do
				for _, form in ipairs(forms) do
					for _, filler in ipairs(fillers) do addSeed(form, filler, fight, target, dot) end
				end
			end end
		end end
	end
	local function at()
		local cursor = (value + stride) % total
		value = cursor
		local conversionIndex = cursor % #conversions + 1
		cursor = math.floor(cursor / #conversions)
		local formIndex = cursor % #forms + 1
		cursor = math.floor(cursor / #forms)
		local dotIndex = cursor % #dots + 1
		cursor = math.floor(cursor / #dots)
		local fillerIndex = cursor % #fillers + 1
		cursor = math.floor(cursor / #fillers)
		local finisherIndex = cursor % #finishers + 1
		cursor = math.floor(cursor / #finishers)
		local openerIndex = cursor % #openers + 1
		cursor = math.floor(cursor / #openers)
		local breakpointIndex = cursor % #BREAKPOINTS + 1
		cursor = math.floor(cursor / #BREAKPOINTS)
		local scenarioIndex = cursor % #scenarios + 1
		local scenario = scenarios[scenarioIndex]
		return {
			fight = scenario.fight,
			targets = scenario.targets,
			breakpoint = BREAKPOINTS[breakpointIndex],
			dot = dots[dotIndex] or false,
			opener = openers[openerIndex] or nil,
			finisher = finishers[finisherIndex] or nil,
			filler = fillers[fillerIndex],
			startForm = forms[formIndex] or nil,
			allowedForms = options.enabled and options.forms or nil,
			conversion = conversions[conversionIndex] or false,
		}
	end
	local dimensions = {
		{ key = "scenario", values = scenarios },
		{ key = "breakpoint", values = BREAKPOINTS },
		{ key = "opener", values = openers },
		{ key = "finisher", values = finishers },
		{ key = "filler", values = fillers },
		{ key = "dot", values = dots },
		{ key = "startForm", values = forms },
		{ key = "conversion", values = conversions },
	}
	local function mutate(parent)
		local child = {}
		for key, value in pairs(parent) do child[key] = value end
		for _ = 1, math.random(1, 3) do
			local dimension = dimensions[math.random(#dimensions)]
			if dimension.key == "scenario" then
				local scenario = dimension.values[math.random(#dimension.values)]
				child.fight, child.targets = scenario.fight, scenario.targets
			else
				child[dimension.key] = dimension.values[math.random(#dimension.values)]
			end
		end
		child.allowedForms = options.enabled and options.forms or nil
		return child
	end
	local function seed(index) return seeds[index] end
	return total, at, mutate, seed, #seeds
end

local function choiceContext(choices)
	local ids, seenIds = {}, {}
	simulationAbilitiesById = {}
	for _, group in ipairs({ choices.abilities, choices.conversions, choices.cooldowns, choices.heals, choices.controls }) do
		for _, ability in ipairs(group or {}) do
			local id = tostring(ability.id)
			simulationAbilitiesById[id] = simulationAbilitiesById[id] or {}
			simulationAbilitiesById[id][#simulationAbilitiesById[id] + 1] = ability
			if not seenIds[id] then seenIds[id] = true ids[#ids + 1] = id end
		end
	end
	table.sort(ids)
	local rotation = TT.SimulationContext and TT.SimulationContext()
		or TT.RotationContext and TT.RotationContext() or ""
	return table.concat({ SIMULATION_VERSION, rotation, table.concat(ids, ",") }, "|")
end

local function scoreHealing(ability)
	if not ability then return nil end
	local results = {}
	if ability.healRate and ability.healRate > 0 then results[#results + 1] = {
		category = "heal_hps",
		score = ability.healRate,
		label = ability.name,
		id = ability.id,
		sequence = { { id = ability.id, name = ability.name, forms = ability.forms, power = ability.power } },
		startForm = abilityStartForm(ability),
	} end
	if ability.healPerResource and ability.healPerResource > 0 then
		results[#results + 1] = {
			category = "heal_efficiency",
			score = ability.healPerResource,
			label = ability.name,
			power = (ability.power or "resource"):lower(),
			id = ability.id,
			sequence = { { id = ability.id, name = ability.name, forms = ability.forms, power = ability.power } },
			startForm = abilityStartForm(ability),
		}
	end
	return results
end

local function advanceHealing(time, target, hots, state)
	if target <= time then return time, state.mana, state.healing end
	for id, hot in pairs(hots) do
		local seconds = math.max(0, math.min(target, hot.expires) - time)
		state.healing = state.healing + seconds * hot.rate
		if hot.expires <= target then hots[id] = nil end
	end
	local regenStart = math.max(time, state.lastCast + HEAL_MANA_REGEN_DELAY)
	if state.regen > 0 and target > regenStart then
		state.mana = math.min(state.maxMana, state.mana + (target - regenStart) * state.regen)
	end
	return target, state.mana, state.healing
end

local function healingTargets(ability, hots, targetCount, cursor)
	local isHot = (ability.healOver or 0) > 0 and (ability.healDuration or 0) > 0
	local targetLimit = ability.aoe and math.max(1, math.min(targetCount, ability.maxTargets or targetCount)) or 1
	local targets = {}
	if not ability.aoe then
		for offset = 0, targetCount - 1 do
			local target = (cursor + offset - 1) % targetCount + 1
			if not isHot or not hots[target .. ":" .. ability.id] then return { target } end
		end
		return nil
	end
	local missing = false
	for offset = 0, targetLimit - 1 do
		local target = (cursor + offset - 1) % targetCount + 1
		local hot = hots[target .. ":" .. ability.id]
		if not isHot or not hot then missing = true end
		targets[#targets + 1] = target
	end
	if isHot and not missing then return nil end
	return targets
end

local function simulateHealingSequence(sequence, horizon, manaState, targetCount)
	local state = {
		mana = manaState.current,
		maxMana = manaState.max,
		regen = manaState.perSecond or 0,
		lastCast = manaState.held and -(manaState.paused or 0) or -HEAL_MANA_REGEN_DELAY,
		healing = 0,
		spent = 0,
	}
	local hots, casts, time, pointer, targetCursor, previousTarget = {}, {}, 0, 1, 1, nil
	while time < horizon do
		local ability, selectedTargets
		for _ = 1, #sequence do
			local index = pointer
			pointer = pointer % #sequence + 1
			local candidate = sequence[index]
			local targets = healingTargets(candidate, hots, targetCount, targetCursor)
			if targets then ability, selectedTargets = candidate, targets break end
		end
		if not ability then
			local nextExpiry
			for _, hot in pairs(hots) do if not nextExpiry or hot.expires < nextExpiry then nextExpiry = hot.expires end end
			if not nextExpiry then break end
			time = advanceHealing(time, math.min(nextExpiry, horizon), hots, state)
		else
			local cost = ability.cost or 0
			if cost > state.mana then
				if state.regen <= 0 or cost > state.maxMana then break end
				local ready = math.max(time, state.lastCast + HEAL_MANA_REGEN_DELAY) + (cost - state.mana) / state.regen
				if ready >= horizon then break end
				time = advanceHealing(time, ready, hots, state)
				if state.mana < cost then break end
			end
			local start, castTime = time, math.min(ability.healCastTime or 0, ability.healCycle or 0)
			state.mana = state.mana - cost
			state.spent = state.spent + cost
			state.lastCast = start
			time = advanceHealing(time, math.min(start + castTime, horizon), hots, state)
			if time >= horizon then break end
			for _, target in ipairs(selectedTargets) do
				state.healing = state.healing + (ability.healDirect or 0)
				if (ability.healOver or 0) > 0 and (ability.healDuration or 0) > 0 then
					hots[target .. ":" .. ability.id] = {
						rate = ability.healOver / ability.healDuration,
						expires = time + ability.healDuration,
					}
				end
			end
			local target = selectedTargets[1]
			if #casts < LOG_MAX_ICONS then
				casts[#casts + 1] = {
					id = ability.id,
					name = ability.name,
					time = time,
					tab = not ability.aoe and previousTarget ~= nil and previousTarget ~= target or nil,
					target = target,
					aoe = ability.aoe,
				}
			end
			if not ability.aoe then
				targetCursor = target % targetCount + 1
				previousTarget = target
			else
				targetCursor = (targetCursor + #selectedTargets - 1) % targetCount + 1
				previousTarget = nil
			end
			time = advanceHealing(time, math.min(start + ability.healCycle, horizon), hots, state)
		end
	end
	time = advanceHealing(time, horizon, hots, state)
	return state.healing, state.spent, casts, targetCount
end

local function healingCandidates(heals)
	local rateRank, efficiencyRank, selected, seen = {}, {}, {}, {}
	for _, ability in ipairs(heals or {}) do
		if ability.healCycle and ability.healCycle > 0
			and ((type(ability.power) == "string" and ability.power:lower() == "mana") or (ability.cost or 0) == 0)
			and ((ability.healDirect or 0) > 0 or (ability.healOver or 0) > 0) then
			rateRank[#rateRank + 1] = ability
			efficiencyRank[#efficiencyRank + 1] = ability
		end
	end
	table.sort(rateRank, function(a, b)
		local left = (a.healDirect or 0) / a.healCycle + ((a.healOver or 0) / math.max(a.healDuration or 0, 1))
		local right = (b.healDirect or 0) / b.healCycle + ((b.healOver or 0) / math.max(b.healDuration or 0, 1))
		return left > right
	end)
	table.sort(efficiencyRank, function(a, b) return (a.healPerResource or 0) > (b.healPerResource or 0) end)
	local function add(ability)
		if ability and not seen[ability.id] and #selected < HEAL_CANDIDATE_LIMIT then
			seen[ability.id] = true
			selected[#selected + 1] = ability
		end
	end
	for i = 1, HEAL_RANK_LIMIT do
		add(rateRank[i])
		add(efficiencyRank[i])
	end
	return selected
end

local function scoreHealingChains(heals, horizon)
	local manaState = TT.ManaState and TT.ManaState()
	if not manaState or not manaState.current or not manaState.max then return nil end
	local candidates, best, bestChain, bestTab, bestAoe = healingCandidates(heals), nil, nil, nil, nil
	if #candidates > HEAL_CANDIDATE_LIMIT then while #candidates > HEAL_CANDIDATE_LIMIT do table.remove(candidates) end end
	local function consider(sequence)
		local healing, spent, casts = simulateHealingSequence(sequence, horizon, manaState, 1)
		if healing <= 0 or #casts == 0 then return end
		local score = healing / horizon
		local function better(previous)
			return not previous or score > previous.score
				or score == previous.score and spent > 0 and previous.spent > 0
					and healing / spent > previous.healing / previous.spent
		end
		local function result(isChain, mode, targets, totalHealing, totalSpent, totalCasts, effectiveTargets)
			local spells = {}
			for index, ability in ipairs(sequence) do spells[index] = ability end
			local shownCasts = {}
			for index, cast in ipairs(totalCasts) do shownCasts[index] = cast end
			return {
				category = nil,
				healScenario = true,
				healChain = isChain or nil,
				healMode = mode,
				score = totalHealing / horizon,
				healing = totalHealing,
				spent = totalSpent,
				id = spells[1].id,
				label = mode == "tab" and "Tabbed HoT rotation"
					or mode == "aoe" and "AoE healing rotation"
					or isChain and "Healing spell chain" or "Healing sequence",
				sequence = shownCasts,
				healSpells = spells,
				casts = shownCasts,
				fight = horizon,
				targets = targets,
				effectiveTargets = effectiveTargets,
			}
		end
		if better(best) then best = result(false, "single", 1, healing, spent, casts, 1) end
		if #sequence > 1 and better(bestChain) then bestChain = result(true, "chain", 1, healing, spent, casts, 1) end
		local hasHot, hasAoe = false, false
		for _, ability in ipairs(sequence) do
			if (ability.healOver or 0) > 0 then hasHot = true end
			if ability.aoe then hasAoe = true end
		end
		if hasHot then
			local total, totalSpent, tabCasts = simulateHealingSequence(sequence, horizon, manaState, 3)
			local hasTab = false
			for _, cast in ipairs(tabCasts) do if cast.tab then hasTab = true break end end
			if hasTab and total > 0 and (not bestTab or total / horizon > bestTab.score) then
				bestTab = result(#sequence > 1, "tab", 3, total, totalSpent, tabCasts, 3)
			end
		end
		if hasAoe then
			local total, totalSpent, aoeCasts = simulateHealingSequence(sequence, horizon, manaState, 3)
			local effectiveTargets = 0
			for _, cast in ipairs(aoeCasts) do
				if cast.aoe then
					for _, candidate in ipairs(sequence) do
						if candidate.id == cast.id then
							effectiveTargets = math.max(effectiveTargets, math.min(3, candidate.maxTargets or 3))
							break
						end
					end
				end
			end
			if total > 0 and (not bestAoe or total / horizon > bestAoe.score) then
				bestAoe = result(#sequence > 1, "aoe", 3, total, totalSpent, aoeCasts, effectiveTargets)
			end
		end
	end
	local function extend(sequence, used)
		if #sequence >= HEAL_CHAIN_DEPTH then return end
		for _, ability in ipairs(candidates) do
			if not used[ability.id] then
				sequence[#sequence + 1] = ability
				used[ability.id] = true
				consider(sequence)
				extend(sequence, used)
				used[ability.id] = nil
				sequence[#sequence] = nil
			end
		end
	end
	extend({}, {})
	return best, bestChain, bestTab, bestAoe
end

local function survivalEvents(profile, maxHealth)
	local events = {}
	local referenceHealth = profile.referenceHealth or maxHealth
	for time = profile.interval, profile.duration, profile.interval do
		local percent = profile.burstPercent and (time <= profile.burstSeconds and profile.burstPercent or profile.steadyPercent)
			or profile.hitPercent
		events[#events + 1] = { time = time, damage = referenceHealth * percent * profile.attackers }
	end
	return events
end

local function simulateSurvival(sequence, profile, manaState, formResource, formPower)
	local effectiveHealth = TT.BaseEhp and TT.BaseEhp() or 0
	if effectiveHealth <= 0 then return nil end
	local stats = TT.Stats and TT.Stats() or {}
	local maxHealth = stats.health or (stats.stam or 0) * 10
	if maxHealth <= 0 then maxHealth = effectiveHealth end
	local healScale = effectiveHealth / maxHealth
	local state = {
		health = effectiveHealth,
		maxHealth = effectiveHealth,
		mana = manaState and manaState.current or 0,
		maxMana = manaState and manaState.max or 0,
		manaRegen = manaState and manaState.perSecond or 0,
		lastCast = manaState and manaState.held and -(manaState.paused or 0) or -HEAL_MANA_REGEN_DELAY,
		energy = formPower == "energy" and formResource or 0,
		rage = formPower == "rage" and formResource or 0,
		time = 0,
		controlledUntil = 0,
		reductions = {},
		cooldowns = {},
		used = {},
		hots = {},
		casts = {},
		damage = 0,
		deadAt = nil,
	}
	local events, eventIndex = survivalEvents(profile, effectiveHealth), 1
	local swings, swingIndex = {}, 1
	if formPower == "rage" and TT.RagePerSecond then
		local _, modeledSwings = TT.RagePerSecond()
		for _, swing in ipairs(modeledSwings or {}) do
			swings[#swings + 1] = { rage = swing.rage, speed = swing.speed, at = swing.speed }
		end
	end

	local function applyHeal(amount)
		state.health = math.min(state.maxHealth, state.health + amount * healScale)
	end

	local function advanceTo(target)
		while state.time < target and state.health > 0 do
			local event = events[eventIndex]
			local swing = swings[swingIndex]
			local finish = event and event.time <= target and event.time or target
			if swing and swing.at <= finish then finish = swing.at end
			local elapsed = finish - state.time
			for id, hot in pairs(state.hots) do
				local seconds = math.max(0, math.min(finish, hot.expires) - state.time)
				applyHeal(seconds * hot.rate)
				if hot.expires <= finish then state.hots[id] = nil end
			end
			local regenStart = math.max(state.time, state.lastCast + HEAL_MANA_REGEN_DELAY)
			if state.manaRegen > 0 and finish > regenStart then
				state.mana = math.min(state.maxMana, state.mana + (finish - regenStart) * state.manaRegen)
			end
			state.energy = math.min(100, state.energy + elapsed * 10)
			state.time = finish
			if swing and swing.at == finish then
				state.rage = math.min(100, state.rage + swing.rage)
				swing.at = swing.at + swing.speed
				swingIndex = swingIndex + 1
			end
			if event and event.time == finish then
				if state.controlledUntil <= finish then
					local damage = event.damage
					local reductionPerSecond = 0
					for id, reduction in pairs(state.reductions) do
						if reduction.expires <= finish then state.reductions[id] = nil
						else reductionPerSecond = reductionPerSecond + reduction.perSecond end
					end
					if reductionPerSecond > 0 then
						local incomingPerSecond = event.damage / profile.interval
						damage = damage * math.max(0, 1 - reductionPerSecond / incomingPerSecond)
					end
					state.health = state.health - damage
					if formPower == "rage" and TT.RageFromDamage then
						state.rage = math.min(100, state.rage + TT.RageFromDamage(damage / healScale))
					end
					if state.health <= 0 then state.health, state.deadAt = 0, finish end
				end
				eventIndex = eventIndex + 1
			end
		end
	end

	local pointer, nextAction, guard = 1, 0, 0
	while state.time < profile.duration and state.health > 0 and #sequence > 0 do
		guard = guard + 1
		if guard > 1000 then break end
		if state.time < nextAction then advanceTo(math.min(nextAction, profile.duration)) end
		if state.health <= 0 or state.time >= profile.duration then break end
		local ability
		for _ = 1, #sequence do
			local candidate = sequence[pointer]
			pointer = pointer % #sequence + 1
			local cost = candidate.cost or 0
			local power = candidate.heal and "mana" or candidate.power
			local resource = power == "mana" and state.mana or power == "energy" and state.energy or power == "rage" and state.rage or math.huge
			local hot = candidate.healOver and candidate.healOver > 0 and state.hots[candidate.id]
			if not hot and (not candidate.openerOnly or not state.used[candidate.id])
				and (state.cooldowns[candidate.id] or 0) <= state.time and cost <= resource
				and (cost == 0 or power == "mana" or power == "energy" or power == "rage") then
				ability = candidate
				break
			end
		end
		if not ability then
			local wake = profile.duration
			if events[eventIndex] then wake = math.min(wake, events[eventIndex].time) end
			if swings[swingIndex] then wake = math.min(wake, swings[swingIndex].at) end
			for _, hot in pairs(state.hots) do wake = math.min(wake, hot.expires) end
			for _, ready in pairs(state.cooldowns) do if ready > state.time then wake = math.min(wake, ready) end end
			for _, candidate in ipairs(sequence) do
				local power, cost = candidate.heal and "mana" or candidate.power, candidate.cost or 0
				if power == "mana" and state.mana < cost and state.manaRegen > 0 then
					local ready = math.max(state.time, state.lastCast + HEAL_MANA_REGEN_DELAY)
						+ (cost - state.mana) / state.manaRegen
					wake = math.min(wake, ready)
				elseif power == "energy" and state.energy < cost then
					wake = math.min(wake, state.time + (cost - state.energy) / 10)
				elseif power == "rage" and state.rage < cost and not swings[swingIndex] then
					wake = math.min(wake, profile.duration)
				end
			end
			if wake <= state.time then break end
			advanceTo(wake)
		else
			local cost, power = ability.cost or 0, ability.heal and "mana" or ability.power
			if power == "mana" then state.mana = state.mana - cost
			elseif power == "energy" then state.energy = state.energy - cost
			elseif power == "rage" then state.rage = state.rage - cost end
			state.lastCast = state.time
			if ability.openerOnly then state.used[ability.id] = true end
			local castTime = ability.heal and math.min(ability.healCastTime or 0, ability.healCycle or 0) or ability.castTime or 0
			local start = state.time
			advanceTo(math.min(start + castTime, profile.duration))
			if state.health > 0 and state.time < profile.duration then
				if ability.heal then
					applyHeal(ability.healDirect or 0)
					if (ability.healOver or 0) > 0 and (ability.healDuration or 0) > 0 then
						state.hots[ability.id] = { rate = ability.healOver / ability.healDuration, expires = state.time + ability.healDuration }
					end
				else
					if ability.control then state.controlledUntil = math.max(state.controlledUntil, state.time + ability.controlDuration) end
					if ability.enemyApReduction then
						state.reductions[ability.id] = {
							expires = state.time + (ability.duration or 30),
							perSecond = TT.AttackPowerDps(ability.enemyApReduction),
						}
					end
					if (ability.instant or 0) > 0 or (ability.over or 0) > 0 then
						local remaining = math.max(0, profile.duration - state.time)
						local over = (ability.over or 0) * math.min(1, remaining / math.max(ability.duration or 0, 1))
						state.damage = state.damage + ((ability.instant or 0) + over) * (ability.scale or 1)
					end
				end
				state.casts[#state.casts + 1] = {
					id = ability.id, name = ability.name, time = start, form = abilityStartForm(ability),
				}
				local cadence = ability.heal and ability.healCycle or ability.gcd or 1.5
				local cooldown = math.max(ability.cooldown or 0, ability.controlDuration or 0, ability.duration or 0, cadence)
				state.cooldowns[ability.id] = start + cooldown
				nextAction = start + math.max(cadence, castTime)
			end
		end
	end
	if state.health > 0 then advanceTo(profile.duration) end
	return { time = state.deadAt or profile.duration, health = state.health, maxHealth = state.maxHealth,
		casts = state.casts, damage = state.damage }
end

local function survivalSequences(heals)
	local candidates, sequences = healingCandidates(heals), {}
	while #candidates > HEAL_SURVIVAL_LIMIT do table.remove(candidates) end
	local function add(sequence) sequences[#sequences + 1] = sequence end
	for i = 1, #candidates do
		add({ candidates[i] })
		for j = 1, #candidates do if i ~= j then
			add({ candidates[i], candidates[j] })
			for k = 1, #candidates do if k ~= i and k ~= j then add({ candidates[i], candidates[j], candidates[k] }) end end
		end end
	end
	return sequences
end

local function scoreSurvivalScenarios(choices)
	local manaState = TT.ManaState and TT.ManaState() or { current = 0, max = 0, perSecond = 0 }
	local formResource, formPower
	if TT.FormResource then formResource, formPower = TT.FormResource() end
	local heals = survivalSequences(choices.heals or {})
	local specials = {}
	for _, ability in ipairs(choices.controls or {}) do
		if ability.controlDuration and ability.controlDuration > 0
			and (not TT.WrongForm or not TT.WrongForm(ability.forms, ability.power))
			and (ability.power == nil or ability.power == "mana" or ability.power == formPower) then
			specials[#specials + 1] = ability
		end
	end
	for _, ability in ipairs(choices.cooldowns or {}) do
		if ability.enemyApReduction and ability.enemyApReduction > 0
			and (not TT.WrongForm or not TT.WrongForm(ability.forms, ability.power))
			and (ability.power == nil or ability.power == "mana" or ability.power == formPower) then
			specials[#specials + 1] = ability
		end
	end
	local specialCandidates = {}
	for index, ability in ipairs(specials) do
		if index > 6 then break end
		specialCandidates[#specialCandidates + 1] = ability
	end
	local results = {}
	for _, profile in ipairs(SURVIVAL_PROFILES) do
		local baseline = simulateSurvival({}, profile, manaState, formResource, formPower)
		local best
		local function consider(sequence)
			local outcome = simulateSurvival(sequence, profile, manaState, formResource, formPower)
			if not outcome or #outcome.casts == 0 then return end
			local timeGain = outcome.time - baseline.time
			local healthGain = outcome.health - baseline.health
			local score = timeGain * outcome.maxHealth + healthGain
			if score <= 0 or (best and score <= best.score) then return end
			local shown = {}
			for index = 1, math.min(#outcome.casts, LOG_MAX_ICONS) do shown[index] = outcome.casts[index] end
			best = {
				category = profile.key,
				score = score,
				display = string.format("%+.0fs, %+.0f%% hp", timeGain, healthGain / outcome.maxHealth * 100),
				label = profile.label,
				sequence = shown,
				startForm = abilityStartForm(sequence[1]),
				fight = profile.duration,
				targets = profile.attackers,
			}
		end
		for _, sequence in ipairs(heals) do
			consider(sequence)
			for _, special in ipairs(specials) do
				local withSpecial = { special }
				for _, ability in ipairs(sequence) do withSpecial[#withSpecial + 1] = ability end
				consider(withSpecial)
			end
		end
		for _, special in ipairs(specials) do consider({ special }) end
		local healingCandidatesForChains = healingCandidates(choices.heals or {})
		for i = 1, #specialCandidates do
			for j = i + 1, #specialCandidates do
				local chain = { specialCandidates[i], specialCandidates[j] }
				consider(chain)
				for _, heal in ipairs(healingCandidatesForChains) do consider({ chain[1], chain[2], heal }) end
				for k = j + 1, #specialCandidates do
					local longer = { chain[1], chain[2], specialCandidates[k] }
					consider(longer)
					for _, heal in ipairs(healingCandidatesForChains) do
						consider({ longer[1], longer[2], longer[3], heal })
					end
				end
			end
		end
		if best then results[#results + 1] = best end
	end
	return results
end

local function scoreTankingScenario(choices)
	if activeOptions and activeOptions.scenarios and not activeOptions.scenarios.tanking then return nil end
	if activeOptions and activeOptions.enabled and not activeOptions.forms.bear then return nil end
	local bearStats = TT.FormStats and TT.FormStats("bear")
	if not bearStats and TT.FormProfileKey and TT.FormProfileKey() == "bear" then
		bearStats = TT.Stats and TT.Stats()
	end
	if not bearStats or not TT.WithStats then return nil end
	local casterStats = TT.FormStats and TT.FormStats("caster")
	local referenceHealth = casterStats and (casterStats.health or (casterStats.stam or 0) * 10)
		or (bearStats.health or (bearStats.stam or 0) * 10)
	if referenceHealth <= 0 then return nil end
	local candidates = {}
	local candidateIds = {}
	local function addCandidate(ability)
		local key = ability.id or ability.name
		if not candidateIds[key] then
			candidateIds[key] = true
			candidates[#candidates + 1] = ability
		end
	end
	for _, ability in ipairs(choices.controls or {}) do
		if ability.controlDuration and ability.controlDuration > 0 and abilityAllowedInForm(ability, "bear") then
			addCandidate(ability)
		end
	end
	for _, ability in ipairs(choices.cooldowns or {}) do
		if (ability.enemyApReduction and ability.enemyApReduction > 0
			or (ability.instant or 0) > 0 or (ability.over or 0) > 0) and abilityAllowedInForm(ability, "bear") then
			addCandidate(ability)
		end
	end
	for _, ability in ipairs(choices.abilities or {}) do
		if ((ability.instant or 0) > 0 or (ability.over or 0) > 0) and abilityAllowedInForm(ability, "bear") then
			addCandidate(ability)
		end
	end
	if #candidates == 0 then return nil end
	table.sort(candidates, function(a, b)
		local aDefense, bDefense = a.enemyApReduction or a.controlDuration or 0, b.enemyApReduction or b.controlDuration or 0
		if (aDefense > 0) ~= (bDefense > 0) then return aDefense > 0 end
		if aDefense > 0 and aDefense ~= bDefense then return aDefense > bDefense end
		local aDamage = ((a.instant or 0) + (a.over or 0)) * (a.scale or 1) / math.max(a.cost or 1, 1)
		local bDamage = ((b.instant or 0) + (b.over or 0)) * (b.scale or 1) / math.max(b.cost or 1, 1)
		if aDamage ~= bDamage then return aDamage > bDamage end
		return (a.controlDuration or 0) > (b.controlDuration or 0)
	end)
	local profile = {
		key = "tanking", label = "Bear tanking",
		duration = activeOptions and activeOptions.fightMax or DEFAULT_MAX_SIM_FIGHT, interval = 5,
		hitPercent = 0.10, attackers = 1, referenceHealth = referenceHealth,
	}
	local manaState = TT.ManaState and TT.ManaState() or { current = 0, max = 0, perSecond = 0 }
	return TT.WithStats(bearStats, function()
		local best
		local function consider(sequence)
			local outcome = simulateSurvival(sequence, profile, manaState, 0, "rage")
			if not outcome or #outcome.casts == 0 then return end
			local score = outcome.time * outcome.maxHealth + outcome.health
			if best and (score < best.score or score == best.score and outcome.damage <= best.damage) then return end
			local shown = {}
			for index = 1, math.min(#outcome.casts, LOG_MAX_ICONS) do shown[index] = outcome.casts[index] end
			local alive = outcome.time >= profile.duration
			local actionNames, seenNames = {}, {}
			for _, cast in ipairs(outcome.casts) do
				if not seenNames[cast.name] then
					seenNames[cast.name] = true
					actionNames[#actionNames + 1] = cast.name
				end
			end
			best = {
				category = "tanking",
				score = score,
				damage = outcome.damage,
				display = alive and string.format("alive %.0fs, %.0f%% hp", outcome.time, outcome.health / outcome.maxHealth * 100)
					or string.format("dies at %.0fs", outcome.time),
				detail = string.format("Bear only, %s, %.1f dps over %.0fs",
					table.concat(actionNames, ", "), outcome.damage / math.max(outcome.time, 1), profile.duration),
				sequence = shown,
				startForm = "bear",
				fight = profile.duration,
				targets = profile.attackers,
			}
		end
		for i = 1, #candidates do
			consider({ candidates[i] })
			for j = i + 1, #candidates do
				consider({ candidates[i], candidates[j] })
				for k = j + 1, #candidates do consider({ candidates[i], candidates[j], candidates[k] }) end
			end
		end
		return best
	end)
end

refreshTankingScenario = function()
	if not activeOptions.scenarios.tanking then return end
	local choices = simulationChoices()
	local result = choices and scoreTankingScenario(choices)
	if result and resultInScope(result, activeOptions) then
		bestByCategory.tanking = result
		for _, category in ipairs(CATEGORIES) do
			if category.key == "tanking" then updateCategory(category, result) end
		end
		trackDiscovery(result)
	elseif not TT.FormStats or not TT.FormStats("bear") then
		categorySlots.tanking.detail:SetText("enter Bear Form once to capture tank stats")
	end
	refreshLog()
end

local function scoreUtility(ability, baseline)
	if not ability or ability.openerOnly or not ability.debuff then return nil end
	local gain = ability.debuff.gain or 0
	local baseDps = baseline and baseline.dps or 0
	if gain <= 0 or baseDps <= 0 then return nil end
	local pct = gain * 100
	return {
		dps = gain * baseDps,
		score = gain,
		display = string.format("+%.0f%% damage", pct),
		label = ability.name,
		id = ability.id,
		sequence = { { id = ability.id, name = ability.name, forms = ability.forms, power = ability.power } },
		category = "utility",
		startForm = abilityStartForm(ability),
		targets = 1,
		fight = 15,
	}
end

--an opener cannot be cast on cooldown, so pricing it by its uptime would sell one cast at the pull as a cadence
local function scoreCooldown(ability, baseline)
	if not ability or ability.openerOnly or (ability.cooldown or 0) <= 0 then return nil end
	local dmg = (ability.instant or 0) + (ability.over or 0)
	local baseDps = baseline and baseline.dps or 0
	if dmg <= 0 or baseDps <= 0 then return nil end
	local uptime = (ability.gcd or 1) / ability.cooldown
	local dps = dmg * uptime / (ability.gcd or 1)
	local pct = dps / baseDps
	if pct < 0.005 then return nil end --a cooldown that can only read as +0% is not worth a row
	return {
		dps = dps,
		score = pct,
		display = string.format("+%.0f%% damage", pct * 100),
		label = string.format("%s (%.0fs cd)", ability.name, ability.cooldown),
		id = ability.id,
		sequence = { { id = ability.id, name = ability.name, forms = ability.forms, power = ability.power } },
		startForm = abilityStartForm(ability),
		category = "cooldown_damage",
		targets = 1,
		fight = 15,
	}
end

local function scoreResourceCooldown(ability, baseline)
	if not ability or ability.openerOnly or not ability.resourceGrant or (ability.cooldown or 0) <= 0 then return nil end
	local grant = ability.resourceGrant
	local baseDps = baseline and baseline.dps or 0
	--a grant is worth what that resource buys in this rotation, so rage given to a rotation that spends energy
	--buys nothing and is not a damage cooldown at all; the old guess of a fortieth of your dps invented the rate
	local perResource = TT.ResourceValue and TT.ResourceValue(grant.kind) or nil
	if not perResource or perResource <= 0 or baseDps <= 0 then return nil end
	local resourcePerSecond = grant.amount / ability.cooldown
	local dps = resourcePerSecond * perResource
	local pct = dps / baseDps
	if pct < 0.005 then return nil end --anything that can only read as +0% is noise on the list
	return {
		dps = dps,
		score = pct,
		display = string.format("+%.0f%% damage", pct * 100),
		label = string.format("%s (+%d %s, %.0fs cd)", ability.name, grant.amount, grant.kind, ability.cooldown),
		id = ability.id,
		sequence = { { id = ability.id, name = ability.name, forms = ability.forms, power = ability.power } },
		startForm = abilityStartForm(ability),
		category = "cooldown_damage",
		targets = 1,
		fight = 15,
	}
end

local function scoreCooldownChain(cooldowns, baseline)
	local sequence, dps = {}, 0
	for _, ability in ipairs(cooldowns or {}) do
		local result = scoreCooldown(ability, baseline) or scoreResourceCooldown(ability, baseline)
		if result then
			sequence[#sequence + 1] = { id = ability.id, name = ability.name, forms = ability.forms, power = ability.power }
			dps = dps + result.dps
		end
	end
	if #sequence < 2 or dps <= 0 then return nil end
	local baseDps = baseline and baseline.dps or 0
	local score = baseDps > 0 and dps / baseDps or 0
	return {
		dps = dps,
		score = score,
		display = string.format("+%.0f%% damage", score * 100),
		label = string.format("%d cooldowns", #sequence),
		id = sequence[1].id,
		sequence = sequence,
		startForm = abilityStartForm(cooldowns[1]),
		category = "cooldown_damage",
		targets = 1,
		fight = 15,
	}
end

local TOUGHNESS_MOB_DPS = 20

--the debuff lands on everything it hits, so what it is worth is what one mob stops doing to you, said per mob
--rather than as four near-identical rows that differ only in how many you imagined standing there
local function scoreToughnessCooldown(ability)
	if not ability or not ability.enemyApReduction or ability.enemyApReduction <= 0 then return nil end
	local apReduction = ability.enemyApReduction
	local damageReduction = apReduction / 14
	local uptime = (ability.duration or 30) / math.max(ability.cooldown or 0, ability.duration or 30)
	local effectiveMitigation = damageReduction * uptime

	local baseEhp = TT.BaseEhp and TT.BaseEhp() or 1000
	if baseEhp <= 0 then return nil end
	local ehpGain = baseEhp * effectiveMitigation / math.max(TOUGHNESS_MOB_DPS - effectiveMitigation, 1)
	return {
		score = ehpGain,
		display = string.format("+%.0f%% toughness per mob", ehpGain / baseEhp * 100),
		label = string.format("%s (-%d AP, %ds)", ability.name, apReduction, ability.duration or 30),
		id = ability.id,
		sequence = { { id = ability.id, name = ability.name, forms = ability.forms, power = ability.power } },
		startForm = abilityStartForm(ability),
		category = "cooldown_toughness",
		targets = 1,
		fight = 15,
	}
end

runExplorer = function(resimulateCache)
	local choices = simulationChoices()
	if not choices or (not choices.filler and #(choices.heals or {}) == 0
		and #(choices.conversions or {}) == 0 and #(choices.cooldowns or {}) == 0
		and #(choices.controls or {}) == 0 and not choices.utility) then
		if logContent then logContent:SetText("|cffff4040no abilities to simulate|r") end
		if startBtn then startBtn:SetText("Start") end
		return
	end
	activeOptions = advancedOptions()
	if searchingText then searchingText:SetText(restrictionSummary(activeOptions)) end
	local context = choiceContext(choices)
	if displayContext ~= context then
		bestByCategory, discoveryResults, discoveryPools = {}, {}, {}
		displayContext = context
		for _, cat in ipairs(CATEGORIES) do
			local slot = categorySlots[cat.key]
			if slot then
				slot.dps:SetText("—")
				slot.detail:SetText("")
				for _, icon in ipairs(slot.icons) do icon:Hide() end
			end
		end
		refreshAoeCategories()
		refreshLog()
	end

	duration = tonumber(durationBox:GetText()) or DEFAULT_DURATION
	if duration < 1 then duration = 1 end
	variantsChecked, cacheHits = 0, 0
	progressBar:SetValue(0)
	if checkingText then checkingText:SetText("Preparing rotation search") end
	startTime = GetTime()
	breatheAt, breatheUntil, breathed = startTime + BREATHE_EVERY, nil, 0
	scanBaseSeconds = scanStats().seconds or 0
	elitePool, eliteKeys = {}, {}
	local configCount, configAt, mutate, seedAt, seedCount = 0, nil, nil, nil, 0
	local searchOptions = activeOptions
	if not searchOptions.enabled then
		searchOptions = {
			fightMin = 4, fightMax = MAX_SIM_FIGHT, targetMin = 1, targetMax = 40,
			forms = {}, scenarios = activeOptions.scenarios,
		}
		local forms = choices.forms
		if not forms or #forms == 0 then forms = FORM_ORDER end
		for _, form in ipairs(forms) do searchOptions.forms[form] = true end
	end
	if searchOptions.scenarios.singleTarget and choices.filler then
		configCount, configAt, mutate, seedAt, seedCount = configsFor(choices, searchOptions)
	end
	local tried = {}
	local function nextConfig(seedIndex)
		if seedIndex <= seedCount then return seedAt(seedIndex) end
		local config
		if #elitePool > 0 and math.random() < 0.8 then
			local parent = elitePool[math.random(math.min(#elitePool, 8))].result.config
			config = mutate(parent)
		else
			config = configAt()
		end
		return config
	end
	if categorySlots.heal_hps and #(choices.heals or {}) == 0 then
		categorySlots.heal_hps.detail:SetText("no healing spells found")
		categorySlots.heal_efficiency.detail:SetText("no healing spells found")
	end

	co = coroutine.create(function()
		--score non-rotation abilities before the configuration sweep
		local baseline = TT.PhysicalBaseline and TT.PhysicalBaseline() or { dps = 50 }
		if activeOptions.scenarios.healing then
			for _, heal in ipairs(choices.heals or {}) do
				for _, r in ipairs(scoreHealing(heal) or {}) do checkResult(r, false) end
				coroutine.yield()
			end
			for _, horizon in ipairs(HEAL_HORIZONS) do
				local result, chain, tab, aoe = scoreHealingChains(choices.heals, horizon)
				if result then checkResult(result, false) end
				if chain then checkResult(chain, false) end
				if tab then checkResult(tab, false) end
				if aoe then checkResult(aoe, false) end
				coroutine.yield()
			end
		end
		if activeOptions.scenarios.singleTarget and choices.utility then
			local r = scoreUtility(choices.utility, baseline)
			if r then checkResult(r, false) end
		end
		for _, cd in ipairs(choices.cooldowns or {}) do
			if activeOptions.scenarios.singleTarget then
				local r = scoreCooldown(cd, baseline) or scoreResourceCooldown(cd, baseline)
				if r then checkResult(r, false) end
			end
			if activeOptions.scenarios.tanking then
				local t = scoreToughnessCooldown(cd)
				if t and abilityAllowedInForm(cd, "bear") then checkResult(t, false) end
			end
		end
		if activeOptions.scenarios.tanking then
			local tanking = scoreTankingScenario(choices)
			if tanking then checkResult(tanking, false) end
		end
		if activeOptions.scenarios.singleTarget then
			local cooldownChain = scoreCooldownChain(choices.cooldowns, baseline)
			if cooldownChain then checkResult(cooldownChain, false) end
		end
		coroutine.yield()

		local simCache = getCache()
		migrateCacheContext(simCache, context)
		local cacheSize = pruneCache(simCache)
		local nextPrune = CACHE_MAX_ENTRIES + 64
		local visited, seedIndex, duplicateProbes = 0, 1, 0
		for key, result in pairs(simCache) do
			if result.context == context and result.config and resultInScope(result, activeOptions) then
				rememberElite(result, key)
			end
		end
		if resimulateCache then
			local keys = {}
			for key, result in pairs(simCache) do
				if result.context == context and result.config and resultInScope(result, activeOptions) then
					keys[#keys + 1] = key
				end
			end
			table.sort(keys)
			if #keys == 0 and checkingText then checkingText:SetText("No cached rotations match these limits") end
			for index, key in ipairs(keys) do
				if scanElapsed() >= duration then break end
				local cached = simCache[key]
				local config = cached.config
				if checkingText then
					checkingText:SetText(string.format("Resimulating %d/%d: %ds, %d target%s, %s start",
						index, #keys, config.fight or 0, config.targets or 1,
						config.targets == 1 and "" or "s", config.startForm or "any form"))
				end
				variantsChecked = variantsChecked + 1
				scanStats().permutations = scanStats().permutations + 1
				local result = TT.SimulateVariantFull(config, choices.abilities)
				if result then
					result.context = context
					result.statBasis = currentStatBasis()
					result._baseDps = result.dps
					simCache[key] = result
					checkResult(result, false, key, nil, true)
				end
				updateProgress()
				coroutine.yield()
			end
		else
			while visited < configCount do
				if scanElapsed() >= duration then break end
				local config = nextConfig(seedIndex)
				seedIndex = seedIndex + 1
				if not config then break end
				if checkingText then
					checkingText:SetText(string.format("Checking: %ds, %d target%s, %s start",
						config.fight, config.targets, config.targets == 1 and "" or "s",
						config.startForm and (config.startForm .. " form") or "any form"))
				end
				local key = simulationKey(config, context)
				if tried[key] then
					duplicateProbes = duplicateProbes + 1
					if duplicateProbes >= 500 then break end
				else
					duplicateProbes = 0
					tried[key] = true
					visited = visited + 1
					local cached = simCache[key]
					if cached then
						cacheHits = cacheHits + 1
					else
						variantsChecked = variantsChecked + 1
						local stats = scanStats()
						stats.permutations = stats.permutations + 1
						local resultStatBasis = currentStatBasis()
						local result = TT.SimulateVariantFull(config, choices.abilities)
						if result then
							result.context = context
							result.statBasis = resultStatBasis
							result._baseDps = result.dps
							simCache[key] = result
							cacheSize = cacheSize + 1
							checkResult(result, false, key)
							if cacheSize >= nextPrune then
								cacheSize = pruneCache(simCache)
								nextPrune = cacheSize + 64
							end
						end
					end
					updateProgress()
					coroutine.yield()
				end
			end
		end
		pruneCache(simCache)
		saveCache()
		updateProgress()
		if checkingText then
			local tankStatsMissing = activeOptions.scenarios.tanking and TT.FormStats and not TT.FormStats("bear")
			checkingText:SetText(configCount == 0 and tankStatsMissing
				and "No damage tests selected; enter Bear Form once to capture tank stats"
				or "Search complete")
		end
		finishScan()
		running = false
	end)
	running = true
end

local function tick()
	if not running or not co then return end
	local started = debugprofilestop and debugprofilestop()
	repeat
		local ok, err = coroutine.resume(co)
		if not ok then
			if statusText then statusText:SetText("|cffff4040error:|r " .. tostring(err)) end
			finishScan()
			saveCache()
			running = false
			break
		end
		if coroutine.status(co) == "dead" then running = false end
		if not running or not started or not debugprofilestop
			or debugprofilestop() - started >= WORK_BUDGET_MS then break end
	until false
	if not running and startBtn then startBtn:SetText("Start") end
end

local function buildProgressDisplay(panel)
	progressBar = CreateFrame("StatusBar", nil, panel)
	progressBar:SetSize(panelContentWidth, PROGRESS_HEIGHT)
	progressBar:SetPoint("BOTTOM", panel, "BOTTOM", 0, 58)
	progressBar:SetMinMaxValues(0, 1)
	progressBar:SetValue(0)
	progressBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
	progressBar:SetStatusBarColor(TT.skin.gold[1], TT.skin.gold[2], TT.skin.gold[3])
	local bg = progressBar:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0.1, 0.1, 0.1, 0.8)

	statusText = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	statusText:SetPoint("BOTTOM", progressBar, "TOP", 0, 2)
	statusText:SetText("")
	scaleFont(statusText, panelFontScale)

	scanTotalsText = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	scanTotalsText:SetPoint("BOTTOM", statusText, "TOP", 0, 1)
	scanTotalsText:SetTextColor(TT.skin.metal[1], TT.skin.metal[2], TT.skin.metal[3])
	scaleFont(scanTotalsText, panelFontScale)

	searchingText = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	searchingText:SetPoint("BOTTOM", scanTotalsText, "TOP", 0, 1)
	searchingText:SetTextColor(0.6, 0.8, 1.0)
	scaleFont(searchingText, panelFontScale)
end

local function buildDiscoveryRows()
	for i = 1, LOG_MAX_ROWS do
		local row = CreateFrame("Frame", nil, logChild)
		row:SetPoint("TOPLEFT", 0, -(i - 1) * logRowHeight)
		row:SetPoint("RIGHT")
		row:SetHeight(logRowHeight)

		local rank = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		rank:SetPoint("LEFT", 0, LOG_CONTENT_LIFT * panelFontScale)
		rank:SetWidth(28 * panelFontScale)
		scaleFont(rank, panelFontScale)

		local dps = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		dps:SetPoint("LEFT", 34 * panelFontScale, LOG_CONTENT_LIFT * panelFontScale)
		dps:SetWidth(LOG_METRIC_WIDTH * panelFontScale)
		dps:SetJustifyH("CENTER")
		dps:SetWordWrap(false)
		dps:SetTextColor(TT.skin.text[1], TT.skin.text[2], TT.skin.text[3])
		scaleFont(dps, panelFontScale)

		--two strips: what you only get to press once, and what you press for the rest of the fight
		local function strip(lift)
			local container = CreateFrame("Frame", nil, row)
			container:SetPoint("LEFT", LOG_SEQUENCE_LEFT * panelFontScale, lift * panelFontScale)
			container:SetSize(logContainerWidth, LOG_ICON_SIZE)

			local ellipsis = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
			ellipsis:SetPoint("LEFT", container, "RIGHT", 2, 0)
			ellipsis:SetTextColor(0.5, 0.5, 0.5)
			scaleFont(ellipsis, panelFontScale)

			local caption = row:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
			caption:SetPoint("RIGHT", container, "LEFT", -4, 0)
			caption:SetJustifyH("RIGHT")
			scaleFont(caption, panelFontScale)

			return { container = container, ellipsis = ellipsis, caption = caption, icons = {}, arrows = {} }
		end
		local openerStrip = strip(LOG_CONTENT_LIFT + LOG_STRIP_LIFT)
		local loopStrip = strip(LOG_CONTENT_LIFT)

		local startForm = createFormIcon(row, 22 * panelFontScale)
		startForm:SetPoint("LEFT", row, "LEFT", (LOG_SEQUENCE_LEFT - 64) * panelFontScale,
			LOG_CONTENT_LIFT * panelFontScale)
		TT.SkinInset(row)

		logRows[i] = { frame = row, rank = rank, dps = dps, startForm = startForm,
			opener = openerStrip, loop = loopStrip, categoryIcons = {} }
		row:Hide()
	end
end

--which preset the saved scope matches, so the button shows where you are rather than where it last left off
local function currentRole()
	local options = advancedOptions()
	if not options.enabled then return nil end
	for _, preset in ipairs(ROLE_PRESETS) do
		local same = true
		for _, form in ipairs(FORM_ORDER) do
			if (options.forms[form] == true) ~= (preset.forms[form] == true) then same = false break end
		end
		for key, wanted in pairs(preset.scenarios) do
			if (options.scenarios[key] == true) ~= wanted then same = false end
		end
		if same then return preset end
	end
	return nil
end

local function applyRole(preset)
	local options = advancedOptions()
	local forms, scenarios = {}, {}
	for _, form in ipairs(FORM_ORDER) do if preset.forms[form] then forms[form] = true end end
	for key, wanted in pairs(preset.scenarios) do scenarios[key] = wanted end
	TT.db.simAdvanced = {
		enabled = true,
		fightMin = options.fightMin, fightMax = options.fightMax,
		fightMaxCustom = options.fightMax ~= DEFAULT_MAX_SIM_FIGHT,
		targetMin = options.targetMin, targetMax = options.targetMax,
		--the weights are left to follow the scenarios, so picking tank weights survival without being told to
		forms = forms, scenarios = scenarios, weightsCustom = false,
	}
	activeOptions = advancedOptions()
	displayContext = nil
end

local function roleCaption()
	local preset = currentRole()
	return preset and preset.label or "Every form"
end

local function buildScanControls(panel)
	startBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	startBtn:SetPoint("BOTTOMLEFT", panelContentLeft + 12, 8)
	startBtn:SetSize(80 * panelFontScale, 22 * panelFontScale)
	startBtn:SetText("Start")
	startBtn:SetScript("OnClick", function()
		if running then
			running = false
			finishScan()
			saveCache()
			startBtn:SetText("Start")
			if statusText then statusText:SetText("|cffffff00stopped|r") end
		else
			startBtn:SetText("Stop")
			runExplorer()
		end
	end)

	local durLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	durLabel:SetPoint("LEFT", startBtn, "RIGHT", 12, 0)
	durLabel:SetText("Search:")
	durLabel:SetTextColor(TT.skin.metal[1], TT.skin.metal[2], TT.skin.metal[3])
	scaleFont(durLabel, panelFontScale)

	durationBox = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
	durationBox:SetPoint("LEFT", durLabel, "RIGHT", 6, 0)
	durationBox:SetSize(40 * panelFontScale, 20 * panelFontScale)
	durationBox.settingKey = "searchDuration"
	durationBox:SetAutoFocus(false)
	durationBox:SetNumeric(true)
	durationBox:SetMaxLetters(4)
	durationBox:SetText(tostring(DEFAULT_DURATION))
	scaleFont(durationBox, panelFontScale)
	durationBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	durationBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

	local secLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	secLabel:SetPoint("LEFT", durationBox, "RIGHT", 4, 0)
	secLabel:SetText("sec")
	secLabel:SetTextColor(TT.skin.metal[1], TT.skin.metal[2], TT.skin.metal[3])
	scaleFont(secLabel, panelFontScale)

	advancedButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	advancedButton:SetPoint("LEFT", secLabel, "RIGHT", 8, 0)
	advancedButton:SetSize(76 * panelFontScale, 22 * panelFontScale)
	advancedButton:SetText("Advanced")
	if advancedButton.GetFontString then scaleFont(advancedButton:GetFontString(), panelFontScale) end
	buildAdvancedFrame()
	roleButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	roleButton:SetPoint("TOPRIGHT", -30, -8)
	roleButton:SetSize(96 * panelFontScale, 22 * panelFontScale)
	roleButton:SetText(roleCaption())
	if roleButton.GetFontString then scaleFont(roleButton:GetFontString(), panelFontScale) end
	roleButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	--stepping on from whatever is set, the way the panel's pack button steps through sizes
	roleButton:SetScript("OnClick", function(self, button)
		local current = currentRole()
		local index = 0
		for slot, preset in ipairs(ROLE_PRESETS) do if current and preset.key == current.key then index = slot end end
		if button == "RightButton" then index = index - 2 end
		applyRole(ROLE_PRESETS[index % #ROLE_PRESETS + 1])
		self:SetText(roleCaption())
		populateFromCache()
		scoreImmediateAbilities()
	end)
	roleButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
		GameTooltip:AddLine("What the scan is looking for")
		GameTooltip:AddLine("click to step through caster, melee, tank, healer and every form", 0.7, 0.7, 0.7)
		GameTooltip:AddLine("the scan is otherwise locked to the form you happen to be standing in", 0.7, 0.7, 0.7)
		GameTooltip:Show()
	end)
	roleButton:SetScript("OnLeave", function(self)
		if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
	end)

	advancedButton:SetScript("OnClick", function()
		local options = advancedOptions()
		advancedFields.fightMin:SetText(tostring(options.fightMin))
		advancedFields.fightMax:SetText(tostring(options.fightMax))
		advancedFields.targetMin:SetText(tostring(options.targetMin))
		advancedFields.targetMax:SetText(tostring(options.targetMax))
		for key, check in pairs(advancedForms) do check:SetChecked(options.forms[key] == true) end
		for key, check in pairs(advancedScenarios) do check:SetChecked(options.scenarios[key] == true) end
		for key, value in pairs(options.weights) do advancedFields[key .. "Weight"]:SetText(tostring(value)) end
		weightsCustomized = TT.db and TT.db.simAdvanced and TT.db.simAdvanced.weightsCustom == true or false
		advancedMessage:SetText("")
		advancedFrame:Show()
	end)
end

local function buildWipeButton(panel)
	local clearBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	clearBtn:SetPoint("BOTTOMRIGHT", -(panelContentLeft + 12), 8)
	clearBtn:SetSize(80 * panelFontScale, 22 * panelFontScale)
	clearBtn:SetText("Wipe Data")
	if clearBtn.GetFontString then scaleFont(clearBtn:GetFontString(), panelFontScale) end
	clearBtn:SetScript("OnClick", function()
		local stats = scanStats()
		local held = 0
		for _ in pairs(getCache()) do held = held + 1 end
		TT.Confirm("Wipe simulation data?", string.format(
			"This permanently deletes every saved rotation and discovery result for this character: %d kept, from %d simulations "
			.. "over %s of scanning.\n\nThe explorer and its running totals will be reset.",
			held, stats.permutations, formatDuration(stats.seconds)),
			"Wipe it anyway", function()
				if running then
					running = false
					finishScan()
				end
				co = nil
				if TT.db then TT.db.simCache = {} end
				bestByCategory, discoveryResults, discoveryPools, elitePool, eliteKeys = {}, {}, {}, {}, {}
				displayContext = nil
				resetScanStats()
				if startBtn then startBtn:SetText("Start") end
				if progressBar then progressBar:SetValue(0) end
				if statusText then statusText:SetText("") end
				populateFromCache()
			end)
	end)
end

local function installFrameHandlers(panel)
	panel:SetScript("OnUpdate", function()
		if not running then return end
		local now = GetTime()
		if breatheUntil then
			if now < breatheUntil then return end
			breathed = breathed + BREATHE_FOR
			breatheUntil, breatheAt = nil, now + BREATHE_EVERY
		elseif breatheAt and now >= breatheAt then
			breatheUntil = now + BREATHE_FOR
			if statusText then statusText:SetText("|cffb0a894standing down a moment for other addons|r") end
			return
		end
		tick()
	end)
	if TT.Listen then
		for _, event in ipairs({
			"PLAYER_EQUIPMENT_CHANGED", "PLAYER_LEVEL_UP", "UNIT_STATS", "UNIT_DAMAGE",
			"UNIT_ATTACK_POWER", "UNIT_ATTACK_SPEED", "UNIT_AURA", "UPDATE_SHAPESHIFT_FORM",
			"UPDATE_SHAPESHIFT_FORMS", "ACTIONBAR_SLOT_CHANGED", "ACTIONBAR_PAGE_CHANGED",
			"UPDATE_BONUS_ACTIONBAR", "PLAYER_TALENT_UPDATE", "SPELLS_CHANGED",
		}) do TT.Listen(panel, event) end
	end
	panel:SetScript("OnEvent", function(_, event, unit)
		if event:find("^UNIT_") and unit and unit ~= "player" then return end
		choicesCache, choicesCachedAt = nil, nil
		if not running and frame:IsShown() then
			eventRefreshId = eventRefreshId + 1
			local refreshId = eventRefreshId
			C_Timer.After(0.25, function()
				if refreshId ~= eventRefreshId or running or not frame:IsShown() then return end
				populateFromCache()
				refreshTankingScenario()
			end)
		end
	end)
end

local function buildFrame()
	local screenWidth = UIParent.GetWidth and UIParent:GetWidth()
	local screenHeight = UIParent.GetHeight and UIParent:GetHeight()
	local frameWidth = (screenWidth and screenWidth > 0 and screenWidth or 1200) * 0.76
	panelMaxHeight = (screenHeight and screenHeight > 0 and screenHeight or 900) * 0.82
	panelHeight = panelMaxHeight
	panelContentWidth = frameWidth * 0.90
	panelContentLeft = (frameWidth - panelContentWidth) / 2
	panelFontScale = math.max(1.2, math.min(1.7, frameWidth / 1100))
	logRowHeight = LOG_ROW_HEIGHT
	logContainerWidth = math.max(120, panelContentWidth - LOG_SEQUENCE_LEFT * panelFontScale)
	frame = CreateFrame("Frame", "AgamonSimulateFrame", UIParent, "BackdropTemplate")
	frame:SetSize(frameWidth, panelHeight)
	frame:SetPoint("CENTER")
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:SetFrameStrata("DIALOG")
	TT.SkinPanel(frame)

	local title = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOP", frame, "TOP", 0, -10)
	title:SetText("Simulation Explorer")
	title:SetTextColor(TT.skin.gold[1], TT.skin.gold[2], TT.skin.gold[3])
	title:SetJustifyH("CENTER")
	scaleFont(title, panelFontScale)

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -2, -2)
	close:SetScript("OnClick", function() frame:Hide() end)

	local y = -36
	categorySlots = {}
	for _, cat in ipairs(CATEGORIES) do
		local row = CreateFrame("Frame", nil, frame)
		row:SetSize(panelContentWidth, CATEGORY_HEIGHT)
		row:SetPoint("TOP", frame, "TOP", 0, y)

		local label = row:CreateFontString(nil, "ARTWORK", "GameFontNormal")
		label:SetPoint("LEFT")
		label:SetWidth(panelContentWidth * 0.20)
		label:SetWordWrap(false)
		label:SetText(cat.label)
		label:SetTextColor(TT.skin.metal[1], TT.skin.metal[2], TT.skin.metal[3])
		label:SetJustifyH("RIGHT")
		scaleFont(label, panelFontScale)

		local dps = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		dps:SetPoint("LEFT", panelContentWidth * 0.22, 0)
		dps:SetWidth(panelContentWidth * 0.14)
		dps:SetWordWrap(false)
		dps:SetText("—")
		dps:SetTextColor(TT.skin.text[1], TT.skin.text[2], TT.skin.text[3])
		dps:SetJustifyH("CENTER")
		scaleFont(dps, panelFontScale)

		local detail = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		detail:SetPoint("LEFT", panelContentWidth * 0.58, 0)
		detail:SetWidth(panelContentWidth * 0.40)
		detail:SetJustifyH("CENTER")
		detail:SetWordWrap(false)
		detail:SetTextColor(0.7, 0.7, 0.7)
		scaleFont(detail, panelFontScale)

		local formMarker = createFormIcon(row, CATEGORY_ICON_SIZE)
		local iconStartX = panelContentWidth * 0.39
		formMarker:SetPoint("LEFT", iconStartX, 0)
		categorySlots[cat.key] = {
			row = row, dps = dps, detail = detail, formMarker = formMarker,
			iconStartX = iconStartX, icons = {},
		}
		y = y - CATEGORY_HEIGHT
	end

	y = y - 8
	discoveryLabel = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	discoveryLabel:SetPoint("TOP", frame, "TOP", 0, y)
	discoveryLabel:SetText("Discovery Log")
	discoveryLabel:SetTextColor(TT.skin.gold[1], TT.skin.gold[2], TT.skin.gold[3])
	discoveryLabel:SetJustifyH("CENTER")
	scaleFont(discoveryLabel, panelFontScale)
	y = y - 18

	checkingText = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	checkingText:SetPoint("TOP", frame, "TOP", 0, y)
	checkingText:SetTextColor(0.7, 0.8, 0.9)
	checkingText:SetText("Ready to search")
	checkingText:SetJustifyH("CENTER")
	scaleFont(checkingText, panelFontScale)
	y = y - 14

	logScroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
	logScroll:SetPoint("TOP", frame, "TOP", 0, y)
	logScroll:SetSize(panelContentWidth, math.max(logRowHeight, panelHeight + y - 92))

	logChild = CreateFrame("Frame", nil, logScroll)
	logChild:SetSize(panelContentWidth, logRowHeight)
	logScroll:SetScrollChild(logChild)
	buildDiscoveryRows()
	buildProgressDisplay(frame)
	buildScanControls(frame)
	buildWipeButton(frame)
	installFrameHandlers(frame)

	frame:Hide()
end

populateFromCache = function()
	local simCache = getCache()
	local choices = simulationChoices()
	local context = choices and choiceContext(choices)
	if context then migrateCacheContext(simCache, context) end
	local stats = scanStats()
	if scanTotalsText then
		scanTotalsText:SetText(string.format("All scans: %d simulations, %s invested",
			stats.permutations, formatDuration(stats.seconds)))
	end
	activeOptions = advancedOptions()
	if searchingText then searchingText:SetText(restrictionSummary(activeOptions)) end
	if displayContext ~= context then
		bestByCategory, discoveryResults, discoveryPools = {}, {}, {}
		displayContext = context
	end
	for _, result in pairs(simCache) do
		if context and result.context == context and resultInScope(result, activeOptions) and not TT.RotationTooLong(result) then
			for _, cat in ipairs(categoryKeys(result)) do
				local prev = bestByCategory[cat]
				if not prev or resultScore(result, cat) > resultScore(prev, cat) then bestByCategory[cat] = result end
			end
			trackDiscovery(result)
		end
	end
	for _, result in pairs(discoveryResults) do
		if result.targets and result.targets > 1 and result.config and not result.targetedSequence then
			local refreshed = TT.SimulateVariantFull(result.config, choices.abilities)
			if refreshed then
				result.sequence = refreshed.sequence
				result.targetedSequence = refreshed.targetedSequence
			end
		end
	end
	pruneCache(simCache)
	for _, cat in ipairs(CATEGORIES) do
		local slot = categorySlots[cat.key]
		if slot then
			local best = bestByCategory[cat.key]
			if best then
				updateCategory(cat, best)
			else
				slot.dps:SetText("—")
				slot.detail:SetText("")
				for _, icon in ipairs(slot.icons) do icon:Hide() end
			end
		end
	end
	refreshAoeCategories()
	refreshLog()
	local count = 0
	for _, result in pairs(simCache) do if context and result.context == context then count = count + 1 end end
	if statusText then statusText:SetText(count > 0 and string.format("%d cached", count) or "") end
end

scoreImmediateAbilities = function()
	local choices = simulationChoices()
	if not choices then return end
	local baseline = TT.PhysicalBaseline and TT.PhysicalBaseline() or { dps = 50 }
	if activeOptions.scenarios.healing then
		for _, heal in ipairs(choices.heals or {}) do
			for _, r in ipairs(scoreHealing(heal) or {}) do
				if resultInScope(r, activeOptions) then
					for _, cat in ipairs(categoryKeys(r)) do
						local prev = bestByCategory[cat]
						if not prev or resultScore(r, cat) > resultScore(prev, cat) then
							bestByCategory[cat] = r
							for _, c in ipairs(CATEGORIES) do if c.key == cat then updateCategory(c, r) end end
						end
					end
					trackDiscovery(r)
				end
			end
		end
		for _, horizon in ipairs(HEAL_HORIZONS) do
			local r, chain, tab, aoe = scoreHealingChains(choices.heals, horizon)
			if r and resultInScope(r, activeOptions) then trackDiscovery(r) end
			if chain and resultInScope(chain, activeOptions) then trackDiscovery(chain) end
			if tab and resultInScope(tab, activeOptions) then trackDiscovery(tab) end
			if aoe and resultInScope(aoe, activeOptions) then trackDiscovery(aoe) end
		end
	end
	if activeOptions.scenarios.singleTarget or activeOptions.scenarios.healing then
		for _, r in ipairs(scoreSurvivalScenarios(choices)) do
			if resultInScope(r, activeOptions) then
				for _, key in ipairs(categoryKeys(r)) do
					local previous = bestByCategory[key]
					if not previous or resultScore(r, key) > resultScore(previous, key) then
						bestByCategory[key] = r
						for _, category in ipairs(CATEGORIES) do
							if category.key == key then updateCategory(category, r) end
						end
					end
				end
				trackDiscovery(r)
			end
		end
	end
	local tanking = activeOptions.scenarios.tanking and scoreTankingScenario(choices)
	if tanking and resultInScope(tanking, activeOptions) then
		bestByCategory.tanking = tanking
		for _, category in ipairs(CATEGORIES) do
			if category.key == "tanking" then updateCategory(category, tanking) end
		end
		trackDiscovery(tanking)
	elseif activeOptions.scenarios.tanking and (not activeOptions.enabled or activeOptions.forms.bear)
		and TT.FormStats and not TT.FormStats("bear") and categorySlots.tanking then
		categorySlots.tanking.detail:SetText("enter Bear Form once to capture tank stats")
	end
	if activeOptions.scenarios.singleTarget and choices.utility then
		local r = scoreUtility(choices.utility, baseline)
		if r and resultInScope(r, activeOptions) then
			local prev = bestByCategory["utility"]
			if not prev or resultScore(r, "utility") > resultScore(prev, "utility") then
				bestByCategory["utility"] = r
				for _, c in ipairs(CATEGORIES) do if c.key == "utility" then updateCategory(c, r) end end
			end
			trackDiscovery(r)
		end
	end
	for _, cd in ipairs(choices.cooldowns or {}) do
		if activeOptions.scenarios.singleTarget then
			local r = scoreCooldown(cd, baseline) or scoreResourceCooldown(cd, baseline)
			if r and resultInScope(r, activeOptions) then
				local prev = bestByCategory["cooldown_damage"]
				if not prev or resultScore(r, "cooldown_damage") > resultScore(prev, "cooldown_damage") then
					bestByCategory["cooldown_damage"] = r
					for _, c in ipairs(CATEGORIES) do if c.key == "cooldown_damage" then updateCategory(c, r) end end
				end
				trackDiscovery(r)
			end
		end
		if activeOptions.scenarios.tanking then
			local t = scoreToughnessCooldown(cd)
			if t and abilityAllowedInForm(cd, "bear") and resultInScope(t, activeOptions) then
				local prev = bestByCategory["cooldown_toughness"]
				if not prev or resultScore(t, "cooldown_toughness") > resultScore(prev, "cooldown_toughness") then
					bestByCategory["cooldown_toughness"] = t
					for _, c in ipairs(CATEGORIES) do if c.key == "cooldown_toughness" then updateCategory(c, t) end end
				end
				trackDiscovery(t)
			end
		end
	end
	if activeOptions.scenarios.tanking then
		for _, ability in ipairs(choices.controls or {}) do
			if ability.taunt and abilityAllowedInForm(ability, "bear")
				and (not activeOptions.enabled or activeOptions.forms.bear) then
				bestByCategory.taunt = ability
				break
			end
		end
	end
	if activeOptions.scenarios.singleTarget then
		local cooldownChain = scoreCooldownChain(choices.cooldowns, baseline)
		if cooldownChain and resultInScope(cooldownChain, activeOptions) then
			local previous = bestByCategory.cooldown_damage
			if not previous or resultScore(cooldownChain, "cooldown_damage") > resultScore(previous, "cooldown_damage") then
				bestByCategory.cooldown_damage = cooldownChain
				for _, category in ipairs(CATEGORIES) do
					if category.key == "cooldown_damage" then updateCategory(category, cooldownChain) end
				end
			end
			trackDiscovery(cooldownChain)
		end
	end
	if bestByCategory.tanking then
		for _, category in ipairs(CATEGORIES) do
			if category.key == "tanking" then updateCategory(category, bestByCategory.tanking) end
		end
	end
	refreshLog()
end

function TT.ShowSimulateExplorer()
	if not frame then buildFrame() end
	populateFromCache()
	TT.RegisterEscapeFrame(frame)
	frame:Show()
	C_Timer.After(0, scoreImmediateAbilities)
end
