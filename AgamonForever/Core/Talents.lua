local ADDON, TT = ...

local COMBO_PATTERNS = {
	"(%d+)%% chance to [%a%s]-an additional combo point",
	"(%d+)%% chance to [%a%s]-an extra combo point",
	"(%d+)%% chance of [%a%s]-an additional combo point",
}

local cached, cooldownCuts

local function talentLines(tab, index)
	local data
	if C_TooltipInfo and C_TooltipInfo.GetTalent then
		data = C_TooltipInfo.GetTalent(tab, index)
	end
	if not data and C_TooltipInfo and C_TooltipInfo.GetHyperlink and GetTalentLink then
		local link = GetTalentLink(tab, index)
		if link then data = C_TooltipInfo.GetHyperlink(link) end
	end
	if not data or not data.lines then return nil end
	if TooltipUtil and TooltipUtil.SurfaceArgs then TooltipUtil.SurfaceArgs(data) end

	local lines = {}
	for _, line in ipairs(data.lines) do
		if TooltipUtil and TooltipUtil.SurfaceArgs then TooltipUtil.SurfaceArgs(line) end
		TT.SplitText(lines, line.leftText)
	end
	return lines
end

--found by reading the talents you actually took, so anything worded like primal fury counts without naming it
local function scan()
	if not GetNumTalentTabs or not GetTalentInfo then return 0 end
	local chance = 0
	for tab = 1, (GetNumTalentTabs() or 0) do
		for index = 1, (GetNumTalents(tab) or 0) do
			local _, _, _, _, rank = GetTalentInfo(tab, index)
			if TT.Readable(rank) and rank > 0 then
				for _, line in ipairs(talentLines(tab, index) or {}) do
					local lower = line:lower()
					for _, pattern in ipairs(COMBO_PATTERNS) do
						local pct = lower:match(pattern)
						if pct then chance = math.max(chance, tonumber(pct) / 100) end
					end
				end
			end
		end
	end
	return chance
end

function TT.ComboBonus()
	if cached == nil then cached = scan() end
	return cached
end

local SHIFT_PATTERNS = {
	energy = { "(%d+) energy when you shapeshift", "shapeshift[^%.]-(%d+) energy" },
	rage = { "(%d+) rage when you shapeshift", "shapeshift[^%.]-(%d+) rage" },
}

local shiftGrant

--what a shapeshift is actually worth to you, which is whatever your talents hand you for doing it
local function scanShift()
	local grant = {}
	if not GetNumTalentTabs or not GetTalentInfo then return grant end
	for tab = 1, (GetNumTalentTabs() or 0) do
		for index = 1, (GetNumTalents(tab) or 0) do
			local _, _, _, _, rank = GetTalentInfo(tab, index)
			if TT.Readable(rank) and rank > 0 then
				for _, line in ipairs(talentLines(tab, index) or {}) do
					local lower = line:lower()
					for kind, patterns in pairs(SHIFT_PATTERNS) do
						for _, pattern in ipairs(patterns) do
							local amount = lower:match(pattern)
							if amount then grant[kind] = math.max(grant[kind] or 0, tonumber(amount)) end
						end
					end
				end
			end
		end
	end
	return grant
end

function TT.ShiftGrant()
	if not shiftGrant then shiftGrant = scanShift() end
	return shiftGrant
end

local function scanCooldownCuts()
	local cuts = {}
	if not GetNumTalentTabs or not GetTalentInfo then return cuts end
	for tab = 1, (GetNumTalentTabs() or 0) do
		for index = 1, (GetNumTalents(tab) or 0) do
			local _, _, _, _, rank = GetTalentInfo(tab, index)
			if TT.Readable(rank) and rank > 0 then
				local lines = talentLines(tab, index)
				local effect = lines and TT.ParseEffect and TT.ParseEffect(lines)
				for _, cut in ipairs(effect and effect.cooldownCuts or {}) do
					local amount = cut.amount * (cut.perRank and rank or 1)
					local key = cut.name:lower()
					cuts[key] = (cuts[key] or 0) + amount
				end
			end
		end
	end
	return cuts
end

function TT.CooldownCuts()
	if not cooldownCuts then cooldownCuts = scanCooldownCuts() end
	return cooldownCuts
end

--the mana a shapeshift costs, read off the form you are speccing for
function TT.ShiftCost()
	if not GetNumShapeshiftForms or not GetShapeshiftFormInfo then return nil end
	for index = 1, (GetNumShapeshiftForms() or 0) do
		local spellID = TT.FormSpell(index)
		local costs = spellID and C_Spell.GetSpellPowerCost(spellID)
		for _, cost in ipairs(costs or {}) do
			if cost.type == Enum.PowerType.Mana and cost.cost > 0 then return cost.cost end
		end
	end
	return nil
end

--a builder awards one point, plus whatever your crits add on top of it
function TT.ComboPerBuilder()
	local stats = TT.Stats()
	local crit = (stats and stats.crit or 0) / 100
	return 1 + TT.ComboBonus() * crit
end

local frame = CreateFrame("Frame")
TT.OnInit(function()
	TT.Listen(frame, "CHARACTER_POINTS_CHANGED")
	TT.Listen(frame, "PLAYER_TALENT_UPDATE")
end)
frame:SetScript("OnEvent", function()
	cached, shiftGrant, cooldownCuts = nil, nil, nil
end)
