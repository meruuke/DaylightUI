-- Named talent builds per character and talent set, plus copying and pasting
-- the game's loadout string.
--
-- Loading a build only stages ranks, one at a time through Spend, top row
-- first. Nothing is learned until Apply, and Undo drops it all. Applied points
-- can't be refunded on Forever (only a trainer resets them), so a build that
-- lacks a talent you already learned is refused. Ranks you can't afford yet
-- are left for later, so a leveling build fills in as you level.
--
-- Saved in DB.Character().talentBuilds[group] = { { name, ranks = { [nodeID] = ranks } } }.

local _, DUI = ...
DUI.Book = DUI.Book or {}   -- the book window's own namespace
local ns = DUI.Book
local L = DUI.L
local Style = DUI.Style

local Builds = {}
ns.Builds = Builds

Builds.MAX = 20        -- builds kept per set
Builds.SAY = 4         -- seconds the result line stays up
Builds.STEPS = 200     -- safety cap on ranks staged per load

local function call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a = pcall(fn, ...)
    if ok then return a end
end

-- Builds saved for the talent set on screen.
function Builds.List(group)
    local char = DUI.DB.Character()
    if type(char) ~= "table" then return {} end
    char.talentBuilds = type(char.talentBuilds) == "table" and char.talentBuilds or {}
    group = group or ns.Spend.Group()
    char.talentBuilds[group] = type(char.talentBuilds[group]) == "table" and char.talentBuilds[group] or {}
    return char.talentBuilds[group]
end

local function read() return ns.TalentData.Read(ns.Spend.Config()) end

-- Save the current points, staged ones included, replacing any build with
-- the same name. Returns nil when no points are spent.
function Builds.Save(name)
    name = type(name) == "string" and string.match(name, "^%s*(.-)%s*$") or ""
    if name == "" then return nil end
    local data = read()
    if not data then return nil end
    local ranks, any = {}, false
    for id, node in pairs(data.byID) do
        if node.rank > 0 then ranks[id] = node.rank; any = true end
    end
    if not any then return nil end
    local list = Builds.List()
    local build = { name = name, ranks = ranks }
    for i, b in ipairs(list) do
        if b.name == name then list[i] = build; return build end
    end
    if #list >= Builds.MAX then return nil end
    list[#list + 1] = build
    return build
end

function Builds.Delete(i)
    local list = Builds.List()
    if list[i] then table.remove(list, i) return true end
    return false
end

-- Returns why the build can't be loaded, or nil. data is an optional
-- TalentData read to reuse.
function Builds.Conflict(build, data)
    if InCombatLockdown() then return ERR_NOT_IN_COMBAT or L["Not in combat."] end
    if ns.Spend.committing then return L["Wait for the talents being applied."] end
    if ns.Spend.Locked() then return L["Activate this set first."] end
    data = data or read()
    if not data then return L["Talents aren't available yet."] end
    local ranks = type(build) == "table" and type(build.ranks) == "table" and build.ranks or {}
    for id, node in pairs(data.byID) do
        if node.active > (ranks[id] or 0) then
            return L["You've already learned talents this build doesn't have. A trainer can reset them."]
        end
    end
end

-- Pick the next rank to stage in the order tiers unlock: row, then tree,
-- then column.
local function nextRank(data, ranks)
    local best
    for ti, t in ipairs(data.trees) do
        for _, node in ipairs(t.nodes) do
            local want = ranks[node.id] or 0
            if node.rank < want and ns.Spend.CanBuy(node, data) then
                local key = node.row * 10000 + ti * 100 + node.col
                if not best or key < best.key then best = { node = node, key = key } end
            end
        end
    end
    return best and best.node
end

local function missing(data, ranks)
    local n = 0
    for id, want in pairs(ranks) do
        local node = data.byID[id]
        n = n + math.max(want - (node and node.rank or 0), 0)
    end
    return n
end

-- Stage a build, given as a list index or a build table. Returns the number
-- staged and a reason: why it failed, or how many points are left over.
function Builds.Load(build)
    if type(build) == "number" then build = Builds.List()[build] end
    if type(build) ~= "table" then return 0 end
    local data = read()
    local why = Builds.Conflict(build, data)
    if why then return 0, why end
    -- Clear any staged ranks first. Learned ones stay (Conflict checked them).
    if ns.Spend.HasChanges() then ns.Spend.Undo(); data = read() end
    local ranks, staged = build.ranks, 0
    -- After each rank, refresh only the build's nodes and the point pool
    -- instead of re-reading the whole tree.
    for _ = 1, Builds.STEPS do
        local node = data and nextRank(data, ranks)
        if not (node and ns.Spend.Buy(node, data)) then break end
        staged = staged + 1
        ns.TalentData.Refresh(data, ranks)
    end
    if ns.Talents then ns.Talents.Soon() end
    local short = data and missing(data, ranks) or 0
    if short > 0 then return staged, string.format(L["%d |4point:points; left for later."], short) end
    return staged
end

-- ---------------------------------------------------------------------
-- Retail: the game's own loadouts (C_ClassTalents), handled the way
-- Blizzard_ClassTalentsFrame.lua does. Builds above stay for Forever.
-- ---------------------------------------------------------------------

local function retail() return ns.TalentData and ns.TalentData.RETAIL end
local function CT() return type(C_ClassTalents) == "table" and C_ClassTalents or nil end
local function trim(s) return type(s) == "string" and string.match(s, "^%s*(.-)%s*$") or "" end

local function specID()
    local id = type(PlayerUtil) == "table" and call(PlayerUtil.GetCurrentSpecID)
    if type(id) == "number" then return id end
    local S = C_SpecializationInfo
    local index = type(S) == "table" and call(S.GetSpecialization) or call(GetSpecialization)
    id = index and (type(S) == "table" and call(S.GetSpecializationInfo, index) or call(GetSpecializationInfo, index))
    return type(id) == "number" and id or nil
end

-- The spec's saved loadouts, in the game's order: { { id, name } }.
function Builds.Loadouts()
    local C, spec, out = CT(), specID(), {}
    local ids = C and spec and call(C.GetConfigIDsBySpecID, spec)
    for _, id in ipairs(type(ids) == "table" and ids or {}) do
        local info = call(C_Traits.GetConfigInfo, id)
        if type(info) == "table" then out[#out + 1] = { id = id, name = info.name or "" } end
    end
    return out
end

-- The loadout the game shows as selected, or nil (none, or not retail).
function Builds.Selected()
    if not retail() then return nil end
    local C, spec = CT(), specID()
    local id = C and spec and call(C.GetLastSelectedSavedConfigID, spec)
    return type(id) == "number" and id or nil
end

local function nameOf(id)
    local info = id and call(C_Traits.GetConfigInfo, id)
    return type(info) == "table" and info.name or ""
end

local function markSelected(id)
    local C, spec = CT(), specID()
    if C and spec then pcall(C.UpdateLastSelectedSavedConfigID, spec, id) end
end

-- Switch to a loadout and apply it. Returns ok and "same", "loading",
-- "ready" (staged, Apply finishes it) or, when not ok, why.
function Builds.LoadSaved(id)
    if InCombatLockdown() then return false, ERR_NOT_IN_COMBAT or L["Not in combat."] end
    if ns.Spend.committing then return false, L["Wait for the talents being applied."] end
    local C = CT()
    if not (C and id) then return false end
    if ns.Spend.HasChanges() then ns.Spend.Undo() end
    local ok, result, err = pcall(C.LoadConfig, id, true)
    if not ok then return false, tostring(result) end
    local R = type(Enum) == "table" and Enum.LoadConfigResult or {}
    if result == (R.Error or 0) then
        return false, type(err) == "string" and err ~= "" and err or L["That loadout can't be loaded right now."]
    end
    markSelected(id)
    if result == (R.LoadInProgress or 2) then ns.Spend.Begin(); return true, "loading" end
    if ns.Talents then ns.Talents.Soon() end
    if result == (R.Ready or 3) then return true, "ready" end
    return true, "same"
end

local function sayLoaded(id, ok, how)
    local name = nameOf(id)
    if not ok then Builds.Say(how or L["That loadout can't be loaded right now."], true)
    elseif how == "loading" then Builds.Say(string.format(L["Switching to %s..."], name))
    elseif how == "ready" then Builds.Say(string.format(L["%s is ready: Apply to learn it."], name))
    else Builds.Say(string.format(L["Now using %s."], name)) end
end

-- A new loadout from the talents you have now. The game answers with
-- TRAIT_CONFIG_CREATED; the new loadout is then selected.
function Builds.NewLoadout(name)
    name = trim(name)
    if name == "" then return false, L["Give it a name."] end
    local C = CT()
    if not (C and call(C.CanCreateNewConfig)) then
        return false, TALENT_FRAME_NEW_LOADOUT_DISABLED_TOOLTIP or L["You have as many loadouts as the game allows."]
    end
    if call(C.RequestNewConfig, name) ~= true then return false, L["The game refused the new loadout."] end
    Builds.creating = true
    return true
end

function Builds.RenameLoadout(id, name)
    name = trim(name)
    local C = CT()
    if name == "" or not (C and id) then return false, L["Give it a name."] end
    call(C.RenameConfig, id, name)
    return true
end

function Builds.DeleteLoadout(id)
    local C = CT()
    if not (C and id) then return false end
    local was = Builds.Selected() == id
    call(C.DeleteConfig, id)
    if was then markSelected(nil) end
    return true
end

-- The game's own loadout string code (Blizzard_ClassTalentImportExport.lua),
-- pointed at the active config instead of the game's talent frame.
local function gameIO()
    if type(ClassTalentImportExportMixin) ~= "table" then
        local load = (type(C_AddOns) == "table" and C_AddOns.LoadAddOn) or LoadAddOn
        pcall(load, "Blizzard_PlayerSpells")
    end
    local M = ClassTalentImportExportMixin
    if type(M) ~= "table" or type(CreateFromMixins) ~= "function" then return nil end
    local configID = ns.Spend.Config()
    local info = configID and call(C_Traits.GetConfigInfo, configID)
    local treeID = type(info) == "table" and type(info.treeIDs) == "table" and info.treeIDs[1]
    if not treeID then return nil end
    local io = CreateFromMixins(M)
    io.IsInspecting = function() return false end
    io.GetConfigID = function() return configID end
    io.GetTreeInfo = function() return call(C_Traits.GetTreeInfo, configID, treeID) or { ID = treeID } end
    io.ShowImportError = function(self, text) self.err = text end
    io.OnTraitConfigCreateStarted = function() end
    return io
end

-- Import a pasted string as a new loadout, like the game's Import dialog.
function Builds.ImportLoadout(text)
    text = trim(text)
    if text == "" then return false, LOADOUT_ERROR_BAD_STRING or L["Paste a talent string first."] end
    local C = CT()
    if not (C and call(C.CanCreateNewConfig)) then
        return false, TALENT_FRAME_NEW_LOADOUT_DISABLED_TOOLTIP or L["You have as many loadouts as the game allows."]
    end
    local io = gameIO()
    if not io then return false, L["The game's talent tools aren't available."] end
    local name = string.format(L["Imported %d"], #Builds.Loadouts() + 1)
    local ok, took = pcall(io.ImportLoadout, io, text, name)
    if ok and took then Builds.creating = true; return true end
    return false, io.err or (not ok and tostring(took)) or LOADOUT_ERROR_IMPORT_FAILED or L["That string didn't import."]
end

-- A new loadout is ready once the game has filled it (IsConfigPopulated),
-- as in ClassTalentsFrameMixin:OnEvent.
local function created(id)
    Builds.creating, Builds.waitFor = nil, nil
    local ok, how = Builds.LoadSaved(id)
    if ok and how == "same" then Builds.Say(string.format(L["Saved %s."], nameOf(id)))
    else sayLoaded(id, ok, how) end
end

function Builds.Events()
    if Builds.listening or not retail() then return end
    Builds.listening = true
    DUI.RegisterEvent("TRAIT_CONFIG_CREATED", function(_, info)
        if not Builds.creating or type(info) ~= "table" then return end
        local combat = type(Enum) == "table" and Enum.TraitConfigType and Enum.TraitConfigType.Combat or 1
        if info.type ~= combat then return end
        if call(CT().IsConfigPopulated, info.ID) == false then Builds.waitFor = info.ID
        else created(info.ID) end
    end)
    DUI.RegisterEvent("TRAIT_CONFIG_UPDATED", function(_, id)
        if Builds.waitFor and id == Builds.waitFor then created(id) end
    end)
end

-- Prefer the client's GenerateImportString, fall back to the encoder here.
function Builds.Copy()
    if retail() then
        local io = gameIO()
        if io then
            local ok, text = pcall(io.GetLoadoutExportString, io)
            if ok and type(text) == "string" and text ~= "" then return text end
        end
    end
    local configID = ns.Spend.Config()
    if not configID then return nil end
    local C = type(C_Traits) == "table" and C_Traits or nil
    local text = C and call(C.GenerateImportString, configID)
    if type(text) == "string" and text ~= "" then return text end
    return ns.LoadoutString.Encode(configID)
end

-- Stage a pasted loadout string. Same returns as Builds.Load.
function Builds.Paste(text)
    local got, err = ns.LoadoutString.Decode(text, ns.Spend.Config())
    if not got then return 0, err end
    return Builds.Load({ name = "", ranks = got.ranks })
end

-- ---------------------------------------------------------------------
-- UI: Builds button and menu, a small input box, and a result line
-- ---------------------------------------------------------------------

function Builds.Say(text, bad)
    local page = Builds.page
    if not page then return end
    local fs = page.buildSay
    fs:SetText(text or "")
    local c = bad and DUI.Tips.WARN or DUI.Tips.TEXT
    fs:SetTextColor(c[1], c[2], c[3], 1)
    fs:SetShown(text ~= nil)
    local token = {}
    Builds.sayToken = token
    C_Timer.After(Builds.SAY, function() if Builds.sayToken == token then fs:Hide() end end)
end

local function report(staged, reason)
    if staged > 0 then
        local text = string.format(L["%d |4point:points; ready: Apply to learn them."], staged)
        if reason then text = text .. "  " .. reason end
        Builds.Say(text)
    else
        Builds.Say(reason or L["Nothing to change."], reason ~= nil)
    end
end

local function makeBox(page)
    local W = DUI.Widgets
    local box = CreateFrame("Frame", nil, page)
    box:SetSize(360, 112)
    box:SetPoint("TOP", page, "TOP", 0, -40)
    box:SetFrameLevel(page:GetFrameLevel() + 40)
    box:EnableMouse(true)
    Style.Shell(box, {})
    box.title = Style.Text(box, Style.SIZE.head, "LEFT")
    box.title:SetPoint("TOPLEFT", box, "TOPLEFT", 12, -10)
    local edit = W.Input(box, { height = 24 })
    edit:SetWidth(336)
    edit:SetPoint("TOPLEFT", box, "TOPLEFT", 12, -32)
    edit:SetScript("OnEscapePressed", function() Builds.CloseBox() end)
    edit:SetScript("OnEnterPressed", function() Builds.Confirm() end)
    box.edit = edit
    box.note = Style.Text(box, Style.SIZE.small, "LEFT")
    box.note:SetPoint("TOPLEFT", edit, "BOTTOMLEFT", 0, -6)
    box.note:SetWidth(336)
    box.ok = W.Button(box, OKAY or L["OK"], 22)
    box.ok:SetWidth(80)
    box.ok:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -10, 10)
    box.ok:SetScript("OnClick", function() Builds.Confirm() end)
    box.cancel = W.Button(box, CANCEL or L["Cancel"], 22)
    box.cancel:SetWidth(80)
    box.cancel:SetPoint("RIGHT", box.ok, "LEFT", -6, 0)
    box.cancel:SetScript("OnClick", function() Builds.CloseBox() end)
    box:Hide()
    return box
end

-- mode is "save" (ask for a name), "copy" (show the string selected) or "paste".
function Builds.OpenBox(mode)
    local page = Builds.page
    if not page then return end
    page.buildBox = page.buildBox or makeBox(page)
    local box = page.buildBox
    box.mode = mode
    box.note:SetText("")
    local tc = DUI.Tips.TEXT
    box.note:SetTextColor(tc[1], tc[2], tc[3], 1)
    if mode == "save" then
        box.title:SetText(L["Save these talents as"])
        box.edit:SetText(string.format(L["Build %d"], #Builds.List() + 1))
    elseif mode == "new" then
        box.title:SetText(L["Save these talents as a new loadout"])
        box.edit:SetText(string.format(L["Loadout %d"], #Builds.Loadouts() + 1))
    elseif mode == "rename" then
        box.title:SetText(L["Rename this loadout"])
        box.edit:SetText(nameOf(Builds.Selected()))
    elseif mode == "import" then
        box.title:SetText(L["Paste a talent string to import as a new loadout"])
        box.edit:SetText("")
    elseif mode == "copy" then
        box.title:SetText(L["Talent string: press Ctrl+C to copy"])
        box.edit:SetText(Builds.Copy() or "")
    else
        box.title:SetText(L["Paste a talent string"])
        box.edit:SetText("")
    end
    box.ok:SetShown(mode ~= "copy")
    box.cancel.text:SetText(mode == "copy" and (CLOSE or L["Close"]) or (CANCEL or L["Cancel"]))
    local opening = not DUI.Motion.Shown(box)
    box:Show()
    if opening then DUI.Motion.Appear(box, 6) end
    box.edit:SetFocus()
    box.edit:HighlightText()
end

function Builds.CloseBox()
    local box = Builds.page and Builds.page.buildBox
    if box then box.edit:ClearFocus(); DUI.Motion.Vanish(box) end
end

function Builds.Confirm()
    local box = Builds.page and Builds.page.buildBox
    if not (box and DUI.Motion.Shown(box)) then return end
    local text = box.edit:GetText() or ""
    local warn = DUI.Tips.WARN
    if box.mode == "new" or box.mode == "rename" or box.mode == "import" then
        local ok, why
        if box.mode == "new" then ok, why = Builds.NewLoadout(text)
        elseif box.mode == "rename" then ok, why = Builds.RenameLoadout(Builds.Selected(), text)
        else ok, why = Builds.ImportLoadout(text) end
        if ok then
            Builds.CloseBox()
            if box.mode == "rename" then Builds.Say(string.format(L["Renamed to %s."], trim(text))) end
        else
            box.note:SetText(why or L["Nothing to change."])
            box.note:SetTextColor(warn[1], warn[2], warn[3], 1)
        end
    elseif box.mode == "save" then
        if Builds.Save(text) then
            Builds.CloseBox()
            Builds.Say(string.format(L["Saved %s."], text))
        else
            box.note:SetText(#Builds.List() >= Builds.MAX and L["That's as many builds as a set keeps: delete one first."]
                or L["Spend some points first, and give it a name."])
            box.note:SetTextColor(warn[1], warn[2], warn[3], 1)
        end
    elseif box.mode == "paste" then
        local staged, reason = Builds.Paste(text)
        if staged > 0 then
            Builds.CloseBox()
            report(staged, reason)
        else
            box.note:SetText(reason or L["Nothing to change."])
            box.note:SetTextColor(warn[1], warn[2], warn[3], 1)
        end
    else
        Builds.CloseBox()
    end
end

-- Retail menu: the spec's loadouts (the selected one marked), then actions.
function Builds.LoadoutMenu(owner)
    local W = DUI.Widgets
    local list = Builds.Loadouts()
    local selected = Builds.Selected()
    local keys, values = {}, {}
    for _, l in ipairs(list) do
        keys[#keys + 1] = l.id
        values[l.id] = l.name
    end
    local function add(k, text) keys[#keys + 1] = k; values[k] = text end
    add("new", L["New loadout from these talents..."])
    if selected then add("rename", string.format(L["Rename %s..."], nameOf(selected))) end
    add("copy", L["Copy talent string"])
    add("import", L["Import talent string..."])
    if #list > 0 then add("delete", L["Delete a loadout..."]) end
    W.OpenMenu(owner, keys, values, selected, function(k)
        if type(k) == "number" then
            sayLoaded(k, Builds.LoadSaved(k))
        elseif k == "delete" then
            local dk, dv = {}, {}
            for i, l in ipairs(list) do dk[i] = l.id; dv[l.id] = string.format(L["Delete %s"], l.name) end
            W.OpenMenu(owner, dk, dv, nil, function(id)
                local name = nameOf(id)
                if Builds.DeleteLoadout(id) then Builds.Say(string.format(L["Deleted %s."], name)) end
            end, 220)
        else
            Builds.OpenBox(k)
        end
    end, 220)
end

function Builds.Menu(owner)
    if retail() then return Builds.LoadoutMenu(owner) end
    local W = DUI.Widgets
    local list = Builds.List()
    local keys, values = {}, {}
    for i, b in ipairs(list) do
        keys[#keys + 1] = i
        values[i] = b.name
    end
    local function add(k, text) keys[#keys + 1] = k; values[k] = text end
    add("save", L["Save these talents..."])
    add("copy", L["Copy talent string"])
    add("paste", L["Paste talent string..."])
    if #list > 0 then add("delete", L["Delete a build..."]) end
    W.OpenMenu(owner, keys, values, nil, function(k)
        if type(k) == "number" then
            report(Builds.Load(k))
        elseif k == "delete" then
            local dk, dv = {}, {}
            for i, b in ipairs(list) do dk[i] = i; dv[i] = string.format(L["Delete %s"], b.name) end
            W.OpenMenu(owner, dk, dv, nil, function(i)
                local name = list[i] and list[i].name
                if Builds.Delete(i) then Builds.Say(string.format(L["Deleted %s."], name)) end
            end, 200)
        else
            Builds.OpenBox(k)
        end
    end, 200)
end

function Builds.Build(page)
    Builds.page = page
    local W = DUI.Widgets
    local b = W.Button(page, retail() and L["Loadouts"] or L["Builds"], 24)
    b:SetWidth(retail() and 84 or 72)
    b:SetPoint("RIGHT", page.search, "LEFT", -8, 0)
    b:SetScript("OnClick", function(self) Builds.Menu(self) end)
    b:HookScript("OnEnter", function(self)
        if retail() then
            local using = Builds.Selected()
            W.Tooltip(self, L["Loadouts"], (using and string.format(L["Using %s."], nameOf(using)) .. "\n" or "")
                .. L["Switch between your saved talent loadouts, make a new one, or copy and import a talent string."])
        else
            W.Tooltip(self, L["Builds"], L["Keep these talents under a name and put them back later, or copy and paste a talent string."])
        end
    end)
    Builds.Events()
    b:HookScript("OnLeave", function() W.HideTooltip() end)
    page.builds = b
    page.buildSay = Style.Text(page, Style.SIZE.small, "CENTER")
    page.buildSay:SetPoint("BOTTOM", page, "BOTTOM", 0, 46)   -- just over the footer's line
    page.buildSay:Hide()
    page:HookScript("OnHide", function() Builds.CloseBox() end)
end
