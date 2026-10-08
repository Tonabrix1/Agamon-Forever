local ADDON, TT = ...

local ROW_HEIGHT = 24
local SECTION_GAP = 10
local HEADER_HEIGHT = 20
local TAB_HEIGHT = 24
local TAB_PADDING = 14
local CONTENT_TOP = -74

local TABS = { "Tooltips", "Rotation", "Spec", "Advanced" }

local SECTIONS = {
	{ tab = "Tooltips", title = "Tooltip lines", options = {
		{ "showRate", "DPS / HPS" },
		{ "showCast", "Damage or healing per cast" },
		{ "showPerResource", "Value per resource" },
		{ "showVersus", "Comparison against your best" },
		{ "showOOM", "Casts until out of mana" },
		{ "showLogged", "What the game's meter actually measured" },
		{ "showConfidence", "How much data stands behind a measurement" },
		{ "showChain", "Totals for a castsequence macro" },
	} },
	{ tab = "Tooltips", title = "Value rows", options = {
		{ "showCombo", "By combo point" },
		{ "showUptime", "By dot uptime" },
		{ "showTargets", "By targets hit" },
	} },
	{ tab = "Rotation", title = "Rotation panel", options = {
		{ "showResourceValue", "What a point of each resource buys" },
		{ "comboIcon", "Show combo points as the game's own pip" },
	} },
	{ tab = "Rotation", title = "Minimap", options = {
		{ "showMinimap", "Show the minimap button" },
	} },
	{ tab = "Advanced", title = "Where it shows up", options = {
		{ "showEffects", "Buffs, debuffs and talents" },
		{ "showItems", "Gear stat value" },
		{ "showUnits", "Enemy armor and kill time (reload to apply)" },
	} },
	{ tab = "Advanced", title = "Other", options = {
		{ "debug", "Print tooltip lines to chat" },
	} },
}

local canvas, category
local pages = {}
local checks = {}
local specButtons = {}
local current

local function makeCheck(parent, option, y)
	local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	check:SetPoint("TOPLEFT", 18, y)
	check:SetSize(20, 20)

	local label = check:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	label:SetPoint("LEFT", check, "RIGHT", 6, 0)
	label:SetText(option[2])
	label:SetTextColor(TT.skin.text[1], TT.skin.text[2], TT.skin.text[3])

	check:SetScript("OnClick", function(self)
		local on = self:GetChecked() and true or false
		TT.db[option[1]] = on
		if option[1] == "showMinimap" and TT.RefreshMinimap then TT.RefreshMinimap() end
		if TT.RefreshPanel then TT.RefreshPanel() end
	end)
	check.key = option[1]
	checks[#checks + 1] = check
	return check
end

--one row per spec: a radio for the one you are gearing for, a box for also pricing items against it
local function makeSpecRow(parent, spec, y)
	local pick = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	pick:SetPoint("TOPLEFT", 18, y)
	pick:SetSize(20, 20)

	local label = pick:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	label:SetPoint("LEFT", pick, "RIGHT", 6, 0)
	label:SetText(spec.name)
	label:SetTextColor(TT.skin.text[1], TT.skin.text[2], TT.skin.text[3])

	local also = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	also:SetPoint("TOPLEFT", 220, y)
	also:SetSize(18, 18)

	pick:SetScript("OnClick", function()
		TT.SetSpec(spec.key)
		TT.RefreshOptions()
		if TT.RefreshPanel then TT.RefreshPanel() end
	end)
	also:SetScript("OnClick", function(self)
		TT.db.extraSpecs = TT.db.extraSpecs or {}
		TT.db.extraSpecs[spec.key] = self:GetChecked() and true or nil
	end)

	specButtons[#specButtons + 1] = { spec = spec, pick = pick, also = also }
end

local function selectTab(name)
	current = name
	for tab, page in pairs(pages) do
		page.frame:SetShown(tab == name)
		page.button.underline:SetShown(tab == name)
		local colour = tab == name and TT.skin.gold or TT.skin.metal
		page.button.label:SetTextColor(colour[1], colour[2], colour[3])
	end
end

local function makeTab(name, x)
	local button = CreateFrame("Button", nil, canvas)
	button:SetHeight(TAB_HEIGHT)

	button.label = button:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	button.label:SetPoint("CENTER")
	button.label:SetText(name)
	button:SetWidth(button.label:GetStringWidth() + TAB_PADDING * 2)
	button:SetPoint("TOPLEFT", x, -44)

	button.underline = button:CreateTexture(nil, "ARTWORK")
	button.underline:SetHeight(2)
	button.underline:SetPoint("BOTTOMLEFT", TAB_PADDING / 2, 0)
	button.underline:SetPoint("BOTTOMRIGHT", -TAB_PADDING / 2, 0)
	button.underline:SetColorTexture(TT.skin.gold[1], TT.skin.gold[2], TT.skin.gold[3], 1)

	button:SetScript("OnClick", function() selectTab(name) end)
	return button
end

local function fillPage(name, frame)
	local y = -8

	if name == "Spec" then
		local specs = TT.SpecList()
		TT.SkinHeader(frame, "Spec you are gearing for", 16, y)
		y = y - HEADER_HEIGHT
		for _, spec in ipairs(specs) do
			makeSpecRow(frame, spec, y)
			y = y - ROW_HEIGHT
		end
		local note = frame:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
		note:SetPoint("TOPLEFT", 18, y)
		note:SetText("left picks the spec, right box prices items for it too")
		y = y - HEADER_HEIGHT - SECTION_GAP
	end

	for _, section in ipairs(SECTIONS) do
		if section.tab == name then
			TT.SkinHeader(frame, section.title, 16, y)
			y = y - HEADER_HEIGHT
			for _, option in ipairs(section.options) do
				makeCheck(frame, option, y)
				y = y - ROW_HEIGHT
			end
			y = y - SECTION_GAP
		end
	end

	if name == "Advanced" then
		local simBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
		simBtn:SetPoint("TOPLEFT", 18, y - 4)
		simBtn:SetSize(120, 24)
		simBtn:SetText("Simulate")
		simBtn:SetScript("OnClick", function() if TT.ShowSimulateExplorer then TT.ShowSimulateExplorer() end end)
		y = y - 32

		local hint = frame:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
		hint:SetPoint("TOPLEFT", 18, y - 2)
		hint:SetText("/agf rank   /agf rotation   /agf meter   /agf blocked")
	end
end

local function build()
	canvas = CreateFrame("Frame", "AgamonOptions")
	canvas.name = TT.db.label

	local title = canvas:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText(TT.db.label)
	title:SetTextColor(TT.skin.gold[1], TT.skin.gold[2], TT.skin.gold[3])

	local x = 12
	for _, name in ipairs(TABS) do
		local frame = CreateFrame("Frame", nil, canvas)
		frame:SetPoint("TOPLEFT", 8, CONTENT_TOP)
		frame:SetPoint("BOTTOMRIGHT", -8, 8)
		local button = makeTab(name, x)
		pages[name] = { frame = frame, button = button }
		fillPage(name, frame)
		x = x + button:GetWidth()
	end

	local rule = canvas:CreateTexture(nil, "ARTWORK")
	rule:SetHeight(1)
	rule:SetPoint("TOPLEFT", 12, CONTENT_TOP + 4)
	rule:SetPoint("TOPRIGHT", -12, CONTENT_TOP + 4)
	rule:SetColorTexture(TT.skin.goldDim[1], TT.skin.goldDim[2], TT.skin.goldDim[3], 0.8)

	canvas:SetScript("OnShow", TT.RefreshOptions)
	selectTab(TABS[1])

	--writing our own ID over the category's breaks GetID, which this client passes straight to a numeric-only api
	category = Settings.RegisterCanvasLayoutCategory(canvas, TT.db.label)
	Settings.RegisterAddOnCategory(category)
end

function TT.RefreshOptions()
	for _, check in ipairs(checks) do check:SetChecked(TT.db[check.key] and true or false) end
	local spec = TT.Spec()
	for _, row in ipairs(specButtons) do
		row.pick:SetChecked(spec and spec.key == row.spec.key)
		row.also:SetChecked((TT.db.extraSpecs or {})[row.spec.key] and true or false)
	end
end

function TT.ToggleOptions()
	if not canvas then build() end
	Settings.OpenToCategory(category:GetID())
end

TT.OnInit(function()
	if Settings and Settings.RegisterCanvasLayoutCategory then build() end
end)
