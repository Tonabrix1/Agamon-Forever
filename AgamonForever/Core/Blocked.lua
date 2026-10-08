local ADDON, TT = ...

local KEEP = 10

local reports = {}

--logged whatever the name on it, since filtering on our own name is how the last report went missing
local function note(kind, addon, func)
	local entry = string.format("%s %s: %s", kind, tostring(addon), tostring(func))
	reports[#reports + 1] = entry
	if #reports > KEEP then table.remove(reports, 1) end
	if TT.char then TT.char.blocked = reports end
	if TT.Print then
		TT.Print("|cffff5555" .. entry .. "|r -- report with /agf blocked")
	else
		print("Agamon: Forever: " .. entry)
	end
end

--anything caught before saved variables existed still gets written once they do
local function flush()
	if TT.char and #reports > 0 then TT.char.blocked = reports end
end

function TT.BlockedReports()
	if TT.char and TT.char.blocked then return TT.char.blocked end
	return reports
end

local frame = CreateFrame("Frame")
--only the event this client has proven it allows; attempting the other one is itself a forbidden action
frame:RegisterEvent("ADDON_ACTION_FORBIDDEN")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function(self, event, addon, func)
	if event == "PLAYER_LOGIN" then
		flush()
		return
	end
	note(event == "ADDON_ACTION_FORBIDDEN" and "forbidden" or "blocked", addon, func)
end)
