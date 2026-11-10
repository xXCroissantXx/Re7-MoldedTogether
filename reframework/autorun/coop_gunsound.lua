-- coop_gunsound.lua: the friend's gunshots are heard and seen (bang, muzzle flash, smoke), and
-- their melee swings are heard (coop-re7 v0.28).
--
-- RE7 plays every sound from native code, so a shot can't be copied by catching the sound. What
-- was found instead (live research, 2026-11-04, notes in NOTES.md):
--   * each weapon's WwiseContainer (on the weapon object under the player) holds its sound files,
--     about 20 paths (Sound/Resource/snd_container/snd_container_wp1010.wcc, the event list, the
--     switch files, impact banks) readable with getContainableAsset(i):get_ResourcePath();
--   * a shot is one trigger on that container; for the handgun the bang is trigger 3908091806
--     (found with a native recorder in the test copy only, confirmed by ear);
--   * a new GameObject made in the player's folder with a via.wwise.WwiseContainer holding the same
--     files (sdk.create_resource + create_holder), switched off and on and given awake() and
--     start(), knows the trigger and plays it at any position, whatever the local player holds.
--
-- Flash and smoke (live, 2026-11-04): the gun's app.EPVExpertMuzzleFlush / app.EPVExpertGunSmoke
-- (whose play() froze the game when called from a script) keep their effects in
-- DataList[0].Elements, one per gun type (TargetID Handgun, ShotGun, Magnum, GrenadeLauncher...),
-- each with getResources(0) -> an .efx path (VFX/VFX_Resource/.../vfx_efd_capcom_muzzle_00_000_0000.efx).
-- A new object with a via.effect.EffectPlayer whose resource is loaded by that path
-- (sdk.create_resource("via.effect.EffectResource", path):create_holder(...)) plays it with
-- set_Action(1) (Start; 2 = Kill first to restart it). Sent once per weapon as "gfx <weapon>
-- <flash path> <smoke path>".
--
-- Our side: each shot of our own held gun (its EPVExpertGunSmoke.play, a scriptable call that
-- runs once per shot) sends "gshot <weapon>"; the first time per weapon also "gsnd <weapon>
-- <path;path;...>". Their side: one sound object per weapon, built from those paths, moved to
-- the friend's hand and triggered with that weapon's bang. Weapons without a known bang yet are
-- logged ("no shot sound known") so the next research round can add them.

-- Every weapon's sounds (v0.41). A trigger id is the MurmurHash3 (seed 0xFFFFFFFF) of the
-- trigger's name in UTF-16: worked out 2026-11-09 from the names the game lists per sound file
-- (app.wwise.TRIGGER_SND_EVENTLIST_WP1010 and the rest, in the type dump) and the two ids found
-- by ear before. SND_DF_WP_SE_SHOT is 3908091806, the handgun bang; SND_DF_WP_SE_CUTTING is
-- 1824153269, the knife whoosh. Every gun's list has SND_DF_WP_SE_SHOT (wp1000-wp1380: handguns,
-- shotguns, magnum, grenade launcher, machine gun...) and every blade's SND_DF_WP_SE_CUTTING
-- (knife, axe...), so each weapon's own sound plays from its own files. Sent as "gshot",
-- "gswing" and "greload <weapon>".
local TRIGGERS = {
    shot = 3908091806,     -- SND_DF_WP_SE_SHOT
    swing = 1824153269,    -- SND_DF_WP_SE_CUTTING
    reload = 3551833905,   -- SND_DF_WP_SE_RELOAD
}
local TRIGGER_NAMES = { shot = "SND_DF_WP_SE_SHOT", swing = "SND_DF_WP_SE_CUTTING", reload = "SND_DF_WP_SE_RELOAD" }
local function trigger_for(key, kind) return TRIGGERS[kind] end

-- MurmurHash3 x86 32 of a name in UTF-16 (ASCII names), seed 0xFFFFFFFF: how RE7 names sounds.
function coop_sound_id(name)
    local M = 0xFFFFFFFF
    local function rotl(x, r) return ((x << r) | (x >> (32 - r))) & M end
    local bytes = {}
    for i = 1, #name do bytes[#bytes + 1] = name:byte(i) bytes[#bytes + 1] = 0 end
    local h, n = 0xFFFFFFFF, #bytes
    local c1, c2 = 0xcc9e2d51, 0x1b873593
    local i = 1
    while i + 3 <= n do
        local k = bytes[i] | (bytes[i + 1] << 8) | (bytes[i + 2] << 16) | (bytes[i + 3] << 24)
        k = (k * c1) & M; k = rotl(k, 15); k = (k * c2) & M
        h = h ~ k; h = rotl(h, 13); h = (h * 5 + 0xe6546b64) & M
        i = i + 4
    end
    local k, rest = 0, n - i + 1
    if rest >= 3 then k = k ~ (bytes[i + 2] << 16) end
    if rest >= 2 then k = k ~ (bytes[i + 1] << 8) end
    if rest >= 1 then
        k = k ~ bytes[i]
        k = (k * c1) & M; k = rotl(k, 15); k = (k * c2) & M
        h = h ~ k
    end
    h = h ~ n
    h = h ~ (h >> 16); h = (h * 0x85ebca6b) & M
    h = h ~ (h >> 13); h = (h * 0xc2b2ae35) & M
    h = h ~ (h >> 16)
    return h
end

-- A stand-in for a gun whose own files don't know the shot (none expected, but just in case): the
-- handgun's bang from the handgun's own files (their paths, as the G17 sends them, 2026-11-08).
local STANDIN_PATHS = {
    "Sound/Resource/snd_container/snd_container_wp1010.wcc", "Sound/Resource/snd_eventlist_wp1010.wel",
    "Sound/Resource/snd_SWITCH/snd_SWITCH_MT_TYPE_WP.wcmsw", "Sound/Resource/snd_SWITCH/snd_SWITCH_WP_CHARACTER_TYPE.wcsw",
    "Sound/Resource/snd_SWITCH/snd_SWITCH_WP_BULLET_CUSTOM.wcsw",
}

local gs = { sent_paths = {}, paths = {}, parts = {}, pending = 0, swings = 0, reloads = 0, missing = {}, fx = {}, fxparts = {},
    early = {}, shoots = 0 }
coop_gunsound = gs
gs.paths.standin = STANDIN_PATHS

local log_buf, log_t = {}, 0
local function log(s) log_buf[#log_buf + 1] = os.date("%H:%M:%S ") .. tostring(s) end
re.on_frame(function()
    if #log_buf == 0 or os.clock() - log_t < 1 then return end
    log_t = os.clock()
    local f = fs.read("coop_gunsound_log.txt") or ""
    if #f > 100000 then f = f:sub(-50000) end
    fs.write("coop_gunsound_log.txt", f .. table.concat(log_buf, "\n") .. "\n")
    log_buf = {}
end)

local function safe(f, ...)
    local ok, r = pcall(f, ...)
    if ok then return r end
    return nil
end

-- "Weapon/wp1210_Handgun/wp1210_Handgun ..." -> "wp1210"
local function weapon_key(w) return w and tostring(w):match("(wp%d%d%d%d)") or nil end

local function container_of(go)
    for _, c in ipairs(safe(function() return go:call("get_Components"):get_elements() end) or {}) do
        if c:get_type_definition():is_a("via.wwise.WwiseContainer") then return c end
    end
    return nil
end

-- Our side -----------------------------------------------------------------------------
-- Which element of the gun's effect lists is this gun: from its object name.
local function target_id(name)
    name = tostring(name)
    if name:find("Albert") then return "Handgun_Albert" end
    if name:find("Shotgun") or name:find("ShotGun") then return "ShotGun" end
    if name:find("Magnum") then return "Magnum" end
    if name:find("Grenade") then return "GrenadeLauncher" end
    if name:find("MachineGun") then return "MachineGun" end
    return "Handgun"
end
function effect_path(go, comp_type)
    local c = safe(go.call, go, "getComponent(System.Type)", sdk.typeof(comp_type))
    local dl = c and safe(c.get_field, c, "DataList")
    local d = dl and safe(dl.call, dl, "get_Item", 0)
    local els = d and safe(d.get_field, d, "Elements")
    local want, first = target_id(go:call("get_Name")), nil
    for i = 0, (els and safe(els.call, els, "get_Count") or 0) - 1 do
        local el = els:call("get_Item", i)
        local h = safe(el.call, el, "getResources", 0)
        local path = h and safe(h.call, h, "get_ResourcePath")
        if path then
            if tostring(safe(el.get_field, el, "TargetID")) == want then return tostring(path) end
            first = first or tostring(path)
        end
    end
    return first
end
do
    local m = sdk.find_type_definition("app.EPVExpertGunSmoke")
    m = m and m:get_method("play")
    if m then
        sdk.hook(m, function(args)
            pcall(function()
                local smoke = sdk.to_managed_object(args[2])
                local go = smoke and smoke:call("get_GameObject")
                if go and held and held.local_go and go:get_address() == held.local_go:get_address() then
                    gs.pending = gs.pending + 1
                end
            end)
        end, function(r) return r end)
    end
end

-- Also app.WeaponGun.shoot (v0.41), for a gun with no smoke, and app.WeaponGun.reload: our held
-- gun only. A shot seen by both in the same frame counts once (the larger count wins).
do
    local td = sdk.find_type_definition("app.WeaponGun")
    local function ours(args)
        local w = sdk.to_managed_object(args[2])
        local go = w and w:call("get_GameObject")
        return go and held and held.local_go and go:get_address() == held.local_go:get_address()
    end
    for _, name in ipairs({ "shoot(via.Ray, System.Boolean, System.Boolean)" }) do
        local m = td and td:get_method(name)
        if m then pcall(sdk.hook, m, function(args) pcall(function() if ours(args) then gs.shoots = gs.shoots + 1 end end) end,
            function(r) return r end) end
    end
    for _, name in ipairs({ "reload(app.Inventory)", "reload(app.Inventory, System.Int32)" }) do
        local m = td and td:get_method(name)
        if m then pcall(sdk.hook, m, function(args) pcall(function() if ours(args) then gs.reloads = gs.reloads + 1 end end) end,
            function(r) return r end) end
    end
end

-- The weapon's sound files (and, for a gun, its flash and smoke), once per weapon.
local function send_files(go, key, gun)
    if gs.sent_paths[key] then return end
    local c = container_of(go)
    local paths = {}
    for i = 0, (c and c:call("getContainableAssetCount") or 0) - 1 do
        local h = c:call("getContainableAsset", i)
        local p = h and safe(h.call, h, "get_ResourcePath")
        if p and p ~= "" then paths[#paths + 1] = tostring(p) end
    end
    if #paths > 0 then
        coop_send_event("gsnd " .. key .. " " .. table.concat(paths, ";"))
        gs.sent_paths[key] = true
        log("sent the sound files of " .. key .. " (" .. #paths .. ")")
    end
    if gun then
        local fl, sm = effect_path(go, "app.EPVExpertMuzzleFlush"), effect_path(go, "app.EPVExpertGunSmoke")
        coop_send_event(string.format("gfx %s %s %s", key, fl or "-", sm or "-"))
        log(string.format("sent the flash and smoke of %s: %s, %s", key, tostring(fl), tostring(sm)))
    end
end

-- Melee swings: the held weapon's app.Weapon.IsAttacking turning on, for weapons without gun smoke.
local swing = { was = false }
re.on_frame(function()
    local go = held and held.local_go
    if go == nil then swing.was = false return end
    local w = safe(go.call, go, "getComponent(System.Type)", sdk.typeof("app.Weapon"))
    local att = w and safe(w.get_field, w, "IsAttacking") == true
    if att and not swing.was and safe(go.call, go, "getComponent(System.Type)", sdk.typeof("app.EPVExpertGunSmoke")) == nil then
        gs.swings = gs.swings + 1
    end
    swing.was = att and true or false
end)

re.on_frame(function()
    if (gs.pending == 0 and gs.swings == 0 and gs.shoots == 0 and gs.reloads == 0) or not coop_send_event then return end
    local n, sw, rl = math.max(gs.pending, gs.shoots), gs.swings, gs.reloads
    gs.pending, gs.swings, gs.shoots, gs.reloads = 0, 0, 0, 0
    pcall(function()
        local go = held and held.local_go
        local key = go and weapon_key(go:call("get_Name"))
        if key == nil then return end
        send_files(go, key, n > 0)
        for _ = 1, math.min(n, 3) do coop_send_event("gshot " .. key) end
        if n > 0 and coop_stat then pcall(coop_stat, "shots", n) end
        for _ = 1, math.min(sw, 2) do coop_send_event("gswing " .. key) end
        if rl > 0 then coop_send_event("greload " .. key) end
    end)
end)
-- Resend the paths after a reconnect (the friend may have restarted).
function coop_gunsound_reset_sent() gs.sent_paths = {} end

-- Their side ---------------------------------------------------------------------------
local function friend_hand(slot)
    -- The weapon copy's position plus a little along its forward axis (about the muzzle), on
    -- the character of the friend who shot (v0.29: friends 2-3 have their own).
    local env = coop_slot_envs and coop_slot_envs[slot or 1] or _G
    local h = rawget(env, "held") or held
    local part = h and h.part
    local tr = part and safe(part.call, part, "get_Transform")
    local p = tr and safe(tr.call, tr, "get_Position")
    if p then
        local fwd = safe(tr.call, tr, "get_AxisZ")
        if fwd then return Vector3f.new(p.x + fwd.x * 0.2, p.y + fwd.y * 0.2, p.z + fwd.z * 0.2) end
        return p
    end
    local ghost_fn = rawget(env, "coop_ghost") or coop_ghost
    local g = ghost_fn and ghost_fn()
    local gp = g and safe(function() return g:call("get_Transform"):call("get_Position") end)
    if gp then return Vector3f.new(gp.x, gp.y + 1.4, gp.z) end
    return nil
end

-- The friend's character, as the source of their sounds (v0.29). With several friends firing
-- at once, one shared sound object played only one of the shots: the sound engine limits copies
-- of a sound per source, so each friend's sounds come from their own character instead.
local function friend_object(slot)
    local env = coop_slot_envs and coop_slot_envs[slot or 1] or _G
    local ghost_fn = rawget(env, "coop_ghost") or coop_ghost
    return ghost_fn and safe(ghost_fn) or nil
end

-- Play trigger id on container c for friend slot: from their character when there is one,
-- else at pos.
local function trigger_at(c, id, slot, pos)
    local g = friend_object(slot)
    if g then
        local ok = pcall(c.call, c, "trigger(System.UInt32, via.GameObject)", id, g)
        if ok then return end
    end
    if pos then pcall(c.call, c, "trigger(System.UInt32, via.vec3)", id, pos) end
end

-- One sound object per weapon, in the player's current folder (rebuilt when that changes:
-- an object outside the running scene never starts).
local function build(key)
    local paths = gs.paths[key]
    if paths == nil then return nil end
    local om = sdk.get_managed_singleton("app.ObjectManager")
    local pl = om and om:get_field("PlayerObj")
    local folder = pl and safe(pl.call, pl, "get_Folder")
    if folder == nil then return nil end
    local holders = {}
    for _, path in ipairs(paths) do
        local r = safe(sdk.create_resource, "via.wwise.ContainableResource", path)
        local h = r and safe(r.create_holder, r, "via.wwise.ContainableResourceHolder")
        if h then pcall(h.add_ref, h) holders[#holders + 1] = h end
    end
    if #holders == 0 then log(key .. ": no sound file loaded") return nil end
    local create = sdk.find_type_definition("via.GameObject"):get_method("create(System.String, via.Folder)")
    local go = create and safe(create.call, create, nil, "coop_friend_gun_" .. key, folder)
    if go == nil then log(key .. ": couldn't make the sound object") return nil end
    pcall(go.add_ref, go)
    local c = safe(go.call, go, "createComponent(System.Type)", sdk.typeof("via.wwise.WwiseContainer"))
    if c == nil then log(key .. ": couldn't make its sound part") return nil end
    pcall(c.add_ref, c)
    c:call("setContainableAssetCount", #holders)
    for i, h in ipairs(holders) do c:call("setContainableAsset", i - 1, h) end
    local part = { go = go, c = c, folder = folder, t0 = os.clock(), step = 0, ready = false, queue = {} }
    log(string.format("%s: sound object built (%d files)", key, #holders))
    return part
end

-- The start-up the container needs once its files are set: off, on, awake + start.
local function settle(key, part)
    if part.ready then return end
    local t = os.clock() - part.t0
    if part.step == 0 and t > 0.1 then part.step = 1 pcall(part.c.call, part.c, "set_Enabled", false)
    elseif part.step == 1 and t > 0.2 then part.step = 2 pcall(part.c.call, part.c, "set_Enabled", true)
    elseif part.step == 2 and t > 0.4 then
        part.step = 3
        pcall(part.c.call, part.c, "awake")
        pcall(part.c.call, part.c, "start")
    elseif part.step == 3 then
        -- Which of the sounds its files have (v0.41: the same ids for every weapon).
        part.knows = part.knows or {}
        local any = false
        for kind, id in pairs(TRIGGERS) do
            local ok, v = pcall(part.c.call, part.c, "exists(System.UInt32)", id)
            part.knows[kind] = ok and v == true
            any = any or part.knows[kind]
        end
        if any or t > 5 then
            part.ready = true
            log(string.format("%s: ready (shot %s, swing %s, reload %s)", key, tostring(part.knows.shot),
                tostring(part.knows.swing), tostring(part.knows.reload)))
        end
    end
end

local function fx_part(path, name, folder)
    if path == nil or path == "-" then return nil end
    local r = safe(sdk.create_resource, "via.effect.EffectResource", path)
    local h = r and safe(r.create_holder, r, "via.effect.EffectResourceHolder")
    if h == nil then log("couldn't load " .. path) return nil end
    pcall(h.add_ref, h)
    local create = sdk.find_type_definition("via.GameObject"):get_method("create(System.String, via.Folder)")
    local go = safe(create.call, create, nil, name, folder)
    if go == nil then return nil end
    pcall(go.add_ref, go)
    local fx = safe(go.call, go, "createComponent(System.Type)", sdk.typeof("via.effect.EffectPlayer"))
    if fx == nil then return nil end
    pcall(fx.add_ref, fx)
    pcall(fx.call, fx, "set_Resource", h)
    return { go = go, fx = fx }
end

-- Flash and smoke for one shot: both at the friend's gun, restarted (Kill, then Start next frame).
local function shoot_fx(key, pos, slot)
    local paths = gs.fx[key]
    if paths == nil or pos == nil then return end
    slot = slot or coop_event_slot or 1
    local om = sdk.get_managed_singleton("app.ObjectManager")
    local pl = om and om:get_field("PlayerObj")
    local folder = pl and safe(pl.call, pl, "get_Folder")
    local fkey = key .. ":" .. slot   -- one flash and smoke per friend, so shots at once all show
    local fp = gs.fxparts[fkey]
    if fp == nil or (folder and fp.folder and folder:get_address() ~= fp.folder:get_address()) then
        fp = { folder = folder, flash = fx_part(paths.flash, "coop_friend_flash_" .. key .. "_" .. slot, folder),
            smoke = fx_part(paths.smoke, "coop_friend_smoke_" .. key .. "_" .. slot, folder) }
        gs.fxparts[fkey] = fp
        log(string.format("%s: flash %s, smoke %s", key, tostring(fp.flash ~= nil), tostring(fp.smoke ~= nil)))
    end
    for _, part in ipairs({ fp.flash or false, fp.smoke or false }) do
        if part then
            pcall(function()
                part.go:call("get_Transform"):call("set_Position", pos)
                part.fx:call("set_Action", 2)
                part.restart = true
            end)
        end
    end
end

re.on_frame(function()
    for _, fp in pairs(gs.fxparts) do
        for _, part in ipairs({ fp.flash or false, fp.smoke or false }) do
            if part and part.restart then part.restart = false pcall(part.fx.call, part.fx, "set_Action", 1) end
        end
    end
end)

-- Our own copy of that weapon (under our player, drawn or put away), if we have one. A freshly
-- built container played the knife whoosh silently (2026-11-05): the knife's sound goes through
-- switch files (character type, motion type) that a new object has no values for, while our own
-- knife has them set and plays it. Swings go through our own copy when we have one.
local function own_weapon_container(key)
    local om = sdk.get_managed_singleton("app.ObjectManager")
    local pl = om and om:get_field("PlayerObj")
    if pl == nil then return nil end
    local found
    local function scan(go, depth)
        if found or depth > 4 then return end
        local tr = safe(go.call, go, "get_Transform")
        local ch = tr and safe(tr.call, tr, "get_Child")
        while ch and not found do
            local g = safe(ch.call, ch, "get_GameObject")
            local n = g and tostring(safe(g.call, g, "get_Name") or "") or ""
            if n:sub(1, #key) == key and n:find("_Item$") then found = container_of(g) end
            if g then scan(g, depth + 1) end
            ch = safe(ch.call, ch, "get_Next")
        end
    end
    scan(pl, 0)
    return found
end

local function play(key, kind, no_fx)
    kind = kind or "shot"
    local id = trigger_for(key, kind)
    if id == nil then return end
    if kind == "swing" then
        -- Through our own copy of that weapon, else (v0.41) our own knife: a freshly built
        -- object plays blades silently (their switch files need values only a held one has).
        local own = own_weapon_container(key)
        local standin = own == nil and key ~= "wp1190" and own_weapon_container("wp1190") or nil
        local pos = friend_hand(coop_event_slot)
        if (own or standin) and pos then
            trigger_at(own or standin, id, coop_event_slot, pos)
            if not gs.swing_logged then
                gs.swing_logged = true
                log(key .. ": swing played through our own " .. (own and "copy" or "knife"))
            end
            return
        end
    end
    local om = sdk.get_managed_singleton("app.ObjectManager")
    local pl = om and om:get_field("PlayerObj")
    local folder = pl and safe(pl.call, pl, "get_Folder")
    local part = gs.parts[key]
    if part == nil or (folder and part.folder and folder:get_address() ~= part.folder:get_address()) then
        part = build(key)
        gs.parts[key] = part
    end
    if part == nil then
        if kind == "shot" and not no_fx then pcall(shoot_fx, key, friend_hand(coop_event_slot), coop_event_slot) end   -- flash and smoke still
        return
    end
    part.queue[#part.queue + 1] = { t = os.clock(), kind = kind, slot = coop_event_slot or 1, fx = not no_fx }
end

re.on_frame(function()
    for key, part in pairs(gs.parts) do
        pcall(settle, key, part)
        if part.ready and #part.queue > 0 then
            for _, q in ipairs(part.queue) do
                local pos = friend_hand(q.slot)
                local id = trigger_for(key, q.kind)
                if pos and id and os.clock() - q.t < 1.0 then
                    if part.knows == nil or part.knows[q.kind] ~= false then
                        pcall(function() part.go:call("get_Transform"):call("set_Position", pos) end)
                        trigger_at(part.c, id, q.slot, pos)
                    elseif q.kind == "shot" and key ~= "standin" and not (settings and settings.standin_shots == false) then
                        -- This gun's files don't have the shot: the handgun's bang instead.
                        if not gs.missing[key] then gs.missing[key] = true log(key .. ": no shot in its files, the handgun's bang stands in") end
                        coop_event_slot = q.slot
                        pcall(play, "standin", "shot", true)
                        coop_event_slot = 1
                    elseif not gs.missing[key .. q.kind] then
                        gs.missing[key .. q.kind] = true
                        log(key .. ": no " .. q.kind .. " sound in its files")
                    end
                    if q.kind == "shot" and q.fx ~= false then pcall(shoot_fx, key, pos, q.slot) end
                end
            end
            part.queue = {}
        end
    end
end)

-- Shots that came in a moment before their weapon's files: played once the files are there.
re.on_frame(function()
    if #gs.early == 0 then return end
    local keep = {}
    for _, e in ipairs(gs.early) do
        if e.at and os.clock() < e.at then keep[#keep + 1] = e
        elseif gs.paths[e.key] then coop_event_slot = e.slot or 1 pcall(play, e.key, e.kind) coop_event_slot = 1
        elseif os.clock() - e.t < 2 then keep[#keep + 1] = e end
    end
    gs.early = keep
end)

function coop_gunsound_on_event(text)
    local key, list = text:match("^gsnd (wp%d%d%d%d) (.+)$")
    if key then
        local paths = {}
        for p in list:gmatch("[^;]+") do paths[#paths + 1] = p end
        local old = gs.paths[key]
        gs.paths[key] = paths
        if old == nil then log("got the sound files of " .. key .. " (" .. #paths .. ")") end
        return true
    end
    local fk, fl, sm = text:match("^gfx (wp%d%d%d%d) (%S+) (%S+)$")
    if fk then
        gs.fx[fk] = { flash = fl, smoke = sm }
        log("got the flash and smoke of " .. fk)
        return true
    end
    local lv = text:match("^light ([01])$")
    if lv then
        -- The friend's flashlight (further down: gs.light).
        if gs.light then gs.light.friend[coop_event_slot or 1] = lv == "1" end
        return true
    end
    local vkind = text:match("^pv (%a[%w_]*)$")
    if vkind then
        pcall(coop_voice_play, vkind, coop_event_slot or 1)
        return true
    end
    local kind, sk = text:match("^g(%a+) (wp%d%d%d%d)$")
    if sk and (kind == "shot" or kind == "swing" or kind == "reload") then
        -- Bot test with several bots: bots 2 and 3 copy us in the same instant, which made three
        -- identical sounds land as one; they're staggered 0.35 s each so all can be heard.
        local slot = coop_event_slot or 1
        local kv = coop_net_state and coop_net_state() and coop_net_state().kv or {}
        if kv.mode == "bot" and slot > 1 then
            gs.early[#gs.early + 1] = { key = sk, kind = kind, t = os.clock(), slot = slot, at = os.clock() + 0.35 * (slot - 1) }
        elseif gs.paths[sk] then pcall(play, sk, kind)
        else gs.early[#gs.early + 1] = { key = sk, kind = kind, t = os.clock(), slot = coop_event_slot } end   -- its files are on the way
        return true
    end
    return false
end

-- The friend's own sounds (v0.42) ------------------------------------------------------
-- Their grunts when they're hit or block, the thump and grunt of a landing, their scream when
-- they die, getting back up, pouring the First Aid Med. The game plays these from the motion it
-- plays (sound tracks run in native code, nothing to catch there); what can be caught is the
-- game choosing that motion, in managed code (type dump, 2026-11-09):
--   app.PlayerDamageController.playDamageSMotion / M / L, playStagger/Fire/Acid/Blow...Motion,
--   playGuardDamageMotion, playDeadMotion and playBlowDeadMotion: one call per hit;
--   processGuardStart (app.PlayerGun, PlayerItem, PlayerMelee, PlayerHands) and
--   app.PlayerMovement.processLand: motion tags, called every frame of the tag (so only the
--   first call after a quiet moment counts).
-- Sent as "pv <kind>". Their side plays that kind's sound from its own player's sound part
-- (app.PlayerDamageController.WwiseContainer, the app.WwiseContainerApp every player component
-- shares) at the friend's character, as the guns do (trigger(id, GameObject)). The names are the
-- same for Ethan and Mia (TRIGGER_SND_EVENTLIST_PL0000_V and PL2000_V), so it's the voice of the
-- character we play, which is the friend's too. Only while their character is shown and we're
-- not in a cutscene (a cutscene has its own voices, in both games). Options: "Your friend's voice".
local VOICE = {
    dmg_s = { "SND_MOT_PL_V_DMG_S" },                 -- 1480908325
    dmg_m = { "SND_MOT_PL_V_DMG_M" },                 -- 55217739
    dmg_l = { "SND_MOT_PL_V_DMG_M" },
    guard = { "SND_MOT_PL_V_GUARD" },                 -- 3338721245
    guard_hit = { "SND_MOT_PL_V_DMG_S" },
    land = { "SND_MOT_PL_V_ACT_LANDING", "SND_MOT_PL_MTF_FS_LANDING" },   -- 973764339, 4079835587
    death = { "SND_MOT_PL_V_DEATH_ROAR" },            -- 1544160693
    up = { "SND_MOT_PL_V_WAKE_UP_01" },               -- 3618666622
    climb = { "SND_MOT_PL_V_ACT_CLIMB" },             -- 402218999
    heal = { "SND_MOT_PL0000_SE_SOLUTION_POUR" },     -- 1195854192 (Ethan's First Aid Med)
}
local PV_HOOKS = {
    { "app.PlayerDamageController", "playDamageSMotion", "dmg_s" },
    { "app.PlayerDamageController", "playDamageMMotion", "dmg_m" },
    { "app.PlayerDamageController", "playStaggerDamageMotion", "dmg_m" },
    { "app.PlayerDamageController", "playFireDamageMotion", "dmg_m" },
    { "app.PlayerDamageController", "playAcidDamageMotion", "dmg_m" },
    { "app.PlayerDamageController", "playDamageLMotion", "dmg_l" },
    { "app.PlayerDamageController", "playBlowDamageMotion", "dmg_l" },
    { "app.PlayerDamageController", "playGuardDamageMotion", "guard_hit" },
    { "app.PlayerDamageController", "playDeadMotion", "death" },
    { "app.PlayerDamageController", "playBlowDeadMotion", "death" },
    { "app.PlayerGun", "processGuardStart", "guard" },
    { "app.PlayerItem", "processGuardStart", "guard" },
    { "app.PlayerMelee", "processGuardStart", "guard" },
    { "app.PlayerHands", "processGuardStart", "guard" },
    { "app.PlayerMovement", "processLand", "land" },
    { "app.PlayerMovement", "processClimbOn", "climb" },
}
-- How long a kind stays quiet after it was sent (s); a motion tag's handler runs every frame.
local PV_GAP = { guard = 0.6, land = 0.8, climb = 1.0, death = 3, up = 3, heal = 2 }
local pv = { calls = {}, sent = 0, played = 0, missing = {}, hooked = 0, ids = {}, err = false,
    heal = { prev = nil, med_t = -100 } }
gs.voice = pv

local function voice_id(name)
    local id = pv.ids[name]
    if id == nil then id = coop_sound_id(name) pv.ids[name] = id end
    return id
end

local function our_player()
    local om = sdk.get_managed_singleton("app.ObjectManager")
    return om and om:get_field("PlayerObj")
end

-- Ours: a hooked call on a component of our own player sends its kind.
local function pv_send(kind)
    local now = os.clock()
    local last = pv.calls[kind]
    pv.calls[kind] = now
    if last and now - last < (PV_GAP[kind] or 0.15) then return end
    if not coop_send_event then return end
    local om = sdk.get_managed_singleton("app.ObjectManager")
    local p = om and om:get_field("PlayerObj")
    local addr = p and p:get_address()
    if addr ~= pv.player_addr then pv.player_addr, pv.spawn_t = addr, now end
    if now - (pv.spawn_t or -100) < 6 then return end
    pv.sent = pv.sent + 1
    coop_send_event("pv " .. kind)
    -- The session page (v0.42): hits taken, heals.
    if coop_stat then
        if kind:match("^dmg") or kind == "guard_hit" then pcall(coop_stat, "hits")
        elseif kind == "heal" then pcall(coop_stat, "heals") end
    end
end
coop_voice_send = pv_send
coop_voice_state = pv   -- read only: what was sent and played (tests, the session page)
re.on_frame(function()
    local om = sdk.get_managed_singleton("app.ObjectManager")
    local p = om and om:get_field("PlayerObj")
    local addr = p and p:get_address() or nil
    if addr ~= pv.player_addr then pv.player_addr, pv.spawn_t = addr, os.clock() end
end)

do
    for _, h in ipairs(PV_HOOKS) do
        local td = sdk.find_type_definition(h[1])
        local m = td and td:get_method(h[2])
        if m then
            local kind = h[3]
            local ok = pcall(sdk.hook, m, function(args)
                pcall(function()
                    local c = sdk.to_managed_object(args[2])
                    local go = c and c:call("get_GameObject")
                    local pl = our_player()
                    if go and pl and go:get_address() == pl:get_address() then pv_send(kind) end
                end)
            end, function(r) return r end)
            if ok then pv.hooked = pv.hooked + 1 end
        else
            log("friend's voice: no " .. h[1] .. "." .. h[2] .. " in this game")
        end
    end
    log(string.format("friend's voice: %d of %d hooks", pv.hooked, #PV_HOOKS))
end

-- Healing: our health going up while a healing item is (or just was) in the hand.
local HEAL_WORDS = { "antiseptic", "remedy", "herb", "medic", "firstaid", "first_aid" }
re.on_frame(function()
    local h = pv.heal
    local now = os.clock()
    if now - (h.t or 0) < 0.2 then return end
    h.t = now
    local pl = our_player()
    local dc = pl and safe(pl.call, pl, "getComponent(System.Type)", sdk.typeof("app.PlayerDamageController"))
    local hp = dc and tonumber(safe(dc.call, dc, "get_health"))
    local max = dc and tonumber(safe(dc.call, dc, "get_maxHealth"))
    if hp == nil or max == nil or max <= 0 then h.prev = nil return end
    local w = tostring(held and held.sent or ""):lower()
    for _, k in ipairs(HEAL_WORDS) do if w:find(k, 1, true) then h.med_t = now end end
    local prev = h.prev
    h.prev = hp
    if prev and hp > prev + max * 0.03 and now - h.med_t < 3 then pv_send("heal") end
end)

-- Theirs: our own player's sound part (its switches are set, as our own knife's were).
local own_pl = { t = -100, c = nil, addr = nil }
local function own_player_sound()
    local pl = our_player()
    if pl == nil then own_pl.c = nil return nil end
    local now = os.clock()
    if own_pl.c and own_pl.addr == pl:get_address() and now - own_pl.t < 5 then return own_pl.c end
    own_pl.t, own_pl.addr = now, pl:get_address()
    local dc = safe(pl.call, pl, "getComponent(System.Type)", sdk.typeof("app.PlayerDamageController"))
    local c = dc and safe(dc.get_field, dc, "WwiseContainer")
    if c == nil then c = container_of(pl) end
    if c and not own_pl.logged then own_pl.logged = true log("friend's voice: plays from our player's sounds (" .. tostring(c:get_type_definition():get_full_name()) .. ")") end
    own_pl.c = c
    return c
end

function coop_voice_play(kind, slot)
    if settings and settings.friend_voice == false then return false end
    local names = VOICE[kind]
    if names == nil then return false end
    slot = slot or coop_event_slot or 1
    local env = coop_slot_envs and coop_slot_envs[slot] or _G
    local hidden = rawget(env, "ghost_hidden")
    if hidden == nil and slot == 1 then hidden = ghost_hidden end
    if hidden ~= false then return false end
    if local_cutscene and safe(local_cutscene) then return false end
    local g = friend_object(slot)
    local c = own_player_sound()
    if g == nil or c == nil then return false end
    local any = false
    for _, name in ipairs(names) do
        local id = voice_id(name)
        local ok, has = pcall(c.call, c, "exists(System.UInt32)", id)
        if ok and has == true then
            local tok = pcall(c.call, c, "trigger(System.UInt32, via.GameObject)", id, g)
            any = any or tok
        elseif not pv.missing[name] then
            pv.missing[name] = true
            log("friend's voice: our player's sounds have no " .. name .. " (" .. kind .. ")")
        end
    end
    if any then
        pv.played = pv.played + 1
        if not pv.first_logged then pv.first_logged = true log("friend's voice: played " .. kind) end
    end
    return any
end

-- The friend's flashlight (v0.42, experimental: Options, off until tried in a real game) -------
-- RE7 lights dark places with app.PlayerHandLight (isHandLightOn); its HandLight object holds an
-- app.HandLightController whose Light is a via.render.IESLight (type dump, 2026-11-09). Ours:
-- "light 1|0" when it goes on or off (and every 15 s while on). Theirs: a copy of our own hand
-- light (same light type, its settings copied from ours: numbers, switches, colours and its IES
-- texture) on a new object at the friend's head, pointing where they look. How a hand light sits
-- next to the view is measured from our own while it's on (and kept in the settings), so the
-- copy sits the same way next to theirs. Nothing is built before that.
local FL = { sent = nil, sent_t = -100, poll_t = 0, friend = {}, parts = {}, rel = nil, broken = false, n_copied = 0 }
gs.light = FL

local function qmul(a, b)
    return { w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z, x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
        y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x, z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w }
end
local function qconj(q) return { w = q.w, x = -q.x, y = -q.y, z = -q.z } end
local function qrot(q, x, y, z)
    local tx, ty, tz = 2 * (q.y * z - q.z * y), 2 * (q.z * x - q.x * z), 2 * (q.x * y - q.y * x)
    return x + q.w * tx + (q.y * tz - q.z * ty), y + q.w * ty + (q.z * tx - q.x * tz), z + q.w * tz + (q.x * ty - q.y * tx)
end
local function axisq(x, y, z, a) local s = math.sin(a / 2) return { w = math.cos(a / 2), x = x * s, y = y * s, z = z * s } end
local function plainq(q) return q and { w = q.w, x = q.x, y = q.y, z = q.z } or nil end
-- A view's rotation from yaw and pitch, for a camera that looks along its +Z (sign 1) or -Z (-1).
local function view_q(yaw, pitch, sign)
    if sign < 0 then return qmul(axisq(0, 1, 0, yaw + math.pi), axisq(1, 0, 0, pitch)) end
    return qmul(axisq(0, 1, 0, yaw), axisq(1, 0, 0, -pitch))
end
coop_view_q = view_q   -- for the light test

-- Our hand light's light part (the IES light), and the object it's on.
local function own_light()
    local pl = our_player()
    local hl = pl and safe(pl.call, pl, "getComponent(System.Type)", sdk.typeof("app.PlayerHandLight"))
    local go = hl and safe(hl.get_field, hl, "HandLight")
    if go == nil then return hl, nil end
    local ctl = safe(go.call, go, "getComponent(System.Type)", sdk.typeof("app.HandLightController"))
    local light = ctl and safe(ctl.get_field, ctl, "Light")
    if light == nil then
        for _, c in ipairs(safe(function() return go:call("get_Components"):get_elements() end) or {}) do
            local n = tostring(safe(function() return c:get_type_definition():get_full_name() end) or "")
            if n:find("^via%.render%.") and n:find("Light") then light = c break end
        end
    end
    return hl, light
end

-- While ours is on: how it sits next to our view (rotation and offset in the camera's frame),
-- and which way our camera looks (+Z or -Z, against our body's facing, as coop_dummy does).
local function measure(light)
    local cam = sdk.get_primary_camera()
    local cgo = cam and safe(cam.call, cam, "get_GameObject")
    local ctr = cgo and safe(cgo.call, cgo, "get_Transform")
    local lgo = light and safe(light.call, light, "get_GameObject")
    local ltr = lgo and safe(lgo.call, lgo, "get_Transform")
    local pl = our_player()
    local btr = pl and safe(pl.call, pl, "get_Transform")
    if ctr == nil or ltr == nil or btr == nil then return end
    local qc, pc = plainq(ctr:call("get_Rotation")), ctr:call("get_Position")
    local ql, plp = plainq(ltr:call("get_Rotation")), ltr:call("get_Position")
    local qb = plainq(btr:call("get_Rotation"))
    local fx, _, fz = qrot(qc, 0, 0, 1)
    local bx, _, bz = qrot(qb, 0, 0, 1)
    local sign = (fx * bx + fz * bz) >= 0 and 1 or -1
    local ic = qconj(qc)
    local rel = qmul(ic, ql)
    local ox, oy, oz = qrot(ic, plp.x - pc.x, plp.y - pc.y, plp.z - pc.z)
    if ox * ox + oy * oy + oz * oz > 1.0 then ox, oy, oz = 0, 0, 0 end   -- not next to the view: no offset
    FL.rel = { w = rel.w, x = rel.x, y = rel.y, z = rel.z, ox = ox, oy = oy, oz = oz, sign = sign }
    if settings and not FL.rel_saved then
        FL.rel_saved = true
        settings.light_rel = FL.rel
        if save_settings then pcall(save_settings) end
        log(string.format("flashlight: measured (camera looks along %sZ, offset %.2f %.2f %.2f)", sign > 0 and "+" or "-", ox, oy, oz))
    end
end

re.on_frame(function()
    local now = os.clock()
    if now - FL.poll_t < 0.25 then return end
    FL.poll_t = now
    local hl, light = own_light()
    local on = hl ~= nil and safe(hl.call, hl, "get_isHandLightOn") == true
    if coop_send_event and (on ~= FL.sent or (on and now - FL.sent_t > 15)) then
        FL.sent, FL.sent_t = on, now
        coop_send_event(on and "light 1" or "light 0")
    end
    if on and light then
        pcall(measure, light)
        FL.template = light
    end
end)

-- Copying a light's settings: every get_X/set_X pair of its own type (not via.Component's) whose
-- value is a plain value (number, switch, colour, enum...) or a resource (its IES texture).
local SKIP_PROPS = { Enabled = true, GameObject = true, UpdateOrder = true }
local function copy_light(src, dst)
    local td, n, guard = src:get_type_definition(), 0, 0
    while td and guard < 8 do
        guard = guard + 1
        local tn = td:get_full_name()
        if tn == "via.Component" or tn == "System.Object" then break end
        for _, m in ipairs(safe(td.get_methods, td) or {}) do
            local name = tostring(m:get_name())
            local prop = name:match("^get_(.+)$")
            if prop and not SKIP_PROPS[prop] and not prop:find("Matrix") and not prop:find("Position") and not prop:find("Rotation")
                and (safe(m.get_num_params, m) or 0) == 0 then
                local setter = td:get_method("set_" .. prop)
                local rt = safe(m.get_return_type, m)
                local rn = rt and tostring(safe(rt.get_full_name, rt) or "") or ""
                local plain = rt and (safe(rt.is_value_type, rt) == true or rn:find("ResourceHolder$") ~= nil)
                if setter and plain and (safe(setter.get_num_params, setter) or 0) == 1 then
                    local ok, v = pcall(m.call, m, src)
                    if ok and v ~= nil and pcall(setter.call, setter, dst, v) then n = n + 1 end
                end
            end
        end
        td = safe(td.get_parent_type, td)
    end
    return n
end

local function build_light(slot)
    local src = FL.template
    if src == nil then return nil end
    local pl = our_player()
    local folder = pl and safe(pl.call, pl, "get_Folder")
    if folder == nil then return nil end
    local create = sdk.find_type_definition("via.GameObject"):get_method("create(System.String, via.Folder)")
    local go = create and safe(create.call, create, nil, "coop_friend_light_" .. slot, folder)
    if go == nil then return nil end
    pcall(go.add_ref, go)
    local tname = src:get_type_definition():get_full_name()
    local c = safe(go.call, go, "createComponent(System.Type)", sdk.typeof(tname))
    if c == nil then log("flashlight: couldn't make a " .. tname) return nil end
    pcall(c.add_ref, c)
    local n = copy_light(src, c)
    FL.n_copied = n
    pcall(c.call, c, "set_Enabled", true)
    log(string.format("flashlight: friend %d's light built (%s, %d settings copied)", slot, tname, n))
    return { go = go, c = c, folder = folder, on = true }
end

-- The friend's head (a joint of their character with "head" in its name), cached per character.
local heads = {}
local function head_pos(g)
    local addr = g:get_address()
    local h = heads[addr]
    if h == nil then
        h = false
        local tr = g:call("get_Transform")
        local arr = safe(tr.call, tr, "get_Joints")
        for _, j in ipairs((arr and safe(arr.get_elements, arr)) or {}) do
            local n = tostring(safe(j.call, j, "get_Name") or ""):lower()
            if n:find("head") and not n:find("end") then h = j break end
        end
        heads[addr] = h
    end
    local p = h and safe(h.call, h, "get_Position")
    if p then return p end
    local gp = g:call("get_Transform"):call("get_Position")
    return { x = gp.x, y = gp.y + 1.6, z = gp.z }
end

re.on_frame(function()
    if FL.broken then return end
    local ok, err = pcall(function()
        if FL.rel == nil and settings and type(settings.light_rel) == "table" and settings.light_rel.w then FL.rel = settings.light_rel end
        local want_any = settings and settings.friend_light == true
        for slot = 1, 3 do
            local env = coop_slot_envs and coop_slot_envs[slot] or (slot == 1 and _G or nil)
            local on = want_any and FL.friend[slot] == true
            local g, hidden
            if on and env then
                local gf = rawget(env, "coop_ghost") or (slot == 1 and coop_ghost) or nil
                g = gf and safe(gf)
                hidden = rawget(env, "ghost_hidden")
                if hidden == nil and slot == 1 then hidden = ghost_hidden end
            end
            local show = on and g ~= nil and hidden == false and FL.rel ~= nil and not (local_cutscene and safe(local_cutscene))
            local part = FL.parts[slot]
            local pl = our_player()
            local folder = pl and safe(pl.call, pl, "get_Folder")
            if part and folder and part.folder and folder:get_address() ~= part.folder:get_address() then
                FL.parts[slot], part = nil, nil   -- our area changed: the old object is gone with it
            end
            if show and part == nil and FL.template then
                part = build_light(slot)
                FL.parts[slot] = part
            end
            if part then
                if show ~= part.on then part.on = show pcall(part.c.call, part.c, "set_Enabled", show) end
                if show then
                    local yaw, pitch = 0, 0
                    local lf = rawget(env, "coop_look_angles") or (slot == 1 and coop_look_angles) or nil
                    if lf then yaw, pitch = lf() end
                    local gtr = g:call("get_Transform")
                    local qg = plainq(gtr:call("get_Rotation"))
                    local bx, _, bz = qrot(qg, 0, 0, 1)
                    local r = FL.rel
                    local qv = view_q(math.atan(bx, bz) + yaw, pitch, r.sign or 1)
                    local hp = head_pos(g)
                    local ox, oy, oz = qrot(qv, r.ox or 0, r.oy or 0, r.oz or 0)
                    local q = qmul(qv, r)
                    local tr = part.go:call("get_Transform")
                    tr:call("set_Position", Vector3f.new(hp.x + ox, hp.y + oy, hp.z + oz))
                    tr:call("set_Rotation", Quaternion.new(q.w, q.x, q.y, q.z))
                end
            end
        end
    end)
    if not ok then
        FL.errs = (FL.errs or 0) + 1
        if FL.errs == 1 or FL.errs == 100 then log("flashlight ERR " .. tostring(err)) end
        if FL.errs >= 100 then FL.broken = true log("flashlight: switched off after repeated errors") end
    end
end)

-- Check (once, 10 s in) that the ids above are the game's: its own constants for the handgun
-- and the knife, and the hash of each name.
do
    local checked = false
    re.on_frame(function()
        if checked or os.clock() < 10 then return end
        checked = true
        pcall(function()
            for kind, name in pairs(TRIGGER_NAMES) do
                local game
                for _, list in ipairs({ "WP1010", "WP1190", "WP_SE_GENERAL" }) do
                    local td = sdk.find_type_definition("app.wwise.TRIGGER_SND_EVENTLIST_" .. list)
                    local f = td and td:get_field(name)
                    local v = f and safe(f.get_data, f, nil)
                    if v then game = tonumber(v) break end
                end
                local hashed = coop_sound_id(name)
                log(string.format("sound id %s (%s): ours %d, hash %d, the game's %s%s", kind, name, TRIGGERS[kind], hashed,
                    tostring(game), (game and game ~= TRIGGERS[kind]) and "  MISMATCH: using the game's" or ""))
                if game and game ~= TRIGGERS[kind] then TRIGGERS[kind] = game end
            end
            -- The friend's voice (v0.42): the same check, quietly unless something differs.
            local seen, bad = {}, 0
            for _, names in pairs(VOICE) do
                for _, name in ipairs(names) do
                    if not seen[name] then
                        seen[name] = true
                        local game
                        for _, list in ipairs({ "PL0000_V", "PL2000_V", "PL0000_MTF", "PL_ITEM" }) do
                            local td = sdk.find_type_definition("app.wwise.TRIGGER_SND_EVENTLIST_" .. list)
                            local f = td and td:get_field(name)
                            local v = f and safe(f.get_data, f, nil)
                            if v then game = tonumber(v) break end
                        end
                        if game and game ~= voice_id(name) then
                            bad = bad + 1
                            log(string.format("sound id %s: hash %d, the game's %d: using the game's", name, voice_id(name), game))
                            pv.ids[name] = game
                        end
                    end
                end
            end
            log("friend's voice ids checked" .. (bad > 0 and (": " .. bad .. " differed") or ": all match the game's"))
        end)
    end)
end

log("coop_gunsound loaded")
