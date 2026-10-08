local ADDON, TT = ...

local BUTTON_SIZE = 31
local ICON_SIZE = 20
local BORDER_SIZE = 56
local RING_GAP = 5 --libdbicon's, so the button sits on the ring whatever size the minimap is
local ICON = "Interface\\Icons\\Ability_Druid_CatForm"
local BORDER = "Interface\\Minimap\\MiniMap-TrackingBorder"

--the square minimap shapes, where a corner is further from the centre than a side is
local SQUARE_QUADRANTS = {
	["SQUARE"] = { false, false, false, false },
	["CORNER-TOPLEFT"] = { false, false, false, true },
	["CORNER-TOPRIGHT"] = { false, false, true, false },
	["CORNER-BOTTOMLEFT"] = { false, true, false, false },
	["CORNER-BOTTOMRIGHT"] = { true, false, false, false },
	["SIDE-LEFT"] = { false, true, false, true },
	["SIDE-RIGHT"] = { true, false, true, false },
	["SIDE-TOP"] = { false, false, true, true },
	["SIDE-BOTTOM"] = { true, true, false, false },
	["TRICORNER-TOPLEFT"] = { false, true, true, true },
	["TRICORNER-TOPRIGHT"] = { true, false, true, true },
	["TRICORNER-BOTTOMLEFT"] = { true, true, false, true },
	["TRICORNER-BOTTOMRIGHT"] = { true, true, true, false },
}

local button

--a ring radius read off the minimap rather than assumed: a hardcoded one puts the button wherever the minimap is not
local function offset(angle)
	local x, y = math.cos(angle), math.sin(angle)
	local w = Minimap:GetWidth() / 2 + RING_GAP
	local h = Minimap:GetHeight() / 2 + RING_GAP
	local shape = GetMinimapShape and GetMinimapShape() or "ROUND"
	local quadrants = SQUARE_QUADRANTS[shape]
	if not quadrants then return x * w, y * h end

	local quadrant = 1
	if x < 0 then quadrant = quadrant + 1 end
	if y > 0 then quadrant = quadrant + 2 end
	if quadrants[quadrant] then return x * w, y * h end

	local diagonalW = math.sqrt(2 * w * w) - 10
	local diagonalH = math.sqrt(2 * h * h) - 10
	return math.max(-w, math.min(x * diagonalW, w)), math.max(-h, math.min(y * diagonalH, h))
end

local function place()
	local x, y = offset(math.rad(TT.db.minimapAngle or 200))
	button:ClearAllPoints()
	button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function drag(self)
	local cx, cy = Minimap:GetCenter()
	local mx, my = GetCursorPosition()
	local scale = Minimap:GetEffectiveScale()
	TT.db.minimapAngle = math.deg(math.atan2(my / scale - cy, mx / scale - cx))
	place()
end

local function tooltip(self)
	GameTooltip:SetOwner(self, "ANCHOR_LEFT")
	GameTooltip:AddLine(TT.db.label)
	GameTooltip:AddLine("|cffffd100Left Click:|r Toggle the rotation panel", 1, 1, 1)
	GameTooltip:AddLine("|cffffd100Shift+Left Click:|r Open item upgrades", 1, 1, 1)
	GameTooltip:AddLine("|cffffd100Ctrl+Left Click:|r Open Simulation Explorer", 1, 1, 1)
	GameTooltip:AddLine("|cffffd100Right Click:|r Open options", 1, 1, 1)
	GameTooltip:AddLine("|cffffd100Ctrl+Right Click:|r Open crafting", 1, 1, 1)
	GameTooltip:AddLine("|cff888888/agf rank   /agf rotation   /agf meter|r")
	GameTooltip:Show()
end

--parented to the minimap rather than hooking anything on it, the way everything else here stays off Blizzard frames
local function build()
	button = CreateFrame("Button", "AgamonMinimapButton", Minimap)
	button:SetSize(BUTTON_SIZE, BUTTON_SIZE)
	--pinned the way libdbicon pins every button the client already shows, so nothing can relevel it underneath the cluster
	button:SetFrameStrata("MEDIUM")
	if button.SetFixedFrameStrata then button:SetFixedFrameStrata(true) end
	button:SetFrameLevel(8)
	if button.SetFixedFrameLevel then button:SetFixedFrameLevel(true) end
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:RegisterForDrag("LeftButton")
	button:SetMovable(true)

	local icon = button:CreateTexture(nil, "ARTWORK")
	icon:SetSize(ICON_SIZE, ICON_SIZE)
	icon:SetPoint("CENTER", -1, 1)
	icon:SetTexture(ICON)
	icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

	local ring = button:CreateTexture(nil, "OVERLAY")
	ring:SetSize(BORDER_SIZE, BORDER_SIZE)
	ring:SetPoint("TOPLEFT")
	ring:SetTexture(BORDER)

	button:SetScript("OnClick", function(self, click)
		local control = IsControlKeyDown and IsControlKeyDown()
		if click == "RightButton" then
			if control and TT.ShowShop then TT.ShowShop("craft") else TT.ToggleOptions() end
		elseif IsShiftKeyDown and IsShiftKeyDown() and TT.ShowShop then TT.ShowShop("upgrades")
		elseif control and TT.ShowSimulateExplorer then TT.ShowSimulateExplorer()
		else TT.TogglePanel() end
	end)
	button:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", drag) end)
	button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
	button:SetScript("OnEnter", tooltip)
	button:SetScript("OnLeave", function() GameTooltip:Hide() end)

	place()
end

--says where the button thinks it is, since a button that exists and cannot be seen looks the same as one that was never made
function TT.MinimapReport()
	if not Minimap then return "there is no Minimap frame on this client" end
	if not button then return "the button was never built, showMinimap is " .. tostring(TT.db.showMinimap) end
	local point, _, relative, x, y = button:GetPoint()
	return string.format("button shown=%s at %s %+.0f %+.0f of %s, %s level %d, angle %s; minimap %.0fx%.0f scale %.2f shape %s shown=%s",
		tostring(button:IsShown()), tostring(point), x or 0, y or 0, tostring(relative),
		tostring(button:GetFrameStrata()), button:GetFrameLevel() or 0, tostring(TT.db.minimapAngle),
		Minimap:GetWidth() or 0, Minimap:GetHeight() or 0, Minimap:GetEffectiveScale() or 0,
		tostring(GetMinimapShape and GetMinimapShape() or "ROUND"), tostring(Minimap:IsShown()))
end

--a compartment entry is the one place the client guarantees is reachable, whatever is covering the ring
local function addToCompartment()
	if not AddonCompartmentFrame or not AddonCompartmentFrame.RegisterAddon then return end
	AddonCompartmentFrame:RegisterAddon({
		text = TT.db.label,
		icon = ICON,
		registerForAnyClick = true,
		func = function(_, menu) if menu == "RightButton" then TT.ToggleOptions() else TT.TogglePanel() end end,
	})
end

function TT.RefreshMinimap()
	if not TT.db.showMinimap then
		if button then button:Hide() end
		return
	end
	if not button then build() end
	button:Show()
	place()
end

TT.OnInit(function()
	addToCompartment()
	if Minimap then TT.RefreshMinimap() end
end)
