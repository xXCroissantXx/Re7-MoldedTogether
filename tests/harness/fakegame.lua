-- A stand-in for REFramework and RE7, enough to load the mod's scripts and run their
-- callbacks (on_frame, on_draw_ui, hooks) without the game. Any error that escapes a script's
-- own pcall is recorded with where it happened. MODE:
--   "empty": no game objects at all (title screen / loading)
--   "nil":   singletons exist, but every call and field read gives nil
--   "rich":  every call and field read gives another fake object (numbers act like 0)
local MODE = HARNESS_MODE or "nil"
local MENUS = HARNESS_MENUS or false
local FILES = HARNESS_FILES or {}

errors, err_count = {}, 0
local function record(where, e)
    local k = where .. ": " .. tostring(e)
    if not errors[k] then errors[k] = 0 end
    errors[k] = errors[k] + 1
    err_count = err_count + 1
end

local addr = 0x10000
local fake_mt = {}
local function fake(name)
    addr = addr + 16
    return setmetatable({ __name = name or "obj", __addr = addr }, fake_mt)
end
local function ret(name)
    if MODE == "rich" then return fake(name) end
    return nil
end
local methods = {}
function methods.call(self, name, ...) return ret(tostring(name)) end
function methods.get_field(self, name) return ret(tostring(name)) end
function methods.set_field() end
function methods.get_address(self) return self.__addr end
function methods.get_type_definition(self) return sdk.find_type_definition(self.__name) end
function methods.get_elements(self) if MODE == "rich" then return { fake("el1"), fake("el2") } end return {} end
function methods.add_ref(self) return self end
function methods.release() end
function methods.read_qword() return 0 end
function methods.read_dword() return 0 end
function methods.write_qword() end
function methods.get_size() return 0 end
function methods.create_holder(self) return fake("holder") end
function methods.get_data() return ret("data") end
function methods.is_valid_offset() return false end
fake_mt.__index = function(t, k)
    if methods[k] then return methods[k] end
    if type(k) == "string" and (k == "x" or k == "y" or k == "z" or k == "w") then return 0 end
    -- obj:someMethod(...) style
    return function(...) return ret(k) end
end
local function num(v) if type(v) == "number" then return v end return 0 end
fake_mt.__add = function(a, b) return num(a) + num(b) end
fake_mt.__sub = function(a, b) return num(a) - num(b) end
fake_mt.__mul = function(a, b) return num(a) * num(b) end
fake_mt.__div = function(a, b) return 0 end
fake_mt.__mod = function(a, b) return 0 end
fake_mt.__unm = function(a) return 0 end
fake_mt.__pow = function(a, b) return 0 end
fake_mt.__idiv = function(a, b) return 0 end
fake_mt.__band = function(a, b) return 0 end
fake_mt.__bor = function(a, b) return 0 end
fake_mt.__shl = function(a, b) return 0 end
fake_mt.__shr = function(a, b) return 0 end
fake_mt.__lt = function(a, b) return num(a) < num(b) end
fake_mt.__le = function(a, b) return num(a) <= num(b) end
fake_mt.__len = function() return 0 end
fake_mt.__concat = function(a, b)
    local function s(v) if type(v) == "table" then return "<" .. tostring(v.__name) .. ">" end return tostring(v) end
    return s(a) .. s(b)
end
fake_mt.__tostring = function(t) return "<" .. tostring(t.__name) .. ">" end
fake_mt.__call = function() return ret("called") end

-- type definitions
local td_mt = {}
local td_cache = {}
local function typedef(name)
    if td_cache[name] then return td_cache[name] end
    local td = setmetatable({ name = name }, td_mt)
    td_cache[name] = td
    return td
end
local method_mt = {}
local function method(td, name)
    return setmetatable({ td = td, name = name }, method_mt)
end
method_mt.__index = {
    call = function(self, ...) return ret(self.name) end,
    get_name = function(self) return (self.name:match("^[^(]+")) end,
    get_num_params = function() return 0 end,
    get_return_type = function(self) return typedef("System.Object") end,
    get_params = function() return {} end,
}
local field_mt = {}
field_mt.__index = {
    get_data = function() return ret("static") end,
    get_name = function(self) return self.name end,
    get_offset_from_base = function() return 0 end,
    get_type = function() return typedef("System.Object") end,
}
td_mt.__index = {
    get_method = function(self, n) return method(self, n) end,
    get_methods = function(self) return { method(self, "update"), method(self, "successInteract") } end,
    get_field = function(self, n) return setmetatable({ name = n }, field_mt) end,
    get_fields = function() return {} end,
    get_full_name = function(self) return self.name end,
    get_name = function(self) return self.name end,
    is_a = function() return false end,
    get_parent_type = function() return nil end,
    create_instance = function(self) return fake(self.name) end,
    get_runtime_type = function(self) return fake("RuntimeType") end,
    is_value_type = function() return false end,
    get_valuetype_size = function() return 16 end,
}

hooks = {}
sdk = {
    PreHookResult = { CALL_ORIGINAL = 0, SKIP_ORIGINAL = 1 },
    find_type_definition = function(n) return typedef(n) end,
    typeof = function(n) return fake("Type:" .. tostring(n)) end,
    get_managed_singleton = function(n) if MODE == "empty" then return nil end return fake(n) end,
    get_native_singleton = function(n) if MODE == "empty" then return nil end return fake(n) end,
    call_native_func = function() return ret("native") end,
    hook = function(m, pre, post) hooks[#hooks + 1] = { m = m, pre = pre, post = post } end,
    create_resource = function(t, p) return fake("res") end,
    create_instance = function(n) return fake(n) end,
    create_managed_string = function(s) return fake("str:" .. tostring(s)) end,
    to_managed_object = function(p) return ret("managed") end,
    to_int64 = function(p) return 0 end,
    to_ptr = function(v) return 0 end,
    to_float = function(v) return 0 end,
    to_valuetype = function() return fake("vt") end,
    get_primary_camera = function() return ret("camera") end,
    copy_to_clipboard = function() end,
    create_managed_array = function() return fake("array") end,
}

callbacks = { frame = {}, ui = {}, reset = {}, pre = {}, app = {} }
re = {
    on_frame = function(f) callbacks.frame[#callbacks.frame + 1] = { f = f, src = CURRENT_SCRIPT } end,
    on_draw_ui = function(f) callbacks.ui[#callbacks.ui + 1] = { f = f, src = CURRENT_SCRIPT } end,
    on_script_reset = function(f) callbacks.reset[#callbacks.reset + 1] = { f = f, src = CURRENT_SCRIPT } end,
    on_config_save = function(f) end,
    on_pre_application_entry = function(n, f) callbacks.pre[#callbacks.pre + 1] = { f = f, src = CURRENT_SCRIPT } end,
    on_application_entry = function(n, f) callbacks.app[#callbacks.app + 1] = { f = f, src = CURRENT_SCRIPT } end,
    msg = function() end,
}

local function imfalse() return false end
imgui = setmetatable({
    checkbox = function(label, v) return false, v end,
    slider_float = function(label, v) return false, v end,
    slider_int = function(label, v) return false, v end,
    combo = function(label, v) return false, v end,
    input_text = function(label, v) return false, v end,
    drag_float = function(label, v) return false, v end,
    collapsing_header = function() return MENUS end,
    tree_node = function() return MENUS end,
    begin_window = function() return MENUS end,
    button = function() return false end,
    get_display_size = function() return { x = 1920, y = 1080 } end,
}, { __index = function() return imfalse end })

draw = setmetatable({
    world_to_screen = function() return nil end,
}, { __index = function() return function() end end })

fsfiles = FILES
fs = {
    read = function(p) return fsfiles[p] or "" end,
    write = function(p, s) fsfiles[p] = s end,
}
json = {
    load_file = function(p) return nil end,
    dump_file = function(p, t) return true end,
}
log = { info = function() end, warn = function() end, error = function() end, debug = function() end }

Vector3f = { new = function(x, y, z) return { x = x, y = y, z = z } end }
Vector2f = { new = function(x, y) return { x = x, y = y } end }
Vector4f = { new = function(x, y, z, w) return { x = x, y = y, z = z, w = w } end }
Quaternion = { new = function(w, x, y, z) return { w = w, x = x, y = y, z = z } end }
reframework = { get_game_name = function() return "re7" end, is_drawing_ui = function() return MENUS end }

function harness_load(name, src)
    CURRENT_SCRIPT = name
    local f, e = load(src, "@" .. name)
    if not f then record(name .. " (compile)", e) return end
    local ok, err = pcall(f)
    if not ok then record(name .. " (load)", err) end
end

FAKE_T = 100.0
os.clock = function() return FAKE_T end
function harness_frames(n)
    for i = 1, n do
        FAKE_T = FAKE_T + 1 / 60
        for _, c in ipairs(callbacks.frame) do
            local ok, e = pcall(c.f)
            if not ok then record(c.src .. " on_frame", e) end
        end
        if i % 10 == 0 then
            for _, c in ipairs(callbacks.ui) do
                local ok, e = pcall(c.f)
                if not ok then record(c.src .. " on_draw_ui", e) end
            end
        end
    end
end

function harness_hooks()
    for _, h in ipairs(hooks) do
        if h.pre then
            local args = { 0, 0, 0, 0, 0, 0, 0, 0 }
            local ok, e = pcall(h.pre, args)
            if not ok then record("hook pre " .. tostring(h.m and h.m.name), e) end
        end
        if h.post then
            local ok, e = pcall(h.post, 0)
            if not ok then record("hook post " .. tostring(h.m and h.m.name), e) end
        end
    end
end

function harness_events(lines)
    -- feed events through the friend's channel file
    local out = {}
    for i, l in ipairs(lines) do out[#out + 1] = (1000 + i) .. "\t" .. l end
    fsfiles["coopnet_ev_in.txt"] = table.concat(out, "\n") .. "\n"
end

function harness_report()
    local list = {}
    for k, v in pairs(errors) do list[#list + 1] = string.format("%5d x %s", v, k) end
    table.sort(list)
    return table.concat(list, "\n")
end
