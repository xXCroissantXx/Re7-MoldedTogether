-- coop_probe.lua: once in game, records the player's GameObject, components,
-- position and chapter every 2 s. Read-only.
-- Output: <game>/reframework/data/coop_probe.txt

local om_name = "app.ObjectManager"
local last = 0
local components_written = false

local function safe(f, ...)
    local ok, r = pcall(f, ...)
    if ok then return r end
    return nil
end

-- Debug registry (v0.52, coop_dummy.lua): dbg_note describes the callback or hook registered on the next lines, dbg_task
-- gives a function its own row in the Debug section. Both are tail calls so the registry sees this file's line.
local function dbg_note(info) if coop_note then return coop_note(info) end end
local function dbg_task(feature, name, f, info) if coop_task then return coop_task(feature, name, f, info) end return f end

local function components_of(go)
    local out = {}
    local comps = safe(go.call, go, "get_Components")
    if comps == nil then return out end
    local elems = safe(comps.get_elements, comps) or {}
    for _, c in ipairs(elems) do
        out[#out + 1] = safe(function() return c:get_type_definition():get_full_name() end) or "?"
    end
    return out
end

dbg_note{ feature = "Probe (research)", name = "Record the player's objects, components, position and chapter",
    when = "every frame, but it only works every 2 s",
    reads = "GameManager chapter / title / mode, SaveDataManager loading state, ObjectManager.PlayerObj and its components",
    writes = "coop_probe.txt (a read-only research log)" }
re.on_frame(function()
    local now = os.clock()
    if now - last < 2.0 then return end
    last = now

    local gm = sdk.get_managed_singleton("app.GameManager")
    local sdm = sdk.get_managed_singleton("app.SaveDataManager")
    local state = string.format("chapter: %s  titleDisp: %s  gameMode: %s  loadingState: %s",
        tostring(gm and safe(gm.get_field, gm, "_CurrentChapter")),
        tostring(gm and safe(gm.get_field, gm, "IsTitleDisp")),
        tostring(gm and safe(gm.get_field, gm, "NowGameMode")),
        tostring(sdm and safe(sdm.get_field, sdm, "NowLoadingState")))

    local om = sdk.get_managed_singleton(om_name)
    local source = "ObjectManager.PlayerObj"
    local player = om and safe(om.get_field, om, "PlayerObj")
    if player == nil then
        local t = sdk.find_type_definition("app.ObjectManager")
        local m = t and t:get_method("findObjectsWithTag")
        local arr = m and safe(m.call, m, nil, "Player")
        local elems = arr and safe(arr.get_elements, arr)
        if elems and #elems > 0 then
            player = elems[1]
            source = "findObjectsWithTag(Player) [" .. #elems .. "]"
        end
    end
    if player == nil then
        fs.write("coop_probe.txt", "no player found\n" .. state)
        return
    end

    local name = safe(player.call, player, "get_Name") or "?"
    local tr = safe(player.call, player, "get_Transform")
    local pos = tr and safe(tr.call, tr, "get_Position")
    local rot = tr and safe(tr.call, tr, "get_Rotation")

    local lines = {
        "player: " .. tostring(name) .. "  (via " .. source .. ")",
        state,
        pos and string.format("pos: %.3f %.3f %.3f", pos.x, pos.y, pos.z) or "pos: ?",
        rot and string.format("rot: %.3f %.3f %.3f %.3f", rot.x, rot.y, rot.z, rot.w) or "rot: ?",
    }
    if not components_written then
        local comps = components_of(player)
        if #comps > 0 then
            fs.write("coop_probe_components.txt", table.concat(comps, "\n"))
            components_written = true
        end
    end
    fs.write("coop_probe.txt", table.concat(lines, "\n"))
end)
