-- MUI_ClassTimer: Per-class buff/cooldown tracker as icon rows above the bar stack.
--
-- Three rows (bottom → top):
--   CD row        (264): always-visible cooldown icons
--   Maintenance   (292): always-visible; warns (red tint) when a buff/debuff is missing
--   Proc row      (320): conditional icons — appear only when actionable
--
-- Tracker modes:
--   "cd"          always show when learned; CD sweep while on cooldown
--   "selfBuff"    always show; red tint when the player buff is missing, duration sweep when up
--   "targetDebuff" always show; grey when no target, red tint if debuff absent, duration when up
--   "targetStack" like targetDebuff but shows a stack counter (e.g. Sunder Armor)
--   "proc"        show only when a buff is active or a condition() returns true
--
-- Adding a class: add an entry to CLASS_TRACKERS keyed by the uppercase English
-- class name returned by UnitClass("player").

local ICON_SIZE        = 30
local ICON_GAP         = 3
local CD_ROW_BOTTOM    = 264              -- 4 px above swingbar top (~260)
local MAINT_ROW_BOTTOM = CD_ROW_BOTTOM    + ICON_SIZE + 4
local PROC_ROW_BOTTOM  = MAINT_ROW_BOTTOM + ICON_SIZE + 4

-- ─── Per-class tracker definitions ────────────────────────────────────────────
-- spell:       name used for GetSpellCooldown and icon texture lookup
-- mode:        see header (default "cd")
-- buff:        player buff name (selfBuff / cd-with-buff; defaults to spell)
-- targetDebuff: debuff name to check on target (targetDebuff / targetStack)
-- maxStacks:   for targetStack mode, the number of stacks to consider "full"
-- condition:   function() → bool; used by proc mode instead of buff lookup
-- ──────────────────────────────────────────────────────────────────────────────
local CLASS_TRACKERS = {
    WARRIOR = {
        -- Proc row ─────────────────────────────────────────────────────────────
        { spell = "Overpower", mode = "proc" },
        { spell = "Revenge",   mode = "proc" },
        {
            spell = "Execute", mode = "proc",
            condition = function()
                return UnitExists("target")
                    and not UnitIsDead("target")
                    and (UnitHealthMax("target") or 0) > 0
                    and UnitHealth("target") / UnitHealthMax("target") <= 0.20
            end,
        },

        -- Maintenance row ──────────────────────────────────────────────────────
        { spell = "Battle Shout",       mode = "selfBuff" },
        { spell = "Demoralizing Shout", mode = "targetDebuff", targetDebuff = "Demoralizing Shout" },
        { spell = "Thunder Clap",       mode = "targetDebuff", targetDebuff = "Thunder Clap" },
        { spell = "Rend",               mode = "targetDebuff", targetDebuff = "Rend" },
        { spell = "Sunder Armor",       mode = "targetStack",  targetDebuff = "Sunder Armor", maxStacks = 5 },

        -- CD row ───────────────────────────────────────────────────────────────
        -- Entries with buff/targetDebuff show active duration, then CD sweep after expiry.
        { spell = "Bloodrage",          buff = "Bloodrage" },
        { spell = "Mortal Strike" },
        { spell = "Bloodthirst" },
        { spell = "Shield Slam" },
        { spell = "Whirlwind" },
        { spell = "Sweeping Strikes",   buff = "Sweeping Strikes" },
        { spell = "Berserker Rage",     buff = "Berserker Rage" },
        { spell = "Death Wish",         buff = "Death Wish" },
        { spell = "Recklessness",       buff = "Recklessness" },
        { spell = "Last Stand",         buff = "Last Stand" },
        { spell = "Shield Wall",        buff = "Shield Wall" },
        { spell = "Shield Block",       buff = "Shield Block" },
        { spell = "Pummel" },
        { spell = "Taunt",              targetDebuff = "Taunt" },
        { spell = "Mocking Blow",       targetDebuff = "Mocking Blow" },
        { spell = "Challenging Shout",  targetDebuff = "Challenging Shout" },
    },
}

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function IsSpellKnown(spellName)
    for t = 1, GetNumSpellTabs() do
        local _, _, offset, numSlots = GetSpellTabInfo(t)
        for i = offset + 1, offset + numSlots do
            if GetSpellBookItemName(i, BOOKTYPE_SPELL) == spellName then
                return true
            end
        end
    end
    return false
end

-- Classic Era (1.13+) UnitBuff: name, icon, count, debuffType, duration, expirationTime, caster
local function FindBuff(name)
    for i = 1, 40 do
        local bname, _, _, _, duration, expiration = UnitBuff("player", i)
        if not bname then break end
        if bname == name then return duration, expiration end
    end
end

-- Classic Era UnitDebuff: name, icon, count, debuffType, duration, expirationTime, caster
local function FindDebuff(unit, name)
    for i = 1, 40 do
        local bname, _, count, _, duration, expiration = UnitDebuff(unit, i)
        if not bname then break end
        if bname == name then return duration, expiration, count or 1 end
    end
    return nil, nil, 0
end

-- ─── Single icon ──────────────────────────────────────────────────────────────

-- Icon frame names are omitted (nil) so rebuilds don't conflict with WoW's
-- global frame name registry.
class "ClassTimerIcon" : extends "Frame" {

    __init = function(self, parent, tracker)
        Frame.__init(self, "Frame", parent)
        self._tracker = tracker
        self:SetSize(ICON_SIZE, ICON_SIZE)

        local _, _, tex = GetSpellInfo(tracker.spell)

        self._iconTex = Texture(self, nil, "BACKGROUND")
        self._iconTex:FillParent()
        self._iconTex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        if tex then self._iconTex:SetTexture(tex) end

        self._cd = Cooldown(self)
        self._cd:FillParent()
        self._cd:SetFrameLevel(self:GetFrameLevel() + 1)
        self._cd:SetDrawEdge(false)
        self._cd:SetSwipeColor(0, 0, 0, 0.8)

        self._glow = Texture(self, nil, "OVERLAY")
        self._glow:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
        self._glow:SetBlendMode("ADD")
        self._glow:FillParent()
        self._glow:SetAlpha(0)

        -- Stack counter for targetStack mode (Sunder Armor etc.)
        self._stackText = FontString(self, nil, "OVERLAY")
        self._stackText:SetFont(MUI.FONT, 9, "OUTLINE")
        self._stackText:SetTextColor(1, 1, 1, 1)
        self._stackText:AlignParentBottom(1)
        self._stackText:CenterInParent()
        self._stackText:Hide()

        local mode = tracker.mode or "cd"
        if mode == "proc" then self:Hide() end
    end;

    -- ── state helpers ──────────────────────────────────────────────────────

    _SetTint = function(self, r, g, b)
        self._iconTex._native:SetVertexColor(r, g, b, 1)
    end;

    _SetBuffDuration = function(self, dur, exp)
        if dur and dur > 0 then
            self._cd:SetCooldown(exp - dur, dur)
        else
            self._cd:Clear()
        end
    end;

    -- ── Refresh ────────────────────────────────────────────────────────────

    Refresh = function(self)
        local t    = self._tracker
        local mode = t.mode or "cd"

        if mode == "proc" then
            return self:_RefreshProc()
        elseif mode == "selfBuff" then
            return self:_RefreshSelfBuff()
        elseif mode == "targetDebuff" then
            return self:_RefreshTargetDebuff()
        elseif mode == "targetStack" then
            return self:_RefreshTargetStack()
        else
            return self:_RefreshCD()
        end
    end;

    _RefreshProc = function(self)
        local t       = self._tracker
        local wasShown = self:IsShown()
        local active  = false

        if t.condition then
            active = t.condition()
        else
            active = FindBuff(t.buff or t.spell) ~= nil
        end

        if active then
            if not wasShown then self:Show() end
            self._glow:SetAlpha(0.65)
            if not t.condition then
                local dur, exp = FindBuff(t.buff or t.spell)
                self:_SetBuffDuration(dur, exp)
            else
                local cs, cd, ce = GetSpellCooldown(t.spell)
                if ce == 1 and cd and cd > 1.5 then
                    self._cd:SetCooldown(cs, cd)
                else
                    self._cd:Clear()
                end
            end
        else
            if wasShown then self:Hide() end
            self._cd:Clear()
            self._glow:SetAlpha(0)
        end

        return self:IsShown() ~= wasShown
    end;

    _RefreshSelfBuff = function(self)
        local t           = self._tracker
        local dur, exp    = FindBuff(t.buff or t.spell)

        if dur then
            self:_SetTint(1, 1, 1)
            self._glow:SetAlpha(0)
            self:_SetBuffDuration(dur, exp)
        else
            -- Missing — red tint, no sweep
            self:_SetTint(1, 0.25, 0.25)
            self._glow:SetAlpha(0)
            self._cd:Clear()
        end
        return false
    end;

    _RefreshTargetDebuff = function(self)
        local t = self._tracker
        if not UnitExists("target") or UnitIsDead("target") then
            self:_SetTint(0.5, 0.5, 0.5)
            self._cd:Clear()
            self._glow:SetAlpha(0)
            return false
        end

        local dur, exp = FindDebuff("target", t.targetDebuff)
        if dur then
            self:_SetTint(1, 1, 1)
            self._glow:SetAlpha(0)
            self:_SetBuffDuration(dur, exp)
        else
            self:_SetTint(1, 0.25, 0.25)
            self._glow:SetAlpha(0)
            self._cd:Clear()
        end
        return false
    end;

    _RefreshTargetStack = function(self)
        local t = self._tracker
        self._stackText:Show()

        if not UnitExists("target") or UnitIsDead("target") then
            self:_SetTint(0.5, 0.5, 0.5)
            self._cd:Clear()
            self._glow:SetAlpha(0)
            self._stackText:SetText("0")
            return false
        end

        local dur, exp, count = FindDebuff("target", t.targetDebuff)
        local max = t.maxStacks or 1
        self._stackText:SetText(count)

        if count >= max then
            self:_SetTint(1, 1, 1)
            self._glow:SetAlpha(0)
            self:_SetBuffDuration(dur, exp)
        elseif count > 0 then
            -- Partially stacked — mild warning tint
            self:_SetTint(1, 0.7, 0.25)
            self._glow:SetAlpha(0)
            self:_SetBuffDuration(dur, exp)
        else
            self:_SetTint(1, 0.25, 0.25)
            self._glow:SetAlpha(0)
            self._cd:Clear()
        end
        return false
    end;

    _RefreshCD = function(self)
        local t       = self._tracker
        local cs, cd, ce = GetSpellCooldown(t.spell)
        local onCD    = ce == 1 and cd and cd > 1.5

        self:_SetTint(1, 1, 1)

        if onCD then
            self._cd:SetCooldown(cs, cd)
            self._glow:SetAlpha(0)
        elseif t.buff then
            local dur, exp = FindBuff(t.buff)
            if dur and dur > 0 then
                self:_SetBuffDuration(dur, exp)
                self._glow:SetAlpha(0.4)
            else
                self._cd:Clear()
                self._glow:SetAlpha(0)
            end
        elseif t.targetDebuff then
            local dur, exp = FindDebuff("target", t.targetDebuff)
            if dur and dur > 0 then
                self:_SetBuffDuration(dur, exp)
                self._glow:SetAlpha(0.4)
            else
                self._cd:Clear()
                self._glow:SetAlpha(0)
            end
        else
            self._cd:Clear()
            self._glow:SetAlpha(0)
        end
        return false
    end;
}

-- ─── Module ───────────────────────────────────────────────────────────────────

object "ModuleClassTimer" : extends "Module" {

    __init = function(self)
        Module.__init(self, "ClassTimer")
        self._procIcons  = {}
        self._maintIcons = {}
        self._cdIcons    = {}
        self._debug      = false
    end;

    OnEnable = function(self)
        local _, class = UnitClass("player")
        local trackers = CLASS_TRACKERS[class]
        if not trackers then return end

        self._trackers = trackers

        self._procContainer  = self:_MakeContainer("MUI_ClassTimerProcs",  PROC_ROW_BOTTOM)
        self._maintContainer = self:_MakeContainer("MUI_ClassTimerMaint",  MAINT_ROW_BOTTOM)
        self._cdContainer    = self:_MakeContainer("MUI_ClassTimerCDs",    CD_ROW_BOTTOM)

        self:_Rebuild()
        self:_WireEvents()
    end;

    _MakeContainer = function(self, name, bottom)
        local f = Frame("Frame", nil, name)
        f:SetFrameStrata("HIGH")
        f:SetSize(1, ICON_SIZE)
        f:AlignParentBottom(bottom)
        return f
    end;

    _Rebuild = function(self)
        for _, icon in ipairs(self._procIcons)  do icon:Hide() end
        for _, icon in ipairs(self._maintIcons) do icon:Hide() end
        for _, icon in ipairs(self._cdIcons)    do icon:Hide() end
        self._procIcons  = {}
        self._maintIcons = {}
        self._cdIcons    = {}

        for _, tracker in ipairs(self._trackers) do
            local mode  = tracker.mode or "cd"
            local known = IsSpellKnown(tracker.spell)
                       or (tracker.condition ~= nil and GetSpellInfo(tracker.spell) ~= nil)

            if known then
                local icon = ClassTimerIcon(
                    mode == "proc"  and self._procContainer
                    or (mode == "selfBuff" or mode == "targetDebuff" or mode == "targetStack")
                        and self._maintContainer
                    or  self._cdContainer,
                    tracker
                )
                if mode == "proc" then
                    self._procIcons[#self._procIcons + 1] = icon
                elseif mode == "selfBuff" or mode == "targetDebuff" or mode == "targetStack" then
                    self._maintIcons[#self._maintIcons + 1] = icon
                else
                    self._cdIcons[#self._cdIcons + 1] = icon
                end
            end
        end

        self:_LayoutFixed(self._cdContainer,   self._cdIcons)
        self:_LayoutFixed(self._maintContainer, self._maintIcons)
        self:_RefreshAll()
    end;

    -- Fixed row: laid out once, never repacked at runtime.
    _LayoutFixed = function(self, container, icons)
        local n = #icons
        if n == 0 then return end
        container:SetWidth(n * ICON_SIZE + (n - 1) * ICON_GAP)
        for i, icon in ipairs(icons) do
            icon:ClearAllPoints()
            icon:SetPoint("LEFT", container, "LEFT", (i - 1) * (ICON_SIZE + ICON_GAP), 0)
        end
    end;

    -- Proc row: repacked each refresh (icons appear/disappear).
    _LayoutProcs = function(self)
        local shown = {}
        for _, icon in ipairs(self._procIcons) do
            if icon:IsShown() then shown[#shown + 1] = icon end
        end
        local n = #shown
        self._procContainer:SetWidth(math.max(1, n * ICON_SIZE + (n - 1) * ICON_GAP))
        for i, icon in ipairs(shown) do
            icon:ClearAllPoints()
            icon:SetPoint("LEFT", self._procContainer, "LEFT", (i - 1) * (ICON_SIZE + ICON_GAP), 0)
        end
    end;

    _WireEvents = function(self)
        local events = Frame()

        events:RegisterEventHandler("UNIT_AURA", function(_, unit)
            if unit == "player" or unit == "target" then self:_RefreshAll() end
        end)

        events:RegisterEventHandler("SPELL_UPDATE_COOLDOWN", function()
            self:_RefreshAll()
        end)

        events:RegisterEventHandler("UNIT_HEALTH", function(_, unit)
            if unit == "target" then self:_RefreshAll() end
        end)

        events:RegisterEventHandler("PLAYER_TARGET_CHANGED", function()
            self:_RefreshAll()
        end)

        events:RegisterEventHandler("LEARNED_SPELL_IN_TAB", function()
            self:_Rebuild()
        end)

        events:RegisterEventHandler("PLAYER_ENTERING_WORLD", function()
            self:_Rebuild()
        end)

        -- /classtimer          → toggle debug
        -- /classtimer show     → force-show all icons
        -- /classtimer hide     → return to normal
        ChatCommand("classtimer", function(_, msg)
            local cmd = strtrim(msg or ""):lower()
            if     cmd == "show" then self:_SetDebug(true)
            elseif cmd == "hide" then self:_SetDebug(false)
            else                      self:_SetDebug(not self._debug)
            end
        end)
    end;

    _RefreshAll = function(self)
        if self._debug then self:_ForceShowAll() return end
        for _, icon in ipairs(self._cdIcons)    do icon:Refresh() end
        for _, icon in ipairs(self._maintIcons) do icon:Refresh() end
        for _, icon in ipairs(self._procIcons)  do icon:Refresh() end
        self:_LayoutProcs()
    end;

    _ForceShowAll = function(self)
        local function showDebug(icon)
            icon:Show()
            local cs, cd, ce = GetSpellCooldown(icon._tracker.spell)
            if ce == 1 and cd and cd > 1.5 then
                icon._cd:SetCooldown(cs, cd)
            else
                icon._cd:Clear()
            end
            icon:_SetTint(1, 1, 1)
            icon._glow:SetAlpha(0.5)
        end

        for _, icon in ipairs(self._cdIcons)    do showDebug(icon) end
        for _, icon in ipairs(self._maintIcons) do showDebug(icon) end
        for _, icon in ipairs(self._procIcons)  do showDebug(icon) end

        -- Layout proc row with all icons forced visible.
        local n = #self._procIcons
        self._procContainer:SetWidth(math.max(1, n * ICON_SIZE + (n - 1) * ICON_GAP))
        for i, icon in ipairs(self._procIcons) do
            icon:ClearAllPoints()
            icon:SetPoint("LEFT", self._procContainer, "LEFT", (i - 1) * (ICON_SIZE + ICON_GAP), 0)
        end
    end;

    _SetDebug = function(self, enable)
        self._debug = enable
        if enable then
            self:_ForceShowAll()
            MUI.Print("|cffffd200ClassTimer:|r debug ON — all icons forced visible.")
        else
            self:_RefreshAll()
            MUI.Print("|cffffd200ClassTimer:|r debug OFF.")
        end
    end;
}
