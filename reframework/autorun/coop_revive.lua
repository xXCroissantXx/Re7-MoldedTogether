-- coop_revive.lua: downed and revive.
-- In co-op a fatal hit doesn't end your game: you go down (held in place on 1 health,
-- can't die) until your friend stands next to you for a few seconds, which gets you back
-- up with some health. If you're both down, or nobody comes within DOWN_LIMIT seconds, it's
-- a normal game over. Without a friend connected (or in a cutscene) deaths are untouched.
-- 3-4 players (v0.33): any friend who is up can get you up; it's a real death only when
-- everyone is down. Each friend's events come with their slot (coop_event_slot).
-- Events (reliable, through coop_enemies.lua's channel):
--   down <chapter>      I went down          up        I'm back up
--   gameover            I died for real (if you're down too, you die with me)

-- v0.48: this script's frame work waits while the game loads or swaps the player (coop_busy, coop_dummy.lua).
local re = setmetatable({ on_frame = function(f)
    return _G.re.on_frame(function() if coop_busy and coop_busy() then return end return f() end)
end }, { __index = _G.re })

-- Debug registry (v0.52, coop_dummy.lua): dbg_note describes the callback or hook registered on the next lines, dbg_task
-- gives a function its own row in the Debug section. Both are tail calls so the registry sees this file's line.
local function dbg_note(info) if coop_note then return coop_note(info) end end
local function dbg_task(feature, name, f, info) if coop_task then return coop_task(feature, name, f, info) end return f end

revive = {
    downed = false, down_t = 0, pos = nil,
    near_t = nil,          -- since when the friend has been close
    friend_down = false, friend_down_t = 0,   -- any friend down (kept for the HUD/other scripts)
    down_slots = {},       -- friend slot -> true while that friend is down
    dead_slots = {},       -- v0.68: friend slot -> clock of their "gameover" (a real death): not a rescuer for DEAD_HOLD_S
    allow_death = false,   -- let the next death through (both down, timeout)
    msg = "-", msg_t = -100,
}
local rv = revive
local REVIVE_DIST = 2.8    -- m (the follow-me bot waits 2.5 m away)
local REVIVE_TIME = 3.0    -- s next to you
local REVIVE_HEALTH = 0.35 -- of max health
local DOWN_LIMIT = 90      -- s alone before it's a real death
local NEAR_GRACE_S = 1.5   -- v0.73: s the friend may drop out of reach (a hitch) without the 3 s count starting again
local VIEW_MIN, VIEW_S = 0.75, 3.0   -- v0.67: after a refused scripted kill, a view this low (m above the feet) this long ends the life
-- v0.72: using a healing item within ITEM_DIST of a downed friend gets them up at once (the idea comes from
-- Kingkiller1195's re7mp). The item's health goes to them, not to the one who used it.
-- Bot test 2026-11-27: PlayerOrder.requestUseItem(First Aid Med) -> PlayerWeaponChange.useItem 0.4 s later (the bottle
-- comes out) -> health 300 -> 800 of 1000 ~3 s later -> Inventory.reduceItem("RemedyM", 1) at the end. A Herb can't be
-- used on its own (the game refuses it: it only goes into crafting), so only the Remedy* items count.
local ITEM_DIST = REVIVE_DIST
local ITEM_HEAL = { RemedyM = 50, RemedyL = 100 }   -- % of max health it gives (First Aid Med measured: +500 of 1000)
local ITEM_NAMES = { RemedyM = "a First Aid Med", RemedyL = "a Strong First Aid Med" }
local function item_name(id) return ITEM_NAMES[id] or "a healing item" end
local function heal_item(id) return type(id) == "string" and id:match("^Remedy") ~= nil end
local function who(k) return (k or 1) == 1 and "your friend" or ("friend " .. k) end

-- Lines are collected and appended once a second (was a full read + rewrite per line).
local log_buf, log_t, log_tail = {}, 0, nil
-- v0.52: repeated lines are limited and the file written by coop_dummy.lua's coop_log_gate / coop_log_flush.
local function log(s)
    if coop_log_gate and not coop_log_gate("revive", s) then return end
    log_buf[#log_buf + 1] = os.date("%H:%M:%S ") .. tostring(s)
end
dbg_note{ feature = "Logging", name = "Write the revive script's log file",
    when = "every frame; writes to disk only when 1 to 5 s have passed since the last write",
    reads = "this script's log lines in memory",
    writes = "coop_revive_log.txt" }
re.on_frame(function()
    if coop_log_flush then log_buf, log_t = coop_log_flush("revive", "coop_revive_log.txt", log_buf, log_t) return end
    -- without coop_dummy.lua: the v0.51 writer
    if #log_buf == 0 or os.clock() - log_t < 3 then return end
    log_t = os.clock()
    local f = (log_tail or fs.read("coop_revive_log.txt") or "") .. table.concat(log_buf, "\n") .. "\n"
    if #f > 200000 then f = f:sub(-100000) end
    log_tail = f
    fs.write("coop_revive_log.txt", f)
    log_buf = {}
end)

local function safe(f, ...)
    local ok, r = pcall(f, ...)
    if ok then return r end
    return nil
end

local function note(msg) rv.msg, rv.msg_t = msg, os.clock() log(msg) end

local function send(text) if coop_send_event then coop_send_event(text) log("sent: " .. text) end end

local function chapter()
    local gm = sdk.get_managed_singleton("app.GameManager")
    return tonumber(gm and safe(gm.get_field, gm, "_CurrentChapter") or 0) or 0
end

local function player() return sdk.get_managed_singleton("app.ObjectManager"):get_field("PlayerObj") end
local function player_dc()
    local p = player()
    return p and safe(p.call, p, "getComponent(System.Type)", sdk.typeof("app.PlayerDamageController"))
end

-- Friend k's character here, while it's shown (data fresh, not in their cutscene).
local function friend_ghost(k)
    local env = coop_slot_envs and coop_slot_envs[k]
    if env == nil and k == 1 then env = _G end
    if env == nil then return nil end
    local gf = rawget(env, "coop_ghost") or (k == 1 and coop_ghost) or nil
    local hidden = rawget(env, "ghost_hidden")
    if hidden == nil and k == 1 then hidden = ghost_hidden end
    if gf == nil or hidden ~= false then return nil end
    return gf()
end
local function friend_pos(k)
    local g = friend_ghost(k)
    return g and safe(function() return g:call("get_Transform"):call("get_Position") end)
end
local function any_friend_down()
    for _, v in pairs(rv.down_slots) do if v then return true end end
    return false
end
-- v0.68: a friend whose game said "gameover" (died for real; their game is on its way back to the checkpoint) is
-- not up for DEAD_HOLD_S. Bot fight 2026-11-25 (enemies noticing the bots): one bot died for real while the other
-- was down (no friend up -> the game's own death), its game never said so, and 3 s later the downed one was "got
-- back up" by the dead one standing next to it.
local DEAD_HOLD_S = 30
local function friend_dead(k)
    local t = rv.dead_slots[k]
    return t ~= nil and os.clock() - t < DEAD_HOLD_S
end

-- A friend who is up is with us. In a cutscene or a grab their character is hidden here, so it goes by
-- the link instead (v0.48). Until then a death during a grab was always a real one: on 2026-11-10 a
-- player revived in the morgue fight was killed in Jack's grab 20 s later, their game loaded the
-- checkpoint (story back to before the fight) and they fought on alone while the friend finished it.
-- Friend k's last position from the link (fresh, same chapter), whether or not their character is shown.
-- v0.73: heard from friend k within FRIEND_GRACE_S, in our chapter (their game may be hitching: no fresh position
-- for a few seconds). Being down still ends for real after DOWN_LIMIT if nobody comes.
local FRIEND_GRACE_S = 10
local function friend_heard(k)
    local env = coop_slot_envs and coop_slot_envs[k]
    local fn = env and rawget(env, "coop_friend_heard")
    if fn == nil and k == 1 then fn = coop_friend_heard end
    return fn ~= nil and safe(fn, FRIEND_GRACE_S) == true
end
local function friend_link_pos(k)
    local env = coop_slot_envs and coop_slot_envs[k]
    local fn = env and rawget(env, "coop_friend_sample")
    if fn == nil and k == 1 then fn = coop_friend_sample end
    local smp = fn and safe(fn)
    return smp and smp.pos or nil
end
-- v0.49: a friend in THEIR cutscene is hidden here too, and counted as gone: in the bot suite a player
-- killed by Jack while the friend watched a 60 s scene (one that puts its player 53 m off) got a real
-- game over, and the game sat paused on it, without a word in the log. v0.48's 40 m limit (for our own
-- grab or scene) went too: a friend whose character is shown counted at any distance anyway, and being
-- down still ends for real after DOWN_LIMIT if nobody comes. So: a friend who's up and in this chapter,
-- by the link (fresh data), counts, whoever is in a scene.
local function friend_here()
    local in_scene = local_cutscene and local_cutscene()
    for k = 1, 3 do
        if not rv.down_slots[k] and not friend_dead(k) then
            if not in_scene and friend_ghost(k) ~= nil then return true end
            if friend_link_pos(k) ~= nil then return true end
            if friend_heard(k) then return true end
        end
    end
    return false
end

local function should_go_down()
    if rv.allow_death then return false end
    if rv.downed then return true end           -- already down: no dying while we wait
    return friend_here()                        -- nobody up and here: a real death
end

-- How being down looks: forced crouch (the view drops; the friend sees our Ethan
-- crouched), no control, black-and-white damage screen. PlayerOrder.setReserveProne did
-- nothing visible, so it's not used.
local function down_look(on)
    local p = player()
    if p == nil then return end
    local o = safe(p.call, p, "getComponent(System.Type)", sdk.typeof("app.PlayerOrder"))
    local mv = safe(p.call, p, "getComponent(System.Type)", sdk.typeof("app.PlayerMovement"))
    if mv then pcall(mv.call, mv, "set_isCrouch(System.Boolean)", on) end
    if o then
        pcall(o.call, o, "switchPlayerOperatable(System.Boolean, app.PlayerDefine.OperationLayer)", not on, 0)
        pcall(o.call, o, "setDamageGUIMonochrome(System.Boolean)", on)
    end
end

local function go_down()
    if rv.downed then return end
    -- A friend's "up" that got lost would keep them "down" forever: forget old downs.
    if os.clock() - (rv.friend_down_t or 0) > DOWN_LIMIT + 10 then rv.down_slots = {} rv.friend_down = false end
    rv.downed, rv.down_t, rv.near_t = true, os.clock(), nil
    local p = player()
    local pos = p and p:call("get_Transform"):call("get_Position")
    rv.pos = pos and Vector3f.new(pos.x, pos.y, pos.z)
    rv.rot = p and p:call("get_Transform"):call("get_Rotation")
    pcall(down_look, true)
    send(string.format("down %d", chapter()))
    if coop_stat then pcall(coop_stat, "downs") end
    note("you're down - a friend has to reach you")
end

-- A finishing grab that kept the body (v0.68). Jack's finishing kill (garage: CommonFinishNeck) plays its player half
-- on our body's motion layer 0 through app.MotionManager's external task, and then asks for a game over. With a friend
-- up that game over is refused and we go down, but nothing ends the task: layer 0 stays jacked on the kill's last
-- frame, and the first-person camera (it rides the head bone) stays where the head fell, through being helped up and
-- after ("revived but his camera still stayed down like his head was cut off", 2026-11-25; bot test: the camera 0.05 m
-- above the feet, layer 0 motion 112 frame 435/435 jacked). MotionManager.clearExternalTask gives the layer back to the
-- player's own motion (bot test: camera 0.18 -> 0.88 m down, 1.6 m up). Done while down once the grab's motion has
-- stood on its last frame for HELD_GRAB_S, and when getting up whatever the frame (no grab goes on through that).
local HELD_GRAB_S = 1.0
local function release_held_grab(why, at_end_only)
    local p = player()
    local mo = p and safe(p.call, p, "getComponent(System.Type)", sdk.typeof("via.motion.Motion"))
    local L = mo and safe(mo.call, mo, "getLayer", 0)
    if L == nil or safe(L.call, L, "get_Jacked") ~= true then rv.held_grab_t = nil return false end
    if at_end_only then
        local f, e = tonumber(safe(L.call, L, "get_Frame")), tonumber(safe(L.call, L, "get_EndFrame"))
        if not (f and e and e > 0 and f >= e - 0.5) then rv.held_grab_t = nil return false end
        rv.held_grab_t = rv.held_grab_t or os.clock()
        if os.clock() - rv.held_grab_t < HELD_GRAB_S then return false end
    end
    rv.held_grab_t = nil
    local mm = safe(p.call, p, "getComponent(System.Type)", sdk.typeof("app.MotionManager"))
    if mm == nil then return false end
    local ok = pcall(mm.call, mm, "clearExternalTask")
    log(string.format("a finishing grab still held our body (motion %s, frame %s): released (%s)%s",
        tostring(safe(L.call, L, "get_MotionID")), tostring(safe(L.call, L, "get_Frame")), why, ok and "" or " ERR"))
    return ok
end

local function get_up(why, health)
    rv.downed, rv.near_t = false, nil
    rv.up_t = os.clock()
    pcall(release_held_grab, "getting up", false)
    pcall(down_look, false)
    local dc = player_dc()
    if dc then
        local max = dc:call("get_maxHealth") or 1000
        pcall(dc.call, dc, "setHealth(System.Single, System.Single)", max * math.max(REVIVE_HEALTH, math.min(1, health or 0)), max)
    end
    send("up")
    note(why)
    -- v0.67: watch the view for a while after a scripted kill was refused (see VIEW_MIN in the frame callback).
    if rv.gameover_t then rv.view_watch_t, rv.view_low_t = os.clock(), nil end
end

local function die_for_real(why)
    rv.downed, rv.allow_death = false, true
    pcall(down_look, false)
    log("real death: " .. why)
    local p, dc = player(), player_dc()
    if p and dc then
        local m = sdk.find_type_definition("app.DamageController"):get_method("newFakeDamageInfo")
        if m == nil then return end
        pcall(dc.call, dc, "setHealth(System.Single, System.Single)", 1.0, dc:call("get_maxHealth") or 1000)
        pcall(dc.call, dc, "addManualDamage", m:call(nil, 100000.0, p, p))
    end
    rv.dead_sent = true   -- v0.68: the death watch in the frame callback doesn't say it again
    send("gameover")
end

-- Stop the death. canDie lives on DamageController (enemies too), so only for our player.
local skip_next = false
local function hook_die(method)
    dbg_note{ feature = "Going down and being revived", name = "Stop a fatal hit on our player (go down instead)",
        when = "when the game calls DamageController.canDie / PlayerDamageController.isEnableDieByDamageInfo (every hit any character takes, enemies included)",
        reads = "is the hit's controller our player's? should we go down (a friend is up in this chapter)?",
        writes = "tells the game 'cannot die' for our player when going down is allowed" }
    sdk.hook(method, function(args)
        skip_next = false
        local ok = pcall(function()
            local dc = player_dc()
            if dc and sdk.to_int64(args[2]) == dc:get_address() then
                if should_go_down() then skip_next = true
                elseif not rv.allow_death and os.clock() - (rv.real_log_t or -100) > 10 then
                    -- Said in the log (v0.49): the suite's real death left nothing to go on.
                    rv.real_log_t = os.clock()
                    log("a fatal hit goes through: no friend up in this chapter")
                end
            end
        end)
        if skip_next then
            pcall(go_down)
            return sdk.PreHookResult.SKIP_ORIGINAL
        end
    end, function(retval)
        if skip_next then skip_next = false return sdk.to_ptr(0) end   -- "can't die"
        return retval
    end)
end
local pdc = sdk.find_type_definition("app.PlayerDamageController")
local m1 = pdc:get_method("isEnableDieByDamageInfo(app.Collision.HitController.DamageInfo)")
local m2 = sdk.find_type_definition("app.DamageController"):get_method("canDie(app.Collision.HitController.DamageInfo)")
if m1 then hook_die(m1) end
if m2 then hook_die(m2) end
log("revive hooks: isEnableDieByDamageInfo " .. tostring(m1 ~= nil) .. ", canDie " .. tostring(m2 ~= nil))

-- The game's own game over (v0.48). A scripted kill (a boss's finishing grab, a timeline's PlayerDeadTrack,
-- the fsm action SetGameOver) doesn't ask canDie: it sets the game-over flag, the screen fades and the
-- checkpoint loads. With a friend up and near, that flag is refused and we go down instead, for the
-- friend to get us up; with nobody there (or once the 90 s are up) it goes through as before.
rv.gameover_refused = 0
do
    local gmt = sdk.find_type_definition("app.GameManager")
    local m = gmt and gmt:get_method("setGameOverFlag(System.Boolean)")
    local skip = false
    if m then
        dbg_note{ feature = "Going down and being revived", name = "Refuse the game's game over while a friend is up",
            when = "when the game calls GameManager.setGameOverFlag",
            reads = "the argument (is it turning game over on?), whether a friend is up in this chapter",
            writes = "SKIPS the game over and lets us go down instead; otherwise lets it through" }
        pcall(sdk.hook, m, function(args)
            skip = false
            pcall(function()
                if (sdk.to_int64(args[3]) & 1) == 1 then
                    if should_go_down() then skip = true
                    elseif not rv.allow_death then log("the game's game over goes through: no friend up in this chapter") end
                end
            end)
            if skip then
                rv.gameover_refused = rv.gameover_refused + 1
                rv.gameover_t = os.clock()
                log("game over refused: a friend is up, going down instead")
                pcall(go_down)
                return sdk.PreHookResult.SKIP_ORIGINAL
            end
        end, function(r) return r end)
    end
    log("revive hooks: setGameOverFlag " .. tostring(m ~= nil))
end

-- v0.72: a healing item used next to a downed friend gets them up (the idea comes from Kingkiller1195's re7mp).
-- PlayerWeaponChange.useItem starts the use (the bottle comes out): with a friend down within ITEM_DIST, they're told
-- at once ("upitem <id> <percent>") and get up with the item's health. The item is spent by the game as usual, and
-- its health is the friend's: ours is held at what it was until the use is over (see the frame callback below).
local function nearest_down_friend()
    local p = player()
    local me = p and safe(function() return p:call("get_Transform"):call("get_Position") end)
    if me == nil then return nil end
    local best, bd
    for k, v in pairs(rv.down_slots) do
        if v and not friend_dead(k) then
            local gp = friend_pos(k) or friend_link_pos(k)
            local d = gp and math.sqrt((gp.x - me.x) ^ 2 + (gp.z - me.z) ^ 2) or nil
            if d and (bd == nil or d < bd) then best, bd = k, d end
        end
    end
    return best, bd
end
local function on_item_use(id)
    if not heal_item(id) then return end
    rv.item_use = nil   -- a new healing use ends any hold from the last one: this one is ours unless it's for a friend
    if rv.downed then return end
    local k, d = nearest_down_friend()
    if k == nil or d > ITEM_DIST then return end
    local dc = player_dc()
    local h = dc and tonumber(safe(dc.call, dc, "get_health"))
    local pct = ITEM_HEAL[id] or 50
    rv.item_use = { id = id, t = os.clock(), hp = h, k = k }
    rv.item_t = os.clock()   -- coop_talk's heal-your-friend leaves this heal alone
    send(string.format("upitem %s %d", id, pct))
    note(string.format("you used %s on %s (%.1f m)", item_name(id), who(k), d))
end
do
    local wc = sdk.find_type_definition("app.PlayerWeaponChange")
    local m = wc and wc:get_method("useItem(app.Item, app.Weapon)")
    if m then
        dbg_note{ feature = "Going down and being revived", name = "A healing item used next to a downed friend gets them up",
            when = "when the game calls PlayerWeaponChange.useItem (any item or weapon our player starts to use)",
            reads = "the item's id (First Aid Meds only), our player, downed friends' positions",
            writes = "sends 'upitem' to the friend's game; our own health is held where it was until the use is over" }
        pcall(sdk.hook, m, function(args)
            pcall(function()
                local this = sdk.to_managed_object(args[2])
                local p = player()
                local go = this and this:call("get_GameObject")
                if go == nil or p == nil or go:get_address() ~= p:get_address() then return end
                local it = sdk.to_managed_object(args[3])
                local id = it and it:get_field("ItemDataID")
                on_item_use(id and tostring(id))
            end)
        end, function(r) return r end)
    end
    log("revive hooks: useItem " .. tostring(m ~= nil))
    local inv = sdk.find_type_definition("app.Inventory")
    local mr = inv and inv:get_method("reduceItem(System.String, System.Int32, System.Boolean)")
    if mr then
        dbg_note{ feature = "Going down and being revived", name = "Notice the game spending the healing item used on a friend",
            when = "when the game calls Inventory.reduceItem (an item leaves an inventory)",
            reads = "the item's id, the healing item being used on a friend",
            writes = "ends the hold on our health half a second later" }
        pcall(sdk.hook, mr, function(args)
            pcall(function()
                local u = rv.item_use
                if u == nil or u.spent then return end
                local id = sdk.to_managed_object(args[3])
                if id and tostring(id:call("ToString")) == u.id then u.spent = os.clock() end
            end)
        end, function(r) return r end)
    end
end

-- While down: hold position, keep 1 health, watch for the friend.
dbg_note{ feature = "Going down and being revived", name = "While down: hold still, keep 1 health, wait for the friend",
    when = "every frame; the heavy part runs only while we are down",
    reads = "while down: our PlayerDamageController health, MovementController, the friend's position",
    writes = "while down: sets health to 1, holds our position, shows the revive prompt; revives when the friend is close; ends the life the game's way when no friend is up" }
re.on_frame(function()
    local now = os.clock()
    if rv.allow_death then
        -- The real death is under way; re-arm once the player is rebuilt (load/retry).
        local dc = player_dc()
        if dc and not dc:call("get_isDead") and now - (rv.allow_t or now) > 10 then rv.allow_death = false end
        rv.allow_t = rv.allow_t or now
        return
    end
    -- Helped up after a refused game over, but the game still has us dead 6 s on (the kill had gone too
    -- far to walk away from): let this life end the game's way rather than leave a player who can't move.
    if not rv.downed and rv.gameover_t and rv.up_t and rv.up_t > rv.gameover_t and now - rv.up_t > 6 then
        rv.gameover_t = nil
        local dc = player_dc()
        local ps = player()
        ps = ps and safe(ps.call, ps, "getComponent(System.Type)", sdk.typeof("app.PlayerStatus"))
        if (dc and safe(dc.call, dc, "get_isDead") == true) or (ps and safe(ps.call, ps, "get_IsDead") == true) then
            die_for_real("still dead after being helped up")
        end
    end
    -- v0.67: helped up after a refused game over, but the view stayed on the floor (bot windows 2026-11-25: Jack's
    -- head-off kill, Chapter3Battle1NeckSlash; "revived but his camera still stayed down like his head was cut off").
    -- The first-person camera rides the head bone (probe: camera and Head joint both 1.6 m above the feet standing), and
    -- the kill's motion leaves that bone where the head fell; nothing in getting up puts it back. Same as the rule
    -- above: a view under VIEW_MIN above the feet for VIEW_S while not crouching ends this life the game's way (the
    -- checkpoint loads) instead of leaving a player who can't see to play. The heights go in the log.
    if not rv.downed and rv.view_watch_t and now - rv.view_watch_t < 20 then
        local p = player()
        local cam = sdk.get_primary_camera()
        local cgo = cam and safe(cam.call, cam, "get_GameObject")
        local cp = cgo and safe(function() return cgo:call("get_Transform"):call("get_Position") end)
        local pp = p and safe(function() return p:call("get_Transform"):call("get_Position") end)
        local pm = p and safe(p.call, p, "getComponent(System.Type)", sdk.typeof("app.PlayerMovement"))
        local crouch = pm and safe(pm.call, pm, "get_isCrouch") == true
        local h = (cp and pp) and (cp.y - pp.y) or nil
        if h and h < VIEW_MIN and not crouch then
            rv.view_low_t = rv.view_low_t or now
            if now - rv.view_low_t >= VIEW_S then
                rv.view_watch_t, rv.view_low_t = nil, nil
                log(string.format("view stuck low after being helped up: camera %.2f m above the feet", h))
                die_for_real("the view stayed on the floor after being helped up")
            end
        else
            rv.view_low_t = nil
        end
    elseif rv.view_watch_t then
        rv.view_watch_t, rv.view_low_t = nil, nil
    end
    -- v0.68: our player died for real by the game's own way (no friend up, so the hit or game over went through):
    -- friends are told, once, with the same "gameover" die_for_real sends, so they don't count us as up (friend_dead).
    -- Not in the 8 s after being helped up: a refused kill can leave isDead set that long (the rule above decides those).
    if not rv.downed and now - (rv.dead_check_t or 0) >= 0.5 and now - (rv.up_t or -100) > 8 then
        rv.dead_check_t = now
        local dc = safe(player_dc)   -- nil on the title screen (no ObjectManager yet)
        local dead = dc and safe(dc.call, dc, "get_isDead") == true
        if dead and not rv.dead_sent then
            rv.dead_sent = true
            log("died for real (the game's own death): telling friends")
            send("gameover")
        elseif not dead and dc then
            rv.dead_sent = false
        end
    end
    -- v0.72: a healing item used on a downed friend (on_item_use): its health is theirs, so ours stays where it was
    -- (lower after a hit, never higher) until half a second after the game spent the item, or 20 s at most (the use
    -- takes ~3.5 s; bot windows in the background run their frames in bursts and took over 8 s), or our next healing use.
    local u = rv.item_use
    if u then
        if now - u.t > 20 or (u.spent and now - u.spent > 0.5) then
            rv.item_use = nil
        elseif u.hp then
            local dc = safe(player_dc)
            local h = dc and tonumber(safe(dc.call, dc, "get_health"))
            if h and h < u.hp then u.hp = h
            elseif h and h > u.hp + 0.5 then
                pcall(dc.call, dc, "setHealth(System.Single, System.Single)", u.hp, dc:call("get_maxHealth") or 1000)
                if not u.held then u.held = true log(string.format("the %s's health went to the friend: ours kept at %.0f", u.id, u.hp)) end
            end
        end
    end
    if not rv.downed then return end
    local ok, err = pcall(function()
        local p, dc = player(), player_dc()
        if p == nil or dc == nil then return end
        if (dc:call("get_health") or 1) < 1 then
            pcall(dc.call, dc, "setHealth(System.Single, System.Single)", 1.0, dc:call("get_maxHealth") or 1000)
        end
        -- v0.68: a finished grab still holding our body (see release_held_grab).
        release_held_grab("while down", true)
        -- Keep the down look (a hit or the game can stand us up again).
        local mv = p:call("getComponent(System.Type)", sdk.typeof("app.PlayerMovement"))
        if mv and not mv:call("get_isCrouch") then pcall(down_look, true) end
        local mc = p:call("getComponent(System.Type)", sdk.typeof("app.MovementController"))
        if mc and rv.pos then
            local cur = p:call("get_Transform"):call("get_Position")
            if (cur.x - rv.pos.x) ^ 2 + (cur.z - rv.pos.z) ^ 2 > 0.01 then
                pcall(mc.call, mc, "warp(via.vec3, via.Quaternion)", rv.pos, p:call("get_Transform"):call("get_Rotation"))
            end
        end
        -- A friend who is up, close for REVIVE_TIME → up.
        local close = false
        -- v0.68: in our own scene the friend's character is hidden here (friend_pos is nil), so their position comes
        -- from the link, as in friend_here. Bot test: down during the garage car fight's event (c03e02_00 running),
        -- the friend stood 0.8 m away and nobody could get us up; after 90 s it was a real death.
        local in_scene = local_cutscene and local_cutscene()
        for k = 1, 3 do
            local up_k = not rv.down_slots[k] and not friend_dead(k)
            local gp = up_k and (friend_pos(k) or (in_scene and friend_link_pos(k)) or nil)
            if gp and rv.pos and math.sqrt((gp.x - rv.pos.x) ^ 2 + (gp.z - rv.pos.z) ^ 2) < REVIVE_DIST then close = true end
        end
        if close then
            rv.near_t = rv.near_t or now
            rv.close_t = now
            if now - rv.near_t >= REVIVE_TIME then
                get_up("your friend got you back up")
                if coop_stat then pcall(coop_stat, "got_up") end   -- the session page (v0.42)
            end
        elseif rv.near_t and now - (rv.close_t or 0) > NEAR_GRACE_S then
            -- v0.73: a moment without the friend (their character hidden for 'no data for 2 s' while their game
            -- hitched) no longer starts the count again; getting up still needs them close at the end.
            rv.near_t = nil
        end
        if rv.downed and now - rv.down_t > DOWN_LIMIT then die_for_real("nobody came for 90 s")
        elseif rv.downed and now - rv.down_t > 2 and any_friend_down() and not friend_here() then
            -- Everyone else here is down too: a real death (as with two players).
            die_for_real("everyone is down")
        end
    end)
    if not ok and not rv.err then rv.err = true log("downed ERR " .. tostring(err)) end
end)

-- Friend's events (called by coop_enemies.lua); true if it was ours.
-- The downed friend lies on the floor on our screen (Ethan's Hands_Supine_Loop, motion 200,
-- played as a full-body move by coop_dummy's action layer) instead of only crouching.
local SUPINE = 200
local function friend_pose(down, k)
    local env = coop_slot_envs and coop_slot_envs[k or 1]
    local nf = env and rawget(env, "coop_net_state") or coop_net_state
    local net = nf and nf()
    if net then net.forced_action, net.forced_action_layer = down and SUPINE or nil, 0 end
end


function coop_revive_on_event(text)
    local k = coop_event_slot or 1
    local item, pct = text:match("^upitem (%S+) (%d+)$")
    if item then
        -- v0.72: friend k used a healing item next to us (see ITEM_DIST). Up at once, with the item's health (never
        -- less than the usual REVIVE_HEALTH), if we're still down and they're still close here (by our own view of them).
        if not rv.downed then return true end
        local gp = friend_pos(k) or friend_link_pos(k)
        local d = (gp and rv.pos) and math.sqrt((gp.x - rv.pos.x) ^ 2 + (gp.z - rv.pos.z) ^ 2) or nil
        if d == nil or d > ITEM_DIST * 1.3 then
            log(string.format("%s used %s on us but is %s m away here: not taken", who(k), item, d and string.format("%.1f", d) or "?"))
            return true
        end
        get_up(who(k) .. " used " .. item_name(item) .. " on you", tonumber(pct) / 100)
        if coop_stat then pcall(coop_stat, "got_up") end
        return true
    elseif text:match("^down ") then
        rv.down_slots[k] = true
        rv.friend_down, rv.friend_down_t = true, os.clock()
        pcall(friend_pose, true, k)
        note(who(k) .. " is down - go to them!")
        return true
    elseif text == "up" then
        rv.down_slots[k], rv.dead_slots[k] = nil, nil
        rv.friend_down = any_friend_down()
        pcall(friend_pose, false, k)
        if coop_voice_play then pcall(coop_voice_play, "up", k) end   -- v0.42: heard getting up
        note(who(k) .. " is back up")
        return true
    elseif text == "gameover" then
        rv.down_slots[k], rv.dead_slots[k] = nil, os.clock()
        rv.friend_down = any_friend_down()
        pcall(friend_pose, false, k)
        -- Nobody left up to get us: we go too.
        if rv.downed and not friend_here() then pcall(die_for_real, who(k) .. " died while you were down") end
        note(who(k) .. " died")
        return true
    end
    return false
end

-- On-screen lines (coop_dummy shows them).
function revive_hud()
    local now = os.clock()
    if rv.downed then
        local left = math.max(0, DOWN_LIMIT - (now - rv.down_t))
        local s = string.format("You're down! A friend has to reach you (%d s)", math.floor(left))
        if rv.near_t then s = s .. string.format(" - getting up %.0f%%", math.min(100, (now - rv.near_t) / REVIVE_TIME * 100)) end
        return s, 0xFF6B6BFF
    end
    if any_friend_down() then
        -- The nearest friend who is down.
        local p = player()
        local b = p and safe(function() return p:call("get_Transform"):call("get_Position") end)
        local best, bd
        for k in pairs(rv.down_slots) do
            local env = coop_slot_envs and coop_slot_envs[k]
            local gf = env and rawget(env, "coop_ghost") or (k == 1 and coop_ghost) or nil
            local g = gf and gf()
            local a = g and safe(function() return g:call("get_Transform"):call("get_Position") end)
            local d = (a and b) and math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2) or nil
            if best == nil or (d and (bd == nil or d < bd)) then best, bd = k, d end
        end
        local name = who(best)
        return name:sub(1, 1):upper() .. name:sub(2) .. " is down! Stand next to them or use a First Aid Med there ("
            .. (bd and string.format("%d m", math.floor(bd)) or "?") .. " away)", 0xFF6B6BFF
    end
    if now - rv.msg_t < 5 then return rv.msg, 0xFF7FE6FF end
    return nil
end

-- Testing: take a hit big enough to kill (you go down if a friend or the bot is with you).
function revive_test_would_go_down() return should_go_down() end
function revive_test_refuse_gameover()
    if not should_go_down() then return false end
    rv.gameover_refused, rv.gameover_t = rv.gameover_refused + 1, os.clock()
    go_down()
    return true
end
function revive_test_fatal_hit()
    local p, dc = player(), player_dc()
    if p == nil or dc == nil then return "no player" end
    local m = sdk.find_type_definition("app.DamageController"):get_method("newFakeDamageInfo")
    local ok, err = pcall(dc.call, dc, "addManualDamage", m:call(nil, (dc:call("get_health") or 1000) * 4 + 1000, p, p))
    return ok and "fatal hit taken" or ("ERR " .. tostring(err))
end

coop_revive_on_event = dbg_task("Friend's events", "Apply a 'down' / 'up' / 'gameover' event from the friend", coop_revive_on_event, {
    when = "when the friend's game sends 'down', 'up' or 'gameover'",
    reads = "the event text",
    writes = "lays the friend's ghost down or stands it up; plays the 'up' voice; ends our life if nobody is left standing" })
log("coop_revive loaded")
