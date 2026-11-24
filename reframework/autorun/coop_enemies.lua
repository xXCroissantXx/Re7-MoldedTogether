-- coop_enemies.lua: shared enemies, and the reliable event channel the other co-op
-- scripts use.
-- Deaths and damage: when an enemy dies (or Jack is knocked down) or loses health in one
-- player's game, the same enemy does in the other's. Movement: each enemy is run by the
-- game of the nearest player and followed in the other (see "Enemy movement" below).
-- Events travel reliably through CoopNet.cs:
--   us -> coopnet_ev_out.txt   "<id>\t<text>" lines, ids always growing
--   friend -> coopnet_ev_in.txt "<n>\t<text>" lines, each n handled once
-- Ours: "kill <enemy id> <chapter> <name>", "dmg <id> <chapter> <amount> <name>",
-- "own <id> <chapter> <name>". coop_world, coop_story and coop_revive send through
-- coop_send_event and get theirs via coop_*_on_event (see on_event).
--
-- Enemy id: regular enemies (and Jack) carry app.EnemySave.SaveGUID, saved in the
-- level, so it's the same on both PCs. The Molded come from a pool and take the id of the
-- spawn point they came out of (v0.47, see spawn_ids). Others fall back to "folder path/name".
-- Regular enemies stay dead: a kill for one that isn't loaded yet is remembered and
-- applied when it appears. Stalkers and bosses (Jack...) get back up in RE7, so their
-- "kill" is only applied if they're loaded right now.

-- v0.48: this script's frame work waits while the game loads or swaps the player (coop_busy, coop_dummy.lua).
local re = setmetatable({ on_frame = function(f)
    return _G.re.on_frame(function() if coop_busy and coop_busy() then return end return f() end)
end }, { __index = _G.re })

enemy_sync = {
    enabled = true,
    list_index = nil, list_t = -100,
    tracked = {},          -- id -> { go, dc, name, dead }
    pending = {},          -- id -> chapter: friend's kills of regular enemies not loaded here yet
    applying = {},         -- id -> clock: kills we applied ourselves (don't echo them back)
    ev_seq = math.floor(os.time()) * 1000,
    ev_out = {},           -- last outgoing lines (the file is rewritten whole)
    ev_in_last = -1,
    last_msg = "-", msg_t = -100,
    sent = 0, applied = 0, scan_t = 0, in_t = 0,
}
local es = enemy_sync

-- Debug registry (v0.52, coop_dummy.lua): dbg_note describes the callback or hook registered on the next lines, dbg_task
-- gives a function its own row in the Debug section. Both are tail calls so the registry sees this file's line.
local function dbg_note(info) if coop_note then return coop_note(info) end end
local function dbg_task(feature, name, f, info) if coop_task then return coop_task(feature, name, f, info) end return f end

-- Lines are collected and appended once a second (was a full read + rewrite per line).
local log_buf, log_t, log_tail = {}, 0, nil
-- v0.52: repeated lines are limited and the file written by coop_dummy.lua's coop_log_gate / coop_log_flush.
local function log(s)
    if coop_log_gate and not coop_log_gate("enemies", s) then return end
    log_buf[#log_buf + 1] = os.date("%H:%M:%S ") .. tostring(s)
end
dbg_note{ feature = "Logging", name = "Write the enemies script's log file",
    when = "every frame; writes to disk only when 1 to 5 s have passed since the last write",
    reads = "this script's log lines in memory",
    writes = "coop_enemies_log.txt" }
re.on_frame(function()
    if coop_log_flush then log_buf, log_t = coop_log_flush("enemies", "coop_enemies_log.txt", log_buf, log_t) return end
    -- without coop_dummy.lua: the v0.51 writer
    if #log_buf == 0 or os.clock() - log_t < 3 then return end
    log_t = os.clock()
    local f = (log_tail or fs.read("coop_enemies_log.txt") or "") .. table.concat(log_buf, "\n") .. "\n"
    if #f > 200000 then f = f:sub(-100000) end
    log_tail = f
    fs.write("coop_enemies_log.txt", f)
    log_buf = {}
end)

local function safe(f, ...)
    local ok, r = pcall(f, ...)
    if ok then return r end
    return nil
end

-- A managed array's items (v0.49): get_elements, or item by item when the game hands back an array
-- without it (about one read in 50, and every read on the title screen). A failed read used to be taken
-- for an empty list: an enemy's AI looked missing for good, a joint list came back empty.
local function arr_items(arr)
    if arr == nil then return {} end
    local ok, l = pcall(function() return arr:get_elements() end)
    if ok and l then return l end
    local out = {}
    local okn, n = pcall(arr.call, arr, "get_Count")
    if okn and type(n) == "number" then
        for i = 0, n - 1 do
            local oki, it = pcall(arr.call, arr, "get_Item", i)
            if oki and it then out[#out + 1] = it end
        end
    end
    return out
end

local function chapter()
    local gm = sdk.get_managed_singleton("app.GameManager")
    return tonumber(gm and safe(gm.get_field, gm, "_CurrentChapter") or 0) or 0
end

-- Molded and other regular enemies die for good; everyone else (Jack Em300x, the
-- Bakers, bosses) only goes down for a while.
local function is_regular(name)
    return name:match("^Em4%d%d%d") ~= nil
end

-- "Host runs every enemy" (v0.57, experimental; settings.host_runs_enemies, the same for everyone). The host's game
-- runs every shared enemy and the others only show copies: no hand-offs, so no enemy changes games mid-fight. An
-- enemy can only attack its own game's player in RE7, so the host's game points each one at whichever player is
-- nearer, the friend's character included (EnemyThinkBase.setTarget + set_targetStatus + the target hold), and
-- catches the enemy's own live attack shapes touching the friend's character, sending the game's own damage value
-- to the friend's game (host_fight, "hurt"). Bot test 2026-11-15: a Molded held this way swung at the friend's
-- character (attack sets with Damage 200/300 going live 1.5-2 m from it, the host's player 5 m away). The way the
-- RE2 co-op mods work (re2coop: host enemies attack the client's NPC, damage caught and replayed on the client).
local function host_mode() return settings ~= nil and settings.host_runs_enemies == true end
function coop_host_runs_enemies() return host_mode() end

-- Boss mode: only the stalker Jack (Em3000) has his movement shared (the Molded too until v0.47,
-- see moves_shared). Boss
-- fights and story characters (Jack's later forms, the family Em31xx-Em33xx...) are scripted
-- around the local player and their props, so each game runs its own copy; damage and defeat
-- are still shared.
-- The garage car fight is Em3000 too (same SaveGUID as the stalker Jack), so it's found by
-- story progress: stage hash 9fb77189 went to 900 at the garage cutscenes (c03e02_10,
-- c03e02_00) and to 1000 at the defeat (c03e03_00) (solo run, 2026-11-03). Other Jack fights
-- (the chainsaw one in the basement) aren't mapped yet.
local JACK_BOSS_STAGES = { { hash = 0x9fb77189, from = 900, to = 999 } }
local boss_cache = { t = -100, on = false }
-- Jack's car in that fight (v0.57): which game runs it ("me", a friend slot, or nil before anyone has started it).
-- See "Jack's car in the garage" further down.
coop_car = coop_car or { runner = nil, hist = {} }
local function car_pinned(name) return name == "Em3000" and coop_car.runner ~= nil end
function jack_boss_fight()
    local now = os.clock()
    if now - boss_cache.t < 1 then return boss_cache.on end
    boss_cache.t = now
    local on = false
    local fm = sdk.get_managed_singleton("app.GameFlowFsmManager")
    for _, st in ipairs(JACK_BOSS_STAGES) do
        local var = fm and safe(fm.call, fm, "getProgressiveNo(System.UInt32)", st.hash)
        local v = var and tonumber(safe(var.call, var, "get_S32"))
        if v and v >= st.from and v <= st.to then on = true end
    end
    if on ~= boss_cache.on then
        log(on and "boss mode: Jack's garage fight" or "boss mode: off")
    end
    boss_cache.on = on
    return on
end

-- Bosses copied from the host's game (v0.32): Mia's fights (Em2000, molded Em2100).
local BOSS_FOLLOW = { Em2000 = true, Em2100 = true }
-- The morgue fight's Jack (Em8000), opt-in and untested (v0.48): with "One Jack for both" on, he is
-- copied from the host's game like Mia. The 2026-11-10 fight had his health in step (damage is shared)
-- but each game ran its own Jack, so each player saw him somewhere else. The bots can't start this fight
-- from the saves there are, so this has never run: off unless switched on (settings.share_jack_fight).
-- v0.48, one Jack for both: a boss copied from the host's game (BOSS_FOLLOW) could only ever attack the
-- host, because in RE7 an enemy only picks its own game's player as a target (bot test 2026-11-11: the
-- copy stood with Jack's every move and never touched the other player). Bosses in BOSS_HANDOFF are run
-- instead by the game of whichever player is nearer, the way ordinary enemies are with "Enemies chase
-- both players": that game's Jack is the real one, with its own AI, and turns on its own player; the
-- other games show the copy. When two games both run him (after a scene, where nobody sends), the
-- host keeps him.
BOSS_HANDOFF = {}
dbg_note{ feature = "One boss for both players", name = "Switch Jack and Mia hand-off on or off",
    when = "every frame (a few table writes and, for the garage fight, a story-stage check)",
    reads = "Options: Share the Jack fight; jack_boss_fight() (story stage of the garage fight)",
    writes = "BOSS_HANDOFF / BOSS_FOLLOW tables (in memory); one log line when it changes" }
re.on_frame(function()
    local on = settings ~= nil and settings.share_jack_fight ~= false
    BOSS_HANDOFF.Em8000 = on or nil
    -- Mia's fights were copied from the host's game since v0.32, so she could only ever go for the host:
    -- the same switch hands her to whoever is nearer too (not bot-tested: no save has her fight).
    BOSS_HANDOFF.Em2000, BOSS_HANDOFF.Em2100 = on or nil, on or nil
    -- The garage car fight's Jack (v0.48) too, while that fight is on (story stage 9fb77189 900-999): the bot
    -- test had him go for one player in one game while the other game's Jack stood in the hall.
    local garage = on and jack_boss_fight()
    BOSS_HANDOFF.Em3000 = garage or nil
    if (BOSS_FOLLOW.Em3000 == true) ~= (garage == true) then BOSS_FOLLOW.Em3000 = garage or nil end
    if (BOSS_FOLLOW.Em8000 == true) ~= on then
        BOSS_FOLLOW.Em8000 = on or nil
        log(on and "one boss for both: Jack and Mia are run by the nearer player's game" or "one boss for both: off, each game runs its own")
    end
end)
function boss_follow(name)
    if not BOSS_FOLLOW[name] then return false end
    if settings and settings.share_bosses == false then return false end
    if local_cutscene and local_cutscene() then return false end
    return true
end

function moves_shared(name)
    -- 3-4 players (v0.29): each enemy has one owner among all the players (see "Ownership"
    -- below). The fallback switch "Share enemies with 3-4 players" (Options, the same for
    -- everyone) makes each game run its own enemies instead, as bosses always do; damage and
    -- kills are still shared either way.
    if coop_party_size and coop_party_size() > 1 and settings and settings.share_enemies_group == false then return false end
    if name == "Em3000" then
        -- The garage car fight (v0.57): Jack rides in the car of the game that runs it (see "Jack's car").
        if jack_boss_fight() and coop_car.runner ~= nil then return not (local_cutscene and local_cutscene()) end
        if jack_boss_fight() then return BOSS_HANDOFF.Em3000 == true and not (local_cutscene and local_cutscene()) end
        return true
    end
    if boss_follow(name) then return true end
    -- The Molded (v0.48, "One Molded for both"): shared again, like Jack. v0.47 had given up on it
    -- because a copy couldn't be moved; the cause (bot test 2026-11-12) was its parent: a Molded body
    -- sits under its generator's MoldedPool, and while it does, a position set from outside changes
    -- only its local transform and its world position (what you see) stops following altogether. Out
    -- of the pool (see unpool) MovementController.warp moves it fully. Off: each game runs its own;
    -- deaths, damage and health are still shared, by spawn point.
    if is_regular(name) then return settings == nil or settings.share_molded_moves ~= false end
    return false
end

local function guid_text(g)
    local b = {}
    for i = 0, 7 do b[#b + 1] = string.format("%02x", (g:get_field("mData4_" .. i) or 0) & 0xFF) end
    return string.format("%08x-%04x-%04x-%s", (g:get_field("mData1") or 0) & 0xFFFFFFFF,
        (g:get_field("mData2") or 0) & 0xFFFF, (g:get_field("mData3") or 0) & 0xFFFF, table.concat(b))
end

local function enemy_id(go)
    local save = safe(go.call, go, "getComponent(System.Type)", sdk.typeof("app.EnemySave"))
    local g = save and safe(save.get_field, save, "SaveGUID")
    if g then
        local t = safe(guid_text, g)
        if t and t ~= "00000000-0000-0000-0000000000000000" then return "g:" .. t end
    end
    local folder = safe(go.call, go, "get_Folder")
    local path = folder and safe(folder.call, folder, "get_Path") or "?"
    return "p:" .. path:gsub("%s", "_") .. "/" .. tostring(safe(go.call, go, "get_Name"))
end

-- The Molded (v0.47): they wait in a pool (five Em4000 in Chapter 3's "Moldeads" folder) with
-- no EnemySave, so "folder path/name" gave all five the same id: a kill, hit or health check
-- for one could land on another. While one is out, the spawn point it came out of
-- (app.EnemySpawnInfo.EnemyInstance) names it, and the spawn point's MyGUID is the same in
-- both games. A pooled body can come back for another spawn point, so the map is read again
-- every second and the enemy's id follows it (scan).
local spawn_map, spawn_body, spawn_map_t = {}, {}, -100
local spawn_known = {}          -- spawn point guid -> when its Molded was last seen out here
es.spawn_out = es.spawn_out or {}   -- newly out: sent by scan()
local function spawn_ids(now)
    if now - spawn_map_t < 1 then return spawn_map, spawn_body end
    spawn_map_t = now
    local m, body = {}, {}
    local sc = sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"), sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
    local arr = sc and safe(sc.call, sc, "findComponents(System.Type)", sdk.typeof("app.EnemySpawnInfo"))
    -- An unreadable list (no get_elements, about one call in 50) keeps the map we had (v0.48): read as
    -- "no spawn points" it took every Molded's id away for a second.
    local list = arr and safe(arr.get_elements, arr)
    if list == nil then
        local n = arr and safe(arr.call, arr, "get_Count")
        if type(n) ~= "number" then return spawn_map, spawn_body end
        list = {}
        for i = 0, n - 1 do local it = safe(arr.call, arr, "get_Item", i) if it then list[#list + 1] = it end end
    end
    for _, s in ipairs(list) do
        local inst = safe(s.get_field, s, "EnemyInstance")
        local g = inst and safe(s.get_field, s, "MyGUID")
        local t = g and safe(guid_text, g)
        if t and t ~= "00000000-0000-0000-0000000000000000" then
            m[inst:get_address()] = "s:" .. t
            body["s:" .. t] = inst:get_address()   -- which body that spawn point has now
            -- Newly out here (v0.48): told to the friend, whose game brings the same one out (spawn_out).
            if spawn_known[t] == nil then es.spawn_out[#es.spawn_out + 1] = t end
            spawn_known[t] = now
        end
    end
    for t, seen in pairs(spawn_known) do if now - seen > 30 then spawn_known[t] = nil end end
    spawn_map, spawn_body = m, body
    return m, body
end

-- "Molded haven't been showing up for both of us" (2026-11-10): each game's director brings a Molded
-- out only when its own player sets it off, so one player fought Molded the other never saw. v0.48:
-- a spawn point that comes alive in one game is sent as "spawn <guid> <chapter>", and the other game
-- asks the game's own spawner for it (app.EnemyGeneratorManager.requestSpawn, tried in the bot copies:
-- the Molded comes out, and the game puts it to sleep by its own rules when no player is in its
-- zone). The game refuses while the spot is in view, so it's asked again for SPAWN_WANT_S (v0.56: 90 s,
-- was 20: "the Molded never spawned in for my friend", 2026-11-14 session; the friend is usually right
-- there, looking at the spot). Kills, hits and health go by the spawn point's id.
local SPAWN_WANT_S = 90
es.spawn_want = es.spawn_want or {}
es.dead_here = es.dead_here or {}   -- id -> chapter: died in this game (seen alive again: forgotten)
local function spawn_requests(now)
    if next(es.spawn_want) == nil or now - (es.spawn_req_t or 0) < 2 then return end
    es.spawn_req_t = now
    local sc = sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"), sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
    local arr = sc and safe(sc.call, sc, "findComponents(System.Type)", sdk.typeof("app.EnemySpawnInfo"))
    local gm = sdk.get_managed_singleton("app.EnemyGeneratorManager")
    local byid = {}
    local list = arr and safe(arr.get_elements, arr)
    if list == nil and arr then   -- the same unreadable list as in spawn_ids (v0.49)
        list = {}
        local n = safe(arr.call, arr, "get_Count")
        for i = 0, (type(n) == "number" and n or 0) - 1 do local it = safe(arr.call, arr, "get_Item", i) if it then list[#list + 1] = it end end
    end
    for _, s in ipairs(list or {}) do
        local g = safe(s.get_field, s, "MyGUID")
        local t = g and safe(guid_text, g)
        if t then byid[t] = s end
    end
    for t, w in pairs(es.spawn_want) do
        local s = byid[t]
        if now > w.until_t or w.ch ~= chapter() then
            if w.asked and w.ch == chapter() then log("spawn " .. t .. ": didn't come out here in " .. SPAWN_WANT_S .. " s") end
            es.spawn_want[t] = nil
        elseif s and gm then
            local inst = safe(s.get_field, s, "EnemyInstance")
            local spawned = safe(s.get_field, s, "IsSpawned") == true
            if spawned and inst == nil and not w.reset and es.dead_here["s:" .. t] ~= chapter() then
                -- Marked spawned with no Molded (v0.49): it came out here once and the game took its body back
                -- to the pool, and a spawn point marked spawned is never asked again, so the friend's awake
                -- Molded never came out here (bot test: two out in one game, one in the other). Not if it died
                -- here. The mark is cleared and the spawn asked for once more.
                w.reset, w.asked = true, true
                pcall(s.set_field, s, "IsSpawned", false)
                pcall(gm.call, gm, "requestSpawn(app.EnemySpawnInfo, System.Int32)", s, 0)
                log("spawn " .. t .. ": marked spawned with no Molded here, asked again")
            elseif spawned and inst == nil and w.asked and safe(s.get_field, s, "IsAlive") == true
                and safe(s.get_field, s, "IsAppeared") ~= true then
                -- v0.56: asked, and the game is waiting to bring it out (spawned + alive, no body yet). It does once
                -- the spot is out of this player's sight (bot test 2026-11-14: a spot 10 m away in view waited a
                -- minute and more; one out of view came out in 2 s; the forced requestSpawn(s, true, 0) raised an
                -- access violation inside the game, so it isn't used). Kept until it comes out or the time is up;
                -- a request the game dropped (alive goes false) is asked again below.
                if not w.wait_said then
                    w.wait_said = true
                    log("spawn " .. t .. ": asked here; the game brings it out once the spot is out of sight")
                end
            elseif spawned or inst ~= nil then
                if w.asked then log("spawn " .. t .. ": out here too") end
                es.spawn_want[t] = nil   -- already out (or was, and is dead or asleep by the game's own doing)
            else
                w.asked = true
                pcall(gm.call, gm, "requestSpawn(app.EnemySpawnInfo, System.Int32)", s, 0)
            end
        end
    end
end

local function damage_controller(go)
    local comps = safe(go.call, go, "get_Components")
    for _, c in ipairs(arr_items(comps)) do
        local td = c:get_type_definition()
        if td:is_a("app.DamageController") then return c end
    end
    return nil
end

-- ObjectManager.ManagedObjects is a list of lists; the enemy list is the one with the most
-- "EmNNNN" objects (its index isn't the ListType enum value). Other things can join it: in
-- Chapter 3's basement three "sm9198_DaveDeadBody_ItemGetGimmick" did, and the old rule (a list
-- made only of "EmNNNN") then found none, so no enemy was scanned down there (bot test
-- 2026-11-10, v0.47). scan() skips the others.
local function enemy_list()
    local om = sdk.get_managed_singleton("app.ObjectManager")
    local lists = om and safe(om.get_field, om, "ManagedObjects")
    if lists == nil then return nil end
    if es.list_index == nil or os.clock() - es.list_t > 5 then
        es.list_t = os.clock()
        local best, best_n = nil, 0
        for i = 0, (safe(lists.call, lists, "get_Count") or 0) - 1 do
            local l = lists:call("get_Item", i)
            local n = l and l:call("get_Count") or 0
            local em = 0
            for j = 0, n - 1 do
                local go = l:call("get_Item", j)
                local name = go and safe(go.call, go, "get_Name") or ""
                if name:match("^Em%d%d%d%d$") then em = em + 1 end
            end
            if em > best_n then best, best_n = i, em end
        end
        es.list_index = best
    end
    return es.list_index and lists:call("get_Item", es.list_index)
end

-- The file is written once per frame (v0.39), not once per event, and keeps the last 150
-- lines (was 30, rewritten on every send). CoopNet reads it 30 times a second, so a burst of
-- more than 30 events between two reads (an area loading, a catch-up arriving) lost the
-- oldest ones before they were sent.
EV_OUT_KEEP = 150
local function flush_events()
    if not es.ev_dirty then return end
    es.ev_dirty = false
    fs.write("coopnet_ev_out.txt", table.concat(es.ev_out, "\n") .. "\n")
end
dbg_note{ feature = "Link to your friend's game", name = "Write the events we sent to the plugin",
    when = "every frame, but it writes only in a frame where an event was sent",
    reads = "the outgoing event list (last 150 lines)",
    writes = "coopnet_ev_out.txt (the whole list is rewritten each time; the plugin reads it 30 times a second)" }
re.on_frame(function() pcall(flush_events) end)

local function send_event(text)
    es.ev_seq = es.ev_seq + 1
    es.ev_out[#es.ev_out + 1] = es.ev_seq .. "\t" .. text
    while #es.ev_out > EV_OUT_KEEP do table.remove(es.ev_out, 1) end
    es.ev_dirty = true
    es.sent = es.sent + 1
    -- Regular check-ins (health, options, version) would fill the log: not logged.
    if not (text:match("^ehp ") or text:match("^opt ") or text:match("^ver ") or text:match("^dang ") or text:match("^spos ")
        or text:match("^lobby me ") or text:match("^lobby open ") or text:match("^stats ") or text:match("^light ")
        or text:match("^car run ")) then log("sent: " .. text) end
    if coop_talk_record then pcall(coop_talk_record, text) end   -- the catch-up list (coop_talk.lua)
end

-- Shared with coop_world.lua (doors and items): one event file, one id sequence.
function coop_send_event(text) send_event(text) end

local function note(msg)
    es.last_msg, es.msg_t = msg, os.clock()
    log(msg)
end

-- One hit far bigger than its health, credited to our player: plays the real death or
-- knock-down. (Setting health to 0 marks it dead but it keeps walking.) The game scales
-- damage (health + 1000 left Jack on 2300 of 10000), so overkill, and hit again if needed.
-- A scripted scene is playing or just set up (v0.36). coop_scene_t: coop_story.lua.
SETTLE = 1.5
function coop_scene_settling() return coop_scene_t ~= nil and os.clock() - coop_scene_t < SETTLE end
local function scripted_now()
    if local_cutscene and local_cutscene() then return true end
    return coop_scene_t ~= nil and os.clock() - coop_scene_t < 4
end

local function kill_enemy(e)
    local player = sdk.get_managed_singleton("app.ObjectManager"):get_field("PlayerObj")
    local m = sdk.find_type_definition("app.DamageController"):get_method("newFakeDamageInfo")
    for _ = 1, 3 do
        local hp = e.dc:call("get_health") or 0
        e.dc:call("addManualDamage", m:call(nil, hp * 4 + 1000.0, player, e.go))
        if e.dc:call("get_isDead") == true then return end
    end
end

-- Scan the enemies here: register new ones, notice deaths, apply remembered kills.
local function scan()
    local l = enemy_list()
    if l == nil then return end
    local seen = {}
    for j = 0, l:call("get_Count") - 1 do
        local go = l:call("get_Item", j)
        if go then
            local addr = go:get_address()
            local e = es.tracked[addr]
            if e == nil and not tostring(safe(go.call, go, "get_Name") or ""):match("^Em%d%d%d%d$") then
                -- Not an enemy (see enemy_list).
            elseif e == nil then
                local dc = damage_controller(go)
                if dc then
                    e = { go = go, dc = dc, id = enemy_id(go), name = go:call("get_Name") }
                    e.dead = dc:call("get_isDead") == true
                    es.tracked[addr] = e
                end
            end
            if e then
                seen[addr] = true
                -- A Molded out of the pool takes its spawn point's id (see spawn_ids).
                if e.id:sub(1, 2) ~= "g:" then
                    local map, body = spawn_ids(os.clock())
                    local sid = map[addr]
                    if sid and sid ~= e.id then
                        log(string.format("%s is now %s (was %s%s)", e.name, sid, e.id, e.standin and ", a stand-in" or ""))
                        if coop_enemy_orphan then pcall(coop_enemy_orphan, e, false) end   -- a copy of what it was
                        e.id, e.hp, e.dup, e.standin = sid, nil, false, nil
                        -- A new body for a Molded the friend's game runs (v0.49): a copy at once (see settled);
                        -- left to its own AI until it had walked 1 m, it stood 3 m from the friend's (bot test).
                        if em_move and em_move.own and type(em_move.own[sid]) == "number" then e.replaced = true end
                        e.dead = e.dc:call("get_isDead") == true
                    elseif sid == nil and e.id:sub(1, 2) == "s:" and body[e.id] and body[e.id] ~= addr then
                        -- Its spawn point has another body now: this one is left over (two bodies
                        -- with one id were seen 2026-11-10). Back to its pool name, so it's left alone.
                        log(string.format("%s %s: its spawn point has another body now%s", e.name, e.id,
                            e.standin and " (the game's own came out: the stand-in goes back to the pool)" or ""))
                        if coop_enemy_orphan then pcall(coop_enemy_orphan, e, true) end
                        e.id, e.hp, e.standin = enemy_id(go), nil, nil
                    end
                end
                local active = safe(go.call, go, "get_Update") == true
                -- When it came out here, and whether it has walked yet (v0.47, see settled).
                if active then
                    local p = safe(function() return go:call("get_Transform"):call("get_Position") end)
                    if e.active_t == nil then
                        e.active_t, e.out = os.clock(), false
                        e.start_pos = p and { x = p.x, z = p.z } or nil
                    elseif not e.out and p and e.start_pos and (p.x - e.start_pos.x) ^ 2 + (p.z - e.start_pos.z) ^ 2 > 1 then
                        e.out = true
                    end
                else
                    e.active_t, e.out, e.start_pos = nil, nil, nil
                    -- Asleep again: a Molded taken out of its pool goes back (see unpool).
                    if e.pool and coop_enemy_repool then pcall(coop_enemy_repool, e) end
                end
                local dead = e.dc:call("get_isDead") == true
                if not dead and active and es.dead_here[e.id] then es.dead_here[e.id] = nil end   -- alive again (a load)
                if e.dup then
                    -- Its id is shared with another enemy here: nothing is sent or applied for it.
                elseif dead and not e.dead then
                    -- Died here. Tell the friend, unless we did it on their word.
                    if e.id:sub(1, 2) == "s:" then es.dead_here[e.id] = chapter() end   -- never spawned again for them (v0.49)
                    if es.applying[e.id] and os.clock() - es.applying[e.id] < 5 then
                        es.applying[e.id] = nil
                    elseif scripted_now() and not is_regular(e.name) then
                        log("not sent: " .. e.name .. " went down in a scripted scene (it does in theirs too)")
                    else
                        send_event(string.format("kill %s %d %s", e.id, chapter(), e.name))
                        if coop_stat then pcall(coop_stat, "kills") end   -- the session page (v0.42)
                    end
                elseif not dead and e.dead then
                    log("back up: " .. e.name .. " " .. e.id)
                end
                -- Damage here (health dropped, still alive): tell the friend how much.
                -- Damage we applied on the friend's word already moved e.hp, so it isn't sent back.
                local hp = e.dc:call("get_health") or 0
                if e.hp and not e.dup and not dead and active and hp < e.hp - 0.5 then
                    if scripted_now() then
                        -- Scripted damage (Mia's wall throw took 1300): their scene does its own.
                        if not is_regular(e.name) then
                            log(string.format("not sent: %s lost %.0f in a scripted scene", e.name, e.hp - hp))
                        end
                    else
                        send_event(string.format("dmg %s %d %.1f %s", e.id, chapter(), e.hp - hp, e.name))
                    end
                end
                e.hp = hp
                e.dead = dead
                if not dead and active and not e.dup and es.pending[e.id] == chapter() then
                    es.pending[e.id] = nil
                    es.applying[e.id] = os.clock()
                    local ok, err = pcall(kill_enemy, e)
                    note(ok and ("your friend already killed " .. e.name .. " here") or ("ERR remembered kill: " .. tostring(err)))
                end
            end
        end
    end
    for addr in pairs(es.tracked) do if not seen[addr] then es.tracked[addr] = nil end end
    -- Molded newly out here go to the friend, and the friend's are brought out here (v0.48).
    if #es.spawn_out > 0 then
        for _, t in ipairs(es.spawn_out) do send_event(string.format("spawn %s %d", t, chapter())) end
        es.spawn_out = {}
    end
    pcall(spawn_requests, os.clock())
    -- Two enemies here with one id (pooled Molded not out yet, see spawn_ids): neither is
    -- synced until each has an id of its own.
    local n_id = {}
    for _, e in pairs(es.tracked) do n_id[e.id] = (n_id[e.id] or 0) + 1 end
    for _, e in pairs(es.tracked) do e.dup = n_id[e.id] > 1 end
    -- Health check-in for the Molded (v0.24): every 3 s each awake one's health goes out as
    -- "ehp", and the game where it's higher lowers it to match. A damage message that never
    -- arrived (a load, a rejoin) can't leave the same Molded with two different healths.
    -- Never raised, never to 0 (the kill event does that), and not Jack or other bosses:
    -- their scripted phases set their own health.
    local now = os.clock()
    if now - (es.ehp_t or 0) >= 3 then
        es.ehp_t = now
        for _, e in pairs(es.tracked) do
            if is_regular(e.name) and not e.dup and not e.dead and (e.hp or 0) > 0 and safe(e.go.call, e.go, "get_Update") == true then
                send_event(string.format("ehp %s %d %.1f %s", e.id, chapter(), e.hp, e.name))
            end
        end
    end
end

local function find_tracked(id)
    for _, e in pairs(es.tracked) do if e.id == id then return (not e.dup) and e or nil end end
    return nil
end

-- The friend hurt an enemy: take the same health off ours. setHealth rather than
-- another hit, so the game doesn't scale it a second time. Never to 0 here: setting 0
-- leaves a walking "dead" enemy; the friend's kill event follows and does it properly.
-- Hit reaction for damage that came over the network. addManualDamage / addHitDamage play
-- none (2026-11-01), so ask the enemy's action controller directly: requestDamageAction with
-- a ResistResultSet. ResistResult Damaged = 1; resist type Small = 0 (Middle = 1 for big
-- hits); body part Chest = 0. Untested in play.
local RESIST_DAMAGED, RESIST_SMALL, RESIST_MIDDLE, PART_CHEST = 1, 0, 1, 0
FLINCH_EVERY = 1.2
function flinch(e, amount)
    if e.ac == nil then
        for _, c in ipairs(arr_items(e.go:call("get_Components"))) do
            if c:get_type_definition():is_a("app.EnemyActionController") then e.ac = c break end
        end
    end
    if e.ac == nil then return "no action controller" end
    if e.ac:call("get_isForbidDamageReaction") then return "reactions forbidden right now" end
    -- sdk.create_instance gave nothing (2026-11-03, on Jack): it's most likely a struct, which
    -- REFramework builds with ValueType.new.
    local td = sdk.find_type_definition("app.EnemyActionController.ResistResultSet")
    if td == nil then return "no ResistResultSet type" end
    -- It's a class whose only constructor takes four arguments, so sdk.create_instance gave nil and no friend's hit
    -- ever made an enemy flinch ("no ResistResultSet (value type: false)" in every log since v0.36). Made without
    -- its constructor (simplify) and filled in below, it works: the Molded played its hit reaction, bank 40 motion
    -- 100, for a second (bot test 2026-11-20).
    local rs
    if td:is_value_type() then
        rs = ValueType.new(td)
    else
        rs = sdk.create_instance("app.EnemyActionController.ResistResultSet", true)
    end
    if rs == nil then return "no ResistResultSet (value type: " .. tostring(td:is_value_type()) .. ")" end
    rs:set_field("result", RESIST_DAMAGED)
    rs:set_field("resistType", (amount or 0) >= 200 and RESIST_MIDDLE or RESIST_SMALL)
    rs:set_field("resistParts", PART_CHEST)
    rs:set_field("hasBlownaway", false)
    e.ac:call("requestDamageAction(app.EnemyActionController.ResistResultSet)", rs)
    return "requested"
end

local function on_damage(id, ch, amount, name)
    if ch ~= chapter() then return end
    if scripted_now() then
        log(string.format("friend's hit on %s (%.0f) not applied: a scripted scene is playing", name, amount))
        return
    end
    local e = find_tracked(id)
    if e == nil or e.dead or safe(e.go.call, e.go, "get_Update") ~= true then return end
    local hp = e.dc:call("get_health") or 0
    local new = math.max(hp - amount, 1.0)
    e.dc:call("setHealth(System.Single, System.Single)", new, e.dc:call("get_maxHealth"))
    e.hp = e.dc:call("get_health")
    -- The reaction plays only where the enemy's AI runs; a copy follows its owner's clip.
    -- At most one forced reaction per FLINCH_EVERY s (v0.57, now that they play): every handgun bullet staggering it
    -- would make the friend's shots far stronger than the game's own resistances.
    if (em_move == nil or type(em_move.own[id]) ~= "number") and is_regular(name) and os.clock() - (e.flinch_t or -100) >= FLINCH_EVERY then
        e.flinch_t = os.clock()
        -- Not bosses (v0.36): their reactions are scripted; a forced one went with a crash.
        local ok, res = pcall(flinch, e, amount)
        if not es.flinch_logged or not ok then
            es.flinch_logged = true
            log("flinch " .. name .. ": " .. (ok and tostring(res) or ("ERR " .. tostring(res))))
        end
    end
    es.applied_dmg = (es.applied_dmg or 0) + 1
    log(string.format("friend hit %s for %.0f: %.0f -> %.0f", name, amount, hp, e.hp))
end

-- Which friend's game has which Molded awake (v0.49): their health check-ins ("ehp", every 3 s) list
-- them. A hand-over held back after a "took back" (mv.no_handoff, for a game that hasn't got it) goes
-- ahead when the friend's game clearly has it: the bot test had a Molded kept 18 m from its runner's
-- player for a minute, next to the friend.
es.friend_has = es.friend_has or {}
function coop_friend_has(id)
    local t = es.friend_has[id]
    return t ~= nil and os.clock() - t < 7
end

local function on_ehp(id, ch, v, name)
    if ch ~= chapter() or not is_regular(name) then return end
    es.friend_has[id] = os.clock()
    local e = find_tracked(id)
    if e == nil or e.dead or safe(e.go.call, e.go, "get_Update") ~= true then return end
    local hp = e.dc:call("get_health") or 0
    if hp <= v + 1 then return end
    local new = math.max(v, 1.0)
    e.dc:call("setHealth(System.Single, System.Single)", new, e.dc:call("get_maxHealth"))
    e.hp = e.dc:call("get_health")
    log(string.format("health check: %s %.0f -> %.0f (matched the friend's)", name, hp, e.hp))
end

local function on_event(text)
    -- Catch-up batches and quick messages belong to coop_talk.lua (a catch-up batch is
    -- unpacked there and each change comes back through coop_apply_event).
    if coop_talk_on_event and coop_talk_on_event(text) then return end
    -- The lobby belongs to the in-game co-op menu (coop_menu.lua, v0.40).
    if coop_menu_on_event and coop_menu_on_event(text) then return end
    -- Character looks belong to coop_dummy.lua's lobby; doors and items to coop_world.lua.
    -- Each friend's look, weapon and animation set go to that friend's character.
    local env = coop_slot_envs and coop_slot_envs[coop_event_slot or 1]
    local lobby_fn = env and rawget(env, "coop_lobby_on_event") or coop_lobby_on_event
    if lobby_fn and lobby_fn(text) then return end
    if coop_world_on_event and coop_world_on_event(text) then return end
    if coop_story_on_event and coop_story_on_event(text) then return end
    if coop_revive_on_event and coop_revive_on_event(text) then return end
    if coop_gunsound_on_event and coop_gunsound_on_event(text) then return end
    -- v0.57: the host's game hands us a Molded it can't set on us ("hrun <id> <chapter> <our SteamID or 0>").
    local rid, rch, rto = text:match("^hrun (%S+) (%-?%d+) (%S+)$")
    if rid then
        if coop_enemy_take_run then pcall(coop_enemy_take_run, rid, tonumber(rch), rto) end
        return
    end
    -- v0.57: which game runs Jack's car in the garage fight.
    if coop_car_on_event and coop_car_on_event(text) then return end
    -- v0.57: a host's enemy hit our character in their game ("Host runs every enemy").
    local hto, hdmg, hname, hid, hch = text:match("^hurt (%S+) (%d+) (%S+) (%S+) (%-?%d+)$")
    if hto then
        if coop_enemy_apply_hurt then pcall(coop_enemy_apply_hurt, hto, tonumber(hdmg), hname, hid, tonumber(hch)) end
        return
    end
    local pz = text:match("^pause ([01])")
    if pz then
        -- em_move, not mv: the local alias is declared further down, so "mv" here was a nil
        -- global and every pause message failed (both logs, 2026-11-03).
        if em_move then
            local slot = coop_event_slot or 1
            em_move.paused_slots = em_move.paused_slots or {}
            em_move.paused_slots[slot] = pz == "1" and os.clock() or nil
            if slot == 1 then
                em_move.friend_paused = pz == "1"
                em_move.friend_paused_t = os.clock()
            end
        end
        note(pz == "1" and "your friend paused the game" or "your friend is back")
        return
    end
    local oid, och, oname, otarget = text:match("^own (%S+) (%-?%d+) (%S+) ?(%d*)")
    if oid then
        if enemy_move_on_own then enemy_move_on_own(oid, tonumber(och), oname, otarget ~= "" and otarget or nil) end
        return
    end
    -- v0.51: a friend's copy asks for one of our enemy's animation banks / we get one for ours.
    local rid, rch, rbank = text:match("^ebankreq (%S+) (%-?%d+) (%d+)$")
    if rid then
        if coop_enemy_bank_req then pcall(coop_enemy_bank_req, rid, tonumber(rch), tonumber(rbank)) end
        return
    end
    local bid, bch, bbank, bow, bpath = text:match("^ebank (%S+) (%-?%d+) (%d+) ([01]) (%S+)$")
    if bid then
        if coop_enemy_bank then pcall(coop_enemy_bank, bid, tonumber(bch), tonumber(bbank), tonumber(bow), bpath) end
        return
    end
    -- v0.51: the friend's game was handed an enemy it can't run (and why): ours again at once.
    local kid, kch, kname, kwhy = text:match("^eskip (%S+) (%-?%d+) (%S+) (.+)$")
    if kid then
        if coop_enemy_skip then pcall(coop_enemy_skip, kid, tonumber(kch), kname, kwhy) end
        return
    end
    local fch, flist = text:match("^mtgt (%-?%d+) ?(.*)$")
    if fch then
        if coop_enemies_on_fight then pcall(coop_enemies_on_fight, tonumber(fch), flist) end
        return
    end
    local sg, sch = text:match("^spawn (%S+) (%-?%d+)$")
    if sg then
        if tonumber(sch) == chapter() and not (settings and settings.share_spawns == false) then
            es.spawn_want[sg] = { ch = tonumber(sch), until_t = os.clock() + SPAWN_WANT_S }
        end
        return
    end
    local hid, hch, hv, hname = text:match("^ehp (%S+) (%-?%d+) ([%d%.]+) (%S+)")
    if hid then pcall(on_ehp, hid, tonumber(hch), tonumber(hv), hname) return end
    local did, dch, damt, dname = text:match("^dmg (%S+) (%-?%d+) ([%d%.]+) (%S+)")
    if did then on_damage(did, tonumber(dch), tonumber(damt), dname) return end
    local id, ch, name = text:match("^kill (%S+) (%-?%d+) (%S+)")
    if id == nil then log("ignored event: " .. text) return end
    ch = tonumber(ch)
    if ch ~= chapter() then log("kill in another chapter, ignored: " .. text) return end
    if scripted_now() and not is_regular(name) then
        log("kill of " .. name .. " not applied: a scripted scene is playing (it plays here too)")
        return
    end
    local e = find_tracked(id)
    local active = e and safe(e.go.call, e.go, "get_Update") == true
    if e and active and not e.dead then
        es.applying[id] = os.clock()
        local ok, err = pcall(kill_enemy, e)
        es.applied = es.applied + 1
        note(ok and ("your friend took down " .. name) or ("ERR applying kill: " .. tostring(err)))
    elseif e and e.dead then
        log("already down here: " .. name)
    elseif is_regular(name) then
        es.pending[id] = ch   -- not here or not awake yet: kill it when it is
        note("your friend killed " .. name .. " (here when you get there)")
    else
        log("friend downed " .. name .. ", not active here: ignored")
    end
end

function coop_apply_event(text) on_event(text) end

-- A chapter jump starts that chapter over (v0.40): the friend's remembered kills there are old.
function coop_enemies_reset_chapter(v)
    local n = 0
    for id, ch in pairs(es.pending) do if ch == v then es.pending[id] = nil n = n + 1 end end
    if n > 0 then log(string.format("chapter %d starts over: %d remembered kills dropped", v, n)) end
end

local ready = { since = nil }
local function game_ready()
    local om = sdk.get_managed_singleton("app.ObjectManager")
    local p = om and safe(om.get_field, om, "PlayerObj")
    local gm = sdk.get_managed_singleton("app.GameManager")
    if p == nil or (gm and safe(gm.get_field, gm, "IsTitleDisp") == true) then ready.since = nil return false end
    ready.since = ready.since or os.clock()
    return os.clock() - ready.since >= 5
end

HELD_IN_CUTSCENE = { open = true, close = true, unlock = true, drawer = true, switch = true, intr = true,
    ["break"] = true, dbreak = true, took = true, got = true, kill = true, catchup = true, own = true,
    drop = true }   -- v0.51: a friend's discarded item is put down after our cutscene, not during it
DROPPED_IN_CUTSCENE = { phys = true, dang = true, dmg = true, ehp = true }
-- Seconds after which a message that waited (while we loaded) is dropped (v0.39). A friend's
-- scene from a minute ago, or a hand-off of an enemy that has moved on since, would only do
-- harm now. Lasting changes (doors, drawers, pickups...) have no limit.
STALE_AFTER = { story = 20, own = 10, phys = 3, dang = 3, dmg = 5, talk = 60, heal = 10, drop = 120 }

-- Changes kept during our cutscene: applied 1 s after it ends (and after a scene settles).
local function release_held(now)
    if es.held == nil or #es.held == 0 then
        if (es.dropped_n or 0) > 0 then log(string.format("cutscene: dropped %d pushes/hits from the friend", es.dropped_n)) es.dropped_n = 0 end
        return
    end
    if local_cutscene and local_cutscene() then es.cut_end_t = nil return end
    es.cut_end_t = es.cut_end_t or now
    if now - es.cut_end_t < 1 then return end
    local list = es.held
    es.held, es.cut_end_t = {}, nil
    log(string.format("cutscene over: applying %d changes from the friend that waited", #list))
    for _, h in ipairs(list) do
        coop_event_slot = h.slot
        local ok, err = pcall(on_event, h.body)
        coop_event_slot = 1
        if not ok then log("event ERR " .. tostring(err)) end
    end
end

local function read_events()
    pcall(release_held, os.clock())
    -- Not while loading or on the title screen (v0.32): the events wait in the file.
    if es.ev_in_last >= 0 and not game_ready() then return end
    local text = fs.read("coopnet_ev_in.txt")
    if text == nil or text == "" then   -- fs.read gives "" for a missing file
        if es.ev_in_last < 0 then es.ev_in_last = 0 end   -- nothing received yet: handle all that comes
        return
    end
    local lines, max_n = {}, -1
    for line in text:gmatch("[^\n]+") do
        -- "<n>\t<arrival, Unix seconds>\t<text>" since v0.39 ("<n>\t<text>" before).
        local n, at, body = line:match("^(%d+)\t(%d+)\t(.*)$")
        if n == nil then n, body = line:match("^(%d+)\t(.*)$") end
        n = tonumber(n)
        if n then
            lines[#lines + 1] = { n, body, tonumber(at) }
            if n > max_n then max_n = n end
        end
    end
    -- First read after Reset scripts: what's in the file was handled before.
    if es.ev_in_last < 0 then es.ev_in_last = math.max(max_n, 0) return end
    -- CoopNet restarted (it deletes the file and counts from 1 again).
    if max_n < es.ev_in_last then es.ev_in_last = 0 end
    for _, l in ipairs(lines) do
        if l[1] > es.ev_in_last and not (es.early and es.early[l[1]]) then
            -- Friends 2 and 3 (v0.29): "@2 <text>" / "@3 <text>". coop_event_slot says whose
            -- event is being handled (1 for friend 1), for the handlers that care.
            local body, slot = l[2], 1
            local sk, rest = body:match("^@([23]) (.*)$")
            if sk then slot, body = tonumber(sk), rest end
            local kind = body:match("^(%S+)")
            local age = l[3] and (os.time() - l[3]) or 0
            if STALE_AFTER[kind] and age > STALE_AFTER[kind] then
                -- Arrived while we were loading, too long ago to act on (v0.39).
                es.stale_n = (es.stale_n or 0) + 1
                if kind == "story" or kind == "own" then log(string.format("too old to act on (%d s): %s", age, body)) end
            elseif local_cutscene and local_cutscene() and HELD_IN_CUTSCENE[kind] then
                es.held = es.held or {}
                if #es.held < 300 then es.held[#es.held + 1] = { slot = slot, body = body } end
                es.held_n = (es.held_n or 0) + 1
            elseif local_cutscene and local_cutscene() and DROPPED_IN_CUTSCENE[kind] then
                es.dropped_n = (es.dropped_n or 0) + 1
            else
                coop_event_slot = slot
                local ok, err = pcall(on_event, body)
                coop_event_slot = 1
                if not ok then log("event ERR " .. tostring(err)) end
            end
        end
    end
    if max_n > es.ev_in_last then es.ev_in_last = max_n end
    es.early = nil   -- everything up to max_n is handled now
end

-- Lobby messages on the title screen (v0.54). Everything a friend sends waits in the file while this game is
-- on the title screen or loading (above, v0.32: world changes can't be applied there), and that held the
-- lobby's own messages back too: a friend on the title screen never heard the host's lobby or its Start, so
-- "start the game from the lobby" only ever worked for players already in a game (bot test 2026-11-14: two
-- copies on the title screen, the host's lobby open, the guest's log had the messages and did nothing). Those
-- messages (and only those) are now read there too; each is remembered so it isn't handled a second time
-- when the rest is read.
local EARLY_KINDS = { lobby = true }
local function read_early_events()
    if es.ev_in_last < 0 or game_ready() then return end
    local text = fs.read("coopnet_ev_in.txt")
    if text == nil or text == "" then return end
    es.early = es.early or {}
    local max_n = -1
    local todo = {}
    for line in text:gmatch("[^\n]+") do
        local n, at, body = line:match("^(%d+)\t(%d+)\t(.*)$")
        if n == nil then n, body = line:match("^(%d+)\t(.*)$") end
        n = tonumber(n)
        if n then
            if n > max_n then max_n = n end
            todo[#todo + 1] = { n, body, tonumber(at) }
        end
    end
    if max_n < es.ev_in_last then es.ev_in_last, es.early = 0, {} end   -- CoopNet restarted
    for _, l in ipairs(todo) do
        if l[1] > es.ev_in_last and not es.early[l[1]] then
            local body, slot = l[2], 1
            local sk, rest = body:match("^@([23]) (.*)$")
            if sk then slot, body = tonumber(sk), rest end
            if EARLY_KINDS[body:match("^(%S+)") or ""] then
                es.early[l[1]] = true
                -- A lobby message from before this game was even on the title screen is old news.
                if not (l[3] and os.time() - l[3] > 20) then
                    coop_event_slot = slot
                    local ok, err = pcall(on_event, body)
                    coop_event_slot = 1
                    if not ok then log("event ERR " .. tostring(err)) end
                end
            end
        end
    end
end
do
    local t = 0
    dbg_note{ feature = "Lobby", name = "Read the friend's lobby messages on the title screen and while loading",
        when = "every frame; reads the file every 0.3 s, and only while on the title screen or loading",
        reads = "coopnet_ev_in.txt (the friend's messages); only 'lobby' ones are handled here",
        writes = "the lobby state (coop_menu_on_event); marks those lines handled (es.early) so the normal read skips them" }
    _G.re.on_frame(function()
        local now = os.clock()
        if now - t < 0.3 then return end
        t = now
        local ok, err = pcall(read_early_events)
        if not ok and not es.early_err then es.early_err = true log("early events ERR " .. tostring(err)) end
    end)
end

-- Enemy movement (step 3) -----------------------------------------------------------
-- One game controls the enemies ("host"); the other game's copies follow it ("puppets").
-- Host: ~10 times a second, coopnet_es_out.txt = "seq <n>" / "t <time> ch <chapter>" and
-- one line per awake enemy: id x y z yaw bank motion frame speed (animation layer 0).
-- CoopNet sends each new seq unreliably; the other side gets it as coopnet_es_in.txt.
-- Guest: for each enemy in the snapshots, switch its own animation brain (MotionFsm) and
-- AI (EnemyOrder.requestThinkOff) off, then place it 0.15 s behind the host's timeline
-- and play the host's clip. An enemy missing from the snapshots for 3 s gets its own AI
-- back. Host = the lower SteamID, so both sides agree without asking.
--
-- Ownership: each enemy is run (real AI) by one game and followed by the other. Enemies
-- only ever target their own game's player (a target set to the ghost is dropped within
-- a second), so an enemy belongs to the game of the player it's near: by default the game
-- where it's awake; if both send it, the host keeps it. The owner hands it over (reliable
-- "own <id> <chapter> <name>") when the other player is 3 m+ closer to it. A game that
-- gets no data for an enemy it gave away takes it back after 3 s (friend gone, or the
-- bot, which can't run enemies).
-- 3-4 players (v0.29): "own" names the new owner by SteamID ("own <id> <chapter> <name>
-- <steamid>"; without it, the receiver is meant, as before). An enemy owned by friend k is
-- followed from friend k's snapshots (coopnet_es_in[_k].txt). The owner hands it to whoever
-- is 3 m+ closer than itself; the host is the lowest SteamID of all; when two games both
-- send an enemy, the lower SteamID keeps it.
em_move = {
    role_pref = "auto", role = "host",
    own = {},        -- id -> "me" | friend slot 1-3 (who runs it)
    own_t = {},      -- id -> when ownership last changed
    handed = {},     -- id -> true: we gave it away and wait for the friend's data
    handoff_t = 0, handoffs = 0, takebacks = 0,
    seq = 0, snap_t = 0, in_t = 0, last_in_seq = nil,
    hist = {},       -- id -> list of { t, x, y, z, yaw, bank, mid, frame, speed }
    puppets = {},    -- id -> e
    offset = nil,    -- local clock - host clock (smallest seen)
    rec = nil, replay = nil,
    msg = "-", sent = 0, recv = 0,
}
local mv = em_move
-- Smoother copies (v0.23): Jack was jittery on the other screen (2026-11-03). At 10 updates
-- a second with 0.15 s of buffer, any late packet left the copy waiting at its last spot and
-- then jumping; now 15 a second with 0.25 s of buffer (the copy runs a tenth of a second
-- further behind, which you can't see).
local MOVE_DELAY = 0.25
local SNAP_EVERY = 1 / 15
-- v0.56: the buffer follows the link, like the friend's body (coop_dummy net.delay, v0.52: one sample gap +
-- margin + how late recent samples were, 80-300 ms). Jack "rubber banding" (2026-11-14 session): that link
-- measured 185 ms round trip with 113 ms of lateness, so snapshots (unreliable, 15 a second, one gap 67 ms)
-- often came later than the fixed 0.25 s and the copy waited, then jumped. Now the body's delay plus one
-- snapshot gap, never under 0.25 s nor over 0.6 s; it moves slowly, as net.delay does.
-- v0.56: snapshots come 15 a second; their file was read 30 times a second (each fs.read ~1.8 ms). 20 a second
-- still sees every one (a read with nothing new stops at the "seq" line).
local SNAP_READ_EVERY = 1 / 20
local function move_delay()
    local st = coop_net_state and coop_net_state()
    local d = st and tonumber(st.delay)
    if d == nil then return MOVE_DELAY end
    return math.max(MOVE_DELAY, math.min(0.6, d + SNAP_EVERY))
end

local kv_cache, kv_t = {}, -100
local function net_kv()
    if os.clock() - kv_t > 1 then
        kv_t = os.clock()
        local st = fs.read("coopnet_status.txt")
        if st and st ~= "" then
            kv_cache = {}
            for k, v in st:gmatch("(%w+)=([^\n]*)") do kv_cache[k] = v end
        end
    end
    return kv_cache
end

-- Our SteamID and each friend slot's (v0.29).
local function party_ids()
    local kv = net_kv()
    local ids = {}
    for k, key in ipairs({ "peer", "peer2", "peer3" }) do
        local id = kv[key] and kv[key]:match("^steam:(%d+)$")
        if id and id ~= "0" then ids[k] = id end
    end
    return kv.steamSelf, ids
end
local function id_less(a, b) return a ~= nil and b ~= nil and ((#a < #b) or (#a == #b and a < b)) end
local function slot_of_id(sid)
    local _, ids = party_ids()
    for k, v in pairs(ids) do if v == sid then return k end end
    return nil
end
local function friend_owned(id) return type(mv.own[id]) == "number" end

-- A Molded waits hidden in a wall or the floor when it spawns and climbs out when it's set off,
-- and until then the game holds it there: neither MovementController.warp nor its transform moves
-- it (bot test 2026-11-10). One handed over or made a copy in that time stayed stuck under the
-- floor on that screen, while the real one fought the other player. So an enemy is neither handed
-- over nor made a copy until it has walked 1 m here and been awake EMERGE_S (v0.47); until then
-- each game runs its own, as v0.46 did.
EMERGE_S = 4
local function settled(e, now)
    if not is_regular(e.name) then return true end   -- Jack and the like: as before
    if e.replaced then return true end               -- a new body for a Molded already out (v0.49, scan)
    return e.out == true and e.active_t ~= nil and now - e.active_t >= EMERGE_S
end
-- Friend slot k's SteamID is lower than ours (they win a tie).
local function lower_than_me(k)
    local me, ids = party_ids()
    return id_less(ids[k], me)
end

local function decide_role()
    if mv.replay then return "guest" end
    if mv.role_pref ~= "auto" then return mv.role_pref end
    local kv = net_kv()
    if kv.mode == "udp" then
        local r = coop_udp_role and coop_udp_role()
        if r then return r end
    end
    if kv.mode == "steam" then
        local me, ids = party_ids()
        if me and next(ids) then
            for _, id in pairs(ids) do if id_less(id, me) then return "guest" end end
            return "host"
        end
    end
    return "host"
end

local function layer0(e)
    if e.layer == nil then
        local mot = safe(e.go.call, e.go, "getComponent(System.Type)", sdk.typeof("via.motion.Motion"))
        e.layer = mot and safe(mot.call, mot, "getLayer", 0)
    end
    return e.layer
end

local function yaw_of(q) return 2 * math.atan(q.y, q.w) end

-- Held weapons. Each enemy's app.EquipManager has its own weapons (ManagedWeapons; Jack:
-- Shovel, Roller, FireAxe). In hand = drawn and parented to the enemy. EquipWeaponIdRight
-- stays 0 whatever is held, so it can't be read. equipWeapon(WeaponID, Hand) attaches and
-- shows one but never puts the previous one away, so a follower shows the friend's weapon
-- (by name, equipped if needed) and hides the rest itself.
local function equip_of(e)
    if e.equip == nil then
        e.equip = safe(e.go.call, e.go, "getComponent(System.Type)", sdk.typeof("app.EquipManager")) or false
    end
    return e.equip or nil
end

local weapon_ids = nil   -- "Shovel" -> app.WeaponID value
local function weapon_id(name)
    if weapon_ids == nil then
        weapon_ids = {}
        local td = sdk.find_type_definition("app.WeaponID")
        for _, f in ipairs(td and td:get_fields() or {}) do
            if f:is_static() then weapon_ids[f:get_name()] = safe(f.get_data, f, nil) end
        end
    end
    return weapon_ids[name]
end

-- v0.51: read at most once a second per enemy, and a weapon whose object is gone is never asked again. The
-- game keeps destroyed weapons in ManagedWeapons (Mia's dropped knife), and asking one for its GameObject
-- throws inside the game: 28 a second in the 2026-11-12 playtest (twice per snapshot), 120 a second in
-- Chapter 3, each one also written to REFramework's log.
-- Forgotten once a minute: a new weapon could reuse a dead one's address (one failed call a minute is nothing).
local dead_weapon_addr, dead_weapon_t = {}, 0
local function weapons_of(e)
    local now = os.clock()
    if now - dead_weapon_t > 60 then dead_weapon_addr, dead_weapon_t = {}, now end
    if e.wpn_list and now - (e.wpn_t or 0) < 1 then return e.wpn_list end
    local eq = equip_of(e)
    local list = eq and safe(eq.get_field, eq, "ManagedWeapons")
    local out = {}
    for i = 0, (list and list:call("get_Count") or 0) - 1 do
        local w = list:call("get_Item", i)
        local a = w and w:get_address()
        if a and not dead_weapon_addr[a] then
            local go = safe(w.call, w, "get_GameObject")
            if go then out[#out + 1] = go else dead_weapon_addr[a] = true end
        end
    end
    e.wpn_list, e.wpn_t = out, now
    return out
end

local function held_weapon(e)
    for _, go in ipairs(weapons_of(e)) do
        local parent = safe(function() return go:call("get_Transform"):call("get_Parent") end)
        if parent and go:call("get_Draw") and parent:call("get_GameObject") == e.go then return go:call("get_Name") end
    end
    return "-"
end

-- Follower: show exactly `want` ("-" = none). Hidden ones are remembered so the enemy's
-- own AI gets them back when the follower is released.
local function show_weapon(e, want)
    if e.cur_weapon == want then return end
    e.cur_weapon = want
    e.hidden_weapons = e.hidden_weapons or {}
    local found = false
    for _, go in ipairs(weapons_of(e)) do
        local name = go:call("get_Name")
        if name == want then
            found = true
            local parent = safe(function() return go:call("get_Transform"):call("get_Parent") end)
            if not (parent and parent:call("get_GameObject") == e.go) then
                local id = weapon_id(want)
                local eq = equip_of(e)
                if id and eq then pcall(eq.call, eq, "equipWeapon(app.WeaponID, app.CharacterDefine.Hand)", id, 0) end
            end
            pcall(go.call, go, "set_DrawSelf", true)
            e.hidden_weapons[name] = nil
        elseif go:call("get_Draw") then
            pcall(go.call, go, "set_DrawSelf", false)
            e.hidden_weapons[name] = go
        end
    end
    log(string.format("follower %s holds %s%s", e.name, want, (want ~= "-" and not found) and " (not in its weapon list)" or ""))
end

-- Its own AI is back: keep the weapon the friend last reported. Un-hide only weapons
-- that are no longer attached to the enemy (put away); one still attached would show as
-- a second weapon in hand (Jack ended up with the axe and the shovel).
local function restore_weapons(e)
    for name, go in pairs(e.hidden_weapons or {}) do
        local parent = safe(function() return go:call("get_Transform"):call("get_Parent") end)
        local attached = parent ~= nil and parent:call("get_GameObject") == e.go
        if not attached then pcall(go.call, go, "set_DrawSelf", true) end
    end
    e.hidden_weapons, e.cur_weapon = nil, nil
end

local function enemy_line(e)
    local tr = e.go:call("get_Transform")
    local p, q = tr:call("get_Position"), tr:call("get_Rotation")
    local L = layer0(e)
    if L == nil then return nil end
    return string.format("%s %.3f %.3f %.3f %.4f %d %d %.2f %.3f %s", e.id, p.x, p.y, p.z, yaw_of(q),
        L:call("get_MotionBankID") or 0, L:call("get_MotionID") or 0, L:call("get_Frame") or 0, L:call("get_Speed") or 1,
        safe(held_weapon, e) or "-")
end

local function parse_line(line)
    local id, x, y, z, yaw, bank, mid, frame, speed, weapon =
        line:match("^(%S+) (%S+) (%S+) (%S+) (%S+) (%-?%d+) (%-?%d+) (%S+) (%S+) (%S+)$")
    if id == nil then
        id, x, y, z, yaw, bank, mid, frame, speed =
            line:match("^(%S+) (%S+) (%S+) (%S+) (%S+) (%-?%d+) (%-?%d+) (%S+) (%S+)$")
    end
    if id == nil then return nil end
    return id, { x = tonumber(x), y = tonumber(y), z = tonumber(z), yaw = tonumber(yaw),
        bank = tonumber(bank), mid = tonumber(mid), frame = tonumber(frame), speed = tonumber(speed),
        weapon = weapon }
end

local function push_hist(id, s, t)
    s.t = t
    local h = mv.hist[id]
    if h == nil then h = {} mv.hist[id] = h end
    h[#h + 1] = s
    while #h > 2 and h[2].t < t - 2 do table.remove(h, 1) end
end

-- Host: write the snapshot of our awake enemies (puppets excluded).
-- Our story sequence is still playing out (coop_story, v0.39): between the dinner and the
-- escape Jack sits at our table while the friend's Jack may already roam the house. Then
-- enemies other than bosses are neither followed nor sent. Checked twice a second.
local seq_cache = { t = -100, on = false }
local function in_story_sequence()
    local now = os.clock()
    if now - seq_cache.t >= 0.5 then
        seq_cache.t = now
        local on = coop_story_in_sequence ~= nil and coop_story_in_sequence() == true
        if on ~= seq_cache.on then
            log(on and "story sequence playing out: enemies (not bosses) run in each game on their own"
                or "story sequence over: enemies follow again")
        end
        seq_cache.on = on
    end
    return seq_cache.on
end
local function seq_hold(name) return not BOSS_FOLLOW[name] and in_story_sequence() end

-- At most this many enemies per snapshot, the nearest to our player first (v0.39).
SNAP_MAX = 24
local function write_snapshot(now)
    local lines = { "seq " .. mv.seq, string.format("t %.3f ch %d", now, chapter()) }
    local om = sdk.get_managed_singleton("app.ObjectManager")
    local player = om and safe(om.get_field, om, "PlayerObj")
    local pp = player and safe(function() return player:call("get_Transform"):call("get_Position") end)
    local list = {}
    for _, e in pairs(es.tracked) do
        -- The host sends every enemy it runs; the guest only the ones handed to it.
        local mine = moves_shared(e.name) and (mv.own[e.id] == "me" or (mv.role == "host" and not friend_owned(e.id)))
        if BOSS_FOLLOW[e.name] and not BOSS_HANDOFF[e.name] and mv.role ~= "host" then mine = false end   -- a copied boss: the host's only (v0.48)
        -- Host runs every enemy (v0.57): the host sends all of them, the others none.
        if host_mode() then
            mine = moves_shared(e.name) and ((mv.role == "host" and type(mv.own[e.id]) ~= "number") or (es.hq_own ~= nil and es.hq_own[e.id] ~= nil))
        end
        -- The garage car fight (v0.57): Jack is sent by the game that runs the car, only.
        if car_pinned(e.name) then mine = coop_car.runner == "me" end
        if mine and not e.dup and not seq_hold(e.name) and safe(e.go.call, e.go, "get_Update") == true and not mv.puppets[e.id] then
            local l = safe(enemy_line, e)
            if l then
                local ep = pp and safe(function() return e.go:call("get_Transform"):call("get_Position") end)
                local d = (ep and pp) and ((ep.x - pp.x) ^ 2 + (ep.y - pp.y) ^ 2 + (ep.z - pp.z) ^ 2) or 0
                list[#list + 1] = { d = d, l = l }
            end
        end
    end
    table.sort(list, function(a, b) return a.d < b.d end)
    for i = 1, math.min(#list, SNAP_MAX) do lines[#lines + 1] = list[i].l end
    -- Jack's car (v0.57): one "car ..." line while our game runs it.
    local cl = coop_car_line and safe(coop_car_line)
    if cl then lines[#lines + 1] = cl end
    -- "end" closes a whole snapshot: CoopNet sends only whole ones (v0.39).
    lines[#lines + 1] = "end"
    mv.seq = mv.seq + 1
    lines[1] = "seq " .. mv.seq
    fs.write("coopnet_es_out.txt", table.concat(lines, "\n") .. "\n")
    mv.sent = mv.sent + 1
end

-- While our cutscene plays no snapshot goes out (v0.39), but the car fight's own moments (Jack pulling the player
-- out of the car, hijacking it) can count as one: the car line still goes, on its own (v0.57).
local function write_car_only(now)
    local cl = coop_car_line and safe(coop_car_line)
    if not cl then return end
    mv.seq = mv.seq + 1
    fs.write("coopnet_es_out.txt", table.concat({ "seq " .. mv.seq, string.format("t %.3f ch %d", now, chapter()), cl, "end" }, "\n") .. "\n")
    mv.sent = mv.sent + 1
end

-- An enemy right next to our player may have hold of us (v0.51). Mia grabbing Ethan, her chainsaw locked
-- against his blade: Ethan's body is tied to hers for the move. The 2026-11-12 playtest had her handed to
-- the friend's game, taken back 3 s later and made a copy there in the middle of a grab: the copy, with
-- its own brain off and moved from the other game, dragged the friend's Ethan up and out of the map
-- again and again until he loaded a save. So within HOLD_R m of our player an enemy that is ours stays
-- ours: no copy is made of it and it isn't handed over until it lets go (both games run it meanwhile).
HOLD_R = 2.0
local function near_my_player(e, r)
    local om = sdk.get_managed_singleton("app.ObjectManager")
    local player = om and safe(om.get_field, om, "PlayerObj")
    if player == nil or e == nil then return false end
    local ep = safe(function() return e.go:call("get_Transform"):call("get_Position") end)
    local pp = safe(function() return player:call("get_Transform"):call("get_Position") end)
    if ep == nil or pp == nil then return false end
    local d = r or HOLD_R
    return (ep.x - pp.x) ^ 2 + (ep.y - pp.y) ^ 2 + (ep.z - pp.z) ^ 2 < d * d
end
local function awake_near_me(e)
    return e ~= nil and not e.dead and safe(e.go.call, e.go, "get_Update") == true and near_my_player(e)
end
local function hold_note(e)
    mv.hold_logged = mv.hold_logged or {}
    if mv.hold_logged[e.id] then return end
    mv.hold_logged[e.id] = true
    log(string.format("%s %s is right next to you: it stays yours until it moves off (no copy mid-grab)", e.name, e.id:sub(1, 12)))
end

-- Friend k is in a cutscene: their samples carry the cutscene flag (coop_dummy keeps it as
-- friend_cutscene, per friend).
local function friend_in_cutscene(k)
    local env = coop_slot_envs and coop_slot_envs[k or 1] or _G
    local v = rawget(env, "friend_cutscene")
    if v == nil and (k or 1) == 1 then v = rawget(_G, "friend_cutscene") end
    return v == true
end

-- How long a game that handed an enemy over waits for the friend's data before taking it back (v0.51):
-- 3 s as before; a boss 6 s (in the 2026-11-12 playtest Mia came back after 3 s twice, mid-fight, with the
-- friend's ping high); up to 30 s while the friend is in a cutscene (their game sends nothing then). A
-- friend's game that says it can't run it ("eskip") gives it back at once.
local function quiet_limit(e, k)
    if mv.skip_why and mv.skip_why[e.id] then return 0 end
    -- Jack in the car fight (v0.57) stays with the game that runs the car, even through its quiet moments.
    if car_pinned(e.name) and coop_car.runner == k then return 60 end
    if type(k) == "number" and friend_in_cutscene(k) then return 30 end
    if BOSS_FOLLOW[e.name] or BOSS_HANDOFF[e.name] then return 6 end
    return 3
end

-- Is friend slot k taken? (v0.55, coop_dummy.lua coop_slot_in_use): an empty slot's snapshot file isn't read
-- (an fs.read costs about 0.8 ms even for a file that isn't there, 30 times a second per slot).
local function slot_live(k) return k == 1 or coop_slot_in_use == nil or coop_slot_in_use(k) end

-- Guest: take a received snapshot into the per-enemy timelines.
local function read_snapshot(now, k)
    local text = fs.read(k == 1 and "coopnet_es_in.txt" or ("coopnet_es_in_" .. k .. ".txt"))
    if text == nil or text == "" then return end
    mv.last_in_seq_s = mv.last_in_seq_s or {}
    mv.offset_s = mv.offset_s or {}
    local seq = text:match("^seq (%d+)")
    if seq == nil or seq == mv.last_in_seq_s[k] then return end
    mv.last_in_seq_s[k] = seq
    local t, ch = text:match("\nt (%S+) ch (%-?%d+)")
    t, ch = tonumber(t), tonumber(ch)
    if t == nil or ch ~= chapter() then return end
    local off = now - t
    -- A jump of 5 s+ means that friend's clock restarted: start over (see coop_dummy).
    local o = mv.offset_s[k]
    if o == nil or off < o or off > o + 5 then o = off mv.offset_s[k] = o end
    if k == 1 then mv.offset = o end
    -- Jack's car (v0.57): followed even through their cutscene (the car fight's own moments can count as one).
    local cl = coop_car_on_line and text:match("\n(car [^\n]+)")
    if cl then pcall(coop_car_on_line, cl, t + o, k) end
    -- Their cutscene moves their enemies (v0.39): Jack sat at their dinner table while ours had
    -- moved on (2026-11-08). Nothing of theirs is followed until it ends.
    if friend_in_cutscene(k) then return end
    for line in text:gmatch("[^\n]+") do
        local id, s = parse_line(line)
        local te = id and find_tracked(id)
        if te and not moves_shared(te.name) then id = nil end   -- a boss: ours runs on its own
        if te and seq_hold(te.name) then id = nil end           -- our story sequence plays out (v0.39)
        if id then
            -- Friend k runs it. Two games running the same enemy: the lower SteamID keeps it.
            local own, take = mv.own[id], false
            if te and car_pinned(te.name) then
                -- The garage car fight (v0.57): the game that runs the car runs Jack, the whole fight.
                if coop_car.runner == k then
                    if own ~= k then mv.own[id], mv.own_t[id] = k, now end
                    take = true
                end
            elseif host_mode() and mv.role == "guest" then
                -- Host runs every enemy (v0.57): the host's copy is the one, always.
                if own ~= k then mv.own[id], mv.own_t[id] = k, now end
                take = true
            elseif host_mode() then
                -- We're the host: ours runs, whatever an older copy of the mod sends. Except a Molded our game hasn't got
                -- awake (v0.57): the guest's game runs that one after HQ_WAIT s, and ours shows it (a stand-in if need be).
                local mine_awake = te ~= nil and safe(te.go.call, te.go, "get_Update") == true and own ~= k
                if id:sub(1, 2) == "s:" and not mine_awake then
                    if own ~= k then mv.own[id], mv.own_t[id] = k, now log("the guest's game runs " .. id:sub(1, 12) .. " (ours hasn't got it)") end
                    take = true
                else
                    take = false
                end
            elseif te and BOSS_HANDOFF[te.name] then
                -- One boss for both (v0.48): ours until handed to us; when both games run him, the host's.
                if own == k then
                    take = true
                elseif awake_near_me(te) then
                    hold_note(te)   -- ours has hold of our player (v0.51): ours until it lets go
                -- Or ours is asleep while theirs is awake (v0.48): at Chapter 1's step 1300 Mia moved to the
                -- attic in one game while the host's slept where she'd been, and the host kept "running" her.
                elseif own == nil or (own == "me" and mv.role == "guest" and now - (mv.own_t[id] or 0) >= 1)
                    or (own == "me" and safe(te.go.call, te.go, "get_Update") ~= true) then
                    if own == "me" then log(string.format("%s: both games ran it, the host's is the one now", te.name)) end
                    mv.own[id], mv.own_t[id], take = k, now, true
                end
            elseif te and BOSS_FOLLOW[te.name] and mv.role == "guest" then
                -- A copied boss (v0.48): the host runs it, always. The rule below (theirs only if their
                -- SteamID is lower, or ours isn't awake) left the guest running its own Jack, awake in
                -- its own fight, so "One Jack for both" did nothing (bot test 2026-11-11).
                if own ~= k then mv.own[id], mv.own_t[id] = k, now end
                take = true
            elseif own == k then
                take = true
            elseif own == nil then
                -- Nobody's yet: theirs, unless we're the lower SteamID and run it awake here.
                local here = te and safe(te.go.call, te.go, "get_Update") == true
                if lower_than_me(k) or not here then mv.own[id], mv.own_t[id], take = k, now, true end
            elseif own == "me" then
                -- Just handed to us: a snapshot they sent a moment before still has it.
                if now - (mv.own_t[id] or 0) >= 1 and lower_than_me(k) and not awake_near_me(te) then
                    mv.own[id], mv.own_t[id], take = k, now, true
                end
            elseif type(own) == "number" and now - (mv.own_t[id] or 0) >= 1 then
                -- Owned by another friend, but friend k sends it too: the lower SteamID keeps it.
                local _, ids = party_ids()
                if id_less(ids[k], ids[own]) then mv.own[id], mv.own_t[id], take = k, now, true end
            end
            if take then push_hist(id, s, t + o) end
        end
    end
    mv.recv = mv.recv + 1
end

local function order_of(e)
    if e.order == nil then
        local comps = safe(e.go.call, e.go, "get_Components")
        for _, c in ipairs(arr_items(comps)) do
            if c:get_type_definition():is_a("app.EnemyOrder") then e.order = c break end
        end
    end
    return e.order
end

local function set_brain(e, on)
    if on then pcall(restore_weapons, e) end   -- its own AI decides what to hold again
    local fsm = safe(e.go.call, e.go, "getComponent(System.Type)", sdk.typeof("via.motion.MotionFsm"))
    if fsm then safe(fsm.call, fsm, "set_Enabled", on) end
    local order = order_of(e)
    if order then
        if mv.owner == nil then
            mv.owner = sdk.create_managed_string("coop-re7")
            if mv.owner and mv.owner.add_ref then mv.owner:add_ref() end
        end
        safe(order.call, order, on and "requestThinkOn" or "requestThinkOff", mv.owner)
    end
end

-- A copy is visible (v0.23). Molded wait hidden in walls and floors and their own AI shows
-- them as they climb out; with the AI off here a copy that was handed over before it came out
-- stayed invisible while it played the owner's attacks, so both players got hit by "invisible
-- monsters" (2026-11-03). The copy's body mesh is switched on, and checked again every second.
local function force_visible(e)
    local go = e.go
    if not safe(go.call, go, "get_DrawSelf") then safe(go.call, go, "set_DrawSelf", true) end
    local m = e.mesh or safe(go.call, go, "getComponent(System.Type)", sdk.typeof("via.render.Mesh"))
    e.mesh = m
    local was_on = m and safe(m.call, m, "get_Enabled")
    local was_draw = m and safe(m.call, m, "get_DrawDefault")
    if m and was_on == false then safe(m.call, m, "set_Enabled", true) end
    if m and was_draw == false then safe(m.call, m, "set_DrawDefault", true) end
    if not e.vis_logged or was_on == false or was_draw == false then
        e.vis_logged = true
        log(string.format("copy %s visible: mesh %s, enabled %s, draw %s", e.name, tostring(m ~= nil),
            tostring(was_on), tostring(was_draw)))
    end
end

-- A Molded copy out of its pool (v0.48). Every Molded body is a child of its generator's MoldedPool;
-- while it is, a position set from outside moves only its local transform and its world position stops
-- updating for good (the body froze where it stood: bot test 2026-11-12). With no parent, warp moves it
-- like Jack. The pool is at the origin, so taking it out or putting it back doesn't move it. It goes
-- back when it sleeps or its spawn point gives it up (repool), so the pool can hand it out again.
local function unpool(e)
    if e.pool or not is_regular(e.name) then return end
    local tr = safe(e.go.call, e.go, "get_Transform")
    local par = tr and safe(tr.call, tr, "get_Parent")
    local pgo = par and safe(par.call, par, "get_GameObject")
    local pn = pgo and tostring(safe(pgo.call, pgo, "get_Name") or "") or ""
    if not pn:find("Pool", 1, true) then return end
    if pcall(tr.call, tr, "set_Parent", nil) then
        e.pool = par
        log(string.format("%s %s out of %s, so it can follow", e.name, e.id, pn))
    end
end
local function repool(e)
    local par = e.pool
    if not par then return end
    e.pool = nil
    local tr = safe(e.go.call, e.go, "get_Transform")
    if tr and safe(tr.call, tr, "get_Parent") == nil then pcall(tr.call, tr, "set_Parent", par) end
end
function coop_enemy_repool(e) if not mv.puppets[e.id] then repool(e) end end
-- The game puts a Molded body to sleep on its own (UpdateSelf off; seen on a copy whose player was 9 m away,
-- bot test 2026-11-12): a copy asleep stays drawn but frozen, and one handed to us asleep never fights.
local function wake(e)
    if safe(e.go.call, e.go, "get_UpdateSelf") == false then
        safe(e.go.call, e.go, "set_UpdateSelf", true)
        safe(e.go.call, e.go, "set_DrawSelf", true)
        e.woke = true
        return true
    end
    return false
end

local function puppetize(e)
    pcall(unpool, e)
    if not safe(e.go.call, e.go, "get_Update") then
        -- Awake in the host's game: wake ours too.
        safe(e.go.call, e.go, "set_UpdateSelf", true)
        safe(e.go.call, e.go, "set_DrawSelf", true)
        e.woke = true
    end
    pcall(force_visible, e)
    e.vis_t = os.clock()
    set_brain(e, false)
    mv.puppets[e.id] = e
    log("puppet on: " .. e.name .. " " .. e.id)
end

local function release(id)
    local e = mv.puppets[id]
    mv.puppets[id] = nil
    mv.hist[id] = nil
    if e then
        safe(set_brain, e, true)
        e.cur_bank, e.cur_mid = nil, nil
        log("puppet off: " .. e.name .. " " .. id)
    end
end

-- A pooled Molded body that isn't the Molded it was a copy of any more (scan, v0.47): its AI back.
-- sleep: no spawn point has it now, so one we woke for that copy goes back to sleep (the game
-- wakes its own bodies itself).
function coop_enemy_orphan(e, sleep)
    if mv.puppets[e.id] == e then
        mv.puppets[e.id] = nil
        safe(set_brain, e, true)
        e.cur_bank, e.cur_mid = nil, nil
    end
    if e.woke and sleep then
        safe(e.go.call, e.go, "set_UpdateSelf", false)
        safe(e.go.call, e.go, "set_DrawSelf", false)
    end
    if sleep then pcall(repool, e) end
    e.woke = nil
end

-- For a save: AI back on, but keep the timeline and ownership so following resumes.
function release_for_save(id)
    local e = mv.puppets[id]
    mv.puppets[id] = nil
    if e then
        safe(set_brain, e, true)
        e.cur_bank, e.cur_mid = nil, nil
    end
end

local function lerp_angle(a, b, k)
    local d = (b - a + math.pi) % (2 * math.pi) - math.pi
    return a + d * k
end

-- Animation banks a copy lacks (v0.51). A copy plays the owner's clip by bank and number, but its brain is
-- off, so the banks the game loads for a fight move never load on it: Mia T-posed on the friend's screen
-- in every grab and when Ethan blocked her chainsaw (2026-11-12 playtest). A clip the copy doesn't have
-- isn't played (it keeps its last move rather than T-posing); the copy asks the owner's game for that bank
-- ("ebankreq"), which answers with the bank's motion list ("ebank"), and the copy adds it, as the friend's
-- character does with a player's added banks (coop_dummy's add_ghost_banks).
local eb = { info = nil, res = {}, asked = {}, added = {} }
local function motion_of(e)
    if e.mot == nil then e.mot = safe(e.go.call, e.go, "getComponent(System.Type)", sdk.typeof("via.motion.Motion")) or false end
    return e.mot or nil
end
local function copy_has_clip(e, bank, mid)
    local m = motion_of(e)
    if m == nil then return true end
    if eb.info == nil then
        eb.info = safe(sdk.create_instance, "via.motion.MotionInfo") or false
        if eb.info then safe(eb.info.add_ref, eb.info) end
    end
    if not eb.info then return true end
    local ok, r = pcall(m.call, m, "getMotionInfo(System.UInt32, System.UInt32, via.motion.MotionInfo)", bank, mid, eb.info)
    if not ok then return true end   -- can't tell: play it, as before
    return r == true
end
local function ask_bank(e, bank, now)
    local key = e.id .. "#" .. bank
    local a = eb.asked[key]
    if a == nil then a = { n = 0, t = -100 } eb.asked[key] = a end
    if a.n >= 4 or now - a.t < 2 then return end
    a.n, a.t = a.n + 1, now
    send_event(string.format("ebankreq %s %d %d", e.id, chapter(), bank))
    if a.n == 1 then log(string.format("%s copy: the owner's clip is in bank %d, which isn't here: asked for it", e.name, bank)) end
end
-- Owner: the motion list of one of our enemy's banks (loaded or added), for a friend's copy.
local function bank_path(e, bank)
    local m = motion_of(e)
    if m == nil then return nil end
    local nd = tonumber(safe(m.call, m, "getDynamicMotionBankCount") or 0) or 0
    for i = 0, math.min(nd, 32) - 1 do
        local db = safe(m.call, m, "getDynamicMotionBank", i)
        local hd = db and safe(db.call, db, "get_MotionList")
        local p = hd and safe(hd.call, hd, "get_ResourcePath")
        if p and tonumber(safe(db.call, db, "get_BankID")) == bank then
            return tostring(p), safe(db.call, db, "get_OverwriteBankID") and 1 or 0
        end
    end
    local na = tonumber(safe(m.call, m, "getActiveMotionBankCount") or 0) or 0
    for i = 0, math.min(na, 64) - 1 do
        local ab = safe(m.call, m, "getActiveMotionBank", i)
        local hd = ab and safe(ab.call, ab, "get_MotionList")
        local p = hd and safe(hd.call, hd, "get_ResourcePath")
        if p and tonumber(safe(ab.call, ab, "get_BankID")) == bank then return tostring(p), 1 end
    end
    return nil
end
function coop_enemy_bank_req(id, ch, bank)
    if ch ~= chapter() then return end
    local e = find_tracked(id)
    if e == nil then return end
    local p, ow = bank_path(e, bank)
    if p and p:match("^%S+$") then
        send_event(string.format("ebank %s %d %d %d %s", id, ch, bank, ow, p))
        log(string.format("%s: friend's copy asked for bank %d: sent %s", e.name, bank, p))
    else
        log(string.format("%s: friend's copy asked for bank %d: not found here", e.name, bank))
    end
end
function coop_enemy_bank(id, ch, bank, ow, path)
    if ch ~= chapter() then return end
    local e = find_tracked(id)
    local m = e and motion_of(e)
    if m == nil then return end
    local key = id .. "#" .. bank .. "#" .. path
    if eb.added[key] == m:get_address() then return end
    local ok, err = pcall(function()
        local hd = eb.res[path]
        if hd == nil then
            local r = sdk.create_resource("via.motion.MotionListResource", path)
            r:add_ref()
            hd = r:create_holder("via.motion.MotionListResourceHolder")
            hd:add_ref()
            eb.res[path] = hd
        end
        local db = sdk.create_instance("via.motion.DynamicMotionBank")
        db:add_ref()
        db:call(".ctor")
        db:call("set_MotionList", hd)
        db:call("set_OverwriteBankID", ow == 1)
        db:call("set_BankID", bank)
        local n = tonumber(m:call("getDynamicMotionBankCount") or 0) or 0
        m:call("setDynamicMotionBankCount", n + 1)
        m:call("setDynamicMotionBank", n, db)
        m:call("setupMotionBank")
    end)
    eb.added[key] = ok and m:get_address() or nil
    e.cur_bank, e.cur_mid = nil, nil   -- play the owner's clip again, now that it can
    log(string.format("%s copy: bank %d (%s) %s", e.name, bank, path, ok and "added" or ("ERR " .. tostring(err))))
end

local function drive(e, h, now)
    if now - (e.vis_t or 0) > 1 then e.vis_t = now pcall(force_visible, e) pcall(unpool, e) end
    -- Woken only while its spawn point still has this body (v0.49): once the game has given the spawn point
    -- a new one, waking the old one left two bodies with one id, and the copy jumped between them.
    local _, body = spawn_ids(now)
    local current = body == nil or body[e.id] == nil or body[e.id] == e.go:get_address()
    if is_regular(e.name) and current and wake(e) and not e.wake_logged then
        e.wake_logged = true
        log(string.format("%s %s: the game put the copy to sleep, woken again", e.name, e.id))
    end
    local t = now - move_delay()
    local a, b = h[1], h[#h]
    for i = #h - 1, 1, -1 do
        if h[i].t <= t then a, b = h[i], h[i + 1] break end
    end
    local k = (b.t > a.t) and math.max(0, math.min(1, (t - a.t) / (b.t - a.t))) or 1
    local x, y, z = a.x + (b.x - a.x) * k, a.y + (b.y - a.y) * k, a.z + (b.z - a.z) * k
    local yaw = lerp_angle(a.yaw, b.yaw, k)
    local mc = e.mc or safe(e.go.call, e.go, "getComponent(System.Type)", sdk.typeof("app.MovementController"))
    e.mc = mc
    local q = Quaternion.new(math.cos(yaw / 2), 0, math.sin(yaw / 2), 0)
    if mc then safe(mc.call, mc, "warp(via.vec3, via.Quaternion)", Vector3f.new(x, y, z), q) end
    -- Animation: the clip at the newer sample; correct the frame if it drifts.
    local s = (k > 0.5) and b or a
    local L = layer0(e)
    if L == nil then return end
    -- Something else put another clip on the copy (v0.57): the game's own handling of an enemy whose AI is off set
    -- its idle (10/1000) back after we'd played the owner's 10/8000, and since the owner's clip didn't change, the
    -- copy stood in the wrong pose for good (bot test 2026-11-20). Played again whenever the body isn't on ours.
    if e.cur_bank ~= nil and now - (e.clip_fix_t or -100) >= 0.5
        and (L:call("get_MotionBankID") ~= e.cur_bank or L:call("get_MotionID") ~= e.cur_mid) then
        e.clip_fix_t = now   -- at most twice a second, so a body something keeps resetting doesn't blend every frame
        if not e.clip_reset_logged then
            e.clip_reset_logged = true
            log(string.format("%s copy: its clip was changed under it (%s/%s instead of %s/%s): played again", e.name,
                tostring(L:call("get_MotionBankID")), tostring(L:call("get_MotionID")), tostring(e.cur_bank), tostring(e.cur_mid)))
        end
        e.cur_bank, e.cur_mid = nil, nil
    end
    if e.cur_bank ~= s.bank or e.cur_mid ~= s.mid then
        -- Not a clip this copy has (v0.51): keep the last move, ask for the bank (checked twice a second).
        local ms = e.missing
        if ms and ms.bank == s.bank and ms.mid == s.mid and now - ms.t < 0.5 then return end
        if not copy_has_clip(e, s.bank, s.mid) then
            e.missing = { bank = s.bank, mid = s.mid, t = now }
            ask_bank(e, s.bank, now)
            return
        end
        e.missing = nil
        local m = e.change_motion
        if m == nil then
            for _, mm in ipairs(L:get_type_definition():get_methods()) do
                if mm:get_name() == "changeMotion" and mm:get_num_params() == 6 then m = mm end
            end
            e.change_motion = m
        end
        if m then safe(m.call, m, L, s.bank, s.mid, s.frame, 8.0, 2, 0) end
        e.cur_bank, e.cur_mid = s.bank, s.mid
    else
        local target = a.frame + ((b.mid == a.mid and b.bank == a.bank) and (b.frame - a.frame) * k or 0)
        local f = L:call("get_Frame") or 0
        if math.abs(f - target) > 4 then safe(L.call, L, "set_Frame", target) end
    end
    safe(L.call, L, "set_Speed", s.speed)
    -- Same weapon in hand as in the friend's game (applied only when it changes).
    if s.weapon then pcall(show_weapon, e, s.weapon) end
end

-- Saves: an enemy's save data holds its ThinkState and IsUpdate, so a follower saved with
-- its AI off (requestThinkOff) could load frozen. When the game prepares an enemy for
-- saving, give every follower its own AI back and pause following for a few seconds;
-- they're taken over again afterwards.
local prep = sdk.find_type_definition("app.EnemySave"):get_method("prepareToSave")
if prep then
    dbg_note{ feature = "Enemy movement", name = "Give followed enemies their own AI back before a save",
        when = "when the game calls EnemySave.prepareToSave (a save is being prepared)",
        reads = "the followed-enemy table",
        writes = "returns every followed (puppet) enemy to its own AI and pauses following for 4 s" }
    sdk.hook(prep, function(args)
        pcall(function()
            local now = os.clock()
            if mv.save_pause_until and now < mv.save_pause_until then return end
            mv.save_pause_until = now + 4
            local n = 0
            for id in pairs(mv.puppets) do release_for_save(id) n = n + 1 end
            if n > 0 then log("saving: gave " .. n .. " followed enemies their AI back") end
        end)
    end, function(r) return r end)
end

-- The friend's position, from their Ethan (only while shown, i.e. data is fresh).
local function friend_pos(k)
    local env = coop_slot_envs and coop_slot_envs[k or 1] or _G
    local ghost_fn = rawget(env, "coop_ghost") or (k == 1 and coop_ghost) or nil
    local g = ghost_fn and ghost_fn()
    local hidden = rawget(env, "ghost_hidden")
    if hidden == nil and (k or 1) == 1 then hidden = ghost_hidden end
    if g == nil or hidden then return nil end
    return safe(function() return g:call("get_Transform"):call("get_Position") end)
end

-- A boss's turn with each game (v0.56, see check_handoffs).
local BOSS_TURN_S, BOSS_TURN_R = 20, 12
mv.mine_own = mv.mine_own or {}
local function hand_off(e, now, k)
    k = k or 1
    local _, ids = party_ids()
    send_event(string.format("own %s %d %s%s", e.id, chapter(), e.name, ids[k] and (" " .. ids[k]) or ""))
    mv.own[e.id], mv.own_t[e.id], mv.handed[e.id] = k, now, true
    mv.hist[e.id] = nil
    puppetize(e)
    mv.handoffs = mv.handoffs + 1
    mv.msg = "handed " .. e.name .. " to " .. (k == 1 and "your friend" or ("friend " .. k))
    log(mv.msg)
end

local function dist2(a, b) return (a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2 end

function check_handoffs(now)
    -- Only to a real friend: the bot can't run enemies (in bot mode only the test button
    -- hands one over). Require "steam" rather than "not bot": a status file read while
    -- it was being rewritten has no mode line, and that once handed Jack to the bot.
    if not (coop_link_friend and coop_link_friend(net_kv())) then return end
    if host_mode() then return end   -- v0.57: the host runs every enemy, nothing changes games
    -- See watch_pause. A "paused" that never got its "back" (they quit) expires after 10 min.
    if mv.friend_paused and now - (mv.friend_paused_t or 0) > 600 then mv.friend_paused = false end
    if mv.paused then return end
    -- Friends here and not paused (a "paused" that never got its "back" expires after 10 min).
    -- Not during or just after a scene of ours, and never to a friend in one (v0.48): the morgue fight's
    -- opening scene ran 38 s later in one game, Jack was handed to it before it had played it (his health
    -- still 8000 there), its scene then took him back, and for half a minute each game ran its own Jack.
    if scripted_now() then return end
    local friends = {}
    for k = 1, 3 do
        local pt = mv.paused_slots and mv.paused_slots[k]
        if pt and now - pt > 600 then mv.paused_slots[k] = nil pt = nil end
        if friend_in_cutscene(k) then pt = true end
        -- Nobody hands an enemy to a friend who's down (v0.48): it would stand over them.
        if revive and revive.down_slots and revive.down_slots[k] then pt = true end
        local g = not pt and friend_pos(k)
        if g then friends[#friends + 1] = { k = k, pos = g } end
    end
    local player = sdk.get_managed_singleton("app.ObjectManager"):get_field("PlayerObj")
    if #friends == 0 or player == nil then return end
    local p = player:call("get_Transform"):call("get_Position")
    for _, e in pairs(es.tracked) do
        local cooling = mv.no_handoff and (mv.no_handoff[e.id] or 0) > now and not coop_friend_has(e.id)
        if moves_shared(e.name) and not e.dup and settled(e, now) and not (BOSS_FOLLOW[e.name] and not BOSS_HANDOFF[e.name]) and not car_pinned(e.name) and not seq_hold(e.name) and not friend_owned(e.id) and not cooling and not e.dead and not mv.puppets[e.id] and safe(e.go.call, e.go, "get_Update") == true then
            local ep = e.go:call("get_Transform"):call("get_Position")
            local best, bd = nil, nil
            for _, f in ipairs(friends) do
                local d = math.sqrt(dist2(ep, f.pos))
                if bd == nil or d < bd then best, bd = f.k, d end
            end
            -- 3 m of hysteresis so it doesn't bounce between games. "Enemies chase both players"
            -- (Options, v0.47): up close it also goes once the friend is clearly nearer (a third
            -- nearer and 1 m+), so it turns on whoever is next to it. An enemy can only attack its
            -- own game's player: one aimed at the friend's character walked up to it and stood
            -- there (bot test 2026-11-10), so the nearer player's game has to run it.
            local dm = math.sqrt(dist2(ep, p))
            -- One Molded for both (v0.48): it goes to whoever is clearly nearer, like a boss, so it turns
            -- on the player next to it in the game that runs it, with its own AI, and can hurt them.
            local eager = (settings ~= nil and settings.enemy_chase_both ~= false) or BOSS_HANDOFF[e.name] == true or is_regular(e.name)
            -- Our player is down (v0.48): the boss goes to a friend who's still standing, within 30 m, the way
            -- he'd turn on the one left in the single-player fight (he stood idle over the downed player).
            local we_down = revive ~= nil and revive.downed == true
            -- Not while it's right on top of us (v0.51, see HOLD_R): a grab would drag our Ethan with the copy.
            if dm < HOLD_R and not we_down then best = nil end
            -- A boss stays at least 5 s with the game that got it (v0.51): with both players close, the bot test
            -- had Mia change games every 3 s, each change a jolt on both screens.
            if (BOSS_FOLLOW[e.name] or BOSS_HANDOFF[e.name]) and not we_down and now - (mv.own_t[e.id] or -100) < 5 then best = nil end
            -- Taking turns (v0.56): "the Mia fights didn't have her attacking my friend" (2026-11-14 session). A boss
            -- only changed games when the friend was clearly nearer and she wasn't on top of whoever had her; in a
            -- fight she's on one player nearly all the time, so she went after that one for the whole fight. Now a
            -- boss our game has run for BOSS_TURN_S goes to a friend within BOSS_TURN_R (and not while she's within
            -- HOLD_R of us, a grab); their game hands her back the same way, so she goes after each of you in turn.
            mv.mine_since = mv.mine_since or {}
            if mv.mine_since[e.id] == nil or mv.own[e.id] ~= mv.mine_own[e.id] then
                mv.mine_since[e.id] = (mv.own[e.id] == "me" and mv.own_t[e.id]) or now
                mv.mine_own[e.id] = mv.own[e.id]
            end
            local turn = BOSS_HANDOFF[e.name] == true and not we_down and best ~= nil and bd < BOSS_TURN_R
                and now - mv.mine_since[e.id] >= BOSS_TURN_S
            if best and ((we_down and bd < 30) or turn or bd + 3 < dm or (eager and bd < dm * 0.7 and dm - bd > 1)) then
                if turn and not (bd + 3 < dm) then log(string.format("%s: your friend's turn (we had it %.0f s)", e.name, now - mv.mine_since[e.id])) end
                mv.mine_since[e.id] = nil
                hand_off(e, now, best)
            end
        end
    end
end

-- One Molded for both of you (v0.48). A copy of a Molded can't be moved (its world position isn't
-- taken from its transform: set_Position, warp, the CharacterController/RigidBodyCharacter warps and
-- the root joint were all ignored, bot tests 2026-11-11), so each game still runs its own. What's
-- shared now is who it goes after: in every game a Molded that's fighting goes for whichever of you
-- is nearest, the friend's character included (EnemyThinkBase.setTarget; it walked up to the
-- friend's character in the bot test), so on both screens it chases the same person. Only the game of
-- the player it's after can land a hit (one aimed at a friend's character stands over it), and that
-- game is the one where it's after them for real. "Fighting" is its own AI having a target, or the
-- friend's game saying theirs has one ("mtgt", every 1.5 s).
local AIM_HYST, AIM_RANGE = 2.0, 25.0
local REASON_SPECIFIED = 4
es.friend_fight = es.friend_fight or {}   -- id -> { t, k }: the friend's game has it fighting
local function friend_ghost(k)
    local env = coop_slot_envs and coop_slot_envs[k or 1] or _G
    local ghost_fn = rawget(env, "coop_ghost") or (k == 1 and coop_ghost) or nil
    return ghost_fn and ghost_fn() or nil
end
local function think_of(e)
    -- Not found: looked for again after 2 s (v0.49; it was "none" for good after one bad read).
    if e.think == false and os.clock() - (e.think_t or 0) > 2 then e.think = nil end
    if e.think == nil then
        e.think_t = os.clock()
        for _, c in ipairs(arr_items(safe(e.go.call, e.go, "get_Components"))) do
            if c:get_type_definition():is_a("app.EnemyThinkBase") then e.think = c break end
        end
        e.think = e.think or false
    end
    return e.think or nil
end
local function set_target(th, go)
    return pcall(th.call, th, "setTarget(via.GameObject, app.EnemyThinkBase.ReasonType)", go, REASON_SPECIFIED)
end
-- One that's already fighting picks its target again every frame (it went straight back to our
-- player in the bot test), so while it's after a friend its own choice is skipped: setTarget to
-- anyone else and updateTarget. es.aim_hold: think address -> the friend character's address.
es.aim_hold = es.aim_hold or {}
do
    local function held(args)
        if next(es.aim_hold) == nil then return nil end
        local th = sdk.to_managed_object(args[2])
        return th and es.aim_hold[th:get_address()] or nil
    end
    local st_m = sdk.find_type_definition("app.EnemyThinkBase"):get_method("setTarget")
    if st_m then
        dbg_note{ feature = "One Molded for both", name = "Block the Molded's own target change",
            when = "when the game calls EnemyThinkBase.setTarget (the AI picks who to chase; can be many times a second)",
            reads = "the aim-hold table (empty unless an enemy is held on a friend): which player the AI wants",
            writes = "SKIPS the game's setTarget when the enemy is held on the friend it was given" }
        sdk.hook(st_m, function(args)
            local ok, skip = pcall(function()
                local want = held(args)
                if want == nil then return false end
                local go = sdk.to_managed_object(args[3])
                return go == nil or go:get_address() ~= want
            end)
            if ok and skip then return sdk.PreHookResult.SKIP_ORIGINAL end
        end, function(r) return r end)
    end
    local hooked = {}
    for _, tn in ipairs({ "app.EnemyThinkBase", "app.Em4000Think" }) do
        local td = sdk.find_type_definition(tn)
        local m = td and td:get_method("updateTarget")
        if m and not hooked[m] then
            hooked[m] = true
            dbg_note{ feature = "One Molded for both", name = "Block the Molded's own target search",
                when = "when the game calls updateTarget on the enemy AI (every AI tick of every enemy)",
                reads = "the aim-hold table (empty unless an enemy is held on a friend)",
                writes = "SKIPS the game's updateTarget for the enemy that is held on a friend" }
            sdk.hook(m, function(args)
                local ok, want = pcall(held, args)
                if ok and want then return sdk.PreHookResult.SKIP_ORIGINAL end
            end, function(r) return r end)
        end
    end
end
-- Our player is down (v0.56). check_handoffs gives every shared enemy within 30 m to a friend who's standing,
-- but when the friend's game can't take it (it isn't in their game, or the hand-off is cooling down) ours
-- kept it, and its AI stays on its own game's player: "Jack stayed focused on the downed player and wouldn't
-- go after the one still up" (2026-11-14 session). Then ours is aimed at the standing friend's character
-- (the same setTarget + target hold as the Molded aim below): it can't hurt them from here, but on their
-- screen it comes after them instead of standing over us. Let go as soon as we're up.
local function down_aim(now)
    if host_mode() then return end   -- v0.57: host_fight does this (and the two fought over the target)
    local we_down = revive ~= nil and revive.downed == true
    if not we_down then
        if es.down_aimed then
            for addr in pairs(es.down_aimed) do es.aim_hold[addr] = nil end
            es.down_aimed = nil
            log("back up: enemies go for you again")
        end
        return
    end
    if now - (es.down_aim_t or 0) < 0.5 then return end
    es.down_aim_t = now
    local fg, fp
    for k = 1, 3 do
        local skip = friend_in_cutscene(k) or (revive.down_slots and revive.down_slots[k]) or (mv.paused_slots and mv.paused_slots[k])
        local pos = not skip and friend_pos(k)
        local g = pos and friend_ghost(k)
        if g then fg, fp = g, pos break end
    end
    if fg == nil then return end
    for _, e in pairs(es.tracked) do
        if not e.dead and not e.dup and not mv.puppets[e.id] and not friend_owned(e.id) and safe(e.go.call, e.go, "get_Update") == true then
            local ep = safe(function() return e.go:call("get_Transform"):call("get_Position") end)
            local th = ep and math.sqrt(dist2(ep, fp)) < 30 and think_of(e)
            local tgt = th and safe(th.call, th, "get_Target")
            if tgt ~= nil and tgt ~= fg then
                set_target(th, fg)
                es.down_aimed = es.down_aimed or {}
                if not es.down_aimed[th:get_address()] then log(e.name .. " goes after your friend while you're down") end
                es.down_aimed[th:get_address()] = true
                es.aim_hold[th:get_address()] = fg:get_address()
            end
        end
    end
end
function aim_regulars(now)
    pcall(down_aim, now)
    local on = settings == nil or settings.share_molded_target ~= false
    local om = sdk.get_managed_singleton("app.ObjectManager")
    local player = om and om:get_field("PlayerObj")
    -- Keep each one on the friend it was given: its own AI turns back to our player now and then.
    for _, e in pairs(es.tracked) do
        if e.aim and e.aim_go and now - (e.aim_t or 0) < 0.6 then
            local th = think_of(e)
            if th and safe(th.call, th, "get_Target") ~= e.aim_go then set_target(th, e.aim_go) end
        end
    end
    if now - (es.aim_t or 0) < 0.3 then return end
    es.aim_t = now
    local live = {}
    for _, e in pairs(es.tracked) do if e.think then live[e.think:get_address()] = true end end
    for a in pairs(es.aim_hold) do if not live[a] then es.aim_hold[a] = nil end end
    local linked = coop_link_friend and coop_link_friend(net_kv())
    local friends = {}
    if on and linked and player and not scripted_now() then
        for k = 1, 3 do
            local skip = friend_in_cutscene(k) or (revive and revive.down_slots and revive.down_slots[k])
                or (mv.paused_slots and mv.paused_slots[k])
            local fp = not skip and friend_pos(k)
            local g = fp and friend_ghost(k)
            if g then friends[k] = { pos = fp, go = g } end
        end
    end
    local p = player and safe(function() return player:call("get_Transform"):call("get_Position") end)
    local fighting = {}
    for _, e in pairs(es.tracked) do
        if is_regular(e.name) and not e.dup and e.id:sub(1, 2) ~= "p:" then
            local th = think_of(e)
            local awake = safe(e.go.call, e.go, "get_Update") == true
            local tgt = th and awake and safe(th.call, th, "get_Target")
            if tgt and player and tgt == player and not e.dead then fighting[#fighting + 1] = e.id end
            local ff = es.friend_fight[e.id]
            local engaged = tgt ~= nil or (ff ~= nil and now - ff.t < 3.5)
            local want = nil
            -- With "One Molded for both" the nearer player's game runs it (check_handoffs): no aiming.
            if th and awake and e.out and not e.dead and engaged and p and next(friends) and not moves_shared(e.name) then
                local ep = safe(function() return e.go:call("get_Transform"):call("get_Position") end)
                if ep then
                    local dm = math.sqrt(dist2(ep, p))
                    local bk, bd
                    for k, f in pairs(friends) do
                        local d = math.sqrt(dist2(ep, f.pos))
                        if d <= AIM_RANGE and (bd == nil or d < bd) then bk, bd = k, d end
                    end
                    local cur = e.aim and friends[e.aim] and e.aim or nil
                    local dc = cur and math.sqrt(dist2(ep, friends[cur].pos))
                    if cur and dc <= AIM_RANGE and dc < dm + AIM_HYST then
                        want = (bk and bk ~= cur and bd + AIM_HYST < dc) and bk or cur
                    elseif bk and bd + AIM_HYST < dm then
                        want = bk
                    end
                end
            end
            if want ~= e.aim then
                if want then
                    log(string.format("%s %s goes after %s (nearer)", e.name, e.id:sub(1, 12), want == 1 and "your friend" or ("friend " .. want)))
                elseif e.aim then
                    log(string.format("%s %s back on you", e.name, e.id:sub(1, 12)))
                    if th then es.aim_hold[th:get_address()] = nil end
                    if th and awake and not e.dead and player and tgt ~= nil and tgt ~= player then set_target(th, player) end
                end
                e.aim = want
            end
            if want then
                e.aim_go, e.aim_t = friends[want].go, now
                es.aim_hold[th:get_address()] = e.aim_go:get_address()
                if tgt ~= e.aim_go then set_target(th, e.aim_go) end
            else
                if th then es.aim_hold[th:get_address()] = nil end
                e.aim_go = nil
            end
        end
    end
    -- Tell the friend which are after us (and once more when none are).
    if linked and now - (es.fight_sent_t or 0) >= 1.5 and (#fighting > 0 or es.fight_sent_n ~= 0) then
        es.fight_sent_t, es.fight_sent_n = now, #fighting
        local ids = {}
        for i = 1, math.min(#fighting, 8) do ids[i] = fighting[i] end
        send_event(string.format("mtgt %d%s", chapter(), #ids > 0 and (" " .. table.concat(ids, " ")) or ""))
    end
end
function coop_enemies_on_fight(ch, list)
    if ch ~= chapter() then return end
    local now = os.clock()
    for id in list:gmatch("%S+") do es.friend_fight[id] = { t = now, k = coop_event_slot or 1 } end
end

-- Handed an enemy our game can't run (v0.51). In the 2026-11-12 playtest Mia went to the friend's game
-- twice and came back 3 s later each time for want of data, and nothing said why. Now the game that got it
-- says why it isn't sending it ("eskip"), the other takes it back at once and logs the reason.
local function why_not_sent(e)
    if e.dead then return "it's dead here" end
    if not moves_shared(e.name) then
        return (local_cutscene and local_cutscene()) and "a cutscene is playing here" or "sharing is off here"
    end
    if e.dup then return "it's a second body here" end
    if seq_hold(e.name) then return "a story sequence is playing out here" end
    if safe(e.go.call, e.go, "get_Update") ~= true then return "it isn't awake here" end
    return nil
end
function coop_enemy_check_skips(now)
    if mv.got_t == nil or now - (mv.skip_t or 0) < 1 then return end
    mv.skip_t = now
    for id, t in pairs(mv.got_t) do
        if now - t > 60 or mv.own[id] ~= "me" then
            mv.got_t[id] = nil
        elseif now - t > 0.5 and not mv.puppets[id] then
            local e = find_tracked(id)
            local why = e and why_not_sent(e)
            if why then
                mv.got_t[id] = nil
                send_event(string.format("eskip %s %d %s %s", id, chapter(), e.name, why))
                log(string.format("handed %s %s, but this game can't run it (%s): told your friend", e.name, id:sub(1, 12), why))
            end
        end
    end
end
function coop_enemy_skip(id, ch, name, why)
    if ch ~= chapter() or not friend_owned(id) then return end
    mv.skip_why = mv.skip_why or {}
    mv.skip_why[id] = why
    log(string.format("your friend's game can't run %s %s: %s", name, id:sub(1, 12), why))
end

-- The friend handed us an enemy: run it ourselves from now on.
function enemy_move_on_own(id, ch, name, target)
    if ch ~= chapter() then return end
    local me = party_ids()
    if target == nil or target == me then
        mv.own[id], mv.own_t[id], mv.handed[id] = "me", os.clock(), nil
        if mv.puppets[id] then release(id) end
        mv.hist[id] = nil
        note("your friend handed " .. name .. " to you")
        mv.got_t = mv.got_t or {}
        mv.got_t[id] = os.clock()
        if find_tracked(id) == nil then
            -- Not in our game (v0.51): say so, so theirs takes it back now instead of freezing it for seconds.
            send_event(string.format("eskip %s %d %s %s", id, chapter(), name, "it isn't in this game"))
            log(string.format("handed %s %s, but it isn't in this game: told your friend", name, id:sub(1, 12)))
        end
        -- One Molded for both (v0.48): it was handed to us because we're nearer (or the friend is down), so
        -- it comes for us. Left to itself it hadn't noticed us yet and sank back into the floor (bot test
        -- 2026-11-12), and the two games passed it back and forth.
        if is_regular(name) then
            pcall(function()
                local e = find_tracked(id)
                local player = sdk.get_managed_singleton("app.ObjectManager"):get_field("PlayerObj")
                local th = e and not e.dead and player and think_of(e)
                -- Asleep here (the game sleeps a copy far from its player): woken, so it can come for us.
                if th and e.woke then wake(e) end
                if th and safe(e.go.call, e.go, "get_Update") == true then
                    local ep = e.go:call("get_Transform"):call("get_Position")
                    local pp = player:call("get_Transform"):call("get_Position")
                    if math.sqrt(dist2(ep, pp)) <= AIM_RANGE then set_target(th, player) end
                end
            end)
        end
        return
    end
    -- Handed to another friend (3-4 players): follow theirs from now on.
    local k = slot_of_id(target)
    if k == nil then return end
    mv.own[id], mv.own_t[id], mv.handed[id] = k, os.clock(), nil
    mv.hist[id] = nil
    log(string.format("%s now runs in friend %d's game", name, k))
end

-- Pausing (pause menu, inventory, map) freezes this game, enemies it runs included, while
-- the friend plays on (2026-11-02 session). On pause: tell the friend and hand them every
-- enemy we run; nothing is handed to a paused player. Unpausing changes nothing at once:
-- enemies come back by distance as usual.
local function is_paused()
    local gm = sdk.get_managed_singleton("app.GameManager")
    if gm and safe(gm.call, gm, "get_IsPause") == true then return true end
    local mm = sdk.get_managed_singleton("app.MenuManager")
    return mm ~= nil and safe(mm.call, mm, "isOpenPauseMenu") == true
end

local function watch_pause(now)
    local paused = is_paused()
    if paused == (mv.paused or false) then return end
    mv.paused = paused
    if not (coop_link_friend and coop_link_friend(net_kv())) then return end
    send_event(paused and "pause 1" or "pause 0")
    if not paused then return end
    for _, e in pairs(es.tracked) do
        if moves_shared(e.name) and not e.dup and settled(e, os.clock()) and not (BOSS_FOLLOW[e.name] and not BOSS_HANDOFF[e.name]) and not car_pinned(e.name) and not friend_owned(e.id) and not e.dead and not mv.puppets[e.id] and safe(e.go.call, e.go, "get_Update") == true then
            -- To the nearest friend who isn't paused.
            local ep = e.go:call("get_Transform"):call("get_Position")
            local best, bd = nil, nil
            for k = 1, 3 do
                local g = not (mv.paused_slots and mv.paused_slots[k]) and friend_pos(k)
                if g then
                    local d = dist2(ep, g)
                    if bd == nil or d < bd then best, bd = k, d end
                end
            end
            if best then hand_off(e, now, best) end
        end
    end
end

-- Molded stand-ins (v0.57). A Molded the friend's game runs showed up here only once our own spawn point brought one
-- out (spawn_requests), and the game won't while the spot is in our player's view: the friend, usually right there
-- looking at it, waited a minute and more, or never saw it ("the molded never spawned in for my friend", 2026-11-14).
-- Now a Molded the friend runs that we have no body for gets one at once from our own pool (MoldedGenerator/
-- MoldedPool: five Em4000 bodies, asleep at the origin): it takes the Molded's id and the copy code drives it from
-- the friend's samples like any copy. If our spawn point brings out the game's own body later, that one takes over
-- and the stand-in goes back to the pool (scan); so does a stand-in the friend's game goes quiet on, or one that died.
STANDIN_QUIET = 2.5   -- s without the friend's data (before the copy code's 3 s take-back)
STANDIN_DEAD = 8      -- s a dead stand-in lies there
local function in_pool(e)
    local tr = safe(e.go.call, e.go, "get_Transform")
    local par = tr and safe(tr.call, tr, "get_Parent")
    local pgo = par and safe(par.call, par, "get_GameObject")
    return pgo ~= nil and tostring(safe(pgo.call, pgo, "get_Name") or ""):find("Pool", 1, true) ~= nil
end
local function standin_back(e, why)
    local id = e.id
    if coop_enemy_orphan then pcall(coop_enemy_orphan, e, true) end
    if e.go and safe(e.go.call, e.go, "get_UpdateSelf") then
        safe(e.go.call, e.go, "set_UpdateSelf", false)
        safe(e.go.call, e.go, "set_DrawSelf", false)
    end
    pcall(repool, e)
    e.id, e.hp, e.standin, e.standin_dead_t = enemy_id(e.go), nil, nil, nil
    log(string.format("stand-in for %s back in the pool (%s)", id, why))
end
local function stand_ins(now)
    if now - (es.standin_t or 0) < 0.25 then return end
    es.standin_t = now
    if settings and settings.molded_standins == false then return end
    if not moves_shared("Em4000") then return end
    local have, free = {}, {}
    for _, e in pairs(es.tracked) do
        have[e.id] = e
        if e.standin then
            local h = mv.hist[e.id]
            local k = mv.own[e.id]
            if e.dead then
                e.standin_dead_t = e.standin_dead_t or now
                if now - e.standin_dead_t > STANDIN_DEAD then standin_back(e, "dead") end
            elseif type(k) ~= "number" then
                standin_back(e, "ours to run now")
            elseif not friend_in_cutscene(k) and (h == nil or #h == 0 or now - h[#h].t > STANDIN_QUIET) then
                standin_back(e, "no data from your friend")
            end
        elseif is_regular(e.name) and e.id:sub(1, 2) == "p:" and not e.dead and safe(e.go.call, e.go, "get_UpdateSelf") == false
            and in_pool(e) then
            free[#free + 1] = e
        end
    end
    -- Wanted: the friend's Molded we have no body for, nearest our player first.
    local om = sdk.get_managed_singleton("app.ObjectManager")
    local pl = om and safe(om.get_field, om, "PlayerObj")
    local pp = pl and safe(function() return pl:call("get_Transform"):call("get_Position") end)
    local function d2(x, z) return pp and ((x - pp.x) ^ 2 + (z - pp.z) ^ 2) or 0 end
    local wanted = {}
    for id, h in pairs(mv.hist) do
        if id:sub(1, 2) == "s:" and have[id] == nil and type(mv.own[id]) == "number" and #h > 0 and now - h[#h].t <= 1
            and es.dead_here[id] ~= chapter() then
            wanted[#wanted + 1] = { id = id, h = h, d = d2(h[#h].x, h[#h].z) }
        end
    end
    table.sort(wanted, function(x, y) return x.d < y.d end)
    for _, w in ipairs(wanted) do
        local id, h = w.id, w.h
        if #free == 0 then
            -- More Molded than spare bodies (the pool has five): the stand-in farthest from us, if it's 10 m+ farther
            -- than this one, gives its body to it, so the Molded next to you are always there (v0.57).
            local far, fd
            for _, e in pairs(es.tracked) do
                if e.standin and not e.dead then
                    local p = safe(function() return e.go:call("get_Transform"):call("get_Position") end)
                    local d = p and d2(p.x, p.z)
                    if d and (fd == nil or d > fd) then far, fd = e, d end
                end
            end
            if far == nil or math.sqrt(fd) < math.sqrt(w.d) + 10 then
                if not es.standin_full_logged then
                    es.standin_full_logged = true
                    log("stand-in: no spare Molded body here (all five in use); the nearest ones keep theirs")
                end
                break
            end
            standin_back(far, "a nearer Molded needs the body")
            free[#free + 1] = far
        end
        do
            local e = table.remove(free)
            e.id, e.standin, e.hp, e.dup, e.replaced = id, true, nil, false, true
            have[id] = e
            es.spawn_want[id:sub(3)] = nil   -- the game's own may still come out: then it takes over
            local s = h[#h]
            log(string.format("stand-in: %s gets a body from our pool at once (your friend's at %.1f, %.1f, %.1f)", id, s.x, s.y, s.z))
        end
    end
end

local function update_movement(now)
    local pok, perr = pcall(watch_pause, now)
    if not pok and not mv.pause_err then mv.pause_err = true log("pause watch ERR " .. tostring(perr)) end
    mv.role = decide_role()
    coop_enemy_role_now = mv.role   -- v0.47: the host leads the story too (coop_story.lua)
    -- Cutscenes (v0.39): a scene moves its characters in each game on its own clock, and the
    -- two games are rarely at the same moment of it. While ours plays: no snapshots out, no
    -- copies (each copy gets its own AI and animation back: a copy with its animation brain
    -- off can't play the scene), no hand-offs. Their snapshots are still read, so following
    -- picks up again right after.
    local cut = local_cutscene and local_cutscene()
    if cut then
        if not mv.cut then
            mv.cut = true
            local n = 0
            for id in pairs(mv.puppets) do release(id) n = n + 1 end
            log("cutscene: enemy following paused" .. (n > 0 and string.format(" (%d copies run on their own)", n) or ""))
        end
        if coop_car.runner == "me" and now - mv.snap_t >= SNAP_EVERY then
            mv.snap_t = now
            pcall(write_car_only, now)
        end
        if not mv.replay and now - mv.in_t >= SNAP_READ_EVERY then
            mv.in_t = now
            for k = 1, 3 do if slot_live(k) then pcall(read_snapshot, now, k) end end
        end
        return
    elseif mv.cut then
        mv.cut = false
        log("cutscene over: enemy following resumes")
        -- Nothing is "taken back" for the quiet during the scene: ownership timers restart.
        for id in pairs(mv.own_t) do mv.own_t[id] = now end
    end
    -- Both games send and read: an enemy handed to the guest is sent back by the guest
    -- (host-only sending made every hand-off fail after 3 s, Jack 2026-11-02).
    if now - mv.snap_t >= SNAP_EVERY then
        mv.snap_t = now
        local ok, err = pcall(write_snapshot, now)
        if not ok and not mv.snap_err then mv.snap_err = true log("snapshot ERR " .. tostring(err)) end
        local ok2, err2 = pcall(coop_enemy_check_skips, now)
        if not ok2 and not mv.skip_err then mv.skip_err = true log("skip check ERR " .. tostring(err2)) end
    end
    if not mv.replay and now - mv.in_t >= SNAP_READ_EVERY then
        mv.in_t = now
        for k = 1, 3 do
            local ok, err = true, nil
            if slot_live(k) then ok, err = pcall(read_snapshot, now, k) end
            if not ok and not mv.read_snap_err then mv.read_snap_err = true log("snapshot read ERR " .. tostring(err)) end
        end
    end
    -- Replay test: feed the recording as if the host had sent it.
    local r = mv.replay
    if r then
        while r.i <= #r.frames and r.frames[r.i].rt <= now - r.t0 do
            local f = r.frames[r.i]
            push_hist(r.id, { x = f.x, y = f.y, z = f.z, yaw = f.yaw, bank = f.bank, mid = f.mid, frame = f.frame,
                speed = f.speed, weapon = f.weapon }, now)
            r.i = r.i + 1
        end
        if r.i > #r.frames and now - r.t0 > r.frames[#r.frames].rt + 3.5 then
            mv.replay = nil
            mv.msg = "replay finished"
        end
    end
    -- Molded the friend runs that we have no body for: one from our pool (v0.57).
    local sok, serr = pcall(stand_ins, now)
    if not sok and not es.standin_err then es.standin_err = true log("stand-in ERR " .. tostring(serr)) end
    -- Drive the enemies the friend runs; take back the ones they went quiet on.
    -- Not while a save is being prepared: followers have their own AI back then.
    local saving = mv.save_pause_until and now < mv.save_pause_until
    for _, e in pairs(es.tracked) do
        local id = e.id
        if friend_owned(id) and not saving and moves_shared(e.name) and not seq_hold(e.name) then
            local h = mv.hist[id]
            local fresh = h ~= nil and #h > 0 and now - h[#h].t <= 3
            if fresh then
                -- Not while ours is still climbing out (see EMERGE_S): its own AI brings it out first.
                if mv.puppets[id] == nil and awake_near_me(e) then
                    hold_note(e)   -- it may have hold of us (v0.51): a copy made now would drag us with it
                elseif mv.puppets[id] == nil and (settled(e, now) or safe(e.go.call, e.go, "get_Update") ~= true) then
                    puppetize(e)
                end
                mv.handed[id] = nil
                if mv.puppets[id] then
                    local ok, err = pcall(drive, e, h, now)
                    if not ok and not mv.drive_err then mv.drive_err = true log("drive ERR " .. tostring(err)) end
                end
            elseif now - (mv.own_t[id] or 0) > quiet_limit(e, mv.own[id]) and (h == nil or #h == 0 or now - h[#h].t > 3) then
                local why = mv.skip_why and mv.skip_why[id]
                mv.own[id], mv.own_t[id], mv.handed[id] = "me", now, nil
                if mv.puppets[id] then release(id) end
                mv.hist[id] = nil
                mv.takebacks = mv.takebacks + 1
                if mv.skip_why then mv.skip_why[id] = nil end
                log("took back " .. e.name .. " " .. id .. (why and (" (your friend's game can't run it: " .. why .. ")")
                    or string.format(" (no data from the friend for %.0f s)", quiet_limit(e, 0))))
                -- Their game couldn't run it (asleep or elsewhere in their story): handing it
                -- straight back made Jack flicker between games every few seconds (2026-11-02).
                mv.no_handoff = mv.no_handoff or {}
                -- Again for the same enemy (v0.47): their game doesn't have it (a Molded only
                -- comes out where its spawn point fired), so each try froze it for 3 s: wait longer.
                mv.no_data_n = mv.no_data_n or {}
                mv.no_data_n[id] = (mv.no_data_n[id] or 0) + 1
                mv.no_handoff[id] = now + (mv.no_data_n[id] > 1 and 120 or 30)
            elseif mv.handed[id] and mv.puppets[id] == nil then
                puppetize(e)   -- just handed over: hold still until their data arrives
            end
        end
    end
    for id, pe in pairs(mv.puppets) do
        if not friend_owned(id) or seq_hold(pe.name) then release(id)
        elseif BOSS_FOLLOW[pe.name] and not moves_shared(pe.name) then
            release(id)
            mv.own[id], mv.hist[id] = nil, nil
        end
    end
    -- Hand enemies to the friend when they're clearly closer to them (every 0.5 s).
    if now - mv.handoff_t >= 0.5 then
        mv.handoff_t = now
        pcall(check_handoffs, now)
    end
    -- One Molded for both: who it goes after (see aim_regulars).
    local aok, aerr = pcall(aim_regulars, now)
    if not aok and not es.aim_err then es.aim_err = true log("ERR aim_regulars: " .. tostring(aerr)) end
    -- Recording (testing): one enemy, 10 times a second.
    local rc = mv.rec
    if rc and now - rc.last >= SNAP_EVERY then
        rc.last = now
        local l = safe(enemy_line, rc.e)
        local s
        if l then _, s = parse_line(l) end
        if s then s.rt = now - rc.t0 rc.frames[#rc.frames + 1] = s end
        if now - rc.t0 >= rc.len then
            mv.rec = nil
            mv.recorded = { id = rc.e.id, e = rc.e, frames = rc.frames }
            mv.msg = string.format("recorded %s: %d samples, ready to replay", rc.e.name, #rc.frames)
            log(mv.msg)
        end
    end
end

scan = dbg_task("Enemy kills and damage", "Scan the enemies here", scan, {
    when = "4 times a second (every 0.25 s), plus once after a scene settles",
    reads = "ObjectManager.ManagedObjects: the enemy list (the list is re-picked every 5 s by reading the name of EVERY managed object); for each enemy: Update flag, position, isDead, spawn-point ids",
    writes = "es.tracked (the enemy table); sends 'kill <id> ...' when one dies here; applies kills the friend made earlier; puts a Molded back in its pool when it is asleep again" })
read_events = dbg_task("Link to your friend's game", "Read the friend's events", read_events, {
    when = "5 times a second (every 0.2 s)",
    reads = "coopnet_ev_in.txt (fs.read of the whole file each time); waits while loading",
    writes = "hands each new line to on_event" })
on_event = dbg_task("Friend's events", "Dispatch one event from the friend to the right script", on_event, {
    when = "once per event the friend's game sends (talk, menu, story, world, gun sounds, revive, kills...); runs per second shows how chatty the link is",
    reads = "the event text",
    writes = "kills / hurts / hands over enemies here; everything else goes to the script that owns the event" })
update_movement = dbg_task("Enemy movement", "Share where enemies are (the whole movement update)", update_movement, {
    when = "every frame (from the enemies callback)",
    reads = "pause state, the cutscene flag, the enemy table; the friend's enemy snapshots; the friend's data age",
    writes = "calls the tasks below; drives or releases enemies the friend runs; takes back enemies that went quiet" })
write_snapshot = dbg_task("Enemy movement", "Send the enemies we run", write_snapshot, {
    when = "15 times a second (every 1/15 s)",
    reads = "for each enemy we run that is awake: Transform position and rotation, motion layer 0 (bank, id, frame, speed), held weapon (about ten game calls per enemy)",
    writes = "coopnet_es_out.txt (fs.write, the plugin sends it)" })
read_snapshot = dbg_task("Enemy movement", "Read the enemies the friend runs", read_snapshot, {
    when = "30 times a second (every 1/30 s), once for each friend slot (1 to 3); not during our cutscenes except to keep up",
    reads = "coopnet_es_in*.txt (fs.read of the file each time)",
    writes = "the enemy position history used to move copies" })
puppetize = dbg_task("Enemy movement", "Turn an enemy into a copy of the friend's", puppetize, {
    when = "once per enemy when the friend's game takes it over (and again after it was given back)",
    reads = "the enemy's Update flag and pool state",
    writes = "wakes the body if it was asleep (set_UpdateSelf / set_DrawSelf), forces it visible, switches its own AI off (set_brain), registers it as a copy" })
drive = dbg_task("Enemy movement", "Move a copied enemy to the friend's position and play their animation", drive, {
    when = "every frame, for each enemy the friend runs (a copy)",
    reads = "the enemy's position history from the snapshots (interpolated, 'MOVE_DELAY' behind), its MovementController and motion layer 0 (to check frame drift); the spawn-point body list",
    writes = "MovementController.warp to the interpolated spot; changes the Motion clip and frame to the owner's; asks for a missing animation bank; wakes a copy the game put to sleep" })
check_handoffs = dbg_task("Enemy movement", "Hand enemies to whoever is nearer", check_handoffs, {
    when = "twice a second (every 0.5 s)",
    reads = "the position of every enemy, our player and each friend's ghost",
    writes = "sends 'own <id> ...' and turns the enemy into a copy when it is clearly nearer to the friend" })
aim_regulars = dbg_task("One Molded for both", "Aim each Molded at the nearest player", aim_regulars, {
    when = "every frame for the held targets; the full pass 3 times a second (every 0.3 s)",
    reads = "each enemy's AI Think component and Target; the friends' ghost positions; our position",
    writes = "EnemyThink.setTarget so a Molded goes for the nearer player; releases the hold when it is not needed" })
coop_enemy_check_skips = dbg_task("Enemy movement", "Check a handed-over enemy was really picked up", coop_enemy_check_skips, {
    when = "once a second (called with the snapshot send)",
    reads = "the table of handed-over enemies and who has them",
    writes = "takes an enemy back if the friend's game cannot run it" })
watch_pause = dbg_task("Enemy movement", "Tell the friend when we pause", watch_pause, {
    when = "every frame (from the movement update)",
    reads = "the game's pause state (is_paused)",
    writes = "sends 'pause 1' / 'pause 0' when it changes" })

-- Host runs every enemy (v0.57): the host's targeting and hits on the friends ---------------------------------
local HF_SWITCH = 2.0      -- m: a friend has to be this much nearer to take the enemy from us (and back)
local HF_RANGE = 25.0      -- m: farther than this from a friend, an enemy stays on us
local HF_WAKE = 15.0       -- m: an enemy the game put to sleep wakes again with a friend this near
local HF_NOTICE = 6.0      -- m: an awake enemy with no target takes on a friend this near
HAND_AGAIN_S = 20             -- s before the same Molded is handed to a friend's game again (v0.57)
HAND_IDLE_S = 3               -- s a Molded held on a friend may go without seeing anyone before the friend's game runs it (v0.57)
HQ_WAIT = 5                 -- s a guest holds a Molded still waiting for the host's game to have it (v0.57)
local HF_BODY_R, HF_BODY_H = 0.45, 1.9   -- the friend's body: radius and height (m) the attack shapes are tested against
es.hf_hits = es.hf_hits or 0
local function our_status()
    local pl = sdk.get_managed_singleton("app.ObjectManager"):get_field("PlayerObj")
    return pl, pl and safe(pl.call, pl, "getComponent(System.Type)", sdk.typeof("app.PlayerStatus"))
end
local function shape_hit(sh, gp)
    -- The shape's centre (sphere) or ends (capsule), against the friend's body (an upright cylinder).
    if sh == nil then return false end
    local pts, r = {}, 0.25
    local ok, c = pcall(function() return sh:call("get_Center") end)
    if ok and c then pts[1] = c local okr, rr = pcall(function() return sh:call("get_Radius") end) if okr and rr then r = rr end end
    if #pts == 0 then
        local okc, cap = pcall(function() return sh:call("get_Capsule") end)
        if okc and cap then pts[1], pts[2], r = cap.p0, cap.p1, cap.r or r end
    end
    if #pts == 0 then
        local oks, sp = pcall(function() return sh:call("get_Sphere") end)
        if oks and sp then pts[1], r = sp.pos, sp.r or r end
    end
    for _, p in ipairs(pts) do
        if p and (math.abs(p.x) + math.abs(p.y) + math.abs(p.z)) > 0.01 then   -- a shape's first frame reads 0,0,0
            local dx, dz = p.x - gp.x, p.z - gp.z
            if p.y >= gp.y - 0.3 and p.y <= gp.y + HF_BODY_H and dx * dx + dz * dz <= (HF_BODY_R + r) ^ 2 then return true end
        end
    end
    return false
end
local function hf_release(e, th, player)
    if th then
        es.aim_hold[th:get_address()] = nil
        if player then set_target(th, player) end
    end
    e.hf = nil
end
es.hq = es.hq or {}   -- enemies whose AI we switched off as a friend of the host (id -> e)
function host_fight(now)
    -- A friend's game in host mode (v0.57): no shared enemy fights here on its own. Until the host's copy takes over
    -- (puppet), its AI is off; in the bot test the guest's own Molded hit the guest before the host's took over.
    if host_mode() and mv.role == "guest" then
        es.hq_t, es.hq_own = es.hq_t or {}, es.hq_own or {}
        for _, e in pairs(es.tracked) do
            local awake = safe(e.go.call, e.go, "get_Update") == true
            if es.hq_own[e.id] and (e.dead or not awake) then es.hq_own[e.id] = nil end
            if moves_shared(e.name) and not e.dead and not e.dup and not mv.puppets[e.id] and not es.hq[e.id]
                and not es.hq_own[e.id] and awake then
                safe(set_brain, e, false)
                es.hq[e.id], es.hq_t[e.id] = e, now
                log(string.format("%s %s held still: the host's game runs it", e.name, e.id:sub(1, 12)))
            elseif es.hq[e.id] and mv.puppets[e.id] then
                es.hq[e.id] = nil   -- a copy now (its brain stays off as a copy)
            elseif es.hq[e.id] and is_regular(e.name) and now - (es.hq_t[e.id] or now) > HQ_WAIT then
                -- A Molded the host's game hasn't got (v0.57): its spawner wouldn't bring it out, or the host is
                -- elsewhere. Held still it stood frozen in front of the friend; now our game runs it after HQ_WAIT s
                -- and sends it, and the host's game shows a copy (from its pool if need be: stand-ins).
                local h = mv.hist[e.id]
                if h == nil or #h == 0 or now - h[#h].t > 2 then
                    es.hq[e.id] = nil
                    es.hq_own[e.id] = now
                    mv.own[e.id], mv.own_t[e.id] = "me", now
                    safe(set_brain, e, true)
                    log(string.format("%s %s: the host's game hasn't got it after %d s, so ours runs it", e.name, e.id:sub(1, 12), HQ_WAIT))
                end
            end
        end
        return
    end
    if next(es.hq) ~= nil then
        for id, e in pairs(es.hq) do if not mv.puppets[id] then safe(set_brain, e, true) end end
        es.hq = {}
        log("enemies held for the host's game: their own AI back")
    end
    if not (host_mode() and mv.role == "host") then
        if es.hf_any then
            es.hf_any = nil
            for _, e in pairs(es.tracked) do if e.hf then hf_release(e, think_of(e), nil) end end
        end
        return
    end
    if not (coop_link_friend and coop_link_friend(net_kv())) or scripted_now() then return end
    local player, ps = our_status()
    if player == nil or ps == nil then return end
    local p = safe(function() return player:call("get_Transform"):call("get_Position") end)
    if p == nil then return end
    local we_down = revive ~= nil and revive.downed == true
    local friends = {}
    for k = 1, 3 do
        if slot_live(k) and not friend_in_cutscene(k) and not (revive and revive.down_slots and revive.down_slots[k])
            and not (mv.paused_slots and mv.paused_slots[k]) then
            local fp = friend_pos(k)
            local g = fp and friend_ghost(k)
            if g then friends[#friends + 1] = { k = k, pos = fp, go = g } end
        end
    end
    local _, ids = party_ids()
    es.hf_any = true
    for _, e in pairs(es.tracked) do
        -- Not Jack in the car fight (v0.57): his targets there are the car's script's.
        if not e.dead and not e.dup and moves_shared(e.name) and not mv.puppets[e.id] and not car_pinned(e.name)
            and type(mv.own[e.id]) ~= "number" then
            local ep = safe(function() return e.go:call("get_Transform"):call("get_Position") end)
            -- The nearest friend, and the distances.
            local best, bd
            if ep then
                for _, f in ipairs(friends) do
                    local d = math.sqrt(dist2(ep, f.pos))
                    if bd == nil or d < bd then best, bd = f, d end
                end
            end
            -- Asleep with a friend next to it (the game sleeps what's far from its own player): awake again.
            if best and bd < HF_WAKE and safe(e.go.call, e.go, "get_UpdateSelf") == false and (e.out or not is_regular(e.name)) then
                if wake(e) then log(string.format("%s %s woken: your friend is next to it", e.name, e.id:sub(1, 12))) end
            end
            local th = ep and safe(e.go.call, e.go, "get_Update") == true and think_of(e)
            if th then
                local tgt = safe(th.call, th, "get_Target")
                local dm = math.sqrt(dist2(ep, p))
                local want = nil
                -- One that's fighting, or an awake one a friend is right next to (with the host's player far off, the host's
                -- game never sets it on anyone: it stood idle next to the friend in the bot test).
                if best and bd < HF_RANGE and (tgt ~= nil or e.hf or bd < HF_NOTICE) then
                    if we_down then want = best
                    elseif e.hf then
                        -- Stays on the friend until we're HF_SWITCH m nearer. (Was "(cond) and nil or best", which is always
                        -- best in Lua: an enemy that once went after the friend never came back to the host, bot test 2026-11-20.)
                        if not (dm + HF_SWITCH < bd) then want = best end
                    elseif bd + HF_SWITCH < dm then want = best end
                end
                if want then
                    if e.hf ~= want.k then log(string.format("%s %s goes after %s", e.name, e.id:sub(1, 12), want.k == 1 and "your friend" or ("friend " .. want.k))) end
                    e.hf = want.k
                    es.aim_hold[th:get_address()] = want.go:get_address()   -- first: the hold lets this target through
                    if tgt ~= want.go then set_target(th, want.go) end
                    if safe(th.call, th, "get_targetStatus") ~= ps then pcall(th.call, th, "set_targetStatus", ps) end
                    -- Handed to the friend's game (v0.57). Our game can't start a fight with the friend's body: its vision
                    -- never sees it (a VrDummyPlayer, no AIVisionBeacon), and even made to see it (AIVisionSensor.senseDirect,
                    -- a beacon, a PlayerStatus on it, all bot-tested 2026-11-20) the Molded idled next to it. One that's
                    -- already fighting keeps going at the friend (its copy's hits land natively); one that has seen no one
                    -- for HAND_IDLE_S s is run by the friend's game instead, where the friend is a real player.
                    if is_regular(e.name) then
                        local vs = safe(th.get_field, th, "<visionSensor>k__BackingField")
                        local tl = vs and safe(vs.get_field, vs, "_TargetList")
                        local seen = tl and (tonumber(safe(tl.call, tl, "get_Count")) or 0) > 0
                        if seen then
                            e.hf_idle_t = nil
                        else
                            e.hf_idle_t = e.hf_idle_t or now
                            -- Not again within HAND_AGAIN_S s of the last time: a Molded the friend's game put to sleep came back
                            -- here and went straight back to them every 6 s in the bot test.
                            if now - e.hf_idle_t > HAND_IDLE_S and now - (e.hand_t or -100) > HAND_AGAIN_S then
                                e.hf_idle_t, e.hand_t = nil, now
                                send_event(string.format("hrun %s %d %s", e.id, chapter(), ids[want.k] or "0"))
                                mv.own[e.id], mv.own_t[e.id] = want.k, now
                                log(string.format("%s %s hasn't seen anyone in %d s: handed to %s's game, where they're a real player",
                                    e.name, e.id:sub(1, 12), HAND_IDLE_S, want.k == 1 and "your friend" or ("friend " .. want.k)))
                                hf_release(e, th, player)
                                goto continue
                            end
                        end
                    end
                    -- Its live attack shapes against the friend's body: the game's own damage on a touch.
                    local rsc = e.rsc or safe(e.go.call, e.go, "getComponent(System.Type)", sdk.typeof("via.physics.RequestSetCollider"))
                    e.rsc = rsc
                    e.hf_sets = e.hf_sets or {}
                    local gp = safe(function() return want.go:call("get_Transform"):call("get_Position") end)
                    for i = 0, (rsc and gp) and ((safe(rsc.call, rsc, "get_NumRequestSets") or 0) - 1) or -1 do
                        local live = safe(rsc.call, rsc, "isRegisteredRequestSetFromIndex(System.UInt32)", i) == true
                        if not live then
                            e.hf_sets[i] = nil
                        elseif e.hf_sets[i] ~= "hit" then
                            local nc = safe(rsc.call, rsc, "getNumCollidablesFromIndex(System.UInt32)", i) or 0
                            for j = 0, nc - 1 do
                                local c = safe(rsc.call, rsc, "getCollidableFromIndex(System.UInt32, System.UInt32)", i, j)
                                local ud = c and safe(c.call, c, "get_UserData")
                                -- v0.57: off unless host_sends_hits is set. The friend's copy of this enemy plays the same attack
                                -- (its attack shapes go live in the friend's own game, where the friend really is), so the hit
                                -- lands there natively (bot tests: 300 and 200 damage hits at 1.2-2 m); sending it too would
                                -- hit them twice. Kept as a fallback for enemies whose copies don't hit.
                                if settings.host_sends_hits == true and ud and ud:get_type_definition():is_a("app.Collision.AttackUserData") and shape_hit(safe(c.call, c, "get_TransformedShape"), gp) then
                                    local dmg = tonumber(safe(ud.get_field, ud, "Damage")) or 0
                                    if dmg > 0 then
                                        e.hf_sets[i] = "hit"
                                        es.hf_hits = es.hf_hits + 1
                                        send_event(string.format("hurt %s %d %s %s %d", ids[want.k] or "0", dmg, e.name, e.id, chapter()))
                                        log(string.format("%s hit %s for %d", e.name, want.k == 1 and "your friend" or ("friend " .. want.k), dmg))
                                    end
                                    break
                                end
                            end
                        end
                    end
                elseif e.hf then
                    log(string.format("%s %s back on you (you %.1f m, your friend %s m)", e.name, e.id:sub(1, 12), dm, bd and string.format("%.1f", bd) or "-"))
                    hf_release(e, th, player)
                end
            end
        end
        ::continue::
    end
end
host_fight = dbg_task("Host runs every enemy", "Point enemies at the nearer player and catch their hits on friends", host_fight, {
    when = "every frame while 'Host runs every enemy' is on and we're the host",
    reads = "every shared enemy's position, target and live attack shapes (RequestSetCollider); the friends' characters",
    writes = "setTarget / set_targetStatus / the target hold on enemies near a friend; wakes ones the game slept near a friend; sends 'hurt' when a live attack shape touches a friend's character" })

-- The host's game handed us a Molded (v0.57, "hrun"): it can't start a fight with our character there; here we're
-- a real player. Ours runs it from now on (its AI back, sent to the host), until it sleeps or dies (host_fight).
function coop_enemy_take_run(id, ch, to)
    if ch ~= chapter() or not host_mode() or mv.role == "host" then return end
    local me = party_ids()
    if not (to == "0" or to == me or net_kv().mode == "udp") then return end
    local e = find_tracked(id)
    if e == nil then log("the host handed us " .. id:sub(1, 12) .. ", but it isn't here") return end
    es.hq_own = es.hq_own or {}
    es.hq_own[id] = os.clock()
    es.hq[id] = nil
    mv.own[id], mv.own_t[id] = "me", os.clock()
    if mv.puppets[id] then release(id) else safe(set_brain, e, true) end
    log(string.format("%s %s: the host's game handed it to ours (it hadn't seen anyone there): ours runs it", e.name, id:sub(1, 12)))
end

-- A host's enemy hit us (v0.57): the game's own damage path, with the copy that hit us as the attacker.
function coop_enemy_apply_hurt(to, dmg, name, id, ch)
    if ch ~= chapter() or not host_mode() then return end
    local me, _ = party_ids()
    local kv = net_kv()
    if not (to == "0" or to == me or kv.mode == "udp") then return end
    local pl = sdk.get_managed_singleton("app.ObjectManager"):get_field("PlayerObj")
    if pl == nil or (local_cutscene and local_cutscene()) then return end
    local dc = safe(pl.call, pl, "getComponent(System.Type)", sdk.typeof("app.PlayerDamageController"))
    local m = sdk.find_type_definition("app.DamageController"):get_method("newFakeDamageInfo")
    if dc == nil or m == nil then return end
    local te = find_tracked(id)
    local attacker = te and te.go or pl
    local info = safe(m.call, m, nil, dmg + 0.0, attacker, pl)
    if info == nil then log("hurt: no damage info") return end
    local ok, err = pcall(dc.call, dc, "addManualDamage", info)
    log(string.format("hit by the host's %s for %d%s", name, dmg, ok and "" or (" ERR " .. tostring(err))))
end

-- Jack's car in the garage (v0.57). ---------------------------------------------------------------------------
-- The garage fight's car (sm9104_EthanCar_Garage) isn't an enemy, so the Game Object explorer's enemy lists never
-- show it: it sits under a scene folder (c03_MainHouse1FGarage_havok), not under any game object, and has no
-- EnemySave. Its app.CarInGarage component and its own FSM (via.fsm.Fsm, states WaitPlayerGetInto, PlayerGetInto,
-- WaitEnemyGetPlayerOut, EnemyGetInto, ... ExecEnemyCrashEvent, AfterExplosion; saved by app.FsmParamSave) play the
-- whole fight with the local player (its Player field is our Pl0000) and garage Jack (its Enemy field, Em3000). So
-- each game had its own car fight: in the 2026-11-20 bot test one game's player sat in the driver's seat while the
-- other game's Jack got into its car, smashed every window and drove it into the wall on his own.
-- Now one game runs the car: the first whose car leaves WaitPlayerGetInto (its player got in, or its Jack did) says
-- so ("car run <chapter> <state>", every 4 s); if both did, the host's. That game keeps Jack for the whole fight (no
-- hand-offs: he rides in its car). The other game's car is a copy: its CarInGarage and FSM are stopped, its get-in
-- points switched off, and it's put every frame where the running game's car is (the "car" line of the enemy
-- snapshot, 15 a second), with the same windows, body, door and tyres broken. When Jack drives it over the other
-- player there, that game hurts its own player (the game's own damage path). With "Host runs every enemy" on, the
-- host's game always runs it.
local car = coop_car
car.hist = car.hist or {}
CAR_IDLE = { WaitPlayerGetInto = true }
CAR_RUNOVER_SPEED = 2.0   -- m/s: the car's own SpeedEnableEnemyRunOver
CAR_HIT_DMG = 250         -- of the player's 1000 health
CAR_HIT_EVERY = 2.0       -- s between two run-over hits
CAR_DELAY = 0.12          -- s the copy stays behind the running game's car (to blend between samples)
-- Its footprint around its origin (m): the headlights sit 2.4 m ahead of it, the body is about 2 m wide.
local CAR_HALF_W, CAR_FRONT, CAR_REAR = 1.0, 2.6, 2.5
local CAR_FLAGS = { "IsDoorBroken", "IsFrontLeftBlownOut", "IsFrontRightBlownOut", "IsRearLeftBlownOut", "IsRearRightBlownOut",
    "IsEnemyDriving", "IsPlayerDriving", "IsCrashed" }
local CAR_TYRES = { [2] = "blowOutFrontLeft", [3] = "blowOutFrontRight", [4] = "blowOutRearLeft", [5] = "blowOutRearRight" }

local function car_find(now)
    if car.c and safe(car.c.call, car.c, "get_GameObject") then return car.c end
    car.c = nil
    if now - (car.find_t or -100) < 2 then return nil end
    car.find_t = now
    local sc = sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"), sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
    local arr = sc and safe(sc.call, sc, "findComponents(System.Type)", sdk.typeof("app.CarInGarage"))
    local n = arr and tonumber(safe(arr.call, arr, "get_Count")) or 0
    if n == 0 then return nil end
    local c = arr:call("get_Item", 0)
    car.c, car.go = c, c:call("get_GameObject")
    car.tr, car.fsm = car.go:call("get_Transform"), c:get_field("Fsm")
    car.interacts = nil
    log("Jack's car found (the garage fight)")
    return c
end

local function car_state()
    return car.fsm and safe(car.fsm.call, car.fsm, "getCurrentState(System.UInt32)", 0)
end

-- The friend slot of the host (the lowest SteamID), or nil when we're the host.
local function car_host_slot()
    if mv.role == "host" then return nil end
    local _, ids = party_ids()
    local best
    for k, id in pairs(ids) do if best == nil or id_less(id, ids[best]) then best = k end end
    return best or 1
end

-- The car's own get-in, ignition and get-out points (InteractSendFsm on its children Interact_*).
local function car_interacts(on)
    if car.interacts == nil then
        car.interacts = {}
        local ch = safe(car.tr.call, car.tr, "get_Child")
        while ch do
            local go = safe(ch.call, ch, "get_GameObject")
            if go and tostring(safe(go.call, go, "get_Name") or ""):match("^Interact_") then
                for _, c in ipairs(arr_items(safe(go.call, go, "get_Components"))) do
                    if c:get_type_definition():get_full_name():find("Interact", 1, true) then car.interacts[#car.interacts + 1] = c end
                end
            end
            ch = safe(ch.call, ch, "get_Next")
        end
    end
    for _, c in ipairs(car.interacts) do safe(c.call, c, "set_Enabled", on) end
end

local function car_puppet(on)
    if car.c == nil or (car.puppet == true) == on then return end
    car.puppet = on
    safe(car.c.call, car.c, "set_Enabled", not on)
    safe(car.fsm.call, car.fsm, "set_Paused", on)
    car_interacts(not on)
    if on then car.win_done, car.fr_calls, car.rr_calls, car.flags_done = 0, 0, 0, 0 end
    log(on and "Jack's car: your friend's game runs it, this one is a copy of theirs" or "Jack's car: this game's own again")
end

-- The running game's car, as one snapshot line.
function coop_car_line()
    if car.runner ~= "me" or car.c == nil then return nil end
    local c, tr = car.c, car.tr
    local p, q = safe(tr.call, tr, "get_Position"), safe(tr.call, tr, "get_Rotation")
    if p == nil or q == nil then return nil end
    local flags = 0
    for i, f in ipairs(CAR_FLAGS) do if safe(c.get_field, c, f) == true then flags = flags | (1 << (i - 1)) end end
    return string.format("car %.3f %.3f %.3f %.4f %.4f %.4f %.4f %.2f %d %d %d %d %s", p.x, p.y, p.z, q.x, q.y, q.z, q.w,
        tonumber(safe(c.get_field, c, "DriveSpeed")) or 0, tonumber(safe(c.get_field, c, "FlagWindowBroken")) or 0,
        tonumber(safe(c.get_field, c, "CrashCountForFrontBody")) or 0, tonumber(safe(c.get_field, c, "CrashCountForRearBody")) or 0,
        flags, tostring(car.st or "-"))
end

-- A friend's car line (t is on our clock).
function coop_car_on_line(line, t, k)
    if car.runner ~= k then return end
    local x, y, z, qx, qy, qz, qw, spd, win, fr, rr, fl, st =
        line:match("^car (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%d+) (%d+) (%d+) (%d+) (%S+)$")
    if x == nil then return end
    local s = { t = t, x = tonumber(x), y = tonumber(y), z = tonumber(z), qx = tonumber(qx), qy = tonumber(qy),
        qz = tonumber(qz), qw = tonumber(qw), spd = tonumber(spd) or 0, win = tonumber(win), fr = tonumber(fr),
        rr = tonumber(rr), fl = tonumber(fl), st = st }
    if s.x == nil or s.qw == nil then return end
    local h = car.hist
    if #h > 0 and t <= h[#h].t then return end
    h[#h + 1] = s
    while #h > 2 and h[2].t < t - 2 do table.remove(h, 1) end
    if car.last == nil or car.last.st ~= st then log("Jack's car (your friend's): " .. st) end
    car.last = s
end

function coop_car_on_event(text)
    local ch, st = text:match("^car run (%-?%d+) (%S+)$")
    if ch == nil then return false end
    if tonumber(ch) ~= chapter() then return true end
    local k = coop_event_slot or 1
    if car.runner == "me" then
        if mv.role == "host" then return true end   -- both games started theirs: the host's is the one
        log("Jack's car: both games started theirs, the host's is the one")
    end
    if car.runner ~= k then
        log(string.format("Jack's car: friend %d's game runs it (it's at %s there)", k, st))
        if k == 1 then note("Jack's car: your friend's game drives it, you see theirs") end
    end
    car.runner = k
    return true
end

-- What the running game's car has broken, broken on ours too (each once).
local function car_mirror_damage()
    local s, c = car.last, car.c
    if s == nil or c == nil then return end
    for i = 1, 6 do
        local b = 1 << i
        if s.win & b ~= 0 and car.win_done & b == 0 then
            car.win_done = car.win_done | b
            safe(c.call, c, "breakWindow(app.CarInGarage.Window)", i)
        end
    end
    while car.fr_calls < math.min(s.fr, 4) do car.fr_calls = car.fr_calls + 1 safe(c.call, c, "breakFrontBody") end
    while car.rr_calls < math.min(s.rr, 4) do car.rr_calls = car.rr_calls + 1 safe(c.call, c, "breakRearBody") end
    if s.fl & 1 ~= 0 and car.flags_done & 1 == 0 then
        car.flags_done = car.flags_done | 1
        if safe(c.get_field, c, "IsDoorBroken") ~= true then safe(c.call, c, "breakOriginalLeftDoor") end
    end
    for bit, m in pairs(CAR_TYRES) do
        local b = 1 << (bit - 1)
        if s.fl & b ~= 0 and car.flags_done & b == 0 then
            car.flags_done = car.flags_done | b
            if safe(c.get_field, c, CAR_FLAGS[bit]) ~= true then safe(c.call, c, m) end
        end
    end
end

-- Jack drives the copy over our player: our game hurts us (the game's own damage path, the car as the attacker).
local function car_runover(now)
    local s = car.last
    if s == nil or s.fl & 32 == 0 or math.abs(s.spd) < CAR_RUNOVER_SPEED then car.inside = false return end
    if now - (car.hit_t or -100) < CAR_HIT_EVERY or (local_cutscene and local_cutscene()) then return end
    if revive and revive.downed then return end
    local pl = sdk.get_managed_singleton("app.ObjectManager"):get_field("PlayerObj")
    local pp = pl and safe(function() return pl:call("get_Transform"):call("get_Position") end)
    local cp, q = safe(car.tr.call, car.tr, "get_Position"), safe(car.tr.call, car.tr, "get_Rotation")
    if pp == nil or cp == nil or q == nil then return end
    -- The car's forward (its local +Z) and right, flat.
    local fx, fz = 2 * (q.x * q.z + q.w * q.y), 1 - 2 * (q.x * q.x + q.y * q.y)
    local n = math.sqrt(fx * fx + fz * fz)
    if n < 1e-4 then return end
    fx, fz = fx / n, fz / n
    local dx, dy, dz = pp.x - cp.x, pp.y - cp.y, pp.z - cp.z
    local along, side = dx * fx + dz * fz, dx * fz - dz * fx
    local m = 0.35   -- the player's own width
    local inside = not (math.abs(dy) > 1.6 or math.abs(side) > CAR_HALF_W + m or along > CAR_FRONT + m or along < -(CAR_REAR + m))
    -- One hit per pass: the bot test's car took 2.6 s to slide through and hit twice.
    local was = car.inside
    car.inside = inside
    if not inside or was then return end
    car.hit_t = now
    local dc = safe(pl.call, pl, "getComponent(System.Type)", sdk.typeof("app.PlayerDamageController"))
    local mk = sdk.find_type_definition("app.DamageController"):get_method("newFakeDamageInfo")
    local info = dc and mk and safe(mk.call, mk, nil, CAR_HIT_DMG + 0.0, car.go, pl)
    if info == nil then return end
    local ok, err = pcall(dc.call, dc, "addManualDamage", info)
    log(string.format("Jack's car hit you (%.1f m/s)%s", math.abs(s.spd), ok and "" or (" ERR " .. tostring(err))))
end

-- The fight is over or left: everything back as the game had it.
local function car_end(why)
    local final = car.last and car.last.st
    if car.puppet then
        car_puppet(false)
        -- The running game's car burnt out: ours is left the way a save loads it after the fight (the FSM state, which
        -- app.FsmParamSave keeps, and the wreck: breakAll, bot-tested 2026-11-20).
        if final and (final:find("Explosion", 1, true) or final:find("Crash", 1, true)) and car.fsm then
            safe(car.fsm.call, car.fsm, "setCurrentState(System.String)", "AfterExplosion")
            safe(car.c.call, car.c, "breakAll")
            log("Jack's car: your friend's burnt out, so ours is the wreck too")
        end
    end
    if car.runner ~= nil then log("Jack's car: " .. why) end
    car.runner, car.hist, car.last, car.ann_t = nil, {}, nil, nil
end

local function car_tick(now)
    if not jack_boss_fight() then
        if car.runner ~= nil or car.puppet then car_end("the garage fight is over") end
        return
    end
    if car.puppet and car.c then pcall(car_runover, now) end
    if now - (car.t or -100) < 0.25 then return end
    car.t = now
    if car_find(now) == nil then return end
    car.st = car_state()
    if host_mode() and mv.role ~= "host" then
        -- Host runs every enemy (v0.57): the host's game runs the car too, from the start.
        local h = car_host_slot()
        if car.runner ~= h then car.runner = h log("Jack's car: the host's game runs it (Host runs every enemy)") end
    elseif car.runner == nil and car.st and not CAR_IDLE[car.st] then
        car.runner, car.ann_t = "me", nil
        log("Jack's car: our game started it (" .. car.st .. "): we run it and Jack, your friend's game copies ours")
        note("Jack's car: your game drives it, your friend sees yours")
        -- Jack is ours from now on: a copy of the friend's Jack stops being one at once.
        for id, e in pairs(es.tracked) do
            if e.name == "Em3000" and mv.own[id] ~= nil and mv.own[id] ~= "me" then
                mv.own[id], mv.own_t[id], mv.handed[id] = "me", now, nil
                if mv.puppets[id] then release(id) end
                mv.hist[id] = nil
                log("took back Em3000 " .. id .. " (he rides in our car)")
            end
        end
    end
    if car.runner == "me" and now - (car.ann_t or -100) >= 4 then
        car.ann_t = now
        send_event(string.format("car run %d %s", chapter(), tostring(car.st or "-")))
    end
    local follow = type(car.runner) == "number"
    car_puppet(follow)
    if follow then pcall(car_mirror_damage) end
end

-- The copy is put where the running game's car was CAR_DELAY s ago, just before the frame is drawn.
local function car_place()
    if not car.puppet or car.tr == nil or #car.hist == 0 then return end
    local h = car.hist
    local rt = os.clock() - CAR_DELAY
    local a, b, f = h[#h], h[#h], 0
    if rt < h[#h].t then
        a, b = h[1], h[1]
        for i = #h - 1, 1, -1 do
            if h[i].t <= rt then a, b = h[i], h[i + 1] break end
        end
        if b.t > a.t then f = math.max(0, math.min(1, (rt - a.t) / (b.t - a.t))) end
    end
    local sgn = (a.qx * b.qx + a.qy * b.qy + a.qz * b.qz + a.qw * b.qw) < 0 and -1 or 1
    local qx, qy = a.qx + (sgn * b.qx - a.qx) * f, a.qy + (sgn * b.qy - a.qy) * f
    local qz, qw = a.qz + (sgn * b.qz - a.qz) * f, a.qw + (sgn * b.qw - a.qw) * f
    local n = math.sqrt(qx * qx + qy * qy + qz * qz + qw * qw)
    if n < 1e-6 then return end
    car.tr:call("set_Position", Vector3f.new(a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f, a.z + (b.z - a.z) * f))
    car.tr:call("set_Rotation", Quaternion.new(qw / n, qx / n, qy / n, qz / n))
end
dbg_note{ feature = "Jack's car (garage fight)", name = "Put the copy of the friend's car where theirs is",
    when = "every frame, just before drawing, only while the friend's game runs the garage car",
    reads = "the friend's car samples (the 'car' line of their enemy snapshot)",
    writes = "our garage car's position and rotation" }
re.on_pre_application_entry("PrepareRendering", function()
    if coop_busy and coop_busy() then return end
    local ok, err = pcall(car_place)
    if not ok and not car.place_err then car.place_err = true log("car place ERR " .. tostring(err)) end
end)
car_tick = dbg_task("Jack's car (garage fight)", "Decide which game runs the garage car; copy it in the other", car_tick, {
    when = "every frame during the garage fight (story stage 9fb77189 900-999); its checks 4 times a second",
    reads = "the car's FSM state and damage, the friend's 'car run' and car samples",
    writes = "'car run' events; on the copy: CarInGarage/FSM off, its get-in points off, windows/body/door/tyres broken like theirs, run-over hits on our player" })

dbg_note{ feature = "Enemy scheduler", name = "The enemies callback (calls the movement update, event reader and scan)",
    when = "every frame; its timers: the movement update every frame, events every 0.2 s, the scan every 0.25 s",
    reads = "see the rows above",
    writes = "see the rows above; waits while a scene is swapping characters" }
re.on_frame(function()
    if not es.enabled then return end
    local now = os.clock()
    -- A scene is swapping characters in and out: hands off, then rescan first (v0.36).
    if coop_scene_settling() then
        if not es.settling then es.settling = true log("scene setting up: enemies left alone for a moment") end
        return
    end
    if es.settling then
        es.settling = false
        es.scan_t = now
        local ok, err = pcall(scan)
        if not ok and not es.scan_err then es.scan_err = true log("scan ERR " .. tostring(err)) end
    end
    local mok, merr = pcall(update_movement, now)
    if not mok and not mv.err then mv.err = true log("movement ERR " .. tostring(merr)) end
    local hok, herr = pcall(host_fight, now)
    if not hok and not es.hf_err then es.hf_err = true log("host_fight ERR " .. tostring(herr)) end
    local cok, cerr = pcall(car_tick, now)
    if not cok and not car.tick_err then car.tick_err = true log("car ERR " .. tostring(cerr)) end
    if now - es.in_t >= 0.2 then
        es.in_t = now
        local ok, err = pcall(read_events)
        if not ok and not es.read_err then es.read_err = true log("read ERR " .. tostring(err)) end
    end
    if now - es.scan_t >= 0.25 then
        es.scan_t = now
        local ok, err = pcall(scan)
        if not ok and not es.scan_err then es.scan_err = true log("scan ERR " .. tostring(err)) end
    end
end)

-- For the on-screen status (coop_dummy shows it for 6 s).
function enemy_sync_hud()
    if mv.friend_paused then return "Your friend paused the game" end
    if os.clock() - es.msg_t < 6 then return "Enemies: " .. es.last_msg end
    return nil
end

-- Testing: the bot "kills" (or hurts, with damage_frac) the awake enemy nearest to
-- us, as if the friend had.
function enemy_sync_bot_kill_nearest(damage_frac)
    local player = sdk.get_managed_singleton("app.ObjectManager"):get_field("PlayerObj")
    if player == nil then return "no player" end
    local pp = player:call("get_Transform"):call("get_Position")
    local best, best_d
    for _, e in pairs(es.tracked) do
        if not e.dead and safe(e.go.call, e.go, "get_Update") == true then
            local p = e.go:call("get_Transform"):call("get_Position")
            local d = (p.x - pp.x) ^ 2 + (p.y - pp.y) ^ 2 + (p.z - pp.z) ^ 2
            if best_d == nil or d < best_d then best, best_d = e, d end
        end
    end
    if best == nil then return "no awake enemy nearby" end
    if damage_frac then
        local amount = (best.dc:call("get_maxHealth") or 0) * damage_frac
        fs.write("coopnet_command.txt", string.format("botevent dmg %s %d %.1f %s", best.id, chapter(), amount, best.name))
        log(string.format("bot test: friend hits %s for %.0f", best.name, amount))
        return string.format("the bot will hit %s for %.0f", best.name, amount)
    end
    fs.write("coopnet_command.txt", string.format("botevent kill %s %d %s", best.id, chapter(), best.name))
    log("bot test: friend kills " .. best.name .. " " .. best.id)
    return "the bot will take down " .. best.name
end

-- Testing (one PC): record the nearest awake enemy under its own AI, then put it back
-- where it started and replay the recording through the puppet code with its AI off.
local function nearest_awake()
    local player = sdk.get_managed_singleton("app.ObjectManager"):get_field("PlayerObj")
    if player == nil then return nil end
    local pp = player:call("get_Transform"):call("get_Position")
    local best, best_d
    for _, e in pairs(es.tracked) do
        if not e.dead and safe(e.go.call, e.go, "get_Update") == true and not mv.puppets[e.id] then
            local p = e.go:call("get_Transform"):call("get_Position")
            local d = (p.x - pp.x) ^ 2 + (p.y - pp.y) ^ 2 + (p.z - pp.z) ^ 2
            if best_d == nil or d < best_d then best, best_d = e, d end
        end
    end
    return best
end

function enemy_move_record(seconds)
    local e = nearest_awake()
    if e == nil then mv.msg = "no awake enemy nearby" return mv.msg end
    mv.rec = { e = e, t0 = os.clock(), last = -100, len = seconds or 6, frames = {} }
    mv.msg = "recording " .. e.name .. " for " .. (seconds or 6) .. " s"
    log(mv.msg)
    return mv.msg
end

function enemy_move_replay()
    local r = mv.recorded
    if r == nil or #r.frames < 2 then mv.msg = "record an enemy first" return mv.msg end
    local f = r.frames[1]
    local mc = safe(r.e.go.call, r.e.go, "getComponent(System.Type)", sdk.typeof("app.MovementController"))
    if mc then safe(mc.call, mc, "warp(via.vec3, via.Quaternion)", Vector3f.new(f.x, f.y, f.z),
        Quaternion.new(math.cos(f.yaw / 2), 0, math.sin(f.yaw / 2), 0)) end
    mv.hist[r.id] = nil
    mv.own[r.id], mv.own_t[r.id] = 1, os.clock()   -- "the friend" (the recording) runs it
    mv.replay = { id = r.id, frames = r.frames, i = 1, t0 = os.clock() }
    mv.msg = "replaying " .. r.e.name .. " with its AI off"
    log(mv.msg)
    return mv.msg
end

-- Testing: hand the nearest awake enemy to "the friend" (the bot never sends it back, so
-- it freezes, and after 3 s we take it back), or have the bot hand it to us.
function enemy_move_test_handoff()
    local e = nearest_awake()
    if e == nil then mv.msg = "no awake enemy nearby" return mv.msg end
    hand_off(e, os.clock())
    return mv.msg .. " (it should freeze, then come back to us after 3 s)"
end

function enemy_move_bot_hands_back()
    for id, o in pairs(mv.own) do
        if type(o) == "number" then
            local e = find_tracked(id)
            fs.write("coopnet_command.txt", string.format("botevent own %s %d %s", id, chapter(), e and e.name or "?"))
            return "the bot hands " .. (e and e.name or id) .. " back"
        end
    end
    return "the friend runs no enemies right now"
end

function enemy_move_status()
    local mine, theirs = 0, 0
    for _, e in pairs(es.tracked) do
        if safe(e.go.call, e.go, "get_Update") == true then
            if friend_owned(e.id) then theirs = theirs + 1 else mine = mine + 1 end
        end
    end
    return string.format("Enemy movement: %d run here, %d run by your friend; handed over %d, taken back %d; snapshots sent %d, received %d; %s",
        mine, theirs, mv.handoffs, mv.takebacks, mv.sent, mv.recv, mv.msg)
end

function enemy_sync_status()
    local awake, down = 0, 0
    for _, e in pairs(es.tracked) do
        if e.dead then down = down + 1 elseif safe(e.go.call, e.go, "get_Update") == true then awake = awake + 1 end
    end
    local pending = 0
    for _ in pairs(es.pending) do pending = pending + 1 end
    local near = ""
    for _, e in pairs(es.tracked) do
        if not e.dead and safe(e.go.call, e.go, "get_Update") == true then
            near = string.format("; %s health %.0f/%.0f", e.name, e.hp or 0, e.dc:call("get_maxHealth") or 0)
        end
    end
    return string.format("Enemy sync: %d awake, %d down here; sent %d, applied %d kills %d hits, remembered %d%s",
        awake, down, es.sent, es.applied, es.applied_dmg or 0, pending, near)
end

log("coop_enemies loaded")
