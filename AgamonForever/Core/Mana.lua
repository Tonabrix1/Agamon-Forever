local ADDON, TT = ...

local FIVE_SECOND_RULE = 5
local TICK_WINDOW = 6 --a regen tick lands every two seconds, so three of them is enough to call it ticking

local last, spentAt, tickAt, perTick = nil, nil, nil, nil

local function displayedMana()
	local player = PlayerFrame
	local content = player and player.PlayerFrameContent
	local main = content and content.PlayerFrameContentMain
	local area = main and main.ManaBarArea
	local bar = PlayerFrameManaBar or (player and (player.ManaBar or player.manaBar))
		or (area and area.ManaBar) or (main and main.ManaBar)
	if not bar or bar.IsShown and not bar:IsShown() or not bar.GetValue or not bar.GetMinMaxValues then return nil end
	local current = TT.ReadableNumber(bar:GetValue())
	local _, maximum = bar:GetMinMaxValues()
	maximum = TT.ReadableNumber(maximum)
	if current and maximum and maximum > 0 then return current, maximum end
end

local function mana()
	if UnitPower and Enum and Enum.PowerType then
		local value = UnitPower("player", Enum.PowerType.Mana)
		if TT.Readable(value) then return value + 0 end
	end
	return displayedMana()
end

local function maxMana()
	if UnitPowerMax and Enum and Enum.PowerType then
		local value = UnitPowerMax("player", Enum.PowerType.Mana)
		if TT.Readable(value) then return value + 0 end
	end
	local _, maximum = displayedMana()
	return maximum
end

--updates spend/tick tracking from the current mana value, called when mana state is read rather than on a timer
local function poll()
	local now = mana()
	if not now then return end
	if last then
		if now < last then
			spentAt = GetTime()
		elseif now > last then
			tickAt = GetTime()
			perTick = now - last
		end
	end
	last = now
end

--mana, and whether the five second rule is currently holding regen off
function TT.ManaState()
	poll()
	local current, pool = mana(), maxMana()
	if not current or not pool or pool <= 0 then return nil end

	local paused = spentAt and (GetTime() - spentAt) or nil
	local ticking = tickAt ~= nil and (GetTime() - tickAt) < TICK_WINDOW
	return {
		current = current,
		max = pool,
		headroom = pool - current,
		paused = paused,
		held = paused ~= nil and paused < FIVE_SECOND_RULE,
		ticking = ticking,
		tickAfterSpend = tickAt ~= nil and (spentAt == nil or tickAt >= spentAt),
		perSecond = (perTick and ticking) and perTick / 2 or nil,
	}
end

--casting restarts the five second rule, so a cast costs its mana plus the regen that pause throws away
function TT.ManaVerdict(cost)
	if not cost or cost <= 0 then return nil end
	local state = TT.ManaState()
	if not state then return nil end

	local detail = {
		{ "Mana", string.format("%d / %d", state.current, state.max) },
	}

	if cost > state.current then
		detail[#detail + 1] = { "Short by", string.format("%d mana", cost - state.current) }
		return { text = string.format("no: %d mana short", cost - state.current), detail = detail }
	end

	local rate = state.perSecond
	if not rate then
		detail[#detail + 1] = { "Regen", "not measured yet" }
		return { text = "unknown: no regen measured yet", detail = detail }
	end

	--casting pushes the moment regen resumes out by five seconds from now, so what you lose is the pause you have already served
	local seconds = state.held and state.paused or FIVE_SECOND_RULE
	--regen you could never have banked is not a cost, so the loss is capped by the room left in the pool
	local lost = math.min(seconds * rate, state.headroom)
	detail[#detail + 1] = { "Regen", string.format("%.1f mana a second%s", rate, state.ticking and ", ticking" or ", idle") }
	detail[#detail + 1] = { "Casting now costs", string.format("%.0f mana of regen", lost) }

	if state.headroom <= cost then
		return { text = "good: the pool is nearly full", detail = detail }
	end
	if lost < rate then
		local why = state.held and string.format("regen is already paused, %.1fs in", state.paused) or "no regen to lose"
		return { text = "good: " .. why, detail = detail }
	end
	if state.held then
		return { text = string.format("costs %.0f mana of regen, %.1fs into the pause", lost, state.paused), detail = detail }
	end
	return { text = string.format("wait: costs %.0f mana of regen", lost), detail = detail }
end
