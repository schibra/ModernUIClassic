-- MUI_ClassTimer profile: Warrior
--
-- Covers all three specs (Arms, Fury, Protection). Spells the player hasn't
-- learned are silently skipped, so a fresh level-1 character loading this
-- profile is safe — icons appear automatically as spells are trained.
--
-- HOW TO READ THIS FILE
-- ─────────────────────
-- Spells are grouped below into three tables — PROC, MAINT, CD — one per
-- icon row. Which table an entry lives in IS its row; you don't set `row`
-- yourself. Each entry is otherwise a plain table with these fields (all
-- optional except `spell`):
--
--   spell       The spell name as it appears in the spellbook. This is the
--               safest form for Classic Era — it always resolves to the
--               highest rank the player knows. Spell IDs are also accepted
--               (number instead of string) if you prefer them.
--
--   track       What to track as the active state:
--                 "selfBuff"     — a buff on the player
--                 "targetDebuff" — a debuff on the current target
--                 "targetStack"  — a stacking debuff on the target (shows counter)
--               On the CD row, track enables the "duration before CD" pattern:
--               the icon shows how long the buff/debuff has left, then switches
--               to a CD sweep the moment it expires.
--               On the PROC row, track = "selfBuff" shows the icon only while
--               that buff is active (see Last Stand / Shield Wall below) —
--               a big glowing timer for a short, critical buff.
--
--   stacks      For track = "targetStack": how many stacks = full. Default 1.
--
--   condition   When to show a PROC-row icon. Built-in presets:
--                 {"targetHealth", 0.20}  target HP ≤ 20%
--                 {"playerHealth", 0.35}  player HP ≤ 35%
--                 {"playerPower",  50}    player rage/mana ≥ 50
--                 {"usable"}             IsUsableSpell (default when omitted)
--               Or a raw function:  condition = function() return ... end
--               `playerHealth` is how a healer profile would flag "use an
--               emergency cooldown now."
--
--   buff        Override buff name when it differs from spell name (rare).
--   debuff      Override debuff name when it differs from spell name (rare).
--
-- ADDING OR REMOVING SPELLS
-- ──────────────────────────
-- To add a spell: copy an existing entry into the table for the row you want
-- (PROC, MAINT, or CD) and change `spell` (and `track` / `condition` if
-- needed). Order within a table determines left-to-right display order.
--
-- To remove a spell: delete its entry or comment it out with --.
--
-- To add a class: duplicate this file, rename it (e.g. Mage.lua), change the
-- first argument of RegisterClassTimerProfile to "MAGE", and populate the
-- three tables below. Add the new file to ModernUI.toc after
-- MUI_ClassTimer\MUI_ClassTimer.lua.

-- ── Proc row ───────────────────────────────────────────────────────────────
-- Hidden by default; pops up with a fade-in and pulsing glow, at a larger
-- size (PROC_ICON_SIZE) so it catches the eye during hectic combat.
--
-- Overpower and Revenge do NOT create a buff aura; the game tracks their
-- availability internally and reflects it via IsUsableSpell. The default
-- proc behaviour (no condition, no track) uses IsUsableSpell automatically.
--
-- Execute uses a health threshold condition instead — the ability is always
-- "usable" in the IsUsableSpell sense (it just fails to cast with no target or
-- too much HP), so we drive it from the target's health fraction directly.
--
-- The proc row isn't only for DPS opportunism. Last Stand and Shield Wall are
-- Protection's emergency buttons — they live here (with track = "selfBuff")
-- instead of quietly on the CD row so the big glowing icon is impossible to
-- miss while it's active, and vanishes the instant it ends. A healer profile
-- would use the same track = "selfBuff" proc pattern for its own short,
-- critical cooldowns.
--
-- Concussion Blow (Protection rune, Season of Discovery): a stun worth
-- flagging the instant it's available, same as Overpower/Revenge — an
-- opportunity to lock down a dangerous mob, not a rotational cooldown.
local PROC = {
    { spell = "Overpower" },
    { spell = "Revenge" },
    { spell = "Execute", condition = {"targetHealth", 0.20} },

    { spell = "Last Stand",  track = "selfBuff" },
    { spell = "Shield Wall", track = "selfBuff" },

    { spell = "Concussion Blow" },
}

-- ── Maintenance row ──────────────────────────────────────────────────────────
-- Always-visible reminders. Red tint = the effect is missing and should be
-- reapplied. Duration sweep = the effect is up and shows time remaining.
-- Target debuffs go grey (instead of red) when no target exists.
local MAINT = {
    -- Battle Shout: personal/party buff. Should be up at all times in combat.
    { spell = "Battle Shout", track = "selfBuff" },

    -- Demoralizing Shout: reduces target's attack power. Reapply when it drops off.
    { spell = "Demoralizing Shout", track = "targetDebuff" },

    -- Thunder Clap: slows target's attack speed. Arms/Prot use this regularly.
    { spell = "Thunder Clap", track = "targetDebuff" },

    -- Rend: a damage-over-time debuff. Worth maintaining for sustained DPS.
    { spell = "Rend", track = "targetDebuff" },

    -- Sunder Armor: stacks up to 5 times for -2500 armour at full stacks.
    -- The icon shows orange while partially stacked and white at 5/5.
    { spell = "Sunder Armor", track = "targetStack", stacks = 5 },
}

-- ── CD row ───────────────────────────────────────────────────────────────────
-- Always visible. `track` entries use the "duration before CD" pattern: while
-- the buff/debuff is active the icon shows remaining duration with a subtle
-- glow; once it expires the standard CD sweep takes over. Entries without
-- `track` show only the CD sweep.
local CD = {
    -- Bloodrage: grants rage at the cost of some HP, applies a self buff.
    { spell = "Bloodrage", track = "selfBuff" },

    -- Core rotational abilities (no associated buff/debuff — pure CD tracking).
    { spell = "Mortal Strike"  },
    { spell = "Bloodthirst"    },
    { spell = "Shield Slam"    },
    { spell = "Whirlwind"      },
    { spell = "Pummel"         },   -- interrupt
    { spell = "Shield Bash"    },   -- interrupt, requires a shield

    -- Tank mobility / utility CDs — no buff or debuff to track, but a
    -- Protection warrior wants a constant reminder of whether these are up.
    { spell = "Intercept" },   -- gap closer, also strong threat generation
    { spell = "Intervene" },   -- redirect an incoming attack away from an ally

    -- Stance / combat CDs with associated self buffs.
    { spell = "Sweeping Strikes", track = "selfBuff" },
    { spell = "Berserker Rage",   track = "selfBuff" },
    { spell = "Death Wish",       track = "selfBuff" },
    { spell = "Recklessness",     track = "selfBuff" },

    -- Shield Block: a self-buff CD used routinely rather than saved for an
    -- emergency, so a quiet CD-row icon fits better than the proc row's
    -- big glowing treatment (unlike Last Stand/Shield Wall above).
    { spell = "Shield Block", track = "selfBuff" },

    -- Disarm: removes the target's weapon for a few seconds — high-value
    -- tank utility against hard-hitting weapon-based mobs.
    { spell = "Disarm", track = "targetDebuff" },

    -- Taunt effects: track the debuff on the target so you know when to re-taunt.
    { spell = "Taunt",             track = "targetDebuff" },
    { spell = "Mocking Blow",      track = "targetDebuff" },
    { spell = "Challenging Shout", track = "targetDebuff" },
}

-- ── Assembly ─────────────────────────────────────────────────────────────────
-- Stamp each entry with the row implied by its table, then flatten into the
-- single list RegisterClassTimerProfile expects.
local function AddRow(profile, row, entries)
    for _, entry in ipairs(entries) do
        entry.row = row
        profile[#profile + 1] = entry
    end
end

local profile = {}
AddRow(profile, "proc",  PROC)
AddRow(profile, "maint", MAINT)
AddRow(profile, "cd",    CD)

RegisterClassTimerProfile("WARRIOR", profile)
