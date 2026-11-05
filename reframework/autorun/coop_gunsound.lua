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

local SHOT_TRIGGER = {
    wp1210 = 3908091806,   -- handgun (G17), 2026-11-04
}
-- Melee swings (v0.28): the swing "whoosh" on the weapon's container, first trigger of each
-- swing in the recorder (22 of 22 swings, 2026-11-05), confirmed by ear. Sent as "gswing <weapon>"
-- when the held weapon's app.Weapon.IsAttacking turns on (melee weapons only: no gun smoke).
local SWING_TRIGGER = {
    wp1190 = 1824153269,   -- knife, 2026-11-05
}
local function trigger_for(key, kind)
    if kind == "swing" then return SWING_TRIGGER[key] end
    return SHOT_TRIGGER[key]
end

local gs = { sent_paths = {}, paths = {}, parts = {}, pending = 0, swings = 0, missing = {}, fx = {}, fxparts = {}, early = {} }
coop_gunsound = gs

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
    if (gs.pending == 0 and gs.swings == 0) or not coop_send_event then return end
    local n, sw = gs.pending, gs.swings
    gs.pending, gs.swings = 0, 0
    pcall(function()
        local go = held and held.local_go
        local key = go and weapon_key(go:call("get_Name"))
        if key == nil then return end
        send_files(go, key, n > 0)
        for _ = 1, math.min(n, 3) do coop_send_event("gshot " .. key) end
        for _ = 1, math.min(sw, 2) do coop_send_event("gswing " .. key) end
    end)
end)
-- Resend the paths after a reconnect (the friend may have restarted).
function coop_gunsound_reset_sent() gs.sent_paths = {} end

-- Their side ---------------------------------------------------------------------------
local function friend_hand()
    -- The weapon copy's position plus a little along its forward axis (about the muzzle).
    local part = held and held.part
    local tr = part and safe(part.call, part, "get_Transform")
    local p = tr and safe(tr.call, tr, "get_Position")
    if p then
        local fwd = safe(tr.call, tr, "get_AxisZ")
        if fwd then return Vector3f.new(p.x + fwd.x * 0.2, p.y + fwd.y * 0.2, p.z + fwd.z * 0.2) end
        return p
    end
    local g = coop_ghost and coop_ghost()
    local gp = g and safe(function() return g:call("get_Transform"):call("get_Position") end)
    if gp then return Vector3f.new(gp.x, gp.y + 1.4, gp.z) end
    return nil
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
        local id = SHOT_TRIGGER[key] or SWING_TRIGGER[key]
        if id and select(2, pcall(part.c.call, part.c, "exists(System.UInt32)", id)) == true then
            part.ready = true
            log(key .. ": ready")
        elseif t > 5 then
            part.ready = true
            log(key .. ": the sound object doesn't know the shot after 5 s")
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
local function shoot_fx(key, pos)
    local paths = gs.fx[key]
    if paths == nil or pos == nil then return end
    local om = sdk.get_managed_singleton("app.ObjectManager")
    local pl = om and om:get_field("PlayerObj")
    local folder = pl and safe(pl.call, pl, "get_Folder")
    local fp = gs.fxparts[key]
    if fp == nil or (folder and fp.folder and folder:get_address() ~= fp.folder:get_address()) then
        fp = { folder = folder, flash = fx_part(paths.flash, "coop_friend_flash_" .. key, folder),
            smoke = fx_part(paths.smoke, "coop_friend_smoke_" .. key, folder) }
        gs.fxparts[key] = fp
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

local function play(key, kind)
    kind = kind or "shot"
    local id = trigger_for(key, kind)
    if id == nil then
        if not gs.missing[key .. kind] then gs.missing[key .. kind] = true log("no " .. kind .. " sound known for " .. key .. " yet") end
        if kind == "shot" then pcall(shoot_fx, key, friend_hand()) end   -- flash and smoke still
        return
    end
    if kind == "swing" then
        local own = own_weapon_container(key)
        local pos = friend_hand()
        if own and pos then
            pcall(own.call, own, "trigger(System.UInt32, via.vec3)", id, pos)
            if not gs.swing_logged then gs.swing_logged = true log(key .. ": swing played through our own copy") end
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
    if part == nil then return end
    part.queue[#part.queue + 1] = { t = os.clock(), kind = kind }
end

re.on_frame(function()
    for key, part in pairs(gs.parts) do
        pcall(settle, key, part)
        if part.ready and #part.queue > 0 then
            local pos = friend_hand()
            for _, q in ipairs(part.queue) do
                local id = trigger_for(key, q.kind)
                if pos and id and os.clock() - q.t < 1.0 then
                    pcall(function()
                        part.go:call("get_Transform"):call("set_Position", pos)
                        part.c:call("trigger(System.UInt32, via.vec3)", id, pos)
                    end)
                    if q.kind == "shot" then pcall(shoot_fx, key, pos) end
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
        if gs.paths[e.key] then pcall(play, e.key, e.kind)
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
    local kind, sk = text:match("^g(%a+) (wp%d%d%d%d)$")
    if sk and (kind == "shot" or kind == "swing") then
        if gs.paths[sk] then pcall(play, sk, kind)
        else gs.early[#gs.early + 1] = { key = sk, kind = kind, t = os.clock() } end   -- its files are on the way
        return true
    end
    return false
end

log("coop_gunsound loaded")
