-- A stand-in for what coop_menu.lua uses (REFramework drawing and keys, RE7's MenuManager and
-- PadManager, and the globals of the other co-op scripts), to drive the menu like a player.
-- menu_test.py makes two of these (a host and a friend) and passes their messages across.

T = { now = 100.0, chapter = 5, title = false, keys = {}, mm_calls = {}, sent = {}, files = {}, frames = {},
      resets = {}, draws = 0, texts = {}, jumps = {}, fails = 0, checks = 0, me = "76561198000000001",
      peer = "76561198000000002", peer_name = "Friend", peer_chapter = 5 }
os.clock = function() return T.now end

local function obj(t) return setmetatable(t, { __index = function(_, k) return function() return nil end end }) end

local mm = obj({ call = function(self, m, a, b) T.mm_calls[#T.mm_calls + 1] = { m = m, a = a, b = b } end })
local gm = obj({ get_field = function(self, f)
    if f == "_CurrentChapter" then return T.title and 3 or T.chapter end
    if f == "IsTitleDisp" then return T.title end
end })
local om = obj({ get_field = function(self, f) if f == "PlayerObj" then return (not T.title) and obj({}) or nil end end })
local singletons = { ["app.MenuManager"] = mm, ["app.GameManager"] = gm, ["app.ObjectManager"] = om }
local LEVELS = { NormalHigh = 6 }
local BUTTONS = { LeftUp = 0, LeftDown = 2, LeftLeft = 3, LeftRight = 1, Decide = 18, Cancel = 19, LeftStickPush = 12, RightStickPush = 13 }
sdk = {
    get_managed_singleton = function(n) return singletons[n] end,
    find_type_definition = function(n)
        return obj({ get_field = function(self, f)
            local v = (n == "app.UICommand.InputLevel" and LEVELS[f]) or (n == "app.Pad.Button" and BUTTONS[f]) or nil
            if v == nil then return nil end
            return obj({ get_data = function() return v end })
        end })
    end,
    create_managed_string = function(s) return s end,
}
re = { on_frame = function(f) T.frames[#T.frames + 1] = f end, on_script_reset = function(f) T.resets[#T.resets + 1] = f end }
reframework = {
    is_key_down = function(self, vk) return T.keys[vk] == true end,
    is_drawing_ui = function(self) return false end,
}
fs = { read = function(p) return T.files[p] or "" end, write = function(p, s) T.files[p] = s end }
imgui = {
    get_display_size = function() return { x = 1920, y = 1080 } end,
    load_font = function(p, size) return size end,
    push_font = function() end, pop_font = function() end,
    calc_text_size = function(s) return { x = #s * 11, y = 22 } end,
    get_mouse = function() return { x = MX or 0, y = MY or 0 } end,
    is_mouse_down = function(i) if i == 0 then return MDOWN == true end return MRDOWN == true end,
}
draw = setmetatable({
    text = function(s) T.draws = T.draws + 1 T.texts[#T.texts + 1] = s end,
}, { __index = function() return function() T.draws = T.draws + 1 end end })

-- The other co-op scripts' globals.
settings = { look = "default" }
save_settings = function() end
CHARACTERS = { { key = "default", name = "Default" }, { key = "ethan", name = "Ethan" } }
coop_set_look = function(k) settings.look = k end
coop_set_shared_option = function(k, v) settings[k] = v end
coop_slot_envs = { [1] = _G }
local net = { kv = {}, history = {}, peer_chapter = nil }
coop_net_state = function()
    net.kv = { mode = "steam", steamSelf = T.me, steamName = T.name or "Me", version = "0.40",
        peer = T.connected and ("steam:" .. T.peer) or "steam:0", peerName = T.peer_name }
    net.history = (T.connected and not T.silent) and { { t = T.now } } or {}
    net.peer_chapter = T.peer_chapter
    return net
end
chapters = { list = {
    { name = "Chapter1", value = 4, key = "Chapter1_Start" },
    { name = "Chapter3", value = 5, key = "Chapter3_Start" },
    { name = "Chapter4", value = 6, key = "Chapter4_Start" },
}, last = "-" }
ensure_chapter_list = function() end
chapter_name = function(v) for _, e in ipairs(chapters.list) do if e.value == v then return e.name end end return tostring(v) end
local_chapter = function() return T.title and 3 or T.chapter end
local_cutscene = function() return false end
jump_busy = function() if T.title then return "load your save first" end return nil end
jump_to_chapter = function(e) T.jumps[#T.jumps + 1] = e.key chapters.last = "jumping to " .. e.name end
friends = { list = {}, show_all = false, dismissed = {} }
read_friends = function() end
pending_invite = function() return nil end
coop_send_event = function(text) T.sent[#T.sent + 1] = text end

-- A stand-in title menu: the tape recorder's list (app.TitleSubMenu on GUI_menu, its _StepParam
-- rows and its via.gui.ScrollList slots), for the CO-OP row.
local function fobj(fields, calls, addr)
    local o = { f = fields or {}, c = calls or {}, addr = addr or 4242 }
    function o.get_field(self, k) return self.f[k] end
    function o.set_field(self, k, v) self.f[k] = v end
    function o.call(self, m, ...) local fn = self.c[m] if fn then return fn(self, ...) end return nil end
    function o.get_address(self) return self.addr end
    function o.add_ref(self) return self end
    return o
end
function install_title()
    TM = { steps = {}, item_max = 7, selected = 1, slots = {} }
    for i, name in ipairs({ "newgame", "continue", "loadgame", "extragame", "specialfeature", "option", "quit" }) do
        TM.steps[i] = fobj({ GUIElemName = name, Step = i, ElemMsgID = "msg_" .. name })
    end
    local steps = fobj({}, {
        get_Count = function() return #TM.steps end,
        get_Item = function(_, i) return TM.steps[i + 1] end,
        Add = function(_, sp) TM.steps[#TM.steps + 1] = sp end,
        RemoveAt = function(_, i) table.remove(TM.steps, i + 1) end,
    })
    for i, name in ipairs({ "selectitem", "item1", "item2", "item3" }) do
        local slot = { name = name, li = i - 1 }
        slot.text = { msg = nil, id = nil }
        local text = fobj({}, {
            get_Name = function() return "m_name" end,
            get_Next = function() return nil end,
            get_Message = function() return slot.text.msg end,
            set_Message = function(_, v) slot.text.msg = v end,
            set_MessageId = function(_, v) slot.text.id = v end,
        })
        slot.obj = fobj({}, {
            get_Name = function() return name end,
            get_ListIndex = function() return slot.li end,
            get_Child = function() return text end,
        })
        TM.slots[i] = slot
    end
    local items = fobj({}, { get_Count = function() return #TM.slots end, get_Item = function(_, i) return TM.slots[i + 1].obj end })
    local sl = fobj({}, {
        ["setSelectedIndex(System.Int32, System.Boolean)"] = function(_, i) TM.selected = i end,
        get_ItemMax = function() return TM.item_max end,
        set_ItemMax = function(_, v) TM.item_max = v end,
        get_Items = function() return items end,
        get_SelectedIndex = function() return TM.selected end,
    })
    local cache = fobj({ _Element = sl })
    local go = fobj({}, { get_Name = function() return "GUI_menu" end })
    local helper = fobj({}, { ["changeStepNextUpdate(System.Int32)"] = function(_, v) TM.step_change = v end })
    local tsm = fobj({ _StepParam = steps, _MainList = cache, IsMainListControl = true, _Step = helper },
        { get_GameObject = function() return go end, changeMotionCamera = function(_, v) TM.cam = v end }, 7777)
    TM.tsm = tsm
    local scene = fobj({}, { ["findComponents(System.Type)"] = function() return { get_elements = function() return { tsm } end } end })
    sdk.call_native_func = function() return scene end
    sdk.get_native_singleton = function() return {} end
    sdk.typeof = function(n) return n end
    sdk.create_instance = function() return fobj({}) end
end

function open_cat(label)
    -- Go to sheet A, move to the section, open it.
    coop_menu.focus, coop_menu.stack, coop_menu.confirm = "A", {}, nil
    for _ = 1, 12 do
        local c = coop_menu.cats[coop_menu.cat or 1]
        if c and c.label == label then press("enter") return end
        press("down")
    end
    print("FAIL couldn't find section " .. label)
    T.fails = T.fails + 1
end

-- Driving it.
function frames(seconds)
    local n = math.max(1, math.floor(seconds * 30))
    for _ = 1, n do
        T.now = T.now + 1 / 30
        for _, f in ipairs(T.frames) do
            local ok, e = pcall(f)
            if not ok then T.fails = T.fails + 1 print("FAIL frame error: " .. tostring(e)) end
        end
    end
end
local VK = { up = 0x26, down = 0x28, left = 0x25, right = 0x27, enter = 0x0D, back = 0x08, f9 = 0x78, f10 = 0x79,
    esc = 0x1B, f = 0x46 }
function press(name)
    T.keys[VK[name]] = true
    frames(0.05)
    T.keys[VK[name]] = false
    frames(0.05)
end
function check(cond, what)
    T.checks = T.checks + 1
    if cond then print("ok   " .. what) else T.fails = T.fails + 1 print("FAIL " .. what) end
end
function called(m, a)
    for _, c in ipairs(T.mm_calls) do if c.m == m and (a == nil or c.a == a) then return true end end
    return false
end
function drew(s) for _, t in ipairs(T.texts) do if t:find(s, 1, true) then return true end end return false end
-- Select the item whose text starts with `label` on the current page (moves down to it).
function choose(label)
    for _ = 1, 20 do
        T.texts = {}
        frames(0.05)
        local sel = coop_menu.sel[coop_menu.page] or 1
        -- the drawn selectable rows are in order; find the chosen one's text by re-reading the page
        local title, items = coop_menu_debug_items()
        local idx, k = nil, 0
        for i, it in ipairs(items) do if not it.info then k = k + 1 if k == sel then idx = i end end end
        if idx and items[idx].text:sub(1, #label) == label then press("enter") return true end
        press("down")
    end
    print("FAIL couldn't find item " .. label)
    T.fails = T.fails + 1
    return false
end
