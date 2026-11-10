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

revive = {
    downed = false, down_t = 0, pos = nil,
    near_t = nil,          -- since when the friend has been close
    friend_down = false, friend_down_t = 0,   -- any friend down (kept for the HUD/other scripts)
    down_slots = {},       -- friend slot -> true while that friend is down
    allow_death = false,   -- let the next death through (both down, timeout)
    msg = "-", msg_t = -100,
}
local rv = revive
local REVIVE_DIST = 2.8    -- m (the follow-me bot waits 2.5 m away)
local REVIVE_TIME = 3.0    -- s next to you
local REVIVE_HEALTH = 0.35 -- of max health
local DOWN_LIMIT = 90      -- s alone before it's a real death

-- Lines are collected and appended once a second (was a full read + rewrite per line).
local log_buf, log_t = {}, 0
local function log(s)
    log_buf[#log_buf + 1] = os.date("%H:%M:%S ") .. tostring(s)
end
re.on_frame(function()
    if #log_buf == 0 or os.clock() - log_t < 1 then return end
    log_t = os.clock()
    local f = fs.read("coop_revive_log.txt") or ""
    if #f > 100000 then f = f:sub(-50000) end
    fs.write("coop_revive_log.txt", f .. table.concat(log_buf, "\n") .. "\n")
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

-- A friend who is up is with us, and we're not in a cutscene.
local function friend_here()
    if local_cutscene and local_cutscene() then return false end
    for k = 1, 3 do
        if not rv.down_slots[k] and friend_ghost(k) ~= nil then return true end
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

local function get_up(why)
    rv.downed, rv.near_t = false, nil
    pcall(down_look, false)
    local dc = player_dc()
    if dc then
        local max = dc:call("get_maxHealth") or 1000
        pcall(dc.call, dc, "setHealth(System.Single, System.Single)", max * REVIVE_HEALTH, max)
    end
    send("up")
    note(why)
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
    send("gameover")
end

-- Stop the death. canDie lives on DamageController (enemies too), so only for our player.
local skip_next = false
local function hook_die(method)
    sdk.hook(method, function(args)
        skip_next = false
        local ok = pcall(function()
            local dc = player_dc()
            if dc and sdk.to_int64(args[2]) == dc:get_address() and should_go_down() then skip_next = true end
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

-- While down: hold position, keep 1 health, watch for the friend.
re.on_frame(function()
    local now = os.clock()
    if rv.allow_death then
        -- The real death is under way; re-arm once the player is rebuilt (load/retry).
        local dc = player_dc()
        if dc and not dc:call("get_isDead") and now - (rv.allow_t or now) > 10 then rv.allow_death = false end
        rv.allow_t = rv.allow_t or now
        return
    end
    if not rv.downed then return end
    local ok, err = pcall(function()
        local p, dc = player(), player_dc()
        if p == nil or dc == nil then return end
        if (dc:call("get_health") or 1) < 1 then
            pcall(dc.call, dc, "setHealth(System.Single, System.Single)", 1.0, dc:call("get_maxHealth") or 1000)
        end
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
        for k = 1, 3 do
            local gp = not rv.down_slots[k] and friend_pos(k)
            if gp and rv.pos and math.sqrt((gp.x - rv.pos.x) ^ 2 + (gp.z - rv.pos.z) ^ 2) < REVIVE_DIST then close = true end
        end
        if close then
            rv.near_t = rv.near_t or now
            if now - rv.near_t >= REVIVE_TIME then
                get_up("your friend got you back up")
                if coop_stat then pcall(coop_stat, "got_up") end   -- the session page (v0.42)
            end
        else
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

local function who(k) return (k or 1) == 1 and "your friend" or ("friend " .. k) end

function coop_revive_on_event(text)
    local k = coop_event_slot or 1
    if text:match("^down ") then
        rv.down_slots[k] = true
        rv.friend_down, rv.friend_down_t = true, os.clock()
        pcall(friend_pose, true, k)
        note(who(k) .. " is down - go to them!")
        return true
    elseif text == "up" then
        rv.down_slots[k] = nil
        rv.friend_down = any_friend_down()
        pcall(friend_pose, false, k)
        if coop_voice_play then pcall(coop_voice_play, "up", k) end   -- v0.42: heard getting up
        note(who(k) .. " is back up")
        return true
    elseif text == "gameover" then
        rv.down_slots[k] = nil
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
        return name:sub(1, 1):upper() .. name:sub(2) .. " is down! Stand next to them to get them up ("
            .. (bd and string.format("%d m", math.floor(bd)) or "?") .. " away)", 0xFF6B6BFF
    end
    if now - rv.msg_t < 5 then return rv.msg, 0xFF7FE6FF end
    return nil
end

-- Testing: take a hit big enough to kill (you go down if a friend or the bot is with you).
function revive_test_fatal_hit()
    local p, dc = player(), player_dc()
    if p == nil or dc == nil then return "no player" end
    local m = sdk.find_type_definition("app.DamageController"):get_method("newFakeDamageInfo")
    local ok, err = pcall(dc.call, dc, "addManualDamage", m:call(nil, (dc:call("get_health") or 1000) * 4 + 1000, p, p))
    return ok and "fatal hit taken" or ("ERR " .. tostring(err))
end

log("coop_revive loaded")
