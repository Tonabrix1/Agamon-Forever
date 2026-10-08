local ADDON, TT = ...

local CACHE_SECONDS = 3 --tooltips and the panel both ask, and the session only moves on its own event anyway
local SWING_SPELL = 6603

local available

local cached, cachedAt = nil, 0

--every field of a session can be a secret value mid combat, so nothing here is compared before it is checked
local function readable(value)
	if issecret and issecret(value) then return false end
	if issecretvalue and issecretvalue(value) then return false end
	return value ~= nil
end

local function number(value)
	if not readable(value) or type(value) ~= "number" then return nil end
	return value
end

function TT.MeterAvailable()
	if available == nil then
		available = (C_DamageMeter ~= nil) and (C_DamageMeter.GetCombatSessionSourceFromType ~= nil)
			and (TT.Safely(C_DamageMeter.IsDamageMeterAvailable) == true)
	end
	return available
end

local function session()
	local kind = Enum.DamageMeterSessionType.Current
	local meter = Enum.DamageMeterType.Dps
	local source = TT.Safely(C_DamageMeter.GetCombatSessionSourceFromType, kind, meter, UnitGUID("player"))
	if not source or not readable(source) then return nil end
	local spells = source.combatSpells
	if not spells or not readable(spells) then return nil end
	return spells
end

--what the game's own meter says each of your spells is actually doing, per second, with no combat log anywhere
function TT.MeterSpells()
	if not TT.MeterAvailable() then return nil end
	if cached and (GetTime() - cachedAt) < CACHE_SECONDS then return cached end

	local spells = session()
	if not spells then return nil end

	local out = {}
	for _, spell in ipairs(spells) do
		local id = number(spell.spellID)
		local total = number(spell.totalAmount)
		local rate = number(spell.amountPerSecond)
		if id and total and total > 0 then
			out[id] = { total = total, rate = rate, overkill = number(spell.overkillAmount) }
			if rate and rate > 0 then TT.NoteSpellRate(id, rate) end
		end
	end

	cached, cachedAt = out, GetTime()
	return out
end

--the measured rate against the predicted one, with how much data stands behind it
function TT.Compare(spellID, predicted)
	if not spellID or not predicted or predicted <= 0 then return nil end
	local measured, confidence = TT.SpellRate(spellID)
	if not measured then
		local spells = TT.MeterSpells()
		local entry = spells and spells[spellID]
		measured = entry and entry.rate
		confidence = 0
	end
	if not measured or measured <= 0 then return nil end
	return { measured = measured, delta = measured / predicted - 1, confidence = confidence or 0 }
end

function TT.MeterSummary()
	local spells = TT.MeterSpells()
	if not spells then return {} end
	local out = {}
	for id, entry in pairs(spells) do
		local info = C_Spell.GetSpellInfo(id)
		local _, confidence = TT.SpellRate(id)
		out[#out + 1] = {
			name = id == SWING_SPELL and "Swing" or (info and info.name or tostring(id)),
			spellID = id,
			rate = entry.rate or 0,
			total = entry.total,
			confidence = confidence or 0,
		}
	end
	table.sort(out, function(a, b) return a.total > b.total end)
	return out
end

local frame = CreateFrame("Frame")
TT.OnInit(function()
	if not TT.MeterAvailable() then return end
	TT.Listen(frame, "DAMAGE_METER_CURRENT_SESSION_UPDATED")
end)
frame:SetScript("OnEvent", function()
	cached, cachedAt = nil, 0
	TT.MeterSpells()
end)
