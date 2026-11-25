local ADDON, ns = ...

local Store = {}
ns.Store = Store

local L = ns.L
local SCHEMA = 3
local DB
local CopyHist

Store.DEFAULTS = {
    tooltip = true,
    tooltipSources = 3,
    tooltipUnit = true,
    tooltipBars = true,
    tooltipObject = true,
    tooltipObjectHook = false,
    tooltipPageHint = true,
    altClickPage = false,
    autoScanAH = true,
    sync = true,
    useGuild = true,
    useCommunity = true,
    streakAlerts = true,
    countGroupKills = true,
    useCombatLog = false,
    tracker = true,
    browserBagsOnly = true,
    arrow = true,
    minimap = true,
    minimapAngle = 220,
    debug = false,
}

local function Tbl(t) return type(t) == "table" and t or {} end

-- Realm of the prices: GetNormalizedRealmName can be "" early in loading (and was on WoW Forever);
-- an empty name made the website drop every uploaded price.
local function RealmName()
    local r = GetNormalizedRealmName and GetNormalizedRealmName()
    if (not r or r == "") and GetRealmName then
        r = GetRealmName()
        r = r and r:gsub("[%s%-]", "")
    end
    if r and r ~= "" then return r end
    return nil
end

local function NewUid()
    local a = math.random(0, 0x7fffffff)
    local b = (math.floor((ns.time() or 0) + (GetTime() or 0) * 1000)) % 0x7fffffff
    return string.format("%08x%08x", a, b)
end

local function EnsureItem(itemId)
    local it = DB.items[itemId]
    if not it then
        it = { src = {} }
        DB.items[itemId] = it
    end
    it.src = Tbl(it.src)
    return it
end

local pendingInfo = {}

-- Item facts kept for export and the website (the client only knows items it has cached):
-- n name (client language), ql quality, v vendor sell price, il item level, rq required level,
-- cl / sc class and subclass ids, eq equip slot token, ic icon, sk stack size, bd bind type.
local ITEM_FACTS = { "n", "ql", "v", "il", "rq", "cl", "sc", "bd", "eq", "ic", "sk" }

function Store.RefreshItemInfo(itemId)
    local it = EnsureItem(itemId)
    local d = ns.ItemDetails(itemId)
    if d.name then
        local old = {}
        for _, f in ipairs(ITEM_FACTS) do
            old[f] = it[f]
        end
        it.n = d.name
        it.ql = d.quality
        if d.sellPrice and d.sellPrice > 0 then it.v = d.sellPrice end
        it.il = (d.ilvl and d.ilvl > 0) and d.ilvl or nil
        it.rq = (d.minLevel and d.minLevel > 0) and d.minLevel or nil
        it.cl, it.sc, it.bd = d.classId, d.subclassId, d.bind
        it.eq = d.equipLoc
        it.ic = d.texture
        it.sk = (d.stack and d.stack > 1) and d.stack or nil
        pendingInfo[itemId] = nil
        for _, f in ipairs(ITEM_FACTS) do
            if old[f] ~= it[f] then
                Store.Mark(it)
                break
            end
        end
        return true
    end
    pendingInfo[itemId] = true
    return false
end

function Store.Item(itemId)
    local it = EnsureItem(itemId)
    if not it.n then Store.RefreshItemInfo(itemId) end
    return it
end

-- ---------------------------------------------------------------- migrations

local function MigrateV1(db)
    if type(db.kills) ~= "table" then return end
    db.sources = Tbl(db.sources)
    for k, kills in pairs(db.kills) do
        local rec = db.sources[k] or { kind = "mob", kills = 0, attempts = 0, loot = {}, streak = {} }
        rec.name = rec.name or (type(db.names) == "table" and db.names[k]) or nil
        rec.kills = kills
        if type(db.corpses) == "table" and db.corpses[k] then rec.attempts = db.corpses[k] end
        if type(db.loot) == "table" and type(db.loot[k]) == "table" then
            for itemId, l in pairs(db.loot[k]) do
                rec.loot[itemId] = { d = l.d or 0, q = l.q or 0 }
            end
        end
        db.sources[k] = rec
    end
    db.kills, db.corpses, db.loot, db.names = nil, nil, nil, nil
end

local function MigrateV2(db)
    db.items = Tbl(db.items)
    local function item(id)
        local it = db.items[id]
        if not it then
            it = { src = {} }
            db.items[id] = it
        end
        return it
    end
    for id, name in pairs(Tbl(db.itemNames)) do
        item(id).n = name
    end
    for id, v in pairs(Tbl(db.prices)) do
        if tonumber(v) and v > 0 then item(id).v = v end
    end
    for key, rec in pairs(Tbl(db.sources)) do
        for id in pairs(Tbl(rec.loot)) do
            item(id).src[key] = true
        end
    end
    local oldAh = Tbl(db.ah)
    db.ah = {}
    for id, r in pairs(oldAh) do
        if type(r) == "table" and type(r.listings) == "table" and next(r.listings) then
            local list = {}
            for p, q in pairs(r.listings) do
                list[#list + 1] = { p = p, q = q }
            end
            ns.Prices.Commit(id, list, r.t, db)
        elseif type(r) == "table" and r.days then
            db.ah[id] = r
        end
    end
    db.itemNames, db.prices = nil, nil
end

local function Normalize(db)
    db.sources = Tbl(db.sources)
    db.items = Tbl(db.items)
    db.ah = Tbl(db.ah)
    db.maps = Tbl(db.maps)
    db.displays = Tbl(db.displays) -- npc id -> creature display id (portraits; personal, never shared)
    db.peers = Tbl(db.peers)
    db.farm = Tbl(db.farm)
    db.farm.hist = Tbl(db.farm.hist)
    db.farm.goals = Tbl(db.farm.goals)
    db.kpi = Tbl(db.kpi)
    db.kpi.cal = Tbl(db.kpi.cal)
    db.kpi.days = Tbl(db.kpi.days)
    db.baseline = Tbl(db.baseline)
    db.baseline.src = Tbl(db.baseline.src)
    db.totals = Tbl(db.totals)
    db.totals.kills = db.totals.kills or 0
    db.totals.attempts = db.totals.attempts or 0
    db.totals.items = db.totals.items or 0
    db.meta = Tbl(db.meta)
    db.meta.uid = db.meta.uid or NewUid()
    db.meta.rev = db.meta.rev or 0
    db.meta.created = db.meta.created or ns.time()
    -- uploads carry the client language so shared names can be shown per locale
    db.meta.locale = (GetLocale and GetLocale()) or db.meta.locale
    -- auction prices belong to a realm and faction (no character names are stored)
    db.meta.realm = RealmName() or (db.meta.realm ~= "" and db.meta.realm or nil)
    db.settings = Tbl(db.settings)
    for k, v in pairs(Store.DEFAULTS) do
        if db.settings[k] == nil then db.settings[k] = v end
    end
    -- Records carry rv, the revision of their last change, so share strings can leave out what this
    -- installation's upload in the community file already has (Store.Snapshot opts.since). Records
    -- from before rv existed count as changed now; the current revision may already be uploaded.
    db.meta.sealed = db.meta.sealed or db.meta.rev
    if not db.meta.rvInit then
        for _, section in ipairs({ db.sources, db.items, db.ah, db.vendors, db.npcs, db.recipes }) do
            if type(section) == "table" then
                for _, r in pairs(section) do
                    if type(r) == "table" and r.rv == nil then r.rv = db.meta.rev end
                end
            end
        end
        db.meta.rvInit = true
    end
    -- empty loot windows without a source used to land here; nothing to learn from them
    local other = db.sources["kind:other"]
    if type(other) == "table" and type(other.loot) == "table" and not next(other.loot) then
        db.sources["kind:other"] = nil
    end
    for key, rec in pairs(db.sources) do
        if type(rec) ~= "table" then
            db.sources[key] = nil
        else
            rec.kind = rec.kind or "other"
            rec.kills = rec.kills or 0
            rec.attempts = rec.attempts or 0
            rec.gk = rec.gk or 0
            rec.ga = rec.ga or 0
            rec.money = rec.money or 0
            rec.loot = Tbl(rec.loot)
            rec.streak = Tbl(rec.streak)
            rec.spawns = Tbl(rec.spawns)
            -- records from before loot-based counting: assume every kill was looted
            if rec.kind == "mob" and rec.lb == nil then rec.lb = rec.kills end
        end
    end
end

function Store.Init(saved)
    local db = type(saved) == "table" and saved or {}
    if type(MobLootDB) == "table" and not db.sources then
        for k, v in pairs(MobLootDB) do
            db[k] = v
        end
    end
    MobLootDB = nil
    MigrateV1(db)
    if (db.version or 1) < 3 then
        db.sources = Tbl(db.sources)
        MigrateV2(db)
    end
    Normalize(db)
    db.version = SCHEMA
    DB = db
    ns.db = db
    Store.RebuildIndex()
    Store.UpdateBaseline()
    return db
end

ns.RegisterEvent("ADDON_LOADED", function(name)
    if name ~= ADDON then return end
    -- "ItemsDB" was this addon's earlier name: its saved data is taken over once (the old file has to
    -- be renamed to WorldCodex.lua, see README) and the old variable is not saved again.
    local saved = WorldCodexDB
    if type(saved) ~= "table" and type(ItemsDB) == "table" then saved = ItemsDB end
    WorldCodexDB = Store.Init(saved)
    ItemsDB = nil
    Store.Prune()
    ns.Fire("DB_READY", ns.db)
end)

local function UpdateRealm()
    if DB then DB.meta.realm = RealmName() or DB.meta.realm end
end
ns.RegisterEvent("PLAYER_ENTERING_WORLD", UpdateRealm)

ns.RegisterEvent("PLAYER_LOGIN", function()
    if not DB then return end
    UpdateRealm()
    local faction = UnitFactionGroup and UnitFactionGroup("player")
    if faction == "Alliance" or faction == "Horde" then DB.meta.faction = faction end
end)

ns.RegisterEvent("PLAYER_LOGOUT", function()
    if not DB then return end
    DB.meta.saved = ns.time()
    -- the saved file can be uploaded: its revision is published (see Store.Mark)
    Store.Seal(DB.meta.rev)
end)

ns.RegisterEvent("GET_ITEM_INFO_RECEIVED", function(itemId, success)
    if DB and pendingInfo[itemId] and success ~= false then Store.RefreshItemInfo(itemId) end
end)

-- ---------------------------------------------------------------- personal data

-- Sample size for drop rates. Mobs: corpses that were looted or confirmed empty (rec.lb); kills that
-- were never looted are left out. Everything else: loot attempts.
function Store.Base(rec)
    if not rec then return 0 end
    if rec.kind == "mob" then
        if rec.lb then return rec.lb end
        if (rec.kills or 0) > 0 then return rec.kills end
    end
    return rec.attempts or 0
end

function Store.EnsureSource(key, name, kind)
    local rec = DB.sources[key]
    if not rec then
        rec = {
            name = name,
            kind = kind or "other",
            kills = 0,
            attempts = 0,
            gk = 0,
            ga = 0,
            money = 0,
            loot = {},
            streak = {},
            spawns = {},
            first = ns.time(),
            lb = (kind == "mob") and 0 or nil,
        }
        DB.sources[key] = rec
    end
    if name and name ~= "" then rec.name = name end
    if kind and (rec.kind == "other" or not rec.kind) then rec.kind = kind end
    if not rec.name then Store.NameFromCache(key, rec) end
    return rec
end

-- ---------------------------------------------------------------- creature names

-- Unit names are secret in instances on Midnight-era clients, so a dungeon mob can be recorded by its
-- npc id alone (the loot window names the corpse's GUID, not the mob). Such records get their name
-- from the npc id (ns.CreatureName): right away when the client has the creature cached, else a few
-- seconds later (the first lookup asks the server). Displays never wait: Store.SourceMeta falls
-- back to the creature cache too.
local unnamed = {} -- source key -> failed tries; false = given up for this session
local NAME_TRIES = 30
local NAME_EVERY = 2

local function CreatureOf(key)
    if type(key) == "number" then return key end
    return ns.Lookup and ns.Lookup.NpcId and ns.Lookup.NpcId(key) or nil
end

function Store.QueueName(key)
    if unnamed[key] == nil and CreatureOf(key) then unnamed[key] = 0 end
end

-- Names a record from the creature cache now, or queues it.
function Store.NameFromCache(key, rec)
    local npc = CreatureOf(key)
    if not npc then return end
    local name = ns.CreatureName(npc)
    if name then
        rec.name = name
    else
        Store.QueueName(key)
    end
end

-- Returns how many names were found.
function Store.ResolveNames(limit)
    if not next(unnamed) then return 0 end
    local found, looked = 0, 0
    for key, tries in pairs(unnamed) do
        if looked >= (limit or 10) then break end
        local rec = DB.sources[key]
        if not rec or rec.name then
            unnamed[key] = nil
        elseif tries ~= false then
            looked = looked + 1
            local name, why = ns.CreatureName(CreatureOf(key))
            if name then
                rec.name = name
                Store.Mark(rec)
                unnamed[key] = nil
                found = found + 1
            elseif why == "secret" then
                break -- hidden here (instance): not a failed try, asked again after leaving
            else
                unnamed[key] = tries + 1 < NAME_TRIES and tries + 1 or false
            end
        end
    end
    if found > 0 then ns.Fire("DATA_CHANGED", "names") end
    return found
end

-- A new zone (leaving a dungeon): names given up on are asked again.
ns.RegisterEvent("PLAYER_ENTERING_WORLD", function()
    for key, tries in pairs(unnamed) do
        if tries == false then unnamed[key] = 0 end
    end
end)

ns.On("DB_READY", function(db)
    for key, rec in pairs(db.sources) do
        if not rec.name then Store.QueueName(key) end
    end
    ns.Every(NAME_EVERY, function() Store.ResolveNames(10) end)
end)

-- Change tracking for exports. rec.rv is the revision of a record's last change. A revision that was
-- published (share string built, saved file written at logout) is sealed: the next change opens a
-- new one, so "changed after the upload with revision R" is exactly rv > R.
Store.gen = 0 -- bumped on every marked change (export cache key)

function Store.Mark(rec, db)
    db = db or DB
    local meta = db and db.meta
    if type(meta) ~= "table" or not meta.rev then return end
    if meta.sealed and meta.rev <= meta.sealed then meta.rev = meta.rev + 1 end
    rec.rv = meta.rev
    Store.gen = Store.gen + 1
end

function Store.Seal(rev)
    if DB and rev and rev > (DB.meta.sealed or -1) then DB.meta.sealed = rev end
end

-- Revision of this installation's upload in the shipped community file (contributors[uid]), or nil.
function Store.DeltaBase()
    local c = Store.Community()
    local rev = c and type(c.contributors) == "table" and c.contributors[DB.meta.uid]
    if type(rev) == "number" and rev > 0 and rev <= DB.meta.rev then return rev end
    return nil
end

local function Touch(rec)
    rec.last = ns.time()
    DB.meta.rev = DB.meta.rev + 1
    rec.rv = DB.meta.rev
    Store.gen = Store.gen + 1
    local day = math.floor(rec.last / 86400)
    DB.kpi.days[day] = true
end

-- ---------------------------------------------------------------- quest items

-- A quest item only drops while a quest in the log still needs it, so attempts without that quest say
-- nothing about its rate. rec.qb[itemId] = { n, d, q, h } counts the attempts made while the item was
-- needed (ns.Quests.Needed) and what dropped in them; rec.loot keeps all drops. Objectives only name
-- their item: until it drops once, its attempts wait under the name in rec.qp.
-- Items: it.qd = objective name (dropped while needed), it.qx = drops no quest asked for (up to 2).
local QUEST_CLASS, QUEST_BIND = 12, 4
local FREE_DROPS = 2 -- that many drops without a quest: an ordinary drop after all
local questNames -- objective name -> { [itemId] = true }, or false (not a quest item)
local sharedQuest = {} -- itemId -> true: quest item according to a shared layer (RebuildIndex)

local function QuestNames()
    if not questNames then
        questNames = {}
        for id, it in pairs(DB.items) do
            if type(it) == "table" and type(it.qd) == "string" then
                questNames[it.qd] = questNames[it.qd] or {}
                questNames[it.qd][id] = true
            end
        end
    end
    return questNames
end

-- "gated" (only drops with its quest), "free" (a quest item that drops anyway) or nil (ordinary or
-- not known).
function Store.QuestState(itemId)
    local it = DB.items[itemId]
    if not it then return nil end
    if (it.qx or 0) >= FREE_DROPS then return "free" end
    return it.qd and "gated" or nil
end

-- Whether an item's rate only counts attempts made while its quest was active.
function Store.IsGated(itemId)
    local state = Store.QuestState(itemId)
    if state then return state == "gated" end
    if Store.indexDirty then Store.RebuildIndex() end
    return sharedQuest[itemId] == true
end

-- Quest items by class or binding; everything else ("bring 10 linen cloth") drops with or without.
local function IsQuestItem(itemId, it)
    local class = it.cl
    if not class and C_Item and C_Item.GetItemInfoInstant then
        local ok, _, _, _, _, _, c = pcall(C_Item.GetItemInfoInstant, itemId)
        class = ok and c or nil
    end
    if class == QUEST_CLASS then return true end
    if it.bd == nil then Store.RefreshItemInfo(itemId) end
    return it.cl == QUEST_CLASS or it.bd == QUEST_BIND
end

local function QuestBase(rec, itemId)
    rec.qb = rec.qb or {}
    local b = rec.qb[itemId]
    if not b then
        b = { n = 0, d = 0, q = 0 }
        rec.qb[itemId] = b
    end
    return b
end

-- The item behind an objective name is known now: attempts waiting under the name move to it.
local function LearnQuestName(name, itemId, quest)
    local names = QuestNames()
    if quest then
        if names[name] and names[name][itemId] then return end
        names[name] = names[name] or {}
        names[name][itemId] = true
    else
        if names[name] ~= nil then return end
        names[name] = false
    end
    for _, rec in pairs(DB.sources) do
        local n = rec.qp and rec.qp[name]
        if n then
            if quest then
                local b = QuestBase(rec, itemId)
                b.n = b.n + n
                Store.Mark(rec)
            end
            rec.qp[name] = nil
            if not next(rec.qp) then rec.qp = nil end
        end
    end
end

-- One attempt: every item needed right now gets one more. Returns the needed items { [id] = true }.
function Store.CountNeeded(rec, needed)
    if not needed or rec.kind == "quest" then return nil end
    local names, ids = QuestNames(), {}
    for name in pairs(needed.names) do
        local known = names[name]
        if known then
            for id in pairs(known) do
                if Store.QuestState(id) == "gated" then
                    local b = QuestBase(rec, id)
                    b.n = b.n + 1
                end
                ids[id] = true
            end
        elseif known == nil then
            rec.qp = rec.qp or {}
            rec.qp[name] = (rec.qp[name] or 0) + 1
        end
    end
    return ids
end

-- One drop of an item, next to rec.loot: counted for the quest it was needed for, or noted as a drop
-- nobody asked for.
local function CountQuestDrop(rec, it, itemId, qty, name, needed)
    if not needed or rec.kind == "quest" then return end
    name = name or it.n
    local objective, ambiguous = ns.Quests.Match(needed.names, name)
    if not IsQuestItem(itemId, it) then
        if objective == name then LearnQuestName(objective, itemId, false) end
        return
    end
    if objective then
        LearnQuestName(objective, itemId, true) -- before qd: the lazily built name list reads it
        if it.qd ~= objective then
            it.qd = objective
            Store.Mark(it)
        end
        local b = QuestBase(rec, itemId)
        b.d, b.q = b.d + 1, b.q + qty
        b.h = b.h or {}
        b.h[qty] = (b.h[qty] or 0) + 1
    elseif not ambiguous and needed.complete and (it.qx or 0) < FREE_DROPS and not ns.Quests.RecentlyNeeded(name) then
        it.qx = (it.qx or 0) + 1
        Store.Mark(it)
    end
end

-- Counts of an item in an own record: n, d, q, histogram. `gated`: only while its quest was active.
function Store.OwnCounts(rec, itemId, gated)
    local x = rec.loot[itemId]
    if not gated or rec.kind == "quest" then
        return Store.Base(rec), x and x.d or 0, x and x.q or 0, x and x.h or nil
    end
    local b = rec.qb and rec.qb[itemId]
    if b then return b.n, math.min(b.d, b.n), b.q, b.h end
    -- never dropped for us: attempts are still under the objective's name
    local it = DB.items[itemId]
    local name = rec.qp and ((it and it.n) or ns.ItemInfo(itemId))
    return name and rec.qp[name] or 0, 0, 0, nil
end

-- The same for a shared record (or the baseline): s.qb[itemId] = attempts of a quest item. Records
-- without it were made before quest items were counted separately and say nothing about the rate.
local function SharedCounts(s, itemId, gated)
    local e = type(s.l) == "table" and s.l[itemId] or nil
    local n = type(s.qb) == "table" and s.qb[itemId] or nil
    if not n then
        if gated and s.k ~= "quest" then return 0, 0, 0, nil end
        n = s.n or 0
    end
    if type(e) ~= "table" then return n, 0, 0, nil end
    return n, e[1] or 0, e[2] or 0, e[3]
end

-- Loot of an own record as it is shared: l[id] = { d, q, hist }, qb[id] = attempts of quest items.
-- `all` also lists quest items that never dropped here.
local function SharedLoot(rec, all)
    local l, qb = {}, nil
    for id in pairs(rec.loot) do
        local state = rec.kind ~= "quest" and Store.QuestState(id) or nil
        local n, d, q, h = Store.OwnCounts(rec, id, state == "gated")
        l[id] = { d, q, CopyHist(h) }
        if state then
            qb = qb or {}
            qb[id] = n
        end
    end
    if all then
        for id, b in pairs(rec.qb or {}) do
            if not rec.loot[id] and Store.QuestState(id) == "gated" then
                qb = qb or {}
                qb[id] = b.n
            end
        end
    end
    return l, qb
end

-- `skip(itemId)`: quest items that could not drop in this attempt keep their streak.
local function StreakAlerts(key, rec, skip)
    if not DB.settings.streakAlerts then return end
    for itemId in pairs(rec.loot) do
        local streak = rec.streak[itemId] or 0
        if streak >= 5 and not skip(itemId) then
            local d, n = Store.Combined(key, itemId)
            local p = n > 0 and d / n or 0
            if p > 0 and p < 1 and streak == ns.Stats.AttemptsFor(p, 0.95) then
                ns.Print(
                    string.format(
                        L["dry streak: %s has not dropped from %s in %d attempts (rate %s, chance of this < 5%%)"],
                        ns.ItemName(itemId, true),
                        rec.name or "?",
                        streak,
                        ns.Pct(p)
                    )
                )
            end
        end
    end
end

local function BumpStreaks(key, rec, neededIds)
    local function skip(itemId)
        return rec.kind ~= "quest" and Store.IsGated(itemId) and not (neededIds and neededIds[itemId])
    end
    for itemId in pairs(rec.loot) do
        if not skip(itemId) then rec.streak[itemId] = (rec.streak[itemId] or 0) + 1 end
    end
    StreakAlerts(key, rec, skip)
end

function Store.CountKill(key, rec, grouped)
    rec.kills = rec.kills + 1
    if grouped then rec.gk = rec.gk + 1 end
    DB.totals.kills = DB.totals.kills + 1
    local now = GetTime()
    if rec.lk and now - rec.lk < 300 and now > rec.lk then
        rec.pk = (rec.pk or 0) + 1
        rec.ps = (rec.ps or 0) + (now - rec.lk)
    end
    rec.lk = now
    Touch(rec)
    ns.Fire("KILL", key, rec)
end

-- A mob corpse enters the drop-rate base (looted, or confirmed to have nothing on it). `needed` here
-- and below: items the quest log needed (ns.Quests.Needed), nil = not known.
function Store.CountLootBase(key, rec, empty, needed)
    rec.lb = (rec.lb or 0) + 1
    if empty then rec.ek = (rec.ek or 0) + 1 end
    Touch(rec)
    BumpStreaks(key, rec, Store.CountNeeded(rec, needed))
end

function Store.CountAttempt(key, rec, grouped, needed)
    rec.attempts = rec.attempts + 1
    if grouped then rec.ga = rec.ga + 1 end
    DB.totals.attempts = DB.totals.attempts + 1
    Touch(rec)
    if rec.kind ~= "mob" then
        local now = GetTime()
        if rec.lk and now - rec.lk < 300 and now > rec.lk then
            rec.pk = (rec.pk or 0) + 1
            rec.ps = (rec.ps or 0) + (now - rec.lk)
        end
        rec.lk = now
        BumpStreaks(key, rec, Store.CountNeeded(rec, needed))
    end
    ns.Fire("ATTEMPT", key, rec)
end

function Store.AddDrop(key, rec, itemId, qty, name, grouped, needed)
    local it = Store.Item(itemId)
    if name and name ~= "" then it.n = name end
    it.src[key] = true
    local l = rec.loot[itemId]
    if not l then
        l = { d = 0, q = 0 }
        rec.loot[itemId] = l
    end
    qty = math.max(1, math.floor(qty or 1))
    l.d = l.d + 1
    l.q = l.q + qty
    -- how often each stack size came from one kill / node / container
    l.h = l.h or {}
    l.h[qty] = (l.h[qty] or 0) + 1
    if grouped then l.g = (l.g or 0) + 1 end
    CountQuestDrop(rec, it, itemId, qty, name, needed)
    rec.streak[itemId] = 0
    Store.Mark(rec)
    DB.totals.items = DB.totals.items + qty
    Store.IndexAdd(itemId, key)
end

function Store.AddMoney(rec, copper)
    rec.money = (rec.money or 0) + copper
    Store.Mark(rec)
end

-- One coin drop: total, how often coin dropped, smallest and largest amount.
function Store.AddCoin(rec, copper)
    copper = math.floor(copper + 0.5)
    if copper <= 0 then return end
    rec.money = (rec.money or 0) + copper
    rec.mc = (rec.mc or 0) + 1
    rec.mmin = math.min(rec.mmin or copper, copper)
    rec.mmax = math.max(rec.mmax or copper, copper)
    Store.Mark(rec)
end

function Store.CellKey(x, y)
    local cx = math.min(99, math.max(0, math.floor(x * 100)))
    local cy = math.min(99, math.max(0, math.floor(y * 100)))
    return cx * 100 + cy
end

function Store.CellXY(cell) return (math.floor(cell / 100) + 0.5) / 100, (cell % 100 + 0.5) / 100 end

-- In instances the client gives no position, only the zone: such sources count zones (rec.zn =
-- { [map] = count }) so pages can still say where they are.
function Store.AddZone(rec, map)
    if not map then return end
    rec.zn = type(rec.zn) == "table" and rec.zn or {}
    rec.zn[map] = (rec.zn[map] or 0) + 1
    Store.Mark(rec)
    if not DB.maps[map] then ns.MapName(map) end
end

-- Where the player is now: a spawn cell, else the zone alone (no position), else the instance (no
-- map either: ns.InstanceZone).
function Store.AddLocation(rec)
    local map, x, y = ns.PlayerLocation()
    if x then
        Store.AddSpawn(rec, map, x, y)
    else
        Store.AddZone(rec, map or ns.InstanceZone())
    end
end

function Store.AddSpawn(rec, map, x, y)
    if not map or not x then return end
    local m = rec.spawns[map]
    if not m then
        m = {}
        rec.spawns[map] = m
    end
    local cell = Store.CellKey(x, y)
    m[cell] = (m[cell] or 0) + 1
    Store.Mark(rec)
    if not DB.maps[map] then ns.MapName(map) end
end

-- ---------------------------------------------------------------- layers

local function Community()
    local c = WorldCodex_CommunityData
    if type(c) == "table" and type(c.sources) == "table" then return c end
    return nil
end
Store.Community = Community

local function IsContributor(uid)
    local c = Community()
    return c and uid and type(c.contributors) == "table" and c.contributors[uid] and true or false
end
Store.IsContributor = IsContributor

-- Calls fn(layer, src, peer) for each shared layer that is switched on: guild peers that are not
-- community contributors (their data is already in the community file), then the community file.
local function SharedTables(fn)
    if DB.settings.useGuild then
        for _, peer in pairs(DB.peers) do
            if type(peer.src) == "table" and not IsContributor(peer.uid) then fn("guild", peer.src, peer) end
        end
    end
    local c = Community()
    if c and DB.settings.useCommunity then fn("community", c.sources) end
end
Store.SharedTables = SharedTables

-- Same as SharedTables for one source: fn(layer, record, peer).
local function EachShared(key, fn)
    SharedTables(function(layer, src, peer)
        local s = src[key]
        if type(s) == "table" then fn(layer, s, peer) end
    end)
end
Store.EachShared = EachShared

-- When the community file already contains our own (older) upload, only data gathered
-- after the baseline is added on top, so nothing is counted twice.
function Store.UpdateBaseline()
    local c = Community()
    if not c then return end
    if not IsContributor(DB.meta.uid) then
        DB.baseline = { src = {} }
        return
    end
    if DB.baseline.gen == c.generated then return end
    local src = {}
    for key, rec in pairs(DB.sources) do
        if c.sources[key] then
            local l, qb = SharedLoot(rec, true)
            src[key] = { n = Store.Base(rec), l = l, qb = qb, m = rec.money, k = rec.kind }
        end
    end
    DB.baseline = { gen = c.generated, src = src }
end

function CopyHist(h)
    if type(h) ~= "table" then return nil end
    local c = {}
    for k, v in pairs(h) do
        c[k] = v
    end
    return c
end
Store.CopyHist = CopyHist

-- Stack-size histogram of an item at a source over all layers: { [size] = count }, total.
function Store.QtyHist(key, itemId)
    local merged, total = {}, 0
    local function add(h, sign)
        if type(h) ~= "table" then return end
        for size, cnt in pairs(h) do
            merged[size] = (merged[size] or 0) + sign * cnt
        end
    end
    local gated = Store.IsGated(itemId)
    local rec = DB.sources[key]
    if rec and rec.loot[itemId] then
        add(select(4, Store.OwnCounts(rec, itemId, gated)), 1)
        local b = DB.baseline.src[key]
        if b then add(select(4, SharedCounts(b, itemId, gated)), -1) end
    end
    EachShared(key, function(_, s) add(select(4, SharedCounts(s, itemId, gated)), 1) end)
    for size, cnt in pairs(merged) do
        if cnt <= 0 then
            merged[size] = nil
        else
            total = total + cnt
        end
    end
    return merged, total
end

local function HasQuestBase(s, itemId) return type(s.qb) == "table" and s.qb[itemId] ~= nil end

-- Per-layer counts for (source, item): list of { layer, n, d, q }, layers without observations left
-- out. "me" is the full personal record. When the community file contains the player's own upload,
-- that part (the baseline) is taken out of the community layer, so each layer shows whose data it is
-- and nothing is counted twice (same sides as Store.Compare).
function Store.Parts(key, itemId)
    local parts = {}
    local rec = DB.sources[key]
    local gated = Store.IsGated(itemId)
    if rec then
        local n, d, q = Store.OwnCounts(rec, itemId, gated)
        if n > 0 or d > 0 then parts[#parts + 1] = { layer = "me", n = n, d = d, q = q } end
    end
    local own = #parts
    local b = DB.baseline.src[key]
    local guild
    EachShared(key, function(layer, s)
        local n, d, q = SharedCounts(s, itemId, gated)
        if layer == "guild" then
            guild = guild or { layer = "guild", n = 0, d = 0, q = 0 }
            guild.n, guild.d, guild.q = guild.n + n, guild.d + d, guild.q + q
        else
            if b then
                local bn, bd, bq = SharedCounts(b, itemId, gated or HasQuestBase(s, itemId))
                n, d, q = math.max(0, n - bn), math.max(0, d - bd), math.max(0, q - bq)
            end
            if n > 0 or d > 0 then parts[#parts + 1] = { layer = "community", n = n, d = d, q = q } end
        end
    end)
    if guild and guild.n > 0 then table.insert(parts, own + 1, guild) end
    return parts
end

function Store.Combined(key, itemId)
    local n, d, q = 0, 0, 0
    local parts = Store.Parts(key, itemId)
    for i = 1, #parts do
        n, d, q = n + parts[i].n, d + parts[i].d, q + parts[i].q
    end
    return math.min(d, n), n, q, parts
end

-- Personal numbers against everyone else's for (source, item). `mine` is the full personal record;
-- `community` has the player's own upload (the baseline) taken out, so `others` = guild + community
-- never contains the player. Each side: { n, d, q, h = {[size]=count} }.
function Store.Compare(key, itemId)
    local function side() return { n = 0, d = 0, q = 0, h = {} } end
    local out = { mine = side(), guild = side(), community = side(), others = side() }
    local function add(t, n, d, q, h, sign)
        t.n, t.d, t.q = t.n + sign * (n or 0), t.d + sign * (d or 0), t.q + sign * (q or 0)
        if type(h) == "table" then
            for size, cnt in pairs(h) do
                t.h[size] = (t.h[size] or 0) + sign * cnt
            end
        end
    end
    local rec = DB.sources[key]
    local gated = Store.IsGated(itemId)
    if rec then
        local n, d, q, h = Store.OwnCounts(rec, itemId, gated)
        add(out.mine, n, d, q, h, 1)
    end
    local counted = gated
    EachShared(key, function(layer, s)
        local n, d, q, h = SharedCounts(s, itemId, gated)
        add(out[layer], n, d, q, h, 1)
        if layer == "community" and HasQuestBase(s, itemId) then counted = true end
    end)
    local b = DB.baseline.src[key]
    if b and out.community.n > 0 then
        local n, d, q, h = SharedCounts(b, itemId, counted)
        add(out.community, n, d, q, h, -1)
    end
    local c = out.community
    c.n, c.d, c.q = math.max(0, c.n), math.max(0, c.d), math.max(0, c.q)
    for size, cnt in pairs(c.h) do
        if cnt <= 0 then c.h[size] = nil end
    end
    add(out.others, out.guild.n, out.guild.d, out.guild.q, out.guild.h, 1)
    add(out.others, c.n, c.d, c.q, c.h, 1)
    for _, t in pairs(out) do
        t.d = math.min(t.d, t.n)
    end
    return out
end

-- Per-attempt coin of a source, personal against everyone else: { mine = {n, m}, others = {n, m} }.
function Store.CompareSource(key)
    local out = { mine = { n = 0, m = 0 }, others = { n = 0, m = 0 } }
    local rec = DB.sources[key]
    if rec then
        out.mine.n, out.mine.m = Store.Base(rec), rec.money or 0
    end
    local community = false
    EachShared(key, function(layer, s)
        out.others.n, out.others.m = out.others.n + (s.n or 0), out.others.m + (s.m or 0)
        if layer == "community" then community = true end
    end)
    local b = DB.baseline.src[key]
    if b and community then
        out.others.n = math.max(0, out.others.n - (b.n or 0))
        out.others.m = math.max(0, out.others.m - (b.m or 0))
    end
    return out
end

-- Name in the player's language: own record, then the community name for this client's locale, then
-- a guild peer with the same locale, then any shared name.
function Store.SourceMeta(key)
    local rec = DB.sources[key]
    if rec and rec.name then return rec.name, rec.kind end
    local kind = rec and rec.kind
    local c = Community()
    local s = c and c.sources[key]
    local locale = GetLocale and GetLocale()
    local names = c and type(c.names) == "table" and c.names[locale]
    if names and names[key] then return names[key], kind or (s and s.k) or "other" end
    local fallback, fallbackKind
    for _, peer in pairs(DB.peers) do
        local p = peer.src and peer.src[key]
        if p and p.nm then
            if peer.lc == locale then return p.nm, kind or p.k end
            fallback, fallbackKind = fallback or p.nm, fallbackKind or p.k
        end
    end
    if s and s.nm then return s.nm, kind or s.k end
    if fallback then return fallback, kind or fallbackKind end
    -- a mob recorded by npc id only (dungeons): the client's creature cache knows its name
    local npc = CreatureOf(key)
    local cached = npc and ns.CreatureName(npc)
    if cached then return cached, kind or (s and s.k) or "mob" end
    return tostring(key), kind or (s and s.k) or "other"
end

-- Level range and classification of a mob: own record, else the shared layers (lv, cl).
function Store.SourceLevel(key)
    local rec = DB.sources[key]
    if rec and rec.lmin then return rec.lmin, rec.lmax or rec.lmin, rec.cls end
    local lmin, lmax, cls
    EachShared(key, function(_, s)
        if type(s.lv) == "table" then
            lmin = math.min(lmin or s.lv[1], s.lv[1])
            lmax = math.max(lmax or s.lv[2], s.lv[2])
        end
        cls = cls or s.cl
    end)
    return lmin, lmax, cls
end

function Store.SourceBaseCombined(key)
    local n, money = 0, 0
    local rec = DB.sources[key]
    if rec then
        n = Store.Base(rec)
        money = rec.money or 0
    end
    EachShared(key, function(_, s)
        n, money = n + (s.n or 0), money + (s.m or 0)
    end)
    return n, money
end

-- Per-attempt summary of a source over all layers: items, stacks and coin.
function Store.SourceSummary(key)
    local n, money = Store.SourceBaseCombined(key)
    local out = { n = n, items = 0, stacks = 0, coin = n > 0 and money / n or 0 }
    if n <= 0 then return out end
    for id in pairs(Store.SourceItems(key)) do
        local d, nn, q = Store.Combined(key, id)
        if nn > 0 then
            out.items = out.items + q / nn
            out.stacks = out.stacks + d / nn
        end
    end
    local mc, ca, mmin, mmax = 0, 0, nil, nil
    local function add(c)
        if not c then return end
        mc, ca = mc + (c[1] or 0), ca + (c[2] or 0)
        if c[3] then mmin = math.min(mmin or c[3], c[3]) end
        if c[4] then mmax = math.max(mmax or c[4], c[4]) end
    end
    local rec = DB.sources[key]
    if rec and rec.ca then add({ rec.mc or 0, rec.ca, rec.mmin, rec.mmax }) end
    EachShared(key, function(_, s) add(s.cm) end)
    if ca > 0 then out.coinChance = mc / ca end
    out.coinMin, out.coinMax = mmin, mmax
    out.imax = rec and rec.imax
    return out
end

function Store.SourceItems(key)
    local ids = {}
    local rec = DB.sources[key]
    if rec then
        for id in pairs(rec.loot) do
            ids[id] = true
        end
    end
    EachShared(key, function(_, s)
        for id in pairs(type(s.l) == "table" and s.l or {}) do
            ids[id] = true
        end
    end)
    return ids
end

-- Other modules add locations that are not loot spawns (NPC sightings, vendors): fn(key, add).
local spawnProviders = {}
function Store.AddSpawnProvider(fn) spawnProviders[#spawnProviders + 1] = fn end

function Store.Spawns(key)
    local merged = {}
    local function add(sp)
        if type(sp) ~= "table" then return end
        for map, cells in pairs(sp) do
            if type(cells) == "table" then
                local m = merged[map]
                if not m then
                    m = {}
                    merged[map] = m
                end
                for cell, n in pairs(cells) do
                    m[cell] = (m[cell] or 0) + (tonumber(n) or 0)
                end
            end
        end
    end
    local rec = DB.sources[key]
    if rec then add(rec.spawns) end
    EachShared(key, function(_, s) add(s.sp) end)
    for _, fn in ipairs(spawnProviders) do
        fn(key, add)
    end
    return merged
end

-- Where a source was recorded, per zone: spawn cells and zone-only counts (instances) over all
-- layers, { [map] = count }.
function Store.ZoneCounts(key)
    local out = {}
    for map, cells in pairs(Store.Spawns(key)) do
        local w = 0
        for _, n in pairs(cells) do
            w = w + n
        end
        if w > 0 then out[map] = w end
    end
    local function add(zn)
        if type(zn) ~= "table" then return end
        for map, n in pairs(zn) do
            if type(map) == "number" then out[map] = (out[map] or 0) + (tonumber(n) or 0) end
        end
    end
    local rec = DB.sources[key]
    if rec then add(rec.zn) end
    EachShared(key, function(_, s) add(s.zn) end)
    return out
end

-- itemId -> { [sourceKey] = true } over all layers
local index = {}
Store.indexDirty = true

function Store.RebuildIndex()
    index = {}
    sharedQuest, questNames = {}, nil
    local function add(id, key)
        local t = index[id]
        if not t then
            t = {}
            index[id] = t
        end
        t[key] = true
    end
    for key, rec in pairs(DB.sources) do
        for id in pairs(rec.loot) do
            add(id, key)
        end
    end
    SharedTables(function(_, src)
        for key, s in pairs(src) do
            if type(s) == "table" then
                for id in pairs(type(s.l) == "table" and s.l or {}) do
                    add(id, key)
                end
                for id in pairs(type(s.qb) == "table" and s.qb or {}) do
                    sharedQuest[id] = true
                end
            end
        end
    end)
    Store.indexDirty = false
end

-- The index follows the layer switches.
ns.On("SETTINGS_CHANGED", function(key)
    if key == nil or key == "useGuild" or key == "useCommunity" then Store.indexDirty = true end
end)

function Store.IndexAdd(itemId, key)
    if Store.indexDirty then return end
    local t = index[itemId]
    if not t then
        t = {}
        index[itemId] = t
    end
    t[key] = true
end

function Store.SourcesForItem(itemId)
    if Store.indexDirty then Store.RebuildIndex() end
    return index[itemId] or {}
end

function Store.AllItemIds()
    if Store.indexDirty then Store.RebuildIndex() end
    local ids = {}
    for id in pairs(index) do
        ids[id] = true
    end
    for id in pairs(DB.items) do
        ids[id] = true
    end
    for id in pairs(DB.ah) do
        ids[id] = true
    end
    return ids
end

function Store.AllSourceKeys()
    local keys = {}
    for key in pairs(DB.sources) do
        keys[key] = true
    end
    SharedTables(function(_, src)
        for key in pairs(src) do
            keys[key] = true
        end
    end)
    return keys
end

function Store.HasSource(key)
    if DB.sources[key] then return true end
    local found = false
    EachShared(key, function() found = true end)
    return found
end

-- ---------------------------------------------------------------- snapshots (sync / export)

local function TopCells(spawns, limit)
    local out = {}
    for map, cells in pairs(spawns or {}) do
        local arr = {}
        for cell, n in pairs(cells) do
            arr[#arr + 1] = { cell, n }
        end
        table.sort(arr, function(a, b) return a[2] > b[2] end)
        local m = {}
        for i = 1, math.min(limit, #arr) do
            m[arr[i][1]] = arr[i][2]
        end
        if next(m) then out[map] = m end
    end
    return out
end

-- Keys of a table, so a job can walk it across frames while the game adds keys (pairs cannot).
local function Keys(t)
    local keys, n = {}, 0
    for k in pairs(t) do
        n = n + 1
        keys[n] = k
    end
    return keys
end

-- The compact per-player snapshot (guild sync, share strings). opts.since: only records changed
-- after that revision (rv > since; records without rv count as changed). Such a snapshot is a delta
-- (v = 2, base = since) and only means something on top of the upload with that revision.
-- Inside a job (ns.RunJob) it yields between records; it never yields inside a live table's pairs.
function Store.Snapshot(opts)
    opts = opts or {}
    local minN = opts.minN or 1
    local since = opts.since
    local rev = DB.meta.rev
    local Yield = ns.Yield or function() end
    local function Changed(r) return not since or r.rv == nil or r.rv > since end
    local src = {}
    for _, key in ipairs(Keys(DB.sources)) do
        local rec = DB.sources[key]
        local n = rec and Store.Base(rec) or 0
        if n >= minN and Changed(rec) then
            local l, qb = SharedLoot(rec, opts.questBases)
            src[key] = {
                nm = rec.name,
                k = rec.kind,
                n = n,
                m = rec.money,
                l = l,
                qb = qb,
                sp = TopCells(rec.spawns, opts.cells or 8),
                zn = type(rec.zn) == "table" and next(rec.zn) and rec.zn or nil,
                ch = rec.choice,
                rp = rec.rep,
                cm = rec.ca and { rec.mc or 0, rec.ca, rec.mmin, rec.mmax } or nil,
                lv = rec.lmin and { rec.lmin, rec.lmax or rec.lmin } or nil,
                cl = rec.cls,
                qg = rec.gid,
                qt = rec.tid,
                rq = rec.req,
                si = rec.si,
            }
        end
        Yield()
    end
    -- Vendors and recipes are facts, not counts: shared through export strings and the community
    -- file only (guild sync leaves them out to keep addon messages small).
    local vd, rc
    if opts.vendors and type(DB.vendors) == "table" then
        vd = {}
        for _, npc in ipairs(Keys(DB.vendors)) do
            local v = DB.vendors[npc]
            if v and type(v.i) == "table" and Changed(v) then
                local items = {}
                for id, e in pairs(v.i) do
                    items[id] = { p = e.p, st = e.st, lim = e.lim, x = e.x }
                end
                vd[npc] = { nm = v.nm, sp = TopCells(v.sp, 4), i = items }
            end
            Yield()
        end
    end
    -- item facts for the website (names in the uploader's language, levels, icons, ...)
    local it
    if opts.items then
        it = {}
        for _, id in ipairs(Keys(DB.items)) do
            local e = DB.items[id]
            if e and e.n and Changed(e) then
                it[id] =
                    { n = e.n, ql = e.ql, v = e.v, il = e.il, rq = e.rq, cl = e.cl, sc = e.sc, eq = e.eq, ic = e.ic }
                it[id].sk, it[id].bd = e.sk, e.bd
            end
            Yield()
        end
    end
    local np
    if opts.npcs and type(DB.npcs) == "table" then
        np = {}
        for _, key in ipairs(Keys(DB.npcs)) do
            local r = DB.npcs[key]
            if r and Changed(r) then
                np[key] = { nm = r.nm, sp = TopCells(r.sp, 8), lv = r.lv, cl = r.cl, r = r.r, f = r.f }
            end
            Yield()
        end
    end
    if opts.recipes and type(DB.recipes) == "table" then
        rc = {}
        for _, key in ipairs(Keys(DB.recipes)) do
            local r = DB.recipes[key]
            if r and Changed(r) then rc[key] = { pf = r.pf, mn = r.mn, mx = r.mx, r = r.r } end
            Yield()
        end
    end
    local ah
    if opts.ah then
        ah = {}
        local cutoff = ns.time() - (opts.ahMaxAge or 3 * 86400)
        -- opts.ahRelevant (guild sync): only items that drop from recorded sources or are farming
        -- goals, not every item of a full auction house scan
        local function Relevant(id)
            if not opts.ahRelevant then return true end
            local it = DB.items[id]
            return (it and type(it.src) == "table" and next(it.src) ~= nil) or (DB.farm.goals[id] ~= nil)
        end
        for _, id in ipairs(Keys(DB.ah)) do
            local r = DB.ah[id]
            local last = r and r.last
            if last and last.t and last.t >= cutoff and last.md and Changed(r) and Relevant(id) then
                ah[id] = { t = last.t, mi = last.mi, md = last.md, mn = last.mn, mx = last.mx, q = last.q }
            end
            Yield()
        end
    end
    return {
        v = since and 2 or 1,
        base = since,
        uid = DB.meta.uid,
        rev = rev,
        t = ns.time(),
        lc = GetLocale and GetLocale() or nil,
        src = src,
        ah = ah,
        vd = vd,
        rc = rc,
        np = np,
        it = it,
        -- auction prices only mean something per realm and faction
        rl = ah and DB.meta.realm or nil,
        fc = ah and DB.meta.faction or nil,
    }
end

local function Num(v, maxv)
    v = tonumber(v)
    if not v or v ~= v or v < 0 then return nil end
    if maxv and v > maxv then return nil end
    return v
end

local function Str(v)
    if type(v) ~= "string" then return nil end
    return v:sub(1, 80):gsub("|", "")
end

local CLASSIFICATIONS = { elite = true, rare = true, rareelite = true, worldboss = true }

-- npc id, or "go:<objectId>" for quests given or taken by objects
local function NpcKey(v)
    if type(v) == "number" and v > 0 and v < 1e8 and v == math.floor(v) then return v end
    if type(v) == "string" and v:match("^go:%d+$") and #v <= 20 then return v end
    return nil
end

local function ItemCounts(t, limit, maxCount)
    if type(t) ~= "table" then return nil end
    local out, c = nil, 0
    for id, n in pairs(t) do
        c = c + 1
        if c > limit then break end
        if type(id) == "number" and id > 0 and Num(n, maxCount) and n >= 1 then
            out = out or {}
            out[id] = n
        end
    end
    return out
end

local function CleanVendors(vd)
    local out, count = {}, 0
    for npc, v in pairs(vd) do
        count = count + 1
        if count > 5000 then break end
        if NpcKey(npc) and type(npc) == "number" and type(v) == "table" and type(v.i) == "table" then
            local items, c = {}, 0
            for id, e in pairs(v.i) do
                c = c + 1
                if c > 300 then break end
                if type(id) == "number" and type(e) == "table" and Num(e.p, 1e9) then
                    items[id] = {
                        p = e.p,
                        st = Num(e.st, 1000) or 1,
                        lim = e.lim == true or nil,
                        x = ItemCounts(e.x, 5, 1e6),
                    }
                end
            end
            local sp = {}
            for map, cells in pairs(type(v.sp) == "table" and v.sp or {}) do
                if type(map) == "number" and type(cells) == "table" then
                    local m, k = {}, 0
                    for cell, n in pairs(cells) do
                        k = k + 1
                        if k > 16 then break end
                        if Num(cell, 9999) and Num(n, 1e7) then m[cell] = n end
                    end
                    sp[map] = m
                end
            end
            out[npc] = { nm = Str(v.nm), sp = sp, i = items }
        end
    end
    return out
end

local REACTIONS = { hostile = true, neutral = true, friendly = true }
local ROLES = { gossip = true, vendor = true, quest = true, trainer = true, taxi = true, banker = true }

local function CleanNpcs(np)
    local out, count = {}, 0
    for key, r in pairs(np) do
        count = count + 1
        if count > 20000 then break end
        if NpcKey(key) and type(r) == "table" then
            local sp, maps = {}, 0
            for map, cells in pairs(type(r.sp) == "table" and r.sp or {}) do
                maps = maps + 1
                if maps > 8 then break end
                if type(map) == "number" and type(cells) == "table" then
                    local m, k = {}, 0
                    for cell, n in pairs(cells) do
                        k = k + 1
                        if k > 24 then break end
                        if Num(cell, 9999) and Num(n, 1e7) then m[cell] = n end
                    end
                    sp[map] = m
                end
            end
            local lv
            if type(r.lv) == "table" then
                local a, b = Num(r.lv[1], 100), Num(r.lv[2], 100)
                if a and b and a >= 1 and a <= b then lv = { a, b } end
            end
            local f
            for role, v in pairs(type(r.f) == "table" and r.f or {}) do
                if ROLES[role] and v == true then
                    f = f or {}
                    f[role] = true
                end
            end
            out[key] = {
                nm = Str(r.nm),
                sp = sp,
                lv = lv,
                cl = CLASSIFICATIONS[r.cl] and r.cl or nil,
                r = REACTIONS[r.r] and r.r or nil,
                f = f,
            }
        end
    end
    return out
end

local function CleanItems(it)
    local out, count = {}, 0
    for id, e in pairs(it) do
        count = count + 1
        if count > 50000 then break end
        if type(id) == "number" and id > 0 and type(e) == "table" and Str(e.n) then
            local icon = e.ic
            if not ((type(icon) == "number" and icon > 0) or (type(icon) == "string" and #icon <= 120)) then
                icon = nil
            end
            out[id] = {
                n = Str(e.n),
                ql = Num(e.ql, 10),
                v = Num(e.v, 1e9),
                il = Num(e.il, 1000),
                rq = Num(e.rq, 100),
                cl = Num(e.cl, 100),
                sc = Num(e.sc, 100),
                eq = type(e.eq) == "string" and e.eq:match("^INVTYPE_[%u_]+$") and e.eq or nil,
                ic = icon,
                sk = Num(e.sk, 10000),
                bd = Num(e.bd, 10),
            }
        end
    end
    return out
end

local function CleanRecipes(rc)
    local out, count = {}, 0
    for key, r in pairs(rc) do
        count = count + 1
        if count > 5000 then break end
        local okKey = (type(key) == "number" and key > 0) or (type(key) == "string" and key:match("^enchant:%d+$"))
        local reagents = type(r) == "table" and ItemCounts(r.r, 12, 1000)
        local pf = type(r) == "table" and type(r.pf) == "string" and r.pf:match("^%w+$") and #r.pf <= 24 and r.pf
        if okKey and reagents and pf then
            local mn, mx = Num(r.mn, 100) or 1, Num(r.mx, 100) or 1
            out[key] = { pf = pf, mn = mn, mx = math.max(mn, mx), r = reagents }
        end
    end
    return out
end

-- Cleans a snapshot from an untrusted source. Returns a sanitized copy or nil, error.
function Store.ValidateSnapshot(s)
    if type(s) ~= "table" or type(s.src) ~= "table" then return nil, "bad format" end
    -- v = 2: a delta, only the records changed after revision `base` (Store.Snapshot opts.since)
    local base = s.v == 2 and Num(s.base, 1e12) or nil
    if s.v ~= 1 and not (base and base > 0) then return nil, "bad format" end
    local out = {
        v = base and 2 or 1,
        base = base,
        uid = Str(s.uid) or "?",
        rev = Num(s.rev) or 0,
        t = Num(s.t) or 0,
        src = {},
        ah = {},
    }
    local count = 0
    for key, x in pairs(s.src) do
        count = count + 1
        if count > 20000 then return nil, "too many sources" end
        local okKey = (type(key) == "number" and key > 0) or (type(key) == "string" and #key <= 80)
        if okKey and type(x) == "table" then
            local n = Num(x.n, 1e7)
            if n and n > 0 then
                -- attempts of quest items (0 is valid: known to drop, never tried with the quest)
                local qb, bases = nil, 0
                for id, qn in pairs(type(x.qb) == "table" and x.qb or {}) do
                    bases = bases + 1
                    if bases > 500 then break end
                    if type(id) == "number" and id > 0 and Num(qn, n) then
                        qb = qb or {}
                        qb[id] = qn
                    end
                end
                local l = {}
                for id, e in pairs(type(x.l) == "table" and x.l or {}) do
                    local d, q = Num(type(e) == "table" and e[1]), Num(type(e) == "table" and e[2])
                    if type(id) == "number" and d and q and d <= (qb and qb[id] or n) then
                        local h, total, sizes = nil, 0, 0
                        if type(e[3]) == "table" then
                            for size, cnt in pairs(e[3]) do
                                sizes = sizes + 1
                                if sizes > 50 then break end
                                if Num(size, 10000) and size >= 1 and Num(cnt, 1e7) then
                                    h = h or {}
                                    h[size] = cnt
                                    total = total + cnt
                                end
                            end
                            if total > d then h = nil end
                        end
                        l[id] = { d, q, h }
                    end
                end
                local sp = {}
                for map, cells in pairs(type(x.sp) == "table" and x.sp or {}) do
                    if type(map) == "number" and type(cells) == "table" then
                        local m, c = {}, 0
                        for cell, cnt in pairs(cells) do
                            c = c + 1
                            if c > 64 then break end
                            if Num(cell, 9999) and Num(cnt, 1e7) then m[cell] = cnt end
                        end
                        sp[map] = m
                    end
                end
                local zn, zones = nil, 0
                for map, cnt in pairs(type(x.zn) == "table" and x.zn or {}) do
                    zones = zones + 1
                    if zones > 16 then break end
                    -- map ids, or negative instance ids (ns.InstanceZone)
                    local okMap = type(map) == "number" and map ~= 0 and map > -1e7 and map < 1e7
                    if okMap and map == math.floor(map) and Num(cnt, 1e7) and cnt >= 1 then
                        zn = zn or {}
                        zn[map] = cnt
                    end
                end
                local ch
                if type(x.ch) == "table" then
                    for id, v in pairs(x.ch) do
                        if type(id) == "number" and v == true and l[id] then
                            ch = ch or {}
                            ch[id] = true
                        end
                    end
                end
                local rp = (x.rp == "daily" or x.rp == "weekly") and x.rp or nil
                local cm
                if type(x.cm) == "table" then
                    local mc, ca = Num(x.cm[1], 1e7), Num(x.cm[2], 1e7)
                    if mc and ca and mc <= ca then cm = { mc, ca, Num(x.cm[3], 1e9), Num(x.cm[4], 1e9) } end
                end
                local lv
                if type(x.lv) == "table" then
                    local a, b = Num(x.lv[1], 100), Num(x.lv[2], 100)
                    if a and b and a >= 1 and a <= b then lv = { a, b } end
                end
                out.src[key] = {
                    nm = Str(x.nm),
                    k = Str(x.k) or "other",
                    n = n,
                    m = Num(x.m, 1e12) or 0,
                    l = l,
                    qb = qb,
                    sp = sp,
                    zn = zn,
                    ch = ch,
                    rp = rp,
                    cm = cm,
                    lv = lv,
                    cl = CLASSIFICATIONS[x.cl] and x.cl or nil,
                    qg = NpcKey(x.qg),
                    qt = NpcKey(x.qt),
                    rq = ItemCounts(x.rq, 20, 1000),
                    si = type(x.si) == "number" and x.si > 0 and x.si or nil,
                }
            end
        end
    end
    if type(s.ah) == "table" then
        for id, a in pairs(s.ah) do
            if type(id) == "number" and type(a) == "table" and Num(a.md) and Num(a.t) then
                out.ah[id] = { t = a.t, mi = Num(a.mi), md = a.md, mn = Num(a.mn), mx = Num(a.mx), q = Num(a.q) }
            end
        end
    end
    if type(s.lc) == "string" and s.lc:match("^%a%a%a%a$") then out.lc = s.lc end
    if type(s.vd) == "table" then out.vd = CleanVendors(s.vd) end
    if type(s.rc) == "table" then out.rc = CleanRecipes(s.rc) end
    if type(s.np) == "table" then out.np = CleanNpcs(s.np) end
    if type(s.it) == "table" then out.it = CleanItems(s.it) end
    if type(s.rl) == "string" and #s.rl <= 40 and not s.rl:find("|", 1, true) then out.rl = s.rl end
    if s.fc == "Alliance" or s.fc == "Horde" then out.fc = s.fc end
    return out
end

function Store.ImportPeer(peerId, snap, label)
    local clean, err = Store.ValidateSnapshot(snap)
    if not clean then return false, err end
    if clean.uid == DB.meta.uid then return false, "that is your own data" end
    -- auction prices of another realm or faction would be wrong here
    local otherRealm = clean.rl and DB.meta.realm and clean.rl ~= DB.meta.realm
    local otherFaction = clean.fc and DB.meta.faction and clean.fc ~= DB.meta.faction
    if otherRealm or otherFaction then clean.ah = {} end
    if clean.base then
        -- a delta only holds what changed after the import it builds on
        local old = DB.peers[peerId]
        if not (old and old.uid == clean.uid and (old.rev or 0) >= clean.base) then
            return false, L["this string only holds changes; import a full share string from that player first"]
        end
        for _, f in ipairs({ "src", "ah", "vd", "rc", "np" }) do
            if clean[f] and next(clean[f]) then
                old[f] = type(old[f]) == "table" and old[f] or {}
                for k, v in pairs(clean[f]) do
                    old[f][k] = v
                end
            end
        end
        old.rev, old.t, old.lc = math.max(old.rev or 0, clean.rev), ns.time(), clean.lc or old.lc
        Store.indexDirty = true
        ns.Fire("DATA_CHANGED", "peer", peerId)
        return true
    end
    DB.peers[peerId] = {
        uid = clean.uid,
        rev = clean.rev,
        t = ns.time(),
        name = label or peerId,
        src = clean.src,
        ah = clean.ah,
        lc = clean.lc,
        vd = clean.vd,
        rc = clean.rc,
        np = clean.np,
    }
    Store.indexDirty = true
    ns.Fire("DATA_CHANGED", "peer", peerId)
    return true
end

-- ---------------------------------------------------------------- maintenance

function Store.Prune()
    local now = ns.time()
    local removed = 0
    for key, rec in pairs(DB.sources) do
        if Store.Base(rec) < 3 and (rec.last or rec.first or now) < now - 90 * 86400 then
            for id in pairs(rec.loot) do
                local it = DB.items[id]
                if it and it.src then it.src[key] = nil end
            end
            DB.sources[key] = nil
            removed = removed + 1
        end
    end
    for id, peer in pairs(DB.peers) do
        if (peer.t or 0) < now - 30 * 86400 then DB.peers[id] = nil end
    end
    local cutoff = math.floor(now / 86400) - 60
    for day in pairs(DB.kpi.days) do
        if day < cutoff then DB.kpi.days[day] = nil end
    end
    Store.indexDirty = true
    return removed
end

function Store.Wipe()
    for k in pairs(DB) do
        DB[k] = nil
    end
    Store.Init(DB)
    WorldCodexDB = DB
    ns.Fire("DATA_CHANGED", "wipe")
end

return Store
