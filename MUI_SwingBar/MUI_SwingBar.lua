-- MUI_SwingBar: Auto-attack swing timers, melee and ranged.
-- Uses the same castbar atlas skin (pill background/border/fill) as MUI_CastBar so
-- it reads as part of the same bar stack rather than a bolted-on debug overlay.
-- Each bar fills left → right over the relevant weapon's attack speed.
-- Melee bar appears on the first melee swing after entering combat; hides on leaving combat.
-- Ranged bar appears the moment auto-repeat (Auto Shot / Shoot / Throw) starts.
-- The two share one screen position — a character is only ever meleeing or
-- ranged-attacking, never both — but stay separate frames/state internally.
-- Sits 2.5 px above the cast bar (default cast bar top ≈ 244.5 px from screen bottom).

local ATLAS       = MUI_AtlasRegistry.CastBar
local FILL_REGION = "FillingStandard"

local BAR_WIDTH  = 186   -- content width; matches the player cast bar
local BAR_HEIGHT = 9     -- content height; matches the player cast bar's default

local MELEE_BOTTOM  = 247   -- 2.5 px gap above the cast bar top
local RANGED_BOTTOM = MELEE_BOTTOM

-- Two combat-log events for the same physical swing (Cleave/Sweeping Strikes hitting a
-- second target) land within the same tick — ignore a repeat reset that close together.
local SWING_DEBOUNCE = 0.1

-- "On next swing" abilities consume the pending auto-attack swing and land it
-- as SPELL_DAMAGE/SPELL_MISSED instead of SWING_DAMAGE/SWING_MISSED, but they
-- still restart the melee swing timer just like a normal white attack.
--
-- Extra-attack procs (Windfury Totem/Weapon, Sword Specialization, Hand of
-- Justice) are the opposite case: they land as an ordinary SWING_DAMAGE/
-- SWING_MISSED bonus swing, always with the mainhand weapon, and they *also*
-- reset the melee swing timer rather than being "free" hits on the side.
local ON_SWING_ABILITIES = {
    ["Heroic Strike"]  = true,
    ["Cleave"]         = true,
    ["Maul"]           = true,
    ["Raptor Strike"]  = true,
    ["Revenge"]        = true,
    ["Riposte"]        = true,
}

object "ModuleSwingBar" : extends "Module" {

    __init = function(self)
        Module.__init(self, "SwingBar")
    end;

    OnEnable = function(self)
        self._pendingExtraAttacks = 0
        self._mainNext = nil   -- predicted next mainhand swing time (dual-wield disambiguation)
        self._offNext  = nil   -- predicted next offhand swing time (dual-wield disambiguation)
        self:_Build()
        self:_WireEvents()
    end;

    _Build = function(self)
        self._melee  = self:_BuildBar("MUI_SwingBar", MELEE_BOTTOM)
        self._ranged = self:_BuildBar("MUI_RangedSwingBar", RANGED_BOTTOM)
    end;

    _BuildBar = function(self, name, bottom)
        local state = { barWidth = BAR_WIDTH }

        state.frame = Frame("Frame", nil, name)
        state.frame:SetSize(BAR_WIDTH + 4, BAR_HEIGHT + 4)
        state.frame:SetFrameStrata("HIGH")
        state.frame:AlignParentBottom(bottom)
        state.frame:Hide()

        state.bg = Texture(state.frame, nil, "BACKGROUND")
        state.bg:SetAtlas(ATLAS, "Background", true)
        state.bg:SetSize(BAR_WIDTH + 2, BAR_HEIGHT + 2)
        state.bg:CenterInParent()

        -- Fill width + texcoord crop update every frame while swinging, at fractional
        -- precision; disable pixel-grid snapping so it grows smoothly, matching CastBar.
        state.fill = Texture(state.frame, nil, "BORDER")
        state.fill:SetAtlas(ATLAS, "FillingStandard", true)
        state.fill:AlignLeft(state.bg, 1)
        state.fill:SetHeight(BAR_HEIGHT)
        state.fill:SetWidth(1)
        state.fill:SetSubpixelRendering(true)

        state.border = Texture(state.frame, nil, "ARTWORK")
        state.border:SetAtlas(ATLAS, "Frame", true)
        state.border:SetSize(BAR_WIDTH + 4, BAR_HEIGHT + 4)
        state.border:CenterInParent()

        -- Countdown text, centered just below the bar
        state.timeText = FontString(state.frame, nil, "OVERLAY")
        state.timeText:SetFont(MUI.FONT, 9)
        state.timeText:SetTextColor(1, 1, 1, 1)
        state.timeText:SetShadowOffset(1, -1)
        state.timeText:Below(state.frame, 1)

        state.frame:SetScript("OnUpdate", function() self:_UpdateBar(state) end)

        return state
    end;

    _WireEvents = function(self)
        self._events = Frame()

        self._events:RegisterEventHandler("COMBAT_LOG_EVENT_UNFILTERED", function()
            self:_OnCombatLog()
        end)

        self._events:RegisterEventHandler("START_AUTOREPEAT_SPELL", function()
            self:_OnRangedStart()
        end)

        self._events:RegisterEventHandler("STOP_AUTOREPEAT_SPELL", function()
            self._ranged.frame:Hide()
            self._ranged.start = nil
        end)

        -- Hide when leaving combat or zoning in
        self._events:RegisterEventHandler("PLAYER_REGEN_ENABLED", function()
            self:_Reset()
        end)

        self._events:RegisterEventHandler("PLAYER_ENTERING_WORLD", function()
            self:_Reset()
        end)

        -- /swingbar — force-show the melee bar at half fill to verify position; /swingbar hide to dismiss
        ChatCommand("swingbar", function(_, msg)
            if msg == "hide" then
                self:_Reset()
                MUI.Print("|cffffd200SwingBar:|r hidden.")
            else
                self:_SetProgress(self._melee, 0.5)
                self._melee.frame:Show()
                MUI.Print("|cffffd200SwingBar:|r forced visible at y=" .. MELEE_BOTTOM
                    .. ". Type /swingbar hide to dismiss.")
            end
        end)
    end;

    _Reset = function(self)
        self._melee.frame:Hide()
        self._melee.start = nil
        self._ranged.frame:Hide()
        self._ranged.start = nil
        self._pendingExtraAttacks = 0
        self._mainNext = nil
        self._offNext  = nil
    end;

    _OnCombatLog = function(self)
        local _, event, _, sourceGUID, _, _, _, _, _, _, _, _, spellName, _, amount = CombatLogGetCurrentEventInfo()
        if sourceGUID ~= UnitGUID("player") then return end

        if event == "SWING_DAMAGE" or event == "SWING_MISSED" then
            if self._pendingExtraAttacks > 0 then
                self._pendingExtraAttacks = self._pendingExtraAttacks - 1
                -- Always mainhand, and resets the timer just like a normal swing —
                -- skip the dual-wield guesser so it can't misclassify this as offhand.
                local mainSpeed = UnitAttackSpeed("player")
                mainSpeed = (mainSpeed and mainSpeed > 0) and mainSpeed or 2.0
                self:_OnSwing(self._melee, mainSpeed)
            else
                self:_OnMeleeSwing()
            end
        elseif event == "SPELL_EXTRA_ATTACKS" then
            self._pendingExtraAttacks = self._pendingExtraAttacks + (amount or 0)
        elseif (event == "SPELL_DAMAGE" or event == "SPELL_MISSED") and ON_SWING_ABILITIES[spellName] then
            self:_OnSwing(self._melee)   -- these always consume the mainhand swing
        elseif event == "RANGE_DAMAGE" or event == "RANGE_MISSED" then
            local speed = UnitRangedDamage("player")
            self:_OnSwing(self._ranged, (speed and speed > 0) and speed or 2.0)
        end
    end;

    -- Classic Era's combat log predates the isOffHand flag (added in Patch 6.0.2), so a
    -- plain SWING_DAMAGE/SWING_MISSED never says which hand fired. Single-weapon and
    -- two-handed characters have no offhand at all, so there's nothing to disambiguate.
    -- True dual-wielders are classified by whichever hand's predicted next-swing time
    -- this event lands closest to; the guess self-corrects every time either hand fires.
    _OnMeleeSwing = function(self)
        local mainSpeed, offSpeed = UnitAttackSpeed("player")
        mainSpeed = (mainSpeed and mainSpeed > 0) and mainSpeed or 2.0

        if not offSpeed then
            self:_OnSwing(self._melee, mainSpeed)
            return
        end

        local now = GetTime()
        local mainDist = self._mainNext and math.abs(now - self._mainNext)
        local offDist  = self._offNext  and math.abs(now - self._offNext)

        local isMain
        if mainDist and offDist then
            isMain = mainDist <= offDist
        elseif mainDist then
            isMain = true
        elseif offDist then
            isMain = false
        else
            -- First classified swing this fight: bias to mainhand, and seed a
            -- same-cadence offhand guess so the next swing has both baselines.
            isMain = true
            self._offNext = now + offSpeed
        end

        if isMain then
            self:_OnSwing(self._melee, mainSpeed)
        else
            self._offNext = now + offSpeed
        end
    end;

    _OnRangedStart = function(self)
        local speed = UnitRangedDamage("player")
        self:_OnSwing(self._ranged, (speed and speed > 0) and speed or 2.0)
    end;

    _OnSwing = function(self, state, speed)
        local now = GetTime()
        if state.start and (now - state.start) < SWING_DEBOUNCE then return end

        if not speed then
            local mainSpeed = UnitAttackSpeed("player")
            speed = (mainSpeed and mainSpeed > 0) and mainSpeed or 2.0
        end

        state.start    = now
        state.duration = speed
        self:_SetProgress(state, 0)
        state.timeText:SetText(string.format("%.1f", speed))
        state.frame:Show()

        -- Bars share one screen slot — whichever attack type just fired owns it.
        if state == self._melee then
            self._mainNext = now + speed
            self._ranged.frame:Hide()
        elseif state == self._ranged then
            self._melee.frame:Hide()
        end
    end;

    _UpdateBar = function(self, state)
        if not state.start then return end
        local elapsed = GetTime() - state.start
        local progress = elapsed / state.duration
        if progress > 1 then progress = 1 end
        self:_SetProgress(state, progress)

        local remaining = state.duration - elapsed
        if remaining < 0 then remaining = 0 end
        state.timeText:SetText(string.format("%.1f", remaining))
    end;

    -- Mirrors CastBar's _SetProgress: crop the atlas fill region rather than
    -- just scaling its width, so the pill's rounded caps render correctly.
    _SetProgress = function(self, state, progress)
        if progress < 0 then progress = 0 end
        if progress > 1 then progress = 1 end
        local w = progress * state.barWidth
        if w < 1 then w = 1 end
        state.fill:SetWidth(w)
        local info = ATLAS:GetRegion(FILL_REGION)
        local cropRight = info.left + (info.right - info.left) * progress
        state.fill:SetTexCoord(info.left, cropRight, info.top, info.bottom)
    end;

}
