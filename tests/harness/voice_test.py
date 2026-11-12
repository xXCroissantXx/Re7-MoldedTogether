"""The friend's voice (coop_gunsound.lua, v0.42) in a stand-in game: the hooked damage, guard
and landing calls send "pv <kind>" once per hit or per tag, only for our own player, and the
receiving side plays that kind's sound from its own player's sound part at the friend's
character, only while it's shown. Usage: python voice_test.py <scripts dir>."""
import sys, os
import lupa

here = os.path.dirname(os.path.abspath(__file__))
fake = open(os.path.join(here, 'fakegame.lua'), encoding='utf-8').read()
src = open(os.path.join(sys.argv[1], 'coop_gunsound.lua'), encoding='utf-8').read()

STAND = r'''
SENT, TRIG, T = {}, {}, { checks = 0, fails = 0 }
function check(c, what)
    T.checks = T.checks + 1
    if c then print("ok   " .. what) else T.fails = T.fails + 1 print("FAIL " .. what) end
end
local obj_mt = {}
obj_mt.__index = function(t, k)
    if k == "call" then return function(self, name, ...) local f = self.calls and self.calls[name] if f then return f(...) end return nil end end
    if k == "get_field" then return function(self, name) return self.fields and self.fields[name] end end
    if k == "get_address" then return function(self) return self.addr or 1 end end
    if k == "get_type_definition" then return function() return { get_full_name = function() return "app.WwiseContainerApp" end, is_a = function() return true end } end end
    return nil
end
local function obj(fields, calls, addr) return setmetatable({ fields = fields or {}, calls = calls or {}, addr = addr }, obj_mt) end
KNOWN = { [1480908325] = true, [55217739] = true, [3338721245] = true, [973764339] = true, [3618666622] = true }
local container = obj({}, {
    ["exists(System.UInt32)"] = function(id) return KNOWN[id] == true end,
    ["trigger(System.UInt32, via.GameObject)"] = function(id, go) TRIG[#TRIG + 1] = { id = id, go = go } end,
})
HEALTH = 500
local dc = obj({ WwiseContainer = container }, { get_health = function() return HEALTH end, get_maxHealth = function() return 1000 end })
PLAYER = obj({}, { ["getComponent(System.Type)"] = function() return dc end }, 77)
OTHER = obj({}, {}, 78)
GHOST = obj({}, {}, 99)
local base_single = sdk.get_managed_singleton
sdk.get_managed_singleton = function(name)
    if name == "app.ObjectManager" then return obj({ PlayerObj = PLAYER }) end
    return base_single(name)
end
-- Hooks by method name; the component handed in decides whose it is.
HOOKS = {}
sdk.hook = function(m, pre, post) HOOKS[m.name] = HOOKS[m.name] or {} table.insert(HOOKS[m.name], pre) end
local COMP = {}
sdk.to_managed_object = function(p) return COMP[p] end
function call_hook(name, owner)
    COMP[1] = obj({}, { get_GameObject = function() return owner end })
    for _, pre in ipairs(HOOKS[name] or {}) do pre({ 0, 1 }) end
end
coop_send_event = function(t) SENT[#SENT + 1] = t end
coop_ghost = function() return GHOST end
ghost_hidden = false
local_cutscene = function() return false end
settings = {}
held = { sent = "" }
function count(prefix) local n = 0 for _, s in ipairs(SENT) do if s == prefix then n = n + 1 end end return n end
'''

L = lupa.LuaRuntime(unpack_returned_tuples=True)
g = L.globals()
g.HARNESS_MODE = 'nil'
L.execute(fake)
L.execute(STAND)
g.harness_load('coop_gunsound.lua', src)
rep = g.harness_report()
assert not rep, rep

L.execute('''
call_hook("processLand", PLAYER)
call_hook("processGuardStart", PLAYER)
check(count("pv land") == 0 and count("pv guard") == 0, "the player has just appeared (a load): no voice for 6 s (v0.44)")
harness_frames(420)
call_hook("playDamageSMotion", PLAYER)
check(count("pv dmg_s") == 1, "a light hit on us: pv dmg_s")
call_hook("playDamageMMotion", OTHER)
check(count("pv dmg_m") == 0, "a hit on anything else: nothing")
for _ = 1, 10 do call_hook("processGuardStart", PLAYER) harness_frames(1) end
check(count("pv guard") == 1, "blocking: the tag runs every frame, one pv guard")
harness_frames(60)
call_hook("processGuardStart", PLAYER)
check(count("pv guard") == 2, "blocking again a second later: another")
call_hook("processLand", PLAYER)
check(count("pv land") == 1, "a landing: pv land")
call_hook("playDeadMotion", PLAYER)
check(count("pv death") == 1, "dying: pv death")
-- Healing: health up with the First Aid Med in hand.
held.sent = "it_RemedyM_FirstAidMed" harness_frames(20) HEALTH = 800 harness_frames(20)
check(count("pv heal") == 1, "healing with a med in hand: pv heal")
held.sent = "" HEALTH = 900 harness_frames(240) HEALTH = 950 harness_frames(20)
check(count("pv heal") == 1, "health up with nothing in hand: no heal sound")
''')

L.execute('''
TRIG = {}
coop_event_slot = 1 coop_gunsound_on_event("pv dmg_s") coop_event_slot = nil
check(#TRIG == 1 and TRIG[1].id == 1480908325 and TRIG[1].go == GHOST, "theirs: SND_MOT_PL_V_DMG_S from our player's sounds, at the friend")
TRIG = {}
coop_gunsound_on_event("pv land")
check(#TRIG == 1 and TRIG[1].id == 973764339, "a landing: the grunt (the thump isn't in these sounds: skipped)")
TRIG = {} ghost_hidden = true
coop_gunsound_on_event("pv dmg_m")
check(#TRIG == 0, "friend not shown (their cutscene...): nothing")
ghost_hidden = false local_cutscene = function() return true end
coop_gunsound_on_event("pv dmg_m")
check(#TRIG == 0, "our cutscene: nothing (it has its own voices)")
local_cutscene = function() return false end settings.friend_voice = false
coop_gunsound_on_event("pv dmg_m")
check(#TRIG == 0, "Your friend's voice off: nothing")
settings.friend_voice = true
check(coop_gunsound_on_event("pv nonsense") == true and #TRIG == 0, "an unknown kind is taken and ignored")
''')

fails, checks = int(L.eval('T.fails')), int(L.eval('T.checks'))
print('voice scenarios:', ('FAILED %d of %d' % (fails, checks)) if fails else ('all %d checks passed' % checks))
sys.exit(1 if fails else 0)
