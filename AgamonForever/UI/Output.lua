local ADDON, TT = ...

local WINDOW_WIDTH = 520
local WINDOW_HEIGHT = 400
local TOP_PADDING = 44

local window, scroll, box
local report = {}

--chat cannot be selected, so anything meant to be pasted back to someone goes in a box you can copy out of
local function build()
	window = CreateFrame("Frame", "AgamonOutput", UIParent)
	window:SetSize(WINDOW_WIDTH, WINDOW_HEIGHT)
	window:SetPoint("CENTER")
	window:SetFrameStrata("DIALOG")
	window:EnableMouse(true)
	window:SetMovable(true)
	window:RegisterForDrag("LeftButton")
	window:SetScript("OnDragStart", window.StartMoving)
	window:SetScript("OnDragStop", window.StopMovingOrSizing)

	TT.SkinPanel(window)
	TT.SkinTitle(window, "Agamon: Forever")
	TT.SkinClose(window)

	local hint = window:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	hint:SetPoint("TOPRIGHT", -32, -18)
	hint:SetText("ctrl+a, ctrl+c")

	scroll = CreateFrame("ScrollFrame", "AgamonOutputScroll", window, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 14, -TOP_PADDING)
	scroll:SetPoint("BOTTOMRIGHT", -32, 14)

	box = CreateFrame("EditBox", nil, scroll)
	box:SetMultiLine(true)
	box:SetAutoFocus(false)
	box:SetFontObject("GameFontHighlightSmall")
	box:SetWidth(WINDOW_WIDTH - 54)
	box:SetScript("OnEscapePressed", function(self) self:ClearFocus() window:Hide() end)
	scroll:SetScrollChild(box)
end

function TT.ShowText(text)
	if not window then build() end
	box:SetText(text or "")
	TT.RegisterEscapeFrame(window)
	window:Show()
	box:SetFocus()
	box:HighlightText()
end

--a diagnostic that dies on the value it is describing is worse than no diagnostic, so nothing unreadable gets through
function TT.Describe(value)
	if issecret and issecret(value) then return "<secret>" end
	if issecretvalue and issecretvalue(value) then return "<secret>" end
	local kind = type(value)
	if kind == "string" or kind == "number" or kind == "boolean" or kind == "nil" then return tostring(value) end
	return "<" .. kind .. ">"
end

--every diagnostic writes through here, so the same text reaches chat and the box you can copy from
function TT.Report(line)
	if not TT.ReadableText(line) then line = "<a secret string>" end
	report[#report + 1] = line
	TT.Print(line)
end

function TT.StartReport()
	report = {}
end

function TT.ShowReport()
	local function strip(text)
		if not TT.ReadableText(text) then return "<a secret string>" end
		return (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", "cp"):gsub("|A.-|a", "cp"))
	end
	local lines = {}
	for index, line in ipairs(report) do lines[index] = strip(line) end
	TT.ShowText(table.concat(lines, "\n"))
end
