local ADDON, TT = ...

local BAR_HEIGHT = 10
local TEXT_HEIGHT = 12
local BORDER_TEXTURE = "Interface\\Buttons\\UI-SliderBar-Border"
local MANA_COLOR = { 0.08, 0.25, 0.95 }
local IDLE_COLOR = { 0.58, 0.69, 0.78 }
local FIVE_SECOND_RULE = 5
local FULL_MANA_PERCENT = 99.5
local REGEN_TICK_MIN = 1.5
local REGEN_TICK_MAX = 2.5
local REGEN_COLOR = { 0.75, 0.85, 1.0, 0.8 }
local MANA_ABBREVIATION_OPTIONS
local REFRESH_EVENTS = {
	"PLAYER_ENTERING_WORLD", "UPDATE_SHAPESHIFT_FORM", "UPDATE_SHAPESHIFT_FORMS",
	"UNIT_DISPLAYPOWER", "UNIT_POWER_UPDATE", "UNIT_MAXPOWER", "UNIT_SPELLCAST_SUCCEEDED",
}

local bar, label, regenOverlay, border
local observedTicking, lastPowerUpdate, lastSpendAt, manaSpendAt, regenerationActive = false, nil, nil, nil, false
local feralForm, barVisible

local function powerBar()
	local player = PlayerFrame
	local content = player and player.PlayerFrameContent
	local main = content and content.PlayerFrameContentMain
	local area = main and main.ManaBarArea
	return PlayerFrameManaBar or (player and (player.ManaBar or player.manaBar or player.PowerBar or player.powerBar))
		or (area and area.ManaBar) or (main and (main.ManaBar or main.PowerBar))
end

local function shortNumber(value)
	if value >= 1000000 then return string.format("%.2fM", value / 1000000) end
	if value >= 1000 then return string.format("%.2fK", value / 1000) end
	return string.format("%.0f", value)
end

local function formatRenderedNumber(text)
	if not TT.ReadableText(text) then return text end
	local before, amount, suffix, after = text:match("^(.-)([%d,]+%.?%d*)([KkMm])(.-)$")
	if not amount then return text end
	return before .. string.format("%.2f%s", tonumber((amount:gsub(",", ""))), suffix:upper()) .. after
end

local function manaAbbreviationOptions()
	if MANA_ABBREVIATION_OPTIONS then return MANA_ABBREVIATION_OPTIONS end
	if not C_StringUtil or not C_StringUtil.GetDefaultAbbreviationBreakpoints then return nil end
	local defaults = C_StringUtil.GetDefaultAbbreviationBreakpoints()
	if type(defaults) ~= "table" then return nil end
	local points = {}
	for _, point in ipairs(defaults) do
		local breakpoint = TT.ReadableNumber(point.breakpoint)
		if breakpoint then
			points[#points + 1] = {
				breakpoint = breakpoint,
				abbreviation = point.abbreviation,
				significandDivisor = breakpoint / 100,
				fractionDivisor = 100,
				abbreviationIsGlobal = point.abbreviationIsGlobal,
			}
		end
	end
	if #points == 0 then return nil end
	MANA_ABBREVIATION_OPTIONS = { breakpointData = points }
	return MANA_ABBREVIATION_OPTIONS
end

local function formattedManaNumber(value)
	if AbbreviateNumbers then
		return formatRenderedNumber(AbbreviateNumbers(value, manaAbbreviationOptions()))
	end
	local formatNumber = BreakUpLargeNumbers
	return formatNumber and formatRenderedNumber(formatNumber(value)) or value
end

local function regenRateText(state)
	local baseRate, castingRate
	if GetManaRegen then baseRate, castingRate = GetManaRegen() end
	local liveRate = TT.ReadableNumber(state and state.held and castingRate or baseRate)
	local measuredRate = state and state.ticking and (not state.held or state.tickAfterSpend)
		and TT.ReadableNumber(state.perSecond)
	local rate = measuredRate and math.max(measuredRate, liveRate or 0) or liveRate
	if not rate or rate <= 0 then return "" end
	return string.format(" |cff80ff80%.0f/s|r", rate)
end

local function updateRegenOverlay()
	if not regenOverlay then return end
	if not TT.db.manaBar or not barVisible or not manaSpendAt then
		regenOverlay:Hide()
		return
	end
	if regenerationActive then regenOverlay:Hide() return end
	local elapsed = GetTime() - manaSpendAt
	if elapsed >= FIVE_SECOND_RULE then
		regenerationActive = true
		bar:SetStatusBarColor(MANA_COLOR[1], MANA_COLOR[2], MANA_COLOR[3])
		regenOverlay:Hide()
		return
	end
	if regenerationActive then regenOverlay:Hide() return end
	regenOverlay:Show()
	regenOverlay:SetValue(math.max(0, elapsed / FIVE_SECOND_RULE))
end

local function paintRegeneration(state)
	local full = state and state.current / state.max * 100 >= FULL_MANA_PERCENT
	if manaSpendAt and GetTime() - manaSpendAt < FIVE_SECOND_RULE then
		regenerationActive = full or false
	else
		regenerationActive = full or state and state.ticking or observedTicking
	end
	local color = regenerationActive and MANA_COLOR or IDLE_COLOR
	bar:SetStatusBarColor(color[1], color[2], color[3])
end

local function manaCostSpell(spellID)
	if not TT.ReadableNumber(spellID) or not C_Spell or not C_Spell.GetSpellPowerCost then return false end
	for _, cost in ipairs(C_Spell.GetSpellPowerCost(spellID) or {}) do
		if TT.ReadableNumber(cost.type) == Enum.PowerType.Mana
			and TT.ReadableNumber(cost.cost) and cost.cost > 0 then return true end
	end
	return false
end

local function isManaPowerType(powerType)
	if TT.ReadableText(powerType) then return powerType:upper() == "MANA" end
	local readableType = TT.ReadableNumber(powerType)
	local manaType = Enum and Enum.PowerType and Enum.PowerType.Mana
	return readableType ~= nil and manaType ~= nil and readableType == manaType
end

feralForm = function()
	local form = TT.CurrentForm and TT.CurrentForm()
	if type(form) ~= "string" then return false end
	form = form:lower()
	return form:find("cat", 1, true) ~= nil or form:find("bear", 1, true) ~= nil
end

local function update()
	if not bar or not label then return end
	if not feralForm() then
		regenerationActive = false
		barVisible = false
		bar:Hide()
		updateRegenOverlay()
		return
	end
	barVisible = true
	bar:Show()
	local state = TT.ManaState()
	if state then
		bar:SetMinMaxValues(0, state.max)
		bar:SetValue(state.current)
		local percent = state.current / state.max * 100
		label:SetText(string.format("%s/%s (%.0f%%)%s",
			shortNumber(state.current), shortNumber(state.max), percent, regenRateText(state)))
		paintRegeneration(state)
	else
		local manaType = Enum.PowerType.Mana
		local current = UnitPower("player", manaType)
		local maximum = UnitPowerMax("player", manaType)
		bar:SetMinMaxValues(0, maximum)
		bar:SetValue(current)
		local currentText = formattedManaNumber(current)
		local maximumText = formattedManaNumber(maximum)
		local percent = UnitPowerPercent("player", manaType, false, CurveConstants and CurveConstants.ScaleTo100)
		label:SetFormattedText("%s/%s (%.0f%%)%s", currentText, maximumText, percent, regenRateText(nil))
		local readablePercent = TT.ReadableNumber(percent)
		if readablePercent and readablePercent >= FULL_MANA_PERCENT then observedTicking = true end
		paintRegeneration(nil)
	end
end

local function updateRegenState(event, now)
	if event == "PLAYER_ENTERING_WORLD" then
		observedTicking, lastPowerUpdate, lastSpendAt, manaSpendAt = false, nil, nil, nil
		return
	end
	if event ~= "UNIT_POWER_UPDATE" then return end

	local gap = lastPowerUpdate and now - lastPowerUpdate
	local sinceSpend = lastSpendAt and now - lastSpendAt
	--event timing reveals regen without inspecting protected mana values
	if sinceSpend and sinceSpend >= FIVE_SECOND_RULE then
		observedTicking = observedTicking or gap == nil
			or gap >= REGEN_TICK_MIN and gap <= REGEN_TICK_MAX or gap >= FIVE_SECOND_RULE
	elseif not lastSpendAt then
		lastSpendAt = now
		observedTicking = false
	else
		observedTicking = false
	end
	lastPowerUpdate = now
end

local function build()
	local anchor = powerBar() or PlayerFrame
	if not anchor then return false end

	bar = CreateFrame("StatusBar", "AgamonManaBar", UIParent)
	bar:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
	bar:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -2)
	bar:SetHeight(BAR_HEIGHT)
	bar:SetFrameStrata(anchor:GetFrameStrata())
	bar:SetFrameLevel(anchor:GetFrameLevel() + 1)
	bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
	bar:SetStatusBarColor(IDLE_COLOR[1], IDLE_COLOR[2], IDLE_COLOR[3])
	bar:SetMinMaxValues(0, 1)
	bar:SetValue(0)

	regenOverlay = CreateFrame("StatusBar", nil, bar)
	regenOverlay:SetPoint("TOPLEFT", bar, "TOPLEFT")
	regenOverlay:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT")
	regenOverlay:SetFrameStrata(bar:GetFrameStrata())
	regenOverlay:SetFrameLevel(bar:GetFrameLevel() + 1)
	regenOverlay:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
	regenOverlay:SetStatusBarColor(REGEN_COLOR[1], REGEN_COLOR[2], REGEN_COLOR[3], REGEN_COLOR[4])
	regenOverlay:SetMinMaxValues(0, 1)
	regenOverlay:SetValue(0)
	regenOverlay:SetScript("OnUpdate", updateRegenOverlay)
	regenOverlay:Hide()

	border = CreateFrame("Frame", nil, bar, "BackdropTemplate")
	border:SetPoint("TOPLEFT", bar, "TOPLEFT", -2, 2)
	border:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 2, -2)
	border:SetFrameStrata(bar:GetFrameStrata())
	border:SetFrameLevel(regenOverlay:GetFrameLevel() + 1)
	border:EnableMouse(false)
	border:SetBackdrop({
		edgeFile = BORDER_TEXTURE,
		tile = true,
		tileSize = 8,
		edgeSize = 8,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	border:SetBackdropBorderColor(0.78, 0.81, 0.86, 1)

	local background = bar:CreateTexture(nil, "BACKGROUND")
	background:SetAllPoints()
	background:SetColorTexture(0, 0, 0, 0.8)

	label = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	label:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -1)
	label:SetPoint("TOPRIGHT", bar, "BOTTOMRIGHT", 0, -1)
	label:SetHeight(TEXT_HEIGHT)
	label:SetJustifyH("CENTER")
	label:SetTextColor(1, 1, 1)
	bar:Show()
	update()
	updateRegenOverlay()
	return true
end

function TT.ToggleManaBar()
	TT.db.manaBar = not TT.db.manaBar
	if TT.db.manaBar then
		if not bar and not build() then
			TT.db.manaBar = false
			TT.Print("could not find the player power bar to anchor the mana bar")
			return
		end
		bar:Show()
		update()
	else
		if bar then bar:Hide() end
		barVisible = false
		updateRegenOverlay()
	end
	TT.Print("mana bar " .. (TT.db.manaBar and "enabled" or "disabled"))
end

local frame = CreateFrame("Frame")
TT.OnInit(function()
	for _, event in ipairs(REFRESH_EVENTS) do TT.Listen(frame, event) end
	if TT.db.manaBar and not build() then
		TT.db.manaBar = false
		TT.Print("could not find the player power bar to anchor the mana bar")
	end
end)
frame:SetScript("OnEvent", function(_, event, unit, powerType, spellID)
	if event:find("^UNIT_") and unit ~= "player" then return end
	if (event == "UNIT_POWER_UPDATE" or event == "UNIT_MAXPOWER") and not isManaPowerType(powerType) then return end
	local now = GetTime()
	if event == "UNIT_SPELLCAST_SUCCEEDED" then
		if manaCostSpell(spellID) then
			observedTicking, lastPowerUpdate, lastSpendAt, manaSpendAt, regenerationActive = false, nil, now, now, false
		else
			return
		end
	else
		updateRegenState(event, now)
	end
	if TT.db.manaBar then
		if not bar and not build() then
			TT.db.manaBar = false
			TT.Print("could not find the player power bar to anchor the mana bar")
			return
		end
		update()
	end
	updateRegenOverlay()
end)
