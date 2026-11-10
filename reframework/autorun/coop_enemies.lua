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
-- level, so it's the same on both PCs. Others fall back to "folder path/name".
-- Regular enemies stay dead: a kill for one that isn't loaded yet is remembered and
-- applied when it appears. Stalkers and bosses (Jack...) get back up in RE7, so their
-- "kill" is only applied if they're loaded right now.

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

-- Lines are collected and appended once a second (was a full read + rewrite per line).
local log_buf, log_t = {}, 0
local function log(s)
    log_buf[#log_buf + 1] = os.date("%H:%M:%S ") .. tostring(s)
end
re.on_frame(function()
    if #log_buf == 0 or os.clock() - log_t < 1 then return end
    log_t = os.clock()
    local f = fs.read("coop_enemies_log.txt") or ""
    if #f > 200000 then f = f:sub(-100000) end
    fs.write("coop_enemies_log.txt", f .. table.concat(log_buf, "\n") .. "\n")
    log_buf = {}
end)

local function safe(f, ...)
    local ok, r = pcall(f, ...)
    if ok then return r end
    return nil
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

-- Boss mode: only the stalker Jack (Em3000) and the Molded have their movement shared. Boss
-- fights and story characters (Jack's later forms, the family Em31xx-Em33xx...) are scripted
-- around the local player and their props, so each game runs its own copy; damage and defeat
-- are still shared.
-- The garage car fight is Em3000 too (same SaveGUID as the stalker Jack), so it's found by
-- story progress: stage hash 9fb77189 went to 900 at the garage cutscenes (c03e02_10,
-- c03e02_00) and to 1000 at the defeat (c03e03_00) (solo run, 2026-11-03). Other Jack fights
-- (the chainsaw one in the basement) aren't mapped yet.
local JACK_BOSS_STAGES = { { hash = 0x9fb77189, from = 900, to = 999 } }
local boss_cache = { t = -100, on = false }
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
        log(on and "boss mode: Jack's garage fight (each game runs its own Jack)" or "boss mode: off")
    end
    boss_cache.on = on
    return on
end

-- Bosses copied from the host's game (v0.32): Mia's fights (Em2000, molded Em2100).
local BOSS_FOLLOW = { Em2000 = true, Em2100 = true }
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
    if name == "Em3000" then return not jack_boss_fight() end
    if boss_follow(name) then return true end
    return is_regular(name)
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

local function damage_controller(go)
    local comps = safe(go.call, go, "get_Components")
    for _, c in ipairs(comps and safe(comps.get_elements, comps) or {}) do
        local td = c:get_type_definition()
        if td:is_a("app.DamageController") then return c end
    end
    return nil
end

-- ObjectManager.ManagedObjects is a list of lists; the enemy list is the biggest one
-- made only of "EmNNNN" objects (its index isn't the ListType enum value).
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
            local all_em = n > 0
            for j = 0, n - 1 do
                local go = l:call("get_Item", j)
                local name = go and safe(go.call, go, "get_Name") or ""
                if not name:match("^Em%d%d%d%d$") then all_em = false break end
            end
            if all_em and n > best_n then best, best_n = i, n end
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
re.on_frame(function() pcall(flush_events) end)

local function send_event(text)
    es.ev_seq = es.ev_seq + 1
    es.ev_out[#es.ev_out + 1] = es.ev_seq .. "\t" .. text
    while #es.ev_out > EV_OUT_KEEP do table.remove(es.ev_out, 1) end
    es.ev_dirty = true
    es.sent = es.sent + 1
    -- Regular check-ins (health, options, version) would fill the log: not logged.
    if not (text:match("^ehp ") or text:match("^opt ") or text:match("^ver ") or text:match("^dang ") or text:match("^spos ")
        or text:match("^lobby me ") or text:match("^lobby open ") or text:match("^stats ") or text:match("^light ")) then log("sent: " .. text) end
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
            if e == nil then
                local dc = damage_controller(go)
                if dc then
                    e = { go = go, dc = dc, id = enemy_id(go), name = go:call("get_Name") }
                    e.dead = dc:call("get_isDead") == true
                    es.tracked[addr] = e
                end
            end
            if e then
                seen[addr] = true
                local active = safe(go.call, go, "get_Update") == true
                local dead = e.dc:call("get_isDead") == true
                if dead and not e.dead then
                    -- Died here. Tell the friend, unless we did it on their word.
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
                if e.hp and not dead and active and hp < e.hp - 0.5 then
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
                if not dead and active and es.pending[e.id] == chapter() then
                    es.pending[e.id] = nil
                    es.applying[e.id] = os.clock()
                    local ok, err = pcall(kill_enemy, e)
                    note(ok and ("your friend already killed " .. e.name .. " here") or ("ERR remembered kill: " .. tostring(err)))
                end
            end
        end
    end
    for addr in pairs(es.tracked) do if not seen[addr] then es.tracked[addr] = nil end end
    -- Health check-in for the Molded (v0.24): every 3 s each awake one's health goes out as
    -- "ehp", and the game where it's higher lowers it to match. A damage message that never
    -- arrived (a load, a rejoin) can't leave the same Molded with two different healths.
    -- Never raised, never to 0 (the kill event does that), and not Jack or other bosses:
    -- their scripted phases set their own health.
    local now = os.clock()
    if now - (es.ehp_t or 0) >= 3 then
        es.ehp_t = now
        for _, e in pairs(es.tracked) do
            if is_regular(e.name) and not e.dead and (e.hp or 0) > 0 and safe(e.go.call, e.go, "get_Update") == true then
                send_event(string.format("ehp %s %d %.1f %s", e.id, chapter(), e.hp, e.name))
            end
        end
    end
end

local function find_tracked(id)
    for _, e in pairs(es.tracked) do if e.id == id then return e end end
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
function flinch(e, amount)
    if e.ac == nil then
        for _, c in ipairs(e.go:call("get_Components"):get_elements()) do
            if c:get_type_definition():is_a("app.EnemyActionController") then e.ac = c break end
        end
    end
    if e.ac == nil then return "no action controller" end
    if e.ac:call("get_isForbidDamageReaction") then return "reactions forbidden right now" end
    -- sdk.create_instance gave nothing (2026-11-03, on Jack): it's most likely a struct, which
    -- REFramework builds with ValueType.new.
    local td = sdk.find_type_definition("app.EnemyActionController.ResistResultSet")
    if td == nil then return "no ResistResultSet type" end
    local rs
    if td:is_value_type() then
        rs = ValueType.new(td)
    else
        rs = sdk.create_instance("app.EnemyActionController.ResistResultSet")
        if rs then pcall(rs.call, rs, ".ctor") end
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
    if (em_move == nil or type(em_move.own[id]) ~= "number") and is_regular(name) then
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

local function on_ehp(id, ch, v, name)
    if ch ~= chapter() or not is_regular(name) then return end
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
    ["break"] = true, dbreak = true, took = true, got = true, kill = true, catchup = true, own = true }
DROPPED_IN_CUTSCENE = { phys = true, dang = true, dmg = true, ehp = true }
-- Seconds after which a message that waited (while we loaded) is dropped (v0.39). A friend's
-- scene from a minute ago, or a hand-off of an enemy that has moved on since, would only do
-- harm now. Lasting changes (doors, drawers, pickups...) have no limit.
STALE_AFTER = { story = 20, own = 10, phys = 3, dang = 3, dmg = 5, talk = 60, heal = 10 }

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
        if l[1] > es.ev_in_last then
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
-- Friend slot k's SteamID is lower than ours (they win a tie).
local function lower_than_me(k)
    local me, ids = party_ids()
    return id_less(ids[k], me)
end

local function decide_role()
    if mv.replay then return "guest" end
    if mv.role_pref ~= "auto" then return mv.role_pref end
    local kv = net_kv()
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

local function weapons_of(e)
    local eq = equip_of(e)
    local list = eq and safe(eq.get_field, eq, "ManagedWeapons")
    local out = {}
    for i = 0, (list and list:call("get_Count") or 0) - 1 do
        local w = list:call("get_Item", i)
        local go = w and safe(w.call, w, "get_GameObject")
        if go then out[#out + 1] = go end
    end
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
        if mine and not seq_hold(e.name) and safe(e.go.call, e.go, "get_Update") == true and not mv.puppets[e.id] then
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
    -- "end" closes a whole snapshot: CoopNet sends only whole ones (v0.39).
    lines[#lines + 1] = "end"
    mv.seq = mv.seq + 1
    lines[1] = "seq " .. mv.seq
    fs.write("coopnet_es_out.txt", table.concat(lines, "\n") .. "\n")
    mv.sent = mv.sent + 1
end

-- Friend k is in a cutscene: their samples carry the cutscene flag (coop_dummy keeps it as
-- friend_cutscene, per friend).
local function friend_in_cutscene(k)
    local env = coop_slot_envs and coop_slot_envs[k or 1] or _G
    local v = rawget(env, "friend_cutscene")
    if v == nil and (k or 1) == 1 then v = rawget(_G, "friend_cutscene") end
    return v == true
end

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
    -- Their cutscene moves their enemies (v0.39): Jack sat at their dinner table while ours had
    -- moved on (2026-11-08). Nothing of theirs is followed until it ends.
    if friend_in_cutscene(k) then return end
    local off = now - t
    -- A jump of 5 s+ means that friend's clock restarted: start over (see coop_dummy).
    local o = mv.offset_s[k]
    if o == nil or off < o or off > o + 5 then o = off mv.offset_s[k] = o end
    if k == 1 then mv.offset = o end
    for line in text:gmatch("[^\n]+") do
        local id, s = parse_line(line)
        local te = id and find_tracked(id)
        if te and not moves_shared(te.name) then id = nil end   -- a boss: ours runs on its own
        if te and seq_hold(te.name) then id = nil end           -- our story sequence plays out (v0.39)
        if id then
            -- Friend k runs it. Two games running the same enemy: the lower SteamID keeps it.
            local own, take = mv.own[id], false
            if own == k then
                take = true
            elseif own == nil then
                -- Nobody's yet: theirs, unless we're the lower SteamID and run it awake here.
                local here = te and safe(te.go.call, te.go, "get_Update") == true
                if lower_than_me(k) or not here then mv.own[id], mv.own_t[id], take = k, now, true end
            elseif own == "me" then
                -- Just handed to us: a snapshot they sent a moment before still has it.
                if now - (mv.own_t[id] or 0) >= 1 and lower_than_me(k) then
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
        for _, c in ipairs(comps and safe(comps.get_elements, comps) or {}) do
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

local function puppetize(e)
    if not safe(e.go.call, e.go, "get_Update") then
        -- Awake in the host's game: wake ours too.
        safe(e.go.call, e.go, "set_UpdateSelf", true)
        safe(e.go.call, e.go, "set_DrawSelf", true)
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

local function drive(e, h, now)
    if now - (e.vis_t or 0) > 1 then e.vis_t = now pcall(force_visible, e) end
    local t = now - MOVE_DELAY
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
    if e.cur_bank ~= s.bank or e.cur_mid ~= s.mid then
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
    if net_kv().mode ~= "steam" then return end
    -- See watch_pause. A "paused" that never got its "back" (they quit) expires after 10 min.
    if mv.friend_paused and now - (mv.friend_paused_t or 0) > 600 then mv.friend_paused = false end
    if mv.paused then return end
    -- Friends here and not paused (a "paused" that never got its "back" expires after 10 min).
    local friends = {}
    for k = 1, 3 do
        local pt = mv.paused_slots and mv.paused_slots[k]
        if pt and now - pt > 600 then mv.paused_slots[k] = nil pt = nil end
        local g = not pt and friend_pos(k)
        if g then friends[#friends + 1] = { k = k, pos = g } end
    end
    local player = sdk.get_managed_singleton("app.ObjectManager"):get_field("PlayerObj")
    if #friends == 0 or player == nil then return end
    local p = player:call("get_Transform"):call("get_Position")
    for _, e in pairs(es.tracked) do
        local cooling = mv.no_handoff and (mv.no_handoff[e.id] or 0) > now
        if moves_shared(e.name) and not BOSS_FOLLOW[e.name] and not seq_hold(e.name) and not friend_owned(e.id) and not cooling and not e.dead and not mv.puppets[e.id] and safe(e.go.call, e.go, "get_Update") == true then
            local ep = e.go:call("get_Transform"):call("get_Position")
            local best, bd = nil, nil
            for _, f in ipairs(friends) do
                local d = math.sqrt(dist2(ep, f.pos))
                if bd == nil or d < bd then best, bd = f.k, d end
            end
            -- 3 m of hysteresis so it doesn't bounce between games.
            if best and bd + 3 < math.sqrt(dist2(ep, p)) then hand_off(e, now, best) end
        end
    end
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
    if net_kv().mode ~= "steam" then return end
    send_event(paused and "pause 1" or "pause 0")
    if not paused then return end
    for _, e in pairs(es.tracked) do
        if moves_shared(e.name) and not BOSS_FOLLOW[e.name] and not friend_owned(e.id) and not e.dead and not mv.puppets[e.id] and safe(e.go.call, e.go, "get_Update") == true then
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

local function update_movement(now)
    local pok, perr = pcall(watch_pause, now)
    if not pok and not mv.pause_err then mv.pause_err = true log("pause watch ERR " .. tostring(perr)) end
    mv.role = decide_role()
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
        if not mv.replay and now - mv.in_t >= 1 / 30 then
            mv.in_t = now
            for k = 1, 3 do pcall(read_snapshot, now, k) end
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
    end
    if not mv.replay and now - mv.in_t >= 1 / 30 then
        mv.in_t = now
        for k = 1, 3 do
            local ok, err = pcall(read_snapshot, now, k)
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
    -- Drive the enemies the friend runs; take back the ones they went quiet on.
    -- Not while a save is being prepared: followers have their own AI back then.
    local saving = mv.save_pause_until and now < mv.save_pause_until
    for _, e in pairs(es.tracked) do
        local id = e.id
        if friend_owned(id) and not saving and moves_shared(e.name) and not seq_hold(e.name) then
            local h = mv.hist[id]
            local fresh = h ~= nil and #h > 0 and now - h[#h].t <= 3
            if fresh then
                if mv.puppets[id] == nil then puppetize(e) end
                mv.handed[id] = nil
                local ok, err = pcall(drive, e, h, now)
                if not ok and not mv.drive_err then mv.drive_err = true log("drive ERR " .. tostring(err)) end
            elseif now - (mv.own_t[id] or 0) > 3 and (h == nil or #h == 0 or now - h[#h].t > 3) then
                mv.own[id], mv.own_t[id], mv.handed[id] = "me", now, nil
                if mv.puppets[id] then release(id) end
                mv.hist[id] = nil
                mv.takebacks = mv.takebacks + 1
                log("took back " .. e.name .. " " .. id .. " (no data from the friend for 3 s)")
                -- Their game couldn't run it (asleep or elsewhere in their story): handing it
                -- straight back made Jack flicker between games every few seconds (2026-11-02).
                mv.no_handoff = mv.no_handoff or {}
                mv.no_handoff[id] = now + 30
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
