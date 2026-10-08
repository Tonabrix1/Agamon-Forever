local ADDON, TT = ...

local COMBO_ATLAS = "ClassOverlay-ComboPoint"
local COMBO_TEXTURE = "Interface\\ComboFrame\\ComboPoint"

local DEFAULTS = {
	enabled = true,
	showRate = true,
	showCast = true,
	showPerResource = true,
	showVersus = true,
	showOOM = true,
	showCombo = true,
	showUptime = true,
	showTargets = true,
	showEffects = true,
	showItems = true,
	showUnits = true,
	panelOpen = false,
	manaBar = false,
	compact = false,
	shopReadyOnly = false, --gear above your level sorts under what you can wear rather than being hidden by default
	itemScanFast = false,
	bisDpsWeight = 70,
	bisEhpWeight = 30,
	targets = 1,
	autoTargets = true,
	bleedImmune = {}, --nothing is assumed immune, each type is added once it has been seen refusing a bleed
	minimapAngle = 200,
	showMinimap = true,
	comboIcon = true,
	showResourceValue = true,
	extraSpecs = {},
	showLogged = true,
	showConfidence = true,
	showChain = true,
	debug = false,
	critMultiplier = 2.0,
	healCritMultiplier = 1.5,
	label = "Agamon: Forever",
}

TT.name = ADDON

local initializers = {}

--modules register their events here instead of at load, because the refused list lives in saved variables
function TT.OnInit(fn)
	initializers[#initializers + 1] = fn
end

--this client forbids addons some events outright, and the attempt itself is what raises the popup,
--so a refusal is recorded once and never tried again
function TT.Listen(frame, event)
	local refused = TT.db and TT.db.refusedEvents
	if refused and refused[event] then return false end

	if C_EventUtils and C_EventUtils.IsEventValid and not C_EventUtils.IsEventValid(event) then
		if refused then refused[event] = true end
		return false
	end

	frame:RegisterEvent(event)
	if frame.IsEventRegistered and not frame:IsEventRegistered(event) then
		if refused then refused[event] = true end
		TT.Print("|cffff5555" .. event .. "|r is not allowed for addons here, so that part is off")
		return false
	end
	return true
end

local SETTINGS_VERSION = 4

local function migrate(db)
	if (db.version or 0) < 3 then
		db.trackLog, db.logMinHits = nil, nil
	end
	if (db.version or 0) < 4 and db.refusedEvents then db.refusedEvents.PLAYER_FORM_CHANGED = nil end
	db.version = SETTINGS_VERSION
end

local function applyDefaults(db)
	for k, v in pairs(DEFAULTS) do
		if db[k] == nil then db[k] = v end
	end
	db.showCrit, db.showCycle, db.showSustain = nil, nil, nil
	return db
end

function TT.Print(msg)
	print("|cff33ff99" .. ADDON .. "|r: " .. msg)
end

local lastDump

--names the tooltip data type back, since which type a thing arrives as is what decides whether we ever run on it
local function typeName(kind)
	if not kind then return "none" end
	for name, value in pairs(Enum.TooltipDataType or {}) do
		if value == kind then return name .. "(" .. kind .. ")" end
	end
	return tostring(kind)
end

function TT.Dump(spellID, lines, data, tooltip)
	local payload = tostring(spellID) .. "|" .. table.concat(lines, "|")
	if payload == lastDump then return end
	lastDump = payload

	local owner = tooltip and tooltip.GetOwner and tooltip:GetOwner()
	local ownerName = owner and ((owner.GetName and owner:GetName()) or "unnamed frame") or "no owner"
	local slot = owner and owner.action
	TT.Print(string.format("spellID %s, type %s, owner %s, slot %s, %d lines",
		tostring(spellID), typeName(data and data.type), ownerName, tostring(slot), #lines))
	for i, line in ipairs(lines) do
		print(string.format("  |cff888888%d|r %s", i, line))
	end
end

--some spell tooltips come back as secret strings to tainted code, and comparing one is itself the error
function TT.ReadableText(text)
	if issecret and issecret(text) then return false end
	if issecretvalue and issecretvalue(text) then return false end
	return type(text) == "string"
end

--tooltip text arrives with newlines inside single lines, so every reader splits through here
function TT.SplitText(lines, text)
	if not TT.ReadableText(text) then return false end
	if text == "" then return true end
	if not text:find("\n", 1, true) then
		lines[#lines + 1] = text
		return true
	end
	for piece in text:gmatch("[^\r\n]+") do lines[#lines + 1] = piece end
	return true
end

local comboMark

--the game's own pip, falling back to the classic texture and then to words if neither is in this client
function TT.ComboMark()
	if TT.db and TT.db.comboIcon == false then return "cp" end
	if comboMark then return comboMark end
	if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(COMBO_ATLAS) then
		comboMark = "|A:" .. COMBO_ATLAS .. ":12:12|a"
	else
		comboMark = "|T" .. COMBO_TEXTURE .. ":12:12:0:0:32:32:4:28:4:28|t"
	end
	return comboMark
end

local function toggle(key, name)
	TT.db[key] = not TT.db[key]
	TT.Print(name .. " = " .. (TT.db[key] and "on" or "off"))
end

local COMMAND_HELP = {
	"/agf [options]: open Agamon: Forever settings",
	"/agf off or /agf toggle: turn addon tooltip features off or on",
	"/agf safe: disable unit, panel, item, and effect features; reload to fully detach enemy tooltips",
	"/agf rank: rank scanned abilities by damage per resource and show spender breakpoints",
	"/agf rotation: show the simulated rotation, opener, loop, and ability priority",
	"/agf bars: report action-bar spells and whether each one parsed",
	"/agf meter or /agf tune: compare the game's measured damage rates with addon estimates",
	"/agf mana: toggle the mana bar shown while in Cat, Bear, or Dire Bear Form",
	"/agf hp [unit]: report health and estimated time to kill for your target or another unit",
	"/agf bleed [type]: toggle bleed immunity for the target's creature type or a named type",
	"/agf gcd <seconds|reset>: set a custom global cooldown estimate or restore the default",
	"/agf why: explain which abilities were accepted or rejected by the scanner",
	"/agf plate [unit]: report what the addon can read from a nameplate",
	"/agf alt: report modifier-key item and tooltip actions",
	"/agf items: open item upgrades; add 'text' to print the shopping list",
	"/agf bis: show the top three known gear items per slot by DPS, weighted DPS/toughness, or combined DPS + EHP",
	"/agf vendor: open an item list of known auction prices below vendor value; saved sightings are labeled as remembered",
	"/agf craft: open the crafting view",
	"/agf item [name or link]: report an item's stats and estimated value",
	"/agf auction: report auction data used by item and crafting estimates",
	"/agf minimap: show or hide the minimap button",
	"/agf compact: toggle the compact rotation panel layout",
	"/agf panel: show the rotation panel and print its current status",
	"/agf copy: reopen the latest addon report",
	"/agf macro: report macros found on scanned action-bar slots",
	"/agf blocked: list events refused by the client and recent blocked addon actions",
	"/agf forget: clear saved bests, kill times, measured rates, and remembered gear for this character",
	"/agf simulate or /agf sim: open Simulation Explorer",
	"/agf help: show this command guide",
}

SLASH_AGAMONFOREVER1 = "/agf"
SLASH_AGAMONFOREVER2 = "/agamon"
SlashCmdList.AGAMONFOREVER = function(msg)
	--the argument keeps its case, because lowercasing an item link breaks the |H that makes it a link
	local cmd, arg = msg:match("^(%S*)%s*(.-)$")
	cmd = cmd:lower()
	if cmd == "help" then
		for _, line in ipairs(COMMAND_HELP) do TT.Print(line) end
	elseif cmd == "" or cmd == "options" then
		TT.ToggleOptions()
	elseif cmd == "off" or cmd == "toggle" then
		toggle("enabled", "addon")
	elseif cmd == "rank" then
		local entries, filler = TT.Efficiency()
		if not entries then
			TT.Print(filler or "nothing to rank")
		else
			TT.Print("damage per resource" .. (filler and (", filler is " .. filler) or ""))
			for index, entry in ipairs(entries) do
				local note = entry.spender and (entry.breakpoint and (" spend at " .. entry.breakpoint .. " " .. TT.ComboMark()) or " never beats your filler") or ""
				TT.Print(string.format("  %d. %-18s %.2f per %s%s", index, entry.name, entry.value, entry.power or "point", note))
			end
		end
	elseif cmd == "rotation" then
		local result, why = TT.Rotation()
		if not result then
			TT.Print(why or "no rotation")
		else
			TT.Print(string.format("%.0f dps from %d abilities (%s)", result.dps, result.count, result.model))
			local function strip(runs)
				local steps = {}
				for _, run in ipairs(runs or {}) do
					steps[#steps + 1] = (run.count > 1 and (run.count .. "x ") or "") .. run.name .. (run.points and (" at " .. run.points .. " " .. TT.ComboMark()) or "")
				end
				return table.concat(steps, " > ")
			end
			local opener = strip(result.opener)
			if opener ~= "" then TT.Print("  opener: " .. opener) end
			local loop = strip(result.loop or result.sequence)
			if loop ~= "" then TT.Print(string.format("  loop (%.1fs): %s", result.loopTime or 0, loop)) end
			for index, entry in ipairs(result.priority) do TT.Print("  " .. index .. ". " .. entry) end
		end
	elseif cmd == "bars" then
		TT.StartReport()
		for _, line in ipairs(TT.ActionReport()) do TT.Report(line) end
		TT.ShowReport()
	elseif cmd == "meter" or cmd == "tune" then
		TT.StartReport()
		if not TT.MeterAvailable() then
			TT.Report("this client has no damage meter api for addons to read")
		else
			local rows = TT.MeterSummary()
			if #rows == 0 then
				TT.Report("the meter has nothing for you yet, pull something")
			else
				TT.Report("what the game's meter measured")
				for _, row in ipairs(rows) do
					TT.Report(string.format("  %-18s %.0f per second, %.0f%% sure", row.name, row.rate, row.confidence * 100))
				end
			end
		end
	elseif cmd == "mana" then
		TT.ToggleManaBar()
	elseif cmd == "hp" then
		TT.StartReport()
		for _, line in ipairs(TT.HealthReport(arg ~= "" and arg or nil)) do TT.Report(line) end
		TT.ShowReport()
	elseif cmd == "bleed" then
		local _, kind = TT.BleedImmune(nil, "target")
		local pick = arg ~= "" and arg:lower() or kind
		if pick then
			TT.db.bleedImmune[pick] = not TT.db.bleedImmune[pick] or nil
			TT.InvalidateRotation()
			TT.Print(pick .. (TT.db.bleedImmune[pick] and " now counts as immune to bleeds" or " no longer counts as immune"))
		else
			TT.Print("target something, or name a creature type, to mark it immune to bleeds")
		end
		local marked = {}
		for name in pairs(TT.db.bleedImmune) do marked[#marked + 1] = name end
		table.sort(marked)
		TT.Print("bleeds are skipped on: " .. (#marked > 0 and table.concat(marked, ", ") or "nothing yet")
			.. (kind and (" / this target is " .. kind) or ""))
	elseif cmd == "gcd" then
		local seconds = tonumber(arg)
		if seconds and seconds > 0 then
			TT.db.gcd = seconds
			TT.InvalidateRotation()
		elseif arg == "reset" then
			TT.db.gcd = nil
			TT.InvalidateRotation()
		end
		TT.Print(string.format("global cooldown %.2fs (%s), every cadence and per-resource figure rides on it",
			TT.Gcd(), TT.db.gcd and "yours" or "assumed vanilla"))
	elseif cmd == "why" then
		TT.StartReport()
		for _, line in ipairs(TT.ClassifyReport()) do TT.Report(line) end
		TT.ShowReport()
	elseif cmd == "plate" then
		TT.StartReport()
		for _, line in ipairs(TT.PlateReport(arg ~= "" and arg or nil)) do TT.Report(line) end
		TT.ShowReport()
	elseif cmd == "items" then
		if arg == "text" then
			TT.StartReport()
			for _, line in ipairs(TT.ShoppingList()) do TT.Report(line) end
			TT.ShowReport()
		else
			TT.ShowShop()
		end
	elseif cmd == "bis" then
		TT.ShowBis()
	elseif cmd == "vendor" then
		TT.ShowShop("vendor")
	elseif cmd == "craft" then
		TT.ShowShop("craft")
	elseif cmd == "alt" then
		TT.StartReport()
		for _, line in ipairs(TT.ModifierReport()) do TT.Report(line) end
		TT.ShowReport()
	elseif cmd == "minimap" then
		TT.db.showMinimap = not TT.db.showMinimap
		TT.RefreshMinimap()
		TT.Print("minimap button " .. (TT.db.showMinimap and "shown" or "hidden"))
	elseif cmd == "auction" then
		TT.StartReport()
		for _, line in ipairs(TT.AuctionReport()) do TT.Report(line) end
		TT.ShowReport()
	elseif cmd == "item" then
		TT.StartReport()
		for _, line in ipairs(TT.ItemReport(arg ~= "" and arg or nil)) do TT.Report(line) end
		TT.ShowReport()
	elseif cmd == "compact" then
		TT.db.compact = not TT.db.compact
		TT.ShowPanel(true)
		TT.Print("compact rotation panel = " .. (TT.db.compact and "on" or "off"))
	elseif cmd == "panel" then
		TT.ShowPanel(true)
		TT.Print(TT.PanelReport())
	elseif cmd == "copy" then
		TT.ShowReport()
	elseif cmd == "macro" then
		TT.StartReport()
		local found = 0
		for slot = 1, 120 do
			local kind, id = GetActionInfo(slot)
			if kind == "macro" then
				found = found + 1
				local name, _, body = GetMacroInfo(id)
				local direct = GetMacroSpell(id)
				local resolved = TT.MacroSpellID(id, nil)
				local info = resolved and C_Spell.GetSpellInfo(resolved)
				TT.Report(string.format("slot %d macro %s %s", slot, tostring(id), tostring(name)))
				TT.Report(string.format("    GetMacroSpell: %s (%s)", tostring(direct), type(direct)))
				TT.Report(string.format("    resolved: %s %s", tostring(resolved), info and info.name or "nothing"))
				for line in tostring(body):gmatch("[^\r\n]+") do TT.Report("    " .. line) end
			end
		end
		if found == 0 then TT.Report("no macros on any action slot the scanner looks at") end
		TT.ShowReport()
	elseif cmd == "blocked" then
		for event in pairs(TT.db.refusedEvents or {}) do
			TT.Print("refused event: " .. event)
		end
		local reports = TT.BlockedReports()
		if #reports == 0 then
			TT.Print("nothing blocked since login")
		else
			for _, entry in ipairs(reports) do TT.Print(entry) end
		end
	elseif cmd == "safe" then
		TT.db.showUnits, TT.db.showItems, TT.db.showEffects = false, false, false
		TT.Print("safe mode on, reload to drop the enemy tooltip handler entirely")
	elseif cmd == "forget" then
		TT.char.roles, TT.char.bestPhysical = {}, nil
		TT.ForgetHistory()
		TT.char.bisItems = {}
		TT.Print("forgot recorded bests, kill times, measured rates and seen gear")
	elseif cmd == "simulate" or cmd == "sim" then
		if TT.ShowSimulateExplorer then TT.ShowSimulateExplorer()
		else TT.Print("simulation explorer not loaded") end
	else
		TT.Print("unknown command; use /agf help to see commands and what they do")
	end
end

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function(self, event, name)
	if name ~= ADDON then return end
	AgamonForeverDB = applyDefaults(AgamonForeverDB or {})
	migrate(AgamonForeverDB)
	AgamonForeverAuctionDB = AgamonForeverAuctionDB or {}
	AgamonForeverCraftDB = AgamonForeverCraftDB or {}
	for itemID, price in pairs(AgamonForeverDB.prices or {}) do
		if AgamonForeverAuctionDB[itemID] == nil then AgamonForeverAuctionDB[itemID] = price end
	end
	AgamonForeverDB.prices = nil
	AgamonForeverChar = AgamonForeverChar or {}
	AgamonForeverChar.roles = AgamonForeverChar.roles or {}
	AgamonForeverChar.best = nil
	AgamonForeverChar.log = nil
	AgamonForeverChar.kills = AgamonForeverChar.kills or {}
	AgamonForeverChar.rates = AgamonForeverChar.rates or {}
	--a rival is kept per shape now, so the buckets that predate the shape have nothing left to match
	for _, roles in pairs(AgamonForeverChar.roles) do
		for role in pairs(roles) do
			if not role:find(":", 1, true) then roles[role] = nil end
		end
	end
	AgamonForeverDB.refusedEvents = AgamonForeverDB.refusedEvents or {}
	TT.db, TT.char, TT.auctionDB = AgamonForeverDB, AgamonForeverChar, AgamonForeverAuctionDB
	self:UnregisterEvent("ADDON_LOADED")

	--one module failing to start used to take every module after it with it, silently
	for _, fn in ipairs(initializers) do
		local ok, err = pcall(fn)
		if not ok then TT.Print("|cffff5555a module failed to start|r: " .. tostring(err)) end
	end
end)
