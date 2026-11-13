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

-- v0.48: this script's frame work waits while the game loads or swaps the player (coop_busy, coop_dummy.lua).
local re = setmetatable({ on_frame = function(f)
    return _G.re.on_frame(function() if coop_busy and coop_busy() then return end return f() end)
end }, { __index = _G.re })

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
local log_buf, log_t, log_tail = {}, 0, nil
-- v0.52: repeated lines are limited and the file written by coop_dummy.lua's coop_log_gate / coop_log_flush.
local function log(s)
    if coop_log_gate and not coop_log_gate("world", s) then return end
    log_buf[#log_buf + 1] = os.date("%H:%M:%S ") .. tostring(s)
end
re.on_frame(function()
    if coop_log_flush then log_buf, log_t = coop_log_flush("world", "coop_world_log.txt", log_buf, log_t) return end
    -- without coop_dummy.lua: the v0.51 writer
    if #log_buf == 0 or os.clock() - log_t < 3 then return end
    log_t = os.clock()
    local f = (log_tail or fs.read("coop_world_log.txt") or "") .. table.concat(log_buf, "\n") .. "\n"
    if #f > 200000 then f = f:sub(-100000) end
    log_tail = f
    fs.write("coop_world_log.txt", f)
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
    if type(arr) == "table" then return arr end
    local ok, r = pcall(function() return arr:get_elements() end)
    if ok and r then return r end
    -- No get_elements on it (v0.48): read it item by item instead.
    local ok2, n = pcall(arr.call, arr, "get_Count")
    if not ok2 or type(n) ~= "number" then return {} end
    local out = {}
    for i = 0, n - 1 do
        local ok3, it = pcall(arr.call, arr, "get_Item", i)
        if ok3 and it then out[#out + 1] = it end
    end
    return out
end
-- Every component of a type in the scene, or nil when the answer can't be read (v0.48). About one call
-- in 50 the list comes back without its array methods; read as "nothing there" it emptied the door and
-- prop lists for a moment, and a friend's door close or drawer arriving just then was dropped as "not
-- loaded here" (seen in a bot run 2026-11-11, and the likely cause of doors not following in the
-- basement on 2026-11-10). Asked up to 3 times; a scan that still can't be read is skipped, not trusted.
local function find_comps(sc, tn)
    if sdk.find_type_definition(tn) == nil then return {} end      -- a type this game doesn't have: none
    for _ = 1, 3 do
        local ok, arr = pcall(sc.call, sc, "findComponents(System.Type)", sdk.typeof(tn))
        if ok and arr ~= nil and pcall(function() return arr:get_elements() end) then return arr end
        -- Without get_elements, but readable item by item (v0.48: always so on the title screen).
        if ok and arr ~= nil then
            local ok2, n = pcall(arr.call, arr, "get_Count")
            if ok2 and type(n) == "number" then return elems(arr) end
        end
    end
    return nil
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
    local arr = sc and find_comps(sc, "app.DoorPush")
    if arr == nil then return end      -- unreadable scan: keep what we have
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
    for id, c in pairs(ws.unlock_check or {}) do
        local s = ws.doors[id]
        if s == nil or c.n >= 3 then
            ws.unlock_check[id] = nil
        elseif now >= c.t then
            if safe(s.d.call, s.d, "get_isLocked") == true then
                c.n, c.t = c.n + 1, now + 1
                ws.applying[id] = now
                pcall(s.d.call, s.d, "unlockDoor")
                log(string.format("door %s still locked after your friend's unlock: unlocked again (try %d)", id, c.n))
            else
                ws.unlock_check[id] = nil
            end
        end
    end
    -- Only doors the scene still has (v0.24): one unloaded by an area change threw inside the
    -- game, like the pushed objects did (see poll_phys).
    local sc = scene()
    local arr = sc and find_comps(sc, "app.DoorPush")
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
            local pc = ws.pending_close and ws.pending_close[id]
            if pc and (now - pc > 60 or not open) then
                ws.pending_close[id] = nil
            elseif pc and not player_near_door(s, 1.5) then
                ws.pending_close[id] = nil
                ws.applying[id] = now
                local ok, err = door_close(d)
                log("closing door " .. id .. " now that you've stepped out" .. (ok and "" or (" ERR " .. tostring(err))))
            end
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
            -- Checked again (v0.48): on the father key door (sm2021, a two-sided item lock) unlockDoor once left
            -- it locked in a bot run; poll_doors calls it again a second later, up to 3 times.
            ws.unlock_check = ws.unlock_check or {}
            ws.unlock_check[id] = { t = os.clock() + 1, n = 0 }
        end
    elseif kind == "open" then
        door_take_by_peer(s)
        if s.d:call("get_isLocked") then
            -- Opened in their game, so it isn't locked there (v0.32).
            pcall(s.d.call, s.d, "unlockDoor")
            log("door " .. id .. ": locked here but your friend opened it: unlocked")
        end
        local before = s.d:call("get_doorState")
        if ws.pending_close then ws.pending_close[id] = nil end
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
            ws.pending_close = ws.pending_close or {}
            ws.pending_close[id] = os.clock()
            log("close door " .. id .. ": you're in the doorway; it closes once you step out")
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
    local arr = sc and find_comps(sc, "app.Item")
    if arr == nil then return end      -- unreadable scan: keep what we have
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
    "getinto", "getout", "ignition", "ethancar", "puzzle", "ladder", "hide", "crouch", "climb",
    "moldedtray01a_enemytray" }   -- the morgue's tray incinerators toggle: shared by state (poll_trays)
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
coop_world_intr_names, coop_world_intr_allowed = intr_names, intr_allowed   -- for the bot tests (v0.50)

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
                    -- Our own player answering a phone (this hook doesn't fire for a friend's, which is
                    -- called from here): coop_story tags the call's scene with it.
                    if mname == "successInteract" and is_phone(c) then coop_my_phone_t = os.clock() end
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
                if st:find("PauseStart", 1, true) then
                    l.pause_t = l.pause_t or now
                    if now - l.pause_t >= 8 then l.until_t = math.min(l.until_t, now - 0.001) end
                end
                if now > l.until_t then
                    ws.locks[id] = nil
                    log("lockpick " .. id .. ": still shut (lock state " .. st .. "): opening it by hand")
                    pcall(lock_hand_open, l.c, id)
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
        local arr = find_comps(sc, tn)
        if arr == nil then return end      -- unreadable scan: keep what we have
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
        local arr = find_comps(sc, pt.type)
        if arr == nil then return end      -- unreadable scan: keep what we have
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

-- How far a prop is from our player (v0.48). RE7 unloads the rooms you've left and loads them again from
-- the save when you come back; in between a drawer reads as shut. A bot test (2026-11-11) caught the far
-- game sending that as "I shut it" and taking the friend's change as already done, so on its way back the
-- drawer was in the old state. Drawers and switches more than PROP_FAR m away are neither sent nor applied
-- at once: the friend's change waits until we're near again. Drawers only: switches can sit far from where
-- they're used.
PROP_FAR = 25
function coop_world_prop_dist(s)
    local om = sdk.get_managed_singleton("app.ObjectManager")
    local p = om and om:get_field("PlayerObj")
    local pp = p and safe(function() return p:call("get_Transform"):call("get_Position") end)
    local q = safe(function() return s.c:call("get_GameObject"):call("get_Transform"):call("get_Position") end)
    if pp == nil or q == nil then return 0 end
    return math.sqrt((pp.x - q.x) ^ 2 + (pp.z - q.z) ^ 2)   -- across the floor: some props sit far below what you use (the shadow puzzle switch, 20 m)
end

local function poll_props(now)
    pcall(poll_dbox, now)
    if coop_world_restore_retargeted then pcall(coop_world_restore_retargeted, now) end
    if coop_world_check_drawers then pcall(coop_world_check_drawers, now) end
    for key, s in pairs(ws.props) do
        local on = safe(s.pt.state, s.c) == true
        local ours = ws.applying[key] and now - ws.applying[key] < 3
        -- Far away nobody touched it: the room unloading or loading back changed what it reads.
        if on ~= s.on and s.kind == "drawer" and coop_world_prop_dist(s) > PROP_FAR then ours = true end
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

-- A friend's interaction is theirs to perform (v0.48). successInteract() alone ran the whole thing on
-- OUR player: walked 3.5 m to the sheet metal and put through the first-person animation (measured
-- 2026-11-11). The interaction's event has a part for the player (app.GameEventAction with
-- isTargetPlayer, next to an InteractEventSetting under the object); pointed at the friend's body
-- instead, the object still animates and reaches the game's own end state while we stay free.
-- settings.intr_pull_me = true brings the old way back. Parts are pointed back afterwards.
ws.retargeted = {}
local function retarget_event(c, body, own)
    local go = safe(c.call, c, "get_GameObject")
    local tr = go and safe(go.call, go, "get_Transform")
    -- own: the component sits on the gimmick's own top object (the statue, a puzzle stand), whose parent
    -- is the whole room: only that object's parts, not every interaction in the hall.
    local par = tr and not (own and safe(tr.call, tr, "get_Child") ~= nil) and safe(tr.call, tr, "get_Parent")
    local n = 0
    local function walk(t, depth)
        local g = safe(t.call, t, "get_GameObject")
        local gea = g and safe(g.call, g, "getComponent(System.Type)", sdk.typeof("app.GameEventAction"))
        if gea and safe(gea.call, gea, "get_isTargetPlayer") == true then
            pcall(gea.set_field, gea, "SetTargetObj", body)
            pcall(gea.set_field, gea, "TargetObjTemp", body)
            ws.retargeted[#ws.retargeted + 1] = { gea = gea, t = os.clock() }
            n = n + 1
        end
        if depth < 4 then
            local ch, k = safe(t.call, t, "get_Child"), 0
            while ch and k < 40 do walk(ch, depth + 1) ch = safe(ch.call, ch, "get_Next") k = k + 1 end
        end
    end
    walk(par or tr, 0)
    return n
end
local function restore_retargeted(now)
    if #ws.retargeted == 0 then return end
    local busy = coop_ghost_event_active and coop_ghost_event_active()
    for i = #ws.retargeted, 1, -1 do
        local r = ws.retargeted[i]
        if now - r.t > 100 or (not busy and now - r.t > 8) then
            pcall(r.gea.set_field, r.gea, "SetTargetObj", nil)
            pcall(r.gea.set_field, r.gea, "TargetObjTemp", nil)
            table.remove(ws.retargeted, i)
        end
    end
end
coop_world_restore_retargeted = restore_retargeted

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
    -- A drawer, locker or switch changed while our own scene plays (v0.48): the game holds its props'
    -- state machines still during a scene. On 2026-11-10 a locker the friend opened during the boiler
    -- room scene took the "open" flag here and stayed shut (the flag then made every later try a no-op).
    -- It waits for the scene to end, and afterwards the prop's own machine is checked (drawer_check).
    if (kind == "drawer" or kind == "switch") and local_cutscene and local_cutscene() then
        ws.pending_props[key] = { kind = kind, id = id, want = want, ch = ch }
        log(kind .. " " .. id .. ": waits for your scene to end")
        return
    end
    if kind == "drawer" and coop_world_prop_dist(s) > PROP_FAR then
        ws.pending_props[key] = { kind = kind, id = id, want = want, ch = ch, far = true }
        log("remembered " .. kind .. ": " .. id .. " (far from you: set when you're near)")
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
            local parts = 0
            if not (settings and settings.intr_pull_me == true) then
                -- A phone starts its call's scene from here a moment later: coop_story gives that to the
                -- friend's body too while this is set.
                if phone or is_phone(s.c) then coop_friend_scene_until = os.clock() + 20 end
                local body = coop_ghost_event_begin and coop_ghost_event_begin()
                if body then parts = retarget_event(s.c, body) end
                log(string.format("intr %s: %s", id, body == nil and "no friend's body yet: it plays on you"
                    or (parts > 0 and (parts .. " player part(s) given to your friend's body") or "no player part in it")))
            end
            ok, err = pcall(s.c.call, s.c, "successInteract")
        end
        if phone or is_phone(s.c) then
            note((settings and settings.intr_pull_me == true) and "your friend answered the phone: the call plays for you too"
                or "your friend answered the phone: you hear the call too")
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
        ws.drawer_check[key] = { want = want, t = os.clock() + 2.5, tries = 0 }
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
    local arr = sc and find_comps(sc, "app.Havok.RigidBodyDynamics")
    if arr == nil then return end      -- unreadable scan: keep what we have
    local seen = {}
    for _, c in ipairs(elems(arr)) do
        local go = safe(c.call, c, "get_GameObject")
        ws.phys_by_addr = ws.phys_by_addr or {}
        local known = ws.phys_by_addr[c:get_address()]
        if known and ws.phys[known] then seen[known] = true
        elseif go then
            local p = safe(function() return go:call("get_Transform"):call("get_Position") end)
            local lname = tostring(go and go:call("get_Name") or ""):lower()
            -- Characters' own body parts (v0.47, bot test 2026-11-10): a Molded's ragdoll pieces
            -- (em4000_Head_RB, em4050_blade_RB...) went out as pushed props several times a second.
            local body = lname:find("^em%d%d%d%d") ~= nil or lname:find("^pl%d%d%d%d") ~= nil or lname:find("^ch%d%d%d%d") ~= nil
            if p and not body then
                local key = string.format("%s@%.1f,%.1f,%.1f", tostring(go:call("get_Name")), p.x, p.y, p.z)
                if ws.phys[key] == nil then
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
    local arr = sc and find_comps(sc, "app.Havok.RigidBodyDynamics")
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

-- Did a drawer or locker we changed on the friend's word really move? Its object's state machine rests
-- in "..._PauseStart" shut and "..._PauseEnd" open (measured on the basement locker, sm1344_Locker03A:
-- Gimmick_Open_PauseStart -> SetSwitch(true) -> Gimmick_Open_PauseEnd). If the flag says one thing and
-- the machine rests in the other 2.5 s later, the switch is thrown again (off, then as wanted), up to 3
-- times. Machines with other state names are left alone.
ws.drawer_check = {}
local function check_drawers(now)
    for key, c in pairs(ws.drawer_check) do
        local s = ws.props[key]
        if s == nil or c.tries >= 3 then
            ws.drawer_check[key] = nil
        elseif now >= c.t and not (local_cutscene and local_cutscene()) then
            local go = safe(s.c.call, s.c, "get_GameObject")
            local tr = go and safe(go.call, go, "get_Transform")
            local par = tr and safe(tr.call, tr, "get_Parent")
            local pg = par and safe(par.call, par, "get_GameObject")
            local fsm = pg and safe(pg.call, pg, "getComponent(System.Type)", sdk.typeof("via.fsm.Fsm"))
            local st = fsm and tostring(safe(fsm.call, fsm, "getCurrentState(System.UInt32)", 0) or "") or ""
            local wrong = (c.want and st:match("PauseStart$") ~= nil) or (not c.want and st:match("PauseEnd$") ~= nil)
            if not wrong then
                ws.drawer_check[key] = nil
            else
                c.tries, c.t = c.tries + 1, now + 2.5
                ws.applying[key] = now
                pcall(s.c.call, s.c, "SetSwitch(System.Boolean)", not c.want)
                pcall(s.c.call, s.c, "SetSwitch(System.Boolean)", c.want)
                log(string.format("%s: flag says %s but it rests in %s: thrown again (try %d)", key, c.want and "open" or "shut", st, c.tries))
            end
        end
    end
end
coop_world_check_drawers = check_drawers

-- Changes the friend made in an area that wasn't loaded here, applied once it is.
local function apply_pending()
    for id, ch in pairs(ws.pending_unlock) do
        if ws.doors[id] and ch == chapter() then
            ws.pending_unlock[id] = nil
            pcall(apply_door, "unlock", id, ch)
        end
    end
    local in_scene = local_cutscene and local_cutscene()
    for key, p in pairs(ws.pending_props) do
        local held = (p.kind == "drawer" or p.kind == "switch") and (in_scene or (p.kind == "drawer" and ws.props[key] and coop_world_prop_dist(ws.props[key]) > PROP_FAR - 5))
        if ws.props[key] and p.ch == chapter() and not held then
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
                -- v0.48: the name only. Counting the inventory here ran in the middle of the game's own
                -- item use (155 game exceptions from getTotalStackNum in one session).
                ws.used_pre = id and { id = tostring(id), c = sdk.to_managed_object(args[2]) } or nil
            end)
        end, function(r)
            pcall(function()
                local u = ws.used_pre
                ws.used_pre = nil
                local res = sdk.to_int64(r) & 0xFFFFFFFF
                if u and res == 0 then
                    ws.used[u.id] = { t = os.clock(), ch = chapter() }
                    log("used " .. u.id .. " on something")
                    -- Told to the friend from the next frame's poll, not from inside the game's item use.
                    if u.c then
                        pcall(u.c.add_ref, u.c)
                        ws.iuse_out[#ws.iuse_out + 1] = { c = u.c, id = u.id, t = os.clock() }
                    end
                end
            end)
            return r
        end)
    end
end
-- v0.48: nothing is taken from anyone's inventory any more. v0.41-v0.47 sent "kused" when a key item was
-- used up, and the other game removed its own copy with Inventory.reduceItem as soon as it had one. On
-- 2026-11-10 that took an item out from under the game three times while its owner was using it (both
-- players putting the pendulum in their clocks; dog heads being placed; a coin taken during an injection),
-- and each time that game crashed a second later. It also emptied the other player's antique coins and
-- took a dog head back after a reload. Key items and coins are each player's own; the doors and locks
-- they open are shared by "unlock". An old version's "kused" is ignored.
-- Key-item gimmicks are shared by their result (v0.48). The dog heads' door, the statue, the clock and
-- every lock that takes an item carry an app.ItemSelectReaction: a list of { ItemID, StateName, Result }
-- and a state machine (via.fsm.Fsm on the same object). Using the right item sends that machine to
-- StateName. Tested 2026-11-11 on the dog heads' door in a game that had no dog head: setCurrentState(
-- "SelectSuccessA") showed head A on the door, B and C the same, and with all three the door unlocked;
-- the player wasn't moved or put in an animation. So when one of you uses an item, the other game gets
-- "iuse <gimmick> <state> <chapter> <item>" and sets the same state; nobody's inventory is touched.
-- The gimmick is named by its object's name and position (it has no id of its own). Not shared: tapes
-- in the video deck (they change chapter; followed separately), antique-coin cages (what you buy is your
-- own), lockpicks (their own code above), and a plain one-key door (its unlock is shared already).
ws.iuse_out, ws.iuse_pending, ws.iuse_last = {}, {}, {}
local function reaction_key(c)
    local go = safe(c.call, c, "get_GameObject")
    local tr = go and safe(go.call, go, "get_Transform")
    local p = tr and safe(tr.call, tr, "get_Position")
    if p == nil then return nil end
    local par = safe(tr.call, tr, "get_Parent")
    local pg = par and safe(par.call, par, "get_GameObject")
    local name = tostring(safe(go.call, go, "get_Name") or "") .. "<" .. tostring(pg and safe(pg.call, pg, "get_Name") or "")
    return string.format("%s@%.1f,%.1f,%.1f", (name:gsub("%s", "_")), p.x, p.y, p.z)
end
local function reaction_settings(c)
    local out = {}
    local list = safe(c.get_field, c, "ReactionSettings")
    local n = list and tonumber(safe(list.call, list, "get_Count")) or 0
    for i = 0, n - 1 do
        local e = safe(list.call, list, "get_Item", i)
        if e then
            out[#out + 1] = { item = tostring(safe(e.get_field, e, "ItemID") or ""), state = tostring(safe(e.get_field, e, "StateName") or ""),
                result = tonumber(safe(e.get_field, e, "Result")) or -1 }
        end
    end
    return out
end
local function under_door(c)
    local go = safe(c.call, c, "get_GameObject")
    local tr = go and safe(go.call, go, "get_Transform")
    for _ = 1, 4 do
        if tr == nil then return false end
        local g = safe(tr.call, tr, "get_GameObject")
        if g and safe(g.call, g, "getComponent(System.Type)", sdk.typeof("app.DoorPush")) then return true end
        tr = safe(tr.call, tr, "get_Parent")
    end
    return false
end
-- Why this gimmick's item use stays with the player who did it, or nil when it is shared.
local function reaction_private(c, item, sets)
    local key = (reaction_key(c) or ""):lower()
    if key:find("videodeck", 1, true) or item:find("FoundFootage", 1, true) or item == "SaveTape" then return "a tape" end
    if item == "Coin" or item == "CoinOld" then return "antique coins are your own" end
    if key:find("keypick", 1, true) or key:find("keylock", 1, true) or item == "CylinderKey" then return "a lockpick" end
    local wins = 0
    for _, e in ipairs(sets) do if e.result == 0 then wins = wins + 1 end end
    if wins <= 1 and under_door(c) then return "a door key (the unlock is shared)" end
    return nil
end
local function find_reaction(key)
    local sc = scene()
    local arr = sc and find_comps(sc, "app.ItemSelectReaction")
    for _, c in ipairs(elems(arr)) do
        if reaction_key(c) == key then return c end
    end
    return nil
end
local function apply_iuse(key, state, ch, item, later)
    if ch ~= chapter() then return true end
    if settings and settings.share_item_gimmicks == false then return true end
    -- One change at a time per gimmick, 2 s apart, in the order they were made (three dog heads placed
    -- in a row each need the door's machine to come back from the one before).
    if not later then
        local waiting = false
        for _, e in ipairs(ws.iuse_pending) do if e.key == key then waiting = true end end
        if waiting or (ws.iuse_last[key] and os.clock() - ws.iuse_last[key] < 2) then
            ws.iuse_pending[#ws.iuse_pending + 1] = { key = key, state = state, ch = ch, item = item, t = os.clock() }
            return false
        end
    end
    local c = find_reaction(key)
    if c == nil then
        if not later then
            ws.iuse_pending[#ws.iuse_pending + 1] = { key = key, state = state, ch = ch, item = item, t = os.clock() }
            log("iuse " .. key .. " " .. state .. ": not loaded here yet, kept for when it is")
        end
        return false
    end
    -- The machine is on the object the gimmick names (FsmObj): itself on the dog heads' door, a child
    -- (InteractShotgun) on the statue.
    local go = safe(c.get_field, c, "FsmObj") or c:call("get_GameObject")
    local fsm = safe(go.call, go, "getComponent(System.Type)", sdk.typeof("via.fsm.Fsm"))
    if fsm == nil then
        go = c:call("get_GameObject")
        fsm = safe(go.call, go, "getComponent(System.Type)", sdk.typeof("via.fsm.Fsm"))
    end
    -- Far from the player a gimmick's state machine isn't running (no current state) and a change is
    -- lost when it starts (tested from the study, 25 m from the hall door): wait until it runs.
    local cur = fsm and tostring(safe(fsm.call, fsm, "getCurrentState(System.UInt32)", 0) or "") or ""
    if fsm ~= nil and (cur == "" or cur == "nil") then
        if not later then
            ws.iuse_pending[#ws.iuse_pending + 1] = { key = key, state = state, ch = ch, item = item, t = os.clock() }
            log("iuse " .. key .. " " .. state .. ": that gimmick isn't running here yet (too far), kept for when it is")
        end
        return false
    end
    if fsm == nil or safe(fsm.call, fsm, "hasState(System.String)", state) ~= true then
        log("iuse " .. key .. ": no state " .. state .. " here")
        return true
    end
    ws.iuse_last[key] = os.clock()
    -- If the state plays a player animation, the friend's body performs it (as with their other interactions).
    local parts = 0
    local body = not (settings and settings.intr_pull_me == true) and coop_ghost_event_begin and coop_ghost_event_begin()
    if body then parts = retarget_event(c, body, true) end
    local before = tostring(safe(fsm.call, fsm, "getCurrentState(System.UInt32)", 0))
    local ok, err = pcall(fsm.call, fsm, "setCurrentState(System.String)", state)
    log(string.format("iuse %s: %s -> %s (%s)%s%s", key, before, state, item, parts > 0 and (", " .. parts .. " player part(s) on the friend's body") or "",
        ok and "" or (" ERR " .. tostring(err))))
    note(item == "ShadowPuzzle" and "your friend solved a puzzle: it's solved in your game too"
        or ("your friend used a key item (" .. item .. "): done in your game too"))
    ws.applied = ws.applied + 1
    return true
end
local function poll_iuse(now)
    for i = #ws.iuse_out, 1, -1 do
        local u = table.remove(ws.iuse_out, i)
        local sets = reaction_settings(u.c)
        local state
        for _, e in ipairs(sets) do if e.item == u.id and e.result == 0 then state = e.state end end
        local key = reaction_key(u.c)
        local why = reaction_private(u.c, u.id, sets)
        if state == nil or state == "" or key == nil then
            log("used " .. u.id .. ": no success state for it on " .. tostring(key))
        elseif why then
            log("used " .. u.id .. " on " .. key .. ": not shared (" .. why .. ")")
            -- A tape in the video deck: the friend's game follows us into it (coop_dummy, coop_follow_tape).
            if u.id:find("^FoundFootage") then send(string.format("tape %s %d", u.id, chapter())) end
        elseif not (settings and settings.share_item_gimmicks == false) then
            send(string.format("iuse %s %s %d %s", key, state, chapter(), u.id))
        end
    end
    if #ws.iuse_pending > 0 and now - (ws.iuse_pend_t or 0) > 2 then
        ws.iuse_pend_t = now
        local tried, i = {}, 1
        while i <= #ws.iuse_pending do            -- oldest first, one per gimmick per pass
            local e = ws.iuse_pending[i]
            local drop = now - e.t > 3600 or e.ch ~= chapter()
            if not drop and not tried[e.key] then
                tried[e.key] = true
                drop = apply_iuse(e.key, e.state, e.ch, e.item, true)
            end
            if drop then table.remove(ws.iuse_pending, i) else i = i + 1 end
        end
    end
end
-- Shadow puzzles (v0.48). The stand is an item gimmick like the others (the piece goes on with
-- SelectSuccess, shared above) and its state machine goes to "Open" when the shadow is matched. Tested
-- 2026-11-11 on the hall puzzle in a game that hadn't solved it: setCurrentState("Open") ran Open_state00
-- and settled in StateCheck_Open with the solved piece shown; the player wasn't touched. So the game
-- that solves it is watched for that change (twice a second) and the other gets the same "iuse" with
-- state Open. A change we made on the friend's word isn't sent back.
ws.puz_state = {}
local function poll_puzzles(now)
    if now - (ws.puz_t or 0) < 0.5 then return end
    ws.puz_t = now
    if settings and settings.share_item_gimmicks == false then return end
    local sc = scene()
    local arr = sc and find_comps(sc, "app.InteractShadowPuzzle")
    local done = {}
    for _, c in ipairs(elems(arr)) do
        local go = safe(c.call, c, "get_GameObject")
        local tr = go and safe(go.call, go, "get_Transform")
        local r
        for _ = 1, 4 do
            if tr == nil or r then break end
            local g = safe(tr.call, tr, "get_GameObject")
            r = g and safe(g.call, g, "getComponent(System.Type)", sdk.typeof("app.ItemSelectReaction"))
            tr = safe(tr.call, tr, "get_Parent")
        end
        local key = r and reaction_key(r)
        if key and not done[key] then
            done[key] = true
            local fo = safe(r.get_field, r, "FsmObj") or safe(r.call, r, "get_GameObject")
            local fsm = fo and safe(fo.call, fo, "getComponent(System.Type)", sdk.typeof("via.fsm.Fsm"))
            local st = fsm and tostring(safe(fsm.call, fsm, "getCurrentState(System.UInt32)", 0) or "") or ""
            local was = ws.puz_state[key]
            ws.puz_state[key] = st
            if was ~= nil and was ~= "" and was ~= "nil" and st:match("^Open") and not was:match("^Open")
                and not (ws.iuse_last[key] and now - ws.iuse_last[key] < 20) then
                log("puzzle " .. key .. ": solved here (" .. was .. " -> " .. st .. ")")
                send(string.format("iuse %s Open %d ShadowPuzzle", key, chapter()))
            end
        end
    end
end

-- The other puzzles (v0.48): the clock's hands, number locks, padlocks, the turning paintings, the
-- cardan grille, pushed blocks. Each is an InteractObjectBase of its own kind sitting under a gimmick
-- object with a state machine, like the shadow puzzle's stand, whose machine went to "Open" when solved.
-- Whether these use the same name isn't known (no save has one unsolved), so this goes by what is seen:
-- every change of such a gimmick's state is logged ("puzzle watch"), and a change INTO a state named
-- Open..., Clear..., Solved... or Success... is sent ("gstate <gimmick> <state> <chapter>"). The other
-- game sets that same state on the same gimmick if its machine has it and isn't there already, once it
-- is running (near the player), never during a scene. Nothing is sent for other names: the log from a
-- real session will show what they are.
local PUZZLE_TYPES = { "app.InteractClockPuzzle", "app.InteractNumberLock", "app.InteractPadlock",
    "app.InteractRotateArt", "app.InteractCardanGrille", "app.InteractPushMove" }
local function solved_name(st) return st:match("^Open") or st:match("^Clear") or st:match("^Solved") or st:match("^Success") end
ws.gim_state, ws.gim_pending, ws.gim_last = {}, {}, {}
local function gimmick_key(go)
    local tr = safe(go.call, go, "get_Transform")
    local p = tr and safe(tr.call, tr, "get_Position")
    if p == nil then return nil end
    local par = safe(tr.call, tr, "get_Parent")
    local pg = par and safe(par.call, par, "get_GameObject")
    local name = tostring(safe(go.call, go, "get_Name") or "") .. "<" .. tostring(pg and safe(pg.call, pg, "get_Name") or "")
    return string.format("%s@%.1f,%.1f,%.1f", (name:gsub("%s", "_")), p.x, p.y, p.z)
end
-- Every puzzle gimmick loaded: key -> its state machine.
local function puzzle_gimmicks()
    local out = {}
    local sc = scene()
    if sc == nil then return out end
    for _, tn in ipairs(PUZZLE_TYPES) do
        local arr = find_comps(sc, tn)
        for _, c in ipairs(elems(arr)) do
            local go = safe(c.call, c, "get_GameObject")
            local tr = go and safe(go.call, go, "get_Transform")
            for _ = 1, 4 do
                if tr == nil then break end
                local g = safe(tr.call, tr, "get_GameObject")
                local fsm = g and safe(g.call, g, "getComponent(System.Type)", sdk.typeof("via.fsm.Fsm"))
                if fsm then
                    local key = gimmick_key(g)
                    if key then out[key] = fsm end
                    break
                end
                tr = safe(tr.call, tr, "get_Parent")
            end
        end
    end
    return out
end
local function poll_gimmicks(now)
    if now - (ws.gim_t or 0) < 0.5 then return end
    ws.gim_t = now
    if settings and settings.share_item_gimmicks == false then return end
    local all = puzzle_gimmicks()
    local in_scene = local_cutscene and local_cutscene()
    for key, fsm in pairs(all) do
        local st = tostring(safe(fsm.call, fsm, "getCurrentState(System.UInt32)", 0) or "")
        local was = ws.gim_state[key]
        ws.gim_state[key] = st
        if was ~= nil and was ~= st and st ~= "" and st ~= "nil" and was ~= "" and was ~= "nil" then
            local ours = ws.gim_last[key] and now - ws.gim_last[key] < 20
            log(string.format("puzzle watch: %s %s -> %s%s", key, was, st, ours and " (on your friend's word)" or ""))
            if solved_name(st) and not solved_name(was) and not ours then
                send(string.format("gstate %s %s %d", key, st, chapter()))
            end
        end
        local pnd = ws.gim_pending[key]
        if pnd and pnd.ch == chapter() and not in_scene and st ~= "" and st ~= "nil" then
            ws.gim_pending[key] = nil
            if solved_name(st) then
                log("puzzle " .. key .. ": already solved here (" .. st .. ")")
            elseif safe(fsm.call, fsm, "hasState(System.String)", pnd.state) ~= true then
                log("puzzle " .. key .. ": no state " .. pnd.state .. " here")
            else
                ws.gim_last[key] = now
                local ok, err = pcall(fsm.call, fsm, "setCurrentState(System.String)", pnd.state)
                log(string.format("puzzle %s: %s -> %s (from the friend)%s", key, st, pnd.state, ok and "" or (" ERR " .. tostring(err))))
                note("your friend solved a puzzle: it's solved in your game too")
                ws.applied = ws.applied + 1
            end
        end
    end
    for key, pnd in pairs(ws.gim_pending) do
        if pnd.ch ~= chapter() or now - pnd.t > 3600 then ws.gim_pending[key] = nil end
    end
end
local function apply_gstate(key, state, ch)
    if ch ~= chapter() or not solved_name(state) then return end
    if settings and settings.share_item_gimmicks == false then return end
    ws.gim_pending[key] = { state = state, ch = ch, t = os.clock() }
    log("puzzle " .. key .. ": your friend solved it (" .. state .. "); done here when it's loaded and you're free")
end

-- The morgue's tray incinerators, "the cremator puzzle" (v0.48). Five trays (sm1750_MoldedTray01A_EnemyTray01-05)
-- each toggle between OpenEnd and CloseEnd when used, and the key tray (ItemTray) unlocks once the right ones
-- are shut. They went out as one-off "intr" (sent the first time only, and lost if the morgue wasn't loaded
-- in the other game), so a tray shut and opened again, or one used before the friend got there, left the
-- two games with different trays shut: the friend got the key and the puzzle was still locked for the
-- other player (2026-11-11; the bot test reproduced it: copy 0 locked, copy 1 unlocked). Now each tray's
-- state is sent when it changes ("tray <name> <state> <chapter>", kept for the catch-up), and the other
-- game uses its own tray until it matches, when the morgue is loaded and no scene is playing.
local TRAY_PAT = "^sm1750_MoldedTray01A_EnemyTray%d+$"
ws.tray_state, ws.tray_ours = {}, {}
ws.tray_want = ws.tray_want or {}
local function tray_end(st) return st == "OpenEnd" or st == "CloseEnd" end
local function tray_list(now)
    if ws.tray_cache and now - ws.tray_cache_t < 3 then return ws.tray_cache end
    local out = {}
    local sc = scene()
    for _, c in ipairs(elems(sc and find_comps(sc, "app.InteractSendFsm"))) do
        local go = safe(c.call, c, "get_GameObject")
        local tr = go and safe(go.call, go, "get_Transform")
        local par = tr and safe(tr.call, tr, "get_Parent")
        local pg = par and safe(par.call, par, "get_GameObject")
        local name = pg and tostring(safe(pg.call, pg, "get_Name") or "") or ""
        if name:match(TRAY_PAT) then
            local fsm = safe(pg.call, pg, "getComponent(System.Type)", sdk.typeof("via.fsm.Fsm"))
            if fsm then out[name] = { fsm = fsm, isf = c } end
        end
    end
    ws.tray_cache, ws.tray_cache_t = out, now
    return out
end
local function poll_trays(now)
    if now - (ws.tray_t or 0) < 0.5 then return end
    ws.tray_t = now
    if not interactions_shared() then return end
    local in_scene = local_cutscene and local_cutscene()
    for name, t in pairs(tray_list(now)) do
        local st = tostring(safe(t.fsm.call, t.fsm, "getCurrentState(System.UInt32)", 0) or "")
        if st == "" or st == "nil" then
            ws.tray_cache = nil   -- unloaded: look again
        else
            local was = ws.tray_state[name]
            ws.tray_state[name] = st
            if was and was ~= st and tray_end(st) then
                local ours = ws.tray_ours[name] and now - ws.tray_ours[name] < 6
                log(string.format("tray %s: %s -> %s%s", name, was, st, ours and " (on your friend's word)" or ""))
                if not ours then send(string.format("tray %s %s %d", name, st, chapter())) end
            end
            local w = ws.tray_want[name]
            if w and w.ch == chapter() and not in_scene and tray_end(st) then
                if st == w.state then
                    ws.tray_want[name] = nil
                elseif now >= (w.next_t or 0) then
                    if (w.tries or 0) >= 3 then
                        log("tray " .. name .. ": still " .. st .. " after 3 tries (the friend's is " .. w.state .. "), left as it is")
                        ws.tray_want[name] = nil
                    else
                        w.tries, w.next_t = (w.tries or 0) + 1, now + 4
                        ws.tray_ours[name] = now
                        local ok, err = pcall(t.isf.call, t.isf, "successInteract")
                        log(string.format("tray %s: %s -> %s like the friend's%s", name, st, w.state, ok and "" or (" ERR " .. tostring(err))))
                        if w.tries == 1 then note("your friend worked an incinerator tray: it's the same in your game") end
                        ws.applied = ws.applied + 1
                    end
                end
            end
        end
    end
    for name, w in pairs(ws.tray_want) do if w.ch ~= chapter() then ws.tray_want[name] = nil end end
end
local function apply_tray(name, state, ch)
    if ch ~= chapter() or not name:match(TRAY_PAT) or not tray_end(state) then return end
    if not interactions_shared() then return end
    ws.tray_want[name] = { state = state, ch = ch }
    if ws.tray_state[name] == nil then log("tray " .. name .. " " .. state .. ": the morgue isn't loaded here, done when it is") end
end

-- Body-bag kicks in the morgue fight (v0.48). A hanging bag (sm1684_Corpsebag_Battle) has a child
-- sm1684_Corpsebag_Kick with app.Em8000.Em8000CorpsebagInteract: setInteract(kicker) runs a 1.2 s event
-- (the kicker's kick, clip pl0000_Hands_Kick) and throws the bag on its chain. Each game ran its own
-- bags, so a kick moved nothing on the other screen. Now our kick is noticed (our player's event task
-- is owned by a bag's kick object) and sent as "kick <x> <y> <z> <chapter>"; the other game runs the
-- same bag's setInteract with our body there as the kicker. Tested 2026-11-11 between two copies: the
-- bag swung 2.6 m in both, the other player wasn't moved or put in the animation.
ws.kick = { on = false }
local function kick_type() return sdk.find_type_definition("app.Em8000.Em8000CorpsebagInteract") end
local function poll_kicks(now)
    if kick_type() == nil then return end
    local om = sdk.get_managed_singleton("app.ObjectManager")
    local p = om and om:get_field("PlayerObj")
    local eac = p and safe(p.call, p, "getComponent(System.Type)", sdk.typeof("app.EventActionController"))
    local on, owner = false, nil
    if eac and safe(eac.call, eac, "get_isActive") == true then
        owner = safe(eac.call, eac, "get_activeOwnerObj")
        on = owner ~= nil and safe(owner.call, owner, "getComponent(System.Type)", sdk.typeof("app.Em8000.Em8000CorpsebagInteract")) ~= nil
    end
    if on and not ws.kick.on and not (settings and settings.share_interactions == false) then
        local tr = safe(owner.call, owner, "get_Transform")
        local pos = tr and safe(tr.call, tr, "get_Position")
        if pos then send(string.format("kick %.1f %.1f %.1f %d", pos.x, pos.y, pos.z, chapter())) end
    end
    ws.kick.on = on
    -- A bag's kicker is pointed back at the player once the friend's kick is over.
    if ws.kick.back and now >= ws.kick.back.t then
        pcall(ws.kick.back.gea.set_field, ws.kick.back.gea, "SetTargetObj", nil)
        pcall(ws.kick.back.gea.set_field, ws.kick.back.gea, "TargetObjTemp", nil)
        ws.kick.back = nil
    end
end
local function apply_kick(x, y, z, ch)
    if ch ~= chapter() or kick_type() == nil then return end
    if settings and (settings.share_interactions == false or settings.intr_pull_me == true) then return end
    local sc = scene()
    local arr = sc and find_comps(sc, "app.Em8000.Em8000CorpsebagInteract")
    local best, bd
    for _, c in ipairs(elems(arr)) do
        local go = safe(c.call, c, "get_GameObject")
        local tr = go and safe(go.call, go, "get_Transform")
        local pos = tr and safe(tr.call, tr, "get_Position")
        if pos then
            local d = (pos.x - x) ^ 2 + (pos.y - y) ^ 2 + (pos.z - z) ^ 2
            if bd == nil or d < bd then best, bd = c, d end
        end
    end
    if best == nil or bd > 0.25 then log(string.format("kick at %.1f %.1f %.1f: no such bag loaded here", x, y, z)) return end
    local body = coop_ghost_event_begin and coop_ghost_event_begin()
    if body == nil then log("kick: no friend's body yet") return end
    local gea = safe(best.get_field, best, "GameEventAction")
    if gea then
        pcall(gea.set_field, gea, "SetTargetObj", body)
        pcall(gea.set_field, gea, "TargetObjTemp", body)
        ws.kick.back = { gea = gea, t = os.clock() + 3 }
    end
    local ok, err = pcall(best.call, best, "setInteract", body)
    log(string.format("your friend kicked the bag at %.1f %.1f %.1f%s", x, y, z, ok and "" or (" ERR " .. tostring(err))))
    ws.applied = ws.applied + 1
end

coop_world_iuse_test = function(c, item) ws.iuse_out[#ws.iuse_out + 1] = { c = c, id = item, t = os.clock() } end   -- bot tests

local function poll_used(now)
    pcall(poll_iuse, now)
    pcall(poll_puzzles, now)
    pcall(poll_gimmicks, now)
    pcall(poll_trays, now)
    pcall(poll_kicks, now)
    for id, u in pairs(ws.used) do
        if now - u.t > 600 or chapter() ~= u.ch then ws.used[id] = nil end
    end
    ws.kused = {}
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
    -- Stacks we already have first (v0.44): no new object for what fits in them.
    local before0 = inv_count(inv, id)
    local list = safe(inv.get_field, inv, "_ItemList")
    local left = n
    for i = 0, (list and (safe(list.call, list, "get_Count") or 0) or 0) - 1 do
        if left <= 0 then break end
        local info = safe(list.call, list, "get_Item", i)
        local it = info and safe(info.get_field, info, "Item")
        if it and tostring(safe(it.get_field, it, "ItemDataID")) == id then
            local cur = tonumber(safe(it.call, it, "getStackNum")) or 0
            local max = tonumber(safe(it.call, it, "getMaxStackNum")) or 0
            local add = math.min(left, max - cur)
            if add > 0 and pcall(it.call, it, "setStackNum(System.Int32)", cur + add) then left = left - add end
        end
    end
    if left <= 0 or left < n then
        local topped = inv_count(inv, id) - before0
        if left <= 0 or topped <= 0 then return math.max(0, topped), topped > 0 and "ok" or "it didn't go in" end
        return topped, "ok"   -- the rest comes in the caller's next round (a new slot)
    end
    local td = sdk.find_type_definition("app.ItemManager")
    local m = td and td:get_method("createItemInstance(via.GameObject, System.String)")
    local go = (m and player) and safe(m.call, m, nil, player, id) or nil
    local item = go and safe(go.call, go, "getComponent(System.Type)", sdk.typeof("app.Item"))
    if item == nil then return 0, "couldn't make " .. id end
    if n > 1 then pcall(item.call, item, "setStackNum(System.Int32)", n) end
    local before = inv_count(inv, id)
    local ok, res = pcall(inv.call, inv, "addItem(app.Item, via.GameObject)", item, go)
    local got = inv_count(inv, id) - before
    if ok and tonumber(res) == 1 or tonumber(res) == 2 then
        log("give: " .. id .. " merged into a stack as a new object (result " .. tostring(res) .. ")")
    end
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
    local udp = st and st.kv and st.kv.mode == "udp"
    if not ((me ~= nil and to == me) or (udp and to == "0")) then return end   -- for someone else ("0": the udp friend)
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

-- Discarding an item drops it for your friend too (v0.51) -----------------------------------------
-- Discard an item in the inventory menu (app.InventoryMenu.discardItem) and it is gone from your
-- inventory. Now it also lands on the ground in front of you, and on your friend's ground at the same
-- spot, where each of you picks up your own copy with the game's own pickup:
--   drop <token> <item> <n> <x> <y> <z> <chapter>   ours: n of <item> were put down here
--   dropok <token>                                   theirs: it is on the ground here too
--   dropno <token> <why>                             theirs: it couldn't be put down (why)
-- Evidence (an earlier co-op mod's real sessions, v0.51 port): drops of Herb, HandgunBullet and
-- ShotgunBullet made with ItemManager.createDropItemInstance(player, id, n) appeared on the floor, stayed
-- alive and could be picked up. The same mod crashed the game every time it made an item for an
-- inventory (createItemInstance + addItem) and when it took a whole entry out with reduceItem, so this
-- never does either: the hook only watches (the game itself removed the discarded item), nothing is
-- created in or taken out of anyone's inventory, and every call is inside pcall. App.Item.reduceNum is
-- no trigger: moving to the item box, crafting and using call it too. Only supplies are dropped: key
-- items, weapons, files and coins are each player's own (a weapon pickup can start a scene).
-- Not seen in this mod's own real sessions yet: say so in the pull request.
do
    local DROP_RANGE = 30.0                       -- metres: farther than this the other area isn't loaded here
    local DROP_FORWARD, DROP_UP = 0.8, 0.1        -- where our own copy lands, from our feet
    ws.drop_pre, ws.drop_q, ws.drop_out, ws.drop_seen, ws.drop_last = nil, {}, {}, {}, {}
    ws.drops = { sent = 0, shown = 0, failed = 0, refused = 0 }

    local function drop_on() return not (settings and settings.drop_on_discard == false) end

    -- A friend (or the test bot) is really there: alone, a discard stays the game's own discard.
    local function friend_linked()
        local st = coop_net_state and coop_net_state()
        local k = st and st.kv
        if not (k and coop_link_any and coop_link_any(k)) then return false end
        if k.mode == "bot" then return true end
        return k.peer ~= nil and k.peer ~= "-" and k.peer ~= "steam:0"
    end

    local function droppable(id)
        local cat = item_category(id)
        return cat ~= nil and not KEYISH[cat]
    end

    local function item_text(id) return (coop_item_name and safe(coop_item_name, id)) or id end

    local function player_pose()
        local om = sdk.get_managed_singleton("app.ObjectManager")
        local go = om and safe(om.get_field, om, "PlayerObj")
        local tr = go and safe(go.call, go, "get_Transform")
        local p = tr and safe(tr.call, tr, "get_Position")
        if p == nil then return nil end
        return go, p, safe(tr.call, tr, "get_Rotation")
    end

    -- Makes the world item (the game's own call for what drawers and boxes drop) and puts it at x y z, or
    -- in front of our feet when there is no position. Returns true and where it ended up, or nil and why.
    local function spawn_world_item(id, n, x, y, z)
        local go, p, q = player_pose()
        if go == nil then return nil, "no_player" end
        if x == nil then
            local fx, fz = 0, 1
            if q and q.x and q.y and q.z and q.w then
                fx, fz = 2 * (q.x * q.z + q.w * q.y), 1 - 2 * (q.x * q.x + q.y * q.y)
            end
            local len = math.sqrt(fx * fx + fz * fz)
            if len < 1e-6 then fx, fz, len = 0, 1, 1 end
            x, y, z = p.x + fx / len * DROP_FORWARD, p.y + DROP_UP, p.z + fz / len * DROP_FORWARD
        end
        local td = sdk.find_type_definition("app.ItemManager")
        local m = td and td:get_method("createDropItemInstance(via.GameObject, System.String, System.Int32)")
        if m == nil then return nil, "no_drop_call" end
        -- The owner is always the player's own GameObject, never an item's object (a suspected crash).
        -- The name as a plain string first, then as a managed one.
        local obj = safe(m.call, m, nil, go, id, n)
        if obj == nil then
            local ms = sdk.create_managed_string and safe(sdk.create_managed_string, id)
            obj = ms and safe(m.call, m, nil, go, ms, n) or nil
        end
        if obj == nil then return nil, "no_object" end
        -- Made as the player's child, at the player's position: let go of the player, then move it
        -- (set_Position doesn't stick while parented: the box drops in coop_world did the same).
        local tr = safe(obj.call, obj, "get_Transform")
        if tr then
            pcall(tr.call, tr, "set_Parent", nil)
            pcall(tr.call, tr, "set_Position", Vector3f.new(x, y, z))
        end
        pcall(obj.call, obj, "set_DrawSelf", true)
        pcall(obj.call, obj, "set_UpdateSelf", true)
        -- An item nobody can see counts as a failure.
        if safe(obj.call, obj, "get_Draw") ~= true then return nil, "not_drawn" end
        return true, x, y, z
    end

    -- The discard hook: it only watches. Pre reads the item's name and count (fields only: nothing is
    -- called in the middle of the game's own discard); post reads whether it went through.
    local function queue_drop(id, n)
        if not (drop_on() and friend_linked()) then return end
        n = math.max(1, math.min(999, math.floor(tonumber(n) or 1)))
        local key, now = id .. ":" .. n, os.clock()
        if ws.drop_last[key] and now - ws.drop_last[key] < 3 then return end   -- the same discard seen twice
        ws.drop_last[key] = now
        ws.drop_q[#ws.drop_q + 1] = { id = id, n = n, t = now }
    end
    do
        local td = sdk.find_type_definition("app.InventoryMenu")
        local m = td and td:get_method("discardItem(app.Item)")
        if m then
            pcall(sdk.hook, m, function(args)
                ws.drop_pre = nil
                pcall(function()
                    local it = sdk.to_managed_object(args[3])
                    local id = it and tostring(safe(it.get_field, it, "ItemDataID") or "")
                    if id and id:match("^[%w_]+$") then
                        ws.drop_pre = { id = id, n = tonumber(safe(it.get_field, it, "ItemStackNum")) or 1 }
                    end
                end)
            end, function(r)
                pcall(function()
                    local d = ws.drop_pre
                    ws.drop_pre = nil
                    if d and (sdk.to_int64(r) & 0xFF) ~= 0 then queue_drop(d.id, d.n) end
                end)
                return r
            end)
        end
        log("discard drop: app.InventoryMenu.discardItem " .. (m and "hooked" or "not found (discards stay the game's own)"))
    end

    -- Ours: 0.2 s after the discard (not inside the game's own call), put it down here, then tell them.
    local function do_drop(d, now)
        if not droppable(d.id) then
            log("discard of " .. d.id .. " not dropped: key items, weapons and files are each player's own")
            return
        end
        local ok, x, y, z = spawn_world_item(d.id, d.n)
        if not ok then
            ws.drops.failed = ws.drops.failed + 1
            log(string.format("discard of %s x%d: couldn't put it on the ground here (%s); it is gone as in the normal game", d.id, d.n, tostring(x)))
            return
        end
        local token = string.format("%x%04x", os.time() % 0x10000000, math.random(0, 0xFFFF))
        ws.drop_out[token] = { id = d.id, n = d.n, t = now }
        ws.drops.sent = ws.drops.sent + 1
        send(string.format("drop %s %s %d %.2f %.2f %.2f %d", token, d.id, d.n, x, y, z, chapter()))
    end

    re.on_frame(function()
        if #ws.drop_q == 0 and next(ws.drop_out) == nil then return end
        local now = os.clock()
        local i = 1
        while i <= #ws.drop_q do
            local d = ws.drop_q[i]
            if now - d.t >= 0.2 then
                table.remove(ws.drop_q, i)
                local ok, err = pcall(do_drop, d, now)
                if not ok then log("discard drop ERR " .. tostring(err)) end
            else
                i = i + 1
            end
        end
        for token, o in pairs(ws.drop_out) do
            if now - o.t > 10 then
                ws.drop_out[token] = nil
                note(string.format("your friend's game didn't answer: they may not see the %s you dropped", item_text(o.id)))
            end
        end
    end)

    -- Theirs: only a well-formed message does anything, and every check is ours (an older or changed
    -- copy of the script may skip its own).
    local function on_drop(token, id, n, x, y, z, ch)
        if ws.drop_seen[token] then return end
        ws.drop_seen[token] = true
        if n < 1 or n > 999 then return end
        local function no(why)
            ws.drops.refused = ws.drops.refused + 1
            log(string.format("friend's drop of %s x%d not put down: %s", id, n, why))
            send("dropno " .. token .. " " .. why)
        end
        if not drop_on() then return no("switched_off") end
        if ch ~= chapter() then return no("other_chapter") end
        if not droppable(id) then return no("not_shared") end
        local _, p = player_pose()
        if p == nil then return no("not_playing") end
        local dx, dy, dz = p.x - x, p.y - y, p.z - z
        if dx * dx + dy * dy + dz * dz > DROP_RANGE * DROP_RANGE then return no("too_far") end
        local ok, why = spawn_world_item(id, n, x, y, z)
        if not ok then
            ws.drops.failed = ws.drops.failed + 1
            return no(tostring(why))
        end
        ws.drops.shown = ws.drops.shown + 1
        log(string.format("friend's drop: %s x%d put down at %.1f %.1f %.1f", id, n, x, y, z))
        send("dropok " .. token)
        note(string.format("%s dropped %s x%d: it is on the ground here too",
            coop_event_slot and coop_event_slot > 1 and ("Friend " .. coop_event_slot) or "Your friend", item_text(id), n))
    end

    local function on_drop_reply(token, ok, why)
        local o = ws.drop_out[token]
        if o == nil then return end   -- not ours, or answered already
        ws.drop_out[token] = nil
        if ok then return end
        local text = tostring(why or "?"):gsub("_", " ")
        local reasons = { ["too far"] = "is too far away to see it", ["other chapter"] = "is in another part of the game",
            ["switched off"] = "has dropping discarded items switched off", ["not shared"] = "can't share that kind of item" }
        note(string.format("your friend %s: the %s you dropped is only on your ground", reasons[text] or ("couldn't see it (" .. text .. ")"), item_text(o.id)))
    end

    -- Called from coop_world_on_event: true when the text is one of ours (even a malformed one).
    function coop_drop_event(text)
        local tok, id, n, x, y, z, ch = text:match("^drop (%x+) ([%w_]+) (%d+) (%-?[%d%.]+) (%-?[%d%.]+) (%-?[%d%.]+) (%-?%d+)$")
        if tok then
            pcall(on_drop, tok, id, tonumber(n), tonumber(x), tonumber(y), tonumber(z), tonumber(ch))
            return true
        end
        local okt = text:match("^dropok (%x+)$")
        if okt then pcall(on_drop_reply, okt, true) return true end
        local not_, why = text:match("^dropno (%x+) (%S+)$")
        if not_ then pcall(on_drop_reply, not_, false, why) return true end
        return text:find("^drop ") ~= nil or text:find("^dropok ") ~= nil or text:find("^dropno ") ~= nil
    end
end

function coop_world_on_event(text)
    if text:find("^drop") and coop_drop_event(text) then return true end
    local gt, gto, gid, gn = text:match("^give (%x+) (%d+) (%S+) (%d+)$")
    if gt then pcall(on_give, gt, gto, gid, tonumber(gn)) return true end
    local okt, okn = text:match("^give_ok (%x+) (%d+)$")
    if okt then pcall(on_give_reply, okt, true, okn) return true end
    local nt, nwhy = text:match("^give_no (%x+) (%S+)$")
    if nt then pcall(on_give_reply, nt, false, nwhy) return true end
    local kx, ky, kz, kch = text:match("^kick (%-?[%d%.]+) (%-?[%d%.]+) (%-?[%d%.]+) (%-?%d+)$")
    if kx then pcall(apply_kick, tonumber(kx), tonumber(ky), tonumber(kz), tonumber(kch)) return true end
    local gkey, gst, gch = text:match("^gstate (%S+) (%S+) (%-?%d+)$")
    if gkey then pcall(apply_gstate, gkey, gst, tonumber(gch)) return true end
    local tname, tst, tch = text:match("^tray (%S+) (%S+) (%-?%d+)$")
    if tname then pcall(apply_tray, tname, tst, tonumber(tch)) return true end
    local titem, tch = text:match("^tape (%S+) (%-?%d+)$")
    if titem then
        if coop_follow_tape then pcall(coop_follow_tape, titem, tonumber(tch)) end
        return true
    end
    local ukey, ustate, uch, uitem = text:match("^iuse (%S+) (%S+) (%-?%d+) (%S+)$")
    if ukey then pcall(apply_iuse, ukey, ustate, tonumber(uch), uitem) return true end
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
