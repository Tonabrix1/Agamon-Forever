local ADDON, TT = ...

local WINDOW_WIDTH = 760
local WINDOW_HEIGHT = 680
local HEADER_HEIGHT = 22
local ITEM_HEIGHT = 32
local ICON_SIZE = 26
local WORK_BUDGET_MS = 2
local MAX_WORK_UNITS_PER_FRAME = 4
local EQUIPPED_RED, EQUIPPED_GREEN, EQUIPPED_BLUE = 0.1, 1, 0.1
local RANKINGS = {
	{ key = "dps", label = "Max DPS" },
	{ key = "weighted", label = "Weighted DPS / Toughness" },
	{ key = "total", label = "Max Total" },
}

local window, scroll, child, footer, rankingButton, levelButton, advancedButton, loadButton, advanced, message, progressBar, progressText
local dpsWeight, ehpWeight
local headers, rows = {}, {}
local collapsed = {}
local rankingIndex = 1
local refresh
local refreshWork
local displayedRows, displayedSkipped
local refreshReadyOnly
local drawRows

local function currentWeights()
	return TT.db.bisDpsWeight or 70, TT.db.bisEhpWeight or 30
end

local function readyLabel()
	return TT.db.shopReadyOnly and "what I can wear" or "every level"
end

local function loadLabel()
	return TT.db.itemScanFast and "Load: Fast" or "Load: Default"
end

local function setScrollTop()
	scroll:ClearAllPoints()
	scroll:SetPoint("TOPLEFT", window, "TOPLEFT", 18,
		advanced:IsShown() and -198 or progressBar:IsShown() and -166 or -94)
	scroll:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -34, 40)
end

local function ensureHeader(index)
	if headers[index] then return headers[index] end
	local header = CreateFrame("Button", nil, child)
	header:SetSize(WINDOW_WIDTH - 100, HEADER_HEIGHT)
	header.label = header:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	header.label:SetAllPoints()
	header.label:SetTextColor(TT.skin.gold[1], TT.skin.gold[2], TT.skin.gold[3])
	header.label:SetJustifyH("LEFT")
	header:SetScript("OnClick", function(self)
		collapsed[self.slot] = not collapsed[self.slot]
		if displayedRows then drawRows(displayedRows, displayedSkipped) end
	end)
	headers[index] = header
	return header
end

local function ensureRow(index)
	if rows[index] then return rows[index] end
	local row = CreateFrame("Button", nil, child)
	row:SetSize(WINDOW_WIDTH - 72, ITEM_HEIGHT)
	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(ICON_SIZE, ICON_SIZE)
	row.icon:SetPoint("LEFT", 4, 0)
	row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	row.name = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	row.name:SetPoint("LEFT", 36, 0)
	row.name:SetPoint("RIGHT", row, "RIGHT", -250, 0)
	row.name:SetJustifyH("LEFT")
	row.name:SetWordWrap(false)
	row.value = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	row.value:SetPoint("RIGHT", row, "RIGHT", -8, 0)
	row.value:SetWidth(238)
	row.value:SetJustifyH("RIGHT")
	row.value:SetWordWrap(false)
	row.highlight = row:CreateTexture(nil, "BACKGROUND")
	row.highlight:SetAllPoints()
	row.highlight:SetColorTexture(TT.skin.gold[1], TT.skin.gold[2], TT.skin.gold[3], 0.12)
	row.highlight:Hide()
	row.equippedBorder = {}
	for _, edge in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
		local texture = row:CreateTexture(nil, "OVERLAY")
		texture:SetColorTexture(TT.skin.gold[1], TT.skin.gold[2], TT.skin.gold[3], 1)
		if edge == "TOP" then
			texture:SetHeight(2)
			texture:SetPoint("TOPLEFT")
			texture:SetPoint("TOPRIGHT")
		elseif edge == "BOTTOM" then
			texture:SetHeight(2)
			texture:SetPoint("BOTTOMLEFT")
			texture:SetPoint("BOTTOMRIGHT")
		elseif edge == "LEFT" then
			texture:SetWidth(2)
			texture:SetPoint("TOPLEFT")
			texture:SetPoint("BOTTOMLEFT")
		else
			texture:SetWidth(2)
			texture:SetPoint("TOPRIGHT")
			texture:SetPoint("BOTTOMRIGHT")
		end
		texture:Hide()
		row.equippedBorder[#row.equippedBorder + 1] = texture
	end
	row:SetScript("OnEnter", function(self)
		row.highlight:Show()
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetHyperlink(self.link)
	end)
	row:SetScript("OnLeave", function(self)
		row.highlight:Hide()
		if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
	end)
	row:SetScript("OnClick", function(self)
		if HandleModifiedItemClick then HandleModifiedItemClick(self.link) end
	end)
	rows[index] = row
	return row
end

local function valueText(item)
	local upgrade = item.upgrade
	local dps, ehp, suffix
	if rankingIndex == 2 then
		dps, ehp, suffix = upgrade.dps * 100, upgrade.ehp * 100, "%%"
	else
		dps, ehp, suffix = upgrade.dpsGain, upgrade.ehpGain, ""
	end
	local values = {}
	if tonumber(string.format("%.2f", dps)) ~= 0 then values[#values + 1] = string.format("%+.2f" .. suffix .. " DPS", dps) end
	if tonumber(string.format("%.2f", ehp)) ~= 0 then values[#values + 1] = string.format("%+.2f" .. suffix .. " EHP", ehp) end
	return table.concat(values, rankingIndex == 3 and " + " or " | ")
end

drawRows = function(found, skipped)
	local ranking = RANKINGS[rankingIndex]
	rankingButton:SetText(ranking.label)
	levelButton:SetText(readyLabel())
	local rendered, currentSlot, y, groupIndex = 0, nil, 0, 0
	for _, entry in ipairs(found) do
		if currentSlot ~= entry.slot then
			currentSlot, groupIndex = entry.slot, groupIndex + 1
			local header = ensureHeader(groupIndex)
			header:ClearAllPoints()
			header:SetPoint("TOPLEFT", child, "TOPLEFT", 4, -y)
			header.slot = entry.slot
			header.label:SetText((collapsed[entry.slot] and "+ " or "- ") .. entry.slot)
			header:Show()
			y = y + HEADER_HEIGHT
		end
		if not collapsed[entry.slot] then
			rendered = rendered + 1
			local entryItem, row = entry.item, ensureRow(rendered)
			row:ClearAllPoints()
			row:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
			row.link = entryItem.link
			row.icon:SetTexture(entryItem.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
			row.name:SetText(entryItem.name .. (entryItem.needs and (" (req. " .. entryItem.needs .. ")") or ""))
			if entryItem.equipped then
				row.value:SetText("equipped")
				row.value:SetTextColor(EQUIPPED_RED, EQUIPPED_GREEN, EQUIPPED_BLUE)
			else
				row.value:SetText(valueText(entryItem) .. "  " .. entryItem.upgrade.spec)
				row.value:SetTextColor(1, 1, 1)
			end
			local quality = C_Item and C_Item.GetItemQualityColor or GetItemQualityColor
			local red, green, blue = 1, 1, 1
			if entryItem.quality and quality then red, green, blue = quality(entryItem.quality) end
			row.name:SetTextColor(red or 1, green or 1, blue or 1)
			row:SetAlpha(entryItem.dimmed and 0.42 or 1)
			for _, edge in ipairs(row.equippedBorder) do edge:SetShown(entryItem.equipped) end
			row:Show()
			y = y + ITEM_HEIGHT
		end
	end
	for index = groupIndex + 1, #headers do headers[index]:Hide() end
	for index = rendered + 1, #rows do rows[index]:Hide() end
	child:SetHeight(math.max(1, y))
	local notes = {}
	if skipped.unusable > 0 then notes[#notes + 1] = string.format("%d class-ineligible items skipped", skipped.unusable) end
	if skipped.unread > 0 then notes[#notes + 1] = string.format("%d uncached items skipped", skipped.unread) end
	footer:SetText(#found == 0
		and "No priced or equipped items found."
		or string.format("Top %d per slot plus equipped items, from gear you have seen%s",
			3, #notes > 0 and (", " .. table.concat(notes, ", ")) or ""))
end

local function resumeRefresh()
	if not refreshWork then return end
	local started = debugprofilestop and debugprofilestop()
	local units = 0
	repeat
		local ok, found, skipped = coroutine.resume(refreshWork)
		if not ok then
			refreshWork = nil
			window:SetScript("OnUpdate", nil)
			progressBar:Hide()
			progressText:SetText("")
			setScrollTop()
			footer:SetText("Loading failed: " .. tostring(found))
			TT.Print("BIS list loading failed: " .. tostring(found))
			return
		end
		if coroutine.status(refreshWork) == "dead" then
			refreshWork = nil
			window:SetScript("OnUpdate", nil)
			progressBar:Hide()
			progressText:SetText("")
			setScrollTop()
			if refreshReadyOnly ~= TT.db.shopReadyOnly then
				local dps, ehp = currentWeights()
				found, skipped = TT.BisRows(RANKINGS[rankingIndex].key, dps, ehp, TT.db.shopReadyOnly)
			end
			drawRows(found, skipped)
			displayedRows, displayedSkipped = found, skipped
			return
		end
		units = units + 1
		if not TT.db.itemScanFast then
			if not started or not debugprofilestop or debugprofilestop() - started >= WORK_BUDGET_MS then return end
			if units >= MAX_WORK_UNITS_PER_FRAME then return end
		end
	until not refreshWork
end

refresh = function()
	if refreshWork then refreshWork = nil end
	local ranking = RANKINGS[rankingIndex]
	local dps, ehp = currentWeights()
	refreshReadyOnly = TT.db.shopReadyOnly
	rankingButton:SetText(ranking.label)
	levelButton:SetText(readyLabel())
	footer:SetText("Loading known gear values")
	progressBar:Hide()
	setScrollTop()
	for _, row in ipairs(rows) do row:Hide() end
	for _, header in ipairs(headers) do header:Hide() end
	child:SetHeight(1)
	refreshWork = coroutine.create(function()
		local function onProgress(done, total, label)
			progressBar:SetMinMaxValues(0, math.max(total, 1))
			progressBar:SetValue(done)
			progressText:SetText(string.format("%s: %d/%d", label, done, total))
			progressBar:Show()
			setScrollTop()
			coroutine.yield()
		end
		return TT.BisRows(ranking.key, dps, ehp, refreshReadyOnly, onProgress)
	end)
	window:SetScript("OnUpdate", resumeRefresh)
	resumeRefresh()
end

local function build()
	window = CreateFrame("Frame", "AgamonBis", UIParent)
	window:SetSize(WINDOW_WIDTH, WINDOW_HEIGHT)
	window:SetPoint("CENTER")
	window:SetFrameStrata("DIALOG")
	window:EnableMouse(true)
	window:SetMovable(true)
	window:RegisterForDrag("LeftButton")
	window:SetScript("OnDragStart", window.StartMoving)
	window:SetScript("OnDragStop", window.StopMovingOrSizing)
	window:SetScript("OnHide", function()
		refreshWork = nil
		window:SetScript("OnUpdate", nil)
	end)
	TT.SkinPanel(window)
	TT.SkinTitle(window, "Best in Slot")
	TT.SkinClose(window)

	local close = CreateFrame("Button", nil, window, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -2, -2)
	close:SetScript("OnClick", function() window:Hide() end)

	rankingButton = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
	rankingButton:SetSize(190, 24)
	rankingButton:SetPoint("TOPLEFT", 18, -40)
	rankingButton:SetScript("OnClick", function()
		rankingIndex = rankingIndex % #RANKINGS + 1
		refresh()
	end)
	rankingButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
		GameTooltip:AddLine("BIS ranking")
		GameTooltip:AddLine("click to cycle Max DPS, Weighted DPS / Toughness, and Max Total", 0.7, 0.7, 0.7)
		GameTooltip:Show()
	end)
	rankingButton:SetScript("OnLeave", function(self)
		if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
	end)

	loadButton = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
	loadButton:SetSize(104, 24)
	loadButton:SetPoint("TOPRIGHT", window, "TOPRIGHT", -34, -40)
	loadButton:SetText(loadLabel())
	loadButton:SetScript("OnClick", function()
		TT.ToggleItemScanFast()
		loadButton:SetText(loadLabel())
	end)
	loadButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
		GameTooltip:AddLine("List loading speed")
		GameTooltip:AddLine("Fast can briefly freeze the UI to finish item pricing sooner; Default spreads work across frames.", 0.7, 0.7, 0.7)
		GameTooltip:Show()
	end)
	loadButton:SetScript("OnLeave", function(self)
		if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
	end)

	levelButton = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
	levelButton:SetSize(130, 24)
	levelButton:SetPoint("LEFT", rankingButton, "RIGHT", 8, 0)
	levelButton:SetScript("OnClick", function()
		TT.db.shopReadyOnly = not TT.db.shopReadyOnly
		levelButton:SetText(readyLabel())
		if not refreshWork then refresh() end
	end)

	advancedButton = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
	advancedButton:SetSize(92, 24)
	advancedButton:SetPoint("LEFT", levelButton, "RIGHT", 8, 0)
	advancedButton:SetText("Advanced")
	advanced = CreateFrame("Frame", nil, window)
	advanced:SetPoint("TOPLEFT", window, "TOPLEFT", 18, -68)
	advanced:SetSize(WINDOW_WIDTH - 36, 92)
	advanced:Hide()
	local dpsLabel = advanced:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	dpsLabel:SetPoint("LEFT", 0, 12)
	dpsLabel:SetText("DPS weight %")
	dpsWeight = CreateFrame("EditBox", nil, advanced, "InputBoxTemplate")
	dpsWeight:SetSize(44, 20)
	dpsWeight:SetPoint("LEFT", dpsLabel, "RIGHT", 6, 0)
	dpsWeight:SetNumeric(true)
	dpsWeight:SetMaxLetters(3)
	dpsWeight:SetAutoFocus(false)
	local ehpLabel = advanced:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	ehpLabel:SetPoint("LEFT", dpsWeight, "RIGHT", 12, 0)
	ehpLabel:SetText("Toughness weight %")
	ehpWeight = CreateFrame("EditBox", nil, advanced, "InputBoxTemplate")
	ehpWeight:SetSize(44, 20)
	ehpWeight:SetPoint("LEFT", ehpLabel, "RIGHT", 6, 0)
	ehpWeight:SetNumeric(true)
	ehpWeight:SetMaxLetters(3)
	ehpWeight:SetAutoFocus(false)
	local saveWeights = CreateFrame("Button", nil, advanced, "UIPanelButtonTemplate")
	saveWeights:SetSize(58, 22)
	saveWeights:SetPoint("LEFT", ehpWeight, "RIGHT", 8, 0)
	saveWeights:SetText("Apply")
	message = advanced:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	message:SetPoint("TOPLEFT", 0, -50)
	message:SetWidth(WINDOW_WIDTH - 42)
	message:SetJustifyH("LEFT")
	message:SetText("Weights are normalized against your current DPS and EHP before combining.")
	saveWeights:SetScript("OnClick", function()
		local dps, ehp = tonumber(dpsWeight:GetText()), tonumber(ehpWeight:GetText())
		if not dps or not ehp or dps > 100 or ehp > 100 or dps + ehp <= 0 then
			message:SetText("Enter weights from 0 to 100, with at least one above 0.")
			return
		end
		TT.db.bisDpsWeight, TT.db.bisEhpWeight = dps, ehp
		message:SetText("Weights applied.")
		refresh()
	end)
	advancedButton:SetScript("OnClick", function()
		local dps, ehp = currentWeights()
		dpsWeight:SetText(tostring(dps))
		ehpWeight:SetText(tostring(ehp))
		advanced:SetShown(not advanced:IsShown())
		setScrollTop()
	end)

	progressBar = CreateFrame("StatusBar", nil, window)
	progressBar:SetSize(WINDOW_WIDTH - 36, 8)
	progressBar:SetPoint("TOPLEFT", window, "TOPLEFT", 18, -138)
	progressBar:SetMinMaxValues(0, 1)
	progressBar:SetValue(0)
	progressBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
	progressBar:SetStatusBarColor(TT.skin.gold[1], TT.skin.gold[2], TT.skin.gold[3])
	progressText = window:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	progressText:SetPoint("TOPLEFT", progressBar, "BOTTOMLEFT", 0, -2)
	progressText:SetText("")
	progressBar:Hide()

	scroll = CreateFrame("ScrollFrame", "AgamonBisScroll", window, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", window, "TOPLEFT", 18, -94)
	scroll:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -34, 40)
	child = CreateFrame("Frame", nil, scroll)
	child:SetSize(WINDOW_WIDTH - 72, 1)
	scroll:SetScrollChild(child)
	footer = window:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	footer:SetPoint("BOTTOMLEFT", 18, 14)
	footer:SetPoint("BOTTOMRIGHT", -18, 14)
	footer:SetJustifyH("LEFT")
	window:Hide()
end

function TT.ShowBis()
	if not window then build() end
	local dps, ehp = currentWeights()
	dpsWeight:SetText(tostring(dps))
	ehpWeight:SetText(tostring(ehp))
	if TT.PrepareBisRows then TT.PrepareBisRows() end
	refresh()
	TT.RegisterEscapeFrame(window)
	window:Show()
end
