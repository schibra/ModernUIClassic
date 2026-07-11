-- Bag / bank sorting for Classic Era.
--
-- Era has no C_Container.SortBags(), so we implement it in Lua. One click runs
-- the whole thing to completion: the target order is computed ONCE (after
-- stacking), then we drive the bags toward that frozen target across
-- BAG_UPDATE_DELAYED ticks until the live layout matches it.
--
-- Why not a single sweep: each PickupContainerItem move makes the server lock
-- the slots it touches until it confirms, and a chained pickup onto a locked
-- slot is dropped. So we only ever fire DISJOINT moves within one frame (each
-- physical slot used at most once), then wait for the locks to clear and do
-- the next batch. Exposes the singleton MUI_BagSorter:SortBags() / :SortBank().

local NUM_BAGS     = NUM_BAG_SLOTS or 4
local NUM_BANKBAGS = NUM_BANKBAGSLOTS or 7
local BANK         = BANK_CONTAINER or -1
local MAX_PASSES   = 60     -- hard stop against a stuck loop
local MAX_STALLS   = 12     -- give up if no batch lands across this many retries
local WATCHDOG     = 5      -- seconds; force-finish so a stuck run can't block re-clicks

-- Item classIDs used to route items to role-assigned bags (see ComputeOrder).
-- Stable across every WoW version; the `or` fallback mirrors NUM_BAGS above.
local ITEM_CLASS_WEAPON     = LE_ITEM_CLASS_WEAPON or 2
local ITEM_CLASS_ARMOR      = LE_ITEM_CLASS_ARMOR or 4
local ITEM_CLASS_TRADEGOODS = LE_ITEM_CLASS_TRADEGOODS or 7
local ITEM_CLASS_QUESTITEM  = LE_ITEM_CLASS_QUESTITEM or 12
local QUALITY_POOR          = LE_ITEM_QUALITY_POOR or 0

local function IsGearItem(classID)    return classID == ITEM_CLASS_WEAPON or classID == ITEM_CLASS_ARMOR end
local function IsReagentItem(classID) return classID == ITEM_CLASS_TRADEGOODS end
local function IsQuestItem(classID)   return classID == ITEM_CLASS_QUESTITEM end

-- Container id lists (filtered to ones that actually exist at sort time).
local BAG_CONTAINERS = { 0 }
for i = 1, NUM_BAGS do BAG_CONTAINERS[#BAG_CONTAINERS + 1] = i end

local BANK_CONTAINERS = { BANK }
for i = NUM_BAGS + 1, NUM_BAGS + NUM_BANKBAGS do BANK_CONTAINERS[#BANK_CONTAINERS + 1] = i end

-- Sort key (see ItemBefore below): quality (high first) -> class -> subclass
-- -> name -> itemID -> stack size.
--
-- classID/subclassID come from GetItemInfoInstant, NOT GetItemInfo: the
-- latter needs the server-provided name/tooltip data, which for an item the
-- client hasn't cached yet returns nil for EVERY field (async — it only
-- populates a moment later via GET_ITEM_INFO_RECEIVED). GetItemInfoInstant
-- only needs the static client-side item template, so it's synchronously
-- correct even for an item you've never inspected. This is what was silently
-- breaking Gear/Reagent role routing (IsGearItem/IsReagentItem comparing
-- against the classID==99 uncached fallback, never matching).
local function ComputeKey(item)
    local name, _, _, _, _, _, _, maxStack = GetItemInfo(item.link or item.itemID)
    local _, _, _, _, _, classID, subclassID = GetItemInfoInstant(item.itemID)
    item.name       = name or ""
    item.maxStack   = maxStack or 1
    item.classID    = classID or 99
    item.subclassID = subclassID or 99
end

-- Quality is the PRIMARY key (epic before rare before uncommon before
-- common before poor), class/subclass/name only break ties within a quality
-- tier — matches "sort by quality" as the headline rule for within-bag order.
local function ItemBefore(a, b)
    if a.quality    ~= b.quality    then return a.quality    > b.quality    end
    if a.classID    ~= b.classID    then return a.classID    < b.classID    end
    if a.subclassID ~= b.subclassID then return a.subclassID < b.subclassID end
    if a.name       ~= b.name       then return a.name       < b.name       end
    if a.itemID     ~= b.itemID     then return a.itemID     < b.itemID     end
    return a.count > b.count
end

object "BagSorter" {

    __init = function(self)
        -- [itemID] = total count across all non-ignored bags, as of the last
        -- check. Drives auto-relocate-on-loot: a manual bag reorganization
        -- (splitting/merging/moving stacks) never changes an item's TOTAL
        -- count, only genuinely acquiring more of it does (loot, purchase,
        -- quest reward, mail) — so this diff naturally ignores your own
        -- manual bag management and only reacts to real acquisitions.
        self._lootCounts = {}
        self._lootSeeded = false

        self._events = Frame("Frame")
        self._events:RegisterEventHandler("BAG_UPDATE_DELAYED", function()
            if self._running then
                self:Step()
            else
                self:CheckAutoLoot()
            end
        end)
    end;

    SortBags = function(self) self:Start(BAG_CONTAINERS) end;
    SortBank = function(self) self:Start(BANK_CONTAINERS) end;

    Start = function(self, containerIDs)
        if self._running then return end
        if InCombatLockdown() then return end

        -- Bag roles/ignore are meaningless once bags are visually merged into
        -- one window (there's no single bag left to route into), so combined
        -- mode sorts as if no bag has a role assigned.
        local roles = (not MUI_DB.settings.bags.combined) and MUI_DB.settings.bags.roles or {}
        local containers = {}
        for _, id in ipairs(containerIDs) do
            local n = C_Container.GetContainerNumSlots(id)
            if n and n > 0 and roles[id] ~= "ignored" then
                containers[#containers + 1] = { id = id, size = n }
            end
        end
        if #containers == 0 then return end

        self._roles      = roles
        self._containers = containers
        self._running = true
        self._phase   = "stack"   -- "stack" -> consolidate partials, then "order"
        self._order   = nil       -- frozen target itemID-per-slot once ordering begins
        self._passes  = 0
        self._stalls  = 0

        -- Watchdog: never let a stuck run keep _running set (which would block
        -- the next click). A fresh Start bumps the token so old timers no-op.
        self._token = (self._token or 0) + 1
        local token = self._token
        C_Timer.After(WATCHDOG, function()
            if self._running and self._token == token then self:Finish() end
        end)

        ClearCursor()
        self:Step()
    end;

    Finish = function(self)
        self._running = false
        self._containers = nil
        self._order = nil
        self._roles = nil
    end;

    -- ===================================================================
    -- Auto-relocate on loot: whenever an item's total count across your
    -- non-ignored bags goes UP (a real acquisition — loot, vendor purchase,
    -- quest reward, mail), and it belongs to a category with a specific
    -- home (vendor/quest/gear/reagent), quietly move it there if it isn't
    -- already at least partly there. Doesn't touch anything else — no full
    -- re-sort, so bags you've arranged by hand stay exactly as you left them.
    -- ===================================================================

    CheckAutoLoot = function(self)
        if self._running then return end
        if InCombatLockdown() then return end

        local roles = (not MUI_DB.settings.bags.combined) and MUI_DB.settings.bags.roles or {}
        local containers = {}
        for _, id in ipairs(BAG_CONTAINERS) do
            local n = C_Container.GetContainerNumSlots(id)
            if n and n > 0 and roles[id] ~= "ignored" then
                containers[#containers + 1] = { id = id, size = n }
            end
        end
        if #containers == 0 then return end

        local counts = {}
        for _, c in ipairs(containers) do
            for slot = 1, c.size do
                local info = C_Container.GetContainerItemInfo(c.id, slot)
                if info then
                    counts[info.itemID] = (counts[info.itemID] or 0) + (info.stackCount or 1)
                end
            end
        end

        local prev = self._lootCounts
        self._lootCounts = counts

        -- First run this session (e.g. right after login/reload): establish
        -- the baseline only. Without this, every item you already own would
        -- look like it "just grew" from 0 and get relocated immediately.
        if not self._lootSeeded then
            self._lootSeeded = true
            return
        end

        for itemID, count in pairs(counts) do
            if count > (prev[itemID] or 0) then
                self:RelocateItem(itemID, containers, roles)
            end
        end
    end;

    -- Moves every current stack of `itemID` into its designated bag, if it
    -- has one and isn't already (at least partly) there. Only ever moves
    -- into genuinely empty slots — never disturbs an existing arrangement
    -- by swapping something else out — so it simply does nothing once the
    -- target bag is full rather than fighting for space.
    RelocateItem = function(self, itemID, containers, roles)
        local roleBags, unassignedBags = { gear = {}, reagents = {} }, {}
        for _, c in ipairs(containers) do
            local role = roles[c.id]
            if role == "gear" or role == "reagents" then
                table.insert(roleBags[role], c.id)
            else
                table.insert(unassignedBags, c.id)
            end
        end
        local unassignedBagsDesc = {}
        for i = #unassignedBags, 1, -1 do
            unassignedBagsDesc[#unassignedBagsDesc + 1] = unassignedBags[i]
        end

        local stacks, quality
        for _, c in ipairs(containers) do
            for slot = 1, c.size do
                local info = C_Container.GetContainerItemInfo(c.id, slot)
                if info and info.itemID == itemID and not info.isLocked then
                    stacks = stacks or {}
                    stacks[#stacks + 1] = { bag = c.id, slot = slot }
                    quality = info.quality
                end
            end
        end
        if not stacks then return end

        local _, _, _, _, _, classID = GetItemInfoInstant(itemID)
        classID = classID or 99

        local targets
        if (quality or 1) == QUALITY_POOR then
            targets = unassignedBags
        elseif IsQuestItem(classID) then
            targets = unassignedBagsDesc
        elseif IsGearItem(classID) and #roleBags.gear > 0 then
            targets = roleBags.gear
        elseif IsReagentItem(classID) and #roleBags.reagents > 0 then
            targets = roleBags.reagents
        else
            return  -- no specific home for this item; leave it wherever it landed
        end

        -- Already at least partly home? Leave it alone.
        for _, s in ipairs(stacks) do
            for _, t in ipairs(targets) do
                if s.bag == t then return end
            end
        end

        for _, s in ipairs(stacks) do
            for _, t in ipairs(targets) do
                local emptySlot = self:FindEmptySlot(t)
                if emptySlot then
                    C_Container.PickupContainerItem(s.bag, s.slot)
                    C_Container.PickupContainerItem(t, emptySlot)
                    ClearCursor()
                    break
                end
            end
        end
    end;

    FindEmptySlot = function(self, bagID)
        local n = C_Container.GetContainerNumSlots(bagID) or 0
        for slot = 1, n do
            if not C_Container.GetContainerItemInfo(bagID, slot) then
                return slot
            end
        end
        return nil
    end;

    -- Read every slot in the target containers plus the subset holding an item
    -- (with sort key + maxStack precomputed). pos.index is the flat slot index.
    Snapshot = function(self)
        local slots, items = {}, {}
        local k = 0
        for _, c in ipairs(self._containers) do
            for slot = 1, c.size do
                k = k + 1
                local pos = { bag = c.id, slot = slot, index = k }
                local info = C_Container.GetContainerItemInfo(c.id, slot)
                if info then
                    pos.itemID  = info.itemID
                    pos.count   = info.stackCount or 1
                    pos.quality = info.quality or 1
                    pos.link    = info.hyperlink
                    pos.locked  = info.isLocked
                    -- The bag UI's own quest-item flag (the exclamation-mark
                    -- border) — independent of the item cache, so it doesn't
                    -- depend on GetItemInfo having seen this item yet.
                    local questInfo = C_Container.GetContainerItemQuestInfo(c.id, slot)
                    pos.isQuestItem = questInfo and questInfo.isQuestItem or false
                    ComputeKey(pos)
                    items[#items + 1] = pos
                end
                slots[k] = pos
            end
        end
        return slots, items
    end;

    -- One batch of work, re-triggered by BAG_UPDATE_DELAYED until done.
    Step = function(self)
        self._passes = self._passes + 1
        if self._passes > MAX_PASSES then
            if MUI_BAGSORT_DEBUG then MUI_Dbg("[Sort] MAX_PASSES hit, giving up") end
            self:Finish(); return
        end

        local slots, items = self:Snapshot()

        local moved
        if self._phase == "stack" then
            moved = self:StackPass(items)
            if not moved then
                -- Stacking settled: freeze the sorted target, start ordering.
                self._phase = "order"
                self._order = self:ComputeOrder(items)
                if MUI_BAGSORT_DEBUG then self:DebugDumpOrder(items, self._order) end
                moved = self:OrderPass(slots, self._order)
            end
        else
            moved = self:OrderPass(slots, self._order)
        end

        if moved then
            self._stalls = 0
            return  -- BAG_UPDATE_DELAYED will run the next batch
        end

        if self._phase == "order" and self:IsSorted(slots, self._order) then
            if MUI_BAGSORT_DEBUG then MUI_Dbg(("[Sort] Finished cleanly after %d passes"):format(self._passes)) end
            self:Finish()
            return
        end

        -- Nothing moved but not done: the slots we need are still locked from a
        -- previous batch. Retry shortly; bail if it never settles.
        self._stalls = self._stalls + 1
        if self._stalls > MAX_STALLS then
            if MUI_BAGSORT_DEBUG then
                MUI_Dbg(("[Sort] MAX_STALLS hit after %d passes, giving up. Mismatched slots:"):format(self._passes))
                for k = 1, #slots do
                    if slots[k].itemID ~= self._order[k] then
                        MUI_Dbg(("  flat%d bag%d slot%d: has=%s want=%s locked=%s"):format(
                            k, slots[k].bag, slots[k].slot, tostring(slots[k].itemID), tostring(self._order[k]), tostring(slots[k].locked)))
                    end
                end
            end
            self:Finish()
        else
            C_Timer.After(0.1, function() if self._running then self:Step() end end)
        end
    end;

    -- Logs each item's computed target bag right after ComputeOrder freezes
    -- it, keyed by itemID so it's easy to grep for a specific item's fate.
    DebugDumpOrder = function(self, items, order)
        local byItem = {}
        for _, it in ipairs(items) do byItem[it.itemID] = it end
        MUI_Dbg("[Sort] Computed order (flat -> bag/slot/itemID):")
        local k = 0
        for _, c in ipairs(self._containers) do
            for slot = 1, c.size do
                k = k + 1
                local want = order[k]
                if want then
                    local it = byItem[want]
                    MUI_Dbg(("  flat%d bag%d slot%d wants item=%s (%s)"):format(
                        k, c.id, slot, tostring(want), it and it.name or "?"))
                end
            end
        end
    end;

    -- Merge a batch of same-item partial stacks. Only disjoint, unlocked pairs
    -- this frame; 3-pickup (src, dst, src) merges with overflow back to src.
    StackPass = function(self, items)
        local partials = {}
        for _, it in ipairs(items) do
            if it.maxStack > 1 and it.count < it.maxStack and not it.locked then
                local list = partials[it.itemID]
                if not list then list = {}; partials[it.itemID] = list end
                list[#list + 1] = it
            end
        end

        local touched, moved = {}, false
        for _, list in pairs(partials) do
            local p = 1
            while p + 1 <= #list do
                local dst, src = list[p], list[p + 1]
                if not touched[dst.index] and not touched[src.index] then
                    C_Container.PickupContainerItem(src.bag, src.slot)
                    C_Container.PickupContainerItem(dst.bag, dst.slot)
                    C_Container.PickupContainerItem(src.bag, src.slot)
                    ClearCursor()
                    touched[dst.index] = true
                    touched[src.index] = true
                    moved = true
                end
                p = p + 2
            end
        end
        return moved
    end;

    -- The frozen target: sorted itemID per flat slot index (nil past the last
    -- stack in each bag). Computed once, after stacking, so the goal never
    -- shifts mid-sort. Assigns every item to a target BAG first (role /
    -- ignore / quest / vendor rules below), then sorts within each bag by
    -- the usual ItemBefore key and flattens back into the flat-slot order
    -- Snapshot/OrderPass already work with (self._containers is already
    -- ignore-filtered by Start).
    ComputeOrder = function(self, items)
        local roles = self._roles or {}

        local roleBags = { gear = {}, reagents = {} }
        local unassignedBags, anyBag, capacity, bucket = {}, {}, {}, {}
        for _, c in ipairs(self._containers) do
            local role = roles[c.id]
            if role == "gear" or role == "reagents" then
                table.insert(roleBags[role], c.id)
            else
                table.insert(unassignedBags, c.id)
            end
            table.insert(anyBag, c.id)
            capacity[c.id] = c.size
            bucket[c.id] = {}
        end

        -- Highest-index-first variant of unassignedBags, for quest items
        -- ("last" unassigned bag first, per the first/last bag definition).
        local unassignedBagsDesc = {}
        for i = #unassignedBags, 1, -1 do
            unassignedBagsDesc[#unassignedBagsDesc + 1] = unassignedBags[i]
        end

        -- Try each candidate bag in order; first one with a free slot wins.
        -- Returns false (placing nothing) if every candidate is full, so the
        -- caller can hand the item to a later overflow pass instead of
        -- letting it eat into a bag another category still needs.
        local function TryPlace(item, candidates)
            for _, bagID in ipairs(candidates) do
                if capacity[bagID] and capacity[bagID] > 0 then
                    table.insert(bucket[bagID], item)
                    capacity[bagID] = capacity[bagID] - 1
                    return true
                end
            end
            return false
        end

        -- Every category's OWN, first-choice bag(s) — no cross-category
        -- fallback yet. This is what every item gets a shot at in phase 1,
        -- so (for example) a full Gear bag can't get filled by vendor/quest
        -- overflow before the actual gear items have had their turn.
        --
        -- The unassigned pool is one continuous quality-sorted stream, filled
        -- top-down: the highest remaining unassigned bag fills first (with
        -- its highest-quality candidates, since items are processed in
        -- quality order below), then spills into the next one down. Vendor
        -- junk is the one exception with its own fixed "first bag" rule.
        local function PrimaryCandidates(item)
            if item.quality == QUALITY_POOR then
                return unassignedBags
            elseif item.isQuestItem or IsQuestItem(item.classID) then
                return unassignedBagsDesc
            elseif IsGearItem(item.classID) and #roleBags.gear > 0 then
                return roleBags.gear
            elseif IsReagentItem(item.classID) and #roleBags.reagents > 0 then
                return roleBags.reagents
            else
                return unassignedBagsDesc
            end
        end

        -- Phase-2 fallback for whatever didn't fit in its primary bag(s).
        -- Vendor/quest/generic already tried every unassigned bag in phase 1,
        -- so their only path left is anyBag (which includes role bags — a
        -- last resort). Gear/Reagent overflow tries the unassigned bags
        -- (same top-down order) first, then anyBag.
        local function OverflowCandidates(item)
            if IsGearItem(item.classID) and #roleBags.gear > 0 then
                return self:_Concat(unassignedBagsDesc, anyBag)
            elseif IsReagentItem(item.classID) and #roleBags.reagents > 0 then
                return self:_Concat(unassignedBagsDesc, anyBag)
            else
                return anyBag
            end
        end

        -- Priority (lower = placed first) governs contention for shared
        -- unassigned-bag space within each phase: vendor/quest have a single
        -- fixed target and should claim it before generic items crowd it out.
        local function Priority(item)
            if item.quality == QUALITY_POOR then return 1 end
            if item.isQuestItem or IsQuestItem(item.classID) then return 2 end
            if IsGearItem(item.classID) and #roleBags.gear > 0 then return 3 end
            if IsReagentItem(item.classID) and #roleBags.reagents > 0 then return 4 end
            return 5
        end

        -- Within the same priority tier, process highest quality first (via
        -- the same ItemBefore key used for the final within-bag order) so
        -- filling a bag to capacity concentrates its best items rather than
        -- whatever happened to come first in raw bag/slot scan order.
        local queue = {}
        for i = 1, #items do queue[i] = items[i] end
        table.sort(queue, function(a, b)
            local pa, pb = Priority(a), Priority(b)
            if pa ~= pb then return pa < pb end
            return ItemBefore(a, b)
        end)

        -- Phase 1: everyone claims their own territory first.
        local overflow = {}
        for _, item in ipairs(queue) do
            if not TryPlace(item, PrimaryCandidates(item)) then
                overflow[#overflow + 1] = item
            end
        end

        -- Phase 2: only items that didn't fit anywhere in phase 1 spill over,
        -- forced into whatever's left (anyBag always succeeds — total
        -- capacity across all bags always covers total items).
        for _, item in ipairs(overflow) do
            if not TryPlace(item, OverflowCandidates(item)) then
                table.insert(bucket[anyBag[1]], item)
            end
        end

        for _, list in pairs(bucket) do
            table.sort(list, ItemBefore)
        end

        local order, k = {}, 0
        for _, c in ipairs(self._containers) do
            local list = bucket[c.id]
            for i = 1, #list do
                k = k + 1
                order[k] = list[i].itemID
            end
            k = k + (c.size - #list)
        end
        return order
    end;

    -- Concatenate candidate-bag-id lists into one (order preserved,
    -- duplicates harmless — TryPlace() just skips full/absent entries).
    _Concat = function(self, ...)
        local out = {}
        for _, list in ipairs({...}) do
            for _, v in ipairs(list) do out[#out + 1] = v end
        end
        return out
    end;

    -- Move a batch toward the frozen order: each wrong slot pulls its desired
    -- item in from anywhere else. Disjoint, unlocked pairs only this frame.
    -- Matching by itemID means we never drop an item onto the same item, so
    -- these are always clean swaps (no accidental merges), preserving stacks.
    --
    -- Searches the WHOLE slot array, not just j > k: with per-bag bucketing
    -- (see ComputeOrder), a bag with spare capacity leaves `order[]` gaps
    -- (nil = "don't care") scattered before later bags' slots in flat order,
    -- not just at the very tail like the old single-global-sort did. An item
    -- sitting in one of those gaps needs to be reachable regardless of
    -- whether its current position is before or after the slot that wants it.
    OrderPass = function(self, slots, order)
        local touched, moved = {}, false
        for k = 1, #slots do
            local cur  = slots[k]
            local want = order[k]
            if want and cur.itemID ~= want and not cur.locked and not touched[cur.index] then
                local from
                for j = 1, #slots do
                    if j ~= k then
                        local s = slots[j]
                        if s.itemID == want and not s.locked and not touched[s.index] then
                            from = s
                            break
                        end
                    end
                end
                if from then
                    C_Container.PickupContainerItem(from.bag, from.slot)
                    C_Container.PickupContainerItem(cur.bag, cur.slot)
                    C_Container.PickupContainerItem(from.bag, from.slot)
                    ClearCursor()
                    touched[cur.index]  = true
                    touched[from.index] = true
                    moved = true
                    if MUI_BAGSORT_DEBUG then
                        MUI_Dbg(("[Sort] swap bag%d/slot%d <-> bag%d/slot%d (item %s)"):format(
                            cur.bag, cur.slot, from.bag, from.slot, tostring(want)))
                    end
                elseif MUI_BAGSORT_DEBUG then
                    -- Wanted item isn't reachable this pass: it's currently
                    -- locked, or already touched by another swap this same
                    -- pass. Normal mid-sort (next pass usually resolves it),
                    -- but if this keeps repeating pass after pass, that's a bug.
                    MUI_Dbg(("[Sort] flat%d bag%d/slot%d wants item %s, not found this pass"):format(
                        k, cur.bag, cur.slot, tostring(want)))
                end
            end
        end
        return moved
    end;

    IsSorted = function(self, slots, order)
        for k = 1, #slots do
            if slots[k].itemID ~= order[k] then return false end
        end
        return true
    end;

    -- Temporary diagnostic: dumps role assignment + per-item classification
    -- without moving anything, into the copyable MUI_Dbg log window (see
    -- MUI_Shared/MUI_DebugLog.lua) instead of the chat frame, which can't be
    -- selected/copied. Run with /run MUI_BagSorter:Debug() then Ctrl+A/Ctrl+C
    -- inside the window that pops up (or /run MUI_DebugLogFrame:Show()).
    Debug = function(self)
        local roles = MUI_DB.settings.bags.roles or {}
        MUI_Dbg("[MUI Bag Sort Debug] combined=" .. tostring(MUI_DB.settings.bags.combined))
        for _, id in ipairs(BAG_CONTAINERS) do
            local n = C_Container.GetContainerNumSlots(id)
            MUI_Dbg(("bag %d: role=%s slots=%s"):format(id, tostring(roles[id]), tostring(n)))
        end
        for _, id in ipairs(BAG_CONTAINERS) do
            local n = C_Container.GetContainerNumSlots(id) or 0
            for slot = 1, n do
                local info = C_Container.GetContainerItemInfo(id, slot)
                if info then
                    local name = GetItemInfo(info.itemID)
                    local _, _, _, _, _, classID, subclassID = GetItemInfoInstant(info.itemID)
                    local questInfo = C_Container.GetContainerItemQuestInfo(id, slot)
                    local cat = "generic"
                    if (info.quality or 1) == (LE_ITEM_QUALITY_POOR or 0) then cat = "vendor"
                    elseif questInfo and questInfo.isQuestItem then cat = "quest"
                    elseif classID == (LE_ITEM_CLASS_WEAPON or 2) or classID == (LE_ITEM_CLASS_ARMOR or 4) then cat = "gear"
                    elseif classID == (LE_ITEM_CLASS_TRADEGOODS or 7) then cat = "reagent" end
                    MUI_Dbg(("  bag%d slot%d: %s (id=%s) quality=%s classID=%s subclassID=%s cat=%s"):format(
                        id, slot, name or "?", tostring(info.itemID), tostring(info.quality),
                        tostring(classID), tostring(subclassID), cat))
                end
            end
        end
    end;
}
