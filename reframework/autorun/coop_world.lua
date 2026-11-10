-- coop_world.lua: shared doors and items.
-- Events go through coop_enemies.lua's reliable channel (coop_send_event) and come back
-- through coop_world_on_event.
--   unlock <door id> <chapter>  a door was unlocked (key, one-way door, story)
--   open <door id> <chapter>    a door swung open
--   close <door id> <chapter>   it swung shut again
--   took <item id> <chapter> <item name>  a supply was picked up
--   break <box id> <chapter>    a breakable box (app.ItemDropDestruct) was smashed
--   drawer <id> <0|1> <chapter> a drawer (app.InteractDrawer) was shut / pulled open
--   intr <id> <chapter>         a one-off interaction (fridge, van, pot...) was completed
--   switch <id> <0|1> <chapter> a switch (app.InteractSwitch) was turned off / on
--   phys <key> <x y z> <qw qx qy qz> <chapter>  a loose physics prop (chair...) moved
-- Doors (app.DoorPush) and items (app.Item) carry SaveGUID, saved in the level, so the id
-- is the same on both PCs. Supplies (ammo, healing, materials, weapons) picked up by one
-- player vanish for the other (Item.disableFromScene); key items, files and maps stay in
-- both worlds so nobody gets stuck. A pickup for an area the other player hasn't loaded
-- yet is remembered and applied when it loads.

world_sync = {
    doors = {},        -- id -> { d = DoorPush, locked, open }
    doors_t = -100, poll_t = 0, items_t = -100,
    items = {},        -- id -> { it = Item, go }
    pending_took = {}, -- id -> chapter
    pending_unlock = {},  -- door id -> chapter (unlocked by the friend, not loaded here yet)
    pending_props = {},   -- "kind:id" -> { kind, id, want, ch } (same, for boxes/drawers/switches)
    applying = {},     -- id -> clock: changes we made on the friend's word (not sent back)
    props = {},        -- "box:<id>" / "drawer:<id>" -> { c = component, kind, on }
    props_t = -100,
    sent = 0, applied = 0, msg = "-", msg_t = -100,
}
local ws = world_sync

-- Lines are collected and appended once a second (was a full read + rewrite per line).
local log_buf, log_t = {}, 0
local function log(s)
    log_buf[#log_buf + 1] = os.date("%H:%M:%S ") .. tostring(s)
end
re.on_frame(function()
    if #log_buf == 0 or os.clock() - log_t < 1 then return end
    log_t = os.clock()
    local f = fs.read("coop_world_log.txt") or ""
    if #f > 200000 then f = f:sub(-100000) end
    fs.write("coop_world_log.txt", f .. table.concat(log_buf, "\n") .. "\n")
    log_buf = {}
end)

local function safe(f, ...)
    local ok, r = pcall(f, ...)
    if ok then return r end
    return nil
end
-- A managed array's items, or {} (v0.33: a query during a load once returned a non-array).
local function elems(arr)
    if arr == nil then return {} end
    local ok, r = pcall(function() return arr:get_elements() end)
    return (ok and r) or {}
end

local function chapter()
    local gm = sdk.get_managed_singleton("app.GameManager")
    return tonumber(gm and safe(gm.get_field, gm, "_CurrentChapter") or 0) or 0
end

local function note(msg)
    ws.msg, ws.msg_t = msg, os.clock()
    log(msg)
end

local function guid_text(g)
    local b = {}
    for i = 0, 7 do b[#b + 1] = string.format("%02x", (g:get_field("mData4_" .. i) or 0) & 0xFF) end
    return string.format("%08x-%04x-%04x-%s", (g:get_field("mData1") or 0) & 0xFFFFFFFF,
        (g:get_field("mData2") or 0) & 0xFFFF, (g:get_field("mData3") or 0) & 0xFFFF, table.concat(b))
end

local function id_of(comp)
    local g = safe(comp.get_field, comp, "SaveGUID")
    local t = g and safe(guid_text, g)
    if t == nil or t == "00000000-0000-0000-0000000000000000" then return nil end
    return t
end

local function send(text)
    if coop_send_event then
        coop_send_event(text)
        ws.sent = ws.sent + 1
        -- Door angles go 10 times a second while pushing: only the first of a push is logged.
        local did = text:match("^dang (%S+)")
        if did == nil then log("sent: " .. text)
        elseif ws.dang_logged ~= did then ws.dang_logged = did log("sent: " .. text .. " (and more angles)") end
    end
end

local function scene()
    return sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"),
        sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
end

-- Supplies are shared; weapons, keys, files and maps (ItemCategoryType 1, 4, 5, 6, 9, 10)
-- are not. Weapon pickups start story beats (the Chapter 1 handgun): taking one away
-- froze the friend mid-pickup (2026-11-02).
local KEYISH = { [1] = true, [4] = true, [5] = true, [6] = true, [9] = true, [10] = true }
local function is_supply(it)
    local d = safe(it.call, it, "get_ItemData")
    local cat = d and safe(d.get_field, d, "Category")
    return cat ~= nil and not KEYISH[cat]
end

-- Doors ------------------------------------------------------------------------------
-- doorState: 0 closed, 1 locked, 2 little open (creaks ajar as you approach), 3 pushed,
-- 4 auto-opening, 5 opened, 6 auto-closing. Only 3-5 count as "opened by someone".
local function is_open(state) return state ~= nil and state >= 3 and state <= 5 end

local function refresh_doors()
    local sc = scene()
    local arr = sc and safe(sc.call, sc, "findComponents(System.Type)", sdk.typeof("app.DoorPush"))
    local seen = {}
    for _, d in ipairs(elems(arr)) do
        local id = id_of(d)
        if id then
            seen[id] = true
            if ws.doors[id] == nil or ws.doors[id].d ~= d then
                local st = d:call("get_doorState")
                ws.doors[id] = { d = d, locked = d:call("get_isLocked") == true,
                    open = is_open(st), full = st == 4 or st == 5, state = st }
            end
        end
    end
    for id in pairs(ws.doors) do if not seen[id] then ws.doors[id] = nil end end
end

-- An "open" that didn't take (v0.25): 87 of 106 remote opens in three sessions left the door
-- at state 0 or 1, the latched main-house doors. Checked 0.7 s later and retried from the
-- other two sides (OpenSide 0 and 1; 2 was the only one used). Every try is logged.
-- Opening and closing a door for the friend (v0.26, tested live 2026-11-04 on a latched
-- main-house door, sm1050): the one-argument requestAutoOpen(side) did nothing on those doors
-- (87 of 106 remote opens). The six-argument requestAutoOpen(side, angle, speed, ease, doFix,
-- doMute), with the door's own auto-open speed and ease, swings it open over about 1.3 s
-- (state 4, then 5); requestAutoClose(speed, ease, doLock, doMute) swings it shut (6, then 0).
-- requestOpened(side, angle, doFix) and requestClosed(doLock) snap it, kept as fallbacks.
-- OpenSide: Front 0, Back 1, Auto 2.
ws.open_retry = {}
local function door_open(d)
    local angle = tonumber(safe(d.get_field, d, "CurrentMaxOpenAngle")) or tonumber(safe(d.get_field, d, "MaxOpenAngle")) or 90
    if angle <= 0 then angle = 90 end
    angle = angle + 0.0
    local speed = tonumber(safe(d.get_field, d, "AutoOpenRotationSpeed")) or 50
    local ease = safe(d.get_field, d, "AutoOpenEaseType") or 0
    return pcall(d.call, d,
        "requestAutoOpen(app.DoorPush.OpenSide, System.Single, System.Single, via.curve.EaseType, System.Boolean, System.Boolean)",
        2, angle, speed, ease, false, false)
end
local function door_close(d)
    local speed = tonumber(safe(d.get_field, d, "AutoCloseRotationSpeed")) or 50
    local ease = safe(d.get_field, d, "AutoCloseEaseType") or 0
    local ok, err = pcall(d.call, d, "requestAutoClose(System.Single, via.curve.EaseType, System.Boolean, System.Boolean)",
        speed, ease, false, false)
    if not ok then ok, err = pcall(d.call, d, "requestClosed(System.Boolean)", false) end
    return ok, err
end
function check_open_retry(id, s, state, now)
    local r = ws.open_retry[id]
    if r == nil or now < r.t then return end
    ws.open_retry[id] = nil
    if is_open(state) or state == 4 then
        log(string.format("door %s opening (state %d)", id, state))
        return
    end
    -- Didn't start: snap it open.
    ws.applying[id] = now
    local angle = tonumber(safe(s.d.get_field, s.d, "MaxOpenAngle")) or 90
    local ok, err = pcall(s.d.call, s.d, "requestOpened(app.DoorPush.OpenSide, System.Single, System.Boolean)", 2, angle, false)
    log(string.format("door %s didn't start (state %d): snapped open%s", id, state, ok and "" or (" ERR " .. tostring(err))))
end

-- Our player using a door's handle (DoorPush.setInteract, user = our player): a close then is
-- a real close even though the door goes through state 6 like a door shutting by itself.
ws.door_touch = {}
do
    local m = sdk.find_type_definition("app.DoorPush"):get_method("setInteract(via.GameObject, System.Boolean, System.Boolean)")
    if m then
        pcall(sdk.hook, m, function(args)
            pcall(function()
                local om = sdk.get_managed_singleton("app.ObjectManager")
                local p = om and om:get_field("PlayerObj")
                local user = sdk.to_managed_object(args[3])
                if p and user and user:get_address() == p:get_address() then
                    ws.door_touch[sdk.to_managed_object(args[2]):get_address()] = os.clock()
                end
            end)
        end, function(r) return r end)
    end
end

local function player_near_door(s, m)
    local om = sdk.get_managed_singleton("app.ObjectManager")
    local p = om and om:get_field("PlayerObj")
    local pp = p and safe(function() return p:call("get_Transform"):call("get_Position") end)
    local dp = safe(function() return s.d:call("get_GameObject"):call("get_Transform"):call("get_Position") end)
    if pp == nil or dp == nil then return false end
    return (pp.x - dp.x) ^ 2 + (pp.z - dp.z) ^ 2 < m * m
end

-- The friend's door: our copy doesn't shut by itself (IsAutoClosable off) until the friend's
-- game closes it or we use it ourselves.
function door_take_by_peer(s)
    if not s.peer then
        s.peer = true
        s.auto_orig = safe(s.d.get_field, s.d, "IsAutoClosable")
        pcall(s.d.set_field, s.d, "IsAutoClosable", false)
    end
end
function door_release(s)
    if s.peer then
        s.peer = nil
        if s.auto_orig ~= nil then pcall(s.d.set_field, s.d, "IsAutoClosable", s.auto_orig) end
    end
end
local function friend_near_door(s, m)
    local g = coop_ghost and coop_ghost()
    local gp = g and safe(function() return g:call("get_Transform"):call("get_Position") end)
    local dp = safe(function() return s.d:call("get_GameObject"):call("get_Transform"):call("get_Position") end)
    if gp == nil or dp == nil or ghost_hidden then return false end
    return (gp.x - dp.x) ^ 2 + (gp.z - dp.z) ^ 2 < m * m
end
-- Our door (we opened it): its self-close waits while the friend stands in the doorway, so it
-- never shuts on them (pauseAutoMoving).
function door_ownership(s, state, now)
    if s.peer then
        if ws.door_touch[s.d:get_address()] and now - ws.door_touch[s.d:get_address()] < 1 then door_release(s) end
        return
    end
    local hold = s.mine and (state == 5 or state == 6) and friend_near_door(s, 1.8) or false
    if hold ~= (s.held or false) then
        s.held = hold
        pcall(s.d.call, s.d, "set_pauseAutoMoving", hold)
        log(string.format("door: self-close %s (your friend %s the doorway)", hold and "paused" or "resumed",
            hold and "is in" or "left"))
    end
end

-- Pushes: a door pushed by a body or cracked open by its handle (states 2 and 3) sends its
-- angle up to 10 times a second ("dang <id> <angle> <side> <chapter>", side 0 = opens to the
-- front, 1 = to the back, from DoorPush.IsOpenFront). The other game sets the same angle with
-- requestPush(side, angle, false) (tested live 2026-11-04: it holds the exact angle, state 3).
ws.dang_t = 0
local function stream_door_angles(now)
    if now - ws.dang_t < 0.1 then return end
    ws.dang_t = now
    for id, s in pairs(ws.doors) do
        if s.live_t and now - s.live_t < 0.3 and (s.state == 2 or s.state == 3) then
            local ours = ws.applying[id] and now - ws.applying[id] < 1
            local a = tonumber(safe(s.d.call, s.d, "get_currentAngle"))
            if a and not ours and math.abs(a - (s.ang_sent or -100)) >= 3 then
                s.ang_sent, s.mine = a, true
                local side = safe(s.d.get_field, s.d, "IsOpenFront") == true and 0 or 1
                send(string.format("dang %s %.0f %d %d", id, a, side, chapter()))
            end
        elseif s.state == 0 then
            s.ang_sent = nil
        end
    end
end
coop_world_stream_doors = stream_door_angles

local function poll_doors(now)
    -- Only doors the scene still has (v0.24): one unloaded by an area change threw inside the
    -- game, like the pushed objects did (see poll_phys).
    local sc = scene()
    local arr = sc and safe(sc.call, sc, "findComponents(System.Type)", sdk.typeof("app.DoorPush"))
    if arr == nil then return end
    local live = {}
    for _, d in ipairs(elems(arr)) do live[d:get_address()] = true end
    ws.door_sent = ws.door_sent or {}
    -- Each open or close went out twice (the door passes through a middle state): the same
    -- message for the same door within 2 s is sent once.
    local function send_once(kind, id)
        local k = kind .. id
        if ws.door_sent[k] and now - ws.door_sent[k] < 2 then return end
        ws.door_sent[k] = now
        send(string.format("%s %s %d", kind, id, chapter()))
    end
    for id, s in pairs(ws.doors) do
        local d = s.d
        if not live[d:get_address()] then
            ws.doors[id] = nil
        else
            local locked = safe(d.call, d, "get_isLocked") == true
            local state = safe(d.call, d, "get_doorState") or 0
            local open = is_open(state)
            local ours = ws.applying[id] and now - ws.applying[id] < 3
            if s.locked and not locked and not ours then send_once("unlock", id) end
            -- A door that swings shut by itself goes through state 6 (auto-closing): that's the
            -- game, not the player, and sending it slammed the door on the other player as
            -- they walked through (2026-11-03). Only a close straight from open is sent.
            local touched = ws.door_touch[d:get_address()] and now - ws.door_touch[d:get_address()] < 3
            s.live_t = now
            -- A push or a cracked-open handle (states 2 and 3) goes as its angle ("dang", below);
            -- "open" is for a door swinging or swung fully open (4 and 5).
            local full = state == 4 or state == 5
            if full and not s.full and not ours then send_once("open", id) s.mine = true end
            -- The door's self-close belongs to the game of whoever opened it (v0.28): that game
            -- sends it, the other game's copy waits for it (its own self-close is off).
            if s.open and not open and not ours and (touched or s.mine or (state ~= 6 and s.state ~= 6)) then
                send_once("close", id)
            end
            if not open and state ~= 2 then
                s.mine = nil
                if s.peer then door_release(s) end
            end
            pcall(door_ownership, s, state, now)
            s.locked, s.open, s.state, s.full = locked, open, state, full
            pcall(check_open_retry, id, s, state, now)
        end
    end
end

local function apply_door(kind, id, ch)
    if ch ~= chapter() then return end
    local s = ws.doors[id]
    if s == nil then
        if kind == "unlock" then
            ws.pending_unlock[id] = ch   -- applied when that area loads here
            log("remembered unlock: " .. id)
        else
            log("door not loaded here: " .. kind .. " " .. id)
        end
        return
    end
    ws.applying[id] = os.clock()
    if kind == "unlock" then
        if s.d:call("get_isLocked") then
            pcall(s.d.call, s.d, "unlockDoor")
            note("your friend unlocked a door")
        end
    elseif kind == "open" then
        door_take_by_peer(s)
        if s.d:call("get_isLocked") then
            -- Opened in their game, so it isn't locked there (v0.32).
            pcall(s.d.call, s.d, "unlockDoor")
            log("door " .. id .. ": locked here but your friend opened it: unlocked")
        end
        local before = s.d:call("get_doorState")
        if not is_open(before) and not s.d:call("get_isLocked") then
            local ok, err = door_open(s.d)
            log(string.format("opening door %s (state %s)%s", id, tostring(before), ok and "" or (" ERR " .. tostring(err))))
            ws.open_retry[id] = { t = os.clock() + 0.7 }
        else
            log(string.format("open door %s: already state %s, locked %s", id, tostring(before),
                tostring(s.d:call("get_isLocked"))))
        end
    elseif kind == "close" then
        door_release(s)
        if player_near_door(s, 1.5) then
            log("close door " .. id .. ": not closed, you're in the doorway")
        elseif is_open(s.d:call("get_doorState")) then
            local ok, err = door_close(s.d)
            log("closing door " .. id .. (ok and "" or (" ERR " .. tostring(err))))
        end
    end
    ws.applied = ws.applied + 1
end

-- Items ------------------------------------------------------------------------------
-- "Share supplies" (off by default since v0.22): on, ammo and healing are one copy for both
-- players (whoever picks it up takes it from both worlds, the harder way to play); off, each
-- player gets their own. Each game applies its own player's choice, so set it the same.
local function supplies_shared() return settings ~= nil and settings.share_supplies == true end

-- Items dropped by smashed boxes: each player gets their own (the friend's game rolls its
-- own from the box's table), so their pickups are never shared. Both games' copies may
-- carry the same SaveGUID.
function box_item_ids()
    ws.box_items = ws.box_items or {}
    for _, s in pairs(ws.props or {}) do
        if s.kind == "box" then
            local di = safe(s.c.get_field, s.c, "DropItem")
            local it = di and safe(di.call, di, "getComponent(System.Type)", sdk.typeof("app.Item"))
            local id = it and id_of(it)
            if id then ws.box_items[id] = true end
        end
    end
end

local function refresh_items()
    local sc = scene()
    local arr = sc and safe(sc.call, sc, "findComponents(System.Type)", sdk.typeof("app.Item"))
    local seen = {}
    for _, it in ipairs(elems(arr)) do
        local id = id_of(it)
        if id then
            seen[id] = true
            if ws.items[id] == nil then
                local go = it:call("get_GameObject")
                ws.items[id] = { it = it, go = go, state = safe(it.call, it, "getItemState"),
                    pos = safe(function() return go:call("get_Transform"):call("get_Position") end) }
            end
            ws.items[id].it = it
        end
    end
    for id in pairs(ws.items) do if not seen[id] then ws.items[id] = nil end end
    box_item_ids()
    -- Pickups the friend made before this area was loaded here.
    for id, ch in pairs(supplies_shared() and ws.pending_took or {}) do
        local e = ws.items[id]
        if e and ch == chapter() and safe(e.go.call, e.go, "get_Draw") then
            ws.pending_took[id] = nil
            ws.applying[id] = os.clock()
            pcall(e.it.call, e.it, "disableFromScene")
            note("your friend already took " .. tostring(e.it:get_field("ItemDataID")) .. " here")
        end
    end
end

local function apply_took(id, ch, name)
    if ch ~= chapter() then return end
    if not supplies_shared() then log("friend took " .. tostring(name) .. ": yours stays (Share supplies is off)") return end
    if ws.box_items and ws.box_items[id] then log("box item stays here: " .. name) return end
    local e = ws.items[id]
    if e and safe(e.go.call, e.go, "get_Draw") then
        ws.applying[id] = os.clock()
        pcall(e.it.call, e.it, "disableFromScene")
        ws.applied = ws.applied + 1
        note("your friend took " .. ((coop_item_name and safe(coop_item_name, name)) or name))   -- v0.42: the game's name for it
    else
        ws.pending_took[id] = ch   -- not loaded (or not shown) yet: when it is
        log("remembered pickup: " .. name .. " " .. id)
    end
end

-- Our pickups. A pickup doesn't go through Item.changeStateInventoryIn (a hook there never
-- fired): the game hides the item lying in the world (getItemState 0 -> 6, as
-- disableFromScene does) and makes a separate inventory Item. So watch world items for
-- 0 -> 6, except the ones we hid on the friend's word.
-- Leaving an area hides its items the same way (2026-11-03: 8 "pickups" at once on an area
-- change, all without an ItemDataID, and the same items again and again): only an item with
-- a name, within reach of us, counts, and each item is reported once.
local ITEM_IN_SCENE, ITEM_GONE = 0, 6
local PICKUP_REACH = 4.0
ws.reported = ws.reported or {}
local function within_reach(e)
    if e.pos == nil then return false end
    local player = sdk.get_managed_singleton("app.ObjectManager"):get_field("PlayerObj")
    local pp = player and safe(function() return player:call("get_Transform"):call("get_Position") end)
    if pp == nil then return false end
    return (pp.x - e.pos.x) ^ 2 + (pp.y - e.pos.y) ^ 2 + (pp.z - e.pos.z) ^ 2 < PICKUP_REACH * PICKUP_REACH
end
local function poll_items(now)
    for id, e in pairs(ws.items) do
        local st = safe(e.it.call, e.it, "getItemState")
        if e.state == ITEM_IN_SCENE and st == ITEM_GONE then
            local ours = ws.applying[id] and now - ws.applying[id] < 3
            if ws.box_items and ws.box_items[id] then
                ours = true   -- a box's item: the friend has their own
            end
            if not ours and (ws.reported[id] or e.it:get_field("ItemDataID") == nil or not within_reach(e)) then
                ws.not_pickup = ws.not_pickup or {}
                if not ws.reported[id] and not ws.not_pickup[id] then
                    ws.not_pickup[id] = true
                    log(string.format("not a pickup (no name or out of reach): %s %s", id, tostring(e.it:get_field("ItemDataID"))))
                end
                ours = true
            end
            if not ours then ws.reported[id] = true end
            if not ours and is_supply(e.it) then
                send(string.format("took %s %d %s", id, chapter(), tostring(e.it:get_field("ItemDataID"))))
            elseif not ours then
                -- Keys, weapons, files: they stay for the friend, who is told to pick them up too
                -- (their pickup can start a scripted moment in their game, like Jack's wall).
                send(string.format("got %s %d %s", id, chapter(), tostring(e.it:get_field("ItemDataID"))))
            end
        end
        e.state = st
    end
end

-- Boxes and drawers -----------------------------------------------------------------
-- Both carry SaveGUID (boxes their own, drawers from InteractObjectBase). A smashed box
-- is smashed for both (each game drops its own item; the supply rule then shares the
-- pickup). Drawers follow open/shut. Untested on a real session yet: every apply logs
-- the state before and after.
local PROP_TYPES = {
    { kind = "box", type = "app.ItemDropDestruct", state = function(c) return c:get_field("IsBreaked") == true end },
    { kind = "drawer", type = "app.InteractDrawer", state = function(c) return c:get_field("NowDrawerOpen") == true end },
    -- One-off interactions (open the fridge, the van, stir the pot...): app.InteractSendFsm and
    -- app.InteractLongPressSendFSM count successes in InteractObjectBase.InteractSuccessCount;
    -- the other game runs successInteract(), the game's own "done" step. Experimental: it can
    -- only be judged in play, so "Share interactions" can switch it off.
    { kind = "intr", type = "app.InteractSendFsm", optional = true,
        state = function(c) return (tonumber(c:get_field("InteractSuccessCount")) or 0) > 0 end },
    { kind = "intr", type = "app.InteractLongPressSendFSM", optional = true,
        state = function(c) return (tonumber(c:get_field("InteractSuccessCount")) or 0) > 0 end },
    { kind = "switch", type = "app.InteractSwitch", optional = true,
        state = function(c) return c:get_field("NowSwitchOn") == true end },
}
local function interactions_shared() return not (settings and settings.share_interactions == false) end
-- Never share these: saving (tape recorders), VHS tapes (followed separately), item boxes,
-- cutscene triggers. Matched on the names of the interactable's GameObject, its parent and
-- grandparent: the interactable itself is mostly just "InteractSendFsm" and the telling name
-- is on its parent (sm0113_Phone01A_AnswerPhoneCodex), so until v0.20 this list never matched.
-- Weapons and items stay per player (v0.23): the shotgun on the hall statue is a trap you
-- disarm by putting the broken shotgun back. Sharing that statue let the friend take the
-- shotgun for free (2026-11-03), so anything that hands out a weapon or an item is skipped.
-- Nor anything that moves the player or opens a view: run on the other game, "get into the
-- car" or "start the shadow puzzle" would do it to the friend wherever they stand (the car's
-- get-in and get-out went across in the 2026-11-03 session).
local INTR_SKIP = { "save", "tape", "video", "vhs", "record", "itembox", "event", "cs_",
    "shotgun", "statue", "pendulum", "item", "wp0", "wp1", "wp2", "wp4",
    "getinto", "getout", "ignition", "ethancar", "puzzle", "ladder", "hide", "crouch", "climb" }
local function intr_names(c)
    local out = {}
    local go = safe(c.call, c, "get_GameObject")
    for _ = 1, 3 do
        if go == nil then break end
        out[#out + 1] = tostring(safe(go.call, go, "get_Name") or ""):lower()
        local tr = safe(go.call, go, "get_Transform")
        local par = tr and safe(tr.call, tr, "get_Parent")
        go = par and safe(par.call, par, "get_GameObject")
    end
    return table.concat(out, "/")
end
-- Phones are shared on purpose (v0.20): when one player answers a call, the other's phone is
-- answered too, so both don't have to take every call to move on.
local function is_phone(c) return intr_names(c):find("phone", 1, true) ~= nil end
local function intr_allowed(c)
    local names = intr_names(c)
    if names:find("phone", 1, true) then return true end
    for _, w in ipairs(INTR_SKIP) do if names:find(w, 1, true) then return false end end
    return true
end

-- Finding what isn't shared yet (v0.23). The garage-door button and the shadow puzzle's
-- unlock never reached the other game, and nothing in the logs said what they are. Every
-- finished interaction the game reports (InteractObjectBase.successInteract) that isn't one of
-- the kinds above is now written to this log with its type and names, so the next bug report
-- shows what to add. Logging only: nothing is sent.
-- What the latched doors and lockpicked drawers can do (v0.25): their method names go to the
-- log once, so the next build can drive them. Names only: nothing is called.
do
    for _, tn in ipairs({ "app.DoorPush", "app.InteractDoor", "app.InteractDetailSearch", "app.InteractSendFsm" }) do
        local td = sdk.find_type_definition(tn)
        local names = {}
        for _, m in ipairs(td and td:get_methods() or {}) do
            names[#names + 1] = m:get_name() .. "/" .. m:get_num_params()
        end
        local fields = {}
        for _, f in ipairs(td and td:get_fields() or {}) do fields[#fields + 1] = f:get_name() end
        log(string.format("type %s: %d methods: %s | fields: %s", tn, #names, table.concat(names, " "), table.concat(fields, " ")))
    end
end
local TRACKED_TYPES = {}
for _, pt in ipairs(PROP_TYPES) do TRACKED_TYPES[pt.type] = true end
TRACKED_TYPES["app.InteractDoor"] = true   -- shared through its door (app.DoorPush) since v0.27
do
    local seen = {}
    local td = sdk.find_type_definition("app.InteractObjectBase")
    local hooked = 0
    for _, m in ipairs(td and td:get_methods() or {}) do
        local mname = m:get_name()
        if mname == "successInteract" or mname == "startInteract" then
            local ok = pcall(sdk.hook, m, function(args)
                pcall(function()
                    local c = sdk.to_managed_object(args[2])
                    if c == nil then return end
                    local tn = c:get_type_definition():get_full_name()
                    if TRACKED_TYPES[tn] and mname == "successInteract" then return end
                    local key = mname .. ":" .. tn .. ":" .. tostring(id_of(c) or intr_names(c))
                    if seen[key] then return end
                    seen[key] = true
                    log(string.format("not shared yet: %s %s (%s) id %s", mname, tn, intr_names(c), tostring(id_of(c))))
                end)
            end, function(r) return r end)
            if ok then hooked = hooked + 1 end
        end
    end
    log("interaction finder: " .. hooked .. " hooks")
end

-- Lockpicks (v0.26, watched live 2026-11-04 on the study desk sm1415_Table09A). Picking runs
-- setInteract + successInteract on the lock's InteractSendFsm (what the friend's copy did), but
-- the desk only changes when the lockpick ends with InteractClose: the locked model
-- (*_KeyOpenBefore) is hidden, the opened lock model (sm2234_KeyPickLock02A, a direct child of
-- the desk) shown, the drawer's InteractDrawer object switched on and the lock's interaction
-- off. The friend's desk stayed locked. Now: InteractClose after the success; if the locked
-- model is still drawn 0.6 s later, InteractClose once more; after that the four changes by
-- hand. Each step is logged.
function is_lockpick(c)
    local n = intr_names(c)
    return n:find("keypick", 1, true) ~= nil or n:find("keylock", 1, true) ~= nil
end
ws.locks = {}
-- The lock's container: the nearest ancestor with a direct child named "InteractDrawer" (the
-- desk sm1415_Table09A_Drawer, the box sm1929_KeyPickBox03A_KeyLock). That child is switched
-- off (DrawSelf false) while locked and on once open, on both kinds: it's what "opened" means.
-- The desk also swaps its locked model (*_KeyOpenBefore) for the opened lock (a direct child
-- named sm2234_KeyPickLock*); the box has no such pair (tested live 2026-11-04: a remote pick
-- of the box changed nothing but the lock's count, and the first check mistook that for open).
local function child_named(go, pred)
    local tr = safe(go.call, go, "get_Transform")
    local child = tr and safe(tr.call, tr, "get_Child")
    local out = {}
    while child do
        local cg = safe(child.call, child, "get_GameObject")
        local name = cg and tostring(safe(cg.call, cg, "get_Name") or "") or ""
        if cg and pred(name:lower()) then out[#out + 1] = cg end
        child = safe(child.call, child, "get_Next")
    end
    return out
end
local function lock_parts(c)
    local go = safe(c.call, c, "get_GameObject")
    for _ = 1, 6 do
        if go == nil then return nil end
        local drawer = child_named(go, function(n) return n == "interactdrawer" end)[1]
        if drawer then return go, drawer end
        local tr = safe(go.call, go, "get_Transform")
        local par = tr and safe(tr.call, tr, "get_Parent")
        go = par and safe(par.call, par, "get_GameObject")
    end
    return nil
end
local function lock_is_open(c)
    local root, drawer = lock_parts(c)
    if drawer == nil then return nil end
    return safe(drawer.call, drawer, "get_DrawSelf") == true
end
-- The lock's app.ItemSelectReaction (on the lock object, e.g. sm2234_KeyPickLock02A_KeyLockSet)
-- maps an item to a state of its via.fsm.Fsm (FsmObj): CylinderKey (the lockpick) ->
-- "SelectSuccess". Setting that state runs the game's own sequence (tested live 2026-11-04 on
-- the study desk: SelectSuccess -> Gimmick_Open_PauseStart -> Open_End in about 3 s, lockpick
-- sound, model swap, drawer usable, prompt gone, the player untouched, no menu).
local function lock_reaction(c)
    local go = safe(c.call, c, "get_GameObject")
    for _ = 1, 3 do
        if go == nil then return nil end
        local r = safe(go.call, go, "getComponent(System.Type)", sdk.typeof("app.ItemSelectReaction"))
        if r then return r end
        local tr = safe(go.call, go, "get_Transform")
        local par = tr and safe(tr.call, tr, "get_Parent")
        go = par and safe(par.call, par, "get_GameObject")
    end
    return nil
end
local function success_state(r)
    local rs = safe(r.get_field, r, "ReactionSettings")
    local n = rs and tonumber(safe(rs.call, rs, "get_Count")) or 0
    for i = 0, n - 1 do
        local e = safe(rs.call, rs, "get_Item", i)
        if e and tonumber(safe(e.get_field, e, "Result")) == 0 then return tostring(safe(e.get_field, e, "StateName")) end
    end
    return "SelectSuccess"
end
function start_lock_open(c, id)
    if lock_is_open(c) == true then log("lockpick " .. id .. ": already open here") return end
    local r = lock_reaction(c)
    local fo = r and safe(r.get_field, r, "FsmObj")
    local fsm = fo and safe(fo.call, fo, "getComponent(System.Type)", sdk.typeof("via.fsm.Fsm"))
    if fsm then
        local st = success_state(r)
        local ok, err = pcall(fsm.call, fsm, "setCurrentState(System.String)", st)
        log(string.format("lockpick %s: lock state -> %s%s (%s)", id, st, ok and "" or (" ERR " .. tostring(err)), intr_names(c)))
        -- Checked every 2 s for a minute. A lock in an area the game isn't running waits in
        -- Gimmick_Open_PauseStart until the area runs again (the box 27 m away, 2026-11-04), so
        -- it's never opened by hand while its own sequence is under way.
        ws.locks[id] = { c = c, t = os.clock() + 4, step = 3, fsm = fsm, until_t = os.clock() + 60 }
    else
        log("lockpick " .. id .. ": no lock state machine, opening by hand (" .. intr_names(c) .. ")")
        ws.locks[id] = { c = c, t = os.clock(), step = 2 }
    end
end
local function lock_hand_open(c, id)
    local root, drawer = lock_parts(c)
    if root == nil then log("lockpick " .. id .. ": no drawer found next to the lock") return end
    local done = {}
    pcall(drawer.call, drawer, "set_DrawSelf", true)
    done[#done + 1] = "drawer on"
    for _, g in ipairs(child_named(root, function(n) return n:find("keyopenbefore", 1, true) ~= nil end)) do
        pcall(g.call, g, "set_DrawSelf", false)
        done[#done + 1] = "hid " .. tostring(safe(g.call, g, "get_Name"))
        -- Its opened lock: a direct child named like the lock inside the locked model.
        for _, o in ipairs(child_named(root, function(n) return n:find("^sm%d+_keypicklock") ~= nil end)) do
            pcall(o.call, o, "set_DrawSelf", true)
            done[#done + 1] = "showed " .. tostring(safe(o.call, o, "get_Name"))
        end
    end
    local lgo = safe(c.call, c, "get_GameObject")
    if lgo then pcall(lgo.call, lgo, "set_DrawSelf", false) done[#done + 1] = "lock off" end
    log("lockpick " .. id .. ": opened by hand (" .. table.concat(done, ", ") .. ")")
    note("your friend picked a lock: it's open for you too")
end
-- Chains (v0.38): the interaction's names contain "chain" (cutchain, chainlock).
function is_chain(c) return intr_names(c):find("chain", 1, true) ~= nil end
ws.chains = ws.chains or {}
local function chain_parts(c)
    local go = safe(c.call, c, "get_GameObject")
    local tr = go and safe(go.call, go, "get_Transform")
    local par = tr and safe(tr.call, tr, "get_Parent")
    local root = par and safe(par.call, par, "get_GameObject")
    -- The chain model is the interaction's parent when that's named for a chain; otherwise the
    -- interaction's own object is all that's touched.
    if root and not tostring(safe(root.call, root, "get_Name") or ""):lower():find("chain", 1, true) then root = nil end
    return go, root
end
-- Cut = the interaction or the chain model no longer drawn (or gone).
function chain_cut(c)
    local go, root = chain_parts(c)
    if go == nil then return true end
    if safe(go.call, go, "get_DrawSelf") == false then return true end
    if root and safe(root.call, root, "get_DrawSelf") == false then return true end
    return false
end
local function chain_hand_cut(c, id)
    local go, root = chain_parts(c)
    local done = {}
    for _, g in ipairs({ root, go }) do
        if g then
            pcall(g.call, g, "set_DrawSelf", false)
            for _, tn in ipairs({ "via.physics.Colliders", "via.dynamics.RigidBodySet" }) do
                local comp = safe(g.call, g, "getComponent(System.Type)", sdk.typeof(tn))
                if comp then safe(comp.call, comp, "set_Enabled", false) end
            end
            done[#done + 1] = "hid " .. tostring(safe(g.call, g, "get_Name"))
        end
    end
    -- What's next to it, for the next build (names only).
    if root then
        local kids = {}
        for _, k in ipairs(child_named(root, function() return true end)) do kids[#kids + 1] = tostring(safe(k.call, k, "get_Name")) end
        done[#done + 1] = "children: " .. table.concat(kids, ",")
    end
    log("chain " .. id .. ": cut by hand (" .. table.concat(done, ", ") .. ")")
    note("your friend cut a chain: it's cut for you too")
end
function start_chain_cut(c, id)
    if chain_cut(c) then log("chain " .. id .. ": already cut here") return end
    local r = lock_reaction(c)
    local fo = r and safe(r.get_field, r, "FsmObj")
    local fsm = fo and safe(fo.call, fo, "getComponent(System.Type)", sdk.typeof("via.fsm.Fsm"))
    if fsm then
        -- Every item -> state pair the chain has, logged once.
        local rs = safe(r.get_field, r, "ReactionSettings")
        local n = rs and tonumber(safe(rs.call, rs, "get_Count")) or 0
        local pairs_ = {}
        for i = 0, n - 1 do
            local e = safe(rs.call, rs, "get_Item", i)
            if e then pairs_[#pairs_ + 1] = tostring(safe(e.get_field, e, "StateName")) .. "=" .. tostring(safe(e.get_field, e, "Result")) end
        end
        local st = success_state(r)
        local ok, err = pcall(fsm.call, fsm, "setCurrentState(System.String)", st)
        log(string.format("chain %s: state -> %s%s (states %s) (%s)", id, st, ok and "" or (" ERR " .. tostring(err)),
            table.concat(pairs_, " "), intr_names(c)))
    else
        log("chain " .. id .. ": no state machine, cutting by hand (" .. intr_names(c) .. ")")
    end
    ws.chains[id] = { c = c, t = os.clock() + (fsm and 10 or 0) }
end
local function poll_chains(now)
    for id, ch in pairs(ws.chains) do
        if chain_cut(ch.c) then
            ws.chains[id] = nil
            log("chain " .. id .. ": cut (the game's own change)")
            note("your friend cut a chain: it's cut for you too")
        elseif now >= ch.t then
            ws.chains[id] = nil
            pcall(chain_hand_cut, ch.c, id)
        end
    end
end

local function poll_locks(now)
    for id, l in pairs(ws.locks) do
        if now >= l.t then
            local open = lock_is_open(l.c)
            if open == true then
                ws.locks[id] = nil
                log("lockpick " .. id .. ": open (the game's own change, step " .. l.step .. ")")
                note("your friend picked a lock: it's open for you too")
            elseif l.step == 3 then
                local st = tostring(safe(l.fsm.call, l.fsm, "getCurrentState", 0))
                if now > l.until_t then
                    ws.locks[id] = nil
                    log("lockpick " .. id .. ": still shut after a minute (lock state " .. st .. ")")
                else
                    if st ~= l.last_st then l.last_st = st log("lockpick " .. id .. ": lock state " .. st) end
                    l.t = now + 2
                end
            elseif l.step == 1 then
                pcall(l.c.call, l.c, "InteractClose")
                l.step, l.t = 2, now + 0.6
            else
                ws.locks[id] = nil
                pcall(lock_hand_open, l.c, id)
            end
        end
    end
end

-- Breakables with no item (v0.32). Type names vary, so each is looked up; state = IsBreak
-- or IsBreaked. Key: "<name>@x,y,z" (first-seen position, 0.1 m). Boxes with an item stay
-- on the "box" kind above (their GameObject also has app.ItemDropDestruct).
local DESTRUCT_TYPES = {}
for _, tn in ipairs({ "app.RigidBodyDestruct", "app.RigidBodyDestructBase", "app.DestructObject",
    "app.BreakableObject" }) do
    if sdk.find_type_definition(tn) then DESTRUCT_TYPES[#DESTRUCT_TYPES + 1] = tn end
end
log("breakables watched: " .. (#DESTRUCT_TYPES > 0 and table.concat(DESTRUCT_TYPES, ", ") or "none found"))
ws.dbox = ws.dbox or {}          -- key -> { c, go, key, name, pos, on }
ws.pending_dbox = ws.pending_dbox or {}
local function dbox_broken(c)
    local v = safe(c.get_field, c, "IsBreak")
    if v == nil then v = safe(c.get_field, c, "IsBreaked") end
    return v == true
end
local function refresh_dbox(sc)
    local seen = {}
    for _, tn in ipairs(DESTRUCT_TYPES) do
        local arr = safe(sc.call, sc, "findComponents(System.Type)", sdk.typeof(tn))
        for _, c in ipairs(elems(arr)) do
            local go = safe(c.call, c, "get_GameObject")
            local has_item = go and safe(go.call, go, "getComponent(System.Type)", sdk.typeof("app.ItemDropDestruct"))
            if go and not has_item then
                ws.dbox_addr = ws.dbox_addr or {}
                local addr = safe(c.get_address, c)
                local known = addr and ws.dbox_addr[addr]
                if known and ws.dbox[known.key] == known and known.c == c then seen[known.key] = true
                else
                    local p = safe(function() return go:call("get_Transform"):call("get_Position") end)
                    local name = tostring(safe(go.call, go, "get_Name") or "?")
                    if p then
                        local key = string.format("%s@%.1f,%.1f,%.1f", name, p.x, p.y, p.z)
                        ws.dbox[key] = { c = c, go = go, key = key, name = name, pos = p, on = dbox_broken(c) }
                        if addr then ws.dbox_addr[addr] = ws.dbox[key] end
                        seen[key] = true
                        local pend = ws.pending_dbox[key]
                        if pend and pend.ch == chapter() then ws.pending_dbox[key] = nil ws.apply_dbox_later = key end
                    end
                end
            end
        end
    end
    for key in pairs(ws.dbox) do if not seen[key] then ws.dbox[key] = nil end end
    for addr, d in pairs(ws.dbox_addr or {}) do if ws.dbox[d.key] ~= d then ws.dbox_addr[addr] = nil end end
end
local function hide_dbox(d)
    ws.applying["dbox:" .. d.key] = os.clock()
    pcall(d.c.call, d.c, "setAlreadyBreak")
    pcall(d.c.set_field, d.c, "IsBreak", true)
    pcall(d.c.set_field, d.c, "IsBreaked", true)
    safe(d.go.call, d.go, "set_DrawSelf", false)
    for _, tn in ipairs({ "via.physics.Colliders", "via.dynamics.RigidBodySet" }) do
        local comp = safe(d.go.call, d.go, "getComponent(System.Type)", sdk.typeof(tn))
        if comp then safe(comp.call, comp, "set_Enabled", false) end
    end
    d.on = true
end
function coop_apply_dbox(key, ch)
    if ch ~= chapter() then return end
    local d = ws.dbox[key]
    if d == nil then
        -- Same name within 1.5 m (positions can differ a little between games).
        local name, x, y, z = key:match("^(.*)@(%-?[%d.]+),(%-?[%d.]+),(%-?[%d.]+)$")
        x, y, z = tonumber(x), tonumber(y), tonumber(z)
        local best, bd
        for _, o in pairs(ws.dbox) do
            if name and o.name == name and not o.on then
                local dd = (o.pos.x - x) ^ 2 + (o.pos.y - y) ^ 2 + (o.pos.z - z) ^ 2
                if dd < 2.25 and (bd == nil or dd < bd) then best, bd = o, dd end
            end
        end
        d = best
    end
    if d == nil then
        ws.pending_dbox[key] = { ch = ch }
        log("remembered breakable: " .. key)
        return
    end
    if d.on then return end
    hide_dbox(d)
    log("breakable " .. key .. " smashed (from the friend)")
    note("your friend smashed something here")
end
local function poll_dbox(now)
    for key, d in pairs(ws.dbox) do
        local on = safe(dbox_broken, d.c) == true
        local ours = ws.applying["dbox:" .. key] and now - ws.applying["dbox:" .. key] < 3
        if on and not d.on and not ours then send(string.format("dbreak %s %d", key, chapter())) end
        d.on = on or d.on
    end
    if ws.apply_dbox_later then
        local k = ws.apply_dbox_later
        ws.apply_dbox_later = nil
        pcall(coop_apply_dbox, k, chapter())
    end
end

local function refresh_props()
    local sc = scene()
    if sc == nil then return end
    pcall(refresh_dbox, sc)
    local seen = {}
    for _, pt in ipairs(PROP_TYPES) do
        local arr = safe(sc.call, sc, "findComponents(System.Type)", sdk.typeof(pt.type))
        for _, c in ipairs(elems(arr)) do
            local id = id_of(c)
            if id then
                local key = pt.kind .. ":" .. id
                seen[key] = true
                if ws.props[key] == nil or ws.props[key].c ~= c then
                    ws.props[key] = { c = c, kind = pt.kind, id = id, pt = pt, on = safe(pt.state, c) == true }
                end
            end
        end
    end
    for key in pairs(ws.props) do if not seen[key] then ws.props[key] = nil end end
end

local function poll_props(now)
    pcall(poll_dbox, now)
    for key, s in pairs(ws.props) do
        local on = safe(s.pt.state, s.c) == true
        local ours = ws.applying[key] and now - ws.applying[key] < 3
        if on ~= s.on and not ours then
            if s.kind == "box" and on then send(string.format("break %s %d", s.id, chapter()))
            elseif s.kind == "drawer" then send(string.format("drawer %s %d %d", s.id, on and 1 or 0, chapter()))
            elseif s.kind == "intr" and on and interactions_shared() and intr_allowed(s.c) then
                local tag = is_phone(s.c) and " phone" or ((is_lockpick(s.c) or is_chain(s.c)) and " lock" or "")
                send(string.format("intr %s %d%s", s.id, chapter(), tag))
            elseif s.kind == "switch" and interactions_shared() then
                send(string.format("switch %s %d %d", s.id, on and 1 or 0, chapter()))
            end
        end
        s.on = on
    end
end

local function apply_prop(kind, id, want, ch, phone, lasting)
    if ch ~= chapter() then return end
    local key = kind .. ":" .. id
    local s = ws.props[key]
    if s == nil then
        if kind ~= "intr" or phone or lasting then
            -- Boxes, drawers and switches keep their state: applied when that area loads here.
            -- One-off interactions aren't replayed later (they can start scripted moments).
            ws.pending_props[key] = { kind = kind, id = id, want = want, ch = ch, phone = phone, lasting = lasting }
            log("remembered " .. kind .. ": " .. id)
        else
            log(kind .. " not loaded here: " .. id)
        end
        return
    end
    local before = safe(s.pt.state, s.c) == true
    -- A lock counts as done when its drawer is open, not when its success count is above 0
    -- (an earlier try can leave the count up and the lock shut).
    if before == want and not (kind == "intr" and is_lockpick(s.c) and lock_is_open(s.c) == false)
        and not (kind == "intr" and not is_lockpick(s.c) and is_chain(s.c) and not chain_cut(s.c)) then return end
    ws.applying[key] = os.clock()
    local ok, err
    if kind == "box" then
        -- RigidBodyDestruct.setBreak(dir, pos, normal, attacker, type) always threw from Lua
        -- (and crashed the game once with the player as attacker); setAlreadyBreak takes no
        -- arguments, the state a box smashed in the save loads in. It (and dispBreakAfter,
        -- breakObjectWithoutSetBreak) leaves the box drawn, so the box is also hidden and
        -- its collision and physics switched off: it's simply gone (no pieces). Both players
        -- get the contents: setItem() (the box's own drop, rolled from its table here) makes
        -- the item as a child of the box at the world origin; it's detached and put where
        -- the box stood. Box items are never shared pickups (see box_item_ids).
        if s.c:get_field("DropItem") == nil and s.c:get_field("IsDropItem") ~= true then
            local iok, ierr = pcall(s.c.call, s.c, "setItem")
            if not iok then log("box item ERR " .. tostring(ierr)) end
        end
        local rb = safe(s.c.get_field, s.c, "RigidBodyCompo")
        if rb then
            ok, err = pcall(rb.call, rb, "setAlreadyBreak")
            if ok then pcall(s.c.set_field, s.c, "IsBreaked", true) end
        else
            ok, err = false, "no RigidBodyCompo"
        end
        local go = s.c:call("get_GameObject")
        safe(go.call, go, "set_DrawSelf", false)
        for _, tn in ipairs({ "via.physics.Colliders", "via.dynamics.RigidBodySet" }) do
            local comp = safe(go.call, go, "getComponent(System.Type)", sdk.typeof(tn))
            if comp then safe(comp.call, comp, "set_Enabled", false) end
        end
        local di = s.c:get_field("DropItem")
        local bp = safe(function() return go:call("get_Transform"):call("get_Position") end)
        if di and bp then
            local itr = di:call("get_Transform")
            safe(itr.call, itr, "set_Parent", nil)
            safe(itr.call, itr, "set_Position", Vector3f.new(bp.x, bp.y + 0.1, bp.z))
            safe(di.call, di, "set_DrawSelf", true)
            note("your friend smashed a box (its item is there for you too)")
        else
            note("your friend smashed a box")
        end
    elseif kind == "intr" then
        if not intr_allowed(s.c) then log("intr " .. id .. ": not shared here (save, tape, item box...): " .. intr_names(s.c)) return end
        if is_lockpick(s.c) then
            -- Not successInteract: on a lock it opened the item menu on the receiving player
            -- (2026-11-04). The lock's own success state does the whole job instead.
            ws.applying[key] = os.clock() + 5   -- its sequence runs about 3 s
            ok, err = pcall(start_lock_open, s.c, id)
        elseif is_chain(s.c) then
            -- Not successInteract either: it counted the chain as used and left it (2026-11-08).
            ws.applying[key] = os.clock() + 12
            ok, err = pcall(start_chain_cut, s.c, id)
        else
            ok, err = pcall(s.c.call, s.c, "successInteract")
        end
        if phone or is_phone(s.c) then
            note("your friend answered the phone: the call plays for you too")
        elseif is_chain(s.c) or is_lockpick(s.c) then
            -- Their own note comes when it's done.
        else
            note("your friend used something here (" .. intr_names(s.c) .. ")")
        end
    elseif kind == "switch" then
        ok, err = pcall(s.c.call, s.c, "SetSwitch(System.Boolean)", want)
        note(want and "your friend switched something on" or "your friend switched something off")
    else
        ok, err = pcall(s.c.call, s.c, "SetSwitch(System.Boolean)", want)
        note(want and "your friend opened a drawer" or "your friend shut a drawer")
    end
    log(string.format("%s %s: %s -> %s%s", kind, id, tostring(before), tostring(safe(s.pt.state, s.c)),
        ok and "" or (" ERR " .. tostring(err))))
    ws.applied = ws.applied + 1
end

-- Loose physics props ----------------------------------------------------------------
-- Chairs, bottles and the like (app.Havok.RigidBodyDynamics) have no SaveGUID; both games
-- load them at the same spot, so the key is the GameObject name plus where it was first
-- seen. Props within 12 m that moved are sent up to 4 times a second; the other game
-- re-places its copy (physics off, move, physics on). Untested (first build, 2026-11-03):
-- "Share pushed objects" switches it off, and the first moves are logged in detail.
ws.phys = {}            -- key -> { c, go, last = {x,y,z}, sent_t }
ws.phys_t, ws.phys_logged = -100, 0
local PHYS_NEAR, PHYS_MOVE = 12, 0.15
local function phys_shared() return not (settings and settings.share_physics == false) end

local function refresh_phys()
    local sc = scene()
    local arr = sc and safe(sc.call, sc, "findComponents(System.Type)", sdk.typeof("app.Havok.RigidBodyDynamics"))
    local seen = {}
    for _, c in ipairs(elems(arr)) do
        local go = safe(c.call, c, "get_GameObject")
        ws.phys_by_addr = ws.phys_by_addr or {}
        local known = ws.phys_by_addr[c:get_address()]
        if known and ws.phys[known] then seen[known] = true
        elseif go then
            local p = safe(function() return go:call("get_Transform"):call("get_Position") end)
            if p then
                local key = string.format("%s@%.1f,%.1f,%.1f", tostring(go:call("get_Name")), p.x, p.y, p.z)
                if ws.phys[key] == nil then
                    local lname = tostring(go:call("get_Name")):lower()
                    ws.phys[key] = { key = key, c = c, go = go, last = { x = p.x, y = p.y, z = p.z }, sent_t = -100,
                        weaponish = lname:find("knife", 1, true) ~= nil or lname:find("^wp%d") ~= nil
                            or lname:find("weapon", 1, true) ~= nil
                            -- Scripted props (v0.38): moved by the scenes they're in.
                            or lname:find("_action", 1, true) ~= nil or lname:find("ethanchair", 1, true) ~= nil }
                end
                ws.phys_by_addr[c:get_address()] = key
                seen[key] = true
            end
        end
    end
    for key in pairs(ws.phys) do if not seen[key] then ws.phys[key] = nil end end
end

local function poll_phys(now)
    if not phys_shared() then return end
    local om = sdk.get_managed_singleton("app.ObjectManager")   -- nil while a load starts
    local player = om and om:get_field("PlayerObj")
    if player == nil then return end
    local pp = player:call("get_Transform"):call("get_Position")
    -- Which props still exist, asked of the scene first (v0.23): a door into another area
    -- unloads them, and the first call on each gone one threw inside the game. Both logs of
    -- the 2026-11-03 session had about 565 of those, in bursts at every door, and three
    -- "VMContext was already corrupted" warnings, which can end in a crash.
    local sc = scene()
    local arr = sc and safe(sc.call, sc, "findComponents(System.Type)", sdk.typeof("app.Havok.RigidBodyDynamics"))
    if arr == nil then return end
    local live = {}
    for _, c in ipairs(elems(arr)) do live[c:get_address()] = true end
    for key, s in pairs(ws.phys) do
        if not live[s.c:get_address()] then
            ws.phys[key] = nil
            if ws.phys_by_addr then ws.phys_by_addr[s.c:get_address()] = nil end
            goto continue
        end
        local tr = safe(s.go.call, s.go, "get_Transform")
        local p = tr and safe(tr.call, tr, "get_Position")
        if p == nil then
            -- Unloaded (area change): every call on it throws a game exception (about 2,700
            -- logged in a minute once), so forget it now instead of at the next refresh.
            ws.phys[key] = nil
            if ws.phys_by_addr then ws.phys_by_addr[s.c:get_address()] = nil end
        elseif (p.x - pp.x) ^ 2 + (p.z - pp.z) ^ 2 < PHYS_NEAR * PHYS_NEAR then
            local moved = math.sqrt((p.x - s.last.x) ^ 2 + (p.y - s.last.y) ^ 2 + (p.z - s.last.z) ^ 2)
            local ours = ws.applying["phys:" .. key] and now - ws.applying["phys:" .. key] < 2
            local held = s.weaponish
            local near_me = (p.x - pp.x) ^ 2 + (p.y - pp.y) ^ 2 + (p.z - pp.z) ^ 2 < 2.5 * 2.5
            local scripted = moved > 3 or held or (local_cutscene and local_cutscene())
            if moved > PHYS_MOVE and not ours and not scripted then
                if near_me then s.mine_until = now + 3 end
            end
            local mine = s.mine_until ~= nil and now < s.mine_until
            if scripted and moved > PHYS_MOVE then
                s.last = { x = p.x, y = p.y, z = p.z }   -- moved by the game: not sent
            elseif moved > PHYS_MOVE and not ours and mine and now - s.sent_t > 0.25 then
                s.mine_until = now + 3
                local q = tr:call("get_Rotation")
                s.last, s.sent_t = { x = p.x, y = p.y, z = p.z }, now
                send(string.format("phys %s %.3f %.3f %.3f %.4f %.4f %.4f %.4f %d", key, p.x, p.y, p.z,
                    q.w, q.x, q.y, q.z, chapter()))
            elseif ours then
                s.last = { x = p.x, y = p.y, z = p.z }
            end
        end
        ::continue::
    end
end

-- A move for a name we don't know (v0.30). A prop's name is its object name plus where this game
-- first saw it; after an area reload a game sees an already-pushed prop again at its new spot and
-- names it anew, so the two games' names for the same chair stopped matching and the friend's
-- pushes were ignored (2026-11-08). Match by object name instead: the prop of that name nearest
-- to where the friend first saw it, or to where it's going, within 3 m. The link is kept.
ws.phys_alias = ws.phys_alias or {}
local function match_phys(key, x, y, z)
    local alias = ws.phys_alias[key]
    if alias and ws.phys[alias] then return ws.phys[alias], alias end
    local name, ox, oy, oz = key:match("^(.-)@(%-?[%d%.]+),(%-?[%d%.]+),(%-?[%d%.]+)$")
    if name == nil then return nil end
    ox, oy, oz = tonumber(ox), tonumber(oy), tonumber(oz)
    local best, bkey, bd
    for k, s in pairs(ws.phys) do
        if k:sub(1, #name + 1) == name .. "@" then
            local p = safe(function() return s.go:call("get_Transform"):call("get_Position") end)
            if p then
                local d1 = (p.x - ox) ^ 2 + (p.y - oy) ^ 2 + (p.z - oz) ^ 2
                local d2 = (p.x - x) ^ 2 + (p.y - y) ^ 2 + (p.z - z) ^ 2
                local d = math.min(d1, d2)
                if bd == nil or d < bd then best, bkey, bd = s, k, d end
            end
        end
    end
    if best and bd < 9 then
        ws.phys_alias[key] = bkey
        log(string.format("phys: friend's %s is our %s", key, bkey))
        return best, bkey
    end
    ws.phys_unmatched = (ws.phys_unmatched or 0) + 1
    if ws.phys_unmatched <= 10 then log("phys: no prop here for the friend's " .. key) end
    return nil
end

local function apply_phys(key, x, y, z, qw, qx, qy, qz, ch)
    if ch ~= chapter() or not phys_shared() then return end
    local s = ws.phys[key]
    if s == nil then
        s, key = match_phys(key, x, y, z)
        if s == nil then return end
    end
    -- Ours right now (we're pushing it), or hanging off something here: leave it (v0.33).
    if s.mine_until and os.clock() < s.mine_until then return end
    if s.weaponish then return end
    local tr = s.go:call("get_Transform")
    ws.applying["phys:" .. key] = os.clock()
    local before = tr:call("get_Position")
    local pos, rot = Vector3f.new(x, y, z), Quaternion.new(qw, qx, qy, qz)
    -- Moving the Transform alone never stuck: every logged move in the sessions of 2026-11-03
    -- ended where it started (the physics body puts it back). v0.28 also moves the physics body
    -- itself (via.dynamics.RigidBodySet setPosition/setRotation for body 0, velocity zeroed) and
    -- resets the body from the Transform. Untested on an active prop: each of the first ten
    -- moves is checked 0.5 s later and logged.
    s.rbs = s.rbs or safe(s.go.call, s.go, "getComponent(System.Type)", sdk.typeof("via.dynamics.RigidBodySet"))
    local rbs = s.rbs
    pcall(s.c.call, s.c, "disable")
    tr:call("set_Position", pos)
    tr:call("set_Rotation", rot)
    if rbs then
        pcall(rbs.call, rbs, "setPosition(System.Int32, via.vec3)", 0, pos)
        pcall(rbs.call, rbs, "setRotation(System.Int32, via.Quaternion)", 0, rot)
        pcall(rbs.call, rbs, "setLinearVelocity(System.Int32, via.vec3)", 0, Vector3f.new(0, 0, 0))
        pcall(rbs.call, rbs, "setAngularVelocity(System.Int32, via.vec3)", 0, Vector3f.new(0, 0, 0))
        pcall(rbs.call, rbs, "resetTransform()")
    end
    pcall(s.c.call, s.c, "enable")
    s.last = { x = x, y = y, z = z }
    if ws.phys_logged < 10 then
        ws.phys_logged = ws.phys_logged + 1
        ws.phys_checks = ws.phys_checks or {}
        ws.phys_checks[#ws.phys_checks + 1] = { s = s, key = key, t = os.clock() + 0.5, want = pos,
            from = { x = before.x, y = before.y, z = before.z } }
    end
end

local function check_phys_moves(now)
    local list = ws.phys_checks
    if list == nil then return end
    for i = #list, 1, -1 do
        local c = list[i]
        if now >= c.t then
            table.remove(list, i)
            local p = safe(function() return c.s.go:call("get_Transform"):call("get_Position") end)
            if p then
                local off = math.sqrt((p.x - c.want.x) ^ 2 + (p.y - c.want.y) ^ 2 + (p.z - c.want.z) ^ 2)
                log(string.format("phys %s: from %.2f %.2f %.2f, wanted %.2f %.2f %.2f, after 0.5 s %.2f %.2f %.2f (%s)",
                    c.key, c.from.x, c.from.y, c.from.z, c.want.x, c.want.y, c.want.z, p.x, p.y, p.z,
                    off < 0.3 and "moved" or "DIDN'T MOVE"))
            end
        end
    end
end

-- Changes the friend made in an area that wasn't loaded here, applied once it is.
local function apply_pending()
    for id, ch in pairs(ws.pending_unlock) do
        if ws.doors[id] and ch == chapter() then
            ws.pending_unlock[id] = nil
            pcall(apply_door, "unlock", id, ch)
        end
    end
    for key, p in pairs(ws.pending_props) do
        if ws.props[key] and p.ch == chapter() then
            ws.pending_props[key] = nil
            pcall(apply_prop, p.kind, p.id, p.want, p.ch, p.phone, p.lasting)
        end
    end
end

-- A chapter jump starts that chapter over (v0.40): changes from the friend still waiting for an
-- area of it to load are from the old run.
function coop_world_reset_chapter(v)
    local n = 0
    for id, ch in pairs(ws.pending_unlock) do if ch == v then ws.pending_unlock[id] = nil n = n + 1 end end
    for id, ch in pairs(ws.pending_took) do if ch == v then ws.pending_took[id] = nil n = n + 1 end end
    for k, p in pairs(ws.pending_props) do if p.ch == v then ws.pending_props[k] = nil n = n + 1 end end
    for k, p in pairs(ws.pending_dbox or {}) do if p.ch == v then ws.pending_dbox[k] = nil n = n + 1 end end
    log(string.format("chapter %d starts over: %d waiting changes from the friend dropped", v, n))
end

-- Incoming events (called by coop_enemies.lua). Returns true if it was ours.
local function apply_angle(id, a, side, ch)
    if ch ~= chapter() then return end
    -- A float: "15" parses to the integer 15, which reached the game's Single parameter as
    -- about 0 (the door fell shut each time, 2026-11-04).
    a = (tonumber(a) or 0) + 0.0
    local s = ws.doors[id]
    if s == nil then return end
    if safe(s.d.call, s.d, "get_isLocked") == true then
        -- Pushed open in their game, so it isn't locked there (v0.32).
        pcall(s.d.call, s.d, "unlockDoor")
        if safe(s.d.call, s.d, "get_isLocked") == true then return end
        log("door " .. id .. ": locked here but your friend pushed it: unlocked")
    end
    ws.applying[id] = os.clock()
    s.ang_sent = a   -- not sent back once our "ours" window ends
    door_take_by_peer(s)
    -- Glide to it (v0.28): the angles come 10 times a second and setting each one straight away
    -- looked choppy; glide_doors moves the door there a little every frame.
    if s.ang_target == nil then
        s.ang_cur = tonumber(safe(s.d.call, s.d, "get_currentAngle")) or 0
        log(string.format("door %s pushed by the friend (side %d)", id, side))
    end
    s.ang_target, s.ang_side, s.ang_t = a, side, os.clock()
end

-- Every frame: doors the friend is pushing move toward the last angle they sent, up to
-- GLIDE_SPEED degrees a second; let go 1.5 s after the last angle.
local GLIDE_SPEED = 360
ws.glide_t = 0
local function glide_doors(now)
    local dt = math.min(now - ws.glide_t, 0.1)
    ws.glide_t = now
    for id, s in pairs(ws.doors) do
        if s.ang_target then
            if now - s.ang_t > 1.5 or not (s.live_t and now - s.live_t < 0.5) then
                s.ang_target = nil
            else
                -- Paced so each step takes about as long as the gap to the next angle (0.1 s):
                -- a fixed speed got there early and then waited, moving in bursts (2026-11-04).
                local d = s.ang_target - s.ang_cur
                local step = math.min(math.max(math.abs(d) * dt / 0.12, 20 * dt), GLIDE_SPEED * dt)
                if math.abs(d) <= step then s.ang_cur = s.ang_target else s.ang_cur = s.ang_cur + (d > 0 and step or -step) end
                if s.ang_cur ~= s.ang_set then
                    s.ang_set = s.ang_cur
                    ws.applying[id] = now
                    pcall(s.d.call, s.d, "requestPush(app.DoorPush.OpenSide, System.Single, System.Boolean)",
                        s.ang_side, s.ang_cur + 0.0, false)
                end
            end
        end
    end
end

-- Key items used up (v0.41) ---------------------------------------------------------------
-- Key items stay in each player's world (each picks them up). When one of you uses one on
-- something in the world (app.ItemSelectReaction.tryUseItem succeeded: a key in its lock, a
-- tape in the VCR) and it's gone from your inventory afterwards, it goes from your friends'
-- too: "kused <item> <count> <chapter>". Taken from them as soon as it's in their inventory
-- (after a tape, back in the main game). Reusable tools (bolt cutters) aren't used up, so nothing
-- is sent for them.
local KEY_CATS = { [4] = true, [9] = true, [10] = true }   -- KeyItem, UsableKeyItem, DiscardableKeyItem
local function active_inventory()
    local td = sdk.find_type_definition("app.Inventory")
    local m = td and td:get_method("getActivePlayerInventory")
    return m and safe(m.call, m, nil) or nil
end
local function inv_count(inv, id)
    return tonumber(inv and safe(inv.call, inv, "getTotalStackNum(System.String, System.Boolean)", id, false)) or 0
end
local function item_category(id)
    local im = sdk.get_managed_singleton("app.ItemManager")
    local d = im and safe(im.call, im, "findItemData(System.String)", id)
    return d and tonumber(safe(d.get_field, d, "Category")) or nil
end
ws.used, ws.used_pre, ws.kused = ws.used or {}, nil, ws.kused or {}
do
    local m = sdk.find_type_definition("app.ItemSelectReaction")
    m = m and m:get_method("tryUseItem")
    if m then
        pcall(sdk.hook, m, function(args)
            pcall(function()
                local so = sdk.to_managed_object(args[3])
                local id = so and (safe(so.call, so, "ToString()") or safe(so.call, so, "ToString"))
                ws.used_pre = id and { id = tostring(id), before = inv_count(active_inventory(), tostring(id)) } or nil
            end)
        end, function(r)
            pcall(function()
                local u = ws.used_pre
                ws.used_pre = nil
                local res = sdk.to_int64(r) & 0xFFFFFFFF
                if u and res == 0 and KEY_CATS[item_category(u.id) or -1] then
                    ws.used[u.id] = { t = os.clock(), ch = chapter(), before = u.before }
                    log("used " .. u.id .. " on something (" .. u.before .. " before)")
                end
            end)
            return r
        end)
    end
end
local function poll_used(now)
    local inv = active_inventory()
    for id, u in pairs(ws.used) do
        if chapter() == u.ch then
            local c = inv_count(inv, id)
            if c < u.before then
                send(string.format("kused %s %d %d", id, u.before - c, u.ch))
                ws.used[id] = nil
            elseif now - u.t > 600 then
                ws.used[id] = nil   -- still there after 10 minutes: not one that gets used up
            end
        end
    end
    -- A friend's used-up key items: taken from ours once we have them.
    for id, k in pairs(ws.kused) do
        if now - k.t > 1800 then ws.kused[id] = nil
        else
            local c = inv_count(inv, id)
            if c > 0 and k.n > 0 then
                local n = math.min(c, k.n)
                local ok = inv and pcall(inv.call, inv, "reduceItem(System.String, System.Int32, System.Boolean)", id, n, false)
                if ok then
                    k.n = k.n - n
                    note("your friend used " .. id .. ": it's gone from yours too")
                end
                if k.n <= 0 or not ok then ws.kused[id] = nil end
            end
        end
    end
end

-- Giving a friend who's behind the host's key items and weapons (v0.41, experimental): "inv_req"
-- asks, "inv <item:count,...>" answers, and the missing ones are made with the game's own
-- ItemManager.createItemInstance and put in the inventory with Inventory.addItem.
local GIVE_CATS = { [1] = true, [4] = true, [8] = true, [9] = true, [10] = true }   -- weapons and key items
-- What's in the inventory: { id, n, cat, item } per kind of item. Inventory._ItemList holds
-- app.Inventory.ItemInfo { Owner, Item, Gun } (type dump); the id and the data are on the Item
-- (v0.42: v0.41 read them off the ItemInfo, which has neither, so the list was always empty).
function coop_inventory_items()
    local inv = active_inventory()
    local list = inv and safe(inv.get_field, inv, "_ItemList")
    local out, seen = {}, {}
    for i = 0, (list and safe(list.call, list, "get_Count") or 0) - 1 do
        local info = safe(list.call, list, "get_Item", i)
        local item = info and safe(info.get_field, info, "Item")
        local id = item and tostring(safe(item.get_field, item, "ItemDataID") or "")
        local d = item and safe(item.call, item, "get_ItemData")
        local cat = d and tonumber(safe(d.get_field, d, "Category"))
        if id and id ~= "" and id ~= "nil" and cat and not seen[id] then
            seen[id] = true
            out[#out + 1] = { id = id, n = inv_count(inv, id), cat = cat, data = d }
        end
    end
    return out, inv
end
function coop_inventory_list()
    local out = {}
    for _, e in ipairs((coop_inventory_items())) do
        if GIVE_CATS[e.cat] then out[#out + 1] = e.id .. ":" .. tostring(e.n) end
    end
    return table.concat(out, ",")
end
-- One new item of that kind (stack n where it stacks) into our inventory, through the game's own
-- calls. Returns how many arrived (counted, not assumed) and why not, if none did.
local function give_one(inv, id, n)
    n = math.max(1, n or 1)
    local om = sdk.get_managed_singleton("app.ObjectManager")
    local player = om and om:get_field("PlayerObj")
    local can = safe(inv.call, inv, "isCanAddItem(System.String, System.Int32)", id, n)
    if can == false then return 0, "no room" end
    local td = sdk.find_type_definition("app.ItemManager")
    local m = td and td:get_method("createItemInstance(via.GameObject, System.String)")
    local go = (m and player) and safe(m.call, m, nil, player, id) or nil
    local item = go and safe(go.call, go, "getComponent(System.Type)", sdk.typeof("app.Item"))
    if item == nil then return 0, "couldn't make " .. id end
    if n > 1 then pcall(item.call, item, "setStackNum(System.Int32)", n) end
    local before = inv_count(inv, id)
    local ok, res = pcall(inv.call, inv, "addItem(app.Item, via.GameObject)", item, go)
    local got = inv_count(inv, id) - before
    if got > 0 then return got, "ok" end
    -- Not counted. Inventory.AddItemResult: Put 0, Integration 1, IntegrationAndNoPut 2, NoPut 3,
    -- LimitOver 4. Only when the game says it wasn't added is the new object removed (one it
    -- did add must never be destroyed under the inventory).
    local r = ok and tonumber(res) or nil
    if not ok or (r ~= nil and r >= 3) then pcall(go.call, go, "destroy(via.GameObject)", go) end
    return 0, ok and ("it didn't go in" .. (r and (" (" .. r .. ")") or "")) or tostring(res)
end
function coop_give_missing(list_text)
    local inv = active_inventory()
    if inv == nil then return 0, "no inventory" end
    local given = 0
    for id, n in tostring(list_text):gmatch("([^:,]+):(%d+)") do
        local want, have = tonumber(n), inv_count(inv, id)
        for _ = 1, math.max(0, want - have) do
            local got, why = give_one(inv, id, 1)
            log(string.format("give %s: %s (%d -> %d)", id, why, have, inv_count(inv, id)))
            if got <= 0 then break end
            have = inv_count(inv, id)
            given = given + got
        end
    end
    return given
end

-- Giving a friend an item (v0.42) ------------------------------------------------------------
-- Ammo, healing, materials and the like, from the co-op screen (Give items):
--   "give <token> <to> <item> <n>"  ours, to the friend with SteamID <to>
--   "give_ok <token> <n>"           theirs: n of them are in their inventory now
--   "give_no <token> <why>"         theirs: nothing arrived (no room...)
-- The friend's game makes the item and puts it in its inventory with the game's own calls,
-- and counts what arrived; only then is ours taken (Inventory.reduceItem). No answer in 10 s:
-- nothing is taken, so an item is never lost on the way.
local SHARE_CATS = { [0] = true, [2] = true, [3] = true, [7] = true, [8] = true }   -- other, ammo, healing, materials, throwables
ws.gives = ws.gives or {}         -- our token -> { to, id, n, t, name }
ws.give_seen = ws.give_seen or {} -- tokens we answered (an event can't arrive twice, but just in case)
ws.give_msg = nil                 -- the last result, for the co-op screen

-- The item's name in the game's language (ItemData.NameMsg through via.gui.message), else its id
-- spelled out ("HandgunBullet" -> "Handgun Bullet").
local msg_get
function coop_item_name(id, data)
    if data == nil then
        local im = sdk.get_managed_singleton("app.ItemManager")
        data = im and safe(im.call, im, "findItemData(System.String)", id)
    end
    if msg_get == nil then
        msg_get = false
        local td = sdk.find_type_definition("via.gui.message")
        for _, sig in ipairs({ "get(System.Guid)", "getMessage(System.Guid)" }) do
            local m = td and td:get_method(sig)
            if m then msg_get = m break end
        end
    end
    local guid = data and safe(data.get_field, data, "NameMsg")
    local s = (msg_get and guid) and safe(msg_get.call, msg_get, nil, guid) or nil
    s = s and tostring(s) or ""
    if s ~= "" and s ~= "nil" and not s:find("^<") and #s < 60 then return s end
    local p = tostring(id):gsub("_", " "):gsub("(%l)(%u)", "%1 %2"):gsub("(%a)(%d)", "%1 %2")
    return p
end

-- What we can give: { id, n, name } for every shareable kind we have.
function coop_shareable_items()
    local out = {}
    for _, e in ipairs((coop_inventory_items())) do
        if SHARE_CATS[e.cat] and e.n > 0 then
            out[#out + 1] = { id = e.id, n = e.n, cat = e.cat, name = coop_item_name(e.id, e.data) }
        end
    end
    table.sort(out, function(a, b) if a.cat ~= b.cat then return a.cat < b.cat end return a.name < b.name end)
    return out
end

function coop_give_item(to, id, n, to_name)
    if not coop_send_event then return nil, "not connected" end
    n = math.max(1, math.floor(tonumber(n) or 1))
    local have = inv_count(active_inventory(), id)
    if have < n then return nil, "you don't have that many" end
    for _, g in pairs(ws.gives) do
        if g.id == id and os.clock() - g.t < 10 then return nil, "already on its way" end
    end
    local token = string.format("%x%04x", os.time() % 0x10000000, math.random(0, 0xFFFF))
    ws.gives[token] = { to = to, id = id, n = n, t = os.clock(), name = coop_item_name(id), to_name = to_name or "your friend" }
    send(string.format("give %s %s %s %d", token, to, id, n))
    return token
end

local function on_give(token, to, id, n)
    local st = coop_net_state and coop_net_state()
    local me = st and st.kv and st.kv.steamSelf
    if me == nil or to ~= me then return end   -- for someone else
    if ws.give_seen[token] then return end
    ws.give_seen[token] = true
    local inv = active_inventory()
    if inv == nil then send("give_no " .. token .. " not_playing") return end
    local got, why, left = 0, "?", n
    -- A big stack may go in as more than one slot.
    for _ = 1, 8 do
        if left <= 0 then break end
        local g, w = give_one(inv, id, left)
        why = w
        if g <= 0 then break end
        got, left = got + g, left - g
    end
    log(string.format("friend gave %s x%d: %d arrived (%s)", id, n, got, why))
    if got > 0 then
        send(string.format("give_ok %s %d", token, got))
        note(string.format("%s gave you %s x%d", coop_event_slot and coop_event_slot > 1 and ("Friend " .. coop_event_slot) or "Your friend",
            coop_item_name(id), got))
    else
        send("give_no " .. token .. " " .. tostring(why):gsub("%s+", "_"))
    end
end

local function on_give_reply(token, ok, val)
    local g = ws.gives[token]
    if g == nil then return end
    ws.gives[token] = nil
    if ok then
        local n = math.min(g.n, tonumber(val) or 0)
        local inv = active_inventory()
        local rok = n > 0 and inv and pcall(inv.call, inv, "reduceItem(System.String, System.Int32, System.Boolean)", g.id, n, false)
        ws.give_msg = { text = string.format("Gave %s x%d to %s", g.name, n, g.to_name), color = 0xFF7FFF8C, t = os.clock() }
        if not rok then log("give: ours couldn't be taken (" .. g.id .. ")") end
        if coop_stat then pcall(coop_stat, "given", n) end
    else
        local why = tostring(val or "?"):gsub("_", " ")
        ws.give_msg = { text = string.format("%s couldn't take %s: %s", g.to_name, g.name, why), color = 0xFF7FE6FF, t = os.clock() }
    end
    note(ws.give_msg.text)
end

re.on_frame(function()
    local now = os.clock()
    for token, g in pairs(ws.gives) do
        if now - g.t > 10 then
            ws.gives[token] = nil
            ws.give_msg = { text = g.to_name .. "'s game didn't answer: nothing was given", color = 0xFF7FE6FF, t = now }
            note(ws.give_msg.text)
        end
    end
end)

function coop_world_on_event(text)
    local gt, gto, gid, gn = text:match("^give (%x+) (%d+) (%S+) (%d+)$")
    if gt then pcall(on_give, gt, gto, gid, tonumber(gn)) return true end
    local okt, okn = text:match("^give_ok (%x+) (%d+)$")
    if okt then pcall(on_give_reply, okt, true, okn) return true end
    local nt, nwhy = text:match("^give_no (%x+) (%S+)$")
    if nt then pcall(on_give_reply, nt, false, nwhy) return true end
    local kid, kn, kch = text:match("^kused (%S+) (%d+) (%-?%d+)")
    if kid then
        if KEY_CATS[item_category(kid) or -1] then
            local k = ws.kused[kid] or { n = 0 }
            k.n, k.t = k.n + tonumber(kn), os.clock()
            ws.kused[kid] = k
            log("friend used up " .. kid .. " x" .. kn)
        end
        return true
    end
    local rq = text:match("^inv_req (%d+)")
    if rq or text == "inv_req" then
        -- Only the one asked answers (the host).
        local st = coop_net_state and coop_net_state()
        local me = st and st.kv and st.kv.steamSelf
        if (rq == nil or rq == me) and coop_send_event then coop_send_event("inv " .. coop_inventory_list()) end
        return true
    end
    local il = text:match("^inv (.*)$")
    if il then
        if ws.want_inv and os.clock() - ws.want_inv < 30 then
            ws.want_inv = nil
            local n = coop_give_missing(il)
            note(n > 0 and string.format("you got %d key items and weapons from the host", n) or "you already have the host's key items and weapons")
        end
        return true
    end
    local aid, aa, aside, ach = text:match("^dang (%S+) ([%d%.]+) ([01]) (%-?%d+)")
    if aid then pcall(apply_angle, aid, tonumber(aa), tonumber(aside), tonumber(ach)) return true end
    local kind, id, ch = text:match("^(unlock) (%S+) (%-?%d+)")
    if not kind then kind, id, ch = text:match("^(open) (%S+) (%-?%d+)") end
    if not kind then kind, id, ch = text:match("^(close) (%S+) (%-?%d+)") end
    if kind then pcall(apply_door, kind, id, tonumber(ch)) return true end
    local dkey, dch = text:match("^dbreak (%S+) (%-?%d+)$")
    if dkey then pcall(coop_apply_dbox, dkey, tonumber(dch)) return true end
    local bid, bch = text:match("^break (%S+) (%-?%d+)")
    if bid then pcall(apply_prop, "box", bid, true, tonumber(bch)) return true end
    local did, don, dch = text:match("^drawer (%S+) ([01]) (%-?%d+)")
    if did then pcall(apply_prop, "drawer", did, don == "1", tonumber(dch)) return true end
    local iid, ich, itag = text:match("^intr (%S+) (%-?%d+) ?(%a*)")
    if iid then
        -- Phone calls move the story on, so they have their own switch ("Share phone calls",
        -- on by default), apart from "Share interactions".
        local phone = itag == "phone"
        if phone and settings and settings.share_phones == false then
            log("phone call not shared (Share phone calls is off): " .. iid)
        elseif phone or interactions_shared() then
            pcall(apply_prop, "intr", iid, true, tonumber(ich), phone, itag == "lock")
        end
        return true
    end
    local sid, son, sch = text:match("^switch (%S+) ([01]) (%-?%d+)")
    if sid then
        if interactions_shared() then pcall(apply_prop, "switch", sid, son == "1", tonumber(sch)) end
        return true
    end
    local gid, gch, gname = text:match("^got (%S+) (%-?%d+) (%S+)")
    if gid then
        if tonumber(gch) == chapter() then
            local e = ws.items[gid]
            local here = e and safe(e.go.call, e.go, "get_Draw")
            local shown = (coop_item_name and safe(coop_item_name, gname)) or gname   -- v0.42: the game's name for it
            note("your friend picked up " .. shown .. (here and ": pick it up too, it's still here for you" or ""))
        end
        return true
    end
    local pk, px, py, pz, pqw, pqx, pqy, pqz, pch =
        text:match("^phys (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%-?%d+)")
    if pk then
        pcall(apply_phys, pk, tonumber(px), tonumber(py), tonumber(pz), tonumber(pqw), tonumber(pqx),
            tonumber(pqy), tonumber(pqz), tonumber(pch))
        return true
    end
    local tid, tch, tname = text:match("^took (%S+) (%-?%d+) (%S+)")
    if tid then pcall(apply_took, tid, tonumber(tch), tname) return true end
    return false
end

re.on_frame(function()
    local now = os.clock()
    -- A scene is swapping objects in and out (v0.36): no object calls, then refresh everything
    -- (the refreshes below run first, before any poll).
    if coop_scene_settling and coop_scene_settling() then
        ws.settling = true
        return
    end
    if ws.settling then
        ws.settling = false
        ws.doors_t, ws.props_t, ws.items_t = -100, -100, -100
    end
    if now - ws.doors_t > 3 then
        ws.doors_t = now
        local ok, err = pcall(refresh_doors)
        if not ok and not ws.door_err then ws.door_err = true log("doors ERR " .. tostring(err)) end
    end
    if now - ws.props_t > 3 then
        ws.props_t = now
        local ok, err = pcall(refresh_props)
        if not ok and not ws.prop_err then ws.prop_err = true log("props ERR " .. tostring(err)) end
        local fok, ferr = pcall(refresh_phys)
        if not fok and not ws.phys_err then ws.phys_err = true log("phys ERR " .. tostring(ferr)) end
        local aok, aerr = pcall(apply_pending)
        if not aok and not ws.pend_err then ws.pend_err = true log("pending ERR " .. tostring(aerr)) end
    end
    if now - ws.items_t > 2 then
        ws.items_t = now
        local ok, err = pcall(refresh_items)
        if not ok and not ws.item_err then ws.item_err = true log("items ERR " .. tostring(err)) end
    end
    pcall(stream_door_angles, now)
    pcall(check_phys_moves, now)
    pcall(glide_doors, now)
    if now - ws.poll_t > 0.25 then
        ws.poll_t = now
        local ok, err = pcall(poll_doors, now)
        if not ok and not ws.poll_err then ws.poll_err = true log("door poll ERR " .. tostring(err)) end
        local fpok, fperr = pcall(poll_phys, now)
        if not fpok and not ws.phys_poll_err then ws.phys_poll_err = true log("phys poll ERR " .. tostring(fperr)) end
        pcall(poll_locks, now)
        local uok, uerr = pcall(poll_used, now)
        if not uok and not ws.used_err then ws.used_err = true log("used items ERR " .. tostring(uerr)) end
        pcall(poll_chains, now)
        local pok, perr = pcall(poll_props, now)
        if not pok and not ws.ppoll_err then ws.ppoll_err = true log("prop poll ERR " .. tostring(perr)) end
        local iok, ierr = pcall(poll_items, now)
        if not iok and not ws.ipoll_err then ws.ipoll_err = true log("item poll ERR " .. tostring(ierr)) end
    end
end)

-- On-screen line (coop_dummy shows it).
function world_sync_hud()
    if os.clock() - ws.msg_t < 6 then return "World: " .. ws.msg end
    return nil
end

function world_sync_status()
    local doors, locked, items, pend = 0, 0, 0, 0
    for _, s in pairs(ws.doors) do doors = doors + 1 if s.locked then locked = locked + 1 end end
    for _ in pairs(ws.items) do items = items + 1 end
    for _ in pairs(ws.pending_took) do pend = pend + 1 end
    return string.format("Doors and items: %d doors (%d locked), %d items here; sent %d, applied %d, remembered %d",
        doors, locked, items, ws.sent, ws.applied, pend)
end

-- Testing: the bot "opens" / "unlocks" the nearest door, or "takes" the nearest supply.
local function nearest(list, pick)
    local player = sdk.get_managed_singleton("app.ObjectManager"):get_field("PlayerObj")
    if player == nil then return nil end
    local pp = player:call("get_Transform"):call("get_Position")
    local best, best_id, best_d
    for id, e in pairs(list) do
        if pick(e) then
            local go = e.go or e.d:call("get_GameObject")
            local p = go:call("get_Transform"):call("get_Position")
            local dd = (p.x - pp.x) ^ 2 + (p.y - pp.y) ^ 2 + (p.z - pp.z) ^ 2
            if best_d == nil or dd < best_d then best, best_id, best_d = e, id, dd end
        end
    end
    return best, best_id
end

function world_sync_bot(kind)
    if kind == "unlock" or kind == "open" then
        local _, id = nearest(ws.doors, function(s)
            if kind == "unlock" then return s.locked end
            return not s.locked and not s.open
        end)
        if id == nil then return "no suitable door nearby" end
        fs.write("coopnet_command.txt", string.format("botevent %s %s %d", kind, id, chapter()))
        return "the bot will " .. kind .. " the nearest door"
    elseif kind == "took" then
        local e, id = nearest(ws.items, function(e) return safe(e.go.call, e.go, "get_Draw") and is_supply(e.it) end)
        if id == nil then return "no supply nearby" end
        local name = tostring(e.it:get_field("ItemDataID"))
        fs.write("coopnet_command.txt", string.format("botevent took %s %d %s", id, chapter(), name))
        return "the bot will take " .. name
    elseif kind == "break" or kind == "drawer" then
        local want = kind == "break" and "box" or "drawer"
        local s, key = nearest(ws.props, function(s)
            if s.kind ~= want then return false end
            s.go = s.go or s.c:call("get_GameObject")
            return want == "drawer" or not s.on
        end)
        if key == nil then return "no " .. want .. " nearby" end
        if kind == "break" then
            fs.write("coopnet_command.txt", string.format("botevent break %s %d", s.id, chapter()))
            return "the bot will smash the nearest box"
        end
        fs.write("coopnet_command.txt", string.format("botevent drawer %s %d %d", s.id, s.on and 0 or 1, chapter()))
        return "the bot will " .. (s.on and "shut" or "open") .. " the nearest drawer"
    end
end

log("coop_world loaded")
