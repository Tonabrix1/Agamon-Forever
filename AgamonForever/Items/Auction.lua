local ADDON, TT = ...

local EVENTS = {
	"AUCTION_HOUSE_BROWSE_RESULTS_UPDATED",
	"AUCTION_HOUSE_BROWSE_RESULTS_ADDED",
	"COMMODITY_SEARCH_RESULTS_UPDATED",
	"ITEM_SEARCH_RESULTS_UPDATED",
}

local DAY = 24 * 60 * 60
local PRICE_HALF_LIFE = 10 * DAY --how fast a sighting stops counting, so today outranks an equal price from last month
local VENDOR_CACHE_VERSION = 2
local VENDOR_CACHE_LIMIT = 8
local capturedThisVisit = {}
local currentBrowseCount = 0
local vendorRowsCache, vendorRowsOrder
--the client's own coin art, sized to sit on a tooltip line
local COIN = {
	gold = "|TInterface\\MoneyFrame\\UI-GoldIcon:12:12:2:0|t",
	silver = "|TInterface\\MoneyFrame\\UI-SilverIcon:12:12:2:0|t",
	copper = "|TInterface\\MoneyFrame\\UI-CopperIcon:12:12:2:0|t",
}

local function store()
	if not TT.auctionDB then
		TT.auctionDB = AgamonForeverAuctionDB or TT.db and TT.db.prices or {}
		AgamonForeverAuctionDB = TT.auctionDB
	end
	return TT.auctionDB
end

local function savedVendorRows()
	local saved = TT.char and TT.char.vendorRows
	if vendorRowsCache then return vendorRowsCache, vendorRowsOrder end
	if saved and saved.version == VENDOR_CACHE_VERSION and type(saved.entries) == "table" then
		vendorRowsCache = saved.entries
		vendorRowsOrder = type(saved.order) == "table" and saved.order or {}
	elseif saved and saved.version == 1 and type(saved.key) == "string" and type(saved.deals) == "table"
		and saved.pending == 0 then
		vendorRowsCache = {
			[saved.key] = {
				deals = saved.deals, pending = saved.pending,
				browsed = saved.browsed, remembered = saved.remembered,
			},
		}
		vendorRowsOrder = { saved.key }
	else
		vendorRowsCache, vendorRowsOrder = {}, {}
	end
	if TT.char then TT.char.vendorRows = { version = VENDOR_CACHE_VERSION, entries = vendorRowsCache, order = vendorRowsOrder } end
	return vendorRowsCache, vendorRowsOrder
end

local function rememberVendorRows(key, rows)
	local entries, order = savedVendorRows()
	entries[key] = rows
	for index = #order, 1, -1 do if order[index] == key then table.remove(order, index) end end
	order[#order + 1] = key
	while #order > VENDOR_CACHE_LIMIT do entries[table.remove(order, 1)] = nil end
	if TT.char then TT.char.vendorRows = { version = VENDOR_CACHE_VERSION, entries = entries, order = order } end
end

local function remember(itemID, price)
	local prices = store()
	if not prices or not itemID or not price or price <= 0 then return end
	prices[itemID] = { price = price, seen = time() }
end

--the browse list is one row per item with the cheapest of them, which is the number a seller cares about
local function fromBrowse()
	if not C_AuctionHouse or not C_AuctionHouse.GetBrowseResults then return 0 end
	local found, current, lowest = 0, 0, {}
	for _, result in ipairs(C_AuctionHouse.GetBrowseResults() or {}) do
		local itemID = result.itemKey and TT.ReadableNumber(result.itemKey.itemID)
		local price = TT.ReadableNumber(result.minPrice)
		if itemID and price and price > 0 then
			lowest[itemID] = lowest[itemID] and math.min(lowest[itemID], price) or price
			capturedThisVisit[itemID] = true
			found = found + 1
		end
		if itemID then current = current + 1 end
	end
	for itemID, price in pairs(lowest) do remember(itemID, price) end
	currentBrowseCount = current
	return found
end

local function fromCommodity(itemID)
	itemID = TT.ReadableNumber(itemID)
	if not itemID then return end
	if not C_AuctionHouse or not C_AuctionHouse.GetCommoditySearchResultInfo then return end
	local result = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, 1)
	local price = result and TT.ReadableNumber(result.unitPrice)
	if price then
		remember(itemID, price)
		capturedThisVisit[itemID] = true
	end
end

local function fromItem(itemKey)
	local itemID = itemKey and TT.ReadableNumber(itemKey.itemID)
	if not itemID then return end
	if not C_AuctionHouse or not C_AuctionHouse.GetItemSearchResultInfo then return end
	local count = C_AuctionHouse.GetNumItemSearchResults
		and TT.ReadableNumber(TT.Safely(C_AuctionHouse.GetNumItemSearchResults, itemKey)) or 1
	local price
	for index = 1, count do
		local result = TT.Safely(C_AuctionHouse.GetItemSearchResultInfo, itemKey, index)
		if type(result) == "table" then
			local listing = TT.ReadableNumber(result.buyoutAmount)
			if not listing then listing = TT.ReadableNumber(result.bidAmount) end
			if listing and (not price or listing < price) then price = listing end
		end
	end
	if price then
		remember(itemID, price)
		capturedThisVisit[itemID] = true
	end
end

function TT.AuctionPrice(itemID)
	local prices = store()
	local entry = prices and itemID and prices[itemID]
	if not entry then return nil end
	return entry.price, entry.seen
end

--every price the addon has seen, for anything that shops the whole memory rather than asking about one item
function TT.KnownPrices()
	local out = {}
	for itemID, entry in pairs(store() or {}) do
		if entry.price and entry.price > 0 then out[#out + 1] = { id = itemID, price = entry.price, seen = entry.seen } end
	end
	return out
end

function TT.AuctionStatus()
	local stored = #TT.KnownPrices()
	local current, browse = 0, C_AuctionHouse and C_AuctionHouse.GetBrowseResults
	and C_AuctionHouse.GetBrowseResults()
	if type(browse) == "table" then
	local unique = {}
	for _, result in ipairs(browse) do
		local itemID = result.itemKey and TT.ReadableNumber(result.itemKey.itemID)
		if itemID then unique[itemID] = true end
	end
	for _ in pairs(unique) do current = current + 1 end
	else
	current = currentBrowseCount
	end
	local captured = 0
	for _ in pairs(capturedThisVisit) do captured = captured + 1 end
	return stored, current, captured
end

function TT.ResetAuctionVisit()
	capturedThisVisit, currentBrowseCount = {}, 0
end

function TT.VendorDeals(onProgress)
	if not C_Item or not C_Item.GetItemInfo then return nil, "item vendor data are not available" end
	local results = C_AuctionHouse and C_AuctionHouse.GetBrowseResults and C_AuctionHouse.GetBrowseResults() or {}
	local remembered = #results == 0
	local candidates = {}
	if remembered then
		for _, entry in ipairs(TT.KnownPrices()) do
			candidates[#candidates + 1] = {
				itemID = entry.id, price = entry.price, seen = entry.seen, quantity = 1,
			}
		end
	else
		for _, result in ipairs(results) do
			local itemID = result.itemKey and TT.ReadableNumber(result.itemKey.itemID)
			local price = TT.ReadableNumber(result.minPrice)
			if itemID and price and price >= 0 then
				candidates[#candidates + 1] = {
					itemID = itemID, price = price,
					quantity = TT.ReadableNumber(result.totalQuantity) or 1,
				}
			end
		end
	end
	local candidateKeys = {}
	for _, candidate in ipairs(candidates) do
		candidateKeys[#candidateKeys + 1] = table.concat({
			tostring(candidate.itemID), tostring(candidate.price), tostring(candidate.quantity),
		}, "=")
	end
	table.sort(candidateKeys)
	local key = (remembered and "remembered|" or "browse|") .. table.concat(candidateKeys, "|")
	local entries = savedVendorRows()
	local cached = entries[key]
	if cached then return cached.deals, cached.pending, cached.browsed, cached.remembered end
	local deals, pending = {}, 0
	if onProgress then onProgress(0, #candidates, "Checking auction prices") end
	for index, candidate in ipairs(candidates) do
		local itemID, price = candidate.itemID, candidate.price
		if itemID and price and price >= 0 then
			local name, link, quality, vendor
			if TT.ItemVendorInfo then name, link, quality, vendor = TT.ItemVendorInfo(itemID)
			else name, link, quality, _, _, _, _, _, _, _, vendor = C_Item.GetItemInfo(itemID) end
			vendor = TT.ReadableNumber(vendor)
			if vendor then
				if vendor > price then
					local icon = TT.ItemIcon and TT.ItemIcon(itemID)
					if C_Item.GetItemInfoInstant then
						if not TT.ItemIcon then
							local _, _, _, _, itemIcon = C_Item.GetItemInfoInstant(itemID)
							icon = itemIcon
						end
					end
					deals[#deals + 1] = {
						id = itemID,
						link = TT.ReadableText(link) and link or ("item:" .. itemID),
						name = TT.ReadableText(name) and name or ("Item " .. itemID),
						icon = icon,
						quality = TT.ReadableNumber(quality),
						price = price,
						vendor = vendor,
						savings = vendor - price,
						quantity = candidate.quantity,
						seen = candidate.seen,
					}
				end
			else
				pending = pending + 1
				if C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(itemID) end
			end
		end
		if onProgress then onProgress(index, #candidates, "Checking auction prices") end
	end
	table.sort(deals, function(left, right)
		local leftTotal, rightTotal = left.savings * left.quantity, right.savings * right.quantity
		if leftTotal == rightTotal then return left.name < right.name end
		return leftTotal > rightTotal
	end)
	if pending == 0 then
		rememberVendorRows(key, { deals = deals, pending = pending, browsed = #candidates, remembered = remembered })
	end
	return deals, pending, #candidates, remembered
end

function TT.VendorRows(onProgress)
	local deals, pending, browsed, remembered = TT.VendorDeals(onProgress)
	if not deals then return { pending = 0, browsed = 0 } end
	deals.pending, deals.browsed, deals.remembered = pending, browsed, remembered
	return deals
end

--an item seen once and never again may be long gone, so an old sighting counts for less rather than being trusted equally
function TT.PriceWeight(seen)
	if not seen then return 0 end
	return 0.5 ^ (math.max(0, time() - seen) / PRICE_HALF_LIFE)
end

--"two days ago" says whether to trust it; an exact timestamp does not
function TT.PriceAge(seen)
	if not seen then return "never" end
	local days = (time() - seen) / DAY
	if days < 1 then return "today" end
	if days < 2 then return "yesterday" end
	return string.format("%.0f days ago", days)
end

--whole numbers are grouped before they are shown
function TT.FormatNumber(value)
	local text = string.format("%.0f", value)
	local replacements
	repeat text, replacements = text:gsub("^(-?%d+)(%d%d%d)", "%1,%2") until replacements == 0
	return text
end

--the client's own coin art, and only the denominations that are actually part of the number
function TT.Money(copper)
	if not copper then return "?" end
	copper = math.floor(copper + 0.5)
	local sign = copper < 0 and "-" or ""
	copper = math.abs(copper)
	local parts = {}
	local gold = math.floor(copper / 10000)
	local silver = math.floor((copper % 10000) / 100)
	local copperOnly = copper % 100
	if gold > 0 then parts[#parts + 1] = TT.FormatNumber(gold) .. COIN.gold end
	if silver > 0 then parts[#parts + 1] = silver .. COIN.silver end
	--nothing at all still has to read as a price, so zero keeps its copper
	if copperOnly > 0 or #parts == 0 then parts[#parts + 1] = copperOnly .. COIN.copper end
	return sign .. table.concat(parts, " ")
end

--what the client actually offers here, since an auction api that is not there looks the same as one that saw nothing
function TT.AuctionReport()
	local lines = {}
	local prices = store() or {}
	local count = 0
	for _ in pairs(prices) do count = count + 1 end
	lines[#lines + 1] = "C_AuctionHouse: " .. tostring(C_AuctionHouse ~= nil)
	for _, name in ipairs({ "GetBrowseResults", "GetCommoditySearchResultInfo", "GetItemSearchResultInfo" }) do
		lines[#lines + 1] = string.format("  %s: %s", name, tostring(C_AuctionHouse and C_AuctionHouse[name] ~= nil))
	end
	lines[#lines + 1] = "items remembered: " .. count
	for event in pairs(TT.db.refusedEvents or {}) do
		lines[#lines + 1] = "refused: " .. event
	end
	return lines
end

local frame = CreateFrame("Frame")
TT.OnInit(function()
	for _, event in ipairs(EVENTS) do TT.Listen(frame, event) end
end)

frame:SetScript("OnEvent", function(self, event, arg)
	if event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
		fromCommodity(arg)
	elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
		fromItem(arg)
	else
		fromBrowse()
	end
	if TT.AuctionStatusChanged then TT.AuctionStatusChanged() end
end)
