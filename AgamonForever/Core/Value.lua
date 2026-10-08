local ADDON, TT = ...

local RESOURCE_LABELS = {
	energy = "energy",
	rage = "rage",
	mana = "mana",
	combo = "combo point",
}

--a resource is worth what your rotation gets out of it on average, so the simulator is the only source of truth
function TT.PriceResource(kind, amount)
	local rate = TT.ResourceValue(kind)
	if not rate or not amount or amount == 0 then return nil end
	return amount * rate, rate
end

--a per resource figure means nothing without the baseline, so it carries what the rest of the rotation gets for the same point
function TT.ShareOfAverage(kind, value)
	local average = TT.ResourceValue(kind)
	if not average or average <= 0 or not value or value <= 0 then return nil end
	local ratio = value / average
	return ratio, string.format("%.0f%% of avg", ratio * 100)
end

--only one form runs on each bar, so a figure per point is a figure for that form and says so
local RESOURCE_FORM = {
	energy = "Cat",
	rage = "Bear",
	combo = "Cat",
}

function TT.ResourceForm(kind)
	return RESOURCE_FORM[kind]
end

function TT.ResourceLabel(kind)
	local form = RESOURCE_FORM[kind]
	local name = kind == "combo" and TT.ComboMark() or (RESOURCE_LABELS[kind] or kind)
	return form and (name .. " (" .. form .. ")") or name
end

--mana only becomes damage through whatever your spec spends it on: casts for a caster, shapeshifts for a form spec
function TT.PriceMana(amount, perShift)
	if not amount or amount == 0 then return nil end
	local spec = TT.Spec()

	if spec and spec.caster then
		local damage, rate = TT.PriceResource("mana", amount)
		if damage then return damage, string.format("%.2f per mana", rate) end
		return nil
	end

	local grant = TT.ShiftGrant()
	local kind = (grant.energy and "energy") or (grant.rage and "rage") or nil
	if not kind then return nil, "no shapeshift talent to turn mana into anything" end

	local cost = TT.ShiftCost()
	if not cost or cost <= 0 then return nil end

	--a saving on every shift buys extra shifts out of the same pool, and each shift pays a talent's grant
	local shifts
	if perShift then
		local reduced = math.max(1, cost - amount)
		shifts = amount / reduced
	else
		shifts = amount / cost
	end

	local resource = shifts * grant[kind]
	local damage = TT.PriceResource(kind, resource)
	if not damage then return nil end
	return damage, string.format("%.1f %s per shift", resource, kind), shifts
end

--the bar the current form runs on
function TT.FormPower()
	if not UnitPowerType then return nil end
	local kind, token = UnitPowerType("player")
	local name = TT.ReadableText(token) and token:lower() or nil
	if name ~= "energy" and name ~= "rage" then return nil end
	return name, kind
end

--and what is sitting on it right now, which is what you leave behind by shifting
function TT.FormResource()
	local name, kind = TT.FormPower()
	if not name then return nil end
	local current = UnitPower("player", kind)
	if not TT.Readable(current) then return nil end
	return current + 0, name
end

--a pure check with no pricing in it, because the rotation filters on this and pricing asks the rotation
function TT.WrongForm(forms, power)
	local current = TT.CurrentForm()
	if not current then return false end
	if forms then
		for form in pairs(forms) do
			if current:find(form, 1, true) or form:find(current, 1, true) then return false end
		end
		return true
	end
	--spending the form's own bar is proof enough that the form can cast it, whatever the tooltip does or does not say
	if power == TT.FormPower() then return false end
	return not (power == "mana" and current:find("moonkin", 1, true))
end

--an ability this form cannot cast costs the shift back, and everything the form's bar was holding when you left
function TT.ShiftPenalty(forms, power)
	if not TT.WrongForm(forms, power) then return nil end

	local damage, parts = 0, {}

	local mana = TT.ShiftCost()
	if mana and mana > 0 then
		local cost = TT.PriceMana(mana, false)
		if cost then damage = damage + cost end
		parts[#parts + 1] = string.format("%d mana back into form", mana)
	end

	local held, kind = TT.FormResource()
	if held and kind then
		local grant = TT.ShiftGrant()[kind] or 0
		local lost = math.max(0, held - grant)
		if lost > 0 then
			local cost = TT.PriceResource(kind, lost)
			if cost then damage = damage + cost end
			parts[#parts + 1] = string.format("%d %s on the floor", lost, kind)
		end
	end

	if damage <= 0 then return nil end
	return damage, table.concat(parts, " + ")
end

function TT.WorthLines()
	local worth = TT.Worth()
	local lines = {}
	for _, kind in ipairs({ "energy", "rage", "mana", "combo" }) do
		if worth[kind] then
			lines[#lines + 1] = { kind = kind, label = TT.ResourceLabel(kind), value = worth[kind] }
		end
	end
	return lines
end
