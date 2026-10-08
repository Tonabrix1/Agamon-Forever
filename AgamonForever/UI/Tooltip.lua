local ADDON, TT = ...

--a dim rule rather than a name: it separates our rows from the client's and is how we recognise our own output
local RULE = "|cff4a4a4a" .. string.rep("-", 28) .. "|r"
local HINT = "hold alt for detail"
local CURRENT = "|cffffffff%s|r"
local BEST = "|cff40ff40%s|r"
--the client's own stat lines, because its grey is the shade it uses for something that does not apply to you
local LABEL = { r = 1, g = 1, b = 1 }
local VALUE = { r = 1, g = 0.82, b = 0 }
local ASIDE = { r = 0.5, g = 0.5, b = 0.5 }
local AUCTION = { r = 0.55, g = 0.82, b = 1 }

local LIMITER_NOTE = {
	cooldown = "on cd",
	swing = "per swing",
	over = "over %.0fs",
}

local NEXT_RANK = "^next rank"
local DOUBLE_LINE_GAP = 12 --the space a double line keeps between a label and its value
local TOOLTIP_PADDING = 20 --the inset the text sits inside, both edges together

local function num(value)
	if value >= 100 then return string.format("%.0f", value) end
	if value >= 10 then return string.format("%.1f", value) end
	return string.format("%.2f", value)
end

--a talent tooltip carries the rank after this one, and valuing it means never letting its numbers into the current rank's
function TT.SplitRanks(lines)
	local split
	for index, line in ipairs(lines) do
		if line:lower():find(NEXT_RANK) then
			split = index
			break
		end
	end
	if not split then return lines end

	local current, later = {}, {}
	for index, line in ipairs(lines) do
		if index < split then current[#current + 1] = line
		elseif index > split then later[#later + 1] = line end
	end
	return current, later
end

local function tooltipLines(tooltip, data)
	local lines = {}
	if data and data.lines then
		for _, line in ipairs(data.lines) do TT.SplitText(lines, line.leftText) end
	end
	if #lines == 0 and tooltip:GetName() then
		for i = 1, tooltip:NumLines() do
			local text = _G[tooltip:GetName() .. "TextLeft" .. i]
			if text then TT.SplitText(lines, text:GetText()) end
		end
	end
	return TT.SplitRanks(lines)
end

--another addon's item tooltip is still an item tooltip; only the comparison panes are left alone
local SKIP = {
	ShoppingTooltip1 = true, ShoppingTooltip2 = true, ShoppingTooltip3 = true,
	ItemRefShoppingTooltip1 = true, ItemRefShoppingTooltip2 = true, ItemRefShoppingTooltip3 = true,
}

local function handled(tooltip)
	if not tooltip or not tooltip.AddDoubleLine or not tooltip.NumLines then return false end
	local name = tooltip.GetName and tooltip:GetName()
	return not (name and SKIP[name])
end

function TT.SkipTooltip(tooltip)
	return false
end

local function alreadyRendered(tooltip)
	local name = tooltip:GetName()
	if not name then return false end
	for index = 1, tooltip:NumLines() do
		local line = _G[name .. "TextLeft" .. index]
		--a nameplate aura hands us secret strings, and comparing one is itself the error
		local text = line and line:GetText()
		if TT.ReadableText(text) and text == RULE then return true end
	end
	return false
end

local function addDouble(tooltip, key, value)
	tooltip:AddDoubleLine(key, value, LABEL.r, LABEL.g, LABEL.b, VALUE.r, VALUE.g, VALUE.b)
end

--everything the player can still ask for is behind alt, so the default block is only the verdict
function TT.Detailed()
	if not IsAltKeyDown then return false end
	return TT.ReadableFlag(IsAltKeyDown()) == true
end

--a stack prices the whole stack; shift asks what one of them is worth, read when the tooltip is built like alt is
function TT.PerItem()
	if not IsShiftKeyDown then return false end
	return TT.ReadableFlag(IsShiftKeyDown()) == true
end

local function rateLabel(result, detailed)
	local stem = result.kind == "heal" and "HPS" or "DPS"
	local notes = {}
	local form = TT.FormLabel(result.forms)
	if form then notes[#notes + 1] = form end
	if detailed then
		local limiter = result.capped and (result.powerName .. "-capped") or LIMITER_NOTE[result.limiter]
		if limiter then notes[#notes + 1] = string.format(limiter, result.refresh) end
	end
	if result.active then notes[#notes + 1] = result.active.points .. " " .. TT.ComboMark() end
	if #notes == 0 then return stem end
	return stem .. " (" .. table.concat(notes, ", ") .. ")"
end

local function castLabel(result)
	local stem = result.kind == "heal" and "Heal" or "Hit"
	if result.cast.instant <= 0 then
		stem = "Ticks"
	elseif result.cast.over > 0 then
		stem = stem .. " + ticks"
	end
	return string.format("%s (%.0f%% crit)", stem, result.crit * 100)
end

--one row per dimension the player controls: combo points, how long a dot ticks, how many targets it lands on
local function rowValues(row)
	local parts = {}
	for _, entry in ipairs(row.entries) do
		local text = entry.key .. ":" .. (entry.text or num(entry.value))
		if entry.best then
			text = string.format(BEST, text)
		elseif entry.current then
			text = string.format(CURRENT, text)
		end
		parts[#parts + 1] = text
	end
	return table.concat(parts, "  ")
end

local ROW_OPTION = { cp = "showCombo", uptime = "showUptime", targets = "showTargets" }

local function put(out, label, value, detail, dim, color)
	out[#out + 1] = { label = label, value = value, detail = detail, dim = dim, color = color }
end

local function rowEntries(out, result)
	for _, row in ipairs(result.rows or {}) do
		local option = ROW_OPTION[row.kind]
		if not option or TT.db[option] then put(out, row.label, rowValues(row), true) end
	end
end

local function spellEntries(out, result)
	local db = TT.db
	local detailed = TT.Detailed()

	--a one-second gcd with no regen cap makes these two lines the same number, so only print one
	if db.showRate and num(result.rate) ~= num(result.critTotal) then
		put(out, rateLabel(result, detailed), num(result.rate))
	end
	if db.showCast then put(out, castLabel(result), num(result.critTotal), true) end

	if result.swing then
		put(out, "Swing", string.format("%.0f-%.0f @ %.1fs", result.swing.low, result.swing.high, result.swing.speed), true)
		if result.offSwing then
			put(out, "Off-hand", string.format("%.0f-%.0f @ %.1fs", result.offSwing.low, result.offSwing.high, result.offSwing.speed), true)
		end
	end

	if result.wrongForm then
		local damage, how = TT.ShiftPenalty(result.forms, result.powerName)
		if damage then
			put(out, "Costs a shift", string.format("-%s dmg", num(damage)))
			put(out, "Which is", how, true)
		end
	end

	--what a point buys here against what a point buys across the fight, so no baseline has to be carried in your head
	if db.showPerResource and result.cost then
		local text = num(result.perResource)
		local _, share = TT.ShareOfAverage(result.powerName, result.perResource)
		if share then text = text .. "  " .. share end
		put(out, "Per " .. result.powerName, text, true)
	end

	rowEntries(out, result)

	if db.showVersus and result.versus and result.versus.ratio ~= 0 then
		put(out, "vs " .. result.versus.name, string.format("%+.0f%%", result.versus.ratio * 100))
	end

	if db.showOOM and result.oomCasts then
		put(out, "Until empty", string.format("%.0f casts / %.0fs", result.oomCasts, result.oomTime))
		if result.oomFull then
			put(out, "From a full pool", string.format("%.0f casts", result.oomFull), true)
		end
	end

	--whether this is the moment to spend, which is the mana you have against the regen a cast throws away
	if result.manaVerdict then
		put(out, "Cast now", result.manaVerdict.text)
		for _, line in ipairs(result.manaVerdict.detail or {}) do put(out, line[1], line[2], true) end
	end

	--what the game's own meter saw, which is an aside next to what the tooltip says it should do
	if db.showLogged and result.spellID and result.rate and result.rate > 0 then
		local seen = TT.Compare(result.spellID, result.rate)
		if seen then
			local sure = seen.confidence > 0 and string.format("%.0f%% sure", seen.confidence * 100) or "this fight only"
			put(out, "Measured (" .. sure .. ")", string.format("%.0f  %+.0f%%", seen.measured, seen.delta * 100), true, true)
		end
	end
end

local function entriesOf(result)
	local out = {}
	if result.kind == "effect" then
		for _, line in ipairs(result.lines) do
			put(out, line[1], line[2], line[3], false, line[4] == "auction" and AUCTION or nil)
		end
		rowEntries(out, result)
	else
		spellEntries(out, result)
	end
	return out
end

--the rank after this one, printed beside the rank you have, so a talent point can be judged without doing the arithmetic
local function pairNext(out, later)
	if not later then return end
	local after = {}
	for _, entry in ipairs(entriesOf(later)) do after[entry.label] = entry.value end
	for _, entry in ipairs(out) do
		local upgraded = after[entry.label]
		if upgraded and upgraded ~= entry.value then entry.value = entry.value .. "  >  " .. upgraded end
	end
end

local function emit(tooltip, entry)
	if entry.color then
		tooltip:AddDoubleLine(entry.label, entry.value,
			entry.color.r, entry.color.g, entry.color.b, entry.color.r, entry.color.g, entry.color.b)
	elseif entry.dim then
		tooltip:AddDoubleLine(entry.label, entry.value, ASIDE.r, ASIDE.g, ASIDE.b, ASIDE.r, ASIDE.g, ASIDE.b)
	else
		addDouble(tooltip, entry.label, entry.value)
	end
end

--what the last render held back, so alt pressed while the tooltip is already up can still open it
local waiting

function TT.ForgetHeld()
	waiting = nil
end

local function lineCount(tooltip)
	return tooltip.NumLines and tooltip:NumLines() or nil
end

--absent is zero, but unreadable is nil: a secret measurement may not be added to anything, so the line it came from is skipped
local function measure(region, method)
	if not region or not region[method] then return 0 end
	return TT.ReadableNumber(region[method](region))
end

local function lineStrings(tooltip, index)
	local name = tooltip.GetName and tooltip:GetName()
	if not name then return nil end
	return _G[name .. "TextLeft" .. index], _G[name .. "TextRight" .. index]
end

--a value too long for a tooltip that is already sized is drawn over its own label, because the value hangs off the far edge.
--only another addon's window is widened: the game's own tooltip lays its border out separately, so setting the width
--moves the right hand values out past the edge of the backdrop rather than making the backdrop bigger
local function widenForLines(tooltip, indices)
	if not tooltip.GetWidth or not tooltip.SetWidth then return end
	if tooltip == GameTooltip then return end
	local widest = 0
	for _, index in ipairs(indices) do
		local left, right = lineStrings(tooltip, index)
		local leftWidth, rightWidth = measure(left, "GetStringWidth"), measure(right, "GetStringWidth")
		if leftWidth and rightWidth then
			local width = leftWidth + rightWidth + DOUBLE_LINE_GAP
			if width > widest then widest = width end
		end
	end
	local current = measure(tooltip, "GetWidth")
	if widest > 0 and current and widest + TOOLTIP_PADDING > current then tooltip:SetWidth(widest + TOOLTIP_PADDING) end
end

local function growForAddedLines(tooltip, previousLines)
	if not previousLines then return end
	if not tooltip.GetName or not tooltip:GetName() or not tooltip.GetHeight or not tooltip.SetHeight then return end
	local addedHeight = 0
	for index = previousLines + 1, tooltip:NumLines() do
		local left, right = lineStrings(tooltip, index)
		addedHeight = addedHeight + math.max(measure(left, "GetHeight") or 0, measure(right, "GetHeight") or 0) + 2
	end
	local height = measure(tooltip, "GetHeight")
	if addedHeight > 0 and height then tooltip:SetHeight(height + addedHeight) end
end

local function addedLineHeight(tooltip, previousLines)
	local height = 0
	for index = previousLines + 1, tooltip:NumLines() do
		local left, right = lineStrings(tooltip, index)
		height = height + math.max(measure(left, "GetHeight") or 0, measure(right, "GetHeight") or 0) + 2
	end
	return height
end

local function heldHeight(tooltip)
	local total = 0
	for _, index in ipairs(waiting.lines) do
		local left, right = lineStrings(tooltip, index)
		total = total + math.max(measure(left, "GetHeight") or 0, measure(right, "GetHeight") or 0) + 2
	end
	return total
end

local function hintHeight(tooltip)
	if not waiting.hintLine then return 0 end
	local left, right = lineStrings(tooltip, waiting.hintLine)
	return math.max(measure(left, "GetHeight") or 0, measure(right, "GetHeight") or 0) + 2
end

local function setHintShown(tooltip, visible)
	if not waiting.hintLine then return end
	local left, right = lineStrings(tooltip, waiting.hintLine)
	if tooltip == GameTooltip and left and left.SetText then
		left:SetText(visible and HINT or "")
		if right and right.SetText then right:SetText("") end
		return
	end
	if left and left[visible and "Show" or "Hide"] then left[visible and "Show" or "Hide"](left) end
	if right and right[visible and "Show" or "Hide"] then right[visible and "Show" or "Hide"](right) end
end

--the rows are hidden rather than erased, so alt pressed again shows those instead of drawing a second copy under them
local function setHeldShown(tooltip, visible)
	for _, index in ipairs(waiting.lines) do
		local left, right = lineStrings(tooltip, index)
		if left then if visible then left:Show() else left:Hide() end end
		if right then if visible then right:Show() else right:Hide() end end
	end
	local delta = heldHeight(tooltip)
	local hint = waiting.hintHeight or hintHeight(tooltip)
	local height = measure(tooltip, "GetHeight")
	if tooltip == GameTooltip and tooltip.Show then
		setHintShown(tooltip, not visible)
		tooltip:Show()
		local expected = height and (height + (visible and delta - hint or -delta + hint)) or nil
		local laidOut = measure(tooltip, "GetHeight")
		if expected and laidOut == height and expected ~= laidOut and tooltip.SetHeight then tooltip:SetHeight(expected) end
		waiting.open = visible
		return
	end
	if delta > 0 and height and tooltip.SetHeight then
		tooltip:SetHeight(height + (visible and delta - hint or -delta + hint))
	end
	setHintShown(tooltip, not visible)
	waiting.open = visible
end

--lines can be added to a tooltip that is already showing, which is how alt works live on a tooltip we did not build
function TT.ReleaseHeld(tooltip)
	if not waiting or waiting.tooltip ~= tooltip or waiting.open or not TT.Detailed() then return end
	if waiting.lines then
		if tooltip:NumLines() ~= waiting.last then return end
		setHeldShown(tooltip, true)
		return
	end
	local previousLines = lineCount(tooltip)
	local previousHeight = measure(tooltip, "GetHeight")
	for _, entry in ipairs(waiting.entries) do emit(tooltip, entry) end
	waiting.open = true
	--a tooltip that cannot count its own lines cannot have ours taken away again either
	if not previousLines then return end
	local lines = {}
	for index = previousLines + 1, tooltip:NumLines() do lines[#lines + 1] = index end
	waiting.lines, waiting.last = lines, tooltip:NumLines()
	local hint = waiting.hintHeight or hintHeight(tooltip)
	waiting.hintHeight = hint
	--a line added to a drawn tooltip is not laid out, so its label runs along under its own value; the client's own
	--tooltip knows how to lay itself out again, and someone else's window has to be fitted by hand instead
	if tooltip == GameTooltip and tooltip.Show then
		setHintShown(tooltip, false)
		tooltip:Show()
		local height = measure(tooltip, "GetHeight")
		local required = previousHeight and (previousHeight + addedLineHeight(tooltip, previousLines) - hint) or nil
		if required and height and required ~= height and tooltip.SetHeight then tooltip:SetHeight(required) end
		return
	end
	growForAddedLines(tooltip, previousLines)
	setHintShown(tooltip, false)
	local height = measure(tooltip, "GetHeight")
	if hint > 0 and height and tooltip.SetHeight then tooltip:SetHeight(height - hint) end
	widenForLines(tooltip, lines)
end

--a tooltip that stays up while you let go of alt has to lose the detail again, since nothing else will redraw it
function TT.CollapseHeld(tooltip)
	if not waiting or not waiting.lines or waiting.tooltip ~= tooltip or not waiting.open or TT.Detailed() then return end
	if tooltip:NumLines() ~= waiting.last then return end
	setHeldShown(tooltip, false)
end

--lines added after a tooltip has drawn itself get no layout pass of their own, so they are fitted by hand
function TT.FitAddedLines(tooltip, previousLines)
	if not previousLines then return end
	growForAddedLines(tooltip, previousLines)
	local lines = {}
	for index = previousLines + 1, lineCount(tooltip) or previousLines do lines[#lines + 1] = index end
	widenForLines(tooltip, lines)
end

--the block can sit on another addon's own window, which stays up while GameTooltip comes and goes
function TT.HeldTooltip()
	return waiting and waiting.tooltip or nil
end

function TT.Rendered(tooltip)
	return alreadyRendered(tooltip)
end

--what the client really answers when asked about a held key, because a shape that is neither true nor 1 reads as not held
function TT.ModifierReport()
	local lines = { "what this client answers about held keys" }
	for _, entry in ipairs({ { "alt", IsAltKeyDown }, { "shift", IsShiftKeyDown }, { "control", IsControlKeyDown } }) do
		local query = entry[2]
		local raw = query and query()
		lines[#lines + 1] = string.format("  %-8s %s (%s) reads as %s", entry[1], TT.Describe(raw),
			issecret and issecret(raw) and "secret" or type(raw), TT.Describe(TT.ReadableFlag(raw)))
	end
	lines[#lines + 1] = "  detail  " .. (TT.Detailed() and "open" or "held back")
	local where = waiting and (waiting.tooltip.GetName and waiting.tooltip:GetName() or "an unnamed tooltip")
	local count = waiting and #(waiting.lines or waiting.entries)
	lines[#lines + 1] = "  rows    " .. (waiting and string.format("%d %s on %s", count, waiting.open and "drawn" or "held back", where) or "nowhere")
	return lines
end

--the last item any tooltip asked us about, because you cannot hover one while typing the command that asks about it
local lastItem

function TT.NoteItem(link)
	if link then lastItem = link end
end

function TT.LastItem()
	return lastItem
end

function TT.Render(tooltip, result)
	local out = entriesOf(result)
	pairNext(out, result.next)

	local detailed = TT.Detailed()
	local shown, held = {}, {}
	for _, entry in ipairs(out) do
		if entry.detail and not detailed then
			held[#held + 1] = entry
		else
			shown[#shown + 1] = entry
		end
	end
	if #shown == 0 then return end

	local first = lineCount(tooltip)
	tooltip:AddLine(RULE)
	local drawn = {}
	for _, entry in ipairs(shown) do
		emit(tooltip, entry)
		if entry.detail and first then drawn[#drawn + 1] = tooltip:NumLines() end
	end
	if #held > 0 then tooltip:AddLine(HINT, ASIDE.r, ASIDE.g, ASIDE.b) end
	if #held > 0 then
		waiting = { tooltip = tooltip, entries = held, hintLine = lineCount(tooltip) }
	elseif #drawn > 0 then
		--alt was already down when this was built, so the rows are drawn and letting go has to take them away again
		waiting = { tooltip = tooltip, entries = held, lines = drawn, last = tooltip:NumLines(), open = true }
	else
		waiting = nil
	end
	tooltip:Show()
	if waiting and waiting.tooltip == tooltip and waiting.hintLine then
		waiting.hintHeight = hintHeight(tooltip)
	end
	--the client sizes a tooltip to its own lines, so someone else's window that will not grow for ours is widened here
	local ours = {}
	for index = (first or 0) + 1, first and tooltip:NumLines() or 0 do ours[#ours + 1] = index end
	widenForLines(tooltip, ours)
end

--a sequence is several casts behind one button, so it is priced as the one action it really is
function TT.RenderChain(tooltip, ids)
	local chain = TT.ChainValue(ids)
	if not chain or chain.damage <= 0 then return end

	local names = {}
	for _, id in ipairs(ids) do
		local info = C_Spell.GetSpellInfo(id)
		names[#names + 1] = info and info.name or tostring(id)
	end

	tooltip:AddLine(" ")
	addDouble(tooltip, "Sequence", table.concat(names, " > "))
	addDouble(tooltip, string.format("All %d over %.1fs", chain.count, chain.time), num(chain.damage))
	if chain.cost > 0 then
		addDouble(tooltip, "Per " .. (chain.power or "point") .. " for the chain", num(chain.damage / chain.cost))
	end
end

--the client fills in the "Next Rank" section after the tooltip post-call has already run, the same way it fills the
--status bar late, so the comparison is read a tick later and added under the client's own text for that rank
local function scheduleNextRank(tooltip, spellID, render)
	if not C_Timer or not C_Timer.After then return end
	local drawn = lineCount(tooltip)
	C_Timer.After(0, function()
		if not tooltip.IsShown or not tooltip:IsShown() then return end
		if lineCount(tooltip) == drawn then return end
		local _, later = tooltipLines(tooltip)
		local result = later and #later > 0 and render(later)
		if not result then return end
		for _, line in ipairs(result.lines) do
			if not line[3] then
				local previousLines = lineCount(tooltip)
				addDouble(tooltip, "Next rank is worth", line[2])
				if tooltip == GameTooltip and tooltip.Show then tooltip:Show()
				else TT.FitAddedLines(tooltip, previousLines) end
				return
			end
		end
	end)
end

--the same path the current rank took, run over the next rank's own block of text
local function nextRank(spellID, later)
	if not later or #later == 0 then return nil end
	local scan = TT.Parse(later)
	if scan then return (TT.Calc(spellID, scan)) end
	if not TT.db.showEffects then return nil end
	local effect = TT.ParseEffect(later)
	return effect and (TT.CalcEffect(spellID, effect)) or nil
end

--another addon builds its tooltip with SetHyperlink, where GetItem has nothing to say, so the data itself is asked first
local function itemLink(tooltip, data)
	if data and TT.ReadableText(data.hyperlink) then return data.hyperlink end
	if tooltip.GetItem then
		local _, link = tooltip:GetItem()
		if link then return link end
	end
	if data and type(data.id) == "number" then return "item:" .. data.id end
	return nil
end

--only an item's displayed stack count is a stack size; GetItemCount can be an inventory or profession quantity
local function stackCount(tooltip)
	local owner = tooltip.GetOwner and tooltip:GetOwner()
	if not owner then return nil end
	local shown = owner.count or owner.Count
	if (type(shown) == "table" or type(shown) == "userdata") and shown.GetText then
		local text = shown:GetText()
		local count = TT.ReadableText(text) and tonumber(text)
		return count and count > 1 and count or nil
	end
	local count = TT.ReadableNumber(shown)
	return count and count > 1 and count or nil
end

local function onTooltip(tooltip, data)
	if not TT.db or not TT.db.enabled then return end
	if TT.SkipTooltip(tooltip) then return end
	if not handled(tooltip) then return end
	if alreadyRendered(tooltip) then return end
	--a preview belongs to the thing you are hovering, so anything else you hover takes it away again
	if TT.SetPreview then TT.SetPreview(nil) end

	if data and data.type == Enum.TooltipDataType.Item then
		if not TT.db.showItems then return end
		local link = itemLink(tooltip, data)
		TT.NoteItem(link)
		local lines = tooltipLines(tooltip, data)
		local result = link and TT.CalcItem(link, lines, stackCount(tooltip))
		if result then
			TT.Render(tooltip, result)
		end
		return
	end

	if data and data.type == Enum.TooltipDataType.Unit then
		if not TT.db.showUnits then return end
		local _, unit = tooltip:GetUnit()
		local readableUnit = TT.ReadableText(unit)
		if readableUnit and TT.ScheduleNameplateRead then TT.ScheduleNameplateRead(unit) end
		local lines = tooltipLines(tooltip, data)
		local result = readableUnit and TT.CalcUnit(unit, lines)
		if result then
			TT.Render(tooltip, result)
		end
		return
	end

	local spellID = TT.ResolveSpell(tooltip, data)
	local lines, later = tooltipLines(tooltip, data)
	if TT.db.debug then TT.Dump(spellID, lines, data, tooltip) end
	if not spellID then return end

	if TT.IsAutoAttack(spellID) then
		local melee = TT.Melee()
		if melee then TT.Render(tooltip, melee) end
		return
	end

	local scan = TT.Parse(lines)
	local result, why
	if scan then
		result, why = TT.Calc(spellID, scan)
	else
		if not TT.db.showEffects then return end
		local effect = TT.ParseEffect(lines)
		if not effect then
			if TT.db.debug then TT.Print("nothing to parse") end
			return
		end
		result, why = TT.CalcEffect(spellID, effect)
	end
	if not result then
		if TT.db.debug and why then TT.Print("calc skipped: " .. why) end
		return
	end

	result.next = nextRank(spellID, later)
	TT.Render(tooltip, result)
	--only when the client had not printed that section yet, or the comparison is already on the line above
	if not result.next then
		scheduleNextRank(tooltip, spellID, function(lines) return nextRank(spellID, lines) end)
	end

	if TT.db.showChain then
		local chain = TT.MacroChain(tooltip, data)
		if chain then TT.RenderChain(tooltip, chain) end
	end
end

--registered per type rather than for everything, so the addon never runs inside tooltip flows it has no business in
local function register()
	local types = Enum.TooltipDataType
	local wanted = { types.Spell, types.Item }
	--a macro button's tooltip arrives as its own type, not as the spell it resolves to
	if types.Macro then wanted[#wanted + 1] = types.Macro end
	if types.UnitAura then wanted[#wanted + 1] = types.UnitAura end
	if TT.db and TT.db.showUnits then wanted[#wanted + 1] = types.Unit end

	for _, kind in ipairs(wanted) do
		if kind then TooltipDataProcessor.AddTooltipPostCall(kind, onTooltip) end
	end
end

TT.OnInit(register)
