-- coop_menu.lua: the in-game co-op menu and lobby (coop-re7 v0.40).
--
-- A full-screen menu drawn over the game, opened with F9 or by pressing both sticks (L3+R3)
-- on a controller, and driven with the keyboard (arrows or WASD, Enter, Backspace) or the
-- controller (D-pad or left stick, A to choose, B to go back). It works on the title screen
-- and in play. It needs no REFramework window.
--
-- While it's open the game's own controls are held, through the game's own switches:
-- MenuManager.setPlayerOperatableFlag / setCameraOperatableFlag (keyed flags, the way the
-- game's menus stop the player) and MenuManager.setInputLevel(NormalHigh), the UI input level
-- above the title menu's and the pause menu's, so they don't react to the same keys. All three
-- are given back when it closes, when scripts reset, and by a watchdog if anything is left over.
-- The game keeps running behind it (your friend's game does too).
--
-- Lobby. One player hosts. Everyone connected joins the host's lobby; friends join by
-- connecting to the host (the host's game accepts them while the lobby is open). The host
-- picks where to start: where each of you already is, the host's chapter, or the start of a
-- chapter. Everyone marks themselves ready; the host starts; every game then goes there. A
-- chapter jump needs each game to be in play already (a jump from the title screen leaves a
-- black screen), so Start waits until everyone has loaded a save. Messages, on the reliable
-- channel (coop_send_event / coop_menu_on_event):
--   lobby open <host id> <round> <start> <host chapter>   the host, every 2 s while open
--   lobby me <ready 0|1> <where> <start>                    every player, every 2 s
--   lobby go <host id> <round> <start> <host chapter>      the host pressed Start
--   lobby closed <host id>
-- <where>: "game" (in play), "title" (title screen, no save loaded yet), "busy" (loading or a
-- cutscene). <start>: "here", "host" or a chapter jump key (Chapter3_Start...).

local M = {
    open = false, page = "lobby", stack = {}, sel = {}, scroll = {}, cat = 1, focus = "A",
    msg = nil, msg_t = -100, msg_color = 0xFFFFFFFF,
    keys = {}, pad = {}, rep = {}, combo_t = nil, combo_done = false,
    locked = false, lock = {},
    fonts = nil, font_t = nil,
    cmdq = {}, cmd_t = 0,
    confirm = nil,
}
coop_menu = M

local LOCK_KEY = "coop_re7_menu"

-- Log ---------------------------------------------------------------------------------------
local log_buf, log_t = {}, 0
local function log(s) log_buf[#log_buf + 1] = os.date("%H:%M:%S ") .. tostring(s) end
re.on_frame(function()
    if #log_buf == 0 or os.clock() - log_t < 1 then return end
    log_t = os.clock()
    local f = fs.read("coop_menu_log.txt") or ""
    if #f > 200000 then f = f:sub(-100000) end
    fs.write("coop_menu_log.txt", f .. table.concat(log_buf, "\n") .. "\n")
    log_buf = {}
end)

local function safe(f, ...)
    local ok, r = pcall(f, ...)
    if ok then return r end
    return nil
end

local function kv()
    local n = coop_net_state and safe(coop_net_state)
    return (n and n.kv) or {}
end

local function say(text, color)
    M.msg, M.msg_t, M.msg_color = text, os.clock(), color or 0xFFFFFFFF
    log(text)
end

-- The key that opens the menu: F9 unless changed in Options (REFramework's own menu key may be F9).
MENU_KEYS = { { vk = 0x78, name = "F9" }, { vk = 0x79, name = "F10" }, { vk = 0x7A, name = "F11" },
    { vk = 0x24, name = "Home" }, { vk = 0x23, name = "End" } }
local function menu_key()
    local want = settings and tonumber(settings.menu_key)
    for _, k in ipairs(MENU_KEYS) do if k.vk == want then return k end end
    return MENU_KEYS[1]
end
function coop_menu_key_name() return menu_key().name end

-- CoopNet takes one command at a time (coopnet_command.txt, read and deleted 30 times a
-- second): queued, and the next written only once the last was taken.
local function command(cmd)
    M.cmdq[#M.cmdq + 1] = cmd
    log("command queued: " .. cmd)
    -- Nobody will carry it out (v0.49): the network plugin isn't running (see coop_plugin_dead, coop_dummy).
    if coop_plugin_dead and coop_plugin_dead() then
        say("The network plugin isn't running, so this can't work. Windows' Smart App Control may be blocking REFramework: see the README's Troubleshooting.", 0xFF6B6BFF)
    end
end
local function pump_commands(now)
    if #M.cmdq == 0 or now - M.cmd_t < 0.15 then return end
    local pending = fs.read("coopnet_command.txt")
    if pending ~= nil and pending ~= "" then
        if now - M.cmd_t < 3 then return end   -- CoopNet not running? Don't wait for ever.
    end
    M.cmd_t = now
    fs.write("coopnet_command.txt", table.remove(M.cmdq, 1))
end

-- Where we are ------------------------------------------------------------------------------
local function game_manager() return sdk.get_managed_singleton("app.GameManager") end
local function my_chapter()
    if local_chapter then return safe(local_chapter) or 0 end
    local gm = game_manager()
    return tonumber(gm and safe(gm.get_field, gm, "_CurrentChapter") or 0) or 0
end
local function on_title()
    local gm = game_manager()
    if gm and safe(gm.get_field, gm, "IsTitleDisp") == true then return true end
    local ch = my_chapter()
    if ch == 3 or ch == 0 then return true end
    local om = sdk.get_managed_singleton("app.ObjectManager")
    return om == nil or safe(om.get_field, om, "PlayerObj") == nil
end
local function where_am_i()
    if on_title() then return "title" end
    if local_cutscene and safe(local_cutscene) then return "busy" end
    if jump_busy and safe(jump_busy) then return "busy" end
    return "game"
end
local WHERE_TEXT = { game = "in the game", title = "on the title screen", busy = "loading or in a cutscene" }

local function chapter_label(v)
    if v == nil then return "?" end
    if chapter_name then
        local n = safe(chapter_name, v)
        if n then return n end
    end
    return tostring(v)
end

-- The party: who we're connected to (up to 3 friends), from CoopNet's status.
local function id_less(a, b) return a ~= nil and b ~= nil and ((#a < #b) or (#a == #b and a < b)) end
local function my_id() local k = kv() return k.steamSelf ~= "0" and k.steamSelf or nil end
local function my_name()
    local k = kv()
    return (k.steamName and k.steamName ~= "") and k.steamName or "You"
end
local function member(slot)
    local k = kv()
    local key = slot == 1 and "peer" or ("peer" .. slot)
    local id = k[key] and k[key]:match("^steam:(%d+)$")
    if id == nil or id == "0" then return nil end
    local name = slot == 1 and k.peerName or k["peer" .. slot .. "Name"]
    local env = coop_slot_envs and coop_slot_envs[slot]
    local fn = env and rawget(env, "coop_net_state")
    if fn == nil and slot == 1 then fn = coop_net_state end
    local st = fn and safe(fn)
    local last = st and st.history and st.history[#st.history]
    return { slot = slot, id = id, name = (name and name ~= "") and name or ("Friend " .. slot),
        fresh = last ~= nil and (os.clock() - last.t) < 3, chapter = st and st.peer_chapter,
        ping = st and tonumber(st.ping) }
end
local function members()
    local out = {}
    for s = 1, 3 do
        local m = member(s)
        if m then out[#out + 1] = m end
    end
    return out
end
local function slot_of(id)
    for _, m in ipairs(members()) do if m.id == id then return m.slot end end
    return nil
end
-- Everyone we play with (v0.44): members() (Steam), or the one friend of a "udp" link (LAN or
-- direct IP; no SteamID, "0" in give messages). The lobby and invites stay Steam only.
local function linked_members()
    local ms = members()
    local k = kv()
    if #ms == 0 and k.mode == "udp" and k.peer and k.peer ~= "-" and k.peer ~= "" then
        local st = coop_net_state and safe(coop_net_state)
        local last = st and st.history and st.history[#st.history]
        ms = { { slot = 1, id = "0", name = (k.peerName and k.peerName ~= "") and k.peerName or "Your friend",
            fresh = last ~= nil and (os.clock() - last.t) < 3, chapter = st and st.peer_chapter,
            ping = st and tonumber(st.ping) } }
    end
    return ms
end

-- This session (v0.42) ---------------------------------------------------------------------
-- Each game counts its own player's: enemies taken down, shots, hits taken, times down, times
-- got back up, heals, items given; "stats <kills> <shots> <hits> <downs> <got_up> <heals>
-- <given>" every 20 s tells the others. The time together counts while someone is connected.
local STATS = { me = {}, friends = {}, together = 0, last_t = nil, sent_t = -100 }
coop_stats = STATS
local STAT_KEYS = { "kills", "shots", "hits", "downs", "got_up", "heals", "given" }
function coop_stat(key, n)
    STATS.me[key] = (STATS.me[key] or 0) + (n or 1)
end
local function pump_stats(now)
    local any = false
    for _, m in ipairs(linked_members()) do if m.fresh then any = true end end
    if STATS.last_t and any then STATS.together = STATS.together + math.min(1, now - STATS.last_t) end
    STATS.last_t = now
    if any and now - STATS.sent_t > 20 and coop_send_event then
        STATS.sent_t = now
        local v = {}
        for i, k in ipairs(STAT_KEYS) do v[i] = tostring(math.floor(STATS.me[k] or 0)) end
        coop_send_event("stats " .. table.concat(v, " "))
    end
end

-- Lobby -------------------------------------------------------------------------------------
local L = {
    state = nil,          -- nil (none), "open", "started"
    host = nil,           -- host's SteamID
    round = 0,
    start = "here",
    host_ch = nil,
    ready = false,        -- ours
    ready_for = nil,      -- the start we said ready to
    info = {},            -- slot -> { ready, where, start, t }
    open_t = -100, me_t = -100,
    go = nil,             -- { round, start, host_ch, t0, tries, done }
    accept_t = {},        -- friend id -> when we last let them in
    seen_round = 0,
}
coop_lobby = L

-- Where to start. Only the chapter jumps this game offers are listed (ensure_chapter_list).
local STARTS = {
    { key = "here", label = "Continue: everyone's own latest save",
      hint = "Whoever is on the title screen loads their latest save (Continue); whoever is playing carries on." },
    { key = "host", label = "The host's chapter",
      hint = "Everyone not in the host's chapter goes to the start of it." },
    { key = "Chapter1_Start", label = "Chapter 1: the guest house",
      hint = "From the start of the story, after the drive in." },
    { key = "Chapter3_Start", label = "Chapter 3: the Baker house",
      hint = "From the dinner with the Bakers." },
    { key = "Chapter4_Start", label = "Chapter 4: the ship",
      hint = "From the shipwreck (you start as Mia)." },
}
local function jump_entry(key)
    if ensure_chapter_list then pcall(ensure_chapter_list) end
    for _, e in ipairs((chapters and chapters.list) or {}) do if e.key == key then return e end end
    return nil
end
local function jump_entry_for_chapter(v)
    if ensure_chapter_list then pcall(ensure_chapter_list) end
    for _, e in ipairs((chapters and chapters.list) or {}) do if e.value == v then return e end end
    return nil
end
local function starts_available()
    local out = {}
    for _, s in ipairs(STARTS) do
        if s.key == "here" or s.key == "host" or jump_entry(s.key) then out[#out + 1] = s end
    end
    return out
end
local function start_label(key)
    for _, s in ipairs(STARTS) do if s.key == key then return s.label end end
    return tostring(key)
end
local function start_hint(key)
    for _, s in ipairs(STARTS) do if s.key == key then return s.hint end end
    return ""
end

local function i_host() return L.state ~= nil and L.host ~= nil and L.host == my_id() end
local function host_name()
    if i_host() then return my_name() .. " (you)" end
    local s = L.host and slot_of(L.host)
    local m = s and member(s)
    return m and m.name or "the host"
end

local function send(text) if coop_send_event then coop_send_event(text) end end

local function set_presence()
    -- Friends' co-op lists show "hosting a lobby" (Steam rich presence, seen only by co-op).
    if i_host() and L.state == "open" then command("presence lobby " .. tostring(#members() + 1))
    else command("presence lobby -") end
end

local function lobby_host()
    if my_id() == nil then say("Steam isn't ready yet: wait a moment and try again", 0xFF6B6BFF) return end
    L.state, L.host, L.round, L.start = "open", my_id(), (L.round or 0), L.start or "here"
    L.ready, L.ready_for, L.info, L.go = true, L.start, {}, nil
    L.open_t = -100
    set_presence()
    say("You're hosting a lobby. Invite friends, pick where to start, then Start.", 0xFF7FFF8C)
end
local function lobby_close(why)
    if i_host() then send("lobby closed " .. L.host) end
    L.state, L.host, L.go, L.info, L.ready = nil, nil, nil, {}, false
    set_presence()
    say("Lobby closed" .. (why and (" (" .. why .. ")") or ""))
end
local function lobby_leave()
    -- Leaving = disconnecting from everyone (they keep playing together).
    L.state, L.host, L.go, L.info, L.ready = nil, nil, nil, {}, false
    if my_id() then send("lobby bye " .. my_id()) end
    command("steamleave")
    say("You left the lobby")
end

-- Can the host start? Returns nil, or the reason not.
local function start_blocker()
    local ms = members()
    if #ms == 0 then return "nobody has joined yet" end
    local jump = L.start ~= "here"
    if jump and where_am_i() == "title" then return "load a save first (Continue): a chapter jump can't start from the title screen" end
    for _, m in ipairs(ms) do
        local i = L.info[m.slot]
        if not m.fresh then return m.name .. " isn't connected right now" end
        if i == nil or os.clock() - i.t > 8 then return "waiting to hear from " .. m.name end
        if i.start ~= L.start or not i.ready then return m.name .. " isn't ready yet" end
        if jump and i.where == "title" then return m.name .. " is on the title screen: they need to load a save first" end
    end
    return nil
end

-- Doing the start in this game. A chapter jump goes through coop_dummy's jump_to_chapter (one
-- jump at a time, saving switched off first), retried every 2 s for a minute while refused.
local function begin_go(round, start, host_ch)
    L.go = { round = round, start = start, host_ch = host_ch, t0 = os.clock(), next_t = os.clock(), done = false }
    L.seen_round = math.max(L.seen_round or 0, round)
    L.state = "started"
    if start == "here" then
        -- Continue (v0.41): on the title screen, the game's own Continue; else carry on.
        if on_title() then
            L.go.continue_t = os.clock()
            say("Started! Loading your latest save (Continue)...", 0xFF7FFF8C)
            M.open_wanted = false
        else
            L.go.done = true
            say("Started! Each of you plays on from your own save.", 0xFF7FFF8C)
        end
        return
    end
    local e
    if start == "host" then
        if host_ch == nil or host_ch == my_chapter() then
            L.go.done = true
            say("Started! You're already in the host's chapter.", 0xFF7FFF8C)
            return
        end
        e = jump_entry_for_chapter(host_ch)
    else
        e = jump_entry(start)
    end
    if e == nil then
        L.go.done = true
        say("Can't go there from this game (no such chapter jump)", 0xFF6B6BFF)
        return
    end
    L.go.entry = e
    say("Starting: going to " .. start_label(start == "host" and e.key or start) .. "...", 0xFF7FFF8C)
end
-- The title screen's Continue, the way the menu does it itself (v0.41): highlight the CONTINUE
-- row, then the title menu's own step change to that row's step (ContinueBefore), on its next
-- update. If any of that fails, CONTINUE stays highlighted and the player is asked to press it.
-- A managed array's items: get_elements, or item by item when it has none (v0.48, see comp_list).
local function array_items(arr)
    if arr == nil then return {} end
    local ok, l = pcall(function() return arr:get_elements() end)
    if ok and l then return l end
    local out = {}
    local ok2, n = pcall(arr.call, arr, "get_Count")
    for i = 0, (ok2 and type(n) == "number") and n - 1 or -1 do
        local it = safe(arr.call, arr, "get_Item", i)
        if it then out[#out + 1] = it end
    end
    return out
end
local function title_continue()
    local sc = sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"), sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
    local arr = sc and safe(sc.call, sc, "findComponents(System.Type)", sdk.typeof("app.TitleSubMenu"))
    local tsm
    for _, t in ipairs(array_items(arr)) do
        local go = safe(t.call, t, "get_GameObject")
        if go and safe(go.call, go, "get_Name") == "GUI_menu" then tsm = t end
    end
    if tsm == nil then return false, "no title menu yet" end
    if safe(tsm.get_field, tsm, "IsMainListControl") ~= true then return false, "the title menu isn't ready" end
    local steps = tsm:get_field("_StepParam")
    local idx, step
    for i = 0, steps:call("get_Count") - 1 do
        local sp = steps:call("get_Item", i)
        if tostring(sp:get_field("GUIElemName")) == "continue" then idx, step = i, sp:get_field("Step") end
    end
    if idx == nil then return false, "no Continue row (no save yet?)" end
    local sl = tsm:get_field("_MainList"):get_field("_Element")
    pcall(sl.call, sl, "setSelectedIndex(System.Int32, System.Boolean)", idx, false)
    if settings and settings.auto_continue == false then return true, "CONTINUE highlighted" end
    local h = tsm:get_field("_Step")
    local ok = h and pcall(h.call, h, "changeStepNextUpdate(System.Int32)", step)
    log("lobby start: title Continue (step " .. tostring(step) .. "): " .. tostring(ok))
    return ok == true, ok and "continuing" or "couldn't press Continue"
end

local function pump_go(now)
    local g = L.go
    if g and not g.done and g.continue_t then
        if now < (g.next_t or 0) then return end
        g.next_t = now + 1
        if not on_title() then g.done = true return end   -- loading: it worked
        if now - g.continue_t > 30 then
            g.done = true
            say("Choose CONTINUE on the tape recorder to load your save", 0xFF7FE6FF)
            return
        end
        if not g.pressed then
            local ok, why = title_continue()
            if ok then g.pressed = true else log("lobby start: " .. tostring(why)) end
        end
        return
    end
    if g == nil or g.done or g.entry == nil or now < g.next_t then return end
    g.next_t = now + 2
    if now - g.t0 > 60 then
        g.done = true
        say("Couldn't start the chapter jump in a minute: " .. tostring(chapters and chapters.last), 0xFF6B6BFF)
        return
    end
    if jump_to_chapter == nil then g.done = true return end
    -- Not in the middle of a cutscene: the jump waits for it to end.
    if local_cutscene and safe(local_cutscene) then log("lobby start: waiting for the cutscene to end") return end
    local busy = jump_busy and safe(jump_busy)
    if busy then log("lobby start: waiting (" .. tostring(busy) .. ")") return end
    pcall(jump_to_chapter, g.entry)
    local last = tostring(chapters and chapters.last or "")
    if last:find("jumping to", 1, true) or last:find("saving switched OFF", 1, true) then
        g.done = true
        log("lobby start: " .. last)
        M.open_wanted = false   -- the menu closes for the load
    end
end

local function lobby_start()
    local why = start_blocker()
    if why then say("Not yet: " .. why, 0xFF7FE6FF) return end
    L.round = (L.round or 0) + 1
    local hc = my_chapter()
    send(string.format("lobby go %s %d %s %d", L.host, L.round, L.start, hc))
    log("lobby: start round " .. L.round .. " -> " .. L.start)
    begin_go(L.round, L.start, hc)
    set_presence()
end

-- Messages from the others.
function coop_menu_on_event(text)
    if text:sub(1, 6) == "stats " then
        local t, i = {}, 0
        for v in text:sub(7):gmatch("%d+") do i = i + 1 if STAT_KEYS[i] then t[STAT_KEYS[i]] = tonumber(v) end end
        STATS.friends[coop_event_slot or 1] = t
        return true
    end
    if text:sub(1, 6) ~= "lobby " then return false end
    local slot = coop_event_slot or 1
    local now = os.clock()
    local hid, round, start, hch = text:match("^lobby open (%d+) (%d+) (%S+) (%-?%d+)")
    if hid then
        round, hch = tonumber(round), tonumber(hch)
        if i_host() and hid ~= L.host then
            -- Two hosts: the lower SteamID keeps theirs, the other joins it.
            if id_less(hid, L.host) then
                log("lobby: " .. hid .. " hosts too and wins (lower id): joining theirs")
                L.host = nil      -- not hosting any more (and "first" below: we join theirs)
                set_presence()
            else
                return true
            end
        end
        local first = L.state == nil or L.host ~= hid
        L.state = (L.state == "started" and L.host == hid and round <= (L.seen_round or 0)) and "started" or "open"
        L.host, L.host_ch = hid, hch
        if start ~= L.start then L.start = start L.ready = false end
        L.round = round
        L.host_seen_t = now
        if first then
            L.ready, L.info = false, {}
            say(host_name() .. " is hosting a lobby: open the co-op menu (" .. menu_key().name .. ") to get ready", 0xFF7FFF8C)
        end
        return true
    end
    local rdy, where, mstart = text:match("^lobby me ([01]) (%a+) (%S+)")
    if rdy then
        L.info[slot] = { ready = rdy == "1", where = where, start = mstart, t = now }
        return true
    end
    local ghid, ground, gstart, ghch = text:match("^lobby go (%d+) (%d+) (%S+) (%-?%d+)")
    if ghid then
        ground = tonumber(ground)
        if ghid ~= L.host and L.host ~= nil then log("lobby: go from someone who isn't our host, ignored") return true end
        if ground <= (L.seen_round or 0) then return true end
        L.host = ghid
        begin_go(ground, gstart, tonumber(ghch))
        return true
    end
    -- Kicks come from the host only (v0.41).
    local kid = text:match("^lobby kick (%d+)")
    if kid then
        local from = member(slot)
        if L.host == nil or from == nil or from.id ~= L.host then log("lobby: a kick from someone who isn't the host, ignored") return true end
        if kid == my_id() then
            L.state, L.host, L.go, L.info, L.ready = nil, nil, nil, {}, false
            command("steamleave")
            say("The host removed you from the session", 0xFF6B6BFF)
        else
            command("steamremove " .. kid)
            command("steamblock " .. kid .. " 600")
            log("lobby: the host removed " .. kid)
        end
        return true
    end
    local bid = text:match("^lobby bye (%d+)")
    if bid then
        local s2 = slot_of(bid)
        local m = s2 and member(s2)
        command("steamremove " .. bid)
        command("steamblock " .. bid .. " 60")
        say((m and m.name or "A friend") .. " left", 0xFF7FE6FF)
        return true
    end
    local ut, uf = text:match("^lobby unlink (%d+) (%d+)")
    if ut then
        if ut == my_id() then
            command("steamremove " .. uf)
            command("steamblock " .. uf .. " 60")
        end
        return true
    end
    local chid = text:match("^lobby closed (%d+)")
    if chid then
        if L.host == chid and not i_host() then
            L.state, L.host, L.go, L.info, L.ready = nil, nil, nil, {}, false
            say("The host closed the lobby")
        end
        return true
    end
    return true
end

local function pump_lobby(now)
    -- The host is gone (disconnected for 15 s): the lobby is over.
    if L.state ~= nil and not i_host() then
        local s = L.host and slot_of(L.host)
        if s == nil or (L.host_seen_t and now - L.host_seen_t > 15 and L.state == "open") then
            L.state, L.host, L.info, L.ready = nil, nil, {}, false
            say("The lobby's host left")
        end
    end
    if i_host() and L.state ~= nil and now - L.open_t >= 2 then
        L.open_t = now
        send(string.format("lobby open %s %d %s %d", L.host, L.round or 0, L.start, my_chapter()))
    end
    if L.state ~= nil and now - L.me_t >= 2 then
        L.me_t = now
        if L.ready_for ~= L.start then L.ready = i_host() end
        send(string.format("lobby me %d %s %s", L.ready and 1 or 0, where_am_i(), L.start))
    end
    -- Friends who ask to join (they connected to us) are let in while we host.
    if i_host() and L.state ~= nil and read_friends then
        pcall(read_friends)
        local ms = members()
        if #ms < 3 then
            for _, f in ipairs((friends and friends.list) or {}) do
                if f.invites and slot_of(f.id) == nil and now - (L.accept_t[f.id] or -100) > 20 then
                    L.accept_t[f.id] = now
                    command("steamadd " .. f.id)
                    say(f.name .. " is joining your lobby", 0xFF7FFF8C)
                    break
                end
            end
        end
    end
    pump_go(now)
end

-- Who's still there (v0.41) -----------------------------------------------------------------
-- CoopNet remembers the party for next time, so a friend whose game had closed still showed as
-- "waiting for your friend" the next day (2026-11-09). Now a friend we hear nothing from is
-- disconnected after 30 s when Steam says their game isn't running co-op any more, or after 3
-- minutes when it is (lost connection). Friends played with in the last week come back by
-- themselves when they invite us again. Leaving and kicking tell everyone at once.
local UP = { gone = {}, t = 0, saved_t = 0 }
local RECENT_DAYS = 7
local function friend_entry(id)
    for _, f in ipairs((friends and friends.list) or {}) do if f.id == id then return f end end
    return nil
end
local function drop(id, block_s)
    command("steamremove " .. id)
    command("steamblock " .. id .. " " .. tostring(block_s or 60))
    UP.gone[id] = nil
end
local function pump_party(now)
    if now - UP.t < 2 then return end
    UP.t = now
    if kv().mode ~= "steam" then return end
    if read_friends then pcall(read_friends) end
    local recent = settings and (settings.recent_friends or {}) or nil
    if settings then settings.recent_friends = recent end
    local changed = false
    for _, m in ipairs(members()) do
        if m.fresh then
            UP.gone[m.id] = nil
            if recent and (recent[m.id] or 0) < os.time() - 600 then recent[m.id] = os.time() changed = true end
        else
            UP.gone[m.id] = UP.gone[m.id] or now
            local f = friend_entry(m.id)
            local running = f ~= nil and f.coop == true
            if now - UP.gone[m.id] > (running and 180 or 30) then
                drop(m.id, 60)
                say(m.name .. (running and " lost connection: disconnected" or " closed the game: disconnected"), 0xFF7FE6FF)
            end
        end
    end
    -- Recent friends who invite us come back by themselves.
    if recent and #members() < 3 then
        for _, f in ipairs((friends and friends.list) or {}) do
            local seen = recent[f.id]
            if f.invites and seen and os.time() - seen < RECENT_DAYS * 86400 and slot_of(f.id) == nil
                and not (friends.dismissed and friends.dismissed[f.id]) and now - (L.accept_t[f.id] or -100) > 20 then
                L.accept_t[f.id] = now
                command((#members() == 0 and "steam " or "steamadd ") .. f.id)
                say(f.name .. " is back: reconnecting", 0xFF7FFF8C)
                break
            end
        end
    end
    if changed and save_settings and now - UP.saved_t > 30 then UP.saved_t = now pcall(save_settings) end
end
-- Leaving everyone: the others drop us at once (not after 3 minutes of silence).
local function leave_all()
    if my_id() then send("lobby bye " .. my_id()) end
    command("steamleave")
end
-- Disconnecting from one friend (not the host's kick): they drop us too.
local function unlink(id)
    if my_id() then send("lobby unlink " .. id .. " " .. my_id()) end
    drop(id, 60)
end
-- The host takes a player out of the session.
local function kick(id)
    send("lobby kick " .. id)
    drop(id, 600)
end

-- Fonts -------------------------------------------------------------------------------------
-- The default font at two sizes, loaded once; used after a second (REFramework builds fonts on
-- a later frame). Without them the menu uses the default size.
local function fonts_ready()
    if M.fonts == false then return false end
    if M.fonts == nil then
        if not (imgui and imgui.load_font and imgui.push_font and imgui.pop_font) then M.fonts = false return false end
        local ok1, big = pcall(imgui.load_font, nil, 34)
        local ok2, body = pcall(imgui.load_font, nil, 22)
        local ok3, small = pcall(imgui.load_font, nil, 18)
        local function good(f) return f ~= nil and f ~= false end
        if not (ok1 and ok2 and ok3) or not (good(big) and good(body) and good(small)) then M.fonts = false return false end
        M.fonts = { big = big, body = body, small = small }
        M.font_t = os.clock()
        return false
    end
    return os.clock() - (M.font_t or 0) > 1.5
end
local SIZES = { big = 34, body = 22, small = 18 }
local function text(s, x, y, color, size)
    size = size or "body"
    local f = fonts_ready() and M.fonts[size] or nil
    if f then pcall(imgui.push_font, f) end
    pcall(draw.text, s, x, y, color or 0xFFE6E6E6)
    if f then pcall(imgui.pop_font) end
end
local function text_w(s, size)
    size = size or "body"
    local f = fonts_ready() and M.fonts[size] or nil
    if f and imgui.calc_text_size then
        pcall(imgui.push_font, f)
        local ok, v = pcall(imgui.calc_text_size, s)
        pcall(imgui.pop_font)
        if ok and v and v.x then return v.x end
    end
    local px = f and SIZES[size] or 13
    return #s * px * 0.52
end
local function line_h(size)
    if fonts_ready() then return SIZES[size or "body"] + 10 end
    return 20
end
local function fit(s, w, size)
    if text_w(s, size) <= w then return s end
    while #s > 4 and text_w(s .. "...", size) > w do s = s:sub(1, -2) end
    return s .. "..."
end

-- For the status lines (coop_dummy) and other on-screen text (v0.40): the same fonts.
function coop_ui_text(s, x, y, color, size) text(s, x, y, color, size) end
function coop_ui_line_h(size) return line_h(size) - 4 end

-- Input -------------------------------------------------------------------------------------
local VK = { up = 0x26, down = 0x28, left = 0x25, right = 0x27, enter = 0x0D, space = 0x20, back = 0x08,
    w = 0x57, s = 0x53, a = 0x41, d = 0x44, f = 0x46, esc = 0x1B }
local function key_down(vk)
    if not (reframework and reframework.is_key_down) then return false end
    local ok, v = pcall(reframework.is_key_down, reframework, vk)
    return ok and v == true
end
local PAD_BUTTONS = {}
local function pad_button(name)
    local b = PAD_BUTTONS[name]
    if b == nil then
        local td = sdk.find_type_definition("app.Pad.Button")
        local f = td and td:get_field(name)
        b = f and safe(f.get_data, f, nil) or false
        PAD_BUTTONS[name] = b
    end
    return b or nil
end
local function the_pad()
    local pm = sdk.get_managed_singleton("app.PadManager")
    return pm and safe(pm.call, pm, "get_mergedPad")
end
local function pad_down(p, name)
    local b = pad_button(name)
    if p == nil or b == nil then return false end
    local ok, v = pcall(p.call, p, "isDown(app.Pad.Button)", b)
    return ok and v == true
end
-- This frame's presses: each "action" true once per press, held directions repeat.
local function read_actions(now)
    local p = the_pad()
    local stick_v = p and tonumber(safe(p.call, p, "getStickLeftVertical")) or 0
    local stick_h = p and tonumber(safe(p.call, p, "getStickLeftHorizontal")) or 0
    local held = {
        up = key_down(VK.up) or key_down(VK.w) or pad_down(p, "LeftUp") or stick_v > 0.6,
        down = key_down(VK.down) or key_down(VK.s) or pad_down(p, "LeftDown") or stick_v < -0.6,
        left = key_down(VK.left) or key_down(VK.a) or pad_down(p, "LeftLeft") or stick_h < -0.6,
        right = key_down(VK.right) or key_down(VK.d) or pad_down(p, "LeftRight") or stick_h > 0.6,
        ok = key_down(VK.enter) or key_down(VK.space) or key_down(VK.f) or pad_down(p, "Decide"),
        back = key_down(VK.back) or key_down(VK.esc) or pad_down(p, "Cancel"),
        toggle = key_down(menu_key().vk),
        combo = pad_down(p, "LeftStickPush") and pad_down(p, "RightStickPush"),
    }
    local out = {}
    for k, v in pairs(held) do
        local was = M.keys[k]
        if v and not was then
            out[k] = true
            M.rep[k] = now + 0.4
        elseif v and was and (k == "up" or k == "down" or k == "left" or k == "right") and now >= (M.rep[k] or math.huge) then
            out[k] = true
            M.rep[k] = now + 0.11
        end
        M.keys[k] = v
    end
    return out
end

-- Holding the game while the menu is open ------------------------------------------------
local function lock_key()
    if M.key_str == nil then
        M.key_str = sdk.create_managed_string and safe(sdk.create_managed_string, LOCK_KEY) or LOCK_KEY
        if type(M.key_str) ~= "string" and M.key_str and M.key_str.add_ref then pcall(M.key_str.add_ref, M.key_str) end
    end
    return M.key_str or LOCK_KEY
end
local function input_level()
    if M.level == nil then
        local td = sdk.find_type_definition("app.UICommand.InputLevel")
        local f = td and td:get_field("NormalHigh")
        M.level = f and safe(f.get_data, f, nil) or false
    end
    return M.level or nil
end
local function hold_game(on)
    local mm = sdk.get_managed_singleton("app.MenuManager")
    if on then
        if M.locked then return end
        M.lock = {}
        if mm then
            local k = lock_key()
            M.lock.player = pcall(mm.call, mm, "setPlayerOperatableFlag(System.Boolean, System.String)", false, k)
            M.lock.camera = pcall(mm.call, mm, "setCameraOperatableFlag(System.Boolean, System.String)", false, k)
            local lvl = input_level()
            if lvl then
                M.lock.level = pcall(mm.call, mm, "setInputLevel(app.UICommand.InputLevel)", lvl)
                -- Did it take? The game's own menus only stop reacting if ours is the active level.
                local active = safe(mm.call, mm, "get_ActiveInputLevel")
                M.lock.level_active = active ~= nil and tonumber(active) == tonumber(lvl)
                log("input level now " .. tostring(active) .. " (ours " .. tostring(lvl) .. ")")
            end
        end
        -- v0.48: the game's own pointer, as its menus ask for it. In play the game pins the mouse to
        -- turn the camera, so our screen saw a pointer that never moved (2026-11-10); on the title
        -- screen it was already free.
        local hid = sdk.get_managed_singleton("app.HIDManager")
        if hid then
            M.lock.cursor = pcall(hid.call, hid, "requestShowMouseCursor(System.String)", lock_key())
            M.lock_hid = hid
        end
        M.locked = true
        M.lock_mm = mm
        log(string.format("menu open: player %s, camera %s, input level %s held, pointer %s", tostring(M.lock.player),
            tostring(M.lock.camera), tostring(M.lock.level), tostring(M.lock.cursor)))
    else
        if not M.locked then return end
        -- The same MenuManager we held (a load may have made a new one: then nothing to give back).
        local m2 = M.lock_mm
        local same = m2 ~= nil and mm ~= nil and (m2 == mm or safe(m2.get_address, m2) == safe(mm.get_address, mm))
        if same then
            local k = lock_key()
            if M.lock.player then pcall(m2.call, m2, "setPlayerOperatableFlag(System.Boolean, System.String)", true, k) end
            if M.lock.camera then pcall(m2.call, m2, "setCameraOperatableFlag(System.Boolean, System.String)", true, k) end
            local lvl = input_level()
            if lvl and M.lock.level then pcall(m2.call, m2, "resetInputLevel(app.UICommand.InputLevel)", lvl) end
        end
        local hid = sdk.get_managed_singleton("app.HIDManager")
        local h2 = M.lock_hid
        if M.lock.cursor and h2 ~= nil and hid ~= nil and (h2 == hid or safe(h2.get_address, h2) == safe(hid.get_address, hid)) then
            pcall(h2.call, h2, "removeShowMouseCursor(System.String)", lock_key())
        end
        M.locked, M.lock, M.lock_mm, M.lock_hid = false, {}, nil, nil
        log("menu closed: game controls given back")
    end
end
re.on_script_reset(function() pcall(hold_game, false) end)

-- Page A: the sections, like the game's Options and Extra Content sheets (v0.41). Page B shows
-- the highlighted one; Right or Enter goes into it, Backspace or B comes back.
local CATS = {
    { page = "lobby", label = "Lobby" },
    { page = "friends", label = "Friends" },
    { page = "talk", label = "Quick messages" },
    { page = "give", label = "Give items" },
    { page = "session", label = "This session" },
    { page = "you", label = "Your character" },
    { page = "options", label = "Options" },
    { page = "help", label = "Help and fixes" },
    { page = nil, label = "Close" },
}
M.cats = CATS   -- for the menu test
local function set_open(on)
    if on == M.open then return end
    M.open = on
    M.open_wanted = on
    if on then
        M.stack, M.confirm = {}, nil
        M.cat = M.cat or 1
        if CATS[M.cat].page == nil then M.cat = 1 end
        M.page, M.focus = CATS[M.cat].page, "A"
        if settings and not settings.menu_welcomed then M.page, M.focus = "welcome", "B" end
        if ensure_chapter_list then pcall(ensure_chapter_list) end
        if read_friends then pcall(read_friends) end
    end
    hold_game(on)
end
coop_menu_set_open = set_open

-- Pages -------------------------------------------------------------------------------------
-- An item: { text, value = string, on = fn, left = fn, right = fn, off = "why it can't be used",
-- hint = string, color }. { info = true, text } lines can't be chosen.
local function go_page(p)
    -- Another page on page B (the lobby's "Invite friends"...); Back returns to the one before.
    M.stack[#M.stack + 1] = M.page
    M.page = p
    M.sel[p] = M.sel[p] or 1
    M.focus = "B"
end
local function back()
    if M.confirm then M.confirm = nil return end
    if M.focus == "B" then
        if #M.stack > 0 then M.page = table.remove(M.stack) return end
        M.focus, M.page = "A", CATS[M.cat].page
        return
    end
    set_open(false)
end
local function ask(question, yes_text, fn)
    M.confirm = { question = question, yes = yes_text, fn = fn, sel = 2 }
end

local function setting_toggle(label, key, default_on, shared, hint, after)
    local s = settings or {}
    local v = s[key]
    if v == nil then v = default_on end
    local function flip()
        local nv = not v
        if shared and coop_set_shared_option then pcall(coop_set_shared_option, key, nv)
        elseif settings then
            settings[key] = nv
            if save_settings then pcall(save_settings) end
        end
        if after then pcall(after, nv) end
    end
    return { text = label, value = v and "On" or "Off", on = flip, left = flip, right = flip, hint = hint }
end

local function party_line()
    local ms = linked_members()
    if #ms == 0 then
        local k = kv()
        if coop_plugin_dead and coop_plugin_dead() then return "Network plugin not running: see Troubleshooting" end
        if k.mode == "bot" then return "Test bot is on (no friend connected)" end
        return "Not connected to anyone yet"
    end
    local names = {}
    for _, m in ipairs(ms) do names[#names + 1] = m.name .. (m.fresh and "" or " (waiting)") end
    return "Playing with " .. table.concat(names, ", ")
end

local function invite_item()
    local inv = pending_invite and safe(pending_invite)
    if inv == nil then return nil end
    return { text = inv.name .. (inv.lobby and " invited you to their lobby" or " wants to play co-op with you"),
        value = "Accept", color = 0xFF7FFF8C,
        on = function()
            command((#members() == 0 and "steam " or "steamadd ") .. inv.id)
            if friends and friends.dismissed then friends.dismissed[inv.id] = nil end
            say("Joining " .. inv.name .. "...", 0xFF7FFF8C)
        end,
        hint = "Connects you to them. Their lobby (if they host one) appears here." }
end

local PAGES = {}

-- Shown once, the first time the menu opens (and from Help).
function PAGES.welcome()
    local items = {
        { info = true, text = "Welcome to Molded Together.", color = 0xFFFFFFFF },
        { info = true, text = "1. Friends: invite a friend who runs Molded Together, or accept their invite." },
        { info = true, text = "2. Lobby: one of you hosts and picks where to start; everyone gets ready; Start." },
        { info = true, text = "   To start at a chapter, everyone loads a save first (Continue), then Start." },
        { info = true, text = "3. Play. Doors, items, enemies and story scenes are shared; if you go down," },
        { info = true, text = "   your friend can get you back up." },
        { info = true, text = "Saving is off unless you switch it on (Options). " .. menu_key().name .. " or L3+R3 opens this menu." },
        { text = "Got it", on = function()
            if settings then settings.menu_welcomed = true if save_settings then pcall(save_settings) end end
            M.page, M.stack, M.focus = CATS[M.cat or 1].page, {}, "A"
        end },
    }
    return "Welcome", items
end

-- How your friends see you.
function PAGES.you()
    local items = {}
    if CHARACTERS and settings then
        local idx = 1
        for i, c in ipairs(CHARACTERS) do if c.key == (settings.look or "default") then idx = i end end
        local function pick(d)
            local n = #CHARACTERS
            local ni = ((idx - 1 + d) % n) + 1
            if coop_set_look then pcall(coop_set_look, CHARACTERS[ni].key) else settings.look = CHARACTERS[ni].key end
        end
        items[#items + 1] = { text = "You appear as", value = CHARACTERS[idx].name,
            left = function() pick(-1) end, right = function() pick(1) end, on = function() pick(1) end,
            hint = "What your friends see you as." }
    end
    local fm = kv().fullModels
    if fm == "1" then
        items[#items + 1] = { info = true, text = "Full character models: installed." }
    elseif fm == "off" or fm == "move" then
        items[#items + 1] = { info = true, text = "Full character models: copied in but not set up." }
        items[#items + 1] = { info = true, text = "Close the game and run Use full models.cmd." }
    else
        items[#items + 1] = { info = true, text = "Full character models: not installed: characters" }
        items[#items + 1] = { info = true, text = "other than Default may lack a face (Nexus mod 86)." }
    end
    return "Your character", items
end

function PAGES.lobby()
    local items = {}
    if L.state == nil then
        items[#items + 1] = { info = true, text = party_line(), color = 0xFF969696 }
        items[#items + 1] = { text = "Host a lobby", on = lobby_host,
            hint = "You pick where to start; friends who join you get ready, and you start together." }
        items[#items + 1] = { text = "Join a friend's lobby", on = function() go_page("friends") end,
            hint = "Friends hosting a lobby are marked in the list." }
            return "Lobby", items
    end
    local host = i_host()
    items[#items + 1] = { info = true, text = "Host: " .. host_name() .. (L.state == "started" and "   (started)" or ""),
        color = 0xFFFFFFFF }
    -- Players.
    local mine = where_am_i()
    items[#items + 1] = { info = true, text = string.format("  %s (you): %s, %s, %s", my_name(), chapter_label(my_chapter()),
        WHERE_TEXT[mine] or mine, (host or L.ready) and "ready" or "not ready"),
        color = (host or L.ready) and 0xFF7FFF8C or 0xFF7FE6FF }
    for _, m in ipairs(members()) do
        local i = L.info[m.slot]
        local state
        if not m.fresh then state = "not connected"
        elseif i == nil or os.clock() - i.t > 8 then state = "joining..."
        else
            state = string.format("%s, %s", WHERE_TEXT[i.where] or i.where,
                (i.ready and i.start == L.start) and "ready" or "not ready")
        end
        local color = (i and i.ready and i.start == L.start and m.fresh) and 0xFF7FFF8C or 0xFF7FE6FF
        local ping = (m.fresh and m.ping) and string.format(", %d ms", math.floor(m.ping * 1000 + 0.5)) or ""
        -- Where they are in the story next to us (v0.41).
        local cmp = coop_story_compare and safe(coop_story_compare, m.slot)
        local where = cmp == "ahead" and ", behind you" or cmp == "behind" and ", ahead of you" or ""
        -- A different difficulty (v0.42): enemies won't match.
        local fd = coop_friend_difficulty and safe(coop_friend_difficulty, m.slot)
        local md = coop_my_difficulty and safe(coop_my_difficulty)
        if fd and md and md >= 0 and fd ~= md then
            where = where .. ", on " .. tostring(coop_difficulty_name and safe(coop_difficulty_name, fd) or fd) .. " (not yours)"
            color = 0xFF6B6BFF
        end
        local row = { info = not host, text = string.format("  %s: %s, %s%s%s", m.name, chapter_label(m.chapter), state, where, ping), color = color }
        if host then
            -- The host can take a player out of the session (v0.41).
            row.on = function() ask("Remove " .. m.name .. " from the session?", "Remove", function() kick(m.id) say(m.name .. " was removed") end) end
            row.hint = "Enter: remove " .. m.name .. " from the session."
        end
        items[#items + 1] = row
    end
    for _ = #members() + 2, 4 do items[#items + 1] = { info = true, text = "  (free place)", color = 0xFF6E6E6E } end
    -- Where to start.
    local avail = starts_available()
    local cur = 1
    for i, s in ipairs(avail) do if s.key == L.start then cur = i end end
    local function pick(d)
        if not host then return end
        local ni = ((cur - 1 + d) % #avail) + 1
        L.start = avail[ni].key
        L.ready_for = L.start
        L.open_t = -100   -- tell everyone now
    end
    items[#items + 1] = { text = "Where to start", value = start_label(L.start), left = host and function() pick(-1) end or nil,
        right = host and function() pick(1) end or nil, on = host and function() pick(1) end or nil,
        off = (not host) and "the host picks where you start" or nil, hint = start_hint(L.start) }
    if host then
        local why = start_blocker()
        items[#items + 1] = { text = L.state == "started" and "Start again" or "Start", value = why and "waiting" or "everyone's ready",
            color = why and nil or 0xFF7FFF8C, off = why,
            on = function()
                if L.start == "here" then lobby_start()
                else ask("Everyone goes to " .. start_label(L.start) .. ". Saving switches off for the jump. Start?", "Start", lobby_start) end
            end,
            hint = why and ("Not yet: " .. why) or "Everyone goes now." }
        items[#items + 1] = { text = "Invite friends", on = function() go_page("friends") end }
        items[#items + 1] = { text = "Close the lobby", on = function() ask("Close the lobby? You stay connected.", "Close it", lobby_close) end }
    else
        items[#items + 1] = { text = "Ready", value = L.ready and "Yes" or "No",
            on = function() L.ready = not L.ready L.ready_for = L.start L.me_t = -100 end,
            left = function() L.ready = false L.me_t = -100 end, right = function() L.ready = true L.ready_for = L.start L.me_t = -100 end,
            hint = (L.start ~= "here" and where_am_i() == "title") and "Load a save first (Continue): the jump can't start from the title screen."
                or "The host starts once everyone is ready." }
        -- Behind the host in the story: their key items and weapons (v0.41, experimental).
        local hslot = L.host and slot_of(L.host)
        local cmp = hslot and coop_story_compare and safe(coop_story_compare, hslot)
        items[#items + 1] = { text = "Get the host's key items and weapons", value = cmp == "behind" and "you're behind" or nil,
            off = (cmp == "ahead") and "you're further on than the host: you keep your own" or (hslot == nil and "the host isn't connected") or nil,
            on = function() ask("Get the key items and weapons the host has and you don't? (experimental)", "Get them", function()
                if world_sync then world_sync.want_inv = os.clock() end
                send("inv_req " .. L.host)
                say("Asking the host for their key items and weapons...", 0xFF7FFF8C)
            end) end,
            hint = "For catching up when you're behind in the story (experimental)." }
        items[#items + 1] = { text = "Leave the lobby", on = function() ask("Leave? You'll be disconnected from everyone.", "Leave", lobby_leave) end }
    end
    if L.go and not L.go.done then
        items[#items + 1] = { info = true, text = "Starting... " .. tostring(chapters and chapters.last or ""), color = 0xFF7FE6FF }
    end
    return "Lobby", items
end

function PAGES.friends()
    local items = {}
    local inv = invite_item()
    if inv then items[#items + 1] = inv end
    if read_friends then pcall(read_friends) end
    local list = (friends and friends.list) or {}
    local in_party = {}
    for _, m in ipairs(members()) do in_party[m.id] = true end
    local shown = 0
    for _, f in ipairs(list) do
        if f.coop or f.invites or (friends and friends.show_all) or in_party[f.id] then
            shown = shown + 1
            local status, verb, act
            if in_party[f.id] then
                status, verb = "connected", "Remove"
                act = function() ask("Disconnect from " .. f.name .. "?", "Disconnect", function()
                    if i_host() then kick(f.id) else unlink(f.id) end
                end) end
            elseif f.invites then
                status, verb = f.lobby and "invited you to their lobby" or "invited you", "Accept"
                act = function() command((#members() == 0 and "steam " or "steamadd ") .. f.id) say("Joining " .. f.name .. "...", 0xFF7FFF8C) end
            elseif f.lobby then
                status, verb = "hosting a lobby", "Join"
                act = function() command((#members() == 0 and "steam " or "steamadd ") .. f.id) say("Asking to join " .. f.name .. "...", 0xFF7FFF8C) end
            elseif f.coop then
                status, verb = "Molded Together " .. tostring(f.version or ""), "Invite"
                act = function() command((#members() == 0 and "steam " or "steamadd ") .. f.id) say("Invited " .. f.name .. ": they accept in their co-op menu", 0xFF7FFF8C) end
            elseif f.in_re7 then
                status, verb = "in RE7, co-op not running", "Invite"
                act = function() command((#members() == 0 and "steam " or "steamadd ") .. f.id) say("Invited " .. f.name .. " for when they start Molded Together") end
            else
                status, verb = "online", "Invite"
                act = function() command((#members() == 0 and "steam " or "steamadd ") .. f.id) say("Invited " .. f.name .. " for when they start Molded Together") end
            end
            local full = not in_party[f.id] and #members() >= 3
            local k = kv()
            if f.coop and f.version and k.version and f.version ~= k.version then status = status .. " (different version!)" end
            items[#items + 1] = { text = f.name, value = status, on = (not full) and act or nil,
                off = full and "the party is full (4 players)" or nil,
                color = (f.invites or f.lobby) and 0xFF7FFF8C or nil,
                hint = verb .. ": " .. ((verb == "Remove") and "disconnects you from them." or
                    (verb == "Accept" or verb == "Join") and "connects you to them." or
                    "connects to them; they see your invite in their co-op menu.") }
        end
    end
    if shown == 0 then
        items[#items + 1] = { info = true, text = "No friends running Molded Together right now.", color = 0xFF969696 }
        items[#items + 1] = { info = true, text = "They appear here as soon as they start it.", color = 0xFF969696 }
    end
    items[#items + 1] = { text = "Show all online friends", value = (friends and friends.show_all) and "Yes" or "No",
        on = function() if friends then friends.show_all = not friends.show_all end end,
        left = function() if friends then friends.show_all = false end end, right = function() if friends then friends.show_all = true end end,
        hint = "Invite a friend who hasn't started Molded Together yet: they get it when they do." }
    if #members() > 0 then
        items[#items + 1] = { text = "Disconnect from everyone", on = function() ask("Disconnect from everyone?", "Disconnect", function()
            if L.state ~= nil and i_host() then lobby_close("you left") end
            leave_all()
        end) end }
    end
    return "Friends", items
end

function PAGES.talk()
    local items = {}
    if #linked_members() == 0 or coop_talk_send == nil then
        items[#items + 1] = { info = true, text = "Nobody's connected: invite a friend under Friends." }
        return "Quick messages", items
    end
    for _, q in ipairs({ { "ping", "Over here", "Marks where you stand for your friends." },
        { "come", "Come here", "Marks where you stand and asks them over." }, { "wait", "Wait for me" },
        { "go", "Go on ahead" }, { "help", "Help!", "Marks where you stand." },
        { "ammo", "I need ammo", "Asks for ammo: your friends can give you some under Give items." },
        { "meds", "I need healing", "Asks for healing: your friends can give you some under Give items." } }) do
        items[#items + 1] = { text = q[2], hint = q[3], on = function()
            pcall(coop_talk_send, q[1])
            set_open(false)
        end }
    end
    return "Quick messages", items
end

-- Give items (v0.42): ammo, healing, materials to a friend. coop_world.lua does the giving: the
-- friend's game puts it in their inventory and says how many arrived, and only then does it
-- leave yours.
local GIVE = { to = 1, amount = 1, list = nil, list_t = -100 }
local AMOUNTS = { "One", "Half", "All" }
function PAGES.give()
    local items = {}
    local ms = linked_members()
    if #ms == 0 or coop_give_item == nil then
        items[#items + 1] = { info = true, text = "Nobody's connected: invite a friend under Friends." }
        return "Give items", items
    end
    -- v0.43: a friend just asked for ammo or healing ("I need ammo"): pick them, once.
    local req = coop_give_ask
    if req and not req.used and os.clock() - req.t < 120 then
        req.used = true
        for i, mm in ipairs(ms) do if mm.slot == req.slot then GIVE.to = i end end
    end
    if GIVE.to > #ms then GIVE.to = 1 end
    local m = ms[GIVE.to]
    local fh = coop_friend_health and coop_friend_health(m.slot)
    local function pick(d) GIVE.to = ((GIVE.to - 1 + d) % #ms) + 1 end
    items[#items + 1] = { text = "Give to", value = m.name .. (m.fresh and "" or " (not connected)") ..
        (fh and string.format(" (health %d%%)", fh) or ""),
        left = #ms > 1 and function() pick(-1) end or nil, right = #ms > 1 and function() pick(1) end or nil,
        on = #ms > 1 and function() pick(1) end or nil }
    local function amount(d) GIVE.amount = ((GIVE.amount - 1 + d) % #AMOUNTS) + 1 end
    items[#items + 1] = { text = "How many", value = AMOUNTS[GIVE.amount],
        left = function() amount(-1) end, right = function() amount(1) end, on = function() amount(1) end }
    -- The inventory, read again twice a second (not every frame).
    local now = os.clock()
    if GIVE.list == nil or now - GIVE.list_t > 0.5 then
        GIVE.list, GIVE.list_t = (coop_shareable_items and safe(coop_shareable_items)) or {}, now
    end
    if #GIVE.list == 0 then
        items[#items + 1] = { info = true, text = "Nothing to give: your ammo, healing and materials show here.", color = 0xFF969696 }
    end
    for _, e in ipairs(GIVE.list) do
        local n = GIVE.amount == 1 and 1 or GIVE.amount == 2 and math.max(1, math.floor(e.n / 2)) or e.n
        items[#items + 1] = { text = e.name, value = "x" .. e.n,
            off = (not m.fresh) and (m.name .. " isn't connected right now") or nil,
            on = function()
                ask(string.format("Give %s x%d to %s?", e.name, n, m.name), "Give", function()
                    local tok, why = coop_give_item(m.id, e.id, n, m.name)
                    if tok then say(string.format("Giving %s x%d to %s...", e.name, n, m.name), 0xFF7FFF8C)
                    else say("Not now: " .. tostring(why), 0xFF7FE6FF) end
                    GIVE.list = nil
                end)
            end,
            hint = string.format("Gives %d to %s; it leaves your inventory once it's in theirs.", n, m.name) }
    end
    local gm = world_sync and world_sync.give_msg
    if gm and now - gm.t < 8 then items[#items + 1] = { info = true, text = gm.text, color = gm.color } end
    return "Give items", items
end

-- This session (v0.42).
local function stat_line(t)
    t = t or {}
    local function n(k) return math.floor(t[k] or 0) end
    local function c(k, one, many) local v = n(k) return v .. " " .. (v == 1 and one or many) end
    return string.format("%s, %s, %s taken, down %d, up %d, %s, %d given",
        c("kills", "enemy", "enemies"), c("shots", "shot", "shots"), c("hits", "hit", "hits"), n("downs"), n("got_up"),
        c("heals", "heal", "heals"), n("given"))
end
function PAGES.session()
    local items = {}
    local mins = math.floor(STATS.together / 60)
    items[#items + 1] = { info = true, color = 0xFFFFFFFF, text = mins >= 60
        and string.format("Together for %d h %02d min", math.floor(mins / 60), mins % 60)
        or string.format("Together for %d min", mins) }
    items[#items + 1] = { info = true, text = "  You: " .. stat_line(STATS.me), color = 0xFF7FFF8C }
    for _, m in ipairs(linked_members()) do
        local t = STATS.friends[m.slot]
        items[#items + 1] = { info = true, text = "  " .. m.name .. ": " .. (t and stat_line(t) or "nothing heard yet (they need v0.42)"),
            color = 0xFF7FE6FF }
    end
    -- Difficulty: different ones mean enemies with different health and damage.
    local mine = coop_my_difficulty and safe(coop_my_difficulty)
    local name = coop_difficulty_name and mine and safe(coop_difficulty_name, mine)
    if name then
        local diff = {}
        for _, m in ipairs(linked_members()) do
            local d = coop_friend_difficulty and safe(coop_friend_difficulty, m.slot)
            if d and d ~= mine then diff[#diff + 1] = m.name .. " " .. tostring(safe(coop_difficulty_name, d)) end
        end
        items[#items + 1] = { info = true, text = "Difficulty: " .. name .. (#diff > 0 and (" (different: " .. table.concat(diff, ", ") .. ")") or ""),
            color = #diff > 0 and 0xFF6B6BFF or 0xFF969696 }
    end
    items[#items + 1] = { text = "Start counting again", on = function()
        ask("Set this session's counts back to zero (yours)?", "Reset", function()
            STATS.me, STATS.together = {}, 0
            STATS.sent_t = -100
        end)
    end, hint = "Your friends' counts start again when they reset theirs." }
    return "This session", items
end

function PAGES.options()
    local items = {}
    items[#items + 1] = setting_toggle("Share story", "share_story", true, true,
        "Cutscenes and story progress one of you reaches count for both; the same for everyone.")
    items[#items + 1] = setting_toggle("Share supplies", "share_supplies", false, true,
        "One copy of ammo and healing for everyone (harder); the same for everyone.")
    items[#items + 1] = setting_toggle("Share interactions", "share_interactions", true, true,
        "Fridges, switches, locks and chains done by one of you are done for all.")
    items[#items + 1] = setting_toggle("Share phone calls", "share_phones", true, true, "One of you answers, everyone gets the call.")
    items[#items + 1] = setting_toggle("Join your friend's scripted moves", "intr_pull_me", false, false,
        "Off: the phone, a fridge, a pot your friend uses plays on their character and you keep control. On: you're put through it too. Cutscenes always play for both.")
    items[#items + 1] = setting_toggle("Share pushed objects", "share_physics", true, true, "Chairs and bottles you push move for everyone.")
    items[#items + 1] = setting_toggle("Share boss fights", "share_bosses", true, true, "One game runs Mia, the others copy her.")
    items[#items + 1] = setting_toggle("One boss for both", "share_jack_fight", true, true,
        "On: Jack in the morgue and Mia are one for all of you, run by the game of whoever is nearer, so they go for any of you. Off: each game runs its own; health and defeat are shared.")
    items[#items + 1] = setting_toggle("One Molded for both", "share_molded_moves", true, true,
        "On: each Molded is one for all of you, run by the game of whoever is nearer, so it's in the same place on every screen and goes for any of you. Off: each game runs its own; health and deaths are shared.")
    items[#items + 1] = setting_toggle("Molded go after any of you", "share_molded_target", true, true,
        "With \"One Molded for both\" off: a Molded that's fighting goes for whichever of you is nearest, in every game, so it chases the same person on both screens.")
    items[#items + 1] = setting_toggle("Bump into your friend", "bump_friend", true, false,
        "Lets go in scripted scenes and when you're stuck.")
    items[#items + 1] = setting_toggle("Follow your friend into VHS tapes", "follow_tapes", true, false)
    items[#items + 1] = setting_toggle("Heal your friend", "heal_friend", false, false,
        "Use a healing item next to them: it heals them, not you.")
    items[#items + 1] = setting_toggle("Show your friend's weapon", "show_weapon", true, false, nil,
        function() if show_friend_weapon_again then pcall(show_friend_weapon_again) end end)
    items[#items + 1] = setting_toggle("Hide your friend on ladders", "hide_on_ladders", false, false, "Your friend climbs with the game's own ladder animation; on hides them instead.")
    items[#items + 1] = setting_toggle("Nameplate over your friend", "nameplate", true, false)
    items[#items + 1] = setting_toggle("Friend's footsteps", "footsteps", true, false)
    items[#items + 1] = setting_toggle("Your friend's voice", "friend_voice", true, false,
        "Their grunts when they're hit, block or land, their scream if they die, getting back up.")
    items[#items + 1] = setting_toggle("Your friend's flashlight (experimental)", "friend_light", false, false,
        "In the dark, their flashlight shines where they look (once your own has been on).")
    items[#items + 1] = setting_toggle("One game leads the story", "story_follow_host", true, true,
        "The host's story scenes play for everyone wherever you are, and the host's progress counts for all; the same for everyone.")
    items[#items + 1] = setting_toggle("Enemies chase both players", "enemy_chase_both", true, true,
        "Up close, an enemy turns on whichever of you is nearer (its game changes to that player's); the same for everyone.")
    items[#items + 1] = setting_toggle("On-screen status", "hud", true, false)
    do
        local cur = 1
        for i, k in ipairs(MENU_KEYS) do if k.vk == menu_key().vk then cur = i end end
        local function pick(d)
            local ni = ((cur - 1 + d) % #MENU_KEYS) + 1
            if settings then settings.menu_key = MENU_KEYS[ni].vk if save_settings then pcall(save_settings) end end
        end
        items[#items + 1] = { text = "Key for this menu", value = menu_key().name, left = function() pick(-1) end,
            right = function() pick(1) end, on = function() pick(1) end,
            hint = "If it's also REFramework's menu key, pick another. L3+R3 on a controller always works." }
    end
    local s = settings or {}
    items[#items + 1] = { text = "Allow saving", value = s.allow_saving and "On" or "Off",
        on = function()
            if s.allow_saving then
                s.allow_saving = false
                if save_settings then pcall(save_settings) end
                say("Saving is off: progress from now on isn't kept")
            else
                ask("Switch saving on? Your RE7 saves are backed up first; Steam Cloud shares them with your normal install.",
                    "Switch it on", function()
                        s.allow_saving = true
                        if save_settings then pcall(save_settings) end
                        command("backup allow")
                        say("Saving is on (your saves were backed up)", 0xFF7FFF8C)
                    end)
            end
        end,
        hint = "Off by default. A chapter jump switches it off again." }
    return "Options", items
end

function PAGES.help()
    local items = {}
    local m1 = member(1)
    local elsewhere = m1 and m1.fresh and m1.chapter and m1.chapter ~= my_chapter()
    items[#items + 1] = { text = "Teleport to your friend", on = function()
        local ok = teleport_to_friend and safe(teleport_to_friend)
        say(join and join.msg or (ok and "teleported" or "can't teleport"))
    end, hint = "When you're close (up to 40 m) and got separated." }
    items[#items + 1] = { text = "Go to your friend's chapter", off = (not elsewhere) and "you're in the same chapter (or no friend connected)" or nil,
        on = function() ask("Go to the start of your friend's chapter? Saving switches off for the jump.", "Go", function()
            if join_friend then pcall(join_friend) end
            say(join and join.msg or "")
            set_open(false)
        end) end, hint = "Starts that chapter from its beginning." }
    items[#items + 1] = { text = "Catch up with your friend", on = function()
        if coop_talk_catch_up_now then pcall(coop_talk_catch_up_now) end
        say("Sent and asked for every change (doors, drawers, pickups...)")
    end, hint = "Sends your changes to the world again, and asks for theirs." }
    items[#items + 1] = { text = "Fast-forward this cutscene", off = not (local_cutscene and safe(local_cutscene)) and "no cutscene is playing" or nil,
        on = function() if fast_forward then pcall(fast_forward, true) end set_open(false) end,
        hint = "Plays it 8 times faster; nothing is skipped." }
    items[#items + 1] = { text = "Fix your friend's character", on = function()
        if build_ethan then pcall(build_ethan) end
        say("Rebuilding your friend's character")
    end, hint = "If they look wrong or frozen." }
    items[#items + 1] = { text = "Make a bug report", on = function()
        command("report")
        if coop_talk_report_both then pcall(coop_talk_report_both) end
        say("Making a bug report: a zip appears on your desktop (your friend's game makes one too)", 0xFF7FFF8C)
    end, hint = "Do it right after something goes wrong." }
    if #members() > 0 then
        items[#items + 1] = { text = "Disconnect from everyone", on = function() ask("Disconnect from everyone?", "Disconnect", function()
            if L.state ~= nil and i_host() then lobby_close("you left") end
            leave_all()
            say("Disconnected")
        end) end, hint = "Leaves the session; your friends are told at once." }
    end
    items[#items + 1] = { text = "How co-op works", on = function() go_page("welcome") end }
    items[#items + 1] = { text = "Reload your last save", on = function() ask("Load your last save? Unsaved progress is lost.", "Load it", function()
        if request_reload then pcall(request_reload) end
        say(reload_msg or "Loading your last save...")
        set_open(false)
    end) end }
    return "Help and fixes", items
end

local function current_items()
    if M.confirm then
        local c = M.confirm
        return "Are you sure?", {
            { info = true, text = c.question, color = 0xFFFFFFFF },
            { text = c.yes, on = function() M.confirm = nil pcall(c.fn) end },
            { text = "Cancel", on = function() M.confirm = nil end },
        }, true
    end
    -- "Close" highlighted on sheet A (it has no page; v0.41 drew the lobby there and then failed
    -- every frame on the missing page name).
    if M.page == nil then
        return "Close", { { info = true, text = "Back to the game: Enter, or " .. menu_key().name .. ".", color = 0xFF969696 } }
    end
    local fn = PAGES[M.page] or PAGES[CATS[M.cat or 1].page] or PAGES.lobby
    local ok, title, items = pcall(fn)
    if not ok then
        log("page ERR " .. tostring(title))
        M.page, M.stack, M.focus = CATS[M.cat or 1].page, {}, "A"
        return "Co-op", { { info = true, text = "Something went wrong on that page (see coop_menu_log.txt)" } }
    end
    return title, items
end

-- Drawing (v0.41): two sheets of paper on the desk, like the game's Options and Extra Content.
local PAPER = { dim = 0xC8000000, paper = 0xFFC2D0D5, paper_edge = 0xFF8C9FA9, rule = 0xFF8E9AA0, ink = 0xFF1E2021,
    faint = 0xFF5E676D, off = 0xFF88939B, bar = 0xFF2F3133, bar_text = 0xFFE2E9EE, bar_dim = 0xFF66717A, letter = 0xFF2C3033 }
-- Item colours are picked for a dark screen: on paper, the same meaning in ink.
local INK = { [0xFF7FFF8C] = 0xFF2E6A24, [0xFF7FE6FF] = 0xFF105E95, [0xFF6B6BFF] = 0xFF2020A8, [0xFFFFFFFF] = 0xFF242729,
    [0xFF969696] = 0xFF5E676D, [0xFF6E6E6E] = 0xFF88939B, [0xFFE6E6E6] = 0xFF242729 }
local ON_BAR = { [0xFF7FFF8C] = 0xFF98E89A, [0xFF7FE6FF] = 0xFF7CCBF2, [0xFF6B6BFF] = 0xFF9090FF }
local function ink(c, on_bar)
    if c == nil then return on_bar and PAPER.bar_text or PAPER.ink end
    if on_bar then return ON_BAR[c] or PAPER.bar_text end
    return INK[c] or c
end

local function screen()
    local w, h = 1920, 1080
    local ok, size = pcall(imgui.get_display_size)
    if ok and size and size.x and size.x > 0 then w, h = size.x, size.y end
    return w, h
end

-- The paper (v0.46), like the game's Options and Extra Content sheets: old paper lying a little
-- crooked on the table, faint stains, darker towards the edges, and the form printed at the top
-- (the letter in its box, Date / N.R., Source with Mono and Stereo boxes, and No.).
local function corners(x, y, w, h, deg)
    local cx, cy, a = x + w / 2, y + h / 2, math.rad(deg or 0)
    local ca, sa = math.cos(a), math.sin(a)
    local function p(px, py) local dx, dy = px - cx, py - cy return cx + dx * ca - dy * sa, cy + dx * sa + dy * ca end
    local x1, y1 = p(x, y) local x2, y2 = p(x + w, y) local x3, y3 = p(x + w, y + h) local x4, y4 = p(x, y + h)
    return x1, y1, x2, y2, x3, y3, x4, y4
end
local function paper_quad(x, y, w, h, deg, c)
    local x1, y1, x2, y2, x3, y3, x4, y4 = corners(x, y, w, h, deg)
    if draw.filled_quad then pcall(draw.filled_quad, x1, y1, x2, y2, x3, y3, x4, y4, c)
    else pcall(draw.filled_rect, x, y, w, h, c) end
end
local STAINS = {}
local function stains_for(letter)
    if STAINS[letter] then return STAINS[letter] end
    local seed = letter == "A" and 7 or 13
    local function rnd() seed = (seed * 1103515245 + 12345) % 2147483648 return seed / 2147483648 end
    local s = {}
    for _ = 1, 6 do
        local cx, cy, r, a = rnd(), rnd(), 0.025 + rnd() * 0.06, 0x07 + math.floor(rnd() * 0x07)
        for _ = 1, 3 do s[#s + 1] = { cx, cy, r * (0.55 + rnd() * 0.5), a, false, (rnd() - 0.5) * r * 1.3, (rnd() - 0.5) * r * 1.3 } end
    end
    for _ = 1, 14 do s[#s + 1] = { rnd(), rnd(), 0.0015 + rnd() * 0.003, 0x28 + math.floor(rnd() * 0x28), true, 0, 0 } end
    STAINS[letter] = s
    return s
end
local function sheet(x, y, w, h, letter, tilt)
    paper_quad(x + 7, y + 9, w, h, tilt, 0x70000000)      -- its shadow on the table
    paper_quad(x, y, w, h, tilt, PAPER.paper)
    for _, st in ipairs(stains_for(letter)) do           -- stains and specks, kept on the paper
        local r = st[3] * w
        local cx = x + 10 + r + st[1] * (w - 20 - 2 * r) + st[6] * w
        local cy = y + 10 + r + st[2] * (h - 20 - 2 * r) + st[7] * w
        cx = math.max(x + r + 6, math.min(x + w - r - 6, cx))
        cy = math.max(y + r + 6, math.min(y + h - r - 6, cy))
        local col = (st[4] << 24) | (st[5] and 0x2A3440 or 0x3E6E92)
        if draw.filled_circle then pcall(draw.filled_circle, cx, cy, r, col, st[5] and 8 or 28) end
    end
    for k = 1, 3 do                                       -- darker towards the edges
        local t, c = 3 + 5 * k, 0x0D3C5F78
        pcall(draw.filled_rect, x + 3, y + 3, w - 6, t, c)
        pcall(draw.filled_rect, x + 3, y + h - 3 - t, w - 6, t, c)
        pcall(draw.filled_rect, x + 3, y + 3 + t, t, h - 6 - 2 * t, c)
        pcall(draw.filled_rect, x + w - 3 - t, y + 3 + t, t, h - 6 - 2 * t, c)
    end
end
-- The printed form at the top of a sheet; returns where the sheet's own lines start.
local function form_header(x, y, w, letter, number)
    local s = line_h("small")
    local bsz = line_h("big") + 12
    for k = 0, 2 do pcall(draw.outline_rect, x + 24 + k, y + k, bsz - 2 * k, bsz - 2 * k, PAPER.letter) end
    text(letter, x + 24 + (bsz - text_w(letter, "big")) / 2, y + (bsz - line_h("big")) / 2 + 2, PAPER.letter, "big")
    local fx, nx = x + 24 + bsz + 18, x + w - 100
    local mid = fx + (nx - 16 - fx) * 0.55
    local y1, y2 = y + 2, y + 2 + s + 8
    local function blank(label, lx, ly, to)
        text(label, lx, ly, PAPER.faint, "small")
        pcall(draw.line, lx + text_w(label .. " ", "small"), ly + s - 2, to, ly + s - 2, PAPER.rule)
    end
    blank("Date", fx, y1, mid - 12)
    blank("N.R.:", mid, y1, nx - 16)
    blank("Source", fx, y2, mid - 12)
    local mx = mid
    for _, lab in ipairs({ "Mono", "Stereo" }) do
        local bx2 = mx + text_w(lab .. " ", "small")
        if bx2 + s < nx - 8 then
            text(lab, mx, y2, PAPER.faint, "small")
            pcall(draw.outline_rect, bx2, y2 + 3, s - 6, s - 6, PAPER.faint)
        end
        mx = bx2 + s + 10
    end
    pcall(draw.outline_rect, nx, y - 2, 76, bsz + 4, PAPER.rule)
    text("No.", nx + 8, y + 2, PAPER.faint, "small")
    if number then text(tostring(number), nx + 8, y + 4 + s, PAPER.ink, "small") end
    return y + bsz + 10
end

local function draw_paper(title, items, is_confirm)
    local w, h = screen()
    local hit = { a = {}, b = {}, more = {} }   -- v0.43: where the rows are, for the mouse
    M.hit = hit
    -- On the Options table (title screen) the table shows; elsewhere a dark cover over the game.
    pcall(draw.filled_rect, 0, 0, w, h, M.table_mode and 0x30000000 or PAPER.dim)
    -- Sheet A: the sections.
    local ax, ay = math.floor(w * 0.07), math.floor(h * 0.12)
    local aw, ah = math.floor(w * 0.29), math.floor(h * 0.72)
    sheet(ax, ay, aw, ah, "A", -0.45)
    local head = "Molded Together"
    text(head, ax + (aw - text_w(head, "big")) / 2, ay + 20, PAPER.ink, "big")
    local y = form_header(ax, ay + 20 + line_h("big") + 12, aw, "A", kv().version) + 16
    pcall(draw.line, ax + 24, y - 10, ax + aw - 24, y - 10, PAPER.rule)
    local lh = line_h("body")
    for i, c in ipairs(CATS) do
        local chosen = i == (M.cat or 1)
        if chosen then
            pcall(draw.filled_rect, ax + 40, y - 4, aw - 80, lh, M.focus == "A" and PAPER.bar or PAPER.bar_dim)
        end
        text(c.label, ax + 56, y, chosen and PAPER.bar_text or PAPER.ink)
        pcall(draw.line, ax + 40, y + lh - 4, ax + aw - 40, y + lh - 4, PAPER.rule)
        hit.a[#hit.a + 1] = { ax + 40, y - 4, ax + aw - 40, y - 4 + lh, i }
        y = y + lh
    end
    -- Who you're playing with, and an invite, at the foot of sheet A.
    local foot = {}
    local inv = pending_invite and safe(pending_invite)
    if inv then foot[#foot + 1] = { inv.name .. " invited you: Friends", 0xFF7FFF8C } end
    foot[#foot + 1] = { party_line(), #linked_members() > 0 and 0xFF7FFF8C or 0xFF969696 }
    local fy = ay + ah - 24 - line_h("small") * #foot
    for _, f in ipairs(foot) do
        text(fit(f[1], aw - 60, "small"), ax + 30, fy, ink(f[2]), "small")
        fy = fy + line_h("small")
    end
    -- Sheet B: the section's page.
    local bx, by = math.floor(w * 0.385), math.floor(h * 0.09)
    local bw, bh = math.floor(w * 0.545), math.floor(h * 0.78)
    sheet(bx, by, bw, bh, "B", -0.25)
    local ty = form_header(bx, by + 22, bw, "B", nil) + 4
    text(fit(title, bw - 120, "big"), bx + 46, ty, PAPER.ink, "big")
    local top = ty + line_h("big") + 14
    pcall(draw.line, bx + 24, top - 8, bx + bw - 24, top - 8, PAPER.rule)
    local selectable = {}
    for i, it in ipairs(items) do if not it.info then selectable[#selectable + 1] = i end end
    local pkey = M.page or "close"
    local key = is_confirm and "confirm" or pkey
    local sel = (is_confirm and M.confirm.sel) or M.sel[pkey] or 1
    if #selectable > 0 then sel = math.max(1, math.min(sel, #selectable)) end
    if is_confirm then M.confirm.sel = sel else M.sel[pkey] = sel end
    local active = M.focus == "B" or is_confirm
    local chosen = active and selectable[sel] or nil
    local area = (by + bh - 30) - top
    local fit_n = math.max(1, math.floor(area / lh))
    local first = M.scroll[key] or 1
    local sidx = {}
    for k, i in ipairs(selectable) do sidx[i] = k end
    hit.page_n, hit.sel_n = fit_n, #selectable
    if chosen then
        if chosen < first then first = chosen end
        if chosen > first + fit_n - 1 then first = chosen - fit_n + 1 end
    end
    if first > math.max(1, #items - fit_n + 1) then first = math.max(1, #items - fit_n + 1) end
    M.scroll[key] = first
    y = top
    local value_x = bx + math.floor(bw * 0.58)
    for i = first, math.min(#items, first + fit_n - 1) do
        local it = items[i]
        local on_bar = i == chosen
        if on_bar then pcall(draw.filled_rect, bx + 30, y - 4, bw - 60, lh, PAPER.bar) end
        local color = it.off and PAPER.off or ink(it.color or (it.info and 0xFF969696 or nil), on_bar)
        if on_bar and it.off then color = 0xFFA6AFB5 end
        local left_w = it.value and (value_x - (bx + 46) - 16) or (bw - 92)
        text(fit(it.text, left_w), bx + 46, y, color)
        if it.value then
            local vc = it.off and PAPER.off or (on_bar and PAPER.bar_text or PAPER.faint)
            if it.left or it.right then
                -- Like the game's Options: "<" and ">" at the ends, the value in the middle.
                local lx, rx = value_x, bx + bw - 66
                text("<", lx, y, vc)
                text(">", rx, y, vc)
                local v = fit(it.value, rx - lx - 44)
                text(v, (lx + rx) / 2 - text_w(v) / 2 + 6, y, vc)
            else
                text(fit(it.value, bx + bw - 46 - value_x), value_x, y, vc)
            end
        end
        if not it.info then
            pcall(draw.line, bx + 30, y + lh - 4, bx + bw - 30, y + lh - 4, PAPER.rule)
            -- A click: Enter on the row, or Right where Right is all it has.
            hit.b[#hit.b + 1] = { bx + 30, y - 4, bx + bw - 30, y - 4 + lh, i, sidx[i],
                it.on ~= nil or it.off ~= nil or it.right == nil }
        end
        y = y + lh
    end
    if #items > fit_n then
        local more = (first > 1 and "more above  " or "") .. (first + fit_n - 1 < #items and "more below" or "")
        text(more, bx + bw - 40 - text_w(more, "small"), by + bh - 28 - line_h("small"), PAPER.faint, "small")
        local mx, my, sh = bx + bw - 40 - text_w(more, "small"), by + bh - 28 - line_h("small"), line_h("small")
        if first > 1 then hit.more[#hit.more + 1] = { mx - 6, my - 4, mx + text_w("more above", "small") + 6, my + sh, -1 } end
        if first + fit_n - 1 < #items then
            local x0 = mx + (first > 1 and text_w("more above  ", "small") or 0)
            hit.more[#hit.more + 1] = { x0 - 6, my - 4, mx + text_w(more, "small") + 6, my + sh, 1 }
        end
        -- The game's scroll bar: a black bar down the right edge, its length the part in view.
        local sx, st0, sb = bx + bw - 28, top - 4, top - 4 + fit_n * lh
        pcall(draw.line, sx, st0, sx, sb, PAPER.rule)
        local th = math.max(24, (sb - st0) * fit_n / #items)
        local sy = st0 + (sb - st0 - th) * (first - 1) / math.max(1, #items - fit_n)
        pcall(draw.filled_rect, sx - 3, sy, 6, th, 0xFF1C1C1C)
    end
    -- Under the sheets, like the game's own line: what the highlighted thing does, then the keys.
    local it = chosen and items[chosen]
    local hint
    if M.focus == "A" and not is_confirm then
        local c = CATS[M.cat or 1]
        hint = c.page == nil and "Back to the game." or ("Open " .. c.label .. ".")
    else
        hint = it and ((it.off and ("Not now: " .. it.off)) or it.hint) or ""
    end
    local hint_color = 0xFFE6E6E6
    if M.msg and os.clock() - M.msg_t < 6 then hint, hint_color = M.msg, M.msg_color end
    hint = fit(hint or "", w - 120)
    local gy = by + bh + 26
    -- The game's prompt band under the sheets.
    pcall(draw.filled_rect, 0, gy - 12, w, line_h("body") + line_h("small") + 24, 0x99000000)
    text(hint, (w - text_w(hint)) / 2 + 1, gy + 1, 0xC0000000)
    text(hint, (w - text_w(hint)) / 2, gy, hint_color)
    local controls = (M.focus == "A" and not is_confirm)
        and ("Up/Down: choose    Right / Enter / F / A: open    Esc / B: close    " .. menu_key().name .. " / L3+R3: close")
        or "Up/Down: choose    Left/Right: change    Enter / F / A: select    Esc / Backspace / B: back"
    local mo = M.mouse
    if mo and os.clock() - (mo.t or -100) < 20 then
        controls = "Mouse: point to choose    Click: select    Right click: back    (the keys and the controller work too)"
    end
    controls = fit(controls, w - 120, "small")
    text(controls, (w - text_w(controls, "small")) / 2, gy + line_h("body"), 0xFFBFBFBF, "small")
    -- A pointer while the mouse is in use (the game may hide its own).
    if mo and mo.x and os.clock() - (mo.t or -100) < 4 then
        pcall(draw.filled_circle, mo.x, mo.y, 6, 0xFFFFFFFF, 16)
        pcall(draw.outline_circle, mo.x, mo.y, 7, 0xFF000000, 16)
    end
end

-- The CO-OP row on the title screen's tape recorder (v0.41, worked out live 2026-11-09). The
-- title menu (app.TitleSubMenu on GUI_menu) lists its rows from _StepParam; its scroll list
-- (_MainList._Element, a via.gui.ScrollList) shows ItemMax of them, three at a time, each slot
-- (item1..3, and selectitem for the highlight) telling which row it shows by ListIndex and
-- writing it through its m_name Text. One more StepParam (step Main: the game does nothing when
-- it's picked) and one more ItemMax give an eighth row; the slot showing it gets the text
-- "CO-OP", and a slot that scrolls on gets its own text back (the literal text cleared, the
-- row's message id set again). Picking it (Enter, A) opens this menu.
local TITLE = { idx = nil, menu_addr = nil, marked = {}, fix = {}, broken = false, t = -100 }
-- Every component of a type in the scene, or nil when the list can't be read. On the title screen the
-- list often comes back without get_elements (every time in the test copies, 2026-11-12): read that
-- as "no title menu" and the CO-OP row lost its text (the blank line people saw), so it's read by
-- get_Count / get_Item then, and a list that can't be read at all keeps the menu we had.
local function comp_list(tn)
    local sc = sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"), sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
    if sc == nil then return nil end
    for _ = 1, 3 do
        local ok, arr = pcall(sc.call, sc, "findComponents(System.Type)", sdk.typeof(tn))
        if ok and arr ~= nil then
            local ok2, l = pcall(function() return arr:get_elements() end)
            if ok2 and l then return l end
            local ok3, n = pcall(arr.call, arr, "get_Count")
            if ok3 and type(n) == "number" then
                local out = {}
                for i = 0, n - 1 do
                    local it = safe(arr.call, arr, "get_Item", i)
                    if it then out[#out + 1] = it end
                end
                return out
            end
        end
    end
    return nil
end
local function title_menu()
    local now = os.clock()
    if TITLE.menu and now - TITLE.t < 2 then return TITLE.menu end
    TITLE.t = now
    local list = comp_list("app.TitleSubMenu")
    if list == nil then return TITLE.menu end   -- unreadable this time: keep what we had
    TITLE.menu = nil
    for _, t in ipairs(list) do
        local go = safe(t.call, t, "get_GameObject")
        if go and safe(go.call, go, "get_Name") == "GUI_menu" then
            TITLE.menu = t
            local gui = safe(go.call, go, "getComponent(System.Type)", sdk.typeof("via.gui.GUI"))
            TITLE.gui_addr = gui and safe(gui.get_address, gui) or nil
        end
    end
    return TITLE.menu
end
local function texts_of(item)
    local key = tostring(safe(item.get_address, item)) .. "/" .. tostring(safe(item.call, item, "get_Name"))
    TITLE.texts = TITLE.texts or {}
    if TITLE.texts[key] then return TITLE.texts[key] end
    local out = {}
    local function walk(e, depth)
        local c = safe(e.call, e, "get_Child")
        local n = 0
        while c and n < 40 do
            n = n + 1
            if tostring(safe(c.call, c, "get_Name")) == "m_name" then out[#out + 1] = c end
            if depth < 4 then walk(c, depth + 1) end
            c = safe(c.call, c, "get_Next")
        end
    end
    walk(item, 1)
    TITLE.texts[key] = out
    return out
end
-- The text, on whichever slot shows our row; the others get theirs back.
-- "Scrolling turns everything to New Game" (2026-11-11): while the list scrolls, a slot's ListIndex
-- passes through other rows for a few frames, and the slot that had shown CO-OP was given back the text
-- of whatever row it read then (often row 0, NEW GAME), which the game didn't redo until the next scroll.
-- Now the CO-OP text comes off at once, and the slot's own text is put back only once the list has stood
-- still for a few frames, from the row it settled on (and checked again on every settled frame).
local SETTLE_SEC = 0.12
local function title_texts()
    local sl, steps = TITLE.sl, TITLE.steps
    if sl == nil or steps == nil or TITLE.idx == nil then return end
    local items = sl:call("get_Items")
    local n_items = items:call("get_Count")
    -- Has the list stood still? (every slot's row and the scroll position as last frame)
    local sig = { tostring(safe(sl.call, sl, "get_ScrollIndex")), tostring(safe(sl.call, sl, "get_SelectedIndex")) }
    local slots = {}
    for i = 0, n_items - 1 do
        local it = items:call("get_Item", i)
        local li = it:call("get_ListIndex")
        slots[#slots + 1] = { it = it, slot = it:call("get_Name"), li = li }
        sig[#sig + 1] = tostring(li)
    end
    local s = table.concat(sig, ",")
    local now = os.clock()
    if s ~= TITLE.sig then TITLE.sig, TITLE.still = s, now end
    local settled = now - (TITLE.still or now) >= SETTLE_SEC
    local n_steps = steps:call("get_Count")
    for _, x in ipairs(slots) do
        local li, slot = x.li, x.slot
        for _, t in ipairs(texts_of(x.it)) do
            if li == TITLE.idx then
                if t:call("get_Message") ~= "CO-OP" then t:call("set_Message", "CO-OP") end
                TITLE.marked[slot], TITLE.fix[slot] = true, nil
            else
                if TITLE.marked[slot] then
                    pcall(t.call, t, "set_Message", nil)   -- off at once
                    TITLE.fix[slot] = true                  -- its own text when the list settles
                end
                if settled and TITLE.fix[slot] then
                    local sp = (li and li >= 0 and li < n_steps) and steps:call("get_Item", li) or nil
                    if sp then pcall(t.call, t, "set_MessageId", sp:get_field("ElemMsgID")) end
                end
            end
        end
        if li ~= TITLE.idx then TITLE.marked[slot] = nil end
        if settled and li ~= TITLE.idx then TITLE.fix[slot] = nil end
    end
end
if re and re.on_pre_gui_draw_element then
    re.on_pre_gui_draw_element(function(element)
        if TITLE.idx ~= nil and TITLE.gui_addr ~= nil and not TITLE.broken then
            local ok, a = pcall(element.get_address, element)
            if ok and a == TITLE.gui_addr then
                local tok, terr = pcall(title_texts)
                if not tok and not TITLE.draw_err then TITLE.draw_err = true log("title text ERR " .. tostring(terr)) end
            end
        end
        return true
    end)
end
local function title_row(now)
    TITLE.selected = false
    if TITLE.broken or (settings and settings.title_coop_row == false) then return end
    if not on_title() then TITLE.idx, TITLE.menu = nil, nil return end
    local tsm = title_menu()
    if tsm == nil then TITLE.idx = nil return end
    local addr = tsm:get_address()
    local steps = tsm:get_field("_StepParam")
    local cache = tsm:get_field("_MainList")
    local sl = cache and cache:get_field("_Element")
    if steps == nil or sl == nil then return end
    if TITLE.menu_addr ~= addr then
        TITLE.menu_addr, TITLE.idx, TITLE.marked, TITLE.seen_n, TITLE.moves, TITLE.texts = addr, nil, {}, nil, 0, {}
        TITLE.fix, TITLE.sig, TITLE.still = {}, nil, nil
    end
    -- Ours, if it's there already (it stays in the list after a reset of scripts).
    local n = steps:call("get_Count")
    local imax = sl:call("get_ItemMax")
    local mine
    for i = 0, n - 1 do
        local sp = steps:call("get_Item", i)
        if sp and tostring(sp:get_field("GUIElemName")) == "coop" then mine = i end
    end
    if mine == nil then
        -- v0.43: only once the game has finished its list and left it alone for a second. v0.41
        -- and v0.42 added CO-OP while the game was still filling it ("added as row 7 of 7"; the
        -- game has 7 rows of its own): CO-OP sat in EXIT's place and the last line was blank.
        if TITLE.seen_n ~= n or TITLE.seen_max ~= imax then
            TITLE.seen_n, TITLE.seen_max, TITLE.seen_t = n, imax, now
            TITLE.idx = nil
            return
        end
        if now - TITLE.seen_t < 1.0 or imax ~= n or n == 0 then
            if now - TITLE.seen_t > 10 and not TITLE.wait_logged then
                TITLE.wait_logged = true
                log(string.format("title row: waiting for the list (%d rows, ItemMax %d)", n, imax))
            end
            TITLE.idx = nil
            return
        end
        local sp = sdk.create_instance("app.TitleSubMenu.StepParam", true)
        if sp == nil then TITLE.broken = true log("title row: couldn't make a row") return end
        pcall(sp.add_ref, sp)
        sp:set_field("Step", 0)
        local name = sdk.create_managed_string("coop")
        if name and name.add_ref then pcall(name.add_ref, name) end
        sp:set_field("GUIElemName", name)
        steps:call("Add", sp)
        sl:call("set_ItemMax", imax + 1)
        TITLE.keep = { sp, name }
        mine, n = n, n + 1
        log(string.format("title row: CO-OP added as row %d of %d", n, n))
    elseif mine ~= n - 1 and (TITLE.moves or 0) < 3 then
        -- Rows came after ours (the list was still filling, or v0.42 put it there): ours goes
        -- back to the end, so EXIT is EXIT again. Only if the removal really took (no copies).
        TITLE.moves = (TITLE.moves or 0) + 1
        local sp = steps:call("get_Item", mine)
        local ok = pcall(steps.call, steps, "RemoveAt", mine)
        if ok and steps:call("get_Count") == n - 1 then
            steps:call("Add", sp)
            log(string.format("title row: CO-OP moved from row %d to the end (row %d)", mine + 1, n))
            mine = n - 1
            TITLE.keep = { sp, TITLE.keep and TITLE.keep[2] }
        else
            TITLE.moves = 3
            log("title row: couldn't move CO-OP to the end")
        end
    end
    -- The game set its row count again without ours: count ours back in.
    if mine == n - 1 and sl:call("get_ItemMax") == n - 1 then sl:call("set_ItemMax", n) end
    TITLE.idx = mine
    TITLE.sl, TITLE.steps = sl, steps
    title_texts()
    TITLE.selected = sl:call("get_SelectedIndex") == TITLE.idx and tsm:get_field("IsMainListControl") == true
end

-- On the title screen the co-op screen goes on the Options table (v0.43): the title menu's own
-- camera move there and back (app.TitleSubMenu.changeMotionCamera: VoiceRecorder_to_Option 2,
-- Optin_to_VoiceRecorder 3; tried live 2026-11-09), with the sheets drawn on the table.
local function title_table(on)
    local tsm = title_menu()
    if on then
        if tsm == nil then return end
        if pcall(tsm.call, tsm, "changeMotionCamera", 2) then
            M.table_mode = true
            log("title: camera to the Options table")
        end
    elseif M.table_mode then
        M.table_mode = false
        if tsm and on_title() then
            pcall(tsm.call, tsm, "changeMotionCamera", 3)
            log("title: camera back to the tape recorder")
        end
    end
end

-- The title-screen and in-game prompts, while the menu is closed.
local function draw_prompts(now)
    if settings and settings.hud == false then return end
    local w, h = screen()
    local lines = {}
    local inv = pending_invite and safe(pending_invite)
    local how = (on_title() and TITLE.idx) and "choose CO-OP" or ("press " .. menu_key().name)
    if inv then lines[#lines + 1] = { inv.name .. (inv.lobby and " invited you to their lobby" or " invited you to co-op") .. ": " .. how .. " to answer", 0xFF7FFF8C } end
    if L.state == "open" and not i_host() and not L.ready then
        lines[#lines + 1] = { host_name() .. "'s lobby is waiting: " .. how .. " to get ready", 0xFF7FFF8C }
    end
    if i_host() and L.state == "open" and #members() > 0 and start_blocker() == nil then
        lines[#lines + 1] = { "Everyone's ready: " .. how .. ", then Start", 0xFF7FFF8C }
    end
    if on_title() then
        if TITLE.selected then
            -- Our row has no description of the game's: ours, where the game writes its own.
            local d = "Play with your friends: host or join a lobby."
            text(d, (w - text_w(d)) / 2 + 1, h * 0.927 + 1, 0xC0000000)
            text(d, (w - text_w(d)) / 2, h * 0.927, 0xFFE6E6E6)
        elseif TITLE.idx == nil then
            lines[#lines + 1] = { "Molded Together: press " .. menu_key().name .. " (or L3+R3 on a controller) for the co-op menu", 0xFFE6E6E6 }
        end
    elseif (M.first_hint_until or 0) > now then
        lines[#lines + 1] = { "Molded Together: " .. menu_key().name .. " or L3+R3 opens the co-op menu", 0xFFBFBFBF }
    end
    if #lines == 0 then return end
    local lh = line_h("small")
    local y = h - 40 - lh * #lines
    for i, l in ipairs(lines) do
        local tw = text_w(l[1], "small")
        pcall(draw.filled_rect, 24, y + (i - 1) * lh - 4, tw + 24, lh, 0xA0000000)
        text(l[1], 36, y + (i - 1) * lh, l[2], "small")
    end
end

-- The mouse (v0.43). Pointing at a row highlights it, but only when the mouse moves, so it never
-- fights the keys or the controller; a left click picks it (like Enter / A), a right click goes
-- back (like Backspace / B). Where the rows are comes from the last frame's drawing (M.hit).
M.mouse = { t = -100, down = false, rdown = false }
local function read_mouse(now)
    local out, mo = {}, M.mouse
    if not (imgui and imgui.get_mouse) then return out end
    local ok, p = pcall(imgui.get_mouse)
    if not ok or (type(p) ~= "table" and type(p) ~= "userdata") then return out end
    local pok, px, py = pcall(function() return p.x, p.y end)
    if not pok or type(px) ~= "number" or type(py) ~= "number" then return out end
    p = { x = px, y = py }
    -- v0.48: while we hold the game's pointer (in play), where the game says it is.
    if M.lock and M.lock.cursor and M.lock_hid then
        local gok, gx, gy = pcall(function()
            local q = M.lock_hid:call("get_mouseScreenPoint")
            return q.x, q.y
        end)
        if gok and type(gx) == "number" and type(gy) == "number" and (gx ~= 0 or gy ~= 0) then p = { x = gx, y = gy } end
    end
    local w, h = screen()
    if p.x < 0 or p.y < 0 or p.x > w or p.y > h then return out end   -- outside the game's window
    if mo.x == nil then mo.x, mo.y = p.x, p.y end
    if math.abs(p.x - mo.x) > 3 or math.abs(p.y - mo.y) > 3 then
        out.moved = true
        mo.x, mo.y, mo.t = p.x, p.y, now
    end
    out.x, out.y = p.x, p.y
    local function button(i, vk)
        if imgui.is_mouse_down then
            local bok, v = pcall(imgui.is_mouse_down, i)
            if bok and v ~= nil then return v == true end
        end
        return key_down(vk)
    end
    local d, rd = button(0, 0x01), button(1, 0x02)
    out.click, out.rclick = d and not mo.down, rd and not mo.rdown
    mo.down, mo.rdown = d, rd
    if out.click or out.rclick then mo.t = now end
    return out
end
local function mouse_actions(ms, a)
    local hit = M.hit
    if hit == nil or ms.x == nil or not (ms.moved or ms.click or ms.rclick) then return end
    if ms.rclick then a.back = true return end
    local function inside(r) return ms.x >= r[1] and ms.x <= r[3] and ms.y >= r[2] and ms.y <= r[4] end
    -- Sheet A: pointing moves the highlight while sheet A has it; a click opens the section.
    if not M.confirm then
        for _, r in ipairs(hit.a) do
            if inside(r) then
                local i = r[5]
                if ms.click then
                    M.cat = i
                    if CATS[i].page == nil then set_open(false)
                    else M.focus, M.page, M.stack = "B", CATS[i].page, {} end
                elseif M.focus == "A" and M.cat ~= i then
                    M.cat, M.page, M.stack = i, CATS[i].page, {}
                end
                return
            end
        end
    end
    -- Sheet B: the page's rows.
    local key = M.page or "close"
    for _, r in ipairs(hit.b) do
        if inside(r) and r[6] then
            if M.focus == "A" and not M.confirm then
                if CATS[M.cat or 1].page == nil then return end
                M.focus = "B"
            end
            if M.confirm then M.confirm.sel = r[6] else M.sel[key] = r[6] end
            if ms.click then
                if r[7] then a.ok = true else a.right = true end
            end
            return
        end
    end
    -- "more above" / "more below": a page up or down.
    if ms.click then
        for _, r in ipairs(hit.more) do
            if inside(r) then
                local cur = (M.confirm and M.confirm.sel) or M.sel[key] or 1
                local s = math.max(1, math.min(hit.sel_n or 1, cur + r[5] * math.max(1, (hit.page_n or 2) - 1)))
                if M.confirm then M.confirm.sel = s else M.sel[key] = s end
                if M.focus == "A" and not M.confirm then M.focus = "B" end
                return
            end
        end
    end
end

-- Every frame -------------------------------------------------------------------------------
local was_title = nil
re.on_frame(function()
    local now = os.clock()
    local ok, err = pcall(function()
        pump_commands(now)
        pump_lobby(now)
        local pok, perr = pcall(pump_party, now)
        if not pok and not M.party_err then M.party_err = true log("party ERR " .. tostring(perr)) end
        local sok, serr = pcall(pump_stats, now)
        if not sok and not M.stats_err then M.stats_err = true log("stats ERR " .. tostring(serr)) end
        local tok, terr = pcall(title_row, now)
        if not tok then
            TITLE.broken = true
            log("title row ERR (switched off until restart) " .. tostring(terr))
        end
        -- A hint for a while after the game first comes up from the title screen.
        local t = on_title()
        if was_title and not t then M.first_hint_until = now + 20 end
        was_title = t
        -- The REFramework window has the keyboard while it's open.
        local rf_open = reframework and reframework.is_drawing_ui and safe(reframework.is_drawing_ui, reframework) == true
        local a = rf_open and {} or read_actions(now)
        local ms = rf_open and {} or read_mouse(now)
        if a.toggle or a.combo then set_open(not M.open) ms = {}
        elseif not M.open and (a.ok or ms.click) and TITLE.selected then
            set_open(true)   -- picked CO-OP on the tape recorder (Enter, A or a click)
            a, ms = {}, {}
        end
        if M.open and M.open_wanted == false then set_open(false) end
        -- The table on the title screen (once per opening), and back when the screen closes.
        if M.open and not M.table_mode and not M.table_tried and on_title() and not TITLE.broken then
            M.table_tried = true
            pcall(title_table, true)
        end
        if not M.open then
            M.table_tried = nil
            if M.table_mode then pcall(title_table, false) end
        end
        if not M.open then
            -- Watchdog: nothing of ours may stay held while the menu is closed.
            if M.locked then hold_game(false) end
            M.hit = nil
            draw_prompts(now)
            return
        end
        mouse_actions(ms, a)
        if not M.open then return end   -- clicked Close
        if M.focus == "A" and not M.confirm then
            local n = #CATS
            if a.up then M.cat = ((M.cat or 1) - 2) % n + 1 end
            if a.down then M.cat = (M.cat or 1) % n + 1 end
            if a.up or a.down then M.page, M.stack = CATS[M.cat].page, {} end
            if a.right or a.ok then
                if CATS[M.cat].page == nil then set_open(false)
                else M.focus, M.page, M.stack = "B", CATS[M.cat].page, {} end
            elseif a.back then
                set_open(false)
            end
        else
            local title, items, is_confirm = current_items()
            local selectable = {}
            for i, it in ipairs(items) do if not it.info then selectable[#selectable + 1] = i end end
            local pkey = M.page or "close"
            local sel = (is_confirm and M.confirm.sel) or M.sel[pkey] or 1
            if #selectable > 0 then
                if a.up then sel = sel - 1 if sel < 1 then sel = #selectable end end
                if a.down then sel = sel + 1 if sel > #selectable then sel = 1 end end
            end
            if is_confirm then M.confirm.sel = sel else M.sel[pkey] = sel end
            local it = items[selectable[sel] or 0]
            if it and not it.off then
                if a.left and it.left then pcall(it.left) end
                if a.right and it.right then pcall(it.right) end
                if a.ok and it.on then
                    local ok2, e2 = pcall(it.on)
                    if not ok2 then log("item ERR " .. tostring(e2)) end
                end
            elseif it and it.off and a.ok then
                say("Not now: " .. it.off, 0xFF7FE6FF)
            end
            -- Left on a row that changes nothing goes back to sheet A, like the game's own sheets.
            if a.left and (it == nil or it.left == nil) and not is_confirm then back() end
            if a.back then back() end
        end
        if M.open then
            local t2, items2, c2 = current_items()
            draw_paper(t2, items2, c2)
        end
    end)
    -- Each different error once (v0.42: only the first was, so a second kind went unseen).
    if not ok then
        local e = tostring(err)
        M.errs = M.errs or {}
        if not M.errs[e] and (M.errs_n or 0) < 20 then
            M.errs[e], M.errs_n = true, (M.errs_n or 0) + 1
            log("frame ERR " .. e)
        end
    end
end)

-- For the menu test (local/build/harness/menu_test.py): what the current page shows.
function coop_menu_debug_items() return current_items() end
function coop_menu_debug_title() return TITLE end

-- For the Molded Together window and the status line.
function coop_menu_status()
    if L.state == nil then return "Lobby: none (" .. menu_key().name .. " opens the co-op menu)" end
    return string.format("Lobby: %s, host %s, start %s", L.state, host_name(), start_label(L.start))
end

log("coop_menu loaded")
