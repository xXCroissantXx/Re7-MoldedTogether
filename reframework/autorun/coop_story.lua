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
local STORY_NAME = "^c%d%de%d%d_%d%d$"
-- Jack's scripted moments (breaking through the hatch-room wall, 2026-11-02) are events too,
-- named em3000_*; they follow the same rules (same chapter, friend within NEAR).
local SCRIPTED_NAME = "^em3%d%d%d_"
local function is_story_event(name) return name:match(STORY_NAME) ~= nil or name:match(SCRIPTED_NAME) ~= nil end
-- A story scene's sequence and its place in it (v0.39): "c03e00_02" -> "c03e00", 2.
local function seq_of(name)
    local grp, idx = tostring(name):match("^(c%d%de%d%d)_(%d%d)$")
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
        -- The sequence our game is in now (v0.39), and when each scene started (for its end).
        local grp = seq_of(name)
        if grp then ss.last_seq = { grp = grp, t = os.clock(), ch = ch } end
        ss.running[name] = os.clock()
        log(string.format("scene %s starts (%s, story clock %d)", name, ours("ev:" .. name) and "your friend's" or "yours",
            coop_story_clock()))
        -- A scene our own phone started (coop_world notes the moment we answer): told apart from a real
        -- cutscene, so the friend's game gives it to our body instead of playing it on the friend.
        local tag = (coop_my_phone_t and os.clock() - coop_my_phone_t < 15) and " phone" or ""
        if first and not ours("ev:" .. name) then send(string.format("story %s %d%s", name, ch, tag)) end
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
local function scene_to_start(name)
    if played_here()[name] then return nil, "already played here" end
    local grp, idx = seq_of(name)
    if grp == nil then return name end
    local mine = seq_played(grp)
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
    if idx and idx >= 1 and idx <= 9 and not (mine and idx and seq_top(grp) > idx) then
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
    if revive and revive.downed then return "down" end
    if local_cutscene and local_cutscene() then return "in a cutscene" end
    return nil
end

local function apply_story(name, ch, phone)
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
        -- step played it here a second time (the morgue scene twice in a bot test). It waits 1.5 s, and while
        -- a step is queued; the step plays it, and if the step doesn't, it plays after (the loop below).
        ss.pending[start] = { ch = ch, t = os.clock(), slot = coop_event_slot or 1, hold_until = os.clock() + 1.5, instead = instead }
    else
        -- After a pull the area streams in around us: allow it longer to load (PENDING_PULLED).
        ss.pending[start] = { ch = ch, t = os.clock(), slot = coop_event_slot or 1, instead = instead, pulled = pulled }
        log("waiting for " .. start .. " to load here")
    end
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
do
    local gmt = sdk.find_type_definition("app.GameManager")
    for _, mname in ipairs({ "newGameRequest", "newGameRequest_Chapter7",
        "chapterJumpRequest(System.String, System.Boolean, System.String)" }) do
        local m = gmt and gmt:get_method(mname)
        dbg_note{ feature = "Loads and the black screen", name = "A load or new game started: drop the friend's waiting scenes",
            when = "when the game calls GameManager." .. mname:match("^[%w_]+") .. " (a New Game or chapter jump begins)",
            reads = "the table of the friend's waiting scenes",
            writes = "starts the 12 s settle time (nothing of the friend's is started meanwhile) and forgets the waiting scenes" }
        if m then pcall(sdk.hook, m, function(args) pcall(coop_story_settle, "a load started (" .. mname:match("^[%w_]+") .. ")") end, function(r) return r end) end
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
function coop_story_on_event(text)
    local oid, och = text:match("^objdone (%x+) (%-?%d+)$")
    if oid then
        local ok, err = pcall(apply_objdone, oid, tonumber(och))
        if not ok then log("objdone ERR " .. tostring(err)) end
        return true
    end
    local pch, pclock, pdiff = text:match("^spos (%-?%d+) (%-?%d+) ?(%-?%d*)")
    if pch then
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
    if name then pcall(apply_story, name, tonumber(ch), stag == "phone") return true end
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
    if now - ss.pend_t < 1 then return end
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
