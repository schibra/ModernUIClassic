-- MUI_ClassTimer profile: Warrior
--
-- Covers all three specs (Arms, Fury, Protection). Spells the player hasn't
-- learned are silently skipped, so a fresh level-1 character loading this
-- profile is safe — icons appear automatically as spells are trained.
--
-- HOW TO READ THIS FILE
-- ─────────────────────
-- Each entry is a table with these fields (all optional except `spell`):
--
--   spell       The spell name as it appears in the spellbook. This is the
--               safest form for Classic Era — it always resolves to the
--               highest rank the player knows. Spell IDs are also accepted
--               (number instead of string) if you prefer them.
--
--   row         Where the icon lives:
--                 "proc"  — hidden until the proc fires, then appears with a
--                           fade-in and pulsing glow. Removed when the window closes.
--                 "maint" — always visible; red when missing, duration sweep when up.
--                 "cd"    — always visible; CD sweep while on cooldown.
--                           (default when row is omitted)
--
--   track       What to track as the active state:
--                 "selfBuff"     — a buff on the player
--                 "targetDebuff" — a debuff on the current target
--                 "targetStack"  — a stacking debuff on the target (shows counter)
--               On the cd row, track enables the "duration before CD" pattern:
--               the icon shows how long the buff/debuff has left, then switches
--               to a CD sweep the moment it expires.
--
--   stacks      For track = "targetStack": how many stacks = full. Default 1.
--
--   condition   When to show a proc-row icon. Built-in presets:
--                 {"targetHealth", 0.20}  target HP ≤ 20%
--                 {"playerHealth", 0.35}  player HP ≤ 35%
--                 {"playerPower",  50}    player rage/mana ≥ 50
--                 {"usable"}             IsUsableSpell (default when omitted)
--               Or a raw function:  condition = function() return ... end
--
--   buff        Override buff name when it differs from spell name (rare).
--   debuff      Override debuff name when it differs from spell name (rare).
--
-- ADDING OR REMOVING SPELLS
-- ──────────────────────────
-- To add a spell: copy an existing entry in the appropriate section and change
-- `spell` (and `track` / `condition` if needed). Order within a row determines
-- left-to-right display order.
--
-- To remove a spell: delete its entry or comment it out with --.
--
-- To add a class: duplicate this file, rename it (e.g. Mage.lua), change the
-- first argument of RegisterClassTimerProfile to "MAGE", and populate the
-- entries. Add the new file to ModernUI.toc after MUI_ClassTimer\MUI_ClassTimer.lua.

RegisterClassTimerProfile("WARRIOR", {

    -- ── Proc row ───────────────────────────────────────────────────────────
    -- Proc icons are hidden by default and pop up when the proc fires.
    -- They are displayed at a larger size (PROC_ICON_SIZE) so they catch the
    -- eye during hectic combat without cluttering the default view.
    --
    -- Overpower and Revenge do NOT create a buff aura; the game tracks their
    -- availability internally and reflects it via IsUsableSpell. The default
    -- proc behaviour (no condition, no track) uses IsUsableSpell automatically.
    --
    -- Execute uses a health threshold condition instead — the ability is always
    -- "usable" in the IsUsableSpell sense (it just fails to cast with no target or
    -- too much HP), so we drive it from the target's health fraction directly.

    { spell = "Overpower", row = "proc" },
    { spell = "Revenge",   row = "proc" },
    { spell = "Execute",   row = "proc", condition = {"targetHealth", 0.20} },


    -- ── Maintenance row ────────────────────────────────────────────────────
    -- Always-visible reminders. Red tint = the effect is missing and should be
    -- reapplied. Duration sweep = the effect is up and shows time remaining.
    -- Target debuffs go grey (instead of red) when no target exists.

    -- Battle Shout: personal/party buff. Should be up at all times in combat.
    { spell = "Battle Shout", row = "maint", track = "selfBuff" },

    -- Demoralizing Shout: reduces target's attack power. Reapply when it drops off.
    { spell = "Demoralizing Shout", row = "maint", track = "targetDebuff" },

    -- Thunder Clap: slows target's attack speed. Arms/Prot use this regularly.
    { spell = "Thunder Clap", row = "maint", track = "targetDebuff" },

    -- Rend: a damage-over-time debuff. Worth maintaining for sustained DPS.
    { spell = "Rend", row = "maint", track = "targetDebuff" },

    -- Sunder Armor: stacks up to 5 times for -2500 armour at full stacks.
    -- The icon shows orange while partially stacked and white at 5/5.
    { spell = "Sunder Armor", row = "maint", track = "targetStack", stacks = 5 },


    -- ── CD row ─────────────────────────────────────────────────────────────
    -- Always visible. `track` entries use the "duration before CD" pattern:
    -- while the buff/debuff is active the icon shows remaining duration with a
    -- subtle glow; once it expires the standard CD sweep takes over.
    -- Entries without `track` show only the CD sweep.
    --
    -- row = "cd" is the default and can be omitted; it is written out on the
    -- first few entries for clarity and omitted on the rest.

    -- Bloodrage: grants rage at the cost of some HP, applies a self buff.
    { spell = "Bloodrage", row = "cd", track = "selfBuff" },

    -- Core rotational abilities (no associated buff/debuff — pure CD tracking).
    { spell = "Mortal Strike"  },
    { spell = "Bloodthirst"    },
    { spell = "Shield Slam"    },
    { spell = "Whirlwind"      },
    { spell = "Pummel"         },   -- interrupt

    -- Stance / combat CDs with associated self buffs.
    { spell = "Sweeping Strikes", track = "selfBuff" },
    { spell = "Berserker Rage",   track = "selfBuff" },
    { spell = "Death Wish",       track = "selfBuff" },
    { spell = "Recklessness",     track = "selfBuff" },

    -- Defensive / survival CDs with associated self buffs.
    { spell = "Last Stand",   track = "selfBuff" },
    { spell = "Shield Wall",  track = "selfBuff" },
    { spell = "Shield Block", track = "selfBuff" },

    -- Taunt effects: track the debuff on the target so you know when to re-taunt.
    { spell = "Taunt",             track = "targetDebuff" },
    { spell = "Mocking Blow",      track = "targetDebuff" },
    { spell = "Challenging Shout", track = "targetDebuff" },
})
