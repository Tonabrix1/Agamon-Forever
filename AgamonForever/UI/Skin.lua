local ADDON, TT = ...

--the look is lifted from GearQuest Forever: metal edge, warm dark fill, gold rules, blizzard fonts
local METAL_EDGE = "Interface\\Tooltips\\UI-Tooltip-Border"
local DIALOG_BG = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark"
local CONFIRM_WIDTH = 360
local CONFIRM_PAD = 18

TT.skin = {
	gold = { 0.90, 0.75, 0.28 },
	goldDim = { 0.55, 0.45, 0.22 },
	metal = { 0.78, 0.72, 0.58 },
	panel = { 0.14, 0.10, 0.06, 0.96 },
	inset = { 0.02, 0.02, 0.02, 0.85 },
	text = { 0.92, 0.88, 0.78 },
}

function TT.RegisterEscapeFrame(frame)
	local name = frame:GetName()
	if not name or type(UISpecialFrames) ~= "table" then return end
	for index = #UISpecialFrames, 1, -1 do
		if UISpecialFrames[index] == name then table.remove(UISpecialFrames, index) end
	end
	UISpecialFrames[#UISpecialFrames + 1] = name
end

local function backdropCapable(frame)
	if frame.SetBackdrop then return true end
	if not BackdropTemplateMixin then return false end
	Mixin(frame, BackdropTemplateMixin)
	frame:OnBackdropLoaded()
	return frame.SetBackdrop ~= nil
end

local function drawnBorder(frame, color)
	local function edge()
		local tex = frame:CreateTexture(nil, "OVERLAY")
		tex:SetColorTexture(color[1], color[2], color[3], 0.95)
		return tex
	end
	local top, bottom, left, right = edge(), edge(), edge(), edge()
	top:SetHeight(1)
	top:SetPoint("TOPLEFT")
	top:SetPoint("TOPRIGHT")
	bottom:SetHeight(1)
	bottom:SetPoint("BOTTOMLEFT")
	bottom:SetPoint("BOTTOMRIGHT")
	left:SetWidth(1)
	left:SetPoint("TOPLEFT")
	left:SetPoint("BOTTOMLEFT")
	right:SetWidth(1)
	right:SetPoint("TOPRIGHT")
	right:SetPoint("BOTTOMRIGHT")
end

--a window: tiled dialog fill, metal edge where the client supports it, drawn gold rules where it does not
function TT.SkinPanel(frame, fill)
	local skin = TT.skin
	local color = fill or skin.panel

	local background = frame:CreateTexture(nil, "BACKGROUND")
	background:SetAllPoints()
	background:SetTexture(DIALOG_BG, "REPEAT", "REPEAT")
	background:SetHorizTile(true)
	background:SetVertTile(true)
	background:SetVertexColor(color[1] * 3, color[2] * 3, color[3] * 3, color[4] or 1)

	local tint = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
	tint:SetAllPoints()
	tint:SetColorTexture(color[1], color[2], color[3], 0.55)

	if backdropCapable(frame) then
		frame:SetBackdrop({
			edgeFile = METAL_EDGE,
			tile = true,
			tileSize = 16,
			edgeSize = 16,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		})
		frame:SetBackdropBorderColor(skin.metal[1], skin.metal[2], skin.metal[3], 1)
	else
		drawnBorder(frame, skin.gold)
	end
end

--an inset: the darker well that lists and rows sit in
function TT.SkinInset(frame)
	local skin = TT.skin
	local background = frame:CreateTexture(nil, "BACKGROUND")
	background:SetAllPoints()
	background:SetColorTexture(skin.inset[1], skin.inset[2], skin.inset[3], skin.inset[4])
	drawnBorder(frame, skin.goldDim)
end

function TT.SkinTitle(frame, text)
	local skin = TT.skin
	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -13)
	title:SetText(text)
	title:SetTextColor(skin.gold[1], skin.gold[2], skin.gold[3])

	local rule = frame:CreateTexture(nil, "ARTWORK")
	rule:SetHeight(1)
	rule:SetPoint("TOPLEFT", 14, -34)
	rule:SetPoint("TOPRIGHT", -14, -34)
	rule:SetColorTexture(skin.goldDim[1], skin.goldDim[2], skin.goldDim[3], 0.8)
	return title
end

function TT.SkinHeader(frame, text, x, y)
	local skin = TT.skin
	local header = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	header:SetPoint("TOPLEFT", x, y)
	header:SetText(text)
	header:SetTextColor(skin.gold[1], skin.gold[2], skin.gold[3])
	return header
end

--one shared confirm, built once and re-worded per use, because an irreversible button should say what it destroys
--no keyboard handling at all: escape is the key the client is touchiest about, so this closes by button only
local confirm

local function buildConfirm()
	confirm = CreateFrame("Frame", nil, UIParent)
	confirm:SetWidth(CONFIRM_WIDTH)
	confirm:SetPoint("CENTER", 0, 140)
	--a question about something irreversible is answered before anything behind it, so it sits above every panel we draw
	confirm:SetFrameStrata("FULLSCREEN_DIALOG")
	confirm:SetToplevel(true)
	confirm:Hide()
	TT.SkinPanel(confirm)
	confirm.title = TT.SkinTitle(confirm, "")
	TT.SkinClose(confirm)

	confirm.body = confirm:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	confirm.body:SetPoint("TOPLEFT", CONFIRM_PAD, -46)
	confirm.body:SetWidth(CONFIRM_WIDTH - CONFIRM_PAD * 2)
	confirm.body:SetJustifyH("LEFT")
	confirm.body:SetSpacing(3)

	confirm.accept = CreateFrame("Button", nil, confirm, "UIPanelButtonTemplate")
	confirm.accept:SetSize(120, 22)
	confirm.accept:SetPoint("BOTTOMRIGHT", -CONFIRM_PAD, 14)
	confirm.accept:SetScript("OnClick", function()
		local act = confirm.action
		confirm:Hide()
		if act then act() end
	end)

	confirm.cancel = CreateFrame("Button", nil, confirm, "UIPanelButtonTemplate")
	confirm.cancel:SetSize(90, 22)
	confirm.cancel:SetPoint("RIGHT", confirm.accept, "LEFT", -8, 0)
	confirm.cancel:SetText("Cancel")
	confirm.cancel:SetScript("OnClick", function() confirm:Hide() end)
end

function TT.Confirm(title, body, acceptText, onAccept)
	if not confirm then buildConfirm() end
	confirm.title:SetText(title)
	confirm.body:SetText(body)
	confirm.accept:SetText(acceptText)
	confirm.action = onAccept
	confirm:SetHeight(46 + confirm.body:GetStringHeight() + 14 + 22 + 14)
	confirm:Show()
end

function TT.SkinClose(frame)
	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -2, -2)
	close:SetScript("OnClick", function() frame:Hide() end)
	return close
end
