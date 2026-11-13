-- Stand-ins for drop_test.py (v0.51), on top of give_test.lua's inventory and item manager: our player
-- (a position and a facing), the game's discard hook point (app.InventoryMenu.discardItem) and the world
-- objects ItemManager.createDropItemInstance makes. WORLD lists what was put on the ground.
WORLD = {}
NOT_DRAWN = false      -- the new object is made but not drawn
NO_OBJECT = false      -- createDropItemInstance answers nothing
PLAYER_POS = { x = 10, y = 0, z = 5 }
PEER = "steam:76561198000000009"
settings = {}

-- Same shape as give_test.lua's obj(), kept here so this file stands alone after it.
local obj2_mt = {}
obj2_mt.__index = function(t, k)
    if k == "call" then return function(self, name, ...) local f = self.calls and self.calls[name] if f then return f(...) end return nil end end
    if k == "get_field" then return function(self, name) return self.fields and self.fields[name] end end
    if k == "set_field" then return function() end end
    if k == "get_address" then return function(self) return self.addr or 1 end end
    if k == "add_ref" then return function(self) return self end end
    return nil
end
local function obj2(fields, calls, addr)
    return setmetatable({ fields = fields or {}, calls = calls or {}, addr = addr }, obj2_mt)
end

local function make_player()
    local t = obj2({}, {
        get_Position = function() return PLAYER_POS end,
        get_Rotation = function() return { x = 0, y = 0, z = 0, w = 1 } end,   -- facing +z
    })
    return obj2({}, { get_Transform = function() return t end }, 77)
end
local the_player = make_player()

local prev_single = sdk.get_managed_singleton
sdk.get_managed_singleton = function(name)
    if name == "app.ObjectManager" then return obj2({ PlayerObj = the_player }) end
    return prev_single(name)
end
sdk.to_managed_object = function(p) return p end
sdk.to_int64 = function(v) if type(v) == "number" then return v end return 0 end
sdk.create_managed_string = function(s) return s end

local discard_method = { name = "discardItem(app.Item)" }
local prev_find = sdk.find_type_definition
sdk.find_type_definition = function(name)
    if name == "app.InventoryMenu" then
        return { get_method = function(self, n) if n == "discardItem(app.Item)" then return discard_method end return nil end }
    end
    if name == "app.ItemManager" then
        local base = prev_find(name)
        return { get_method = function(self, n)
            if n == "createDropItemInstance(via.GameObject, System.String, System.Int32)" then
                return { call = function(_, _, owner, id, count)
                    if NO_OBJECT then return nil end
                    local rec = { id = id, n = count, owner = owner, parent = owner }
                    local t = obj2({}, {
                        set_Parent = function(p) rec.parent = p end,
                        set_Position = function(v) rec.pos = { x = v.x, y = v.y, z = v.z } end,
                    })
                    local o = obj2({}, {
                        get_Transform = function() return t end,
                        set_DrawSelf = function(v) rec.draw_self = v end,
                        set_UpdateSelf = function(v) rec.update_self = v end,
                        get_Draw = function() return not NOT_DRAWN end,
                    })
                    WORLD[#WORLD + 1] = rec
                    return o
                end }
            end
            return base:get_method(n)
        end }
    end
    return prev_find(name)
end

function coop_net_state() return { kv = { steamSelf = ME, mode = "steam", peer = PEER } } end
function coop_link_any(kv) local m = kv and kv.mode return m == "steam" or m == "udp" or m == "bot" end

-- The game's own discard: pre sees the item, post sees the result (true = it went through).
function discard(id, n, went)
    local item = obj2({ ItemDataID = id, ItemStackNum = n })
    for _, h in ipairs(hooks) do
        if h.m == discard_method then
            local args = { 0, 0, item }
            if h.pre then h.pre(args) end
            if h.post then h.post(went == false and 0 or 1) end
        end
    end
end
