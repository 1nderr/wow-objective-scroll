-- ObjectiveScroll
-- Lets Blizzard's objective tracker lay out ALL of its contents (by giving it a tall frame),
-- then shows them through a scrolling window that sits under the (fixed) "All Objectives"
-- header and is as tall as the height you chose in Edit Mode.
--
-- Layout:
--   * ObjectiveTrackerFrame stays exactly where Blizzard/Edit Mode puts it; we only make it tall
--     and un-clamp it from the screen edges.
--   * The header and background stay children of the tracker (so the collapse button still works).
--   * The tracker's modules (Quests, Achievements, ...) are re-parented into our clip frame,
--     which starts just below the header. Scrolling slides the top module (the rest follow).
--   * The background is re-anchored so it never extends past the visible height.
--
-- Taint notes: we never replace Blizzard methods or write fields on Blizzard frames.
-- We only use hooksecurefunc post-hooks and plain widget calls, and skip anything that is
-- protected during combat.

local TALL_HEIGHT = 4000 -- layout height handed to the tracker so nothing gets truncated
local WHEEL_STEP = 45 -- pixels per mouse-wheel notch
local LEFT_PAD = 40 -- clip margin on the left (quest icons / background stick out)
local BAR_GAP = 10 -- gap between the tracker's right edge and the bar
local MIN_WIDTH, MAX_WIDTH = 2, 24
local DEFAULTS = {
	enabled = true,
	barWidth = 8,
	barColor = { 96 / 255, 96 / 255, 96 / 255 }, -- gray
}
local DB_VERSION = 2
local SMOOTHNESS = 14 -- higher = snappier glide, lower = floatier

local tracker -- ObjectiveTrackerFrame
local clip -- our clipping frame (child of the tracker)
local bar, thumb -- scroll bar widgets
local attached = false
local origClamped
local visibleHeight -- the height Blizzard wants (your Edit Mode height)
local offset = 0 -- current scroll offset (what's on screen)
local target = 0 -- where we're gliding to
local range = 0 -- max scroll offset
local contentHeight = 0
local moduleAnchors = {} -- [module] = { point, rel, relPoint, x, y } for modules anchored to the tracker top
local hookedModules = {}
local nsAnchor -- Blizzard's bottom anchor for the background: { point, rel, relPoint, x, y }
local trackerBase = {} -- tracker anchors exactly as Blizzard set them: list of { point, rel, relPoint, x, y }
local shiftX = 0 -- how far we slide the tracker left so the scroll bar fits on screen
local busy = false -- guards our own calls from our hooks
local editMode = false
local dirty = true
local barAnchoredWidth -- bar width the scroll bar was last anchored with (nil = re-anchor)
local ApplyBarStyle -- defined with the widgets; re-applies width/colour from settings
local BuildSettings -- defined with the settings page below

local function DB()
	ObjectiveScrollDB = ObjectiveScrollDB or {}
	local db = ObjectiveScrollDB
	if (db.version or 1) < DB_VERSION then
		db.barWidth = DEFAULTS.barWidth
		db.barColor = { unpack(DEFAULTS.barColor) }
		db.version = DB_VERSION
	end
	if db.enabled == nil then
		db.enabled = DEFAULTS.enabled
	end
	if type(db.barWidth) ~= "number" then
		db.barWidth = DEFAULTS.barWidth
	end
	if type(db.barColor) ~= "table" or #db.barColor < 3 then
		db.barColor = { unpack(DEFAULTS.barColor) }
	end
	return db
end

local function BarWidth()
	return math.max(MIN_WIDTH, math.min(MAX_WIDTH, math.floor(DB().barWidth + 0.5)))
end

-- clip margin on the right: room for the gap + the bar + a little slack
local function RightPad()
	return BAR_GAP + BarWidth() + 2
end

local function Print(msg)
	print("|cff66ccffObjectiveScroll:|r " .. msg)
end

local function Blocked(frame)
	return InCombatLockdown() and frame:IsProtected() and true or false
end

local function IsDefaultPosition()
	if tracker.IsInDefaultPosition then
		local ok, res = pcall(tracker.IsInDefaultPosition, tracker)
		if ok then
			return res
		end
	end
	return false
end

local function ClipTop()
	-- where the first module starts; header lives above this
	return (tonumber(tracker.topModulePadding) or 38) - 4
end

-- Normalise the many SetPoint call forms into point, rel, relPoint, x, y.
local function ParseSetPoint(p, a, b, c, d)
	local rel, rp, x, y
	if type(a) == "number" then -- (p, x, y)
		rel, rp, x, y = nil, p, a, b
	elseif type(b) == "number" then -- (p, rel, x, y)
		rel, rp, x, y = a, p, b, c
	else -- (p, rel, relPoint, x, y) / (p, rel) / (p)
		rel, rp, x, y = a, b or p, c, d
	end
	if type(rel) == "string" then
		rel = _G[rel]
	end
	return p:upper(), rel, (rp or p):upper(), x or 0, y or 0
end

local function GetModules()
	local list = {}
	if type(tracker.modules) == "table" then
		for _, m in ipairs(tracker.modules) do
			if type(m) == "table" and m.GetObjectType then
				list[#list + 1] = m
			end
		end
	end
	return list
end

---------------------------------------------------------------------------
-- Anchoring
---------------------------------------------------------------------------
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
		if p and p:find("TOP") and (rel == tracker or rel == clip or rel == nil) then
			moduleAnchors[m] = { p, tracker, rp, x or 0, (y or 0) - (attached and offset or 0) }
			return
		end
	end
end

local function UpdateContentHeight()
	local top = tracker:GetTop()
	contentHeight = 0
	if not top then
		return
	end
	local ns = tracker.NineSlice
	if nsAnchor and ns and ns:IsShown() and nsAnchor[2] and nsAnchor[2].GetBottom then
		local b = nsAnchor[2]:GetBottom()
		if b then
			-- the last module has been moved up by `offset`; undo that, add Blizzard's padding
			contentHeight = top - (b - offset) - nsAnchor[5]
		end
	end
end

-- Keep the background no taller than the visible window.
local function ApplyNineSlice()
	local ns = tracker.NineSlice
	if not (ns and nsAnchor and visibleHeight) then
		return
	end
	local h = math.min(contentHeight, visibleHeight)
	if h <= 0 then
		return
	end
	busy = true
	ns:SetPoint(nsAnchor[1], tracker, "TOP", nsAnchor[4], -h)
	busy = false
end

local function RestoreNineSlice()
	local ns = tracker.NineSlice
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
		end -- can't move protected frames in combat
	end
	offset = new
	ApplyAllModuleAnchors()
	dirty = true
end

-- Sets where to scroll to; glides there unless `instant`.
local function SetOffset(new, instant)
	target = math.max(0, math.min(range, math.floor(new + 0.5)))
	if instant and target ~= offset then
		ApplyOffset(target)
	end
end

-- Eases `offset` toward `target` each frame.
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

---------------------------------------------------------------------------
-- Tracker anchoring
-- Edit Mode anchors the tracker by whichever point is nearest (TOP*, BOTTOM*, or the middle,
-- depending on where you dropped it). When we stretch it to TALL_HEIGHT, a middle/bottom anchor
-- would make it grow upward off the screen, so we shift that anchor down to keep the top fixed.
---------------------------------------------------------------------------
local function SetTrackerBase(p, rel, rp, x, y)
	for i = #trackerBase, 1, -1 do
		if trackerBase[i][1] == p then
			table.remove(trackerBase, i)
		end
	end
	trackerBase[#trackerBase + 1] = { p, rel or tracker:GetParent(), rp, x, y }
end

local function CaptureTrackerBase()
	wipe(trackerBase)
	for i = 1, tracker:GetNumPoints() do
		local p, rel, rp, x, y = tracker:GetPoint(i)
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

-- True if the tracker is already anchored exactly as ApplyTrackerAnchors would anchor it.
local function TrackerAnchorsMatch(stretched)
	if tracker:GetNumPoints() ~= #trackerBase then
		return false
	end
	for i, b in ipairs(trackerBase) do
		local p, rel, rp, x, y = tracker:GetPoint(i)
		local wx, wy = b[4], b[5]
		if stretched then
			wx, wy = wx + shiftX, wy + VerticalShift(b[1])
		end
		if p ~= b[1] or rel ~= b[2] or rp ~= b[3]
			or math.abs((x or 0) - wx) > 0.01 or math.abs((y or 0) - wy) > 0.01 then
			return false
		end
	end
	return true
end

-- Re-anchoring a frame (even to the same spot) makes the game re-check what's under the
-- mouse, which closes and re-opens the hovered quest's tooltip. In a group Blizzard updates
-- the tracker many times a second, so only touch anchors when they actually differ.
local function ApplyTrackerAnchors(stretched)
	if #trackerBase == 0 or Blocked(tracker) or TrackerAnchorsMatch(stretched) then
		return
	end
	busy = true
	tracker:ClearAllPoints()
	for _, b in ipairs(trackerBase) do
		if stretched then
			tracker:SetPoint(b[1], b[2], b[3], b[4] + shiftX, b[5] + VerticalShift(b[1]))
		else
			tracker:SetPoint(b[1], b[2], b[3], b[4], b[5])
		end
	end
	busy = false
end

-- Make the tracker tall while keeping its top edge where Blizzard put it.
local function StretchTracker()
	if Blocked(tracker) then
		return
	end
	ApplyTrackerAnchors(true)
	if math.abs(tracker:GetHeight() - TALL_HEIGHT) > 0.01 then
		busy = true
		tracker:SetHeight(TALL_HEIGHT)
		busy = false
	end
end

---------------------------------------------------------------------------
-- Hooks (post-hooks only)
---------------------------------------------------------------------------
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
		if rel == nil or rel == clip then
			rel = tracker
		end
		if rel == tracker then
			moduleAnchors[self] = { p, tracker, rp, x, y }
			if attached then
				ApplyModuleAnchor(self)
			end
		else
			moduleAnchors[self] = nil -- chained below another module; follows it automatically
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
	local ns = tracker.NineSlice
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
		nsAnchor = { p, rel or tracker, rp, x, y }
		dirty = true
		if attached then
			UpdateContentHeight()
			ApplyNineSlice()
		end
	end)
end

---------------------------------------------------------------------------
-- Attach / detach
---------------------------------------------------------------------------
local function Attach()
	if attached or Blocked(tracker) then
		return
	end
	for _, m in ipairs(GetModules()) do
		if Blocked(m) then
			return
		end
	end

	visibleHeight = tracker:GetHeight()
	offset, target = 0, 0
	origClamped = tracker:IsClampedToScreen()
	tracker:SetClampedToScreen(false) -- a 4000px frame would otherwise be shoved up on screen

	clip:Show()
	attached = true
	for _, m in ipairs(GetModules()) do
		HookModule(m)
		m:SetParent(clip)
		ApplyModuleAnchor(m)
	end

	CaptureTrackerBase()
	StretchTracker()
	dirty = true
end

local function Detach()
	if not attached or Blocked(tracker) then
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
		m:SetParent(tracker)
		ApplyModuleAnchor(m)
	end
	RestoreNineSlice()
	shiftX = 0
	ApplyTrackerAnchors(false)
	busy = true
	if visibleHeight then
		tracker:SetHeight(visibleHeight)
	end
	busy = false
	if origClamped ~= nil then
		tracker:SetClampedToScreen(origClamped)
	end
	clip:Hide()
end

---------------------------------------------------------------------------
-- Clip window + scroll bar
---------------------------------------------------------------------------
local function UpdateLayout()
	if not visibleHeight then
		return
	end
	local top = ClipTop()
	-- Only touch the clip when something changed; re-anchoring it every update closes the
	-- hovered quest's tooltip for a frame (see ApplyTrackerAnchors).
	local p, rel, rp, x, y = clip:GetPoint(1)
	if clip:GetNumPoints() ~= 1 or p ~= "TOPLEFT" or rel ~= tracker or rp ~= "TOPLEFT"
		or x ~= -LEFT_PAD or y ~= -top then
		clip:ClearAllPoints()
		clip:SetPoint("TOPLEFT", tracker, "TOPLEFT", -LEFT_PAD, -top)
	end
	local w, h = tracker:GetWidth() + LEFT_PAD + RightPad(), math.max(1, visibleHeight - top)
	local cw, ch = clip:GetSize()
	if math.abs(cw - w) > 0.01 or math.abs(ch - h) > 0.01 then
		clip:SetSize(w, h)
	end
	local level = tracker:GetFrameLevel() + 3
	if clip:GetFrameLevel() ~= level then
		clip:SetFrameLevel(level)
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

	local scrollable = range > 0 and tracker:IsVisible()

	-- Slide the whole tracker left by exactly as much as the scroll bar would stick off the
	-- right edge of the screen (0 if it fits, or if there's no bar to show).
	local wantShift = 0
	if scrollable then
		local tr, sr = tracker:GetRight(), UIParent:GetRight()
		if tr and sr then
			local k = UIParent:GetEffectiveScale() / tracker:GetEffectiveScale()
			local baseRight = tr - shiftX -- where Blizzard/Edit Mode put it
			local overflow = baseRight + RightPad() - sr * k
			wantShift = -math.max(0, math.ceil(overflow))
		end
	end
	if wantShift ~= shiftX and #trackerBase > 0 and not Blocked(tracker) then
		shiftX = wantShift
		ApplyTrackerAnchors(true)
	end

	clip:EnableMouseWheel(scrollable)
	bar:SetShown(scrollable)
	if scrollable then
		-- bar sits just outside the tracker's right edge (BAR_GAP px past it), clear of the
		-- quest-item buttons. Leave a little room between the tracker and the screen edge.
		local w = BarWidth()
		if w ~= barAnchoredWidth then
			barAnchoredWidth = w
			bar:ClearAllPoints()
			bar:SetWidth(w)
			-- always just outside the tracker's right edge (the tracker is slid left if needed, below)
			bar:SetPoint("TOPLEFT", clip, "TOPRIGHT", -RightPad() + BAR_GAP, -4)
			bar:SetPoint("BOTTOMLEFT", clip, "BOTTOMRIGHT", -RightPad() + BAR_GAP, 8)
			thumb:SetWidth(w)
		end

		local barH = bar:GetHeight()
		local thumbH = math.max(24, barH * visibleHeight / contentHeight)
		thumb:SetHeight(thumbH)
		thumb:ClearAllPoints()
		thumb:SetPoint("TOP", bar, "TOP", 0, -(barH - thumbH) * (offset / range))
	end
end

---------------------------------------------------------------------------
-- Main driver (cheap, throttled)
---------------------------------------------------------------------------
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
	if not tracker then
		return
	end

	local want = DB().enabled and not editMode and not IsDefaultPosition()
	if want and not attached then
		Attach()
	elseif not want and attached then
		Detach()
	end
	if not attached then
		return
	end

	-- new modules, or Blizzard shrank / re-clamped the tracker: re-assert when allowed
	for _, m in ipairs(GetModules()) do
		HookModule(m)
		if m:GetParent() ~= clip and not Blocked(m) then
			m:SetParent(clip)
			ApplyModuleAnchor(m)
		end
	end
	if not Blocked(tracker) then
		if tracker:IsClampedToScreen() then
			tracker:SetClampedToScreen(false)
		end
		if tracker:GetHeight() < TALL_HEIGHT - 1 then
			StretchTracker()
		end
	end
	UpdateLayout()
end

---------------------------------------------------------------------------
-- Widgets
---------------------------------------------------------------------------
local function CreateWidgets()
	clip = CreateFrame("Frame", "ObjectiveScrollClipFrame", tracker)
	clip:SetClipsChildren(true)
	clip:SetSize(1, 1)
	clip:Hide()
	clip:SetScript("OnMouseWheel", function(_, delta)
		SetOffset(target - delta * WHEEL_STEP)
	end)

	bar = CreateFrame("Frame", nil, clip)
	bar:SetFrameLevel(clip:GetFrameLevel() + 50)
	bar:EnableMouse(true)
	bar:Hide()
	-- Pill shape: a solid middle plus a round cap at each end (cap = circle, bar-width across).
	local caps = {}
	local CIRCLE = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask"
	local SOLID = "Interface\\Buttons\\WHITE8X8"
	local function MakePill(frame, layer)
		local top = frame:CreateTexture(nil, layer)
		top:SetTexture(CIRCLE)
		top:SetTexCoord(0, 1, 0, 0.5) -- upper half of the circle
		top:SetPoint("TOPLEFT")
		top:SetPoint("TOPRIGHT")
		caps[#caps + 1] = top
		local bottom = frame:CreateTexture(nil, layer)
		bottom:SetTexture(CIRCLE)
		bottom:SetTexCoord(0, 1, 0.5, 1) -- lower half of the circle
		bottom:SetPoint("BOTTOMLEFT")
		bottom:SetPoint("BOTTOMRIGHT")
		caps[#caps + 1] = bottom
		local mid = frame:CreateTexture(nil, layer)
		mid:SetTexture(SOLID)
		mid:SetPoint("TOPLEFT", top, "BOTTOMLEFT")
		mid:SetPoint("BOTTOMRIGHT", bottom, "TOPRIGHT")
		return function(r, g, b, a)
			for _, t in ipairs({ top, mid, bottom }) do
				t:SetVertexColor(r, g, b, a)
			end
		end
	end

	local setTrackColor = MakePill(bar, "BACKGROUND")
	setTrackColor(0, 0, 0, 0.45)

	thumb = CreateFrame("Frame", nil, bar)
	thumb:EnableMouse(true)
	local setThumbColor = MakePill(thumb, "ARTWORK")
	-- colour from settings; a bit lighter while hovered
	local function SetThumbColor(hover)
		local c = DB().barColor
		local r, g, b = c[1], c[2], c[3]
		if hover then
			r, g, b = math.min(1, r + 0.12), math.min(1, g + 0.12), math.min(1, b + 0.12)
		end
		setThumbColor(r, g, b, 1)
	end
	ApplyBarStyle = function()
		local w = BarWidth()
		bar:SetWidth(w)
		thumb:SetWidth(w)
		for _, cap in ipairs(caps) do
			cap:SetHeight(w / 2)
		end
		SetThumbColor(thumb:IsMouseOver())
		dirty = true
	end
	ApplyBarStyle()
	thumb:SetScript("OnShow", function()
		SetThumbColor(false)
	end)
	thumb:SetScript("OnEnter", function()
		SetThumbColor(true)
	end)
	thumb:SetScript("OnLeave", function()
		SetThumbColor(false)
	end)

	local function CursorY(frame)
		local _, y = GetCursorPosition()
		return y / frame:GetEffectiveScale()
	end

	thumb:SetScript("OnMouseDown", function(self, button)
		if button ~= "LeftButton" then
			return
		end
		local startY, startOffset = CursorY(self), offset
		self:SetScript("OnUpdate", function()
			local free = bar:GetHeight() - self:GetHeight()
			if free > 0 then
				SetOffset(startOffset + (startY - CursorY(self)) * range / free, true)
			end
		end)
	end)
	thumb:SetScript("OnMouseUp", function(self)
		self:SetScript("OnUpdate", nil)
	end)

	bar:SetScript("OnMouseDown", function(self)
		local y = CursorY(self)
		local page = (visibleHeight or 200) * 0.8
		if y > (thumb:GetTop() or y) then
			SetOffset(target - page)
		else
			SetOffset(target + page)
		end
	end)

	-- driver lives on its own always-shown frame (clip is hidden while detached)
	local driver = CreateFrame("Frame")
	driver:SetScript("OnUpdate", Tick)
end

local function HookTracker()
	hooksecurefunc(tracker, "SetHeight", function(_, h)
		if busy then
			return
		end
		visibleHeight = h -- Blizzard's own height = your Edit Mode height
		if attached then
			StretchTracker()
		end -- re-stretch now so it never jumps for a frame
		dirty = true
	end)
	hooksecurefunc(tracker, "SetPoint", function(_, ...)
		if busy or type((...)) ~= "string" then
			return
		end
		SetTrackerBase(ParseSetPoint(...))
		if attached then
			StretchTracker()
		end
		dirty = true
	end)
	hooksecurefunc(tracker, "ClearAllPoints", function()
		if not busy then
			wipe(trackerBase)
		end
	end)
	tracker:HookScript("OnShow", function()
		dirty = true
	end)
	tracker:HookScript("OnHide", function()
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

local function TryInit()
	if tracker or not ObjectiveTrackerFrame then
		return
	end
	tracker = ObjectiveTrackerFrame
	CreateWidgets()
	HookTracker()
	dirty = true
	if IsDefaultPosition() then
		Print(
			"the quest tracker is in its default spot, where Blizzard sizes it to the screen. Move it in Edit Mode to use your custom height + scrolling."
		)
	end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:SetScript("OnEvent", function(_, event)
	if event == "PLAYER_REGEN_ENABLED" then
		dirty = true
	else
		DB()
		TryInit()
		if event == "PLAYER_LOGIN" then
			BuildSettings()
		end
	end
end)

---------------------------------------------------------------------------
-- Settings page (Options > AddOns > ObjectiveScroll)
---------------------------------------------------------------------------
local settingsCategory
local PRESETS = {
	{ "Gold", nil }, -- read from the "All Objectives" text
	{ "Brown", { 77 / 255, 59 / 255, 36 / 255 } },
	{ "Gray", { 96 / 255, 96 / 255, 96 / 255 } },
}

local function HeaderGold()
	local text = tracker and tracker.Header and tracker.Header.Text
	if text and text.GetTextColor then
		local r, g, b = text:GetTextColor()
		if r then
			return { r, g, b }
		end
	end
	return { 1, 0.82, 0 }
end

local function StyleChanged()
	if ApplyBarStyle then
		ApplyBarStyle()
	end
	dirty = true
end

function BuildSettings()
	if settingsCategory then
		return
	end
	local panel = CreateFrame("Frame")
	panel:Hide() -- so OnShow fires when the Settings window displays it
	panel.name = "ObjectiveScroll"
	local refreshers = {}

	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText("ObjectiveScroll")
	local sub = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
	sub:SetText("Scroll bar for the quest tracker. Changes apply instantly.")

	-- Enabled -------------------------------------------------------------
	local enable = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
	enable:SetPoint("TOPLEFT", sub, "BOTTOMLEFT", -2, -16)
	local enableLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	enableLabel:SetPoint("LEFT", enable, "RIGHT", 4, 0)
	enableLabel:SetText("Enable scrolling quest tracker")
	enable:SetScript("OnClick", function(self)
		DB().enabled = self:GetChecked() and true or false
		dirty = true
	end)
	refreshers[#refreshers + 1] = function()
		enable:SetChecked(DB().enabled)
	end

	-- Width ---------------------------------------------------------------
	local widthLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	widthLabel:SetPoint("TOPLEFT", enable, "BOTTOMLEFT", 2, -20)
	widthLabel:SetText("Bar width")

	local slider = CreateFrame("Slider", nil, panel)
	slider:SetOrientation("HORIZONTAL")
	slider:SetSize(240, 18)
	slider:SetPoint("TOPLEFT", widthLabel, "BOTTOMLEFT", 4, -10)
	slider:SetMinMaxValues(MIN_WIDTH, MAX_WIDTH)
	slider:SetValueStep(1)
	slider:SetObeyStepOnDrag(true)
	slider:EnableMouse(true)
	slider:EnableMouseWheel(true)
	local groove = slider:CreateTexture(nil, "BACKGROUND")
	groove:SetPoint("LEFT")
	groove:SetPoint("RIGHT")
	groove:SetHeight(6)
	groove:SetColorTexture(0, 0, 0, 0.6)
	local grooveEdge = slider:CreateTexture(nil, "BORDER")
	grooveEdge:SetPoint("TOPLEFT", groove, -1, 1)
	grooveEdge:SetPoint("BOTTOMRIGHT", groove, 1, -1)
	grooveEdge:SetColorTexture(0.4, 0.4, 0.4, 0.6)
	grooveEdge:SetDrawLayer("BACKGROUND", -1)
	local knob = slider:CreateTexture(nil, "ARTWORK")
	knob:SetSize(10, 18)
	knob:SetColorTexture(0.9, 0.75, 0.3, 1)
	slider:SetThumbTexture(knob)

	local lo = slider:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	lo:SetPoint("TOPLEFT", slider, "BOTTOMLEFT", 0, -2)
	lo:SetText(MIN_WIDTH .. "px")
	local hi = slider:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	hi:SetPoint("TOPRIGHT", slider, "BOTTOMRIGHT", 0, -2)
	hi:SetText(MAX_WIDTH .. "px")
	local val = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	val:SetPoint("LEFT", slider, "RIGHT", 12, 0)

	local syncing = false
	slider:SetScript("OnValueChanged", function(_, v)
		v = math.floor(v + 0.5)
		val:SetText(v .. " px")
		if syncing then
			return
		end
		DB().barWidth = v
		StyleChanged()
	end)
	slider:SetScript("OnMouseWheel", function(self, delta)
		self:SetValue(self:GetValue() + delta)
	end)
	refreshers[#refreshers + 1] = function()
		syncing = true
		slider:SetValue(BarWidth())
		val:SetText(BarWidth() .. " px")
		syncing = false
	end

	-- Colour ---------------------------------------------------------------
	local colorLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	colorLabel:SetPoint("TOPLEFT", slider, "BOTTOMLEFT", -4, -30)
	colorLabel:SetText("Bar colour")

	local function MakeSwatch(parent, size)
		local b = CreateFrame("Button", nil, parent)
		b:SetSize(size, size)
		local border = b:CreateTexture(nil, "BACKGROUND")
		border:SetAllPoints()
		border:SetColorTexture(0.6, 0.6, 0.6, 1)
		b.fill = b:CreateTexture(nil, "ARTWORK")
		b.fill:SetPoint("TOPLEFT", 2, -2)
		b.fill:SetPoint("BOTTOMRIGHT", -2, 2)
		local hl = b:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetColorTexture(1, 1, 1, 0.25)
		return b
	end

	local current = MakeSwatch(panel, 28)
	current:SetPoint("TOPLEFT", colorLabel, "BOTTOMLEFT", 0, -10)
	local currentText = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	currentText:SetPoint("LEFT", current, "RIGHT", 10, 0)

	local function SetColor(r, g, b)
		DB().barColor = { r, g, b }
		current.fill:SetColorTexture(r, g, b, 1)
		currentText:SetText(
			string.format(
				"Custom colour...   (RGB %d, %d, %d)",
				math.floor(r * 255 + 0.5),
				math.floor(g * 255 + 0.5),
				math.floor(b * 255 + 0.5)
			)
		)
		StyleChanged()
	end
	refreshers[#refreshers + 1] = function()
		local c = DB().barColor
		current.fill:SetColorTexture(c[1], c[2], c[3], 1)
		currentText:SetText(
			string.format(
				"Custom colour...   (RGB %d, %d, %d)",
				math.floor(c[1] * 255 + 0.5),
				math.floor(c[2] * 255 + 0.5),
				math.floor(c[3] * 255 + 0.5)
			)
		)
	end

	current:SetScript("OnClick", function()
		local c = DB().barColor
		local pr, pg, pb = c[1], c[2], c[3]
		local function OnChange()
			local r, g, b = ColorPickerFrame:GetColorRGB()
			SetColor(r, g, b)
		end
		local function OnCancel()
			SetColor(pr, pg, pb)
		end
		if ColorPickerFrame.SetupColorPickerAndShow then
			ColorPickerFrame:SetupColorPickerAndShow({
				r = pr,
				g = pg,
				b = pb,
				hasOpacity = false,
				swatchFunc = OnChange,
				cancelFunc = OnCancel,
			})
		else -- older picker API
			ColorPickerFrame.hasOpacity = false
			ColorPickerFrame.previousValues = { pr, pg, pb }
			ColorPickerFrame.func = OnChange
			ColorPickerFrame.cancelFunc = OnCancel
			ColorPickerFrame:SetColorRGB(pr, pg, pb)
			ColorPickerFrame:Hide()
			ColorPickerFrame:Show()
		end
	end)

	local presetLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	presetLabel:SetPoint("TOPLEFT", current, "BOTTOMLEFT", 0, -14)
	presetLabel:SetText("Presets:")
	local PER_ROW, COL_W, ROW_H = 3, 130, 30
	for i, p in ipairs(PRESETS) do
		local name, col = p[1], p[2]
		local sw = MakeSwatch(panel, 22)
		local c, r = (i - 1) % PER_ROW, math.floor((i - 1) / PER_ROW)
		sw:SetPoint("TOPLEFT", presetLabel, "BOTTOMLEFT", c * COL_W, -8 - r * ROW_H)
		local lbl = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		lbl:SetPoint("LEFT", sw, "RIGHT", 6, 0)
		lbl:SetText(name)
		sw:SetScript("OnClick", function()
			local c = col or HeaderGold()
			SetColor(c[1], c[2], c[3])
		end)
		refreshers[#refreshers + 1] = function()
			local c = col or HeaderGold()
			sw.fill:SetColorTexture(c[1], c[2], c[3], 1)
		end
	end

	-- Reset -----------------------------------------------------------------
	local reset = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	reset:SetSize(140, 24)
	reset:SetPoint("TOPLEFT", presetLabel, "BOTTOMLEFT", 0, -8 - math.ceil(#PRESETS / PER_ROW) * ROW_H - 16)
	reset:SetText("Reset to defaults")
	reset:SetScript("OnClick", function()
		DB().enabled = DEFAULTS.enabled
		DB().barWidth = DEFAULTS.barWidth
		DB().barColor = { unpack(DEFAULTS.barColor) }
		StyleChanged()
		for _, fn in ipairs(refreshers) do
			fn()
		end
	end)

	local hint = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	hint:SetPoint("TOPLEFT", reset, "BOTTOMLEFT", 0, -12)
	hint:SetText("Tip: the bar only appears when your quests don't all fit. /oscroll config opens this page.")

	local function RefreshAll()
		for _, fn in ipairs(refreshers) do
			fn()
		end
	end
	panel:SetScript("OnShow", RefreshAll)
	panel.OnRefresh = RefreshAll
	RefreshAll()

	if Settings and Settings.RegisterCanvasLayoutCategory then
		settingsCategory = Settings.RegisterCanvasLayoutCategory(panel, "ObjectiveScroll")
		Settings.RegisterAddOnCategory(settingsCategory)
	elseif InterfaceOptions_AddCategory then
		InterfaceOptions_AddCategory(panel)
		settingsCategory = panel
	end
end

local function OpenSettings()
	BuildSettings()
	if Settings and Settings.OpenToCategory and settingsCategory and settingsCategory.GetID then
		Settings.OpenToCategory(settingsCategory:GetID())
	elseif InterfaceOptionsFrame_OpenToCategory and settingsCategory then
		InterfaceOptionsFrame_OpenToCategory(settingsCategory)
		InterfaceOptionsFrame_OpenToCategory(settingsCategory)
	end
end

---------------------------------------------------------------------------
-- Slash command
---------------------------------------------------------------------------
SLASH_OBJECTIVESCROLL1 = "/oscroll"
SlashCmdList.OBJECTIVESCROLL = function(msg)
	msg = (msg or ""):lower():match("^%s*(.-)%s*$")
	if msg == "top" then
		SetOffset(0)
	elseif msg == "config" or msg == "options" or msg == "settings" then
		OpenSettings()
	elseif msg == "on" or msg == "off" or msg == "" then
		if msg == "" then
			DB().enabled = not DB().enabled
		else
			DB().enabled = (msg == "on")
		end
		dirty = true
		Print(DB().enabled and "enabled" or "disabled")
	else
		Print("/oscroll  - toggle   |  /oscroll on|off  |  /oscroll top  |  /oscroll config - settings")
	end
end
