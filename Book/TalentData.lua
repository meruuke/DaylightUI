-- Reads the talent trees from C_Traits into plain tables for the talents
-- page. Nothing here is class-specific: positions, ranks, arrows and rules
-- all come from the game.
--
-- On Forever a config holds one tree, with the class's three trees as
-- display groups (GetGroupDisplayInfoByTreeID). A node lists several
-- groupIDs, and its tree is whichever of them is a display group. Positions
-- sit on a 600-unit grid: rows are shared by all three trees, columns start
-- at each tree's own leftmost x. Tier requirements are trait conditions with
-- spentAmountRequired, and the game's own text is shown for them. Talent
-- data is never secret.

local _, DUI = ...
DUI.Book = DUI.Book or {}   -- the book window's own namespace
local ns = DUI.Book
local L = DUI.L

local TD = {}
ns.TalentData = TD

TD.STEP = 600   -- grid spacing between tiles, both axes

-- Retail (interface 100000 and up) has one tree per config with no display
-- groups: class, spec and hero nodes are told apart by what they cost
-- (GetNodeCost against GetTreeCurrencyInfo, class first, spec second) and
-- hero nodes by subTreeID. Forever reports 16001 and keeps its own path.
TD.RETAIL = (select(4, GetBuildInfo()) or 0) >= 100000

local function call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c = pcall(fn, ...)
    if ok then return a, b, c end
end

local function traits() return type(C_Traits) == "table" and C_Traits or nil end

-- Active talent set, 1 or 2.
function TD.ActiveGroup()
    local S = C_SpecializationInfo
    local g = type(S) == "table" and call(S.GetActiveSpecGroup)
    return type(g) == "number" and g or 1
end

-- Use the global GetNumSpecGroups, as the game's IsDualSpecUnlocked does.
-- C_SpecializationInfo has no GetNumSpecGroups on Forever, and relying on it
-- kept the second set grayed out after learning dual spec.
function TD.NumGroups()
    local n = call(GetNumSpecGroups)
    return type(n) == "number" and n or 1
end

-- Combat config for a set, as in ClassTalentsFrameMixin:SetTab. nil for a
-- second set that was never activated. Defaults to the active set.
function TD.ConfigID(group)
    local S = C_SpecializationInfo
    if type(S) == "table" then
        local id = call(S.GetCombatConfigIDForSpecGroup, group or TD.ActiveGroup())
        if type(id) == "number" then return id end
        -- Retail has no GetCombatConfigIDForSpecGroup: the active set still
        -- has the active config, only another set has none.
        if group and group ~= TD.ActiveGroup() then return nil end
    end
    if type(C_ClassTalents) == "table" then
        local id = call(C_ClassTalents.GetActiveConfigID)
        if type(id) == "number" then return id end
    end
end

local function spellLook(spellID, def)
    local name = type(def) == "table" and def.overrideName or nil
    local icon = type(def) == "table" and def.overrideIcon or nil
    if type(C_Spell) == "table" and type(spellID) == "number" then
        if type(name) ~= "string" or name == "" then name = call(C_Spell.GetSpellName, spellID) end
        -- The game's talent buttons use the second return, the spell's base
        -- icon (TalentButtonUtil.CalculateIconTexture).
        if not icon then
            local now, own = call(C_Spell.GetSpellTexture, spellID)
            icon = (own ~= nil and own ~= 0 and own) or (now ~= nil and now ~= 0 and now) or nil
        end
    end
    return type(name) == "string" and name or "", icon or 134400   -- question mark icon
end

-- The node's first point-spending condition (tier requirement).
local function rule(C, configID, n)
    for _, condID in ipairs(type(n.conditionIDs) == "table" and n.conditionIDs or {}) do
        local c = call(C.GetConditionInfo, configID, condID)
        if type(c) == "table" and type(c.spentAmountRequired) == "number" and c.spentAmountRequired > 0 then
            return { amount = c.spentAmountRequired, format = c.tooltipFormat, met = c.isMet == true }
        end
    end
end

-- Entries of a choice (Selection) node, else nil. Class trees have none.
local SELECTION = { [2] = true, [3] = true }   -- Enum.TraitNodeType Selection, SubTreeSelection
local function choicesOf(n)
    local T = Enum and Enum.TraitNodeType
    local sel = T and (n.type == T.Selection or n.type == T.SubTreeSelection) or (not T and SELECTION[n.type])
    if sel and type(n.entryIDs) == "table" and #n.entryIDs > 1 then return n.entryIDs end
end

-- Name, icon (file ID or path), atlas and spellID of one entry. A hero tree
-- choice's entry has no spell, only a subTreeID: its name and atlas come
-- from GetSubTreeInfo.
local function entryLook(C, configID, entryID)
    local entry = entryID and call(C.GetEntryInfo, configID, entryID)
    if type(entry) == "table" and type(entry.subTreeID) == "number" then
        local sub = call(C.GetSubTreeInfo, configID, entry.subTreeID)
        if type(sub) == "table" then
            return type(sub.name) == "string" and sub.name or "", nil, sub.iconElementID, nil, entry.subTreeID
        end
    end
    local def = type(entry) == "table" and entry.definitionID and call(C.GetDefinitionInfo, entry.definitionID) or nil
    local spellID = type(def) == "table" and def.spellID or nil
    local name, icon = spellLook(spellID, def)
    return name, icon, nil, spellID
end

-- Every entry of a choice node, for its menu and split icon.
local function optionsOf(C, configID, n)
    local ids = choicesOf(n)
    if not ids then return nil end
    local out = {}
    for _, entryID in ipairs(ids) do
        local name, icon, atlas, spellID, subTreeID = entryLook(C, configID, entryID)
        out[#out + 1] = { entryID = entryID, name = name, icon = icon, atlas = atlas, spellID = spellID, subTreeID = subTreeID }
    end
    return out
end

-- Bought ranks, and the rank to show. Retail counts granted and staged ranks
-- in currentRank (the game's buttons show it); ranksPurchased stays 0 for a
-- talent the game hands out for free.
function TD.MaxOf(n) return type(n.maxRanks) == "number" and n.maxRanks or 1 end
function TD.Ranks(n)
    local bought = type(n.ranksPurchased) == "number" and n.ranksPurchased or 0
    local rank = TD.RETAIL and type(n.currentRank) == "number" and math.max(n.currentRank, bought) or bought
    return bought, rank
end
-- As the game's buttons: no buying past max, no refunding a granted rank.
function TD.CanBuyInfo(n)
    local _, rank = TD.Ranks(n)
    return n.canPurchaseRank == true and rank < TD.MaxOf(n)
end
function TD.CanRefundInfo(n)
    local bought = TD.Ranks(n)
    return n.canRefundRank == true and bought > 0
end

local function readNode(C, configID, id, n)
    local entryID = type(n.activeEntry) == "table" and n.activeEntry.entryID or (type(n.entryIDs) == "table" and n.entryIDs[1]) or nil
    local name, icon, atlas, spellID = entryLook(C, configID, entryID)
    local bought, rank = TD.Ranks(n)
    local active = type(n.activeRank) == "number" and n.activeRank or rank
    local edges = {}
    for _, e in ipairs(type(n.visibleEdges) == "table" and n.visibleEdges or {}) do
        if type(e) == "table" and type(e.targetNode) == "number" then
            edges[#edges + 1] = { to = e.targetNode, active = e.isActive == true }
        end
    end
    return {
        id = id, x = n.posX, y = n.posY, rank = rank, bought = bought, active = active, max = TD.MaxOf(n),
        staged = rank > active, entryID = entryID, spellID = spellID, name = name, icon = icon, atlas = atlas,
        canBuy = TD.CanBuyInfo(n), canRefund = TD.CanRefundInfo(n),
        available = n.isAvailable ~= false and n.meetsEdgeRequirements ~= false,
        edgesMet = n.meetsEdgeRequirements ~= false, rule = rule(C, configID, n), edges = edges,
        choices = choicesOf(n), chosen = type(n.activeEntry) == "table" and n.activeEntry.entryID ~= nil,
        options = TD.RETAIL and optionsOf(C, configID, n) or nil,
    }
end

local function round(v) return math.floor(v + 0.5) end

-- Forever keeps a few retired talents in its trees, parked far off the
-- board (e.g. the hunter's old Lightning Reflexes at x = 102800, the
-- priest's old Holy Specialization at 9280, 21300). The game's frame never
-- shows them. No tree is more than SPAN tiles in either direction, so
-- anything beyond that is skipped.
TD.SPAN = 10

-- Smallest value within span of the median, so a stray node can't set the edge.
local function edge(values, o)
    table.sort(values)
    local mid, low = values[math.ceil(#values / 2)], nil
    for _, v in ipairs(values) do
        if math.abs(v - mid) <= o.span * o.step and (not low or v < low) then low = v end
    end
    return low
end

-- Grid index, or nil when off the board.
local function cell(v, from, o)
    local c = round((v - from) / o.step)
    if c >= 0 and c < o.span then return c end
end

-- Guess the grid step for trees with their own spacing (the Legacy trees):
-- the smallest gap along an axis, ignoring tiny ones from near-overlapping nodes.
function TD.Step(values)
    table.sort(values)
    local best
    for i = 2, #values do
        local d = values[i] - values[i - 1]
        if d > 50 and (not best or d < best) then best = d end
    end
    return best or TD.STEP
end

-- Rows count from the top of the whole config so tiers line up across
-- trees; columns from each tree's left edge. Off-board nodes are dropped
-- from the tree and byID, though any points in them still count.
local function grid(trees, byID, o)
    local ys = {}
    for _, t in ipairs(trees) do
        for _, n in ipairs(t.nodes) do ys[#ys + 1] = n.y end
    end
    local minY = edge(ys, o)
    for _, t in ipairs(trees) do
        local xs = {}
        for _, n in ipairs(t.nodes) do xs[#xs + 1] = n.x end
        local minX = edge(xs, o)
        t.cols, t.rows = o.cols, o.rows   -- at least the classic 4 x 7, so all trees match
        local kept = {}
        for _, n in ipairs(t.nodes) do
            n.col, n.row = cell(n.x, minX, o), cell(n.y, minY, o)
            if n.col and n.row then
                kept[#kept + 1] = n
                if n.col + 1 > t.cols then t.cols = n.col + 1 end
                if n.row + 1 > t.rows then t.rows = n.row + 1 end
            else
                byID[n.id] = nil
            end
        end
        t.nodes = kept
        table.sort(t.nodes, function(a, b) if a.row ~= b.row then return a.row < b.row end return a.col < b.col end)
    end
end

-- ---------------------------------------------------------------------
-- Retail: class, hero and spec trees from one C_Traits tree
-- ---------------------------------------------------------------------

local function specLook()
    local S = C_SpecializationInfo
    local index = (type(S) == "table" and call(S.GetSpecialization)) or call(GetSpecialization)
    if type(index) ~= "number" then return nil end
    local get = (type(S) == "table" and S.GetSpecializationInfo) or GetSpecializationInfo
    local _, name, _, icon = call(get, index)
    return name, icon
end

-- Columns and rows on a half-tile grid (retail offsets nodes by half a
-- tile), from each tree's own top-left node.
local function retailGrid(t)
    local minX, minY
    for _, n in ipairs(t.nodes) do
        if not minX or n.x < minX then minX = n.x end
        if not minY or n.y < minY then minY = n.y end
    end
    -- Hero trees sit on a tighter grid than class and spec, so they use
    -- their own row gap as the step (rows have no half offsets; columns may).
    local step = TD.STEP
    if t.kind == "hero" and #t.nodes > 1 then
        local ys = {}
        for _, n in ipairs(t.nodes) do ys[#ys + 1] = n.y end
        local s = TD.Step(ys)
        if s and s > 50 and s < TD.STEP then step = s end
    end
    local half = step / 2
    t.cols, t.rows = 1, 1
    for _, n in ipairs(t.nodes) do
        n.col = round((n.x - minX) / half) / 2
        n.row = round((n.y - minY) / half) / 2 + (t.drop or 0)
        if n.col + 1 > t.cols then t.cols = n.col + 1 end
        if n.row + 1 > t.rows then t.rows = n.row + 1 end
    end
    table.sort(t.nodes, function(a, b) if a.row ~= b.row then return a.row < b.row end return a.col < b.col end)
end

local function addTo(t, node, out)
    node.tree = t
    t.nodes[#t.nodes + 1] = node
    t.spent = t.spent + (node.bought or node.rank)
    out.byID[node.id] = node
end

-- Fills out.trees with class, hero (when there's one to show) and spec.
local function readRetail(C, configID, treeID, out, pending)
    local cur = call(C.GetTreeCurrencyInfo, configID, treeID, false)
    cur = type(cur) == "table" and cur or {}
    local function curID(i) return type(cur[i]) == "table" and cur[i].traitCurrencyID or nil end
    local className, token = UnitClass("player")
    local specName, specIcon = specLook()
    local class = { kind = "class", name = className or L["Class"], spent = 0, nodes = {}, cur = curID(1),
                    icon = token and ("Interface\\Icons\\ClassIcon_" .. token) or nil }
    local spec = { kind = "spec", name = specName or L["Specialization"], icon = specIcon, spent = 0, nodes = {}, cur = curID(2) }
    local hero = { kind = "hero", name = L["Hero Talents"], spent = 0, nodes = {} }
    local loose, selector = {}, nil
    local T = Enum and Enum.TraitNodeType
    for _, id in ipairs(call(C.GetTreeNodes, treeID) or {}) do
        local n = call(C.GetNodeInfo, configID, id)
        if type(n) == "table" and n.isVisible ~= false and type(n.posX) == "number" and type(n.posY) == "number" then
            local node = readNode(C, configID, id, n)
            if pending[id] then node.staged = true end
            if T and n.type == T.SubTreeSelection then
                node.heroPick = true
                selector = node
            elseif type(n.subTreeID) == "number" then
                if n.subTreeActive == true then
                    addTo(hero, node, out)
                    if not hero.subTreeID then
                        hero.subTreeID = n.subTreeID
                        local sub = call(C.GetSubTreeInfo, configID, n.subTreeID)
                        if type(sub) == "table" then
                            hero.name = type(sub.name) == "string" and sub.name ~= "" and sub.name or hero.name
                            hero.atlas = sub.iconElementID
                            hero.cur = sub.traitCurrencyID
                        end
                    end
                end
            else
                local costs = call(C.GetNodeCost, configID, id)
                local first = type(costs) == "table" and type(costs[1]) == "table" and costs[1].ID or nil
                if first and first == class.cur then addTo(class, node, out)
                elseif first and first == spec.cur then addTo(spec, node, out)
                else loose[#loose + 1] = node end
            end
        end
    end
    -- Free nodes (the spec's starting talents) go to whichever tree they sit in.
    local function span(t)
        local lo, hi
        for _, n in ipairs(t.nodes) do
            if not lo or n.x < lo then lo = n.x end
            if not hi or n.x > hi then hi = n.x end
        end
        return lo, hi
    end
    local cLo, cHi = span(class)
    local sLo, sHi = span(spec)
    for _, node in ipairs(loose) do
        local dc = cLo and (node.x < cLo and cLo - node.x or node.x > cHi and node.x - cHi or 0) or math.huge
        local ds = sLo and (node.x < sLo and sLo - node.x or node.x > sHi and node.x - sHi or 0) or math.huge
        addTo(ds < dc and spec or class, node, out)
    end
    -- The hero tree choice sits centered above the hero talents.
    if selector then
        hero.selector = selector
        hero.drop = #hero.nodes > 0 and 1.25 or 0
        selector.tree = hero
        out.byID[selector.id] = selector
    end
    retailGrid(class)
    retailGrid(spec)
    if #hero.nodes > 0 then retailGrid(hero) end
    if selector then
        hero.nodes[#hero.nodes + 1] = selector
        selector.row = 0
        selector.col = math.max(((hero.cols or 1) - 1) / 2, 0)
        if #hero.nodes == 1 then hero.cols, hero.rows = 1, 1 end
        table.sort(hero.nodes, function(a, b) if a.row ~= b.row then return a.row < b.row end return a.col < b.col end)
    end
    local list = { class }
    if #hero.nodes > 0 then list[#list + 1] = hero end
    list[#list + 1] = spec
    for _, t in ipairs(list) do
        if #t.nodes > 0 then
            out.trees[#out.trees + 1] = t
            t.index = #out.trees
            out.spent = out.spent + t.spent
        end
    end
    out.retail = true
end

-- Points left per tree (t.left) and in all (data.left), from each tree's
-- own currency. Retail has two or three pools, not just the first.
function TD.RetailLeft(data)
    data.left = 0
    for _, t in ipairs(data.trees) do
        t.left = t.cur and data.currency[t.cur] or nil
        if t.left then data.left = data.left + t.left end
    end
end

-- Returns { configID, trees = { { groupID, name, icon, spent, cols, rows,
-- nodes = { ... } } }, left, spent, byID = { [nodeID] = node },
-- currency = { [traitCurrencyID] = points left } }, or nil when there's no
-- tree (no C_Traits or no config).
-- opts, used by the Legacy trees: treeID limits to one tree, step sets the
-- grid step ("auto" uses TD.Step), plus span and minimum cols/rows.
function TD.Read(configID, opts)
    local C = traits()
    configID = configID or TD.ConfigID()
    opts = opts or {}
    if not (C and configID) then return nil end
    local info = call(C.GetConfigInfo, configID)
    if type(info) ~= "table" or type(info.treeIDs) ~= "table" then return nil end
    local out = { configID = configID, trees = {}, left = 0, spent = 0, byID = {}, currency = {} }
    -- Mark staged nodes from GetStagedChanges, as the game's talent window
    -- does, rather than only comparing purchased and active ranks.
    local pending = {}
    local buys, _, swaps = call(C.GetStagedChanges, configID)
    for _, list in ipairs({ buys, swaps }) do
        for _, id in ipairs(type(list) == "table" and list or {}) do pending[id] = true end
    end
    for _, treeID in ipairs(opts.treeID and { opts.treeID } or info.treeIDs) do
        local groups = call(C.GetGroupDisplayInfoByTreeID, treeID)
        local mine, order = {}, {}
        for _, g in ipairs(type(groups) == "table" and groups or {}) do
            local t = { groupID = g.groupID, name = g.displayName or "", icon = g.icon, order = g.orderIndex or #order, spent = 0, nodes = {} }
            mine[g.groupID] = t
            order[#order + 1] = t
        end
        table.sort(order, function(a, b) return a.order < b.order end)
        local whole   -- used when the tree has no display groups
        if TD.RETAIL and #order == 0 then
            readRetail(C, configID, treeID, out, pending)
        end
        for _, id in ipairs(out.retail and {} or call(C.GetTreeNodes, treeID) or {}) do
            local n = call(C.GetNodeInfo, configID, id)
            if type(n) == "table" and n.isVisible ~= false and type(n.posX) == "number" and type(n.posY) == "number" then
                local t
                for _, g in ipairs(type(n.groupIDs) == "table" and n.groupIDs or {}) do
                    if mine[g] then t = mine[g] break end
                end
                if not t and #order == 0 then
                    whole = whole or { name = "", spent = 0, nodes = {} }
                    t = whole
                end
                if t then
                    local node = readNode(C, configID, id, n)
                    if pending[id] then node.staged = true end
                    node.tree = t
                    t.nodes[#t.nodes + 1] = node
                    t.spent = t.spent + (node.bought or node.rank)
                    out.byID[id] = node
                end
            end
        end
        if whole then order[#order + 1] = whole end
        for _, t in ipairs(out.retail and {} or order) do
            if #t.nodes > 0 then out.trees[#out.trees + 1] = t; t.index = #out.trees; out.spent = out.spent + t.spent end
        end
        local cur = call(C.GetTreeCurrencyInfo, configID, treeID, false)
        for i, c in ipairs(type(cur) == "table" and cur or {}) do
            if type(c) == "table" and type(c.quantity) == "number" then
                if i == 1 then out.left = out.left + c.quantity end
                if c.traitCurrencyID then out.currency[c.traitCurrencyID] = (out.currency[c.traitCurrencyID] or 0) + c.quantity end
            end
        end
    end
    if out.retail then   -- readRetail placed the nodes already
        TD.RetailLeft(out)
        return out
    end
    local o = { step = opts.step or TD.STEP, span = opts.span or TD.SPAN, cols = opts.cols or 4, rows = opts.rows or 7 }
    if o.step == "auto" then
        local xs, ys = {}, {}
        for _, node in pairs(out.byID) do xs[#xs + 1] = node.x; ys[#ys + 1] = node.y end
        o.step = math.min(TD.Step(xs), TD.Step(ys))
    end
    grid(out.trees, out.byID, o)
    return out
end

-- Re-query only the given nodes (ids = { [nodeID] = true }) and the point
-- pool, updating data in place: ranks, staged state, buy/refund flags.
-- Layout, names and icons are left alone. Builds.Load uses this between
-- ranks instead of re-reading the whole tree.
function TD.Refresh(data, ids)
    local C = traits()
    if not (C and data and data.configID) then return data end
    local configID = data.configID
    local pending = {}
    local buys, _, swaps = call(C.GetStagedChanges, configID)
    for _, list in ipairs({ buys, swaps }) do
        for _, id in ipairs(type(list) == "table" and list or {}) do pending[id] = true end
    end
    for id in pairs(ids) do
        local node = data.byID[id]
        local n = node and call(C.GetNodeInfo, configID, id)
        if type(n) == "table" then
            local bought, rank = TD.Ranks(n)
            local delta = bought - (node.bought or node.rank)
            if node.tree then node.tree.spent = node.tree.spent + delta end
            data.spent = data.spent + delta
            node.rank, node.bought = rank, bought
            node.active = type(n.activeRank) == "number" and n.activeRank or rank
            node.staged = pending[id] == true or rank > node.active
            node.canBuy, node.canRefund = TD.CanBuyInfo(n), TD.CanRefundInfo(n)
            node.available = n.isAvailable ~= false and n.meetsEdgeRequirements ~= false
            node.edgesMet = n.meetsEdgeRequirements ~= false
        end
    end
    local info = call(C.GetConfigInfo, configID)
    if type(info) == "table" and type(info.treeIDs) == "table" then
        data.left, data.currency = 0, {}
        for _, treeID in ipairs(info.treeIDs) do
            local cur = call(C.GetTreeCurrencyInfo, configID, treeID, false)
            for i, c in ipairs(type(cur) == "table" and cur or {}) do
                if type(c) == "table" and type(c.quantity) == "number" then
                    if i == 1 then data.left = data.left + c.quantity end
                    if c.traitCurrencyID then data.currency[c.traitCurrencyID] = (data.currency[c.traitCurrencyID] or 0) + c.quantity end
                end
            end
        end
        if data.retail then TD.RetailLeft(data) end
    end
    return data
end

-- Description for a rank (rank 0 uses rank 1). Empty until the client has
-- loaded the spell, typically on the first hover after login; the second
-- return is then true and TD.LoadSpell can request it.
function TD.Description(node, rank)
    local C = traits()
    if not (C and node and node.entryID) then return nil end
    local text = call(C.GetTraitDescription, node.entryID, math.max(rank or node.rank, 1))
    if type(text) == "string" and text ~= "" then return text end
    return nil, TD.Loading(node)
end

-- Full tooltip lines for a rank from C_TooltipInfo.GetTraitEntry, the same
-- data the game's talent buttons show (cost, range, cast time, cooldown,
-- then the description). Returns { left, right, lc, rc } entries with false
-- for blank lines, trimmed at both ends, or nil if there are none (use
-- TD.Description then). The title line and any secret text are dropped.
local function plainText(v)
    if type(v) ~= "string" or DUI.IsSecret(v) or v == "" then return nil end
    return v
end
function TD.EntryLines(node, rank)
    local TI = C_TooltipInfo
    if not (type(TI) == "table" and node and type(node.entryID) == "number") then return nil end
    local data = call(TI.GetTraitEntry, node.entryID, math.max(rank or node.rank, 1))
    if type(data) ~= "table" or type(data.lines) ~= "table" then return nil end
    local out = {}
    for _, line in ipairs(data.lines) do
        if type(line) == "table" then
            local left, right = plainText(line.leftText), plainText(line.rightText)
            if left or right then
                if not (left == node.name and not right) then
                    out[#out + 1] = { left = left or "", right = right, lc = line.leftColor, rc = line.rightColor }
                end
            elseif #out > 0 and out[#out] then
                out[#out + 1] = false
            end
        end
    end
    while #out > 0 and not out[#out] do out[#out] = nil end
    return #out > 0 and out or nil
end

-- True while the node's spell data isn't cached yet. The game's talent
-- buttons wait the same way (Spell:ContinueWithCancelOnSpellLoad).
function TD.Loading(node)
    local S = C_Spell
    if not (type(S) == "table" and node and type(node.spellID) == "number") then return false end
    return call(S.IsSpellDataCached, node.spellID) == false
end

-- SPELL_DATA_LOAD_RESULT fires when it arrives.
function TD.LoadSpell(node)
    local S = C_Spell
    if type(S) == "table" and node and type(node.spellID) == "number" then call(S.RequestLoadSpellData, node.spellID) end
end

-- Unmet requirements, in the game's words where possible: the tier rule
-- ("Spend 10 more points in Arms Talents"), then any prerequisite talent not
-- yet maxed. Each line is { text, name, tree }, where name is the tree or
-- talent to highlight and tree gives its color. nil when nothing is missing.
function TD.Missing(node, data)
    local out = {}
    local r = node.rule
    if r and not r.met then
        -- spentAmountRequired is already the remaining amount; the game
        -- prints it as is.
        local more = r.amount
        local ok, text = false, nil
        if type(r.format) == "string" then
            -- The client picks |4one:many; forms from the preceding number,
            -- so the tree name ("Enhancement |4Talent:Talents;") came out
            -- singular after "1 more point". It's a tree name, so force plural.
            local fmt = r.format
            local at = string.find(fmt, "%s", 1, true)
            if at then fmt = string.sub(fmt, 1, at + 1) .. (string.gsub(string.sub(fmt, at + 2), "|4[^:;]*:([^;]*);", "%1")) end
            ok, text = pcall(string.format, fmt, more, node.tree.name)
        end
        out[#out + 1] = { text = ok and text or string.format(L["Spend %d more |4point:points; in %s"], more, node.tree.name),
            name = node.tree.name, tree = node.tree }
    end
    if not node.edgesMet and data then
        for _, t in ipairs(data.trees) do
            for _, src in ipairs(t.nodes) do
                for _, e in ipairs(src.edges) do
                    if e.to == node.id and src.rank < src.max then
                        out[#out + 1] = { text = string.format(L["Requires %d |4point:points; in %s"], src.max, src.name), name = src.name }
                    end
                end
            end
        end
    end
    return #out > 0 and out or nil
end
