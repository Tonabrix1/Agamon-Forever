local ADDON, TT = ...

local POLL_SECONDS = 0.1

--another addon can hand draw an item tooltip with ClearLines and AddLine, which the data pipeline never hears about,
--so the item is looked for on the button the tooltip belongs to instead
local OWNER_FIELDS = { "itemLink", "link", "itemID", "itemId", "id" }

local attempted

local function fromEntry(owner)
	local entry = owner.entry or owner.item or owner.data
	if type(entry) ~= "table" then return nil end
	local id = entry.itemId or entry.itemID or entry.id
	if type(id) == "number" then return "item:" .. id end
	if type(entry.link) == "string" then return entry.link end
	return nil
end

local function foreignItem(tooltip)
	local _, tooltipLink
	if tooltip.GetItem then _, tooltipLink = tooltip:GetItem() end
	if type(tooltipLink) == "string" and tooltipLink:find("item:", 1, true) then return tooltipLink end
	local owner = tooltip.GetOwner and tooltip:GetOwner()
	if type(owner) ~= "table" and type(owner) ~= "userdata" then return nil end

	for _, method in ipairs({ "GetItemLink", "GetHyperlink" }) do
		if type(owner[method]) == "function" then
			local link = TT.Safely(owner[method], owner)
			if type(link) == "string" and link:find("item:", 1, true) then return link end
		end
	end

	local link = fromEntry(owner)
	if link then return link end

	local frame = owner
	while frame do
		local name = frame.GetName and TT.Safely(frame.GetName, frame)
		if TT.ReadableText(name) and name:lower():find("trainer", 1, true) then
			local index = frame.GetID and TT.ReadableNumber(TT.Safely(frame.GetID, frame))
			local itemLink = index and GetTrainerServiceItemLink and TT.Safely(GetTrainerServiceItemLink, index)
			if TT.ReadableText(itemLink) and itemLink:find("item:", 1, true) then return itemLink end
			break
		end
		frame = frame.GetParent and TT.Safely(frame.GetParent, frame)
	end

	for _, field in ipairs(OWNER_FIELDS) do
		local value = owner[field]
		if type(value) == "string" and value:find("item:", 1, true) then return value end
		if type(value) == "number" and value > 0 then return "item:" .. value end
	end
	return nil
end

local function shownLines(tooltip)
	local name = tooltip:GetName()
	if not name then return {} end
	local lines = {}
	for index = 1, tooltip:NumLines() do
		local left = _G[name .. "TextLeft" .. index]
		if left then TT.SplitText(lines, left:GetText()) end
		local right = _G[name .. "TextRight" .. index]
		if right then TT.SplitText(lines, right:GetText()) end
	end
	return lines
end

local function sameLines(left, right)
	if #left ~= #right then return false end
	for index, line in ipairs(left) do if line ~= right[index] then return false end end
	return true
end

local function adopt(tooltip)
	local link = foreignItem(tooltip)
	if not link then attempted = nil; return end
	local lines = shownLines(tooltip)
	if attempted and attempted.tooltip == tooltip and attempted.link == link and sameLines(attempted.lines, lines) then return end
	attempted = { tooltip = tooltip, link = link, lines = lines }
	TT.NoteItem(link)

	local result = TT.CalcItem(link, lines)
	if not result then return end
	TT.Render(tooltip, result)
end

local frame = CreateFrame("Frame")
local elapsed = 0
frame:SetScript("OnUpdate", function(self, delta)
	elapsed = elapsed + delta
	if elapsed < POLL_SECONDS then return end
	elapsed = 0

	if not TT.db or not TT.db.enabled then attempted = nil; return end

	--the block can be on another addon's own window, which stays up while GameTooltip comes and goes
	local held = TT.HeldTooltip()
	if held then
		if held.IsShown and held:IsShown() then
			TT.ReleaseHeld(held)
			TT.CollapseHeld(held)
		else
			TT.ForgetHeld()
		end
	end

	local tooltip = GameTooltip
	if not tooltip or not tooltip.IsShown or not tooltip:IsShown() then
		attempted = nil
		TT.SetPreview(nil)
		return
	end
	if TT.SkipTooltip(tooltip) then return end

	if TT.Rendered(tooltip) then return end
	if TT.db.showItems then adopt(tooltip) else attempted = nil end
end)
