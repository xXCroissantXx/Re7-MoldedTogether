-- A controlled stand-in for the parts of RE7 coop_story.lua uses, to play story scenarios
-- through it and check what it does (story_test.py loads this, then coop_story.lua, then runs
-- the scenarios at the bottom). Every check failure is printed as "FAIL ...".

T = { now = 100.0, chapter = 5, scenes = {}, requested = {}, prog = {}, ended = {}, sent = {},
      player_addr = 1000, player = { x = 0, y = 0, z = 0 }, ghost = { x = 3, y = 0, z = 0 },
      cutscene = false, hooks = {}, frames = {}, files = {}, json = {}, fails = 0, checks = 0 }
os.clock = function() return T.now end

local function obj(t) return setmetatable(t, { __index = function(_, k) return function() return nil end end }) end

local function pos_obj(p) return obj({ call = function(self, m) if m == "get_Position" then return p end end }) end
local player = obj({
    get_address = function() return T.player_addr end,
    call = function(self, m) if m == "get_Transform" then return pos_obj(T.player) end end,
})
local ghost = obj({ call = function(self, m) if m == "get_Transform" then return pos_obj(T.ghost) end end })
coop_ghost = function() return ghost end

local function setting(name) return obj({ call = function(self, m) if m == "get_eventName" then return name end end }) end
local settings_list = obj({
    call = function(self, m, i)
        if m == "get_Count" then return #T.scenes end
        if m == "get_Item" then return setting(T.scenes[i + 1]) end
    end,
})
local event_mgr = obj({
    get_field = function(self, f) if f == "EventSettings" then return settings_list end end,
    call = function(self, m, a)
        if m:find("^requestEvent") then T.requested[#T.requested + 1] = a return obj({}) end
        if m:find("^isSameEventRequested") then return false end
    end,
})
local gm = obj({
    get_field = function(self, f)
        if f == "_CurrentChapter" then return T.chapter end
        if f == "PlayingMovie" then return nil end
    end,
    call = function(self, m) if m == "get_IsPause" then return false end end,
})
local var_mt = {}
local function var(v) return obj({ call = function(self, m) if m == "get_S32" then return v end end }) end
local fm = obj({
    call = function(self, m, h, v)
        if m == "getProgressiveNo(System.UInt32)" then return var(T.prog[h] or 0) end
        if m == "setProgressiveNo(System.UInt32, System.Int32)" then
            T.prog[h] = v
            T.set_prog = (T.set_prog or 0) + 1
            return
        end
        if m == "isEventEnded(System.UInt32)" then return T.ended[h] == true end
        if m == "sendEventEnded(System.UInt32)" then T.ended[h] = true return end
        if m == "get_CurrentMainGameFlow" then return "C03_1_Main" end
    end,
})
local om = obj({ get_field = function(self, f) if f == "PlayerObj" then return T.no_player and nil or player end end })
local mm = obj({ call = function(self, m) if m == "isOpenPauseMenu" then return false end end })

local singletons = { ["app.GameManager"] = gm, ["app.GameFlowFsmManager"] = fm, ["app.ObjectManager"] = om,
    ["app.MenuManager"] = mm }
local function method(td, name) return { td = td, name = name } end
local function typedef(name)
    return obj({
        get_method = function(self, n) return method(name, n) end,
        get_field = function(self, n)
            if name == "app.GameManager" and n == "_GameEventMan" then
                return obj({ get_data = function() return event_mgr end })
            end
        end,
    })
end
sdk = {
    find_type_definition = function(n) return typedef(n) end,
    get_managed_singleton = function(n) return singletons[n] end,
    hook = function(m, pre, post) T.hooks[m.td .. "." .. m.name] = pre end,
    to_managed_object = function(p) return p end,
    to_int64 = function(p) return p end,
    create_managed_string = function(s) return s end,
}
re = { on_frame = function(f) T.frames[#T.frames + 1] = f end }
fs = { read = function(p) return T.files[p] or "" end, write = function(p, s) T.files[p] = s end }
json = { load_file = function(p) return T.json[p] end, dump_file = function(p, t) T.json[p] = t return true end }
settings = { share_story = true }
coop_send_event = function(text) T.sent[#T.sent + 1] = text end
local_cutscene = function() return T.cutscene end

function frames(seconds)
    local n = math.floor(seconds * 10)
    for _ = 1, n do
        T.now = T.now + 0.1
        for _, f in ipairs(T.frames) do
            local ok, e = pcall(f)
            if not ok then print("FAIL frame error: " .. tostring(e)) T.fails = T.fails + 1 end
        end
    end
end
local function hook(name, args)
    local h = T.hooks[name]
    if h == nil then print("FAIL no hook " .. name) T.fails = T.fails + 1 return end
    h(args)
end
-- Our own game starts a scene (its own trigger).
function our_scene(name) hook("app.GameEventController.requestSetup(app.GameEventSetting, via.Transform)", { 0, 0, setting(name) }) end
function our_scene_ends(name)
    hook("app.GameEventController.doOnDestroy", { 0, obj({ call = function(self, m) if m == "get_eventSetting" then return setting(name) end end }) })
end
function our_prog(h, v) T.prog[h] = v hook("app.GameFlowFsmManager.setProgressiveNo(System.UInt32, System.Int32)", { 0, 0, h, v }) end
function friend(text) coop_story_on_event(text) end
function check(cond, what)
    T.checks = T.checks + 1
    if not cond then T.fails = T.fails + 1 print("FAIL " .. what) else print("ok   " .. what) end
end
function requested(name) for _, n in ipairs(T.requested) do if n == name then return true end end return false end
function sent(prefix) for _, s in ipairs(T.sent) do if s:sub(1, #prefix) == prefix then return true end end return false end
function reset_requests() T.requested = {} T.sent = {} T.set_prog = 0 end
