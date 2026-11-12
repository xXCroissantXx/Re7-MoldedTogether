-- Stand-ins for give_test.py (v0.42): an inventory, the item manager and our player, on top of
-- fakegame.lua in "nil" mode. INV holds counts per item id; CATS their categories.
INV = INV or {}
CATS = { HandgunBullet = 2, RemedyM = 3, Herb = 7, Key = 4, Handgun = 1, Burner = 8 }
ROOM = true          -- isCanAddItem answers
ADD_WORKS = true     -- addItem really adds
SENT = {}
NOTES = {}
T = { checks = 0, fails = 0 }
function check(c, what)
    T.checks = T.checks + 1
    if c then print("ok   " .. what) else T.fails = T.fails + 1 print("FAIL " .. what) end
end

local obj_mt = {}
obj_mt.__index = function(t, k)
    if k == "call" then return function(self, name, ...) local f = self.calls and self.calls[name] if f then return f(...) end return nil end end
    if k == "get_field" then return function(self, name) return self.fields and self.fields[name] end end
    if k == "set_field" then return function() end end
    if k == "get_address" then return function(self) return self.addr or 1 end end
    if k == "add_ref" then return function(self) return self end end
    return nil
end
local function obj(fields, calls, addr) return setmetatable({ fields = fields or {}, calls = calls or {}, addr = addr }, obj_mt) end

local function data_of(id) return obj({ Category = CATS[id] or 0, NameMsg = obj({}) }) end
local function item_of(id)
    local it
    it = obj({ ItemDataID = id, ItemStackNum = 1 }, {
        ["get_ItemData"] = function() return data_of(id) end,
        ["setStackNum(System.Int32)"] = function(n) it.fields.ItemStackNum = n end,
    })
    return it
end
local function item_list()
    local list = {}
    local ids = {}
    for id, n in pairs(INV) do if n > 0 then ids[#ids + 1] = id end end
    table.sort(ids)
    for _, id in ipairs(ids) do list[#list + 1] = obj({ Item = item_of(id), Owner = obj({}) }) end
    return obj({}, { get_Count = function() return #list end, get_Item = function(i) return list[i + 1] end })
end
local inv = obj({}, {
    ["getTotalStackNum(System.String, System.Boolean)"] = function(id) return INV[id] or 0 end,
    ["isCanAddItem(System.String, System.Int32)"] = function() return ROOM end,
    ["addItem(app.Item, via.GameObject)"] = function(item)
        if ADD_WORKS then local id = item.fields.ItemDataID INV[id] = (INV[id] or 0) + (item.fields.ItemStackNum or 1) return 0 end
        return ADD_RESULT or 3   -- NoPut
    end,
    ["reduceItem(System.String, System.Int32, System.Boolean)"] = function(id, n) INV[id] = math.max(0, (INV[id] or 0) - n) return true end,
})
inv.fields._ItemList = nil
setmetatable(inv.fields, { __index = function(t, k) if k == "_ItemList" then return item_list() end end })

local player = obj({}, {}, 77)
DESTROYED = 0
local base_find = sdk.find_type_definition
sdk.find_type_definition = function(name)
    if name == "app.Inventory" then
        return { get_method = function(self, n)
            if n == "getActivePlayerInventory" then return { call = function() return inv end } end
            return nil
        end }
    end
    if name == "app.ItemManager" then
        return { get_method = function(self, n)
            if n == "createItemInstance(via.GameObject, System.String)" then
                return { call = function(_, _, owner, id)
                    local it = item_of(id)
                    return obj({}, { ["getComponent(System.Type)"] = function() return it end,
                        ["destroy(via.GameObject)"] = function() DESTROYED = DESTROYED + 1 end })
                end }
            end
            return nil
        end }
    end
    return base_find(name)
end
local base_single = sdk.get_managed_singleton
sdk.get_managed_singleton = function(name)
    if name == "app.ItemManager" then return obj({}, { ["findItemData(System.String)"] = function(id) return data_of(id) end }) end
    if name == "app.ObjectManager" then return obj({ PlayerObj = player }) end
    return base_single(name)
end

function coop_net_state() return { kv = { steamSelf = ME, mode = "steam" } } end
function coop_send_event(t) SENT[#SENT + 1] = t end
