local ADDON, TT = ...

local PANEL_WIDTH = 268
local PANEL_HEIGHT = 250
local MIN_COMPACT_HEIGHT = 82
local LINE_HEIGHT = 15
local ICON_SIZE = 30
local ARROW_WIDTH = 24 --a little extra room so the word tab does not crowd the next icon
local RING_WIDTH = 3 --wide enough to read under the icon's own 1px edge
local CAPTION_HEIGHT = 13
local ROW_HEIGHT = ICON_SIZE + CAPTION_HEIGHT + 6 + RING_WIDTH --the ring hangs above the icon, so the caption needs the room
local STRIP_TOP = -80 - CAPTION_HEIGHT - RING_WIDTH --keep rotation captions below the effective-health line
local REFRESH_EVENTS = {
	"UPDATE_SHAPESHIFT_FORM", "UPDATE_SHAPESHIFT_FORMS", "ACTIONBAR_PAGE_CHANGED",
	"UPDATE_BONUS_ACTIONBAR", "ACTIONBAR_SLOT_CHANGED", "PLAYER_EQUIPMENT_CHANGED",
	"PLAYER_TALENT_UPDATE", "PLAYER_TARGET_CHANGED", "SPELLS_CHANGED",
}
local POLL_SECONDS = 0.2
local NEXT_HEIGHT = 18
local CYCLE_TARGETS = 5 --the button steps through pack sizes up to this, and shift click takes any number
local PROMPT_WIDTH = 260
local PROMPT_HEIGHT = 108

local panel, dpsLabel, dps, ehpLabel, ehpValue, note, well, scroll, content, strip, nextLine, sizer, packer, prompt
local strips = {}
local lines = {}
local dirty = true
local lastContext
local lastPreview, lastPreviewLabel, lastDetailed

--everything on the panel is read off one simulation, so changing the pack size means building it again
function TT.SetTargets(count)
	if count == nil then
		TT.db.autoTargets = true
	else
		TT.db.autoTargets = false
		TT.db.targets = math.max(1, math.floor(tonumber(count) or 1))
	end
	TT.InvalidateRotation()
	TT.RefreshPanel()
end

--our own prompt rather than a StaticPopupDialogs entry: writing that global taints it, and the escape handler reads it
local function buildPrompt()
	prompt = CreateFrame("Frame", nil, UIParent)
	prompt:SetSize(PROMPT_WIDTH, PROMPT_HEIGHT)
	prompt:SetPoint("CENTER", 0, 120)
	prompt:SetFrameStrata("FULLSCREEN_DIALOG")
	prompt:SetToplevel(true)
	prompt:Hide()
	TT.SkinPanel(prompt)
	TT.SkinTitle(prompt, "Targets")
	TT.SkinClose(prompt)

	local label = prompt:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	label:SetPoint("TOPLEFT", 16, -44)
	label:SetPoint("TOPRIGHT", -16, -44)
	label:SetJustifyH("LEFT")
	label:SetText("how many targets should the rotation be simulated against?")

	local box = CreateFrame("EditBox", nil, prompt)
	box:SetSize(PROMPT_WIDTH - 32, 20)
	box:SetPoint("BOTTOMLEFT", 16, 14)
	box:SetAutoFocus(true)
	box:SetMaxLetters(3)
	box:SetNumeric(true)
	box:SetFontObject("GameFontHighlight")
	box:SetTextInsets(6, 6, 0, 0)
	TT.SkinInset(box)
	box:SetScript("OnEnterPressed", function(self)
		local typed = tonumber(self:GetText())
		if typed then TT.SetTargets(typed) end
		prompt:Hide()
	end)
	box:SetScript("OnEscapePressed", function() prompt:Hide() end)
	prompt.box = box
	prompt:SetScript("OnShow", function()
		box:SetText(tostring(TT.Targets()))
		box:HighlightText()
		box:SetFocus()
	end)
end

local function showTargetPrompt()
	if not prompt then buildPrompt() end
	prompt:Show()
end

local function lineAt(index)
	if lines[index] then return lines[index] end
	--the well is a child frame, so anything drawn on the panel sits under its dark fill
	local text = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	text:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -7 - (index - 1) * LINE_HEIGHT)
	text:SetPoint("RIGHT", content, "RIGHT", -8, 0)
	text:SetJustifyH("LEFT")
	lines[index] = text
	return text
end

--we are the ones who set this tooltip, so re-setting it is ours to do, and alt can switch the block while you hover
local function altWatch(self)
	local now = TT.Detailed()
	if now == self.alt then return end
	self.alt = now
	if self.spellID and GameTooltip:IsOwned(self) then GameTooltip:SetSpellByID(self.spellID) end
end

--each step is a real button, so hovering it opens the spell's own tooltip with our numbers already on it
local function iconAt(row, index)
	if row.icons[index] then return row.icons[index] end

	local button = CreateFrame("Button", nil, row.frame)
	button:SetSize(ICON_SIZE, ICON_SIZE)
	button:EnableMouse(true)

	button.texture = button:CreateTexture(nil, "ARTWORK")
	button.texture:SetAllPoints()
	button.texture:SetTexCoord(0.07, 0.93, 0.07, 0.93)

	local edge = button:CreateTexture(nil, "BORDER")
	edge:SetPoint("TOPLEFT", -1, 1)
	edge:SetPoint("BOTTOMRIGHT", 1, -1)
	edge:SetColorTexture(TT.skin.goldDim[1], TT.skin.goldDim[2], TT.skin.goldDim[3], 0.9)

	button.count = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	button.count:SetPoint("TOPLEFT", -2, 3)
	button.count:SetTextColor(1, 1, 1)

	button.points = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	button.points:SetPoint("BOTTOMRIGHT", 3, -3)
	button.points:SetTextColor(TT.skin.gold[1], TT.skin.gold[2], TT.skin.gold[3])

	--the live call is a ring rather than a line of text: it sits under the icon's own edge, so only its outer band shows
	button.ring = button:CreateTexture(nil, "BACKGROUND")
	button.ring:SetPoint("TOPLEFT", -RING_WIDTH, RING_WIDTH)
	button.ring:SetPoint("BOTTOMRIGHT", RING_WIDTH, -RING_WIDTH)
	button.ring:SetColorTexture(TT.skin.gold[1], TT.skin.gold[2], TT.skin.gold[3], 1)
	button.ring:Hide()

	button.arrow = row.frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	button.arrow:SetPoint("LEFT", button, "RIGHT", 2, 0)
	button.arrow:SetText(">")
	button.arrow:SetTextColor(TT.skin.goldDim[1], TT.skin.goldDim[2], TT.skin.goldDim[3])

	--SetSpellByID shows the tooltip itself; calling Show on it is what the blocked-action rules forbid
	button:SetScript("OnEnter", function(self)
		if not self.spellID then return end
		self.alt = TT.Detailed()
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetSpellByID(self.spellID)
		self:SetScript("OnUpdate", altWatch)
	end)
	button:SetScript("OnLeave", function(self)
		self:SetScript("OnUpdate", nil)
		if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
	end)

	row.icons[index] = button
	return button
end

local function rowAt(index)
	if strips[index] then return strips[index] end
	local frame = CreateFrame("Frame", nil, strip)
	frame:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
	frame:SetPoint("TOPRIGHT", 0, -(index - 1) * ROW_HEIGHT)
	frame:SetHeight(ICON_SIZE)

	local label = frame:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	label:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 1, 2 + RING_WIDTH)

	strips[index] = { frame = frame, label = label, icons = {} }
	return strips[index]
end

local function drawRow(row, sequence, caption)
	local x, shown = 0, 0
	for index, run in ipairs(sequence or {}) do
		local button = iconAt(row, index)
		button:ClearAllPoints()
		button:SetPoint("TOPLEFT", row.frame, "TOPLEFT", x, 0)
		button.spellID = run.id
		button.texture:SetTexture(C_Spell.GetSpellTexture(run.id) or "Interface\\Icons\\INV_Misc_QuestionMark")
		button.count:SetText(run.count > 1 and (run.count .. "x") or "")
		button.points:SetText(run.points and (run.points .. TT.ComboMark()) or "")
		button:Show()
		shown = index
		x = x + ICON_SIZE + ARROW_WIDTH
		--a repeat on one mob and a tab round the pack look identical as icons, so the arrow says which it is
		local following = sequence[index + 1]
		local tabbing = run.spread or (following and following.tab)
		button.arrow:SetFontObject(tabbing and GameFontNormalSmall or GameFontNormal)
		button.arrow:SetText(tabbing and "tab" or ">")
		local tint = tabbing and TT.skin.gold or TT.skin.goldDim
		button.arrow:SetTextColor(tint[1], tint[2], tint[3])
		button.arrow:Show()
	end
	if shown > 0 and not sequence[shown].spread then row.icons[shown].arrow:Hide() end
	if shown > 0 and sequence[shown].spread then row.icons[shown].arrow:SetPoint("LEFT", row.icons[shown], "RIGHT", 2, 0) end
	for index = shown + 1, #row.icons do
		row.icons[index]:Hide()
		row.icons[index].arrow:Hide()
	end
	row.label:SetText(shown > 0 and caption or "")
	row.frame:SetShown(shown > 0)
	return shown
end

--two rows: what you do once at the start, then the part that repeats and the clock it runs on
local function drawSequence(result)
	if not result then
		for _, row in ipairs(strips) do drawRow(row, nil, "") end
		return 0
	end
	local opener = rowAt(1)
	local loop = rowAt(2)
	--a form change is a cast the simulation paid for, so it is already in the strip rather than pinned to the front
	local drawnOpener = drawRow(opener, result.opener, "|cffb0a894opener|r")
	local caption = result.loopTime and string.format("|cffffd100rotation|r |cffb0a894%.1fs|r", result.loopTime) or "|cffffd100rotation|r"
	local drawnLoop = drawRow(loop, result.loop or result.sequence, caption)

	--with nothing to open with, the loop moves up into the first row's place
	loop.frame:ClearAllPoints()
	local offset = drawnOpener > 0 and ROW_HEIGHT or 0
	loop.frame:SetPoint("TOPLEFT", 0, -offset)
	loop.frame:SetPoint("TOPRIGHT", 0, -offset)

	return (drawnOpener > 0 and 1 or 0) + (drawnLoop > 0 and 1 or 0)
end

--the well starts under however many strip rows were actually drawn, and the panel is only ever as tall as what it drew
local function fit(count, stripRows, nextShown)
	local stripSpace = stripRows > 0 and (stripRows * ROW_HEIGHT + 8) or 0
	local top = STRIP_TOP - stripSpace

	strip:SetHeight(math.max(1, stripRows * ROW_HEIGHT))
	strip:SetShown(stripRows > 0)

	nextLine:ClearAllPoints()
	nextLine:SetPoint("TOPLEFT", 16, top)
	nextLine:SetPoint("RIGHT", panel, "RIGHT", -14, 0)
	--the ring costs no row, so the well only gives up the space when the fallback line is actually drawn
	local below = top - (nextShown and NEXT_HEIGHT or 0)

	--compact is the strip, the dps and the live call, and nothing that only reads the same at every glance
	if TT.db.compact then
		well:Hide()
		note:Hide()
		local stripBottom = stripRows > 0 and (-STRIP_TOP + (stripRows - 1) * ROW_HEIGHT + ICON_SIZE + RING_WIDTH) or 0
		local contentBottom = math.max(stripBottom, nextShown and (-top + NEXT_HEIGHT) or 0)
		panel:SetHeight(math.max(contentBottom + 14, MIN_COMPACT_HEIGHT))
		return
	end

	local body = count * LINE_HEIGHT + 20
	well:Show()
	note:Show()
	local maxHeight = math.max(-below + 80, UIParent:GetHeight() - 40)
	local panelHeight = math.min(-below + body + 40, maxHeight)
	local viewportHeight = math.max(40, panelHeight + below - 40)
	content:SetHeight(body)
	scroll:SetVerticalScroll(math.min(scroll:GetVerticalScroll(), math.max(0, body - viewportHeight)))
	well:SetHeight(viewportHeight)
	well:ClearAllPoints()
	well:SetPoint("TOPLEFT", 12, below)
	well:SetPoint("TOPRIGHT", -12, below)
	panel:SetHeight(panelHeight)
end

--the live call changes second to second, which is why it is read on the poll and not on the simulation
local function refreshNext()
	if not panel then return false end
	local choice = TT.NextCast()
	local wanted = choice and choice.id or nil
	--the strip draws the same ability more than once, and only the first one it comes to is the one you press next
	local marked = false
	for _, row in ipairs(strips) do
		for _, button in ipairs(row.icons) do
			local on = not marked and wanted ~= nil and button.spellID == wanted and button:IsShown()
			button.ring:SetShown(on)
			marked = marked or on
		end
	end
	--an ability the strip never draws cannot be ringed, so it falls back to the one line it used to have
	if nextLine then
		nextLine:SetText(choice and not marked and string.format("|cffb0a894next|r  %s", choice.name) or "")
	end
	return choice ~= nil and not marked
end

local function refresh()
	if not panel or not panel:IsShown() then return end
	dirty = false

	local result = TT.Rotation()
	--a talent you are holding alt over replaces the whole panel with the rotation it would give you
	local shown, previewOf = TT.Preview()
	if not TT.Detailed() then shown, previewOf = nil, nil end
	if shown then result = shown end
	for _, text in ipairs(lines) do text:SetText("") end
	sizer.caption:SetText(TT.db.compact and "full" or "compact")
	local targets = TT.Targets()
	packer.caption:SetText(TT.db.autoTargets and ("auto " .. targets) or (targets == 1 and "1 target" or (targets .. " targets")))

	--the ring is put on a drawn icon, so the strip has to exist before the live call is read
	if not result then
		local effectiveHealth = TT.BaseEhp and TT.BaseEhp() or 0
		ehpLabel:SetText(effectiveHealth > 0 and "Effective health" or "")
		ehpValue:SetText(effectiveHealth > 0 and TT.FormatNumber(effectiveHealth) or "")
		dpsLabel:SetText("")
		dps:SetText("")
		note:SetText("")
		note:Hide()
		well:Hide()
		drawSequence(nil)
		refreshNext()
		panel:SetHeight(MIN_COMPACT_HEIGHT)
		return
	end

	local effectiveHealth = TT.BaseEhp and TT.BaseEhp() or 0
	ehpLabel:SetText(effectiveHealth > 0 and "Effective health" or "")
	ehpValue:SetText(effectiveHealth > 0 and TT.FormatNumber(effectiveHealth) or "")
	dpsLabel:SetText("Rotation DPS")
	if TT.db.compact then
		dps:SetText(string.format("%.0f", result.dps))
		local rows = drawSequence(result)
		fit(0, rows, refreshNext())
		return
	end

	dps:SetText(string.format("%.0f", result.dps))
	local how
	if result.model == "energy" then
		how = string.format("simulated over %.0fs, %s", result.fight or 0, result.fightSource or "assumed")
		if (result.targets or 1) > 1 then how = how .. string.format(", against %d targets", result.targets) end
		if previewOf then how = previewOf end
	elseif result.model == "rage" then
		how = string.format("rage from auto-attacks only, %.1f per sec", result.resourcePerSecond or 0)
	elseif result.model == "mana" then
		how = string.format("mana-limited estimate, %.0f%% cast uptime", (result.manaUptime or 1) * 100)
	else
		how = "estimate, no resource model"
	end
	note:SetText(how)
	local stripRows = drawSequence(result)

	local rows = 0
	local entries = TT.Efficiency()
	if entries and #entries > 0 then
		rows = rows + 1
		lineAt(rows):SetText("|cffffd100Per resource|r |cff888888net of regen|r")
		for rank = 1, math.min(5, #entries) do
			local entry = entries[rank]
			local mark = entry.spender and (entry.breakpoint and ("  |cff9fd98fspend at " .. entry.breakpoint .. "|r " .. TT.ComboMark()) or "  |cffd98f8fnever|r") or ""
			local _, share = TT.ShareOfAverage(entry.power, entry.value)
			rows = rows + 1
			lineAt(rows):SetText(string.format("|cffe8e0cc%s|r  |cffffd100%.1f|r  |cff888888%s|r%s",
				entry.name, entry.value, share or "", mark))
		end
	end

	local worth = TT.WorthLines()
	if TT.db.showResourceValue and #worth > 0 then
		rows = rows + 2
		lineAt(rows):SetText("|cffffd100What a point buys|r")
		for _, entry in ipairs(worth) do
			rows = rows + 1
			lineAt(rows):SetText(string.format("|cffe8e0cc%s|r  |cffffd100%.2f|r |cff888888dmg|r", entry.label, entry.value))
		end
	end

	rows = rows + 2
	lineAt(rows):SetText(string.format("|cffb0a894swing is %.0f of the %.0f|r", result.melee, result.dps))
	if result.perBuilder and result.perBuilder > 1.01 then
		rows = rows + 1
		lineAt(rows):SetText(string.format("|cffb0a894%.2f combo per builder from talents|r", result.perBuilder))
	end

	fit(rows, stripRows, refreshNext())
end

local function onScreen(anchor)
	if not anchor or not anchor.x or not anchor.y then return false end
	return math.abs(anchor.x) <= UIParent:GetWidth() / 2 and math.abs(anchor.y) <= UIParent:GetHeight() / 2
end

local function build()
	panel = CreateFrame("Frame", "AgamonRotationPanel", UIParent)
	panel:SetSize(PANEL_WIDTH, PANEL_HEIGHT)
	--the character sheet draws at HIGH too, and whichever was shown last wins there
	panel:SetFrameStrata("DIALOG")
	panel:SetToplevel(true)
	panel:SetClampedToScreen(true)
	panel:EnableMouse(true)
	panel:SetMovable(true)
	panel:RegisterForDrag("LeftButton")
	panel:SetScript("OnDragStart", panel.StartMoving)
	panel:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local x, y = self:GetCenter()
		local centreX, centreY = UIParent:GetCenter()
		TT.db.panelAnchor = { x = x - centreX, y = y - centreY }
	end)

	--a saved anchor from a different resolution can put the panel where nothing can reach it
	local saved = TT.db.panelAnchor
	if saved and onScreen(saved) then
		panel:SetPoint("CENTER", UIParent, "CENTER", saved.x, saved.y)
	else
		TT.db.panelAnchor = nil
		panel:SetPoint("RIGHT", UIParent, "RIGHT", -40, 60)
	end

	TT.SkinPanel(panel)
	TT.SkinTitle(panel, "Agamon: Forever")
	TT.SkinClose(panel):SetScript("OnClick", function() TT.ShowPanel(false) end)
	panel:SetScript("OnHide", function()
		if TT.db then TT.db.panelOpen = false end
	end)

	dpsLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	dpsLabel:SetPoint("TOPLEFT", 16, -42)
	dpsLabel:SetText("Rotation DPS")
	dpsLabel:SetTextColor(TT.skin.text[1], TT.skin.text[2], TT.skin.text[3])

	dps = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	dps:SetPoint("TOPRIGHT", -16, -40)
	dps:SetTextColor(TT.skin.gold[1], TT.skin.gold[2], TT.skin.gold[3])

	ehpLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	ehpLabel:SetPoint("TOPLEFT", 16, -59)
	ehpLabel:SetTextColor(TT.skin.metal[1], TT.skin.metal[2], TT.skin.metal[3])
	ehpValue = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	ehpValue:SetPoint("TOPRIGHT", -16, -59)
	ehpValue:SetTextColor(TT.skin.text[1], TT.skin.text[2], TT.skin.text[3])

	strip = CreateFrame("Frame", nil, panel)
	strip:SetPoint("TOPLEFT", 14, STRIP_TOP)
	strip:SetPoint("TOPRIGHT", -14, STRIP_TOP)
	strip:SetHeight(ROW_HEIGHT * 2)

	well = CreateFrame("Frame", nil, panel)
	TT.SkinInset(well)

	scroll = CreateFrame("ScrollFrame", nil, well, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", well, "TOPLEFT", 6, -6)
	scroll:SetPoint("BOTTOMRIGHT", well, "BOTTOMRIGHT", -20, 6)
	content = CreateFrame("Frame", nil, scroll)
	content:SetWidth(PANEL_WIDTH - 46)
	scroll:SetScrollChild(content)
	scroll:EnableMouseWheel(true)
	scroll:SetScript("OnMouseWheel", function(self, delta)
		local limit = math.max(0, content:GetHeight() - self:GetHeight())
		self:SetVerticalScroll(math.max(0, math.min(limit, self:GetVerticalScroll() - delta * LINE_HEIGHT * 3)))
	end)

	nextLine = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	nextLine:SetJustifyH("LEFT")

	note = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	note:SetPoint("BOTTOMLEFT", 14, 10)

	--a real button with an edge, clear of the close button's own hit area, because an unmarked label is not a control
	sizer = CreateFrame("Button", "AgamonCompactButton", panel)
	sizer:SetSize(58, 18)
	sizer:SetPoint("TOPRIGHT", -40, -11)
	TT.SkinInset(sizer)
	sizer.caption = sizer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	sizer.caption:SetPoint("CENTER")
	local function paint(button, lit)
		local shade = lit and TT.skin.gold or TT.skin.text
		button.caption:SetTextColor(shade[1], shade[2], shade[3])
	end
	paint(sizer, false)
	sizer:SetScript("OnEnter", function(self) paint(self, true) end)
	sizer:SetScript("OnLeave", function(self) paint(self, false) end)
	sizer:SetScript("OnClick", function()
		TT.db.compact = not TT.db.compact
		TT.RefreshPanel()
	end)

	--the pack the rotation is simulated against, cycling through the common sizes with any number a shift click away
	packer = CreateFrame("Button", "AgamonTargetsButton", panel)
	packer:SetSize(58, 18)
	packer:SetPoint("TOPRIGHT", sizer, "TOPLEFT", -6, 0)
	TT.SkinInset(packer)
	packer.caption = packer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	packer.caption:SetPoint("CENTER")
	paint(packer, false)
	packer:SetScript("OnEnter", function(self)
		paint(self, true)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
		GameTooltip:AddLine("Targets")
		GameTooltip:AddLine("auto counts the enemies on your plates", 0.7, 0.7, 0.7)
		GameTooltip:AddLine("click to step up from the count on the button, wrapping at " .. CYCLE_TARGETS, 0.7, 0.7, 0.7)
		GameTooltip:AddLine("right click to go back to auto", 0.7, 0.7, 0.7)
		GameTooltip:AddLine("shift click to type a number", 0.7, 0.7, 0.7)
		GameTooltip:Show()
	end)
	packer:SetScript("OnLeave", function(self)
		paint(self, false)
		if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
	end)
	packer:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	--counting up from whatever is on the button, so pinning the pack you are already in is one click rather than five
	packer:SetScript("OnClick", function(_, button)
		if button == "RightButton" then TT.SetTargets(nil) return end
		if IsShiftKeyDown() then showTargetPrompt() return end
		TT.SetTargets(TT.Targets() % CYCLE_TARGETS + 1)
	end)

	panel:SetScript("OnShow", refresh)
end

--the panel's own state, and nothing but a click changes it, so closing it stays closed
function TT.ShowPanel(show)
	if not TT.db then return end
	TT.db.panelOpen = show and true or false
	TT.RefreshPanel()
end

function TT.TogglePanel()
	TT.ShowPanel(not (TT.db and TT.db.panelOpen))
end

--polled rather than hooked: a hook on the character frame runs our code inside Blizzard's panel system and taints it
local function update()
	if not TT.db then return end
	local detailed = TT.Detailed()
	local preview, previewLabel = TT.Preview()
	if detailed ~= lastDetailed or preview ~= lastPreview or previewLabel ~= lastPreviewLabel then
		lastDetailed, lastPreview, lastPreviewLabel = detailed, preview, previewLabel
		dirty = true
	end
	local context = TT.RotationContext()
	if lastContext ~= context then
		lastContext = context
		dirty = true
		TT.InvalidateRotation()
	end

	if not TT.db.panelOpen then
		if panel then panel:Hide() end
		return
	end
	if not panel then build() end
	if not panel:IsShown() then
		TT.RegisterEscapeFrame(panel)
		panel:Show()
		dirty = true
	end
	if dirty then refresh() else refreshNext() end
end

local frame = CreateFrame("Frame")
TT.OnInit(function()
	for _, event in ipairs(REFRESH_EVENTS) do TT.Listen(frame, event) end
end)
frame:SetScript("OnEvent", function(self, event)
	dirty = true
	TT.InvalidateRotation()
end)

local elapsed = 0
frame:SetScript("OnUpdate", function(self, delta)
	elapsed = elapsed + delta
	if elapsed < POLL_SECONDS then return end
	elapsed = 0
	update()
end)

--a panel that exists and cannot be seen looks the same as one that was never built, so it says where it thinks it is
function TT.PanelReport()
	if not panel then return "the panel was never built, panelOpen is " .. tostring(TT.db.panelOpen) end
	local point, _, relative, x, y = panel:GetPoint()
	local _, why = TT.Rotation()
	return string.format("panel shown=%s at %s %+.0f %+.0f of %s, %dx%d, strata %s, rotation: %s",
		tostring(panel:IsShown()), tostring(point), x or 0, y or 0, tostring(relative),
		panel:GetWidth() or 0, panel:GetHeight() or 0, tostring(panel:GetFrameStrata()), why or "built")
end

function TT.RefreshPanel()
	dirty = true
	update()
end
