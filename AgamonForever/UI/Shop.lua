local ADDON, TT = ...

local WINDOW_WIDTH = 580
local WINDOW_HEIGHT = 480
local TOP_PADDING = 64
local ROW_HEIGHT = 26
local ICON_SIZE = 22
local NAME_LEFT = 36
local UPGRADE_RIGHT = -210
local PRICE_RIGHT = -92
local SEEN_RIGHT = -8
local WORK_BUDGET_MS = 2
local MAX_WORK_UNITS_PER_FRAME = 4

--the column you clicked, and which way a fresh click on it should run: an upgrade reads best first, a price cheapest first
local SORTS = {
	upgrade = { label = "Upgrade", descending = true, of = function(row) return row.upgrade.share end },
	dps = { label = "Damage", descending = true, of = function(row) return row.upgrade.dps end },
	ehp = { label = "Toughness", descending = true, of = function(row) return row.upgrade.ehp end },
	price = { label = "Price", descending = false, of = function(row) return row.price end },
	seen = { label = "Seen", descending = true, of = function(row) return row.seen or 0 end },
	name = { label = "Item", descending = false, of = function(row) return row.name:lower() end },
	profit = { label = "Profit", descending = true, of = function(row) return row.profit end },
	cost = { label = "Reagents", descending = false, of = function(row) return row.cost end },
	sells = { label = "Sells for", descending = true, of = function(row) return row.sells end },
	savings = { label = "Savings", descending = true, of = function(row) return row.savings * row.quantity end },
	vendor = { label = "Vendor", descending = true, of = function(row) return row.vendor end },
}

local function usableNow(row)
	if not row.needs then return true end
	local level = TT.PlayerLevel()
	return not (level and row.needs > level)
end

--two lists share one window, because a row of gear and a row of something you can make are the same four columns
local MODES = {
	upgrades = {
		title = "Upgrades you could buy",
		gather = function(onProgress) return TT.ShoppingRows(onProgress) end,
		cycle = { "upgrade", "dps", "ehp" },
		columns = { "price", "seen" },
		ready = usableNow,
		values = function(entry)
			local level = TT.PlayerLevel()
			local late = entry.needs and level and entry.needs > level
			return TT.ShoppingVerdict(entry.upgrade), TT.Money(entry.price),
				late and ("needs " .. entry.needs) or TT.PriceAge(entry.seen), late
		end,
		count = function(rows, shown)
			local locked = 0
			for _, row in ipairs(rows) do if not usableNow(row) then locked = locked + 1 end end
			local above = locked > 0 and string.format(", %d above your level%s", locked, TT.db.shopReadyOnly and " hidden" or "") or ""
			return string.format("%d upgrades%s", #shown, above), TT.ShoppingSkipped(rows), "nothing remembered would upgrade you"
		end,
	},
	craft = {
		title = "What you can make",
		gather = function(onProgress) return TT.CraftRows(onProgress) end,
		cycle = { "profit" },
		columns = { "cost", "sells" },
		values = function(entry)
			local made = entry.makes and entry.makes > 1 and string.format(" x%d", entry.makes) or ""
			--a reagent nobody has priced makes the profit a ceiling, and a ceiling says so rather than passing as a figure
			return (entry.partial and "up to " or "") .. TT.Money(entry.profit) .. made,
				TT.Money(entry.cost), TT.Money(entry.sells), entry.partial
		end,
		count = function(rows, shown)
			local partial = rows.unpriced and rows.unpriced > 0
				and string.format("%d rest on a reagent never seen at auction", rows.unpriced) or nil
			return string.format("%d you can make", #shown), partial,
				"no recipes priced yet: open a profession once, and browse the auction house"
		end,
	},
	vendor = {
		title = "Items below vendor price",
		gather = function(onProgress) return TT.VendorRows(onProgress) end,
		cycle = { "savings" },
		columns = { "price", "vendor" },
		values = function(entry)
				return string.format("+%s each x%d (+%s total)", TT.Money(entry.savings), entry.quantity,
					TT.Money(entry.savings * entry.quantity)), TT.Money(entry.price), TT.Money(entry.vendor)
		end,
		count = function(rows, shown)
				if #rows == 0 then
					if rows.pending > 0 then
						return "no item vendor values loaded", string.format("%d item prices still loading", rows.pending),
							"run /agf vendor again shortly"
					end
					return "no below-vendor listings", nil, rows.browsed == 0
						and "no auction results or remembered prices" or "nothing in the checked prices is below vendor value"
				end
				local source = rows.remembered and "remembered prices, not confirmed currently listed" or "current auction results"
				local notes = { source }
				if rows.pending > 0 then notes[#notes + 1] = string.format("%d item prices still loading", rows.pending) end
				return string.format("%d vendor deals", #shown), table.concat(notes, ", "), "no below-vendor listings"
		end,
	},
}

local window, scroll, child, footer, locker, rows, sortBy, descending, headers, mode, title, nameHeader, valueHeaders
local progressBar, progressText, gatherWork
local drawn = {}

local function sortRows()
	local sort = SORTS[sortBy]
	table.sort(rows, function(left, right)
		--what you cannot wear yet is not what you are shopping for, so it sits under everything you can, in every sort
		local leftReady = not mode.ready or mode.ready(left)
		local rightReady = not mode.ready or mode.ready(right)
		if leftReady ~= rightReady then return leftReady end
		local a, b = sort.of(left), sort.of(right)
		if a == b then return left.name < right.name end
		if descending then return a > b end
		return a < b
	end)
end

local function shownRows()
	if not mode.ready or not TT.db.shopReadyOnly then return rows end
	local shown = {}
	for _, row in ipairs(rows) do if mode.ready(row) then shown[#shown + 1] = row end end
	return shown
end

local function sortingBy(button)
	for _, key in ipairs(button.cycle) do if key == sortBy then return true end end
	return false
end

local function paintHeaders()
	for _, button in pairs(headers) do
		local active = sortingBy(button)
		local label = SORTS[active and sortBy or button.cycle[1]].label
		button:SetText(active and (label .. (descending and " v" or " ^")) or label)
		local shade = active and TT.skin.gold or TT.skin.metal
		button.caption:SetTextColor(shade[1], shade[2], shade[3])
	end
end

local function rowAt(index)
	if drawn[index] then return drawn[index] end

	local row = CreateFrame("Button", nil, child)
	row:SetSize(WINDOW_WIDTH - 56, ROW_HEIGHT)
	row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)

	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(ICON_SIZE, ICON_SIZE)
	row.icon:SetPoint("LEFT", 4, 0)
	row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

	local function label(anchor, offset, justify)
		local text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		text:SetPoint(anchor, offset, 0)
		text:SetJustifyH(justify)
		return text
	end
	row.name = label("LEFT", NAME_LEFT, "LEFT")
	row.name:SetPoint("RIGHT", row, "RIGHT", UPGRADE_RIGHT - 6, 0)
	row.name:SetWordWrap(false)
	row.upgrade = label("RIGHT", UPGRADE_RIGHT, "RIGHT")
	row.price = label("RIGHT", PRICE_RIGHT, "RIGHT")
	row.seen = label("RIGHT", SEEN_RIGHT, "RIGHT")

	row.highlight = row:CreateTexture(nil, "BACKGROUND")
	row.highlight:SetAllPoints()
	row.highlight:SetColorTexture(TT.skin.gold[1], TT.skin.gold[2], TT.skin.gold[3], 0.12)
	row.highlight:Hide()

	--its own tooltip, so the addon's own block is already on it the way it is anywhere else you hover gear
	row:SetScript("OnEnter", function(self)
		self.highlight:Show()
		if not self.link then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetHyperlink(self.link)
	end)
	row:SetScript("OnLeave", function(self)
		self.highlight:Hide()
		if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
	end)
	row:SetScript("OnClick", function(self)
		if self.link and HandleModifiedItemClick then HandleModifiedItemClick(self.link) end
	end)

	drawn[index] = row
	return row
end

local function fillRow(row, entry)
	row.link = entry.link
	row.icon:SetTexture(entry.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
	row.name:SetText(entry.name)
	local quality = C_Item and C_Item.GetItemQualityColor or GetItemQualityColor
	local red, green, blue = 1, 1, 1
	if entry.quality and quality then red, green, blue = quality(entry.quality) end
	row.name:SetTextColor(red or 1, green or 1, blue or 1)
	local verdict, middle, last, dim = mode.values(entry)
	row.upgrade:SetText(verdict)
	row.upgrade:SetTextColor(TT.skin.gold[1], TT.skin.gold[2], TT.skin.gold[3])
	row.price:SetText(middle)
	row.seen:SetText(last)
	--whatever is standing between you and the row is said in the client's dim shade rather than its plain one
	local shade = dim and TT.skin.goldDim or TT.skin.metal
	row.seen:SetTextColor(shade[1], shade[2], shade[3])
	row:Show()
end

local function refreshRows()
	if not rows then return end
	sortRows()
	paintHeaders()
	local shown = shownRows()
	for index, entry in ipairs(shown) do fillRow(rowAt(index), entry) end
	for index = #shown + 1, #drawn do drawn[index]:Hide() end
	child:SetHeight(math.max(1, #shown * ROW_HEIGHT))

	locker:SetShown(mode.ready ~= nil)
	if mode.ready then locker:SetText(TT.db.shopReadyOnly and "what I can wear" or "every level") end

	local counted, note, empty = mode.count(rows, shown)
	if #shown == 0 then
		footer:SetText(note and (empty .. ", " .. note) or empty)
	else
		footer:SetText(counted .. (note and (", " .. note) or ""))
	end
end

local function gatherProgress(done, total, label)
		progressBar:SetMinMaxValues(0, math.max(total, 1))
		progressBar:SetValue(done)
		progressText:SetText(string.format("%s: %d/%d", label, done, total))
		progressBar:Show()
	end

	local function loadLabel()
		return TT.db.itemScanFast and "Load: Fast" or "Load: Default"
	end

	local function resumeGather()
		if not gatherWork then return end
		local started = debugprofilestop and debugprofilestop()
		local units = 0
		repeat
			local ok, result = coroutine.resume(gatherWork)
			if not ok then
				gatherWork = nil
				window:SetScript("OnUpdate", nil)
				progressBar:Hide()
				progressText:SetText("")
				footer:SetText("Loading failed: " .. tostring(result))
				TT.Print("item list loading failed: " .. tostring(result))
				return
			end
			if coroutine.status(gatherWork) == "dead" then
				rows = result
				gatherWork = nil
				window:SetScript("OnUpdate", nil)
				progressBar:Hide()
				progressText:SetText("")
				refreshRows()
				return
			end
			units = units + 1
			if not TT.db.itemScanFast then
				if not started or not debugprofilestop or debugprofilestop() - started >= WORK_BUDGET_MS then return end
				if units >= MAX_WORK_UNITS_PER_FRAME then return end
			end
		until not gatherWork
	end

local function refresh()
		if gatherWork then gatherWork = nil end
		rows = nil
		progressBar:Hide()
		footer:SetText("Loading item values")
		for _, row in ipairs(drawn) do row:Hide() end
		child:SetHeight(1)
		gatherWork = coroutine.create(function()
			local function onProgress(done, total, label)
				gatherProgress(done, total, label)
				coroutine.yield()
			end
			return mode.gather(onProgress)
		end)
		window:SetScript("OnUpdate", resumeGather)
		resumeGather()
end

local function build()
	window = CreateFrame("Frame", "AgamonShop", UIParent)
	window:SetSize(WINDOW_WIDTH, WINDOW_HEIGHT)
	window:SetPoint("CENTER")
	window:SetFrameStrata("DIALOG")
	window:EnableMouse(true)
	window:SetMovable(true)
	window:RegisterForDrag("LeftButton")
	window:SetScript("OnDragStart", window.StartMoving)
	window:SetScript("OnDragStop", window.StopMovingOrSizing)
	window:SetScript("OnHide", function()
		gatherWork = nil
		window:SetScript("OnUpdate", nil)
	end)
	TT.SkinPanel(window)
	title = TT.SkinTitle(window, mode.title)
	TT.SkinClose(window)

	headers = {}
	local function header(cycle, anchor, offset)
		local button = CreateFrame("Button", nil, window)
		button:SetSize(90, 18)
		button:SetPoint(anchor, offset, -42)
		button.cycle = cycle
		button.caption = button:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
		button.caption:SetPoint(anchor == "TOPLEFT" and "LEFT" or "RIGHT")
		button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		button:SetScript("OnClick", function(self, click)
			--left steps on to the next question this column can answer, right turns the answer round
			if click == "RightButton" and sortingBy(self) then descending = not descending
			else
				local index = 0
				for slot, key in ipairs(self.cycle) do if key == sortBy then index = slot end end
				sortBy = self.cycle[index % #self.cycle + 1]
				descending = SORTS[sortBy].descending
			end
			if rows then refreshRows() end
		end)
		button.SetText = function(self, text) self.caption:SetText(text) end
		headers[#headers + 1] = button
		return button
	end
	nameHeader = header({ "name" }, "TOPLEFT", 14 + NAME_LEFT)
	valueHeaders = {
		header({}, "TOPRIGHT", UPGRADE_RIGHT - 14),
		header({}, "TOPRIGHT", PRICE_RIGHT - 14),
		header({}, "TOPRIGHT", SEEN_RIGHT - 14),
	}

	progressBar = CreateFrame("StatusBar", nil, window)
	progressBar:SetSize(WINDOW_WIDTH - 28, 8)
	progressBar:SetPoint("TOPLEFT", 14, -62)
	progressBar:SetMinMaxValues(0, 1)
	progressBar:SetValue(0)
	progressBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
	progressBar:SetStatusBarColor(TT.skin.gold[1], TT.skin.gold[2], TT.skin.gold[3])
	progressText = window:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	progressText:SetPoint("TOPLEFT", progressBar, "BOTTOMLEFT", 0, -2)
	progressText:SetText("")
	progressBar:Hide()

	scroll = CreateFrame("ScrollFrame", "AgamonShopScroll", window, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 14, -78)
	scroll:SetPoint("BOTTOMRIGHT", -32, 34)
	child = CreateFrame("Frame", nil, scroll)
	child:SetSize(WINDOW_WIDTH - 56, ROW_HEIGHT)
	scroll:SetScrollChild(child)

	footer = window:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	footer:SetPoint("BOTTOMLEFT", 16, 14)

	--up by the title, because the footer already has the counts and the two were drawing over each other
	local hint = window:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	hint:SetPoint("TOPLEFT", 14, -18)
	hint:SetText("click a column to sort, right click to reverse")

	local loadButton = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
	loadButton:SetSize(104, 20)
	loadButton:SetPoint("TOPRIGHT", window, "TOPRIGHT", -34, -18)
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

	locker = CreateFrame("Button", nil, window)
	locker:SetSize(124, 18)
	locker:SetPoint("BOTTOMRIGHT", -14, 10)
	TT.SkinInset(locker)
	locker.caption = locker:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	locker.caption:SetPoint("CENTER")
	locker.SetText = function(self, text)
		self.caption:SetText(text)
		local shade = TT.db.shopReadyOnly and TT.skin.gold or TT.skin.metal
		self.caption:SetTextColor(shade[1], shade[2], shade[3])
	end
	locker:SetScript("OnClick", function()
		TT.db.shopReadyOnly = not TT.db.shopReadyOnly
		if rows then refreshRows() end
	end)
	locker:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
		GameTooltip:AddLine("Gear above your level")
		GameTooltip:AddLine("it always sorts under what you can wear; click to drop it entirely", 0.7, 0.7, 0.7)
		GameTooltip:Show()
	end)
	locker:SetScript("OnLeave", function(self)
		if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
	end)
end

--the columns belong to the list being shown, so switching lists re-points them rather than building a second window
local function applyMode()
	title:SetText(mode.title)
	valueHeaders[1].cycle = mode.cycle
	for index, key in ipairs(mode.columns) do valueHeaders[index + 1].cycle = { key } end
	sortBy = mode.cycle[1]
	descending = SORTS[sortBy].descending
end

--built once and refilled, because pricing everything remembered is the expensive part and a re-sort must not pay it again
function TT.ShowShop(which)
	mode = MODES[which or "upgrades"]
	if not mode then mode = MODES.upgrades end
	if not window then build() end
	applyMode()
	TT.RegisterEscapeFrame(window)
	window:Show()
	refresh()
end

function TT.ShopSort(key, reversed)
	sortBy, descending = key, reversed
	if rows then refreshRows() end
end
