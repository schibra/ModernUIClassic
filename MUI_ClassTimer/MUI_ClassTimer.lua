-- MUI_ClassTimer: Per-class buff/cooldown tracker displayed as icon rows above the cast/swing bar stack.
--
-- ┌─────────────────────────────────────────────────────────────────┐
-- │  Proc row  (large icons, top)  — hidden until proc fires        │
-- │  Maint row (small icons, mid)  — always visible, red = missing  │
-- │  CD row    (small icons, bot)  — always visible, sweep = on CD  │
-- └─────────────────────────────────────────────────────────────────┘
--
-- HOW IT WORKS
-- ────────────
-- On the first PLAYER_ENTERING_WORLD the module reads the registered profile for
-- the player's class, normalises it into an internal tracker list, and builds one
-- ClassTimerIcon frame per known spell. Icons are rebuilt whenever a new spell is
-- learned (LEARNED_SPELL_IN_TAB) so they appear automatically on level-up.
--
-- Each ClassTimerIcon runs one of five refresh modes (derived from the profile
-- during normalisation):
--
--   "cd"          CD sweep while on cooldown; idle otherwise.
--                 Add `track = "selfBuff"` or `"targetDebuff"` to show active
--                 duration before the CD sweep (the "Bloodrage pattern").
--
--   "selfBuff"    Maintenance: always visible; red tint when the player buff is
--                 absent, duration sweep while it is up.
--
--   "targetDebuff" Maintenance: always visible; grey with no target, red when
--                 the debuff is not on the target, duration sweep when it is.
--
--   "targetStack" Like targetDebuff but also shows a stack counter. Orange tint
--                 while partially stacked, white when full.
--
--   "proc"        Hidden by default. Appears with a fade-in + shimmer glow when
--                 the proc fires; disappears immediately when it expires.
--                 Detection is automatic: proc-row entries without an explicit
--                 condition use IsUsableSpell (right for opportunity procs like
--                 Overpower/Revenge that change spell usability on dodge). Entries
--                 with `track = "selfBuff"` use FindBuff instead (right for
--                 talent procs that manifest as visible buff auras). Pass a
--                 condition preset or a raw function for anything else.
--                 This row isn't DPS-only: `track = "selfBuff"` also works for
--                 short, critical tank/healer cooldowns (see Last Stand /
--                 Shield Wall in Warrior.lua) — a big glowing icon while the
--                 buff is active, gone the instant it ends. A
--                 `condition = {"playerHealth", X}` entry is the other
--                 pattern, for "use your emergency cooldown now" alerts.
--
-- ADDING A CLASS PROFILE
-- ──────────────────────
-- Create MUI_ClassTimer/Profiles/<ClassName>.lua (use Warrior.lua as a template)
-- and add it to ModernUI.toc AFTER MUI_ClassTimer\MUI_ClassTimer.lua. The profile
-- file calls RegisterClassTimerProfile with the uppercase English class name
-- returned by UnitClass("player") and a list of spell entries.
--
-- Entry fields:
--   spell       Spell name (string) or spell ID (number). Using the name is
--               recommended for Classic Era because IDs are rank-specific;
--               GetSpellCooldown("Execute") always resolves to the highest rank
--               the player knows, while the rank-1 ID would break at rank 5.
--               Both forms are supported: an ID is resolved to its name via
--               GetSpellInfo at load time, then the name is used for all
--               runtime API calls.
--
--   row         Which row the icon lives in. "proc" | "maint" | "cd" (default).
--
--   track       What to track as the active state. Optional.
--               "selfBuff"    — player has this buff
--               "targetDebuff" — target has this debuff
--               "targetStack" — target has this debuff; show stack counter
--               Required for maint row. Optional for cd row (enables the
--               duration-before-CD pattern). On proc row, switches detection
--               from IsUsableSpell to FindBuff (for talent/aura procs).
--
--   stacks      Maximum stacks for targetStack tracking. Default 1.
--
--   condition   When to show the icon (proc row) or an override for custom logic.
--               Built-in presets (table form):
--                 {"targetHealth", 0.20}  — target HP ≤ 20%
--                 {"playerHealth", 0.35}  — player HP ≤ 35%
--                 {"playerPower",  50}    — player rage/mana/energy ≥ 50
--                 {"usable"}             — IsUsableSpell (explicit; same as default)
--               Raw Lua: function() → bool   (power-user escape hatch)
--               On proc row without condition or track, defaults to {"usable"}.
--
--   buff        Override the buff name when it differs from the spell name.
--               Example: a spell named "Foo" that applies a buff called "Bar":
--                 { spell = "Foo", track = "selfBuff", buff = "Bar" }
--
--   debuff      Override the debuff name when it differs from the spell name.

-- ─── User options ─────────────────────────────────────────────────────────────
-- Change these values to adjust how icons behave outside of active combat.

-- Fade icons to a low opacity when the player is not in combat.
local FADE_OUT_OF_COMBAT  = true

-- Opacity of icons when out of combat (0.0 = invisible, 1.0 = fully opaque).
-- Only applies when FADE_OUT_OF_COMBAT is true.
local OUT_OF_COMBAT_ALPHA = 0.12

-- Hide icons completely when the player is resting (inside an inn or major city).
-- Takes priority over FADE_OUT_OF_COMBAT.
local HIDE_WHEN_RESTING   = true

-- Duration of the fade-in / fade-out transition in seconds.
local FADE_DURATION       = 0.5

-- ──────────────────────────────────────────────────────────────────────────────

local ICON_SIZE        = 30    -- cd and maint row icon size in pixels
local PROC_ICON_SIZE   = 46    -- proc row icons are larger so they stand out
local ICON_GAP         = 3     -- gap between icons in the same row (pixels)

-- Vertical position of each row's bottom edge, measured from the screen bottom.
-- The cast bar top sits at roughly 244 px; the swing bar fills the 13 px above it.
-- CD row bottom starts 4 px above the swing bar, then each row stacks upward with
-- a 4 px gap between them.
local CD_ROW_BOTTOM    = 264
local MAINT_ROW_BOTTOM = CD_ROW_BOTTOM    + ICON_SIZE + 4   -- 298
local PROC_ROW_BOTTOM  = MAINT_ROW_BOTTOM + ICON_SIZE + 4   -- 332

-- ─── Profile registry ─────────────────────────────────────────────────────────
-- Profiles are registered by individual class files (see Profiles/ folder).
-- The table is populated before OnEnable runs because TOC load order guarantees
-- profile files load after this file but well before PLAYER_ENTERING_WORLD fires.

MUI_ClassTimerProfiles = {}

-- RegisterClassTimerProfile(classKey, profile)
-- classKey: uppercase English class name as returned by UnitClass("player"),
--           e.g. "WARRIOR", "MAGE", "PRIEST".
-- profile:  ordered list of spell entry tables (see header for field reference).
function RegisterClassTimerProfile(classKey, profile)
    MUI_ClassTimerProfiles[classKey] = profile
end

-- ─── Profile normalisation ────────────────────────────────────────────────────
-- NormalizeEntry converts the author-facing profile format into the internal
-- tracker format consumed by ClassTimerIcon. This keeps the public API clean
-- and the engine simple: the engine only ever sees the resolved internal form.
--
-- Normalisation happens once in OnEnable (after spells are available) and the
-- result is stored in self._trackers. Subsequent _Rebuild calls reuse the same
-- tracker list — they only re-evaluate IsSpellKnown to decide which icons to
-- create, they do not re-normalise.

-- ResolveCondition turns a built-in preset table or a raw function into a plain
-- function() → bool that _RefreshProc can call directly. Each closure captures
-- its `value` by value (Lua closure semantics), so multiple entries with
-- different thresholds each get their own independent condition function.
local function ResolveCondition(cond, spellName)
    if type(cond) == "function" then return cond end
    if type(cond) ~= "table"    then return nil  end

    local condType = cond[1]
    local value    = cond[2]

    if condType == "targetHealth" then
        -- Show when target is at or below `value` fraction of max HP.
        -- Guard against no-target and dead-target to avoid divide-by-zero.
        return function()
            if not UnitExists("target") or UnitIsDead("target") then return false end
            local max = UnitHealthMax("target") or 0
            return max > 0 and UnitHealth("target") / max <= value
        end

    elseif condType == "playerHealth" then
        -- Show when the player's own HP is at or below `value` fraction.
        return function()
            local max = UnitHealthMax("player") or 0
            return max > 0 and UnitHealth("player") / max <= value
        end

    elseif condType == "playerPower" then
        -- Show when the player's rage/mana/energy is at or above `value`.
        return function()
            return (UnitPower("player") or 0) >= value
        end

    elseif condType == "usable" then
        -- Explicit IsUsableSpell preset. Identical to the default proc-row
        -- behaviour, but useful when you want to be self-documenting in a profile.
        return function()
            return IsUsableSpell(spellName) == true
        end
    end
    -- Unknown preset type → return nil; the entry will still be created but
    -- proc detection falls back to FindBuff.
end

local function NormalizeEntry(entry)
    -- Resolve spell ID → name so all downstream code works with names.
    -- In Classic Era, each spell rank has a different ID; using the name with
    -- GetSpellCooldown/IsUsableSpell always targets the highest rank the player
    -- knows, which is what we want.
    local spellName
    if type(entry.spell) == "number" then
        spellName = (GetSpellInfo(entry.spell))
        if not spellName then return nil end  -- ID not in DB or not accessible
    else
        spellName = entry.spell
    end

    local row   = entry.row   or "cd"  -- default to cooldown row
    local track = entry.track

    local t = { spell = spellName }

    if row == "proc" then
        t.mode = "proc"
        if entry.condition then
            -- Explicit condition: resolve preset or pass through raw function.
            t.condition = ResolveCondition(entry.condition, spellName)
        elseif track == "selfBuff" then
            -- Buff-based proc (e.g. a talent that applies a visible aura).
            -- No condition is set; _RefreshProc falls back to FindBuff(t.buff or t.spell).
            t.buff = entry.buff or spellName
        else
            -- Default for proc row: IsUsableSpell. Correct for opportunity
            -- procs like Overpower and Revenge that flip spell usability on dodge.
            t.condition = function() return IsUsableSpell(spellName) == true end
        end

    elseif row == "maint" then
        -- Maintenance icons are always visible and show presence/absence state.
        -- track is required; return nil to silently skip misconfigured entries.
        if track == "selfBuff" then
            t.mode = "selfBuff"
            t.buff = entry.buff or spellName
        elseif track == "targetDebuff" then
            t.mode = "targetDebuff"
            t.targetDebuff = entry.debuff or spellName
        elseif track == "targetStack" then
            t.mode = "targetStack"
            t.targetDebuff = entry.debuff or spellName
            t.maxStacks    = entry.stacks or 1
        else
            return nil  -- maint row with no track is invalid — skip
        end

    else
        -- CD row (default). With track, enables the "duration before CD" pattern:
        -- show active duration while the buff/debuff is up, then switch to CD sweep
        -- the moment it expires (see _RefreshCD). Without track, pure CD sweep only.
        if track == "selfBuff" then
            -- t.buff must be set explicitly so _RefreshCD knows to check for it.
            t.buff = entry.buff or spellName
        elseif track == "targetDebuff" then
            t.targetDebuff = entry.debuff or spellName
        end
        -- mode stays nil → Refresh() dispatches to _RefreshCD by default
    end

    return t
end

local function NormalizeProfile(profile)
    local result = {}
    for _, entry in ipairs(profile) do
        local t = NormalizeEntry(entry)
        if t then result[#result + 1] = t end
    end
    return result
end

-- ─── Helpers ──────────────────────────────────────────────────────────────────

-- Scan every tab of the player's spellbook for `spellName`. GetNumSpellTabs +
-- GetSpellTabInfo is the correct Classic Era approach: iterating raw slot indices
-- 1..MAX would stop at the first nil slot, which appears at tab boundaries and
-- would silently skip any spell in tab 2+.
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

-- Classic Era (1.13+) removed the `rank` return value from UnitBuff, shifting
-- all subsequent positions by one compared to 1.12. The correct signature is:
--   name, icon, count, debuffType, duration, expirationTime, caster, ...
local function FindBuff(name)
    for i = 1, 40 do
        local bname, _, _, _, duration, expiration = UnitBuff("player", i)
        if not bname then break end
        if bname == name then return duration, expiration end
    end
end

-- Same rank-shift caveat as FindBuff. Returns duration, expiration, count so
-- that targetStack mode can read the stack count in a single call.
local function FindDebuff(unit, name)
    for i = 1, 40 do
        local bname, _, count, _, duration, expiration = UnitDebuff(unit, i)
        if not bname then break end
        if bname == name then return duration, expiration, count or 1 end
    end
    return nil, nil, 0
end

-- ─── Single icon ──────────────────────────────────────────────────────────────
-- ClassTimerIcon wraps one WoW frame that holds an icon texture, a cooldown
-- sweep (CooldownFrameTemplate via the MUI Cooldown wrapper), a highlight glow,
-- and an optional stack counter. The icon is self-contained: call Refresh() on
-- every event tick and it drives its own visual state.
--
-- Frame names are intentionally nil so that repeated _Rebuild calls (on zone
-- change or spell learn) do not collide with WoW's global frame name registry.

class "ClassTimerIcon" : extends "Frame" {

    -- size: optional pixel size override. Proc icons pass PROC_ICON_SIZE; all
    --       others omit it and receive ICON_SIZE via the default.
    __init = function(self, parent, tracker, size)
        Frame.__init(self, "Frame", parent)
        self._tracker = tracker
        local sz = size or ICON_SIZE
        self:SetSize(sz, sz)

        -- Resolve icon texture from the spell name. GetSpellInfo returns the
        -- texture path as its third return value in Classic Era.
        local _, _, tex = GetSpellInfo(tracker.spell)

        self._iconTex = Texture(self, nil, "BACKGROUND")
        self._iconTex:FillParent()
        -- Clip 7% on each side to remove the ugly border WoW bakes into spell icons.
        self._iconTex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        if tex then self._iconTex:SetTexture(tex) end

        -- CooldownFrameTemplate sweep. Sits one level above the icon texture so
        -- the swipe draws on top of it. SetDrawEdge(false) hides the thin bright
        -- line at the sweep boundary which looks cluttered at small icon sizes.
        self._cd = Cooldown(self)
        self._cd:FillParent()
        self._cd:SetFrameLevel(self:GetFrameLevel() + 1)
        self._cd:SetDrawEdge(false)
        self._cd:SetSwipeColor(0, 0, 0, 0.8)

        -- Additive highlight glow drawn in the OVERLAY layer so it sits above the
        -- CD sweep. Used both as a static "active" indicator (maint/cd rows) and
        -- as the animated shimmer target for proc icons.
        self._glow = Texture(self, nil, "OVERLAY")
        self._glow:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
        self._glow:SetBlendMode("ADD")
        self._glow:FillParent()
        self._glow:SetAlpha(0)

        -- Stack counter for targetStack mode (e.g. Sunder Armor 0/5 → 5/5).
        -- Anchored to the bottom-centre of the icon, hidden for all other modes.
        self._stackText = FontString(self, nil, "OVERLAY")
        self._stackText:SetFont(MUI.FONT, 9, "OUTLINE")
        self._stackText:SetTextColor(1, 1, 1, 1)
        self._stackText:AlignParentBottom(1)
        self._stackText:CenterInParent()
        self._stackText:Hide()

        -- Proc icons start hidden and get a looping alpha animation on the glow
        -- so they pulse ("shimmer") while the proc window is open. The animation
        -- group is stored so _RefreshProc can Play/Stop it on visibility changes.
        -- BOUNCE looping makes the glow oscillate smoothly without a hard reset.
        local mode = tracker.mode or "cd"
        self._shimmerAG = nil
        if mode == "proc" then
            self:Hide()
            local ag = self._glow._native:CreateAnimationGroup()
            ag:SetLooping("BOUNCE")
            local pulse = ag:CreateAnimation("Alpha")
            pulse:SetFromAlpha(0.15)
            pulse:SetToAlpha(0.95)
            pulse:SetDuration(0.45)    -- each half-cycle; full period = 0.9 s
            pulse:SetSmoothing("IN_OUT")
            self._shimmerAG = ag
        end
    end;

    -- ── State helpers ──────────────────────────────────────────────────────

    -- SetVertexColor tints the icon texture. Used to signal state:
    -- white (1,1,1) = present/ready, red (1,.25,.25) = missing, grey (.5,.5,.5) = no target.
    _SetTint = function(self, r, g, b)
        self._iconTex._native:SetVertexColor(r, g, b, 1)
    end;

    -- Drive the CD sweep as a duration countdown rather than a cooldown.
    -- WoW's CooldownFrame takes a start time and a total duration; we reconstruct
    -- the start by subtracting duration from expirationTime.
    _SetBuffDuration = function(self, dur, exp)
        if dur and dur > 0 then
            self._cd:SetCooldown(exp - dur, dur)
        else
            self._cd:Clear()
        end
    end;

    -- ── Refresh entry point ────────────────────────────────────────────────
    -- Called by ModuleClassTimer:_RefreshAll on every relevant event.
    -- Dispatches to the mode-specific handler; returns true if icon visibility
    -- changed (used by _LayoutProcs to know when to repack the proc row).

    Refresh = function(self)
        local t    = self._tracker
        local mode = t.mode or "cd"

        if     mode == "proc"         then return self:_RefreshProc()
        elseif mode == "selfBuff"     then return self:_RefreshSelfBuff()
        elseif mode == "targetDebuff" then return self:_RefreshTargetDebuff()
        elseif mode == "targetStack"  then return self:_RefreshTargetStack()
        else                               return self:_RefreshCD()
        end
    end;

    -- ── Mode: proc ─────────────────────────────────────────────────────────
    -- Shows the icon (with fade-in + shimmer) when the proc is active;
    -- hides it immediately when the proc window closes.
    -- Detection priority:
    --   1. t.condition (function)  — explicit preset or raw Lua
    --   2. FindBuff(t.buff|spell)  — for buff-manifest procs (track = "selfBuff")
    --   (default IsUsableSpell is baked into t.condition at normalisation time)

    _RefreshProc = function(self)
        local t        = self._tracker
        local wasShown = self:IsShown()
        local active   = false

        if t.condition then
            active = t.condition()
        else
            active = FindBuff(t.buff or t.spell) ~= nil
        end

        if active then
            if not wasShown then
                -- Pre-set alpha to 0 before Show() so the frame is invisible for
                -- one frame; FadeIn then animates it to 1 over 0.2 s. Without this
                -- the frame would flash at full alpha for one tick before fading.
                self._native:SetAlpha(0)
                self:Show()
                self:FadeIn(0.2, 0, 1)
                if self._shimmerAG then self._shimmerAG:Play() end
            end
            -- Show remaining duration or active CD sweep while the proc is up.
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
            if wasShown then
                if self._shimmerAG then
                    self._shimmerAG:Stop()
                    self._glow:SetAlpha(0)
                end
                self:Hide()
            end
            self._cd:Clear()
            self._glow:SetAlpha(0)
        end

        return self:IsShown() ~= wasShown
    end;

    -- ── Mode: selfBuff (maintenance) ───────────────────────────────────────
    -- Always visible. Red tint when the player buff is absent (reminder to
    -- reapply); white with a duration sweep while the buff is running.

    _RefreshSelfBuff = function(self)
        local t        = self._tracker
        local dur, exp = FindBuff(t.buff or t.spell)

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

    -- ── Mode: targetDebuff (maintenance) ───────────────────────────────────
    -- Always visible. Grey when no target exists (no action possible), red when
    -- the debuff is missing from the target, white + duration sweep when present.

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

    -- ── Mode: targetStack (maintenance) ────────────────────────────────────
    -- Like targetDebuff but shows a live stack counter and uses an orange tint
    -- (instead of red) while partially stacked to distinguish "some progress
    -- made" from "nothing applied yet".

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
            -- Full stacks: white, show remaining duration.
            self:_SetTint(1, 1, 1)
            self._glow:SetAlpha(0)
            self:_SetBuffDuration(dur, exp)
        elseif count > 0 then
            -- Partial stacks: orange warning tint, still show current duration.
            self:_SetTint(1, 0.7, 0.25)
            self._glow:SetAlpha(0)
            self:_SetBuffDuration(dur, exp)
        else
            -- Not applied: red tint.
            self:_SetTint(1, 0.25, 0.25)
            self._glow:SetAlpha(0)
            self._cd:Clear()
        end
        return false
    end;

    -- ── Mode: cd (cooldown, default) ───────────────────────────────────────
    -- Always visible. Behaviour depends on which optional fields are set:
    --
    --   t.buff set        ("Bloodrage pattern") — when NOT on CD, check whether
    --                     the associated player buff is active and show its
    --                     remaining duration with a subtle glow. Once the buff
    --                     expires the spell goes on CD and the sweep takes over.
    --
    --   t.targetDebuff set — same pattern but tracking a debuff on the target
    --                     (e.g. Taunt: show the taunt debuff duration, then CD).
    --
    --   neither set       — pure CD sweep; idle while the spell is available.
    --
    -- The "on cooldown" threshold is 1.5 s to filter out the global cooldown
    -- (GCD ≈ 1.0–1.5 s) which would otherwise briefly show a sweep on every cast.

    _RefreshCD = function(self)
        local t          = self._tracker
        local cs, cd, ce = GetSpellCooldown(t.spell)
        -- ce == 1 means the cooldown is a real spell CD (not just GCD).
        local onCD       = ce == 1 and cd and cd > 1.5

        self:_SetTint(1, 1, 1)

        if onCD then
            self._cd:SetCooldown(cs, cd)
            self._glow:SetAlpha(0)
        elseif t.buff then
            local dur, exp = FindBuff(t.buff)
            if dur and dur > 0 then
                self:_SetBuffDuration(dur, exp)
                self._glow:SetAlpha(0.4)   -- subtle glow while buff is active
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
        -- Separate icon lists per row so _RefreshAll and _LayoutProcs can
        -- iterate only the relevant set without mode-checking every icon.
        self._procIcons  = {}
        self._maintIcons = {}
        self._cdIcons    = {}
        self._debug      = false
    end;

    OnEnable = function(self)
        local _, class = UnitClass("player")
        local rawProfile = MUI_ClassTimerProfiles[class]
        if not rawProfile then return end   -- no profile registered for this class

        -- Normalise once; rebuilds reuse self._trackers without re-normalising.
        self._trackers = NormalizeProfile(rawProfile)

        self._procContainer  = self:_MakeContainer("MUI_ClassTimerProcs",  PROC_ROW_BOTTOM, PROC_ICON_SIZE)
        self._maintContainer = self:_MakeContainer("MUI_ClassTimerMaint",  MAINT_ROW_BOTTOM)
        self._cdContainer    = self:_MakeContainer("MUI_ClassTimerCDs",    CD_ROW_BOTTOM)

        self:_Rebuild()
        self:_WireEvents()
    end;

    -- Container frames are invisible sizing/anchor helpers. Each row's icons are
    -- parented to its container so the whole row can be repositioned by moving
    -- one frame. iconSize sets the container height; width is computed by the
    -- layout helpers once the icon count is known.
    _MakeContainer = function(self, name, bottom, iconSize)
        local f = Frame("Frame", nil, name)
        f:SetFrameStrata("HIGH")
        f:SetSize(1, iconSize or ICON_SIZE)
        f:AlignParentBottom(bottom)
        return f
    end;

    -- _Rebuild is called on first enable and again on every PLAYER_ENTERING_WORLD
    -- and LEARNED_SPELL_IN_TAB event. It tears down all existing icons and
    -- recreates only those for spells the player currently knows. This keeps
    -- the icon list in sync after level-ups without tracking individual learn events.
    _Rebuild = function(self)
        for _, icon in ipairs(self._procIcons)  do icon:Hide() end
        for _, icon in ipairs(self._maintIcons) do icon:Hide() end
        for _, icon in ipairs(self._cdIcons)    do icon:Hide() end
        self._procIcons  = {}
        self._maintIcons = {}
        self._cdIcons    = {}

        for _, tracker in ipairs(self._trackers) do
            local mode = tracker.mode or "cd"

            -- A tracker is shown if the spell is in the spellbook OR if it has
            -- a condition and GetSpellInfo returns something (handles condition-
            -- based procs that may not appear in the standard spellbook scan).
            local known = IsSpellKnown(tracker.spell)
                       or (tracker.condition ~= nil and GetSpellInfo(tracker.spell) ~= nil)

            if known then
                local container = mode == "proc" and self._procContainer
                    or (mode == "selfBuff" or mode == "targetDebuff" or mode == "targetStack")
                        and self._maintContainer
                    or  self._cdContainer
                local iconSize = mode == "proc" and PROC_ICON_SIZE or nil
                local icon = ClassTimerIcon(container, tracker, iconSize)

                if mode == "proc" then
                    self._procIcons[#self._procIcons + 1] = icon
                elseif mode == "selfBuff" or mode == "targetDebuff" or mode == "targetStack" then
                    self._maintIcons[#self._maintIcons + 1] = icon
                else
                    self._cdIcons[#self._cdIcons + 1] = icon
                end
            end
        end

        -- CD and maint rows are fixed: laid out once and never repacked.
        -- Proc row is dynamic (icons appear/disappear) and handled by _LayoutProcs.
        self:_LayoutFixed(self._cdContainer,    self._cdIcons)
        self:_LayoutFixed(self._maintContainer, self._maintIcons)
        self:_RefreshAll()
        -- Snap to correct opacity without animation; smooth fades are reserved
        -- for PLAYER_REGEN events so zone transitions don't look jittery.
        self:_ApplyCombatState(false)
    end;

    -- Fixed-layout rows: evenly space icons left-to-right inside the container.
    -- The container width is set to exactly contain all icons so that a centered
    -- anchor (added by the edit mode system if ever integrated) works correctly.
    _LayoutFixed = function(self, container, icons)
        local n = #icons
        if n == 0 then return end
        container:SetWidth(n * ICON_SIZE + (n - 1) * ICON_GAP)
        for i, icon in ipairs(icons) do
            icon:ClearAllPoints()
            icon:SetPoint("LEFT", container, "LEFT", (i - 1) * (ICON_SIZE + ICON_GAP), 0)
        end
    end;

    -- Proc row layout: called after every _RefreshAll because visible icon count
    -- changes dynamically. Only shown icons are packed; hidden ones are skipped
    -- so there are no gaps in the row. Container width updates to match.
    _LayoutProcs = function(self)
        local shown = {}
        for _, icon in ipairs(self._procIcons) do
            if icon:IsShown() then shown[#shown + 1] = icon end
        end
        local n = #shown
        self._procContainer:SetWidth(math.max(1, n * PROC_ICON_SIZE + (n - 1) * ICON_GAP))
        for i, icon in ipairs(shown) do
            icon:ClearAllPoints()
            icon:SetPoint("LEFT", self._procContainer, "LEFT", (i - 1) * (PROC_ICON_SIZE + ICON_GAP), 0)
        end
    end;

    -- _ApplyCombatState evaluates the current combat and resting conditions and
    -- sets or animates all container frames to the appropriate opacity. Call with
    -- animate = false for instant snap (initial setup, zone transitions) and
    -- animate = true for the smooth fade on combat enter/leave and resting change.
    _ApplyCombatState = function(self, animate)
        if not self._procContainer then return end  -- called before OnEnable

        local inCombat = UnitAffectingCombat("player")
        local resting  = IsResting()

        local target
        if HIDE_WHEN_RESTING and resting then
            target = 0
        elseif FADE_OUT_OF_COMBAT and not inCombat then
            target = OUT_OF_COMBAT_ALPHA
        else
            target = 1
        end

        local containers = { self._procContainer, self._maintContainer, self._cdContainer }
        for _, c in ipairs(containers) do
            if animate then
                local from = c:GetAlpha()
                if target >= from then
                    c:FadeIn(FADE_DURATION, from, target)
                else
                    c:FadeOut(FADE_DURATION, from, target)
                end
            else
                c:SetAlpha(target)
            end
        end
    end;

    _WireEvents = function(self)
        local events = Frame()

        -- UNIT_AURA fires when any buff or debuff is added, removed, or updated
        -- on the player or their target. RegisterEventHandler passes (self, event, ...)
        -- to the handler, so the actual unit token is the third argument (evt = event name).
        events:RegisterEventHandler("UNIT_AURA", function(_, evt, unit)
            if unit == "player" or unit == "target" then self:_RefreshAll() end
        end)

        -- SPELL_UPDATE_COOLDOWN fires whenever any spell's cooldown state changes.
        -- Catches CD completions and new CDs without needing per-spell timers.
        events:RegisterEventHandler("SPELL_UPDATE_COOLDOWN", function()
            self:_RefreshAll()
        end)

        -- SPELL_UPDATE_USABLE fires when a spell's usability changes — this is the
        -- correct event for opportunity procs (Overpower, Revenge) that become
        -- available after an enemy dodge/parry/block rather than via a buff aura.
        events:RegisterEventHandler("SPELL_UPDATE_USABLE", function()
            self:_RefreshAll()
        end)

        -- UNIT_HEALTH drives condition-based proc checks that depend on HP thresholds,
        -- e.g. Execute at target ≤ 20%. Also covers playerHealth conditions.
        events:RegisterEventHandler("UNIT_HEALTH", function(_, evt, unit)
            if unit == "target" or unit == "player" then self:_RefreshAll() end
        end)

        -- Target change: reset all target-dependent icons (debuffs go grey,
        -- targetStack resets to 0, proc conditions re-evaluate for the new target).
        events:RegisterEventHandler("PLAYER_TARGET_CHANGED", function()
            self:_RefreshAll()
        end)

        -- LEARNED_SPELL_IN_TAB fires when the player trains or levels into a new
        -- spell. Rebuild so the newly available icon appears immediately.
        events:RegisterEventHandler("LEARNED_SPELL_IN_TAB", function()
            self:_Rebuild()
        end)

        -- Zone/login: rebuild after every loading screen. Blizzard resets spell
        -- state on zone transitions so this also handles any edge cases where the
        -- icon list drifted out of sync. _Rebuild calls _ApplyCombatState internally.
        events:RegisterEventHandler("PLAYER_ENTERING_WORLD", function()
            self:_Rebuild()
        end)

        -- Combat state: fade in on engage, fade out on disengage.
        -- PLAYER_REGEN_DISABLED fires when the player loses health/mana regeneration
        -- (i.e. enters combat). PLAYER_REGEN_ENABLED fires when regeneration resumes.
        events:RegisterEventHandler("PLAYER_REGEN_DISABLED", function()
            self:_ApplyCombatState(true)
        end)

        events:RegisterEventHandler("PLAYER_REGEN_ENABLED", function()
            self:_ApplyCombatState(true)
        end)

        -- Resting state: fires when the player enters or leaves an inn / major city.
        -- IsResting() reflects the new state at the time the event fires.
        events:RegisterEventHandler("PLAYER_UPDATE_RESTING", function()
            self:_ApplyCombatState(true)
        end)

        -- /classtimer           — toggle debug mode
        -- /classtimer show      — force all icons visible
        -- /classtimer hide      — return to normal display
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
        -- Repack proc row after refreshing so newly shown/hidden icons slot in.
        self:_LayoutProcs()
    end;

    -- Debug mode: force all icons visible regardless of game state so the layout
    -- can be inspected in-game without needing the right combat conditions. CDs
    -- reflect real state; proc icons skip the shimmer animation to keep things clean.
    -- Container alpha is forced to 1 so the icons are fully visible even when the
    -- out-of-combat fade or resting hide would normally suppress them.
    _ForceShowAll = function(self)
        -- Override opacity so icons are always fully visible in debug mode.
        self._procContainer:SetAlpha(1)
        self._maintContainer:SetAlpha(1)
        self._cdContainer:SetAlpha(1)

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

        -- Force-layout the proc row with all icons visible.
        local n = #self._procIcons
        self._procContainer:SetWidth(math.max(1, n * PROC_ICON_SIZE + (n - 1) * ICON_GAP))
        for i, icon in ipairs(self._procIcons) do
            icon:ClearAllPoints()
            icon:SetPoint("LEFT", self._procContainer, "LEFT", (i - 1) * (PROC_ICON_SIZE + ICON_GAP), 0)
        end
    end;

    _SetDebug = function(self, enable)
        self._debug = enable
        if enable then
            self:_ForceShowAll()
            MUI.Print("|cffffd200ClassTimer:|r debug ON — all icons forced visible.")
        else
            self:_RefreshAll()
            -- Restore the correct opacity for the current combat/resting state
            -- now that debug is no longer overriding it.
            self:_ApplyCombatState(false)
            MUI.Print("|cffffd200ClassTimer:|r debug OFF.")
        end
    end;
}
