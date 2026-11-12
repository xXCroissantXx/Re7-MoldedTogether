"""The friend's flashlight (coop_gunsound.lua, v0.42) in a stand-in game: our own hand light is
measured against our view, then a copy of it (its settings copied) sits at the friend's head and
points where the friend looks, and goes off with "light 0". Usage: python light_test.py <dir>."""
import sys, os, math
import lupa

here = os.path.dirname(os.path.abspath(__file__))
fake = open(os.path.join(here, 'fakegame.lua'), encoding='utf-8').read()
src = open(os.path.join(sys.argv[1], 'coop_gunsound.lua'), encoding='utf-8').read()

STAND = r'''
T = { checks = 0, fails = 0 }
function check(c, what)
    T.checks = T.checks + 1
    if c then print("ok   " .. what) else T.fails = T.fails + 1 print("FAIL " .. what) end
end
local obj_mt = {}
obj_mt.__index = function(t, k)
    if k == "call" then return function(self, name, ...) local f = self.calls and self.calls[name] if f then return f(...) end return nil end end
    if k == "get_field" then return function(self, name) return self.fields and self.fields[name] end end
    if k == "get_address" then return function(self) return self.addr or 1 end end
    if k == "add_ref" then return function(self) return self end end
    if k == "get_type_definition" then return function(self) return self.td end end
    return nil
end
local function obj(fields, calls, addr) return setmetatable({ fields = fields or {}, calls = calls or {}, addr = addr }, obj_mt) end
function transform(pos, rot)
    local tr = { pos = pos, rot = rot }
    tr.o = obj({}, { get_Position = function() return tr.pos end, get_Rotation = function() return tr.rot end,
        set_Position = function(p) tr.pos = p end, set_Rotation = function(q) tr.rot = q end,
        get_Joints = function() return nil end })
    return tr
end
-- A light type with three settings and its parent (via.Component, not copied).
local function m(name, nparams, fn, rtype) return { get_name = function() return name end, get_num_params = function() return nparams end,
    call = function(self, o, ...) return fn(o, ...) end, get_return_type = function() return rtype end } end
local VT = { is_value_type = function() return true end, get_full_name = function() return "System.Single" end }
local REF = { is_value_type = function() return false end, get_full_name = function() return "System.String" end }
local RES = { is_value_type = function() return false end, get_full_name = function() return "via.render.TextureResourceHolder" end }
local COMPONENT_TD = { get_full_name = function() return "via.Component" end, get_methods = function() return {} end, get_parent_type = function() return nil end }
local methods = {
    m("get_Intensity", 0, function(o) return o.v.Intensity end, VT), m("set_Intensity", 1, function(o, v) o.v.Intensity = v end, VT),
    m("get_Radius", 0, function(o) return o.v.Radius end, VT), m("set_Radius", 1, function(o, v) o.v.Radius = v end, VT),
    m("get_IESTexture", 0, function(o) return o.v.IESTexture end, RES), m("set_IESTexture", 1, function(o, v) o.v.IESTexture = v end, RES),
    m("get_Name", 0, function(o) return "x" end, REF), m("set_Name", 1, function(o, v) o.v.Name = v end, REF),
    m("get_Enabled", 0, function(o) return o.v.Enabled end, VT), m("set_Enabled", 1, function(o, v) o.v.Enabled = v end, VT),
}
LIGHT_TD = { get_full_name = function() return "via.render.IESLight" end, get_methods = function() return methods end,
    get_method = function(self, n) for _, mm in ipairs(methods) do if mm.get_name() == n then return mm end end end,
    get_parent_type = function() return COMPONENT_TD end }
function light(go, v)
    local l
    l = obj({}, { get_GameObject = function() return go end, set_Enabled = function(b) l.v.Enabled = b end })
    l.v, l.td = v, LIGHT_TD
    return l
end
CAM = transform({ x = 0, y = 1.6, z = 0 }, { w = 1, x = 0, y = 0, z = 0 })
LIGHT_TR = transform({ x = 0, y = 0, z = 0 }, { w = 1, x = 0, y = 0, z = 0 })
local light_go = obj({}, { get_Transform = function() return LIGHT_TR.o end })
OWN_LIGHT = light(light_go, { Intensity = 900, Radius = 12, IESTexture = "ies_tex", Enabled = true })
local ctl = obj({ Light = OWN_LIGHT })
local hl_go = obj({}, { ["getComponent(System.Type)"] = function() return ctl end })
HL_ON = true
local hl = obj({ HandLight = hl_go }, { get_isHandLightOn = function() return HL_ON end })
BODY = transform({ x = 0, y = 0, z = 0 }, { w = 1, x = 0, y = 0, z = 0 })
FOLDER = obj({}, {}, 555)
PLAYER = obj({}, { ["getComponent(System.Type)"] = function() return hl end, get_Transform = function() return BODY.o end,
    get_Folder = function() return FOLDER end }, 77)
local base_single = sdk.get_managed_singleton
sdk.get_managed_singleton = function(name)
    if name == "app.ObjectManager" then return obj({ PlayerObj = PLAYER }) end
    return base_single(name)
end
local cam_go = obj({}, { get_Transform = function() return CAM.o end })
sdk.get_primary_camera = function() return obj({}, { get_GameObject = function() return cam_go end }) end
-- Objects we make: GameObject.create gives one whose createComponent gives a light.
MADE = {}
local base_find = sdk.find_type_definition
sdk.find_type_definition = function(name)
    if name == "via.GameObject" then
        return { get_method = function() return { call = function(_, _, oname)
            local tr = transform({ x = 0, y = 0, z = 0 }, { w = 1, x = 0, y = 0, z = 0 })
            local go
            go = obj({}, { get_Transform = function() return tr.o end,
                ["createComponent(System.Type)"] = function() local l = light(go, {}) MADE[#MADE + 1] = { go = go, tr = tr, l = l } return l end })
            return go
        end } end }
    end
    return base_find(name)
end
sdk.typeof = function(n) return n end
GHOST_TR = transform({ x = 10, y = 0, z = 5 }, { w = 1, x = 0, y = 0, z = 0 })
GHOST = obj({}, { get_Transform = function() return GHOST_TR.o end }, 99)
coop_ghost = function() return GHOST end
ghost_hidden = false
local_cutscene = function() return false end
LOOK = { 0, 0 }
coop_look_angles = function() return LOOK[1], LOOK[2] end
settings = { friend_light = true }
save_settings = function() end
SENT = {}
coop_send_event = function(t) SENT[#SENT + 1] = t end
held = { sent = "" }
'''

L = lupa.LuaRuntime(unpack_returned_tuples=True)
g = L.globals()
g.HARNESS_MODE = 'nil'
L.execute(fake)
L.execute(STAND)
g.harness_load('coop_gunsound.lua', src)
rep = g.harness_report()
assert not rep, rep

# Our camera looks along -Z (RE Engine cameras), rotated 30 degrees right; our light sits 0.2 m to
# the right and 0.3 m below the eye, turned like the camera.
L.execute('''
local yaw = math.rad(30)
local q = coop_view_q(yaw, 0, -1)
CAM.rot = { w = q.w, x = q.x, y = q.y, z = q.z }
BODY.rot = { w = math.cos(yaw / 2), x = 0, y = math.sin(yaw / 2), z = 0 }   -- the body faces +Z, the same way
-- the light: 0.2 m along the camera's right, 0.3 m down
local function rot(q, x, y, z)
    local tx, ty, tz = 2 * (q.y * z - q.z * y), 2 * (q.z * x - q.x * z), 2 * (q.x * y - q.y * x)
    return x + q.w * tx + (q.y * tz - q.z * ty), y + q.w * ty + (q.z * tx - q.x * tz), z + q.w * tz + (q.x * ty - q.y * tx)
end
local ox, oy, oz = rot(q, 0.2, -0.3, 0)
LIGHT_TR.pos = { x = CAM.pos.x + ox, y = CAM.pos.y + oy, z = CAM.pos.z + oz }
LIGHT_TR.rot = CAM.rot
harness_frames(30)
local fl = coop_gunsound.light
check(fl.rel ~= nil and fl.rel.sign == -1, "our light is measured; the camera looks along -Z")
check(fl.rel and math.abs(fl.rel.ox - 0.2) < 1e-6 and math.abs(fl.rel.oy + 0.3) < 1e-6, "its offset from the view: 0.2 right, 0.3 down")
check(SENT[1] == "light 1", "ours on: light 1")
''')

# The friend: body turned 90 degrees, looking a further 20 degrees left and 15 degrees up.
L.execute('''
GHOST_TR.rot = { w = math.cos(math.rad(90) / 2), x = 0, y = math.sin(math.rad(90) / 2), z = 0 }
LOOK = { math.rad(20), math.rad(15) }
coop_event_slot = 1 coop_gunsound_on_event("light 1") coop_event_slot = nil
harness_frames(5)
check(#MADE == 1, "the friend's light is built")
local p = MADE[1]
check(p and p.l.v.Intensity == 900 and p.l.v.Radius == 12 and p.l.v.IESTexture == "ies_tex", "its settings are copied from ours")
check(p and p.l.v.Name == nil, "but not a name (only plain values and resources)")
check(p and p.l.v.Enabled == true, "and it's on")
local q = p.tr.rot
local function rot(q, x, y, z)
    local tx, ty, tz = 2 * (q.y * z - q.z * y), 2 * (q.z * x - q.x * z), 2 * (q.x * y - q.y * x)
    return x + q.w * tx + (q.y * tz - q.z * ty), y + q.w * ty + (q.z * tx - q.x * tz), z + q.w * tz + (q.x * ty - q.y * tx)
end
-- Our light shines along its -Z (like the camera): the copy's -Z must be the friend's view.
local fx, fy, fz = rot(q, 0, 0, -1)
local yaw, pitch = math.rad(110), math.rad(15)
local ex, ey, ez = math.cos(pitch) * math.sin(yaw), math.sin(pitch), math.cos(pitch) * math.cos(yaw)
check(math.abs(fx - ex) < 1e-6 and math.abs(fy - ey) < 1e-6 and math.abs(fz - ez) < 1e-6,
    string.format("it shines where the friend looks (%.3f %.3f %.3f)", fx, fy, fz))
local pos = p.tr.pos
local d = math.sqrt((pos.x - 10) ^ 2 + (pos.y - 1.6) ^ 2 + (pos.z - 5) ^ 2)
check(math.abs(d - math.sqrt(0.2 ^ 2 + 0.3 ^ 2)) < 1e-6, "at the friend's head, offset like ours")
coop_gunsound_on_event("light 0")
harness_frames(2)
check(p.l.v.Enabled == false, "light 0: it goes off")
settings.friend_light = false
coop_gunsound_on_event("light 1")
harness_frames(2)
check(p.l.v.Enabled == false and #MADE == 1, "with the option off: stays off")
''')

fails, checks = int(L.eval('T.fails')), int(L.eval('T.checks'))
print('light scenarios:', ('FAILED %d of %d' % (fails, checks)) if fails else ('all %d checks passed' % checks))
sys.exit(1 if fails else 0)
