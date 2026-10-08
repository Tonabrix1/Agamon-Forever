local ADDON, TT = ...

local WEIGHT = 0.2 --a new sample moves the average a fifth of the way, so recent gear wins without ever needing a reset
local FULL_CONFIDENCE = 20
local MIN_KILL_SECONDS = 0.5
local MAX_KILL_SECONDS = 300
local LEVEL_CLAMP = 5

local pending = {}

local function rows(kind)
	TT.char[kind] = TT.char[kind] or {}
	return TT.char[kind]
end

local function fold(store, key, value)
	local row = store[key] or {}
	row.value = row.value and (row.value * (1 - WEIGHT) + value * WEIGHT) or value
	row.samples = (row.samples or 0) + 1
	store[key] = row
	return row
end

function TT.Confidence(samples)
	return math.min(1, (samples or 0) / FULL_CONFIDENCE)
end

function TT.KillBucket(level, classification, playerLevel)
	local difference = (level or playerLevel) - playerLevel
	difference = math.max(-LEVEL_CLAMP, math.min(LEVEL_CLAMP, difference))
	return difference .. ":" .. (classification or "normal")
end

--the only kill timer that works on a client where health is secret: engaged until dead, no numbers read
function TT.NoteKill(bucket, seconds)
	if not seconds or seconds < MIN_KILL_SECONDS or seconds > MAX_KILL_SECONDS then return end
	fold(rows("kills"), bucket or "any", seconds)
	if bucket then fold(rows("kills"), "any", seconds) end
end

--a kill is timed from the first damage we see on a unit to the moment its health reaches zero
function TT.NoteUnitHealth(guid, entry, playerLevel)
	if not guid or not entry or not entry.max or entry.max <= 0 or not entry.current then return end
	local now = GetTime()

	if entry.current >= entry.max then
		pending[guid] = nil
	elseif entry.current > 0 then
		pending[guid] = pending[guid] or { start = now, bucket = TT.KillBucket(entry.level, entry.classification, playerLevel) }
	else
		local fight = pending[guid]
		pending[guid] = nil
		if fight then
			local seconds = now - fight.start
			if seconds >= MIN_KILL_SECONDS and seconds <= MAX_KILL_SECONDS then
				fold(rows("kills"), fight.bucket, seconds)
				fold(rows("kills"), "any", seconds)
			end
		end
	end
end

function TT.KillTime(bucket)
	local store = rows("kills")
	local row = bucket and store[bucket]
	if row and row.value then return row.value, TT.Confidence(row.samples) end
	row = store.any
	if row and row.value then return row.value, TT.Confidence(row.samples) end
	return nil
end

--what the game's own meter measured this spell doing, kept rolling so clearing the meter costs nothing
function TT.NoteSpellRate(spellID, rate)
	if not spellID or not rate or rate <= 0 then return end
	fold(rows("rates"), spellID, rate)
end

function TT.SpellRate(spellID)
	local row = rows("rates")[spellID]
	if not row or not row.value then return nil end
	return row.value, TT.Confidence(row.samples)
end

function TT.ForgetHistory()
	TT.char.kills, TT.char.rates, pending = {}, {}, {}
end
