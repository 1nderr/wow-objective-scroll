local TALL_HEIGHT = 4000
local WHEEL_STEP = 45
local LEFT_PAD = 40
local BAR_GAP = 10
local SCROLLBAR_WIDTH = 17
local RIGHT_PAD = BAR_GAP + SCROLLBAR_WIDTH + 2
local SMOOTHNESS = 14

local objectiveTracker
local scrollView
local scrollBar
local syncingScrollBar = false
local attached = false
local origClamped
local visibleHeight
local offset = 0
local target = 0
local range = 0
local contentHeight = 0
local moduleAnchors = {}
local hookedModules = {}
local nsAnchor
local trackerBase = {}
local shiftX = 0
local busy = false
local editMode = false
local dirty = true

local function Print(msg)
	print("|cff66ccffObjectiveScroll:|r " .. msg)
end

local function Blocked(frame)
	return InCombatLockdown() and frame:IsProtected() and true or false
end

local function IsDefaultPosition()
	if objectiveTracker.IsInDefaultPosition then
		local ok, res = pcall(objectiveTracker.IsInDefaultPosition, objectiveTracker)
		if ok then
			return res
		end
	end
	return false
end

local function ClipTop()
	return (tonumber(objectiveTracker.topModulePadding) or 38) - 4
end

local function ParseSetPoint(p, a, b, c, d)
	local rel, rp, x, y
	if type(a) == "number" then
		rel, rp, x, y = nil, p, a, b
	elseif type(b) == "number" then
		rel, rp, x, y = a, p, b, c
	else
		rel, rp, x, y = a, b or p, c, d
	end
	if type(rel) == "string" then
		rel = _G[rel]
	end
	return p:upper(), rel, (rp or p):upper(), x or 0, y or 0
end

local function GetModules()
	local list = {}
	if type(objectiveTracker.modules) == "table" then
		for _, m in ipairs(objectiveTracker.modules) do
			if type(m) == "table" and m.GetObjectType then
				list[#list + 1] = m
			end
		end
	end
	return list
end

local function ApplyModuleAnchor(m)
	local a = moduleAnchors[m]
	if not a or Blocked(m) then
		return
	end
	busy = true
	m:SetPoint(a[1], a[2], a[3], a[4], a[5] + (attached and offset or 0))
	busy = false
end

local function ApplyAllModuleAnchors()
	for m in pairs(moduleAnchors) do
		ApplyModuleAnchor(m)
	end
end

local function CaptureModuleAnchor(m)
	for i = 1, m:GetNumPoints() do
		local p, rel, rp, x, y = m:GetPoint(i)
		if p and p:find("TOP") and (rel == objectiveTracker or rel == scrollView or rel == nil) then
			moduleAnchors[m] = { p, objectiveTracker, rp, x or 0, (y or 0) - (attached and offset or 0) }
			return
		end
	end
end

local function UpdateContentHeight()
	local top = objectiveTracker:GetTop()
	contentHeight = 0
	if not top then
		return
	end
	local ns = objectiveTracker.NineSlice
	if nsAnchor and ns and ns:IsShown() and nsAnchor[2] and nsAnchor[2].GetBottom then
		local b = nsAnchor[2]:GetBottom()
		if b then
			contentHeight = top - (b - offset) - nsAnchor[5]
		end
	end
end

local function ApplyNineSlice()
	local ns = objectiveTracker.NineSlice
	if not (ns and nsAnchor and visibleHeight) then
		return
	end
	local h = math.min(contentHeight, visibleHeight)
	if h <= 0 then
		return
	end
	busy = true
	ns:SetPoint(nsAnchor[1], objectiveTracker, "TOP", nsAnchor[4], -h)
	busy = false
end

local function RestoreNineSlice()
	local ns = objectiveTracker.NineSlice
	if not (ns and nsAnchor) then
		return
	end
	busy = true
	ns:SetPoint(nsAnchor[1], nsAnchor[2], nsAnchor[3], nsAnchor[4], nsAnchor[5])
	busy = false
end

local function ApplyOffset(new)
	for m in pairs(moduleAnchors) do
		if Blocked(m) then
			target = offset
			return
		end
	end
	offset = new
	ApplyAllModuleAnchors()
	dirty = true
end

local function SetOffset(new, instant)
	target = math.max(0, math.min(range, math.floor(new + 0.5)))
	if instant and target ~= offset then
		ApplyOffset(target)
	end
end

local function Animate(elapsed)
	if offset == target then
		return
	end
	local new = offset + (target - offset) * math.min(1, elapsed * SMOOTHNESS)
	if math.abs(target - new) < 0.5 then
		new = target
	end
	ApplyOffset(new)
end

local function SetTrackerBase(p, rel, rp, x, y)
	for i = #trackerBase, 1, -1 do
		if trackerBase[i][1] == p then
			table.remove(trackerBase, i)
		end
	end
	trackerBase[#trackerBase + 1] = { p, rel or objectiveTracker:GetParent(), rp, x, y }
end

local function CaptureTrackerBase()
	wipe(trackerBase)
	for i = 1, objectiveTracker:GetNumPoints() do
		local p, rel, rp, x, y = objectiveTracker:GetPoint(i)
		if p then
			SetTrackerBase(p, rel, rp, x or 0, y or 0)
		end
	end
end

local function VerticalShift(p)
	local extra = TALL_HEIGHT - (visibleHeight or TALL_HEIGHT)
	if p:find("TOP") then
		return 0
	elseif p:find("BOTTOM") then
		return -extra
	else
		return -extra / 2
	end
end

local function TrackerAnchorsMatch(stretched)
	if objectiveTracker:GetNumPoints() ~= #trackerBase then
		return false
	end
	for i, b in ipairs(trackerBase) do
		local p, rel, rp, x, y = objectiveTracker:GetPoint(i)
		local wx, wy = b[4], b[5]
		if stretched then
			wx, wy = wx + shiftX, wy + VerticalShift(b[1])
		end
		if
			p ~= b[1]
			or rel ~= b[2]
			or rp ~= b[3]
			or math.abs((x or 0) - wx) > 0.01
			or math.abs((y or 0) - wy) > 0.01
		then
			return false
		end
	end
	return true
end

local function ApplyTrackerAnchors(stretched)
	if #trackerBase == 0 or Blocked(objectiveTracker) or TrackerAnchorsMatch(stretched) then
		return
	end
	busy = true
	objectiveTracker:ClearAllPoints()
	for _, b in ipairs(trackerBase) do
		if stretched then
			objectiveTracker:SetPoint(b[1], b[2], b[3], b[4] + shiftX, b[5] + VerticalShift(b[1]))
		else
			objectiveTracker:SetPoint(b[1], b[2], b[3], b[4], b[5])
		end
	end
	busy = false
end

local function StretchTracker()
	if Blocked(objectiveTracker) then
		return
	end
	ApplyTrackerAnchors(true)
	if math.abs(objectiveTracker:GetHeight() - TALL_HEIGHT) > 0.01 then
		busy = true
		objectiveTracker:SetHeight(TALL_HEIGHT)
		busy = false
	end
end

local function HookModule(m)
	if hookedModules[m] then
		return
	end
	hookedModules[m] = true
	hooksecurefunc(m, "SetPoint", function(self, ...)
		if busy or type((...)) ~= "string" then
			return
		end
		local p, rel, rp, x, y = ParseSetPoint(...)
		if not p:find("TOP") then
			return
		end
		if rel == nil or rel == scrollView then
			rel = objectiveTracker
		end
		if rel == objectiveTracker then
			moduleAnchors[self] = { p, objectiveTracker, rp, x, y }
			if attached then
				ApplyModuleAnchor(self)
			end
		else
			moduleAnchors[self] = nil
		end
		dirty = true
	end)
	hooksecurefunc(m, "ClearAllPoints", function(self)
		if not busy then
			moduleAnchors[self] = nil
		end
	end)
	CaptureModuleAnchor(m)
end

local function HookNineSlice()
	local ns = objectiveTracker.NineSlice
	if not ns then
		return
	end
	for i = 1, ns:GetNumPoints() do
		local p, rel, rp, x, y = ns:GetPoint(i)
		if p and p:find("BOTTOM") then
			nsAnchor = { p, rel, rp, x or 0, y or 0 }
		end
	end
	hooksecurefunc(ns, "SetPoint", function(_, ...)
		if busy or type((...)) ~= "string" then
			return
		end
		local p, rel, rp, x, y = ParseSetPoint(...)
		if not p:find("BOTTOM") then
			return
		end
		nsAnchor = { p, rel or objectiveTracker, rp, x, y }
		dirty = true
		if attached then
			UpdateContentHeight()
			ApplyNineSlice()
		end
	end)
end

local function Attach()
	if attached or Blocked(objectiveTracker) then
		return
	end
	for _, m in ipairs(GetModules()) do
		if Blocked(m) then
			return
		end
	end

	visibleHeight = objectiveTracker:GetHeight()
	offset, target = 0, 0
	origClamped = objectiveTracker:IsClampedToScreen()
	objectiveTracker:SetClampedToScreen(false)

	scrollView:Show()
	attached = true
	for _, m in ipairs(GetModules()) do
		HookModule(m)
		m:SetParent(scrollView)
		ApplyModuleAnchor(m)
	end

	CaptureTrackerBase()
	StretchTracker()
	dirty = true
end

local function Detach()
	if not attached or Blocked(objectiveTracker) then
		return
	end
	for _, m in ipairs(GetModules()) do
		if Blocked(m) then
			return
		end
	end

	attached = false
	offset, target = 0, 0
	for _, m in ipairs(GetModules()) do
		m:SetParent(objectiveTracker)
		ApplyModuleAnchor(m)
	end
	RestoreNineSlice()
	shiftX = 0
	ApplyTrackerAnchors(false)
	busy = true
	if visibleHeight then
		objectiveTracker:SetHeight(visibleHeight)
	end
	busy = false
	if origClamped ~= nil then
		objectiveTracker:SetClampedToScreen(origClamped)
	end
	scrollView:Hide()
end

local function UpdateLayout()
	if not visibleHeight then
		return
	end
	local top = ClipTop()
	local p, rel, rp, x, y = scrollView:GetPoint(1)
	if
		scrollView:GetNumPoints() ~= 1
		or p ~= "TOPLEFT"
		or rel ~= objectiveTracker
		or rp ~= "TOPLEFT"
		or x ~= -LEFT_PAD
		or y ~= -top
	then
		scrollView:ClearAllPoints()
		scrollView:SetPoint("TOPLEFT", objectiveTracker, "TOPLEFT", -LEFT_PAD, -top)
	end
	local w, h = objectiveTracker:GetWidth() + LEFT_PAD + RIGHT_PAD, math.max(1, visibleHeight - top)
	local cw, ch = scrollView:GetSize()
	if math.abs(cw - w) > 0.01 or math.abs(ch - h) > 0.01 then
		scrollView:SetSize(w, h)
	end
	local level = objectiveTracker:GetFrameLevel() + 3
	if scrollView:GetFrameLevel() ~= level then
		scrollView:SetFrameLevel(level)
	end

	UpdateContentHeight()
	range = math.max(0, math.floor(contentHeight - visibleHeight + 0.5))
	if target > range then
		target = range
	end
	if offset > range then
		SetOffset(range, true)
	end
	ApplyNineSlice()

	local scrollable = range > 0 and objectiveTracker:IsVisible()

	local wantShift = 0
	local tr, sr = objectiveTracker:GetRight(), UIParent:GetRight()
	if tr and sr then
		local k = UIParent:GetEffectiveScale() / objectiveTracker:GetEffectiveScale()
		local baseRight = tr - shiftX
		local pad = scrollable and RIGHT_PAD or 0
		local overflow = baseRight + pad - sr * k
		wantShift = -math.max(0, math.ceil(overflow))
	end
	if wantShift ~= shiftX and #trackerBase > 0 and not Blocked(objectiveTracker) then
		shiftX = wantShift
		ApplyTrackerAnchors(true)
	end

	scrollView:EnableMouseWheel(scrollable)
	scrollBar:SetShown(scrollable)
	if scrollable then
		syncingScrollBar = true
		scrollBar:SetPanExtentPercentage(WHEEL_STEP / range)
		scrollBar:SetVisibleExtentPercentage(visibleHeight / contentHeight)
		scrollBar:SetScrollPercentage(offset / range, true)
		syncingScrollBar = false
	end
end

local elapsedAcc = 0
local function Tick(_, elapsed)
	if attached then
		Animate(elapsed)
	end
	elapsedAcc = elapsedAcc + elapsed
	if elapsedAcc < 0.1 and not dirty then
		return
	end
	elapsedAcc = 0
	dirty = false
	if not objectiveTracker then
		return
	end

	local want = not editMode and not IsDefaultPosition()
	if want and not attached then
		Attach()
	elseif not want and attached then
		Detach()
	end
	if not attached then
		return
	end

	for _, m in ipairs(GetModules()) do
		HookModule(m)
		if m:GetParent() ~= scrollView and not Blocked(m) then
			m:SetParent(scrollView)
			ApplyModuleAnchor(m)
		end
	end
	if not Blocked(objectiveTracker) then
		if objectiveTracker:IsClampedToScreen() then
			objectiveTracker:SetClampedToScreen(false)
		end
		if objectiveTracker:GetHeight() < TALL_HEIGHT - 1 then
			StretchTracker()
		end
	end
	UpdateLayout()
end

local function CreateScrollUi()
	scrollView = CreateFrame("Frame", "ObjectiveScrollViewport", objectiveTracker)
	scrollView:SetClipsChildren(true)
	scrollView:Hide()
	scrollView:SetScript("OnMouseWheel", function(_, delta)
		SetOffset(target - delta * WHEEL_STEP)
	end)

	scrollBar = CreateFrame("EventFrame", nil, scrollView, "MinimalScrollBar")
	scrollBar:SetFrameLevel(scrollView:GetFrameLevel() + 50)
	scrollBar:SetPoint("TOP", scrollView, "TOPRIGHT", -(SCROLLBAR_WIDTH / 2 + 2), -4)
	scrollBar:SetPoint("BOTTOM", scrollView, "BOTTOMRIGHT", -(SCROLLBAR_WIDTH / 2 + 2), 8)
	scrollBar:Hide()
	scrollBar:RegisterCallback("OnScroll", function(_, percentage)
		if syncingScrollBar then
			return
		end
		SetOffset(percentage * range, scrollBar:IsThumbMouseDown())
	end)

	local driver = CreateFrame("Frame")
	driver:SetScript("OnUpdate", Tick)
end

local function HookTracker()
	hooksecurefunc(objectiveTracker, "SetHeight", function(_, h)
		if busy then
			return
		end
		visibleHeight = h
		if attached then
			StretchTracker()
		end
		dirty = true
	end)
	hooksecurefunc(objectiveTracker, "SetPoint", function(_, ...)
		if busy or type((...)) ~= "string" then
			return
		end
		SetTrackerBase(ParseSetPoint(...))
		if attached then
			StretchTracker()
		end
		dirty = true
	end)
	hooksecurefunc(objectiveTracker, "ClearAllPoints", function()
		if not busy then
			wipe(trackerBase)
		end
	end)
	objectiveTracker:HookScript("OnShow", function()
		dirty = true
	end)
	objectiveTracker:HookScript("OnHide", function()
		dirty = true
	end)
	HookNineSlice()

	if EditModeManagerFrame then
		EditModeManagerFrame:HookScript("OnShow", function()
			editMode = true
			dirty = true
		end)
		EditModeManagerFrame:HookScript("OnHide", function()
			editMode = false
			dirty = true
		end)
		editMode = EditModeManagerFrame:IsShown()
	end
end

local function Initialize()
	if objectiveTracker or not ObjectiveTrackerFrame then
		return
	end
	objectiveTracker = ObjectiveTrackerFrame

	CreateScrollUi()
	HookTracker()
	dirty = true

	-- TODO: Find a way to get the addon to work when in default position
	if IsDefaultPosition() then
		Print(
			"the quest tracker is in its default spot, where Blizzard sizes it to the screen. Move it in Edit Mode to use your custom height + scrolling."
		)
	end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function()
	Initialize()
end)
