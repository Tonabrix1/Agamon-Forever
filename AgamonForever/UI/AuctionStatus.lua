local ADDON, TT = ...

local PANEL_WIDTH = 300
local PANEL_HEIGHT = 154
local panel, tab, counts, instructions

local function refresh()
	if not panel then return end
	local stored, current, captured = TT.AuctionStatus()
	counts:SetText(string.format("Saved item prices: %d\nCurrent browse results: %d\nUnique items scanned this visit: %d",
		stored, current, captured))
end

local function build(parent)
	panel = CreateFrame("Frame", nil, parent)
	panel:SetSize(PANEL_WIDTH, PANEL_HEIGHT)
	panel:SetPoint("TOPLEFT", parent, "TOPRIGHT", 86, -48)
	panel:SetFrameStrata("DIALOG")
	panel:SetClampedToScreen(true)
	if panel.SetToplevel then panel:SetToplevel(true) end
	TT.SkinPanel(panel)
	panel:Hide()

	local title = TT.SkinTitle(panel, "Agamon: Forever Auction Scan")
	title:SetTextColor(TT.skin.gold[1], TT.skin.gold[2], TT.skin.gold[3])

	counts = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	counts:SetPoint("TOPLEFT", 14, -44)
	counts:SetJustifyH("LEFT")

	instructions = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	instructions:SetPoint("TOPLEFT", counts, "BOTTOMLEFT", 0, -7)
	instructions:SetWidth(PANEL_WIDTH - 28)
	instructions:SetJustifyH("LEFT")
	instructions:SetText("Browse categories or search items normally. Prices are captured automatically when result pages load. Browse more pages and run more searches to expand saved price coverage.")

	tab = CreateFrame("Button", nil, parent)
	tab:SetSize(88, 24)
	tab:SetPoint("TOPLEFT", parent, "TOPRIGHT", -2, -48)
	tab:SetFrameStrata("DIALOG")
	if tab.SetToplevel then tab:SetToplevel(true) end
	TT.SkinPanel(tab)
	local label = tab:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	label:SetPoint("CENTER")
	label:SetText("Agamon: Forever")
	label:SetTextColor(TT.skin.gold[1], TT.skin.gold[2], TT.skin.gold[3])
	tab:SetScript("OnClick", function()
		if panel:IsShown() then panel:Hide() else panel:Show(); refresh() end
	end)
	refresh()
end

function TT.AuctionStatusChanged()
	if panel and panel:IsShown() then refresh() end
end

local frame = CreateFrame("Frame")
TT.OnInit(function()
	for _, event in ipairs({
		"AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED",
		"AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", "AUCTION_HOUSE_BROWSE_RESULTS_ADDED",
		"COMMODITY_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_UPDATED",
	}) do TT.Listen(frame, event) end
end)

frame:SetScript("OnEvent", function(_, event)
	if event == "AUCTION_HOUSE_SHOW" then
		TT.ResetAuctionVisit()
		local parent = AuctionHouseFrame
		if parent then
			if not panel then build(parent) end
			tab:Show()
		end
	elseif event == "AUCTION_HOUSE_CLOSED" then
		if panel then panel:Hide() end
		if tab then tab:Hide() end
	else
		TT.AuctionStatusChanged()
	end
end)
