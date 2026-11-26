-- coop_story.lua: shared story.
-- RE7's story moves on through triggers (areas, items, cutscene ends); the progress
-- numbers only record it (setting one changes nothing in the world). So whoever triggers
-- a story beat leads it: their game sends it, the other game plays the same thing.
--   story <name> <chapter>       a story cutscene started (names like c03e01_00)
--   prog <flow hash> <value> <chapter>   a story stage's progress number went up
--   evend <event hash> <chapter> a story event was marked finished
-- Cutscenes start by name with GameEventManager.requestEvent. Each cutscene plays once per
-- side; progress only ever goes up. Events go through coop_enemies.lua's reliable channel.
--
-- Rules since the first real session (2026-11-02), which showed that pushing a player who
-- is elsewhere breaks their game (a tape ended early, a chapter change stuck, a washed-out
-- picture, the dinner chair skipping ahead):
--   * a friend's cutscene is only played here when we are in the same chapter and within
--     NEAR metres of them; otherwise we see it ourselves when we get there;
--   * progress numbers and finished events are only copied while "in step": for
--     IN_STEP seconds after we were pulled into a cutscene of theirs. Outside that each
--     game keeps its own story.

-- v0.48: this script's frame work waits while the game loads or swaps the player (coop_busy, coop_dummy.lua).
local re = setmetatable({ on_frame = function(f)
    return _G.re.on_frame(function() if coop_busy and coop_busy() then return end return f() end)
end }, { __index = _G.re })

story_sync = {
    played = {},       -- cutscene name -> true (started on this side, by us or the friend)
    applying = {},     -- key -> clock: changes we made on the friend's word (not sent back)
    pending = {},      -- cutscene name -> { ch, t }: friend's cutscene not loaded here yet
    running = {},      -- scene name -> when it started here (v0.39)
    sent = 0, applied = 0, msg = "-", msg_t = -100, pend_t = 0,
}
local ss = story_sync

-- Debug registry (v0.52, coop_dummy.lua): dbg_note describes the callback or hook registered on the next lines, dbg_task
-- gives a function its own row in the Debug section. Both are tail calls so the registry sees this file's line.
local function dbg_note(info) if coop_note then return coop_note(info) end end
local function dbg_task(feature, name, f, info) if coop_task then return coop_task(feature, name, f, info) end return f end

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
-- v0.53: tape scenes too ("c01f01_00", FF000's opening): they were never shared, so the tape's scripted
-- moments ran in each game on its own clock.
local STORY_NAME = "^c%d%d[ef]%d%d_%d%d$"
-- Jack's scripted moments (breaking through the hatch-room wall, 2026-11-02) are events too,
-- named em3000_*; they follow the same rules (same chapter, friend within NEAR).
local SCRIPTED_NAME = "^em3%d%d%d_"
local function is_story_event(name) return name:match(STORY_NAME) ~= nil or name:match(SCRIPTED_NAME) ~= nil end
-- A story scene's sequence and its place in it (v0.39): "c03e00_02" -> "c03e00", 2.
local function seq_of(name)
    local grp, idx = tostring(name):match("^(c%d%d[ef]%d%d)_(%d%d)$")
    return grp, tonumber(idx)
end

-- Cutscenes already played this chapter survive Reset scripts (coop_story_played.json):
-- replaying one the game had finished (the dinner, on the bot's word after a reset) hung
-- it halfway and left the player unable to move. The list starts over on a new chapter.
-- Each entry is the story clock when it played (v0.39; older lists have true): loading an
-- earlier save makes the scenes from after that point count as not played again.
ss.prog_seen, ss.prog_ch = ss.prog_seen or {}, ss.prog_ch
local function save_played()
    local prog = {}
    if ss.prog_ch == ss.played_chapter then for h in pairs(ss.prog_seen) do prog[#prog + 1] = h end end
    pcall(json.dump_file, "coop_story_played.json", { chapter = ss.played_chapter, played = ss.played, prog = prog })
end
do
    local ok, data = pcall(json.load_file, "coop_story_played.json")
    if ok and type(data) == "table" and type(data.played) == "table" then
        ss.played, ss.played_chapter = data.played, data.chapter
        if type(data.prog) == "table" then
            ss.prog_seen, ss.prog_ch = {}, data.chapter
            for _, h in ipairs(data.prog) do
                local n = tonumber(h)
                if n then ss.prog_seen[math.tointeger(n) or n] = true end
            end
        end
    end
end

-- Story clock (v0.39): the sum of this chapter's progress numbers (every stage hash the game
-- set since the chapter began). It only grows as the story moves on, and a loaded save sets
-- it back to that save's point.
local function chapter_now()
    local gm = sdk.get_managed_singleton("app.GameManager")
    if gm == nil then return 0 end
    local ok, v = pcall(gm.get_field, gm, "_CurrentChapter")
    return tonumber(ok and v or 0) or 0
end
function coop_story_clock()
    local fm = sdk.get_managed_singleton("app.GameFlowFsmManager")
    if fm == nil or ss.prog_ch ~= chapter_now() then return 0 end
    local sum = 0
    for h in pairs(ss.prog_seen) do
        local ok, var = pcall(fm.call, fm, "getProgressiveNo(System.UInt32)", h)
        local ok2, v = false, nil
        if ok and var then ok2, v = pcall(var.call, var, "get_S32") end
        sum = sum + ((ok2 and tonumber(v)) or 0)
    end
    return sum
end

local function mark_played(name, ch)
    if ss.played_chapter ~= ch then ss.played, ss.played_chapter = {}, ch end
    if not ss.played[name] then
        ss.played[name] = coop_story_clock()
        save_played()
    end
end
-- This chapter's played scenes ({} when the list is from another chapter).
local function played_here()
    if ss.played_chapter ~= chapter_now() then return {} end
    return ss.played
end
local PENDING_FOR = 10    -- s to keep waiting for a nearby friend's cutscene to load here
local PENDING_PULLED = 30 -- s, after we were brought next to them (the area streams in around us first)
local NEAR = 12           -- m: a friend's cutscene pulls us in only this close (with "scene_pull" off)
SCENE_PULL_MAX = 200      -- m (v0.51): with it on (the default), from this far
local IN_STEP = 30        -- s after a shared cutscene during which their progress is copied

-- Lines are collected and appended once a second (was a full read + rewrite per line).
local log_buf, log_t, log_tail = {}, 0, nil
-- v0.52: repeated lines are limited and the file written by coop_dummy.lua's coop_log_gate / coop_log_flush.
local function log(s)
    if coop_log_gate and not coop_log_gate("story", s) then return end
    log_buf[#log_buf + 1] = os.date("%H:%M:%S ") .. tostring(s)
end
dbg_note{ feature = "Logging", name = "Write the story script's log file",
    when = "every frame; writes to disk only when 1 to 5 s have passed since the last write",
    reads = "this script's log lines in memory",
    writes = "coop_story_log.txt" }
re.on_frame(function()
    if coop_log_flush then log_buf, log_t = coop_log_flush("story", "coop_story_log.txt", log_buf, log_t) return end
    -- without coop_dummy.lua: the v0.51 writer
    if #log_buf == 0 or os.clock() - log_t < 3 then return end
    log_t = os.clock()
    local f = (log_tail or fs.read("coop_story_log.txt") or "") .. table.concat(log_buf, "\n") .. "\n"
    if #f > 200000 then f = f:sub(-100000) end
    log_tail = f
    fs.write("coop_story_log.txt", f)
    log_buf = {}
end)

local function chapter()
    local gm = sdk.get_managed_singleton("app.GameManager")
    if gm == nil then return 0 end
    local ok, v = pcall(gm.get_field, gm, "_CurrentChapter")
    return tonumber(ok and v or 0) or 0
end

local function note(msg)
    ss.msg, ss.msg_t = msg, os.clock()
    log(msg)
end

-- "Share story" (Options): off = neither send nor apply. Off by default from 2026-11-02 (the first real
-- session pushed the player who was behind: tape ended early, washed-out picture, chapter change stuck);
-- on by default since v0.49, after those were fixed and every later session and bot test ran with it on.
local function sharing() return settings ~= nil and settings.share_story ~= false end

-- Story steps are always sent (v0.23), and applied only with Share story on: with it off the
-- other game just keeps track of how far you are, to warn when your stories drift apart.
local function send(text)
    if coop_send_event then coop_send_event(text) ss.sent = ss.sent + 1 log("sent: " .. text) end
end

local function ours(key) return ss.applying[key] and os.clock() - ss.applying[key] < 5 end

local function u32(p) return sdk.to_int64(p) & 0xFFFFFFFF end
local function i32(p)
    local v = sdk.to_int64(p) & 0xFFFFFFFF
    if v >= 0x80000000 then v = v - 0x100000000 end
    return v
end

local function flow_mgr() return sdk.get_managed_singleton("app.GameFlowFsmManager") end
local function event_mgr()
    return sdk.find_type_definition("app.GameManager"):get_field("_GameEventMan"):get_data(nil)
end

-- Our side ---------------------------------------------------------------------------
local ec = sdk.find_type_definition("app.GameEventController")
-- Starting cutscenes together (v0.53). A scene of ours that the friend will join is held for a moment at its
-- setup: the friend's game brings its player over and loads the scene, answers "ready <name>", and both start
-- it in the same moment (one network trip apart) instead of the friend's starting seconds later. VHS tapes'
-- scenes too, so a tape's scripted NPCs run in step. Held at most SCENE_READY_MAX s; a scene that follows on
-- from one of ours (the next part of a sequence) isn't held. "scene_ready": false in coop_settings.json: off.
SCENE_READY_MAX = 8
ss.held = ss.held or {}
local function hold_scene(name, ch)
    -- Opt-in (settings.scene_ready = true): in one bot case (a scene asked for twice in the same moment) the held
    -- scene was set up but never played in time. Off, the friend's game starts it within about half a second.
    if not (settings and settings.scene_ready == true) or settings.scene_pull == false then return false end
    if ss.scene_pass == name or ss.held[name] then return false end
    if ss.running[name] then return false end   -- set up already (a second request for it)
    -- Already asked for by another path (a second request for the same scene): left alone.
    local em0 = event_mgr()
    local okq, same = pcall(em0.call, em0, "isSameEventRequested(System.String)", sdk.create_managed_string(name))
    if okq and same == true then return false end
    if ours("ev:" .. name) or (ss.played_chapter == ch and ss.played[name]) then return false end
    if coop_my_phone_t and os.clock() - coop_my_phone_t < 15 then return false end   -- a phone call: theirs to hear
    -- The friend is holding this one for us (their "story <name> hold" came first): we start, they follow.
    if ss.ready_for and ss.ready_for[name] then return false end
    local smp = coop_friend_sample and coop_friend_sample()
    if smp == nil then
        -- A tape we've just gone into together (v0.53): its first scene waits for whoever is still loading in.
        local into = math.max(coop_tape_sent_t or -1000, coop_tape_follow_t or -1000)
        if TAPE_CHAPTERS and TAPE_CHAPTERS[ch] and os.clock() - into < 120 and not ss.tape_scene_held then
            if next(ss.running) ~= nil then return false end
            ss.tape_scene_held = true
            return true, nil, TAPE_READY_MAX
        end
        return false
    end
    if rawget(_G, "friend_cutscene") == true then return false end
    if revive and revive.down_slots and revive.down_slots[1] then return false end
    if next(ss.running) ~= nil or os.clock() - (ss.cut_end_t or -100) < 3 then return false end   -- mid-sequence
    local om = sdk.get_managed_singleton("app.ObjectManager")
    local pl = om and om:get_field("PlayerObj")
    local pp = pl and pl:call("get_Transform"):call("get_Position")
    if pp == nil then return false end
    local d = math.sqrt((smp.pos.x - pp.x) ^ 2 + (smp.pos.y - pp.y) ^ 2 + (smp.pos.z - pp.z) ^ 2)
    return d <= SCENE_PULL_MAX, d
end
-- Held at the request (GameEventManager.requestEvent), the game's normal way in, and asked again the same way:
-- a replayed requestSetup (the first try) was only taken up 26 s later in the bot test. The friend answers as
-- it asks for the scene itself, so both games load it side by side and start it together.
ss.held_sent = ss.held_sent or {}
local function release_scene(name, why)
    local h = ss.held[name]
    if h == nil then return end
    ss.held[name] = nil
    local em = event_mgr()
    -- Set up or asked for meanwhile by another path: not asked for a second time (that one waited behind it).
    local okq, same = pcall(em.call, em, "isSameEventRequested(System.String)", sdk.create_managed_string(name))
    if ss.running[name] or (okq and same == true) then
        log(string.format("scene %s: %s; it was already starting here (held %.1f s)", name, why, os.clock() - h.t))
        return
    end
    ss.scene_pass = name
    local ok, err = pcall(em.call, em, "requestEvent(System.String, via.Transform, System.Boolean)",
        sdk.create_managed_string(name), h.tr, h.flag == true)
    ss.scene_pass = nil
    -- The caller's callbacks (on the Handle it got while held) go onto the real request.
    if ok and err and h.handle then
        local tok, terr = pcall(h.handle.call, h.handle, "transferTo", err)
        if not tok then log("scene " .. name .. ": couldn't move its callbacks onto the real request (" .. tostring(terr) .. ")") end
    end
    log(string.format("scene %s: %s, starting it (held %.1f s)%s", name, why, os.clock() - h.t, ok and "" or (" ERR " .. tostring(err))))
end
function coop_story_scene_ready(name, from_slot)
    if ss.held[name] then release_scene(name, "your friend is ready") end
end
dbg_note{ feature = "Story cutscenes", name = "Release held scenes (Cutscenes wait for both) when the friend is late",
    when = "every frame",
    reads = "the scenes held for the friend and how long each has waited; our chapter",
    writes = "requests a held scene for real after its wait (8 s, 30 s into a tape); forgets the one-per-tape hold outside the tapes" }
re.on_frame(function()
    local now = os.clock()
    for name, h in pairs(ss.held) do
        if now - h.t > (h.max or SCENE_READY_MAX) then release_scene(name, "your friend didn't answer in time") end
    end
    -- One held first scene per tape: cleared once we're out of the tapes again.
    if ss.tape_scene_held and not (TAPE_CHAPTERS and TAPE_CHAPTERS[chapter()]) then ss.tape_scene_held = nil end
end)
do
    local emt = sdk.find_type_definition("app.GameEventManager")
    local rq = emt and emt:get_method("requestEvent(System.String, via.Transform, System.Boolean)")
    if rq then
        -- requestEvent returns a GameEventManager.Handle (an object its caller may hang start/end callbacks on). A
        -- held call gets a fresh Handle of its own (a skipped call handed back an undefined one: an exception in the
        -- bot suite), and when the scene is really requested its callbacks are moved onto the real one (transferTo).
        -- (Swapping in a name no scene has instead blocked the game's queue: the real scene then waited 24 s.)
        local HANDLE_T = sdk.find_type_definition("app.GameEventManager.Handle")
        local held_ret = nil
        dbg_note{ feature = "Story cutscenes", name = "Hold a scene of ours until the friend is ready (Cutscenes wait for both)",
            when = "when the game calls GameEventManager.requestEvent (a scene is asked for); only with scene_ready on",
            reads = "the scene's name; whether the friend is near and not in a scene; tape entry time",
            writes = "skips the request and returns a stand-in Handle; sends 'story <scene> <chapter> hold'" }
        sdk.hook(rq, function(args)
            local skip = false
            held_ret = nil
            pcall(function()
                local so = sdk.to_managed_object(args[3])
                local n0 = so and tostring(so:call("ToString"))
                if n0 == nil or not is_story_event(n0) then return end
                local ch0 = chapter()
                local hold, d, max = hold_scene(n0, ch0)
                if hold then
                    local tr = args[4] and sdk.to_managed_object(args[4]) or nil
                    if tr then tr:add_ref() end
                    local hd = HANDLE_T and sdk.create_instance("app.GameEventManager.Handle")
                    if hd then pcall(hd.call, hd, ".ctor") hd:add_ref() end
                    ss.held[n0] = { tr = tr, flag = (sdk.to_int64(args[5]) & 0xff) ~= 0, t = os.clock(), max = max, handle = hd }
                    held_ret = hd
                    ss.held_sent[n0] = true
                    send(string.format("story %s %d hold", n0, ch0))
                    log(string.format("scene %s: held until your friend is ready (%s)", n0,
                        d and string.format("%.0f m away", d) or "they're still loading into the tape"))
                    skip = true
                end
            end)
            if skip and held_ret then return sdk.PreHookResult.SKIP_ORIGINAL end
        end, function(r)
            if held_ret then
                local hd = held_ret
                held_ret = nil
                return sdk.to_ptr(hd)
            end
            return r
        end)
    else
        log("scene hold: GameEventManager.requestEvent not found; cutscenes start as before")
    end
end
dbg_note{ feature = "Story cutscenes", name = "A scene is being set up here: tell the friend",
    when = "when the game calls GameEventController.requestSetup (a cutscene or scripted moment starts here)",
    reads = "the scene's event name; whether it is a story scene; our chapter; whether it is the friend's scene or our own phone call",
    writes = "coop_scene_t (marks a scripted moment, so bumping and enemy sharing wait); sends 'story <scene> <chapter>'; hands the player part of a friend's phone call to the friend's body" }
sdk.hook(ec:get_method("requestSetup(app.GameEventSetting, via.Transform)"), function(args)
    pcall(function()
        local st = sdk.to_managed_object(args[3])
        local name = st and tostring(st:call("get_eventName"))
        if name ~= nil then coop_scene_t = os.clock() end   -- any scripted scene (collision, v0.34)
        -- A call the friend answered: our own phone starts the scene a moment later (coop_world sets
        -- coop_friend_scene_until). It is the friend's scene: their body takes the player's part.
        if name ~= nil and os.clock() < (coop_friend_scene_until or 0) and coop_story_retarget_setting
            and not (settings and settings.intr_pull_me == true) and not (ss.retargeted and ss.retargeted[name]) then
            local n = coop_story_retarget_setting(st, name)
            if n > 0 then
                ss.applying["ev:" .. name] = os.clock()
                log("friend's call " .. name .. ": " .. n .. " player part(s) given to your friend's body")
            end
        end
        if name == nil or not is_story_event(name) then return end
        local ch = chapter()
        if ss.played_chapter ~= ch then ss.played, ss.played_chapter = {}, ch end
        local first = not ss.played[name]
        mark_played(name, ch)
        -- Our game started a scene the friend is holding for us, by itself or on their word (v0.53): both go now.
        if coop_story_started_for_friend then coop_story_started_for_friend(name) end
        -- The sequence our game is in now (v0.39), and when each scene started (for its end).
        local grp = seq_of(name)
        if grp then ss.last_seq = { grp = grp, t = os.clock(), ch = ch } end
        ss.running[name] = os.clock()
        -- v0.69: started for the friend (their scene played here), not by our own story: see scene_to_start.
        ss.for_friend = ss.for_friend or {}
        ss.for_friend[name] = ours("ev:" .. name) and true or nil
        log(string.format("scene %s starts (%s, story clock %d)", name, ours("ev:" .. name) and "your friend's" or "yours",
            coop_story_clock()))
        -- A scene our own phone started (coop_world notes the moment we answer): told apart from a real
        -- cutscene, so the friend's game gives it to our body instead of playing it on the friend.
        local tag = (coop_my_phone_t and os.clock() - coop_my_phone_t < 15) and " phone" or ""
        -- A held scene was announced when it was held ("story <name> <ch> hold"): not twice.
        if first and not ours("ev:" .. name) and not ss.held_sent[name] then send(string.format("story %s %d%s", name, ch, tag)) end
        ss.held_sent[name] = nil
    end)
end, function(r) return r end)

-- When each scene ends (v0.39), for the logs: the dinner's last scene never ended on 2026-11-08
-- and nothing showed it until Jack didn't come.
ss.running, ss.stuck_said = ss.running or {}, ss.stuck_said or {}
do
    local m = ec:get_method("doOnDestroy")
    if m then
        dbg_note{ feature = "Story cutscenes", name = "A scene ended here",
            when = "when the game calls GameEventController.doOnDestroy",
            reads = "the scene's event name, how long it ran",
            writes = "coop_scene_end_t; forgets the scene as running; gives a retargeted player part back; one log line" }
        pcall(sdk.hook, m, function(args)
            pcall(function()
                coop_scene_end_t = os.clock()   -- for teleport_to_friend (v0.49)
                local c = sdk.to_managed_object(args[2])
                local st = c and c:call("get_eventSetting")
                local name = st and tostring(st:call("get_eventName"))
                local t0 = name and ss.running[name]
                if t0 then
                    ss.running[name] = nil
                    log(string.format("scene %s ended after %.0f s (story clock %d)", name, os.clock() - t0, coop_story_clock()))
                end
                if name and coop_story_scene_given_back then coop_story_scene_given_back(name) end
            end)
        end, function(r) return r end)
    end
end
dbg_note{ feature = "Story cutscenes", name = "Warn about a scene that has run for 5 minutes",
    when = "every frame, but it only looks every 30 s",
    reads = "the table of running scenes (in memory)",
    writes = "one log line per stuck scene" }
re.on_frame(function()
    local now = os.clock()
    if now - (ss.stuck_t or 0) < 30 then return end
    ss.stuck_t = now
    for name, t0 in pairs(ss.running) do
        if now - t0 > 300 and not ss.stuck_said[name] then
            ss.stuck_said[name] = true
            log(string.format("scene %s still running after %d minutes (stuck? a bug report now would show it)", name,
                math.floor((now - t0) / 60)))
        end
    end
end)

local gf = sdk.find_type_definition("app.GameFlowFsmManager")
dbg_note{ feature = "Story progress", name = "The story took a step here: tell the friend",
    when = "when the game calls GameFlowFsmManager.setProgressiveNo (every story-flow step, in bursts around scenes)",
    reads = "the stage hash and value; our chapter",
    writes = "coop_scene_t (marks a scripted moment); remembers the stage hash for the story clock; sends 'prog <hash> <value> <chapter>' unless the friend's step caused it" }
sdk.hook(gf:get_method("setProgressiveNo(System.UInt32, System.Int32)"), function(args)
    pcall(function()
        local h, v = u32(args[3]), i32(args[4])
        -- A story step is a scripted moment too (v0.48): the morgue fight's step 600 takes 3500 off Jack
        -- before its scene is set up, and the host's game sent that as damage (coop_enemies scripted_now).
        coop_scene_t = os.clock()
        -- The story clock's stage hashes (v0.39).
        local ch = chapter()
        if ss.prog_ch ~= ch then ss.prog_seen, ss.prog_ch = {}, ch end
        if not ss.prog_seen[h] then ss.prog_seen[h] = true ss.prog_dirty = true end
        if v > 0 and not ours(string.format("pg:%08x", h)) then
            send(string.format("prog %08x %d %d", h, v, chapter()))
        end
    end)
end, function(r) return r end)
dbg_note{ feature = "Story progress", name = "Save the list of story stages seen",
    when = "every frame (a flag check); writes the file at most every 5 s and only when a new stage was seen",
    reads = "ss.prog_dirty",
    writes = "the played-scenes file (save_played)" }
re.on_frame(function()
    if ss.prog_dirty and os.clock() - (ss.prog_save_t or 0) > 5 then
        ss.prog_dirty, ss.prog_save_t = false, os.clock()
        save_played()
    end
end)
-- A fight's end (v0.48): the game marks every boss fight and ambush over with sendBattleEnded(hash), the
-- way it marks events with sendEventEnded. It was never shared, so a fight one game had won stayed open
-- in the other. Same rules as a finished event: copied when together, kept for later when apart.
do
    local mb = gf:get_method("sendBattleEnded(System.UInt32)")
    if mb then
        dbg_note{ feature = "Story progress", name = "A fight ended here: tell the friend",
            when = "when the game calls GameFlowFsmManager.sendBattleEnded",
            reads = "the fight's hash",
            writes = "sends 'btlend <hash> <chapter>' unless the friend's game caused it" }
        pcall(sdk.hook, mb, function(args)
            pcall(function()
                local h = u32(args[3])
                if not ours(string.format("be:%08x", h)) then send(string.format("btlend %08x %d", h, chapter())) end
            end)
        end, function(r) return r end)
    end
end
dbg_note{ feature = "Story progress", name = "A story event ended here: tell the friend",
    when = "when the game calls GameFlowFsmManager.sendEventEnded",
    reads = "the event's hash",
    writes = "sends 'evend <hash> <chapter>' unless the friend's game caused it" }
sdk.hook(gf:get_method("sendEventEnded(System.UInt32)"), function(args)
    pcall(function()
        local h = u32(args[3])
        if not ours(string.format("ee:%08x", h)) then send(string.format("evend %08x %d", h, chapter())) end
    end)
end, function(r) return r end)

-- Friend's side ----------------------------------------------------------------------
-- Distance to the friend's Ethan (nil when there's none to measure).
local function friend_distance(slot)
    -- To the friend whose story event it is (v0.29: friends 2-3 have their own character).
    local env = coop_slot_envs and coop_slot_envs[slot or coop_event_slot or 1] or _G
    local ghost_fn = rawget(env, "coop_ghost") or coop_ghost
    local g = ghost_fn and ghost_fn()
    local om = sdk.get_managed_singleton("app.ObjectManager")
    local player = om and om:get_field("PlayerObj")
    if g == nil or player == nil then return nil end
    local ok, gp = pcall(function() return g:call("get_Transform"):call("get_Position") end)
    if not ok or gp == nil then return nil end
    local pp = player:call("get_Transform"):call("get_Position")
    return math.sqrt((gp.x - pp.x) ^ 2 + (gp.y - pp.y) ^ 2 + (gp.z - pp.z) ^ 2)
end

-- One game leads the story (v0.47, Options; on by default and the same for everyone since v0.49): the host
-- (the game that runs the enemies) leads; in the other game the host's scenes play wherever we are, and
-- its progress is always copied.
local function follower()
    return settings ~= nil and settings.story_follow_host ~= false and coop_enemy_role_now == "guest"
end
-- In step: for IN_STEP s after a shared cutscene ENDS (v0.30). It used to count from the start:
-- a 31 s cutscene (Mia, 2026-11-08) ended after the window closed, so the "event finished" that
-- followed was dropped and Mia stood frozen in the friend's game, blocking the way.
local function in_step()
    if ss.in_step_until == nil then return false end
    if local_cutscene and local_cutscene() then
        ss.in_step_until = math.max(ss.in_step_until, os.clock() + IN_STEP)
        return true
    end
    return os.clock() < ss.in_step_until
end
-- Keep the window open while the shared cutscene plays, even when no message comes in.
dbg_note{ feature = "Story cutscenes", name = "Keep the 'copy their progress' window open during a shared scene",
    when = "every frame (a flag and a cutscene check)",
    reads = "ss.in_step_until, local_cutscene()",
    writes = "pushes in_step_until forward (in memory)" }
re.on_frame(function()
    if ss.in_step_until and os.clock() < ss.in_step_until and local_cutscene and local_cutscene() then
        ss.in_step_until = math.max(ss.in_step_until, os.clock() + IN_STEP)
    end
end)
-- The scenes loaded here (GameEventManager.EventSettings), re-read at most once a second.
local names_cache = { t = -100, list = {} }
local function loaded_scene_names()
    local now = os.clock()
    if now - names_cache.t < 1 then return names_cache.list end
    names_cache.t = now
    local out = {}
    local em = event_mgr()
    local list = em and em:get_field("EventSettings")
    for i = 0, (list and list:call("get_Count") or 0) - 1 do
        local s = list:call("get_Item", i)
        local n = s and tostring(s:call("get_eventName"))
        if n then out[#out + 1] = n end
    end
    names_cache.list = out
    return out
end
local function setting_loaded(name)
    for _, n in ipairs(loaded_scene_names()) do if n == name then return true end end
    return false
end

-- Scene sequences (v0.39) ------------------------------------------------------------
-- Story scenes come in sequences: c03e00_00 (the dinner), then c03e00_01 and c03e00_02 (the
-- escape), with play in between (rocking the chair). Once a game has started a sequence it
-- plays the rest itself, each scene when its own player gets there. Starting the friend's
-- later scene in a game still earlier in the sequence skips what's in between: on 2026-11-08
-- the escape was started 71 s into the friend's dinner, the chapter never moved on, and Jack
-- never came in either game.
-- A scene of this sequence already played here (this chapter): its name, or nil.
local function seq_played(grp)
    for n in pairs(played_here()) do
        -- Variants numbered 10 and up are side scenes, not steps (v0.48): the garage shutter opening,
        -- c03e02_10, made the friend's game refuse the car fight c03e02_00 as "a step it plays itself".
        local g, i = seq_of(n)
        if g == grp and (i == nil or i < 10) then return n end
    end
    return nil
end
-- Our game is between two scenes of its sequence: a later one is loaded and hasn't played
-- (after the dinner, before the escape). Variants numbered 10 and up don't count; 10 minutes
-- at most.
local function sequence_open()
    local s = ss.last_seq
    if s == nil or s.ch ~= chapter() or os.clock() - s.t > 600 then return false end
    -- v0.49 (bot playthrough): a group's later scenes can be loaded and never come (c01e00_00's _01/_02 are
    -- branches the host never played), and this held every story step of the friend's for up to 10 minutes
    -- (the guest took step 1100 six minutes late, and the host's next scenes waited behind it). Over when the
    -- friend has started a later scene group, and, when the host leads (follower), 20 s after our last scene.
    if ss.friend_grp and ss.friend_grp > s.grp then return false end
    if follower() and not ss.cut_on and os.clock() - (ss.cut_end_t or -100) > 20 then return false end
    local top = -1
    for n in pairs(played_here()) do
        local g, i = seq_of(n)
        if g == s.grp and i and i > top then top = i end
    end
    for _, n in ipairs(loaded_scene_names()) do
        local g, i = seq_of(n)
        if g == s.grp and i and i > top and i < 10 then return true end
    end
    return false
end
-- A chapter jump starts that chapter over (v0.40: the lobby's Start, Go to my friend's chapter):
-- its scenes count as not played, nothing kept from the friend is applied, and the friend is told.
function coop_story_reset_chapter(v)
    if ss.played_chapter == v then ss.played = {} save_played() end
    ss.pending, ss.missed, ss.in_step_until, ss.last_seq, ss.running = {}, {}, nil, nil, {}
    ss.steps = {}
    ss.friend_grp, ss.friend_played = nil, {}
    ss.obj_done = {}   -- v0.48: starts the friend's objective check-offs over
    if ss.prog_ch == v then ss.prog_seen = {} end
    log("chapter " .. tostring(v) .. " starts over (chapter jump): its scenes count as not played")
    send(string.format("rewind %d 0", v))
end
-- For coop_enemies (v0.39): while our sequence is playing out, enemies aren't followed or sent
-- (Jack sits at our dinner table while the friend's Jack already roams the house).
function coop_story_in_sequence()
    local ok, v = pcall(sequence_open)
    return ok and v == true
end
-- The scene to start here for the friend's scene `name` (same chapter), or nil and why not.
-- The furthest scene (index under 10) of a group this game has played, or -1.
local function seq_top(grp)
    local top = -1
    for n in pairs(played_here()) do
        local g, i = seq_of(n)
        if g == grp and i and i < 10 and i > top then top = i end
    end
    return top
end
-- A scene of this sequence (index under 10) playing here right now: its name, or nil.
local function seq_running(grp)
    for n in pairs(ss.running or {}) do
        local g, i = seq_of(n)
        if g == grp and (i == nil or i < 10) then return n end
    end
    return nil
end
local function scene_to_start(name)
    if played_here()[name] then return nil, "already played here" end
    local grp, idx = seq_of(name)
    if grp == nil then return name end
    local mine = seq_played(grp)
    -- v0.69: a part of this sequence still playing here counts as started. Bot run 2026-11-26, Chapter 4: the host's
    -- c04e71_01 came while the guest was 1 s from the end of c04e71_00 (the host's, played here); it wasn't "played"
    -- yet, so the late-arrival rule below swapped in c04e71_00, which was then "already played", and _01 was lost: the
    -- third flashback never happened in the guest's ship (its past-ship doors stayed as they were).
    local running = seq_running(grp)
    local started = mine or running
    if running and not mine and not (ss.for_friend and ss.for_friend[running]) then mine = running end
    -- v0.69: our part of this sequence was the friend's scene played here, not our own story's: nothing here will go on
    -- to the next part by itself, so the friend's next part plays too. Bot sweep 2026-11-26, Chapter 4: the guest played
    -- the host's c04e71_00 and then refused its c04e71_01 ("your game is in this scene's sequence and plays it when you
    -- get there"); it never did.
    if mine and ss.for_friend and ss.for_friend[mine] then mine = nil end
    if mine then
        -- v0.50 (bot playthrough): only while our game is still before this scene in the sequence. Chapter 4's
        -- start plays c04e12_01 (a 0 s setup scene) by itself, and the host's c04e12_00 afterwards was refused as
        -- "a step you'll reach yourself" though the sequence had already gone past it here: it never played.
        local top = seq_top(grp)
        if not (idx and top > idx) then
            return nil, "your game is in this scene's sequence (" .. mine .. ") and plays it when you get there"
        end
        log(string.format("friend's %s: your game has played %s_%02d of its sequence, past this one: playing it", name, grp, top))
    end
    if idx and idx >= 1 and idx <= 9 and not started then
        -- Partway through a sequence we haven't started: start it from its first scene (a late arrival: the friend
        -- played _00 before we were there). v0.50: dropped again if our own game then plays the friend's scene
        -- itself (see the pending queue): Chapter 4's start plays c04e12_01 before c04e12_00 in both games.
        local first = grp .. "_00"
        if setting_loaded(first) then return first, "starting its sequence here from " .. first end
        return nil, "it's partway through a sequence your game hasn't started"
    end
    return name
end

-- A friend's scene is theirs to perform (v0.48). A story scene (app.GameEventSetting) lists its parts in
-- EventActions; the one for the player (cNNeNN_NN_pl0000, isTargetPlayer) can be pointed at the friend's
-- body with SetTargetObj, like an interaction's. Tested 2026-11-11 with c03e20_00: the scene loaded, ran
-- its 12 s and ended with the friend's body in it; our player was never in an event and never moved.
-- A scene can leave its player somewhere else (a fall, a room that locks): when it ends and the friend is
-- more than 6 m away, we are brought next to them.
-- The owner's rule (2026-11-11): real cutscenes are watched by both players in first person, as before;
-- only phone calls (and the scripted world interactions in coop_world) are the initiator's alone, with
-- the other player hearing it and having it count. So only a scene tagged as a phone call is given to
-- the friend's body; settings.cutscenes_on_friend = true (coop_settings.json) does it for every scene.
ss.retargeted = ss.retargeted or {}
ss.phone_scene = ss.phone_scene or {}
local function scenes_on_friend(name)
    if settings and settings.intr_pull_me == true then return false end
    if settings and settings.cutscenes_on_friend == true then return true end
    return ss.phone_scene[name] ~= nil or os.clock() < (coop_friend_scene_until or 0)
end
local function retarget_setting(st, name)
    local body = coop_ghost_event_begin and coop_ghost_event_begin(60, 900)
    if body == nil then return 0, "no friend's body yet" end
    local acts = st:call("get_eventActions")
    local n, list = 0, {}
    for k = 0, (acts and acts:call("get_Count") or 0) - 1 do
        local a = acts:call("get_Item", k)
        if a and a:call("get_isTargetPlayer") == true then
            pcall(a.set_field, a, "SetTargetObj", body)
            pcall(a.set_field, a, "TargetObjTemp", body)
            list[#list + 1] = a
            n = n + 1
        end
    end
    if n > 0 then ss.retargeted[name] = { acts = list, t = os.clock() } end
    return n
end
local function retarget_scene(name)
    local em = event_mgr()
    local list = em and em:get_field("EventSettings")
    for i = 0, (list and list:call("get_Count") or 0) - 1 do
        local st = list:call("get_Item", i)
        if st and tostring(st:call("get_eventName")) == name then return retarget_setting(st, name) end
    end
    return 0, "scene not loaded"
end
coop_story_retarget_setting = function(st, name)        -- for the scene-start hook
    local ok, n, why = pcall(retarget_setting, st, name)
    return ok and n or 0, why
end
-- When our copy of a friend's scene has ended: point its player part back at the player, and stand
-- with the friend if the scene took them somewhere.
local function scene_given_back(name)
    local r = ss.retargeted[name]
    if r == nil then return end
    ss.retargeted[name] = nil
    for _, a in ipairs(r.acts) do
        pcall(a.set_field, a, "SetTargetObj", nil)
        pcall(a.set_field, a, "TargetObjTemp", nil)
    end
    ss.regroup_t = os.clock() + 3.5   -- after teleport_to_friend's 3 s wait at a scene's end (v0.49)
    log("friend's " .. name .. ": ended here, played on your friend's body")
end
coop_story_scene_given_back = scene_given_back

local function play(name)
    local em = event_mgr()
    -- Already asked for here (our own trigger in the same moment): don't ask twice (v0.39).
    local okr, dup = pcall(em.call, em, "isSameEventRequested(System.String)", sdk.create_managed_string(name))
    if okr and dup == true then
        mark_played(name, chapter())
        log("friend's " .. name .. ": already starting here")
        return
    end
    ss.applying["ev:" .. name] = os.clock()
    mark_played(name, chapter())
    if scenes_on_friend(name) then
        local okr2, n, why = pcall(retarget_scene, name)
        log(string.format("friend's %s: %s", name, (okr2 and (n or 0) > 0) and (n .. " player part(s) given to your friend's body: you keep control")
            or ("plays on you (" .. tostring(okr2 and (why or "it has no player part") or n) .. ")")))
    end
    local ok, err = pcall(em.call, em, "requestEvent(System.String, via.Transform, System.Boolean)",
        sdk.create_managed_string(name), nil, false)
    ss.applied = ss.applied + 1
    if ok then ss.in_step_until = os.clock() + IN_STEP end
    note(ok and ("your friend's story: " .. name) or ("ERR playing " .. name .. ": " .. tostring(err)))
end

-- v0.56: a "scene" of ours that has run for over LONG_SCENE_S isn't a cutscene to wait for. Some story events
-- stay running while you play: the opening drive (c01e00_01, 155 s in real play) and the Mia fight's c01e01_01
-- (288 s and 637 s on 2026-11-13/14, "still running after 5 minutes"). Everything of the friend's waited behind
-- them (steps, event and fight ends, their scenes), and in the bot test (2026-11-14) the friend's game sat in the
-- drive for over 4 minutes with the host's step 600 and wall-throw scene (c01e04_00) held: the story never moved
-- on there, so Mia's wall stayed up and "you are further on in the story" repeated. The longest real cutscene
-- seen is the dinner, c03e00_00, at 102 s, so 130 s leaves every real one alone.
local LONG_SCENE_S = 130

-- Our player left inside a scene's player part (v0.69). Bot test 2026-11-26, Chapter 1 from a New Game: the guest's
-- player stayed in the opening's event action (its GameEventActionController isPlay, process 6, waiting on its
-- "continue" end: isEndContinueAction) for over 20 minutes after the host's game had gone on; the guest couldn't move
-- (PlayerOrder Base layer locked), MenuManager.isPlayingEvent stayed true, so the game counted as "in a cutscene" for
-- good and boss sharing stayed off: each game ran its own Mia. endCompleteAction(false) ended it (isPlayingEvent false
-- 2 s later, Mia shared at once). Done only when it has lasted STUCK_ACTION_S, our friend isn't in a scene, and we
-- aren't down; then a Base lock left on is lifted too.
STUCK_ACTION_S = 120
local stuck_act = { since = nil, t = 0 }
local function safe(f, ...)
    local ok, r = pcall(f, ...)
    if ok then return r end
    return nil
end
dbg_note{ feature = "Story cutscenes", name = "End a scene's player part our player was left in",
    when = "every frame, but it only works once a second, and only with a friend linked",
    reads = "our player's GameEventActionController (isPlay, isEndContinueAction), the friend's cutscene flag, revive.downed",
    writes = "after STUCK_ACTION_S: GameEventActionController.endCompleteAction(false); PlayerOrder Base lock lifted if still on" }
re.on_frame(function()
    local now = os.clock()
    if now - stuck_act.t < 1 then return end
    stuck_act.t = now
    local ns = coop_net_state and coop_net_state()
    local linked = coop_link_friend ~= nil and ns ~= nil and coop_link_friend(ns.kv) == true
    if not linked then stuck_act.since = nil return end
    local om = sdk.get_managed_singleton("app.ObjectManager")
    local p = om and safe(om.get_field, om, "PlayerObj")
    local gea = p and safe(p.call, p, "getComponent(System.Type)", sdk.typeof("app.GameEventActionController")) or nil
    local stuck = type(gea) == "userdata" and safe(gea.call, gea, "get_isPlay") == true and safe(gea.call, gea, "get_isEndContinueAction") == true
        and rawget(_G, "friend_cutscene") == false and not (revive and revive.downed)
    if not stuck then stuck_act.since = nil return end
    stuck_act.since = stuck_act.since or now
    if now - stuck_act.since < STUCK_ACTION_S then return end
    stuck_act.since = nil
    local ok = pcall(gea.call, gea, "endCompleteAction(System.Boolean)", false)
    log(string.format("our player was left in a scene's part for %d s while your friend played on: ended it (%s)",
        STUCK_ACTION_S, ok and "ok" or "ERR"))
    note("you were stuck in a scene: it's ended so you can play on")
    -- The scene's Base lock (PlayerOrder.switchPlayerOperatable layer 0) can stay on after it: lifted 2 s later.
    stuck_act.unlock_at = now + 2
end)
dbg_note{ feature = "Story cutscenes", name = "Lift the Base lock a scene part left on (2 s after ending it)",
    when = "every frame, a clock check; works once, 2 s after the scene part above was ended",
    reads = "PlayerOrder.get_isPlayerNoneOperatable, revive.downed",
    writes = "PlayerOrder.switchPlayerOperatable(true, Base) if still locked" }
re.on_frame(function()
    if stuck_act.unlock_at == nil or os.clock() < stuck_act.unlock_at then return end
    stuck_act.unlock_at = nil
    if revive and revive.downed then return end
    local om = sdk.get_managed_singleton("app.ObjectManager")
    local p = om and om:get_field("PlayerObj")
    local po = p and safe(p.call, p, "getComponent(System.Type)", sdk.typeof("app.PlayerOrder"))
    if po and safe(po.call, po, "get_isPlayerNoneOperatable") == true then
        pcall(po.call, po, "switchPlayerOperatable(System.Boolean, app.PlayerDefine.OperationLayer)", true, 0)
        log("our player was still locked after that scene part: unlocked")
    end
end)

local function only_long_scenes()
    if next(ss.running) == nil then return false end
    local now = os.clock()
    for _, t0 in pairs(ss.running) do
        if now - (tonumber(t0) or now) < LONG_SCENE_S then return false end
    end
    return true
end
-- v0.69: for coop_enemies, whose held-in-cutscene friend's changes waited behind long events too (see there).
function coop_only_long_scenes() return only_long_scenes() end

-- The game's own screens that hold the player (v0.69, probes/menu_is.lua): inventory, a file or examined item, the item
-- box, item select, the save screen, tips, carrying something, a full-screen movie, and any stacked menu. Bot sweep
-- 2026-11-26 (FF040): the orphan-lock watchdog below unlocked a player the game kept locking (3 times in 32 s) because
-- only the pause menu counted; a player reading a file for 15 s would have been let loose under it.
local GAME_SCREENS = { "isExistStackOpenMenu", "isOpenInventoryMenu", "isOpenDetailSearchGUI", "isOpenItemBoxMenu",
    "isOpenItemSelectMenu", "isOpenSaveMenuGUI", "isOpenTableItemExplanationMenu", "isTipsOpen", "isOpenMultiSubMenu",
    "isCarryActionMode", "isPlayerCarryAction", "get_IsPlayInGameFullScreenMovie", "isOpenCardGameInventory" }
local function game_screen_open()
    local mm = sdk.get_managed_singleton("app.MenuManager")
    if mm == nil then return nil end
    for _, m in ipairs(GAME_SCREENS) do
        local ok, v = pcall(mm.call, mm, m)
        if ok and v == true then return m end
    end
    return nil
end
coop_game_screen_open = game_screen_open

local function busy_here()
    local om = sdk.get_managed_singleton("app.ObjectManager")
    if om == nil or om:get_field("PlayerObj") == nil then return "loading" end
    -- v0.51: a load, and its first seconds, count as loading (see coop_story_settle), and so does a screen
    -- faded to black: a friend's scene started then left the game on a black screen for good.
    if os.clock() < (ss.settle_until or 0) then return "loading" end
    local gm = sdk.get_managed_singleton("app.GameManager")
    if gm then
        local tok, title = pcall(gm.get_field, gm, "IsTitleDisp")
        if tok and title == true then return "loading" end
    end
    if coop_black_fade and coop_black_fade() then return "faded out" end
    if gm and pcall(gm.call, gm, "get_IsPause") and gm:call("get_IsPause") == true then return "paused" end
    local mm = sdk.get_managed_singleton("app.MenuManager")
    local ok, open = false, false
    if mm then ok, open = pcall(mm.call, mm, "isOpenPauseMenu") end
    if ok and open == true then return "in the menu" end
    if game_screen_open() then return "in a game screen" end
    if revive and revive.downed then return "down" end
    if local_cutscene and local_cutscene() and not only_long_scenes() then return "in a cutscene" end
    return nil
end

-- A lock with nothing behind it (v0.69). Bot sweep 2026-11-26, Chapter 4's start: the guest's player and camera stayed
-- locked on PlayerOrder's Base layer with no event running, no scene part and MenuManager.isPlayingEvent false; whatever
-- locked it (a scene of the start that was dropped or ran in the friend's game) never unlocked it. switchPlayerOperatable
-- / switchCameraOperatable(true, Base) gave the guest its player back. Done after ORPHAN_LOCK_S with a friend linked,
-- when nothing that locks a player is going on here (a real scene, an event, a grab, being down, a load or a pause) and
-- the friend isn't in a scene either.
ORPHAN_LOCK_S = 15
local orphan = { since = nil, t = 0, fights = 0 }
dbg_note{ feature = "Story cutscenes", name = "Unlock a player locked with nothing going on",
    when = "every frame, but it only works once a second, and only with a friend linked",
    reads = "PlayerOrder locks, running scenes, MenuManager.isPlayingEvent, the player's event action and grab layer, revive, busy_here, the friend's cutscene flag",
    writes = "after ORPHAN_LOCK_S: PlayerOrder.switchPlayerOperatable / switchCameraOperatable(true, Base)" }
re.on_frame(function()
    local now = os.clock()
    if now - orphan.t < 1 then return end
    orphan.t = now
    local ns = coop_net_state and coop_net_state()
    if not (coop_link_friend ~= nil and ns ~= nil and coop_link_friend(ns.kv) == true) then orphan.since = nil return end
    local om = sdk.get_managed_singleton("app.ObjectManager")
    local p = om and safe(om.get_field, om, "PlayerObj")
    local po = p and safe(p.call, p, "getComponent(System.Type)", sdk.typeof("app.PlayerOrder")) or nil
    if type(po) ~= "userdata" then orphan.since = nil return end
    local locked = safe(po.call, po, "get_isPlayerNoneOperatable") == true or safe(po.call, po, "get_isCameraNoneOperatable") == true
    local mm = sdk.get_managed_singleton("app.MenuManager")
    local gea = safe(p.call, p, "getComponent(System.Type)", sdk.typeof("app.GameEventActionController"))
    local mo = safe(p.call, p, "getComponent(System.Type)", sdk.typeof("via.motion.Motion"))
    local L = mo and safe(mo.call, mo, "getLayer", 0)
    local busy = (local_cutscene and local_cutscene() and not only_long_scenes())
        or (mm and safe(mm.call, mm, "isPlayingEvent") == true)
        or (gea and safe(gea.call, gea, "get_isPlay") == true)
        or (L and safe(L.call, L, "get_Jacked") == true)
        or (revive and revive.downed) or busy_here() ~= nil or rawget(_G, "friend_cutscene") == true
    if not locked then
        -- Free for 5 s on the game's own: whatever we gave up on is over.
        if orphan.free_t == nil then orphan.free_t = now end
        if now - orphan.free_t >= 5 then orphan.fights, orphan.gave_up = 0, nil end
        orphan.since = nil
        return
    end
    orphan.free_t = nil
    if busy then orphan.since = nil return end
    -- Locked again within 3 s of our unlock: the game means it (bot sweep FF040: 3 unlocks in 32 s). Twice, and this
    -- lock is left to the game until the player has been free 5 s.
    if orphan.unlock_t and now - orphan.unlock_t < 3 then
        orphan.unlock_t = nil
        orphan.fights = orphan.fights + 1
        if orphan.fights >= 2 and not orphan.gave_up then
            orphan.gave_up = true
            log("our player keeps being locked again right after unlocking: left to the game")
        end
    end
    if orphan.gave_up then orphan.since = nil return end
    orphan.since = orphan.since or now
    if now - orphan.since < ORPHAN_LOCK_S then return end
    orphan.since = nil
    orphan.unlock_t = now
    pcall(po.call, po, "switchPlayerOperatable(System.Boolean, app.PlayerDefine.OperationLayer)", true, 0)
    pcall(po.call, po, "switchCameraOperatable(System.Boolean, app.PlayerDefine.OperationLayer)", true, 0)
    log(string.format("our player was locked %d s with nothing going on (no scene, event, grab or menu): unlocked", ORPHAN_LOCK_S))
    note("you were stuck with nothing going on: you can move again")
end)


local apply_story_body
-- v0.53: a scene the friend's game is holding for us ("story <name> <ch> hold"): it starts there when we answer
-- "sready" (sent as ours starts, see the pending loop), or at once on "snoready" when we won't join it.
local function apply_story(name, ch, phone, hold)
    ss.ready_for = ss.ready_for or {}
    if hold then ss.ready_for[name] = os.clock() end
    local joined = apply_story_body(name, ch, phone)
    -- A tape scene held for us while we're still on our way into that tape (v0.53): kept, and answered when our own
    -- game starts it there (the requestSetup hook), so the first one in waits for the second.
    local into = math.max(coop_tape_sent_t or -1000, coop_tape_follow_t or -1000)
    if hold and not joined and ch ~= chapter() and TAPE_CHAPTERS and TAPE_CHAPTERS[ch] and os.clock() - into < 120 then
        log("friend's " .. name .. ": held for us in the tape; it starts there when we arrive")
        return
    end
    if hold and not joined then
        ss.ready_for[name] = nil
        send("snoready " .. name)
    end
end
-- Our game starts a scene the friend is holding for: tell them, so both start now.
function coop_story_started_for_friend(name)
    if ss.ready_for and ss.ready_for[name] then
        ss.ready_for[name] = nil
        send("sready " .. name)
    end
end
apply_story_body = function(name, ch, phone)
    coop_scene_t = os.clock()   -- the friend's scene is starting: no bumping for a while (v0.34)
    -- The latest scene group the friend has reached (v0.49, see sequence_open).
    local fg = ch == chapter() and seq_of(name) or nil
    if fg and (ss.friend_grp == nil or fg > ss.friend_grp) then ss.friend_grp = fg end
    -- Which scenes the friend has played (v0.50, see scene_to_start).
    if ch == chapter() then ss.friend_played = ss.friend_played or {} ss.friend_played[name] = true end
    if phone and ch == chapter() then ss.phone_scene[name] = os.clock() end
    if ch ~= chapter() then
        log("story event in another chapter, ignored: " .. name)
        if ch > 0 and (ss.last_together_t or -100) > os.clock() - 120 then
            ss.moved_on = { ch = ch, t = os.clock(), mine = chapter() }
        end
        return
    end
    -- A friend who has just come into our chapter (v0.63, drop-in): the scenes their game plays on arriving (the
    -- chapter's opening) are theirs, not the host's story. The host's game joined the opening of a guest who had
    -- dropped in at Chapter 3's start, and was pulled "next to" them by the guest's last position from Chapter 4.
    local arrived = ss.friend_arrived_t and ss.friend_arrived_t[coop_event_slot or 1]
    if not follower() and arrived and os.clock() - arrived < ARRIVE_S then
        log(string.format("friend's %s: they came into this chapter %.0f s ago (their arrival), not joined", name, os.clock() - arrived))
        return
    end
    ss.last_together_t = os.clock()
    -- Jack's scripted moves (em3000_*: through the hatch-room wall, door kicks) aren't started
    -- here any more (v0.39): each game's own Jack does them when its own player sets them off
    -- (each of you picks up the hatch key). Starting one moved our Jack out of whatever he was
    -- doing, and Jack has gone missing in Chapter 3 more than once. settings.share_jack_moves
    -- = true (in coop_settings.json) brings the old way back.
    if name:match(SCRIPTED_NAME) and not (settings and settings.share_jack_moves == true) then
        log("friend's " .. name .. " (Jack's scripted move): your Jack does it when you set it off")
        return
    end
    if played_here()[name] then
        -- We both played it: we are in step (v0.31).
        ss.in_step_until = math.max(ss.in_step_until or 0, os.clock() + IN_STEP)
        log("already played here: " .. name .. " (in step)")
        return
    end
    local start, why = scene_to_start(name)
    if start == nil then
        ss.in_step_until = math.max(ss.in_step_until or 0, os.clock() + IN_STEP)
        log("friend's " .. name .. ": not started here: " .. tostring(why))
        note("your friend is a step further on in this scene: you'll see it when you get to the same point")
        return
    end
    if start ~= name then log("friend's " .. name .. ": " .. tostring(why)) end
    local d = friend_distance()
    if ss.phone_scene[name] and scenes_on_friend(name) then
        -- Their phone call: it runs here on their body wherever we stand; nobody is moved.
        log(string.format("friend's %s is a phone call: it plays on their body here, you keep control (%s m away)", name,
            d and string.format("%.0f", d) or "?"))
        d = 0
    end
    -- v0.51: a cutscene pulls everyone in the chapter in (the owner's rule after the 2026-11-12 playtest: "cutscenes
    -- should automatically teleport everyone and start instantly when someone initiates them"). Whoever starts
    -- one, the others within SCENE_PULL_MAX m are brought next to them and it plays as soon as it has loaded there.
    -- It used to bring the guest along only from 30 m (beyond that the scene waited 10 s to load where they stood,
    -- which it never did, and was dropped), and the host only from 12 m.
    local pull = settings == nil or settings.scene_pull ~= false
    local reach = pull and SCENE_PULL_MAX or NEAR
    if d ~= nil and d > reach and not follower() then
        note(string.format("your friend is watching a cutscene (%.0f m away: you'll see it when you get there)", d))
        log(string.format("friend's %s: not joined, %.0f m away (you'll see it when you get there)", name, d))
        return
    end
    if follower() and (d == nil or d > NEAR) then
        log(string.format("friend's %s: the host leads, playing it here (%s m away)", name, d and string.format("%.0f", d) or "?"))
        note("the host's story: you're brought into this scene")
    end
    local busy = busy_here()
    -- Brought next to them first (v0.48: joining from the next room left a player locked in the boiler room while
    -- the fight started without them). Not while we're loading or in a scene of our own: then when it starts.
    local pulled = false
    if not busy and d and d > 2.5 and d <= reach and teleport_to_friend then
        local tok = select(2, pcall(teleport_to_friend, reach))
        pulled = tok == true
        log(string.format("friend's %s: joining from %.0f m away, brought next to them first (%s)", name, d, tostring(tok)))
    end
    -- for: the friend's scene this one stands in for (v0.50): a sequence started here from its _00 because the
    -- friend played a later scene of it. Dropped if our own game plays that scene itself meanwhile.
    local instead = start ~= name and name or nil
    if busy then
        ss.pending[start] = { ch = ch, t = os.clock(), slot = coop_event_slot or 1, instead = instead, pull = d and d > 2.5 }
        log("friend's " .. start .. " waits: you're " .. busy)
    elseif setting_loaded(start) then
        -- Not at once (v0.48): a scene the friend's story step started comes with that step ("prog"), and the
        -- step played it here a second time (the morgue scene twice in a bot test). It waits a moment, and while
        -- a step is queued; the step plays it, and if the step doesn't, it plays after (the loop below).
        -- v0.53: 0.5 s (was 1.5): the step comes before or with the scene (events arrive in order, read 5 times a
        -- second), and the "a step is queued" wait below still covers it; the friend's scene now starts here about
        -- half a second after theirs instead of two.
        ss.pending[start] = { ch = ch, t = os.clock(), slot = coop_event_slot or 1, hold_until = os.clock() + 0.5, instead = instead }
    else
        -- After a pull the area streams in around us: allow it longer to load (PENDING_PULLED).
        ss.pending[start] = { ch = ch, t = os.clock(), slot = coop_event_slot or 1, instead = instead, pulled = pulled }
        log("waiting for " .. start .. " to load here")
    end
    ss.pending[start].friend_name = name
    return true
end

-- Together: in step, or the friend within NEAR m (v0.31). Progress and finished events that
-- arrive while apart are kept (ss.missed) and applied when we are together again.
ss.missed = ss.missed or {}
-- Our own cutscene, and when the last one ended (v0.32).
ss.cut_on, ss.cut_end_t = false, -100
dbg_note{ feature = "Story cutscenes", name = "Note when our own cutscene starts and ends",
    when = "every frame",
    reads = "local_cutscene(): the game's list of running event controllers",
    writes = "ss.cut_on and the time the last cutscene ended (in memory)" }
re.on_frame(function()
    local on = local_cutscene and local_cutscene() or false
    if ss.cut_on and not on then ss.cut_end_t = os.clock() end
    ss.cut_on = on
end)
dbg_note{ feature = "Story cutscenes", name = "Bring us next to the friend after their scene moved them",
    when = "every frame (timers in memory)",
    reads = "the regroup timer; the distance to the friend's ghost; the retargeted-scene list",
    writes = "when due: teleport_to_friend (warps our player); gives a scene part back after 15 minutes" }
re.on_frame(function()
    local now = os.clock()
    if ss.regroup_t and now >= ss.regroup_t then
        ss.regroup_t = nil
        local d = friend_distance()
        if d and d > 6 and d < 400 and teleport_to_friend then
            local tok = select(2, pcall(teleport_to_friend))
            log(string.format("after your friend's scene they are %.0f m away: brought next to them (%s)", d, tostring(tok)))
            note(tok == true and "your friend's scene moved them: you're brought along"
                or string.format("your friend's scene took them %.0f m away: go to them", d))
        end
    end
    -- A part still pointed at the friend 15 minutes on (its scene never ended here): give it back.
    for name, r in pairs(ss.retargeted) do
        if now - r.t > 900 then scene_given_back(name) end
    end
end)
local HOLD_AFTER_CUTSCENE = 8
-- Also while our own scene sequence is still playing out (v0.39): the friend's progress from
-- the end of the dinner would skip our chair, as it did on 2026-11-02. Our game sets those
-- numbers itself when it gets there; whatever is still behind afterwards is copied then.
local function hold_for_cutscene()
    if ss.cut_on and only_long_scenes() then
        if not ss.long_said then ss.long_said = true log("a long story event is running here: your friend's story is copied anyway") end
        return false
    end
    ss.long_said = nil
    return ss.cut_on or os.clock() - ss.cut_end_t < HOLD_AFTER_CUTSCENE or sequence_open()
end

local function together()
    if follower() then return true end
    if in_step() then return true end
    local d = friend_distance(coop_event_slot or 1)
    return d ~= nil and d <= NEAR
end

-- Story progress, for real (v0.48). Each part of the story (c03_2_Main...) is an object "<part>Flow"
-- with a state machine whose states are named by the progress numbers ("400", "600"...) and an
-- app.GameFlowActiveControl; GameFlowFsmManager.Flows maps the progress hash to it. The number alone is
-- only a record: until now the friend's number was copied with setProgressiveNo and nothing else moved,
-- so on 2026-11-10 one game sat in c03_2 at "800" for the rest of the evening (no phone call, no new
-- objective, the old ones still up) while the other was in c03_3. GameFlowActiveControl.sendNo(n) is the
-- game's own step: tested 2026-11-11 on c03_2 (400 -> sendNo(600)): the number, the machine and the
-- game's next beat (its scene, the objective checked off) all followed. At FlowEndNo the part ends and
-- the next one starts. So the friend's numbers are queued per part and taken one at a time, lowest
-- first, 1.5 s apart, never during our own scene: every step's own logic runs, none is jumped over.
-- settings.story_flow_steps = false goes back to copying the number only.
ss.steps = ss.steps or {}          -- hash -> { ch, list = ascending values, t = last step }
local function flow_control(fm, hash)
    local flows = fm and fm:get_field("Flows")
    local ok, c = pcall(function() return flows:call("get_Item", hash) end)
    return ok and c or nil
end
-- The next step of a story part between where ours is and the friend's (v0.48): a catch-up from 400 to
-- 800 goes 500, 600, 700, 800, so each step's own beat (a scene, an objective, a door) happens here too.
-- The part's machine names its steps by number (c03_1: 0, 100, ... 1100; c03_2: 0 100 200 400 500 600 700).
local function next_state(hash, cur, value)
    local ctl = flow_control(flow_mgr(), hash)
    local go = ctl and ctl:call("get_GameObject")
    local fsm = go and go:call("getComponent(System.Type)", sdk.typeof("via.fsm.Fsm"))
    if fsm == nil then return value end
    for v = cur + 10, value - 10, 10 do
        if fsm:call("hasState(System.String)", tostring(v)) == true then return v end
    end
    return value
end
local function step_story(hash, value)
    local fm = flow_mgr()
    local var = fm and fm:call("getProgressiveNo(System.UInt32)", hash)
    local cur = var and var:call("get_S32") or 0
    if value <= cur then return false end
    ss.applying[string.format("pg:%08x", hash)] = os.clock()
    local ctl = not (settings and settings.story_flow_steps == false) and flow_control(fm, hash) or nil
    local how = "number only"
    if ctl then
        local go = ctl:call("get_GameObject")
        local fsm = go and go:call("getComponent(System.Type)", sdk.typeof("via.fsm.Fsm"))
        local is_state = fsm and fsm:call("hasState(System.String)", tostring(value)) == true
        local is_end = tonumber(ctl:get_field("FlowEndNo")) == value
        if is_state or is_end then
            local ok, err = pcall(ctl.call, ctl, "sendNo(System.Int32)", value)
            how = ok and ("story part " .. tostring(go:call("get_Name")) .. (is_end and " ends" or " steps")) or ("sendNo ERR " .. tostring(err))
            if ok then ss.in_step_until = math.max(ss.in_step_until or 0, os.clock() + IN_STEP) end
        end
    end
    if how == "number only" or how:find("ERR") then
        pcall(fm.call, fm, "setProgressiveNo(System.UInt32, System.Int32)", hash, value)
    end
    ss.applied = ss.applied + 1
    log(string.format("progress %08x %d -> %d (from the friend; %s)", hash, cur, value, how))
    return true
end
local function apply_prog(hash, value, ch)
    if ch ~= chapter() then return end
    local q = ss.steps[hash]
    if q == nil or q.ch ~= ch then q = { ch = ch, list = {}, t = -100 } ss.steps[hash] = q end
    for _, v in ipairs(q.list) do if v == value then return end end
    q.list[#q.list + 1] = value
    table.sort(q.list)
end
dbg_note{ feature = "Story progress", name = "Copy the friend's story steps one at a time",
    when = "every frame (returns at once with nothing queued); works every 0.5 s while steps are queued",
    reads = "the queue of the friend's steps, GameFlowFsmManager.getProgressiveNo, whether we are together and not in a scene",
    writes = "steps the story forward (step_story) one step per pass, 1.5 s apart" }
re.on_frame(function()
    if next(ss.steps) == nil then return end
    local now = os.clock()
    if now - (ss.steps_t or 0) < 0.5 then return end
    ss.steps_t = now
    local ch = chapter()
    local can = together() and not hold_for_cutscene()
    for hash, q in pairs(ss.steps) do
        if q.ch ~= ch or #q.list == 0 then
            ss.steps[hash] = nil
        elseif can and now - q.t >= 1.5 then
            local v = q.list[1]
            local fm = flow_mgr()
            local var = fm and fm:call("getProgressiveNo(System.UInt32)", hash)
            local cur = var and var:call("get_S32") or 0
            -- The serum choice (v0.58): a step past it waits a few seconds for the friend's choice to arrive.
            if ss.choice_holds and ss.choice_holds(hash, cur, v, now) then return end
            local okn, nx = pcall(next_state, hash, cur, v)
            if not okn or nx == nil or nx >= v then
                nx = v
                table.remove(q.list, 1)
            end
            if pcall(step_story, hash, nx) then q.t = now end
            return                         -- one step a pass: the next waits for what this one starts
        elseif not can and not q.said then
            q.said = true
            log(string.format("progress %08x %d waits (%s)", hash, q.list[1], together() and "your scene is playing or just ended" or "you're apart"))
            -- v0.48: say so on screen when it's waiting for the two of you to be together (a catch-up
            -- pressed from across the map did nothing visible).
            if not together() then note("your friend's story is further on: go to them and it catches up here") end
        end
        if can then q.said = nil end
    end
end)

local function apply_btlend(hash, ch)
    if ch ~= chapter() then return end
    if hold_for_cutscene() or not together() then
        ss.missed[string.format("be:%08x", hash)] = { kind = "btlend", hash = hash, ch = ch }
        log(string.format("fight %08x end kept for later (%s)", hash, together() and "your scene is playing" or "you're apart"))
        return
    end
    local fm = flow_mgr()
    if fm and not fm:call("isBattleEnded(System.UInt32)", hash) then
        ss.applying[string.format("be:%08x", hash)] = os.clock()
        pcall(fm.call, fm, "sendBattleEnded(System.UInt32)", hash)
        log(string.format("fight %08x ended (from the friend)", hash))
    end
end

local function apply_evend(hash, ch)
    if ch ~= chapter() then return end
    if hold_for_cutscene() then
        ss.missed[string.format("ee:%08x", hash)] = { kind = "evend", hash = hash, ch = ch }
        log(string.format("event %08x end held (your scene is playing, just ended, or its sequence is still playing out)", hash))
        return
    end
    if not together() then
        ss.missed[string.format("ee:%08x", hash)] = { kind = "evend", hash = hash, ch = ch }
        log(string.format("event %08x end not copied yet (apart; kept for when you're together)", hash))
        return
    end
    local fm = flow_mgr()
    if fm and not fm:call("isEventEnded(System.UInt32)", hash) then
        ss.applying[string.format("ee:%08x", hash)] = os.clock()
        pcall(fm.call, fm, "sendEventEnded(System.UInt32)", hash)
        log(string.format("event %08x ended (from the friend)", hash))
    end
end

-- Saving together. Each player saves their own game; to load matching points later,
-- both should save at the same moment. When ours really saves (only possible with "Allow
-- saving" on; the save guard blocks the rest), tell the friend, and show theirs.
local sdm = sdk.find_type_definition("app.SaveDataManager")
local function hook_save(method_name, kind)
    local m = sdm:get_method(method_name)
    if m == nil then log("save hook missing: " .. method_name) return end
    dbg_note{ feature = "Saving together", name = "Tell the friend when our game really saves (" .. kind .. ")",
        when = "when the game calls SaveDataManager." .. method_name,
        reads = "Options: Allow saving",
        writes = "sends 'saved " .. kind .. " <chapter>' (only when saving is allowed; the save guard blocks it otherwise)" }
    sdk.hook(m, function(args)
        pcall(function()
            if settings and settings.allow_saving then send(string.format("saved %s %d", kind, chapter())) end
        end)
    end, function(r) return r end)
end
hook_save("saveFileMenuRequestExecute()", "menu")
hook_save("saveFileAutoRequestExecute()", "auto")

-- Loading a save (v0.39) -------------------------------------------------------------
-- Continue, Load Game and a retry after dying load a save, and the story then stands where
-- that save was. Scenes played after that point count as not played again (so the friend's
-- can be shown again, and ours are sent again); waiting scenes and kept progress are dropped;
-- and our catch-up list loses the changes made after it (coop_talk), so the friend's game
-- isn't sent changes our world no longer has. Checked 8 s after the new player appears.
ss.load = nil
local function on_load(what)
    local om = sdk.get_managed_singleton("app.ObjectManager")
    local p = om and om:get_field("PlayerObj")
    local addr = p and p:get_address() or 0
    if ss.load and ss.load.addr == addr then return end   -- the same load, another step of it
    ss.load = { t = os.clock(), what = what, addr = addr }
    log("a save is loading (" .. what .. ")")
    if coop_story_settle then pcall(coop_story_settle, "a save is loading") end
end
-- The level load from save data is what counts (a load request can be cancelled in the menu);
-- the requests only if this build has no such method.
do
    local function hook_load(mname)
        local m = sdm:get_method(mname)
        if m == nil then return false end
        dbg_note{ feature = "Saving together", name = "A save is loading (" .. mname .. ")",
            when = "when the game calls SaveDataManager." .. mname .. " (Continue, Load Game or a retry after dying)",
            reads = "ObjectManager.PlayerObj address",
            writes = "starts the 8 s wait for the new player (ss.load); one log line" }
        return pcall(sdk.hook, m, function(args) pcall(on_load, mname) end, function(r) return r end)
    end
    if not hook_load("loadLevelUsingLoadData") then
        for _, mname in ipairs({ "loadFileAutoRequest", "loadFileMenuRequest", "loadFileTitleRequest" }) do hook_load(mname) end
        log("save load: watching the load requests")
    end
end

-- Loads and the black screen (v0.51). A friend's scene that waited here was started while this game was loading
-- (a New Game, Continue, a chapter jump): the old player is still there for a moment, so nothing stopped it, and
-- the game came out of the load on a black screen for good. That is the "friend only sees black unless both
-- played the opening before connecting" of the 2026-11-12 playtest (bot test 2026-11-13: reproduced by a scene
-- waiting while the game started the opening; the opening alone, or a real New Game alone, came out fine).
-- Now any load drops the friend's waiting scenes, and for SETTLE_S s after it (and while the player object is
-- new) this game counts as loading, so nothing of theirs is started (busy_here).
SETTLE_S = 12
function coop_story_settle(why)
    ss.settle_until = math.max(ss.settle_until or 0, os.clock() + SETTLE_S)
    local n = 0
    for k in pairs(ss.pending) do ss.pending[k] = nil n = n + 1 end
    if n > 0 then log(string.format("%s: %d of your friend's waiting scene(s) dropped (they were for before the load)", why, n)) end
end
-- Into a VHS tape together (v0.53). Putting a tape in the deck changes chapter; the friend's game followed only
-- after ours was in, then loaded on its own, and the tape's scripted NPCs ran ahead in ours. Now, when we've
-- just used a tape (coop_world sets coop_tape_sent_t) and the friend is with us, our chapter change waits until
-- their game says it's on its way ("tapejump", coop_dummy's tape follow) or TAPE_HOLD_MAX s pass; both games
-- then load the tape at the same time, and its first scene waits for both (hold_scene, TAPE_READY_MAX).
TAPE_HOLD_MAX = 6
TAPE_READY_MAX = 30
ss.tape_hold = nil
local function tape_hold_applies()
    -- Opt-in with the scene hold (settings.scene_ready = true): not tried on a real tape deck yet.
    if not (settings and settings.scene_ready == true) then return false end
    if ss.tape_pass or ss.tape_hold then return false end
    if settings and settings.follow_tapes == false then return false end
    if not (coop_tape_sent_t and os.clock() - coop_tape_sent_t < 15) then return false end
    return coop_friend_sample ~= nil and coop_friend_sample() ~= nil
end
local function release_tape(why)
    local h = ss.tape_hold
    if h == nil then return end
    ss.tape_hold = nil
    ss.tape_pass = true
    local gm = sdk.get_managed_singleton("app.GameManager")
    local ok, err
    if h.key then
        ok, err = pcall(gm.call, gm, "chapterJumpRequest(System.String, System.Boolean, System.String)", h.key, h.flag, h.extra or "")
    else
        ok, err = pcall(gm.call, gm, "nextChapterJumpRequest")
    end
    ss.tape_pass = false
    log(string.format("into the tape: %s (held %.1f s)%s", why, os.clock() - h.t, ok and "" or (" ERR " .. tostring(err))))
end
function coop_story_tape_jump()
    if ss.tape_hold then release_tape("your friend is on the way too") end
end
dbg_note{ feature = "VHS tapes", name = "Let a held tape jump go when the friend's game doesn't follow",
    when = "every frame",
    reads = "the tape jump held for the friend and how long it has waited",
    writes = "asks the game for that chapter jump after TAPE_HOLD_MAX (6 s)" }
re.on_frame(function()
    if ss.tape_hold and os.clock() - ss.tape_hold.t > TAPE_HOLD_MAX then release_tape("your friend's game didn't follow in time") end
end)
local function managed_text(ptr)
    local ok, s = pcall(function() local o = sdk.to_managed_object(ptr) return o and o:call("ToString") end)
    return ok and s ~= nil and tostring(s) or nil
end
do
    local gmt = sdk.find_type_definition("app.GameManager")
    for _, mname in ipairs({ "newGameRequest", "newGameRequest_Chapter7",
        "chapterJumpRequest(System.String, System.Boolean, System.String)", "nextChapterJumpRequest" }) do
        local m = gmt and gmt:get_method(mname)
        local short = mname:match("^[%w_]+")
        dbg_note{ feature = "Loads and the black screen", name = "A load or new game started: drop the friend's waiting scenes",
            when = "when the game calls GameManager." .. short .. " (a New Game or chapter jump begins)",
            reads = "the table of the friend's waiting scenes; whether we're going into a VHS tape with the friend",
            writes = "starts the 12 s settle time (nothing of the friend's is started meanwhile) and forgets the waiting scenes; holds a tape's chapter jump until the friend's game follows (TAPE_HOLD_MAX)" }
        if m then
            pcall(sdk.hook, m, function(args)
                local hold = false
                pcall(function()
                    if (short == "chapterJumpRequest" or short == "nextChapterJumpRequest") and tape_hold_applies() then
                        local h = { t = os.clock() }
                        if short == "chapterJumpRequest" then
                            h.key, h.flag, h.extra = managed_text(args[3]), (sdk.to_int64(args[4]) & 0xff) ~= 0, managed_text(args[5])
                        end
                        if short == "nextChapterJumpRequest" or h.key then
                            ss.tape_hold, hold = h, true
                            log("into the tape: waiting for your friend's game to follow (" .. tostring(h.key or "next chapter") .. ")")
                        end
                    end
                    if not hold then coop_story_settle("a load started (" .. short .. ")") end
                end)
                if hold then return sdk.PreHookResult.SKIP_ORIGINAL end
            end, function(r) return r end)
        end
    end
    -- A save load settles too: from on_load (one hook on loadLevelUsingLoadData).
end
-- A new player object (the game swapped it in a load) restarts the settle time too.
dbg_note{ feature = "Loads and the black screen", name = "A new player object means a load: restart the settle time",
    when = "every frame",
    reads = "ObjectManager.PlayerObj address (two game calls every frame)",
    writes = "ss.settle_until (in memory)" }
re.on_frame(function()
    local om = sdk.get_managed_singleton("app.ObjectManager")
    local p = om and om:get_field("PlayerObj")
    local addr = p and p:get_address() or 0
    if addr ~= (ss.player_addr or 0) then
        ss.player_addr = addr
        -- Not the first player this script sees (scripts started mid-game): only a swap after we had one.
        if addr ~= 0 and ss.had_player and addr ~= ss.had_player then
            ss.settle_until = math.max(ss.settle_until or 0, os.clock() + SETTLE_S)
        end
        if addr ~= 0 then ss.had_player = addr end
    end
end)

-- The screen fade (app.FadeControl "Fade_In_Out_Black"): state 0 when it's clear. Found once per scene.
local fade = { comp = nil, t = -100 }
function coop_black_fade()
    local now = os.clock()
    -- Found again after every load (a new player object): the old scene's fade is gone with it.
    if fade.for_player ~= ss.player_addr then fade.comp, fade.for_player, fade.t = nil, ss.player_addr, -100 end
    if fade.comp == nil and now - fade.t > 5 then
        fade.t = now
        pcall(function()
            local sm = sdk.get_native_singleton("via.SceneManager")
            local scene = sdk.call_native_func(sm, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
            local arr = scene:call("findComponents(System.Type)", sdk.typeof("app.FadeControl"))
            for i = 0, arr:call("get_Count") - 1 do
                local c = arr:call("get_Item", i)
                local go = c:call("get_GameObject")
                if go and tostring(go:call("get_Name")):find("Black", 1, true) then fade.comp = c end
            end
        end)
    end
    if fade.comp == nil then return false end
    local ok, st = pcall(fade.comp.call, fade.comp, "get_FadeState")
    if not ok then fade.comp = nil return false end
    return st ~= nil and st ~= 0
end
-- A black screen that never clears (v0.51): with a friend connected, faded to black for FADE_STUCK_S s while
-- nothing plays (no cutscene, no movie, not loading, not paused) and the player is there, it's faded back in.
FADE_STUCK_S = 25
dbg_note{ feature = "Loads and the black screen", name = "Fade back in from a black screen that never clears",
    when = "every frame, but it only works once a second, and only with a friend linked",
    reads = "the FadeControl 'Black' fade state (the component is searched for in the scene every 5 s until found), cutscene, loading and player state",
    writes = "after 25 s of black with nothing playing: FadeControl.requestFadeIn (at most once a minute)" }
re.on_frame(function()
    local now = os.clock()
    if now - (fade.check_t or 0) < 1 then return end
    fade.check_t = now
    local ns = coop_net_state and coop_net_state()
    local linked = coop_link_friend ~= nil and ns ~= nil and coop_link_friend(ns.kv) == true
    if not linked then fade.black_since = nil return end
    local black = coop_black_fade()
    local quiet = not (local_cutscene and local_cutscene()) and now >= (ss.settle_until or 0)
    local om = sdk.get_managed_singleton("app.ObjectManager")
    local there = om and om:get_field("PlayerObj") ~= nil
    if not (black and quiet and there) then fade.black_since = nil return end
    fade.black_since = fade.black_since or now
    if now - fade.black_since < FADE_STUCK_S or now - (fade.lifted_t or -100) < 60 then return end
    fade.lifted_t = now
    local ok = pcall(fade.comp.call, fade.comp, "requestFadeIn")
    log(string.format("the screen stayed black for %d s with nothing playing: faded back in (%s)", FADE_STUCK_S,
        ok and "ok" or "ERR"))
    note("the screen was stuck on black: it's faded back in")
end)
local function after_load()
    local ch = chapter()
    local clock = coop_story_clock()
    local n = 0
    -- Where the save stands is only known from progress the game has set this chapter.
    -- (Before the dinner every stage of Chapter 3 is at 0: a clock of 0 is a real point.)
    local known = ss.prog_ch == ch and next(ss.prog_seen) ~= nil
    if not known then
        log("save loaded: where it stands in the story can't be told yet; played scenes kept")
    elseif ss.played_chapter == ch then
        for name, c in pairs(ss.played) do
            if type(c) == "number" and c >= clock then ss.played[name] = nil n = n + 1 end
        end
        if n > 0 then save_played() end
    end
    ss.pending, ss.missed, ss.in_step_until, ss.last_seq, ss.running = {}, {}, nil, nil, {}
    ss.steps = {}
    ss.friend_grp, ss.friend_played = nil, {}
    ss.obj_done = {}   -- v0.48: starts the friend's objective check-offs over
    log(string.format("save loaded: chapter %d, story clock %d; %d scenes from after it count as not played", ch, clock, n))
    if known and coop_talk_rewind then pcall(coop_talk_rewind, ch, clock) end
    send(string.format("rewind %d %d", ch, clock))
end
dbg_note{ feature = "Saving together", name = "After loading a save: wait for the new player, then reset the story record",
    when = "every frame (a flag check; works only for 8 s after a load starts)",
    reads = "ObjectManager.PlayerObj address",
    writes = "after the new player has been there 8 s: counts scenes after the save as unplayed, drops waiting scenes and kept progress, rewinds the catch-up list" }
re.on_frame(function()
    local L = ss.load
    if L == nil then return end
    local now = os.clock()
    if now - L.t > 300 then ss.load = nil log("save load: no new player within 5 minutes, nothing changed") return end
    local om = sdk.get_managed_singleton("app.ObjectManager")
    local p = om and om:get_field("PlayerObj")
    if p == nil then L.gone, L.back = true, nil return end
    if p:get_address() ~= L.addr or L.gone then
        L.back = L.back or now
        if now - L.back >= 8 then
            ss.load = nil
            local ok, err = pcall(after_load)
            if not ok then log("save load ERR " .. tostring(err)) end
        end
    end
end)

local function on_saved(kind, ch)
    local what = kind == "menu" and "Your friend saved at a tape recorder" or "Your friend's game autosaved"
    if not (settings and settings.allow_saving) then
        note(what .. " (your saving is off: turn on Allow saving to keep matching saves)")
    elseif kind == "menu" then
        note(what .. ": save too so your games match")
    else
        note(what)
    end
end

-- Called by coop_enemies.lua for every incoming event; true if it was ours.
-- How far the friend's story is (their newest progress number per stage, this chapter).
ss.friend_prog = {}
local function track_friend(text)
    local h, v, ch = text:match("^prog (%x+) (%-?%d+) (%-?%d+)")
    if not h then return end
    h, v, ch = tonumber(h, 16), tonumber(v), tonumber(ch)
    local f = ss.friend_prog[h]
    if f == nil or f.ch ~= ch or v > f.v then ss.friend_prog[h] = { v = v, ch = ch } end
end

-- Every 20 s: is one of us two or more story steps ahead (same chapter)? Then say so, at
-- most every 3 minutes. Last session nobody could tell their stories had split until the
-- wall didn't break.
local drift = { t = 0, said_t = -1000 }
dbg_note{ feature = "Story progress", name = "Are we ahead of or behind the friend in the story?",
    when = "every frame, but it only looks every 20 s",
    reads = "GameFlowFsmManager.getProgressiveNo for each stage the friend has sent",
    writes = "ss.drift and, at most every 3 minutes, an on-screen message" }
re.on_frame(function()
    local now = os.clock()
    if now - drift.t < 20 then return end
    drift.t = now
    pcall(function()
        local fm = flow_mgr()
        if fm == nil then return end
        local ch = chapter()
        local ahead, behind = false, false
        for h, f in pairs(ss.friend_prog) do
            if f.ch == ch then
                local var = fm:call("getProgressiveNo(System.UInt32)", h)
                local mine = var and var:call("get_S32") or 0
                if f.v >= mine + 200 then ahead = true end
                if mine >= f.v + 200 and mine > 0 then behind = true end
            end
        end
        ss.drift = ahead and "ahead" or behind and "behind" or nil
        if ss.drift and now - drift.said_t > 180 then
            drift.said_t = now
            note(ss.drift == "ahead"
                and "your friend is further on in the story than you: stay together, or use Go to my friend's chapter"
                or "you are further on in the story than your friend: wait for them, or they can use Go to my friend's chapter")
        end
    end)
end)

-- Where each of us is in the story (v0.41), for the lobby (who's behind) and giving items:
-- "spos <chapter> <story clock>" every 10 s. Same chapter: the story clocks compare (the same
-- stages are set at the chapter's load in every game); else the chapters' story order.
local CHAPTER_ORDER = { [2] = 1, [4] = 2, [13] = 3, [5] = 4, [14] = 5, [6] = 6 }
ss.spos = ss.spos or {}
-- The difficulty rides along (v0.42): app.GameManager.GameDifficulty, Easy 0 (Casual), Normal 1,
-- Hard 2 (Madhouse); -1 on the title screen. Different difficulties give enemies different health
-- and damage, so the lobby and the status line say so.
local DIFF_NAMES = { [0] = "Casual", [1] = "Normal", [2] = "Madhouse" }
function coop_my_difficulty()
    local gm = sdk.get_managed_singleton("app.GameManager")
    if gm == nil then return -1 end
    local ok, v = pcall(gm.call, gm, "get_gameDifficulty")
    if not ok or v == nil then ok, v = pcall(gm.get_field, gm, "GameDifficulty") end
    return tonumber(ok and v or -1) or -1
end
function coop_difficulty_name(v) return DIFF_NAMES[v] end
-- Friend k's difficulty, or nil if not known (an older version, or not heard from lately).
function coop_friend_difficulty(k)
    local f = ss.spos[k or 1]
    if f == nil or os.clock() - f.t > 40 or f.diff == nil or f.diff < 0 then return nil end
    return f.diff
end
-- Said once per friend and pair of difficulties.
ss.diff_said = ss.diff_said or {}
local function check_difficulty(k)
    local theirs, mine = coop_friend_difficulty(k), coop_my_difficulty()
    if theirs == nil or mine < 0 or theirs == mine then return end
    local key = k .. ":" .. theirs .. ":" .. mine
    if ss.diff_said[key] then return end
    ss.diff_said[key] = true
    note(string.format("%s plays on %s and you on %s: enemies won't match. Play on the same difficulty.",
        k == 1 and "Your friend" or ("Friend " .. k), DIFF_NAMES[theirs] or "?", DIFF_NAMES[mine] or "?"))
end
-- A friend's arrival in our chapter (v0.63, drop-in): their samples' chapter (coop_dummy, ~30 a second) turning into
-- ours. For ARRIVE_S after it, the scenes their game plays (the chapter's opening) aren't joined here (apply_story_body).
ARRIVE_S = 60
ss.friend_arrived_t = ss.friend_arrived_t or {}
ss.friend_ch_seen = ss.friend_ch_seen or {}
dbg_note{ feature = "Story cutscenes", name = "Notice a friend arriving in our chapter",
    when = "every frame, but it only looks every 0.5 s",
    reads = "each friend's chapter from their samples (coop_net_state), our chapter",
    writes = "ss.friend_arrived_t[slot] when a friend's chapter turns into ours" }
re.on_frame(function()
    local now = os.clock()
    if now - (ss.arrive_t or 0) < 0.5 then return end
    ss.arrive_t = now
    local mine = chapter()
    for k = 1, 3 do
        local env = coop_slot_envs and coop_slot_envs[k]
        local f = env and rawget(env, "coop_net_state") or (k == 1 and coop_net_state) or nil
        local st = f and f() or nil
        local h = type(st) == "table" and st.history or nil
        local last = type(h) == "table" and h[#h] or nil
        local theirs = type(last) == "table" and last.t and now - last.t < 3 and st.peer_chapter or nil
        if theirs then
            local seen = ss.friend_ch_seen[k]
            if theirs == mine and seen ~= nil and seen ~= mine then
                ss.friend_arrived_t[k] = now
                log(string.format("friend %d came into this chapter (from %s)", k, tostring(seen)))
            end
            ss.friend_ch_seen[k] = theirs
        end
    end
end)
dbg_note{ feature = "Story progress", name = "Tell the friend where we are in the story",
    when = "every frame, but it only works every 10 s",
    reads = "our chapter, the story clock, the difficulty",
    writes = "sends 'spos <chapter> <clock> <difficulty>'" }
re.on_frame(function()
    local now = os.clock()
    if now - (ss.spos_t or 0) < 10 or not coop_send_event then return end
    ss.spos_t = now
    local ch, d = chapter(), -1
    if ch ~= 3 and ch ~= 0 then d = coop_my_difficulty() end   -- not on the title screen or booting
    pcall(coop_send_event, string.format("spos %d %d %d", ch, coop_story_clock(), d))
end)
-- We are "behind", "ahead" or "same" as friend slot k; nil when it can't be told.
function coop_story_compare(k)
    local f = ss.spos[k or 1]
    if f == nil or os.clock() - f.t > 40 then return nil end
    local my = chapter()
    if my == f.ch then
        local c = coop_story_clock()
        if c < f.clock then return "behind" elseif c > f.clock then return "ahead" end
        return "same"
    end
    local a, b = CHAPTER_ORDER[my], CHAPTER_ORDER[f.ch]
    if a == nil or b == nil then return nil end
    if a < b then return "behind" elseif a > b then return "ahead" end
    return "same"
end

-- Objectives (v0.48). "After my friend opened the door it didn't clear 'get out of the house' for me"
-- (2026-11-10): an objective one game checks off (app.ObjectiveControl.removeObjectiveItem) is checked
-- off in the other too, found there by its ObjectiveId. Only checking off: adding one from outside could
-- collide with the game adding it itself later. Not while loading (every objective leaves then), and
-- only with Share story on.
local function obj_guid(g)
    local b = {}
    for i = 0, 7 do b[#b + 1] = string.format("%02x", (g:get_field("mData4_" .. i) or 0) & 0xFF) end
    return string.format("%08x%04x%04x%s", (g:get_field("mData1") or 0) & 0xFFFFFFFF,
        (g:get_field("mData2") or 0) & 0xFFFF, (g:get_field("mData3") or 0) & 0xFFFF, table.concat(b))
end
-- Found by comparing the active list once a second (a hook on removeObjectiveItem can't be exercised by
-- the bot tests). A load, a chapter change or a player swap in between starts the comparison over.
local function active_objectives()
    local om = sdk.get_managed_singleton("app.ObjectiveManager")
    local list = om and om:call("getEnableOvjectives")
    if list == nil then return nil end
    local set = {}
    for i = 0, (list:call("get_Count") or 0) - 1 do
        local id = tostring(list:call("get_Item", i):get_field("ObjectiveId")):gsub("-", ""):lower()
        set[id] = true
    end
    return set
end
ss.obj_prev, ss.obj_t, ss.obj_busy_n, ss.obj_ch = nil, 0, nil, nil
dbg_note{ feature = "Story progress", name = "Share objectives checked off",
    when = "every frame, but it only works once a second",
    reads = "the game's active objectives list (ObjectiveManager); compares with the last second's",
    writes = "sends 'objdone <id> <chapter>' for one that disappeared here; checks off ones the friend finished" }
re.on_frame(function()
    local now = os.clock()
    if now - ss.obj_t < 1 then return end
    ss.obj_t = now
    local ok, cur = pcall(active_objectives)
    if not ok or cur == nil then ss.obj_prev = nil return end
    local bn = coop_busy_state and coop_busy_state.n or 0
    local ch = chapter()
    if ss.obj_prev and ss.obj_busy_n == bn and ss.obj_ch == ch and sharing() then
        for id in pairs(ss.obj_prev) do
            if not cur[id] and not (ss.obj_applied and ss.obj_applied[id]) then
                send(string.format("objdone %s %d", id, ch))
                log("objective checked off here: " .. id)
            end
        end
    end
    ss.obj_prev, ss.obj_busy_n, ss.obj_ch, ss.obj_applied = cur, bn, ch, nil
    -- One the friend checked off before it was listed here (objectives register a few seconds after a
    -- load): checked off now.
    for id, d in pairs(ss.obj_done or {}) do
        if d.ch ~= ch or now - d.t > 1800 then ss.obj_done[id] = nil
        elseif cur[id] and ss.obj_apply then pcall(ss.obj_apply, id, ch) end
    end
end)
ss.obj_done = ss.obj_done or {}   -- the friend's check-offs: applied when that objective is active here
local function apply_objdone(id, ch)
    if ch ~= chapter() or not sharing() then return end
    ss.obj_done[id] = { ch = ch, t = os.clock() }
    local sc = sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"), sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
    local arr = sc and sc:call("findComponents(System.Type)", sdk.typeof("app.ObjectiveControl"))
    local om = sdk.get_managed_singleton("app.ObjectiveManager")
    local list = om and om:call("getEnableOvjectives")
    local active = {}
    for i = 0, (list and list:call("get_Count") or 0) - 1 do
        active[tostring(list:call("get_Item", i):get_field("ObjectiveId")):gsub("-", ""):lower()] = true
    end
    for _, c in ipairs(arr_items(arr)) do
        local g = c:get_field("ObjectiveId")
        if g and obj_guid(g) == id then
            if active[id] then
                ss.obj_applied = ss.obj_applied or {}
                ss.obj_applied[id] = true   -- ours to do, not to send back
                local ok, err = pcall(c.call, c, "removeObjectiveItem")
                log("objective " .. id .. " checked off (your friend's game did)" .. (ok and "" or (" ERR " .. tostring(err))))
                note("an objective was checked off: your friend did it")
            end
            return
        end
    end
end

ss.obj_apply = apply_objdone

-- Story flags (v0.57). ------------------------------------------------------------------------------------------
-- RE7 keeps its story state in global variables (via.userdata.GlobalUserData.get_VariablesHub(): 93 named sets such
-- as c03_2_Main_Flag, c03_Objective_Flag, ProgressiveNumber). The story flows advance on their own when their
-- milestone flags turn true: at c03_2 step 400, setting c03_2_Main_OpenTrayInWorkshopKey moved it to 500 within a
-- second, and c03_2_Main_GetCrestInFreezerRoom to 600 (bot test 2026-11-23). A milestone done in one game (a tray
-- opened, a crest found, a puzzle solved) never set the flag in the other, so that story waited for good; the
-- owner's own save sat at c03_2 400 that way. Now the milestone and objective flags that turn true in one game are
-- set in the other ("gflag"), only ever false to true; a friend who connects gets every one that's true here
-- ("gfall"). Per-moment flags (the *_Flag sets: car positions, a cut leg), boss working state, timers, failures and
-- deaths stay each game's own. Every story flag change is logged by name (coop_story_log.txt).
local function gsafe(f, ...) local ok, r = pcall(f, ...) if ok then return r end return nil end
local gf = { list = nil, by_key = {}, scan_t = -100, poll_t = 0, pending = {}, held = {}, sent = 0, applied = 0, digest_due = false }
story_flags = gf
GF_POLL_S = 0.5
local GF_SET_OK = { "_Main_Flag$", "_Main_A_Flag$", "_Main_B_Flag$", "Objective_Flag$" }
local GF_SET_NO = { "LastBoss" }
local GF_NAME_NO = { "Failed", "Dead", "Wait_", "_Trg", "Loop", "Random" }
local function gf_sharing() return sharing() and settings.share_story_flags ~= false end
local function gf_hub()
    local td = sdk.find_type_definition("via.userdata.GlobalUserData")
    local m = td and td:get_method("get_VariablesHub")
    return m and gsafe(m.call, m, nil)
end
local function gf_wanted_set(n)
    for _, p in ipairs(GF_SET_NO) do if n:find(p) then return false end end
    for _, p in ipairs(GF_SET_OK) do if n:find(p) then return true end end
    return false
end
local function gf_wanted_name(n)
    for _, p in ipairs(GF_NAME_NO) do if n:find(p, 1, true) then return false end end
    return true
end
-- Every wanted bool flag: { v, key = "<set hash>:<name hash>", name, set, on }. Read again every 10 s (a load swaps them).
local function gf_scan(now)
    gf.scan_t = now
    local hub = gf_hub()
    if hub == nil then gf.list = nil return end
    local list, by_key = {}, {}
    local n = tonumber(gsafe(hub.call, hub, "getUserVariablesCount")) or 0
    for i = 0, n - 1 do
        local uv = gsafe(hub.call, hub, "getUserVariables", i)
        local sn = uv and tostring(gsafe(uv.call, uv, "get_Name") or "")
        if sn and gf_wanted_set(sn) then
            local sh = (tonumber(gsafe(uv.call, uv, "get_HashName")) or 0) & 0xFFFFFFFF
            for j = 0, (tonumber(gsafe(uv.call, uv, "getVariableCount")) or 0) - 1 do
                local v = gsafe(uv.call, uv, "getVariable", j)
                local name = v and tostring(gsafe(v.call, v, "get_Name") or "")
                local on = v and gsafe(v.call, v, "get_Bool")
                if name and name ~= "" and type(on) == "boolean" and gf_wanted_name(name) then
                    local key = string.format("%08x:%08x", sh, (tonumber(gsafe(v.call, v, "get_NameHash")) or 0) & 0xFFFFFFFF)
                    local old = gf.by_key[key]
                    local e = { v = v, key = key, name = name, set = sn, on = old and old.on }
                    if e.on == nil then e.on = on end
                    list[#list + 1] = e
                    by_key[key] = e
                end
            end
        end
    end
    gf.list, gf.by_key = list, by_key
end
local function gf_apply(key, ch, why)
    local e = gf.by_key[key]
    if e == nil then return false end
    if ch ~= chapter() then
        gf.pending[key] = ch
        return true
    end
    gf.pending[key] = nil
    local cur = gsafe(e.v.call, e.v, "get_Bool")
    if cur == true then e.on = true gf.held[key] = nil return true end
    -- Not while we're loading, in our own scene or just after one (v0.58), as with the friend's steps: a milestone
    -- set then moves our story on before this step's own pieces have run. Chapter 4's start in a bot run: the host's
    -- C04_1_Main_MiaEventEnd reached the guest a second into its load, the guest's c04_1 went 0 -> 25 at once, and
    -- its step-0 pieces were switched off half done (Mia's opening scene never kicked, 0_Init_Inventory4-1Start
    -- never set her inventory). Held, our own step 0 runs first, and the flag is set afterwards if still needed.
    local b = busy_here()
    if b == "loading" or b == "faded out" or b == "in a cutscene" or hold_for_cutscene() then
        if not gf.held[key] then
            gf.held[key] = ch
            log(string.format("story flag %s from your friend waits (%s)", e.name, b or "your scene just ended"))
        end
        return true
    end
    gf.held[key] = nil
    local ok = pcall(e.v.call, e.v, "set_Bool", true)
    e.on = true
    gf.applied = gf.applied + 1
    log(string.format("story flag %s (%s) set from your friend's game%s%s", e.name, e.set, why or "", ok and "" or " ERR"))
    return true
end
local function gf_tick(now)
    if now - gf.poll_t < GF_POLL_S then return end
    gf.poll_t = now
    if gf.list == nil or now - gf.scan_t > 10 then gf_scan(now) end
    if gf.list == nil then return end
    local ch = chapter()
    for _, e in ipairs(gf.list) do
        local on = gsafe(e.v.call, e.v, "get_Bool")
        if type(on) == "boolean" and on ~= e.on then
            e.on = on
            if on then
                log(string.format("story flag %s (%s) set here", e.name, e.set))
                if gf_sharing() then
                    send(string.format("gflag %s %d %s", e.key, ch, e.name))
                    gf.sent = gf.sent + 1
                end
            else
                log(string.format("story flag %s (%s) cleared here (a load or the game's own reset)", e.name, e.set))
            end
        end
    end
    -- Ones that came for another chapter, now that we're in it.
    for key, pch in pairs(gf.pending) do
        if pch == ch and gf_sharing() then gf_apply(key, pch, " (held until we got to that chapter)") end
    end
    -- Ones held while we were loading or in a scene (v0.58).
    for key, hch in pairs(gf.held) do
        if hch ~= ch then gf.held[key] = nil
        elseif gf_sharing() then gf_apply(key, hch, " (held until your scene or load was over)") end
    end
    -- A friend just connected: every milestone that's true here, 40 to an event.
    if gf.digest_due and gf_sharing() then
        gf.digest_due = false
        local keys = {}
        for _, e in ipairs(gf.list) do if e.on then keys[#keys + 1] = e.key end end
        for i = 1, #keys, 40 do
            send(string.format("gfall %d %s", ch, table.concat(keys, ",", i, math.min(i + 39, #keys))))
        end
        log(string.format("story flags: sent all %d that are set here to the friend who connected", #keys))
    end
end
dbg_note{ feature = "Shared story", name = "Watch the story flags and share milestones",
    when = "every frame; its work twice a second (and a rescan of the flag list every 10 s)",
    reads = "the global variables hub (via.userdata.GlobalUserData): the *_Main_Flag and *Objective_Flag sets, about 300 flags",
    writes = "logs every change by name; sends 'gflag' when a milestone turns true here and 'gfall' to a friend who connects" }
re.on_frame(function()
    local ok, err = pcall(gf_tick, os.clock())
    if not ok and not gf.err then gf.err = true log("story flags ERR " .. tostring(err)) end
end)
-- Tutorial gates (v0.69). The TutorialCheck_Flag set holds what the player may do right now: CanChangeWeapon,
-- CanOpenInventory, CanOpenMap... A story moment turns them off and turns them back on when it's done, in each game
-- for its own player. Bot sweep 2026-11-26 (both players kept together): after Jack's fight the "look at dead Jack"
-- message (700_MSG_WatchDeadJack_FFS) waits at PositionCheck until the player walks up to the body; the guest had, the
-- host hadn't, the story went on, and the host's weapons, inventory and map stayed locked for the rest of Chapter 3
-- (60 steps). Now a gate that turns on in one game is told to the other ("tcan"), and there, if ours is still off
-- TCAN_WAIT_S later and we're not in a scene, loading or down, it's turned on too. Also seen in that sweep: both games
-- turn these gates off for a moment at every story step and back on after it, but a step that reached our game from
-- the friend's never turned them back on here: with 20 s first, the guest had no inventory for 20 s after every step.
-- 5 s: past the step's own moment, and a friend who is on already got past whatever gated it.
TCAN_WAIT_S = 5
-- A gate the game keeps turning back off here is left alone this long, then tried again (a hold that ended without
-- the game turning it on, the v0.66 bug, still gets fixed; a long hold, a Marguerite chase, flickers once in 30 s).
TCAN_RETRY_S = 30
TCAN_RESEND_S = 30
-- v0.69 (play-mode sweep, Chapter 1): the friend's gate state is kept as it is now ("tcan <name> <ch> <0|1>", both
-- ways), and ours is turned on once it has been off TCAN_WAIT_S while theirs is on. Keeping only the moment theirs came
-- on (and forgetting it when ours was on) left a gate that went off here later off until theirs happened to flip again.
local tc = { list = nil, scan_t = -100, poll_t = 0, friend = {}, off_since = {}, set_t = {}, fights = {}, gave_up = {} }
local function tc_scan(now)
    tc.scan_t = now
    local hub = gf_hub()
    if hub == nil then tc.list = nil return end
    local list = {}
    for i = 0, (tonumber(gsafe(hub.call, hub, "getUserVariablesCount")) or 0) - 1 do
        local uv = gsafe(hub.call, hub, "getUserVariables", i)
        if uv and tostring(gsafe(uv.call, uv, "get_Name") or "") == "TutorialCheck_Flag" then
            for j = 0, (tonumber(gsafe(uv.call, uv, "getVariableCount")) or 0) - 1 do
                local v = gsafe(uv.call, uv, "getVariable", j)
                local name = v and tostring(gsafe(v.call, v, "get_Name") or "")
                local on = v and gsafe(v.call, v, "get_Bool")
                if name and name:sub(1, 3) == "Can" and type(on) == "boolean" then
                    local old = tc.list and tc.list[name]
                    list[name] = { v = v, on = old and old.on }
                    if list[name].on == nil then list[name].on = on end
                end
            end
        end
    end
    tc.list = list
end
local function tc_tick(now)
    if now - tc.poll_t < 0.5 then return end
    tc.poll_t = now
    if tc.list == nil or now - tc.scan_t > 10 then tc_scan(now) end
    if tc.list == nil then return end
    -- Every gate's state again every TCAN_RESEND_S (bot sweep, Chapter 3): states went only on a change, and the
    -- guest's "on" sent while both games were still loading never arrived, so the host's gates stayed off after the
    -- dead-Jack moment with nothing to go on.
    if gf_sharing() and now - (tc.resend_t or -100) >= TCAN_RESEND_S then
        tc.resend_t = now
        for name, e in pairs(tc.list) do
            -- Not logged (the changes are): it would be a line per gate every 30 s.
            if type(e.on) == "boolean" and coop_send_event then
                coop_send_event(string.format("tcan %s %d %d", name, chapter(), e.on and 1 or 0))
                ss.sent = ss.sent + 1
            end
        end
    end
    for name, e in pairs(tc.list) do
        local on = gsafe(e.v.call, e.v, "get_Bool")
        if type(on) == "boolean" and on ~= e.on then
            e.on = on
            -- Ours came back on by the game's own doing: whatever held it off here is over, so a gate we left to the
            -- game gets another chance (the friend's flips at every story step aren't news: FF030 bot sweep, a
            -- Marguerite chase holds the chased player's gates off and each step's flip there re-fought it twice).
            if on == true and tc.set_t[name] == nil then tc.gave_up[name], tc.fights[name] = nil, nil end
            -- The game turned it straight back off after we turned it on (a story moment here holds it off, bot sweep
            -- 2026-11-26: on, off, on, off every 5 s): twice and that gate is left to the game for TCAN_RETRY_S, or
            -- until the game turns it on itself.
            if on == false and tc.set_t[name] and now - tc.set_t[name] < 3 then
                tc.fights[name] = (tc.fights[name] or 0) + 1
                if tc.fights[name] >= 2 and not tc.gave_up[name] then
                    tc.gave_up[name] = now
                    log(string.format("%s: the game here keeps it off (a story moment of ours): left to the game", name))
                end
            end
            tc.set_t[name] = nil
            if gf_sharing() then send(string.format("tcan %s %d %d", name, chapter(), on and 1 or 0)) end
        end
        if tc.gave_up[name] and now - tc.gave_up[name] >= TCAN_RETRY_S then tc.gave_up[name], tc.fights[name] = nil, nil end
        if on == false and tc.friend[name] == true and not tc.gave_up[name] then
            tc.off_since[name] = tc.off_since[name] or now
            if now - tc.off_since[name] >= TCAN_WAIT_S then
                local b = busy_here()
                if not b and not (revive and revive.downed) and not (local_cutscene and local_cutscene()) then
                    tc.off_since[name] = nil
                    pcall(e.v.call, e.v, "set_Bool", true)
                    e.on = true
                    tc.set_t[name] = now
                    log(string.format("%s was off here %d s while your friend's is on: on again", name, TCAN_WAIT_S))
                end
            end
        else
            tc.off_since[name] = nil
        end
    end
end
dbg_note{ feature = "Shared story", name = "Tutorial gates: share them and turn ours on when the friend's is",
    when = "every frame; its work twice a second (a rescan of the gate list every 10 s)",
    reads = "the TutorialCheck_Flag set's Can* flags (global variables hub), the friend's 'tcan' states",
    writes = "sends 'tcan' when a gate changes here; sets a gate true after TCAN_WAIT_S off while the friend's is on" }
re.on_frame(function()
    local ok, err = pcall(tc_tick, os.clock())
    if not ok and not tc.err then tc.err = true log("tutorial gates ERR " .. tostring(err)) end
end)

local function gf_on_event(text)
    local tname, tch, tv = text:match("^tcan (%S+) (%-?%d+) ?(%d?)")
    if tname then
        if gf_sharing() and tonumber(tch) == chapter() then
            tc.friend[tname] = (tv ~= "0")
        end
        return true
    end
    local key, ch, name = text:match("^gflag (%x+:%x+) (%-?%d+) ?(%S*)")
    if key then
        if gf_sharing() then
            if gf.list == nil then pcall(gf_scan, os.clock()) end
            if not gf_apply(key, tonumber(ch)) then log("story flag " .. tostring(name) .. " from your friend: not known here") end
        end
        return true
    end
    local ach, keys = text:match("^gfall (%-?%d+) (%S+)")
    if ach then
        if gf_sharing() then
            if gf.list == nil then pcall(gf_scan, os.clock()) end
            local n = 0
            for k in keys:gmatch("[^,]+") do
                local e = gf.by_key[k]
                if e and not e.on then n = n + 1 end
                gf_apply(k, tonumber(ach), " (catching up)")
            end
            if n > 0 then log(string.format("story flags: caught up %d from your friend's game", n)) end
        end
        return true
    end
    return false
end
-- Story objects (v0.57). ----------------------------------------------------------------------------------------
-- What a gimmick leaves behind in the world is kept on objects with app.OtherObjectSave (about 50 in the main house:
-- collisions, boards, props a scene moved): their GameObject's UpdateSelf/DrawSelf, saved by SaveGUID. After the
-- same story steps one of them differed between the test copies: BossArea_PLFallDownStopCollision_OOS on in one game
-- and off in the other (bot test 2026-11-23). A change that holds GOS_HOLD_S s outside a cutscene goes to the friend
-- ("gos <guid> <upd><draw> <chapter> <name>") and is applied there; a friend who connects gets the host's states
-- ("gosall"). Logged by name.
local gos = { list = nil, by_id = {}, scan_t = -100, poll_t = 0, pend = {}, sent = 0, applied = 0, digest_due = false }
story_objects = gos
GOS_POLL_S, GOS_HOLD_S = 1.0, 2.0
local function gos_sharing() return sharing() and settings.share_story_objects ~= false end
local function gos_guid(g)
    if g == nil then return nil end
    local b = {}
    for i = 0, 7 do b[#b + 1] = string.format("%02x", (gsafe(g.get_field, g, "mData4_" .. i) or 0) & 0xFF) end
    local t = string.format("%08x%04x%04x%s", (gsafe(g.get_field, g, "mData1") or 0) & 0xFFFFFFFF,
        (gsafe(g.get_field, g, "mData2") or 0) & 0xFFFF, (gsafe(g.get_field, g, "mData3") or 0) & 0xFFFF, table.concat(b))
    if t == "00000000000000000000000000000000" then return nil end
    return t
end
local function gos_state(go)
    local u, d = gsafe(go.call, go, "get_UpdateSelf"), gsafe(go.call, go, "get_DrawSelf")
    if type(u) ~= "boolean" or type(d) ~= "boolean" then return nil end
    return (u and "1" or "0") .. (d and "1" or "0")
end
local function gos_scan(now)
    gos.scan_t = now
    local sc = sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"), sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
    local arr = sc and gsafe(sc.call, sc, "findComponents(System.Type)", sdk.typeof("app.OtherObjectSave"))
    if arr == nil then return end
    local list, by_id = {}, {}
    for _, c in ipairs(arr_items(arr)) do
        local id = gos_guid(gsafe(c.get_field, c, "SaveGUID"))
        local go = id and gsafe(c.call, c, "get_GameObject")
        if go then
            local old = gos.by_id[id]
            local e = { id = id, go = go, name = tostring(gsafe(go.call, go, "get_Name") or "?"), st = old and old.st or gos_state(go) }
            list[#list + 1] = e
            by_id[id] = e
        end
    end
    gos.list, gos.by_id = list, by_id
end
local function gos_apply(id, st, ch, why)
    if ch ~= chapter() then return end
    local e = gos.by_id[id]
    if e == nil then return end
    if gos_state(e.go) == st then e.st = st return end
    pcall(e.go.call, e.go, "set_UpdateSelf", st:sub(1, 1) == "1")
    pcall(e.go.call, e.go, "set_DrawSelf", st:sub(2, 2) == "1")
    e.st, e.since, e.cand = st, nil, nil
    gos.applied = gos.applied + 1
    log(string.format("story object %s set to %s from your friend's game%s", e.name, st == "11" and "on" or (st == "00" and "off" or st), why or ""))
end
local function gos_tick(now)
    if now - gos.poll_t < GOS_POLL_S then return end
    gos.poll_t = now
    if gos.list == nil or now - gos.scan_t > 10 then gos_scan(now) end
    if gos.list == nil then return end
    local cut = local_cutscene and local_cutscene()
    local ch = chapter()
    for _, e in ipairs(gos.list) do
        local st = gos_state(e.go)
        if st and st ~= e.st then
            -- Held GOS_HOLD_S s, outside a cutscene (scenes hide and show things for a moment).
            if e.cand ~= st then e.cand, e.since = st, now
            elseif not cut and now - e.since >= GOS_HOLD_S then
                log(string.format("story object %s %s here (%s -> %s)", e.name, st == "11" and "on" or (st == "00" and "off" or "changed"), tostring(e.st), st))
                e.st, e.cand, e.since = st, nil, nil
                if gos_sharing() then
                    send(string.format("gos %s %s %d %s", e.id, st, ch, e.name))
                    gos.sent = gos.sent + 1
                end
            end
        else
            e.cand, e.since = nil, nil
        end
    end
    if gos.digest_due and gos_sharing() and coop_enemy_role_now == "host" and not cut then
        gos.digest_due = false
        local parts = {}
        for _, e in ipairs(gos.list) do if e.st then parts[#parts + 1] = e.id .. ":" .. e.st end end
        for i = 1, #parts, 30 do send(string.format("gosall %d %s", ch, table.concat(parts, ",", i, math.min(i + 29, #parts)))) end
        log(string.format("story objects: sent the state of all %d here to the friend who connected", #parts))
    end
end
dbg_note{ feature = "Shared story", name = "Watch the saved story objects and share their changes",
    when = "every frame; its work once a second (and a rescan of the objects every 10 s)",
    reads = "every app.OtherObjectSave's GameObject: UpdateSelf / DrawSelf (about 50 in an area)",
    writes = "logs changes by name; sends 'gos' for a change that held 2 s outside a cutscene, 'gosall' (host) to a friend who connects" }
re.on_frame(function()
    local ok, err = pcall(gos_tick, os.clock())
    if not ok and not gos.err then gos.err = true log("story objects ERR " .. tostring(err)) end
end)
local function gos_on_event(text)
    local id, st, ch = text:match("^gos (%x+) ([01][01]) (%-?%d+)")
    if id then
        if gos_sharing() then
            if gos.list == nil then pcall(gos_scan, os.clock()) end
            gos_apply(id, st, tonumber(ch))
        end
        return true
    end
    local ach, items = text:match("^gosall (%-?%d+) (%S+)")
    if ach then
        if gos_sharing() and coop_enemy_role_now ~= "host" and not (local_cutscene and local_cutscene()) then
            if gos.list == nil then pcall(gos_scan, os.clock()) end
            for gid, gst in items:gmatch("(%x+):([01][01])") do gos_apply(gid, gst, tonumber(ach), " (the host's, on connecting)") end
        end
        return true
    end
    return false
end

-- Saved story timelines (v0.57). ---------------------------------------------------------------------------------
-- app.TimeLineKicker plays a timeline (a gimmick's animation or effect); the 34 in the main house are mostly scene
-- lights, scene cameras and enemy effects, which belong to each game's own moment. The few the game SAVES (IsSave:
-- three there, ShallowWater_bath and two Chapter 3-2 scene effects) are story state: once played (PlayStamp) they
-- stay played. One played here is sent ("gtl <guid> <chapter> <name>"); the other game jumps it to its last frame
-- (setLastFrame, the state a save loads it in) and marks it played, outside a cutscene. Never replayed (no camera
-- or sound on the friend). Logged by name.
local gtl = { list = nil, by_id = {}, scan_t = -100, poll_t = 0, pend = {}, sent = 0, applied = 0 }
story_timelines = gtl
local function gtl_sharing() return sharing() and settings.share_story_timelines ~= false end
local function gtl_scan(now)
    gtl.scan_t = now
    local sc = sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"), sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
    local arr = sc and gsafe(sc.call, sc, "findComponents(System.Type)", sdk.typeof("app.TimeLineKicker"))
    if arr == nil then return end
    local list, by_id = {}, {}
    for _, k in ipairs(arr_items(arr)) do
        if gsafe(k.get_field, k, "IsSave") == true then
            local id = gos_guid(gsafe(k.get_field, k, "SaveGUID"))
            local go = id and gsafe(k.call, k, "get_GameObject")
            if go then
                local old = gtl.by_id[id]
                local e = { id = id, k = k, name = tostring(gsafe(go.call, go, "get_Name") or "?"),
                    on = old and old.on or (gsafe(k.get_field, k, "PlayStamp") == true) }
                list[#list + 1] = e
                by_id[id] = e
            end
        end
    end
    gtl.list, gtl.by_id = list, by_id
end
local function gtl_apply(id, ch)
    local e = gtl.by_id[id]
    if e == nil or ch ~= chapter() then return false end
    if gsafe(e.k.get_field, e.k, "PlayStamp") == true then e.on = true return true end
    if local_cutscene and local_cutscene() then return false end
    local ok = pcall(e.k.call, e.k, "setLastFrame")
    pcall(e.k.set_field, e.k, "PlayStamp", true)
    e.on = true
    gtl.applied = gtl.applied + 1
    log(string.format("story timeline %s: played in your friend's game, set to its end here%s", e.name, ok and "" or " (ERR)"))
    return true
end
local function gtl_tick(now)
    if now - gtl.poll_t < 1.0 then return end
    gtl.poll_t = now
    if gtl.list == nil or now - gtl.scan_t > 10 then gtl_scan(now) end
    if gtl.list == nil then return end
    local ch = chapter()
    for _, e in ipairs(gtl.list) do
        local on = gsafe(e.k.get_field, e.k, "PlayStamp") == true
        if on and not e.on then
            e.on = true
            log(string.format("story timeline %s played here", e.name))
            if gtl_sharing() then send(string.format("gtl %s %d %s", e.id, ch, e.name)) gtl.sent = gtl.sent + 1 end
        elseif not on and e.on then
            e.on = false
        end
    end
    for id, pch in pairs(gtl.pend) do
        if gtl_apply(id, pch) then gtl.pend[id] = nil end
    end
end
dbg_note{ feature = "Shared story", name = "Watch the saved story timelines and share the ones played",
    when = "every frame; its work once a second (and a rescan every 10 s)",
    reads = "every app.TimeLineKicker the game saves (IsSave): PlayStamp (a few per area)",
    writes = "logs; sends 'gtl' when one is played here; on the friend's, jumps theirs to its last frame" }
re.on_frame(function()
    local ok, err = pcall(gtl_tick, os.clock())
    if not ok and not gtl.err then gtl.err = true log("story timelines ERR " .. tostring(err)) end
end)
local function gtl_on_event(text)
    local id, ch = text:match("^gtl (%x+) (%-?%d+)")
    if not id then return false end
    if gtl_sharing() then
        if gtl.list == nil then pcall(gtl_scan, os.clock()) end
        if not gtl_apply(id, tonumber(ch)) then gtl.pend[id] = tonumber(ch) end
    end
    return true
end

-- The serum choice (v0.58). -----------------------------------------------------------------------------------------
-- At the end of Chapter 3 (c03_5, step 1000) Ethan gives the one serum to Mia or to Zoe. The game keeps the answer in
-- one flag, c03_5_Flag/Choice_Mia (true Mia, false Zoe), and reads it at c03_5 step 1200 (1200_MiaChoice /
-- 1200_ZoiChoice: which scene plays), in Chapter 4 (c04_2's 100_MiaZoiSelectBunki: which doors open, and the fight on
-- the Zoe route) and for the ending. Each game asked its own player, so two players could choose differently and play
-- different routes to the end. The story flag sync can't carry it (it shares flags turning true, and choosing Zoe
-- leaves this one false), so the choice goes as its own message: the first game to make it sends "choice <1|0> <ch>"
-- and the other takes it; when both chose at the same moment, the host's choice stays. A step to 1200 copied from the
-- friend waits up to CHOICE_HOLD_S for their choice, so the scene at 1200 reads the right answer.
local CHOICE_SET, CHOICE_FLAG, CHOICE_PART = "c03_5_Flag", "Choice_Mia", "c03_5_Main"
local CHOICE_WAIT, CHOICE_MADE = 1000, 1200
CHOICE_HOLD_S = 5
local sch = { poll_t = 0, scan_t = -100, flag = nil, step = nil, hash = nil, prev = nil, made = nil, got = nil,
    pend = nil, digest_due = false }
story_choice = sch
local function sch_scan(now)
    sch.scan_t = now
    sch.flag, sch.step, sch.hash = nil, nil, nil
    local hub = gf_hub()
    if hub == nil then return end
    for i = 0, (tonumber(gsafe(hub.call, hub, "getUserVariablesCount")) or 0) - 1 do
        local uv = gsafe(hub.call, hub, "getUserVariables", i)
        local sn = uv and tostring(gsafe(uv.call, uv, "get_Name") or "")
        if sn == CHOICE_SET or sn == "ProgressiveNumber" then
            for j = 0, (tonumber(gsafe(uv.call, uv, "getVariableCount")) or 0) - 1 do
                local v = gsafe(uv.call, uv, "getVariable", j)
                local name = v and tostring(gsafe(v.call, v, "get_Name") or "")
                if sn == CHOICE_SET and name == CHOICE_FLAG then sch.flag = v end
                if sn == "ProgressiveNumber" and name == CHOICE_PART then
                    sch.step = v
                    sch.hash = (tonumber(gsafe(v.call, v, "get_NameHash")) or 0) & 0xFFFFFFFF
                end
            end
        end
    end
end
local function sch_read()
    local step = sch.step and tonumber(gsafe(sch.step.call, sch.step, "get_S32"))
    local mia = sch.flag and gsafe(sch.flag.call, sch.flag, "get_Bool")
    if type(mia) ~= "boolean" then mia = nil end   -- (not "x and mia or nil": that turns Zoe, false, into nil)
    return step, mia
end
local function who(v) return v and "Mia" or "Zoe" end
local function sch_set(v, why)
    local _, cur = sch_read()
    if cur == v then return end
    local ok = sch.flag and pcall(sch.flag.call, sch.flag, "set_Bool", v)
    log(string.format("serum choice: %s here too (%s)%s", who(v), why, ok and "" or " ERR"))
end
local function sch_apply(v, ch)
    if ch ~= chapter() then sch.pend = { v = v, ch = ch } return end
    sch.pend = nil
    if sch.flag == nil then sch_scan(os.clock()) end
    if sch.flag == nil then sch.pend = { v = v, ch = ch } return end
    local step = sch_read()
    if sch.made ~= nil and sch.made ~= v and not follower() then
        -- We both chose at the same moment: the host's choice stays (the friend's game takes ours when it arrives).
        log(string.format("serum choice: your friend chose %s at the same moment you chose %s; yours stays (host)", who(v), who(sch.made)))
        return
    end
    sch.got, sch.made = v, v
    if (step or 0) >= CHOICE_MADE then
        sch_set(v, "your friend's choice, after yours here")
    else
        sch_set(v, "your friend's choice")
        note("your friend gave the serum to " .. who(v))
    end
end
-- A copied step to 1200 or beyond waits for the friend's choice (called by the step copier above).
ss.choice_holds = function(hash, cur, value, now)
    if sch.hash == nil or hash ~= sch.hash or cur >= CHOICE_MADE or value < CHOICE_MADE then return false end
    if sch.got ~= nil or sch.made ~= nil then return false end
    sch.hold_t = sch.hold_t or now
    if now - sch.hold_t < CHOICE_HOLD_S then return true end
    log("serum choice: your friend's step went past the choice but no choice came; the step goes on")
    return false
end
local function sch_tick(now)
    if now - sch.poll_t < 0.25 then return end
    sch.poll_t = now
    if sch.flag == nil or sch.step == nil or now - sch.scan_t > 10 then
        if now - sch.scan_t > 2 then sch_scan(now) end
    end
    local step, mia = sch_read()
    if step == nil or mia == nil then sch.prev = nil return end
    if step < CHOICE_WAIT then sch.made, sch.got, sch.hold_t = nil, nil, nil end   -- an earlier save, or not there yet
    local prev = sch.prev
    sch.prev = step
    if prev == nil and step >= CHOICE_MADE and sch.made == nil then sch.made = mia end   -- a save from after the choice
    if sch.pend and sch.pend.ch == chapter() and gf_sharing() then sch_apply(sch.pend.v, sch.pend.ch) end
    if prev and prev < CHOICE_MADE and step >= CHOICE_MADE then
        local applied = ss.applying[string.format("pg:%08x", sch.hash or 0)]
        if sch.got ~= nil then
            sch_set(sch.got, "your friend's choice")
        elseif applied and now - applied < 5 then
            log(string.format("serum choice: the step came from your friend's game with no choice; %s kept here", who(mia)))
            sch.made = mia
        else
            sch.made = mia
            log(string.format("serum choice: you gave the serum to %s%s", who(mia), gf_sharing() and "; sent to your friend" or ""))
            if gf_sharing() then send(string.format("choice %d %d", mia and 1 or 0, chapter())) end
        end
    end
    if sch.digest_due and gf_sharing() then
        sch.digest_due = false
        if sch.made ~= nil and step >= CHOICE_MADE then send(string.format("choice %d %d", sch.made and 1 or 0, chapter())) end
    end
end
dbg_note{ feature = "Shared story", name = "The serum choice (Mia or Zoe)",
    when = "every frame; its work 4 times a second (and a look-up of two story variables every 10 s)",
    reads = "the global variables hub: ProgressiveNumber/c03_5_Main and c03_5_Flag/Choice_Mia",
    writes = "sends 'choice' when you make the choice here; sets Choice_Mia to the friend's choice" }
re.on_frame(function()
    local ok, err = pcall(sch_tick, os.clock())
    if not ok and not sch.err then sch.err = true log("serum choice ERR " .. tostring(err)) end
end)
local function sch_on_event(text)
    local v, ch = text:match("^choice ([01]) (%-?%d+)")
    if not v then return false end
    if gf_sharing() then
        local ok, err = pcall(sch_apply, v == "1", tonumber(ch))
        if not ok then log("serum choice ERR " .. tostring(err)) end
    end
    return true
end

function story_flags_status()
    local n, on = 0, 0
    for _, e in ipairs(gf.list or {}) do n = n + 1 if e.on then on = on + 1 end end
    return string.format("Story flags: %d watched, %d set; sent %d, applied %d", n, on, gf.sent, gf.applied)
end

function coop_story_on_event(text)
    if gf_on_event(text) then return true end
    if gos_on_event(text) then return true end
    if gtl_on_event(text) then return true end
    if sch_on_event(text) then return true end
    local oid, och = text:match("^objdone (%x+) (%-?%d+)$")
    if oid then
        local ok, err = pcall(apply_objdone, oid, tonumber(och))
        if not ok then log("objdone ERR " .. tostring(err)) end
        return true
    end
    local pch, pclock, pdiff = text:match("^spos (%-?%d+) (%-?%d+) ?(%-?%d*)")
    if pch then
        -- A friend we hadn't heard from for 20 s+ (just connected, or back): our story flags go to them (gfall).
        local prev = ss.spos[coop_event_slot or 1]
        if prev == nil or os.clock() - prev.t > 20 then gf.digest_due, gos.digest_due, sch.digest_due = true, true, true end
        ss.spos[coop_event_slot or 1] = { ch = tonumber(pch), clock = tonumber(pclock), t = os.clock(), diff = tonumber(pdiff) }
        pcall(check_difficulty, coop_event_slot or 1)
        return true
    end
    local skind, sch = text:match("^saved (%a+) (%-?%d+)")
    if skind then pcall(on_saved, skind, tonumber(sch)) return true end
    -- The friend loaded a save (v0.39): what we kept from them (progress to copy, scenes to
    -- start, how far they were) is from after it.
    local rch = text:match("^rewind (%-?%d+)")
    if rch then
        rch = tonumber(rch)
        ss.missed, ss.pending, ss.friend_prog = {}, {}, {}
        note(rch == chapter() and "your friend loaded a save: their story is back where that save was"
            or "your friend loaded a save in another chapter")
        return true
    end
    pcall(track_friend, text)
    if not sharing() and (text:match("^story ") or text:match("^prog ") or text:match("^evend ")) then
        log("story sharing is off, ignored: " .. text)
        return true
    end
    local bh, bch = text:match("^btlend (%x+) (%-?%d+)$")
    if bh then
        if sharing() then pcall(apply_btlend, tonumber(bh, 16), tonumber(bch)) end
        return true
    end
    local name, ch, stag = text:match("^story (%S+) (%-?%d+) ?(%a*)")
    if name then pcall(apply_story, name, tonumber(ch), stag == "phone", stag == "hold") return true end
    -- v0.53: the friend's game is ready for a scene ours is holding (or won't join it): start it now.
    if text:match("^tapejump") then
        if coop_story_tape_jump then pcall(coop_story_tape_jump) end
        return true
    end
    local rname = text:match("^sready (%S+)") or text:match("^snoready (%S+)")
    if rname then
        if coop_story_scene_ready then pcall(coop_story_scene_ready, rname) end
        return true
    end
    local h, v, pch = text:match("^prog (%x+) (%-?%d+) (%-?%d+)")
    if h then pcall(apply_prog, tonumber(h, 16), tonumber(v), tonumber(pch)) return true end
    local eh, ech = text:match("^evend (%x+) (%-?%d+)")
    if eh then pcall(apply_evend, tonumber(eh, 16), tonumber(ech)) return true end
    return false
end

-- Kept story steps: applied once we're together (same chapter); dropped on a chapter change.
dbg_note{ feature = "Story progress", name = "Apply story steps and scene ends that were kept while apart",
    when = "every frame (returns at once with nothing kept); works once a second",
    reads = "ss.missed (in memory), our chapter, whether we are together and not in a scene",
    writes = "applies the kept steps (story progress, finished events and fights)" }
re.on_frame(function()
    if next(ss.missed) == nil then return end
    local now = os.clock()
    if now - (ss.missed_t or 0) < 1 then return end
    ss.missed_t = now
    local ch = chapter()
    local stale = false
    for _, m in pairs(ss.missed) do if m.ch ~= ch then stale = true end end
    if stale then
        for k, m in pairs(ss.missed) do if m.ch ~= ch then ss.missed[k] = nil end end
    end
    if next(ss.missed) == nil or not together() or hold_for_cutscene() then return end
    local list = ss.missed
    ss.missed = {}
    for _, m in pairs(list) do
        if m.kind == "prog" then pcall(apply_prog, m.hash, m.value, m.ch) end
    end
    for _, m in pairs(list) do
        if m.kind == "evend" then pcall(apply_evend, m.hash, m.ch) end
    end
    for _, m in pairs(list) do
        if m.kind == "btlend" then pcall(apply_btlend, m.hash, m.ch) end
    end
end)

-- The friend moved on to the next chapter and our game didn't follow within 40 s (v0.32):
-- tell the player how to get out of a stuck black screen.
dbg_note{ feature = "Story cutscenes", name = "Warn when the friend moved to the next chapter and we did not follow",
    when = "every frame (a flag check; works only after the friend's chapter changed)",
    reads = "our chapter",
    writes = "an on-screen message every 30 s after 40 s" }
re.on_frame(function()
    local m = ss.moved_on
    if m == nil then return end
    local now = os.clock()
    if chapter() ~= m.mine then ss.moved_on = nil return end
    if now - m.t < 40 or ss.cut_on then return end
    if now - (m.note_t or -100) > 30 then
        m.note_t = now
        note("your friend went on to the next chapter. If your screen is stuck black, press Go to my friend's chapter (Lobby)")
    end
    if now - m.t > 300 then ss.moved_on = nil end
end)

-- Cutscenes the friend started before their area loaded here.
dbg_note{ feature = "Story cutscenes", name = "Play the friend's scenes that were waiting for their area to load here",
    when = "every frame, but it only works once a second",
    reads = "the waiting scenes, the distance to the friend's ghost, whether the scene's setting is loaded (EventSettings)",
    writes = "starts the scene here (play) once it is loaded and we are free; gives up after a while" }
re.on_frame(function()
    local now = os.clock()
    if now - ss.pend_t < 0.25 then return end   -- v0.53: 4 times a second (was once): a scene starts sooner
    ss.pend_t = now
    local busy = busy_here()
    for name, p in pairs(ss.pending) do
        local d = friend_distance(p.slot)
        -- While we're busy (paused, down...) it keeps waiting, for up to 2 minutes (v0.37).
        p.first = p.first or p.t
        if busy and now - p.first < 120 then p.t = now end
        local steps_queued = false
        for _, q in pairs(ss.steps or {}) do if q.ch == chapter() and #q.list > 0 then steps_queued = true end end
        local held = (p.hold_until and now < p.hold_until) or (steps_queued and now - p.first < 60)
        if held then p.t = now end
        if p.instead and played_here()[p.instead] then
            -- Our own game played the friend's scene itself (v0.50): the sequence was never "partway" here.
            ss.pending[name] = nil
            log(string.format("friend's %s: your game played it itself, so %s isn't started for it", p.instead, name))
        elseif held then
            -- see apply_story: the friend's step may play it
        elseif now - p.t > (p.pulled and PENDING_PULLED or PENDING_FOR) or p.ch ~= chapter() or d == nil
            or (d > ((settings == nil or settings.scene_pull ~= false) and SCENE_PULL_MAX or NEAR) and not follower()) then
            ss.pending[name] = nil
            log("gave up waiting for " .. name)
        elseif p.pull and not busy and not p.pulled and d > 2.5 and teleport_to_friend then
            -- It came while we were busy (v0.51): now we're free, brought next to them first.
            local tok = select(2, pcall(teleport_to_friend, SCENE_PULL_MAX))
            p.pulled, p.t = true, now
            log(string.format("friend's %s: brought next to them now (%.0f m, %s)", name, d, tostring(tok)))
        else
            -- Our own game may have started the scene, or its sequence, meanwhile (v0.39).
            local start, why = scene_to_start(name)
            if start ~= name then
                ss.pending[name] = nil
                log("friend's " .. name .. ": not started here: " .. tostring(why))
            elseif setting_loaded(name) and not busy then
                ss.pending[name] = nil
                -- A scene the friend is holding for us (v0.53): both start now.
                coop_story_started_for_friend(p.friend_name or name)
                if p.instead then coop_story_started_for_friend(p.instead) end
                play(name)
            end
        end
    end
end)

function story_sync_hud()
    if os.clock() - ss.msg_t < 6 then return "Story: " .. ss.msg end
    return nil
end

function story_sync_status()
    local fm = flow_mgr()
    local stage = fm and fm:call("get_CurrentMainGameFlow")
    local played, pend = 0, 0
    for _ in pairs(ss.played) do played = played + 1 end
    for _ in pairs(ss.pending) do pend = pend + 1 end
    return string.format("Story: stage %s; cutscenes played %d, waiting %d; sent %d, applied %d",
        tostring(stage), played, pend, ss.sent, ss.applied)
end

-- Testing: the bot "triggers" the next story cutscene loaded here that hasn't played.
function story_sync_bot_next()
    local em = event_mgr()
    local list = em and em:get_field("EventSettings")
    local names = {}
    for i = 0, (list and list:call("get_Count") or 0) - 1 do
        local n = tostring(list:call("get_Item", i):call("get_eventName"))
        if n:match(STORY_NAME) and not ss.played[n] then names[#names + 1] = n end
    end
    table.sort(names)
    if #names == 0 then return "no unplayed story cutscene loaded here" end
    fs.write("coopnet_command.txt", string.format("botevent story %s %d", names[1], chapter()))
    return "the bot triggers " .. names[1]
end

coop_story_on_event = dbg_task("Friend's events", "Apply a story event from the friend (scene, step, fight end, objective)", coop_story_on_event, {
    when = "when the friend's game sends a story event ('story', 'prog', 'evend', 'btlend', 'objdone', 'spos', 'rewind'...)",
    reads = "the event text, our played-scenes record, our chapter and the distance to the friend",
    writes = "plays the friend's scene here, queues or applies story steps, ends events and fights, checks off objectives" })
log("coop_story loaded")
