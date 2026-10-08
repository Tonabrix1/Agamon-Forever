local ADDON, TT = ...

local function spellID(identifier)
	if not identifier or identifier == "" then return nil end
	local info = C_Spell.GetSpellInfo(identifier)
	return info and info.spellID
end

local function trim(text)
	if not TT.ReadableText(text) then return nil end
	return text:match("^%s*(.-)%s*$")
end

--the client already resolved any #showtooltip conditionals when it drew the tooltip, so its title is the last word
local function fromTitle(tooltip)
	local name = tooltip:GetName()
	if not name then return nil end
	local left = _G[name .. "TextLeft1"]
	local right = _G[name .. "TextRight1"]
	local title = left and trim(left:GetText())
	if not title then return nil end
	local rank = right and trim(right:GetText())
	if rank and rank ~= "" then
		local id = spellID(title .. "(" .. rank .. ")")
		if id then return id end
	end
	return spellID(title)
end

local DIRECTIVES = { "^#showtooltip%s+", "^#show%s+" }
local CASTS = { "^/cast%s+", "^/use%s+", "^/castrandom%s+" }
local SEQUENCE = { "^/castsequence%s+" }

local function argsAfter(line, prefixes)
	local lowered = line:lower()
	for _, prefix in ipairs(prefixes) do
		local _, stop = lowered:find(prefix)
		if stop then return line:sub(stop + 1) end
	end
	return nil
end

local function firstSpellIn(body, prefixes)
	for line in body:gmatch("[^\r\n]+") do
		local args = argsAfter(line, prefixes)
		if args then
			local resolved = SecureCmdOptionParse and SecureCmdOptionParse(args) or args
			local id = spellID(trim(resolved))
			if id then return id end
		end
	end
	return nil
end

--only a castsequence genuinely fires several casts in order, so only it gets chain maths
local function sequenceSpells(macroIndex)
	local _, _, body = GetMacroInfo(macroIndex)
	if not body then return nil end
	for line in body:gmatch("[^\r\n]+") do
		local args = argsAfter(line, SEQUENCE)
		if args then
			args = args:gsub("%b[]", ""):gsub("reset=%S+", "")
			local ids = {}
			for part in args:gmatch("[^,]+") do
				local id = spellID(trim(part))
				if id then ids[#ids + 1] = id end
			end
			if #ids > 1 then return ids end
		end
	end
	return nil
end

local function macroIndexOf(tooltip, data)
	if data and Enum.TooltipDataType.Macro and data.type == Enum.TooltipDataType.Macro then return data.id end
	local owner = tooltip and tooltip:GetOwner()
	local slot = owner and owner.action
	if not slot then return nil end
	local kind, id = GetActionInfo(slot)
	return kind == "macro" and id or nil
end

function TT.MacroChain(tooltip, data)
	local index = macroIndexOf(tooltip, data)
	return index and sequenceSpells(index) or nil
end

local function fromMacroBody(macroIndex)
	local _, _, body = GetMacroInfo(macroIndex)
	if not body then return nil end
	return firstSpellIn(body, DIRECTIVES) or firstSpellIn(body, CASTS)
end

function TT.MacroSpellID(macroIndex, tooltip)
	local spell = GetMacroSpell(macroIndex)
	if type(spell) == "number" then return spell end
	if type(spell) == "string" then
		local id = spellID(spell)
		if id then return id end
	end
	return fromMacroBody(macroIndex) or (tooltip and fromTitle(tooltip))
end

--buff and debuff icons carry their own aura index rather than an action slot
local function fromAura(owner, tooltip)
	if not owner then return nil end
	local index = owner.buffIndex or owner.auraIndex or (owner.GetID and owner:GetID())
	local filter = owner.filter or (owner.isHarmful and "HARMFUL") or (owner.isHelpful and "HELPFUL")
	local unit = owner.unit or (owner.GetParent and owner:GetParent() and owner:GetParent().unit) or "player"
	if index and index > 0 and filter then
		if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
			local aura = C_UnitAuras.GetAuraDataByIndex(unit, index, filter)
			if aura and aura.spellId then return aura.spellId end
		end
		if UnitAura then
			local aura = { UnitAura(unit, index, filter) }
			for _, value in ipairs(aura) do
				if type(value) == "number" and value > 10 then return value end
			end
		end
	end
	return fromTitle(tooltip)
end

local function isAuraOwner(owner)
	if not owner then return false end
	if owner.buffIndex or owner.auraIndex or owner.filter then return true end
	local name = owner.GetName and owner:GetName()
	return name ~= nil and (name:find("Buff", 1, true) or name:find("Debuff", 1, true) or name:find("Aura", 1, true)) ~= nil
end

--a nameplate aura hands us a secret number, and everything downstream compares the id, so it stops here
local function plain(id)
	if not TT.Readable(id) then return nil end
	return id
end

function TT.ResolveSpell(tooltip, data)
	return plain(TT.ResolveSpellID(tooltip, data))
end

function TT.ResolveSpellID(tooltip, data)
	if data and data.id then
		if data.type == Enum.TooltipDataType.Spell then return data.id end
		if Enum.TooltipDataType.Macro and data.type == Enum.TooltipDataType.Macro then return TT.MacroSpellID(data.id, tooltip) end
		if Enum.TooltipDataType.UnitAura and data.type == Enum.TooltipDataType.UnitAura then return data.id end
	end

	local owner = tooltip:GetOwner()
	local slot = owner and owner.action
	if slot then
		local kind, id = GetActionInfo(slot)
		if kind == "spell" then return id end
		if kind == "macro" then return TT.MacroSpellID(id, tooltip) end
		return nil
	end

	if isAuraOwner(owner) then return fromAura(owner, tooltip) end
	return nil
end
