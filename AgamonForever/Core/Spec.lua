local ADDON, TT = ...

local MANA_PER_INTELLECT = 15
local REGEN_TICK = 2 --a spirit tick lands every two seconds
--mana per tick is spirit over this, plus a flat base the stat itself does not move
local SPIRIT_PER_TICK = {
	DRUID = 5, SHAMAN = 5, PALADIN = 5, HUNTER = 5, WARLOCK = 5, WARRIOR = 5, ROGUE = 5,
	MAGE = 4, PRIEST = 4,
}

--what each spec actually spends its gear budget on, which is what decides how an item is priced for it
local SPECS = {
	DRUID = {
		{ key = "cat", name = "Feral (Cat)", melee = true, form = "cat" },
		{ key = "bear", name = "Bear Tank", melee = true, tank = true, form = "bear" },
		{ key = "balance", name = "Balance", caster = true },
		{ key = "resto", name = "Restoration", caster = true, healer = true },
	},
	WARRIOR = {
		{ key = "arms", name = "Arms", melee = true },
		{ key = "fury", name = "Fury", melee = true },
		{ key = "prot", name = "Protection", melee = true, tank = true },
	},
	ROGUE = {
		{ key = "combat", name = "Combat", melee = true },
		{ key = "assassination", name = "Assassination", melee = true },
		{ key = "subtlety", name = "Subtlety", melee = true },
	},
	HUNTER = {
		{ key = "ranged", name = "Ranged", melee = true },
	},
	PALADIN = {
		{ key = "ret", name = "Retribution", melee = true },
		{ key = "prot", name = "Protection", melee = true, tank = true },
		{ key = "holy", name = "Holy", caster = true, healer = true },
	},
	SHAMAN = {
		{ key = "enhance", name = "Enhancement", melee = true },
		{ key = "ele", name = "Elemental", caster = true },
		{ key = "resto", name = "Restoration", caster = true, healer = true },
	},
	PRIEST = {
		{ key = "shadow", name = "Shadow", caster = true },
		{ key = "holy", name = "Holy", caster = true, healer = true },
	},
	MAGE = { { key = "mage", name = "Mage", caster = true } },
	WARLOCK = { { key = "lock", name = "Warlock", caster = true } },
}

local function class()
	local _, token = UnitClass("player")
	return token
end

function TT.SpecList()
	return SPECS[class()] or {}
end

function TT.Spec()
	local list = TT.SpecList()
	local chosen = TT.char and TT.char.spec
	for _, spec in ipairs(list) do
		if spec.key == chosen then return spec end
	end
	return list[1]
end

function TT.SetSpec(key)
	if TT.char then TT.char.spec = key end
	if TT.InvalidateRotation then TT.InvalidateRotation() end
end

--which other specs the player asked to see priced alongside their own
function TT.ExtraSpecs()
	local extras = {}
	local wanted = TT.db and TT.db.extraSpecs or {}
	local current = TT.Spec()
	for _, spec in ipairs(TT.SpecList()) do
		if wanted[spec.key] and (not current or spec.key ~= current.key) then extras[#extras + 1] = spec end
	end
	return extras
end

--this client returns icon, active, castable, spellID where older ones returned icon, name, so the slot is found by type
--castable comes back a secret boolean here, and `value or false` is itself the boolean test that errors on one
local function plainNumber(value)
	if not TT.Readable(value) then return nil end
	return type(value) == "number" and value or nil
end

function TT.FormSpell(index)
	if not GetShapeshiftFormInfo then return nil end
	local _, second, third, fourth = GetShapeshiftFormInfo(index)
	local spellID = plainNumber(fourth) or plainNumber(third) or plainNumber(second)
	if spellID then return spellID end
	if TT.ReadableText(second) then
		local info = C_Spell.GetSpellInfo(second)
		return info and info.spellID or nil
	end
	return nil
end

function TT.SpellName(spellID)
	local info = spellID and C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spellID)
	return info and info.name or nil
end

--the form itself as a castable thing, so a rotation that needs one can tell you to press it,
--looked up once because every form read walks a secret-laden api
local formsByName = {}

function TT.FormByName(wanted)
	if not wanted or not GetNumShapeshiftForms then return nil end
	local hit = formsByName[wanted]
	if hit then return hit.id, hit.name end
	for index = 1, (GetNumShapeshiftForms() or 0) do
		local spellID = TT.FormSpell(index)
		local info = spellID and C_Spell.GetSpellInfo(spellID)
		local name = info and info.name
		if name and name:lower():find(wanted, 1, true) then
			formsByName[wanted] = { id = spellID, name = name }
			return spellID, name
		end
	end
	return nil
end

function TT.ForgetForms()
	formsByName = {}
end

--caster form is not a form spell and so owns no icon, and the class icon is the closest thing to standing as yourself
function TT.FormTexture(form)
	if not form then return nil end
	if form == "caster" then
		local _, class = UnitClass and UnitClass("player")
		if not class then return nil end
		return "Interface\\Icons\\ClassIcon_" .. class:sub(1, 1) .. class:sub(2):lower()
	end
	local spellID = TT.FormByName(form)
	return spellID and C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(spellID) or nil
end

--named the way a spell tooltip names it, so "requires cat form" can be checked against it directly
function TT.CurrentForm()
	if not GetShapeshiftForm then return nil end
	local index = GetShapeshiftForm()
	if not index or index == 0 then return nil end
	local spellID = TT.FormSpell(index)
	local info = spellID and C_Spell.GetSpellInfo(spellID)
	return info and info.name and info.name:lower() or nil
end

local FORM_LABELS = {
	bear = "Bear", cat = "Cat", moonkin = "Moonkin", travel = "Travel", aquatic = "Aquatic",
}

--a tooltip lists every form an ability allows, and dire bear is still bear to someone reading a label
function TT.FormLabel(forms)
	if not forms then return nil end
	local seen, names = {}, {}
	for name in pairs(forms) do
		for key, label in pairs(FORM_LABELS) do
			if not seen[key] and name:find(key, 1, true) then
				seen[key] = true
				names[#names + 1] = label
			end
		end
	end
	if #names == 0 then return nil end
	table.sort(names)
	return table.concat(names, "/")
end

function TT.ManaFromIntellect(intellect)
	return (intellect or 0) * MANA_PER_INTELLECT
end

--spirit is mana per regen tick rather than pool, so what it is worth depends entirely on how long the fight runs
function TT.ManaFromSpirit(spirit, seconds)
	if not spirit or spirit == 0 or not seconds or seconds <= 0 then return nil end
	local _, class = UnitClass("player")
	local divisor = class and SPIRIT_PER_TICK[class]
	if not divisor then return nil end
	return spirit / divisor * (seconds / REGEN_TICK)
end
