"""Story scenarios through coop_story.lua (v0.39): scene sequences, held progress, loading a
save. Usage: python story_test.py <scripts dir>. Exits 1 on any failed check."""
import sys, os
import lupa

here = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(sys.argv[1], 'coop_story.lua'), encoding='utf-8').read()
fake = open(os.path.join(here, 'story_test.lua'), encoding='utf-8').read()

SCENARIOS = {
'dinner: friend escapes while we are still at the table': r'''
T.scenes = { "c03e00_00", "c03e00_01", "c03e00_02", "c03e01_00" }
our_scene("c03e00_00")
frames(5)
reset_requests()
friend("story c03e00_01 5")
friend("story c03e00_02 5")
frames(2)
check(not requested("c03e00_01") and not requested("c03e00_02"), "the friend's escape is not started in the middle of our dinner")
-- Their progress from the end of the dinner waits while our dinner sequence is still open.
friend("prog 9fb77189 100 5")
frames(2)
check((T.prog[0x9fb77189] or 0) == 0, "their end-of-dinner progress is held while our sequence is open")
-- We rock the chair and our own escape plays (a cutscene).
T.cutscene = true
our_scene("c03e00_01")
our_scene("c03e00_02")
frames(5)
check((T.prog[0x9fb77189] or 0) == 0, "still held while our escape plays")
T.cutscene = false
our_scene_ends("c03e00_02")
-- Our own game moves the chapter on itself after the escape.
frames(1)
our_prog(0x9fb77189, 100)
frames(12)
check(T.set_prog == 0, "the mod never had to set it: our game got there itself")
''',
'late arrival: friend is partway through a sequence we have not started': r'''
T.scenes = { "c03e00_00", "c03e00_01", "c03e00_02" }
reset_requests()
friend("story c03e00_01 5")
frames(3)   -- v0.48: a friend's scene waits 1.5 s for a story step that may play it
check(requested("c03e00_00"), "the sequence starts here from its first scene")
check(not requested("c03e00_01"), "not from the friend's scene in the middle of it")
''',
'chapter start: a later-numbered scene plays first in both games (c04e12_01 before c04e12_00)': r'''
T.scenes = { "c04e12_00", "c04e12_01" }
reset_requests()
friend("story c04e12_01 5")
-- our own game plays the same setup scene a moment later, before the stand-in _00 is started
our_scene("c04e12_01")
our_scene_ends("c04e12_01")
frames(4)
check(not requested("c04e12_00"), "the friend's _01 doesn't start _00 here when our game played _01 itself")
reset_requests()
friend("story c04e12_00 5")
frames(4)
check(requested("c04e12_00"), "the host's _00 later plays here (our sequence is already past it)")
''',
'a new sequence starts for both': r'''
T.scenes = { "c03e01_00", "c03e01_01" }
reset_requests()
friend("story c03e01_00 5")
frames(3)
check(requested("c03e01_00"), "the friend's first scene of a sequence plays here")
reset_requests()
friend("story c03e01_01 5")
frames(2)
check(not requested("c03e01_01"), "its next scene is ours to reach (we're in the sequence now)")
''',
'the friend\'s next part comes while their first part is still playing here (c04e71)': r'''
T.scenes = { "c03e31_00", "c03e31_01" }
reset_requests()
friend("story c03e31_00 5")
frames(3)
check(requested("c03e31_00"), "the friend's first part plays here")
our_scene("c03e31_00")
T.cutscene = true
reset_requests()
friend("story c03e31_01 5")
frames(2)
check(not requested("c03e31_01"), "their next part waits while the first still plays here")
check(not requested("c03e31_00"), "the first part isn't asked for again")
T.cutscene = false
our_scene_ends("c03e31_00")
frames(4)
check(requested("c03e31_01"), "their next part plays here once the first is over (it was lost: no flashback 3)")
''',
'far away: nothing is started': r'''
-- v0.52 rule: a cutscene pulls in everyone within SCENE_PULL_MAX (200 m); beyond that nothing is started.
T.scenes = { "c03e02_00" }
T.ghost = { x = 300, y = 0, z = 0 }
reset_requests()
friend("story c03e02_00 5")
frames(2)
check(not requested("c03e02_00"), "a friend 300 m away doesn't pull us into their scene")
T.ghost = { x = 3, y = 0, z = 0 }
''',
'loading an earlier save': r'''
T.scenes = { "c03e00_00", "c03e00_01", "c03e00_02" }
our_prog(0x2c60d2ac, 100)
our_scene("c03e00_00")
our_scene("c03e00_01")
our_scene("c03e00_02")
frames(1)
our_prog(0x9fb77189, 100)
frames(1)
reset_requests()
-- The save from before the dinner is loaded: the player object changes, progress goes back.
hook_load = T.hooks["app.SaveDataManager.loadLevelUsingLoadData"]
check(hook_load ~= nil, "the level load is watched")
if hook_load then hook_load({}) end
T.no_player = true
frames(3)
T.no_player = false
T.player_addr = 2000
T.prog[0x9fb77189] = 0
frames(10)
check(sent("rewind 5"), "the friend is told we loaded a save")
friend("story c03e00_00 5")
frames(2)
-- v0.51: not in the first seconds after a load (a scene started then left the screen black for good) ...
check(not requested("c03e00_00"), "a friend's scene right after our load waits for the load to settle")
frames(14)
-- ... and once it has settled, it plays.
check(requested("c03e00_00"), "after loading the save, the friend's dinner can start here again")
''',
'loading the save from just before the dinner (every stage at 0)': r'''
T.scenes = { "c03e00_00", "c03e00_01", "c03e00_02" }
our_prog(0x9fb77189, 0)
our_prog(0x2c60d2ac, 0)
our_scene("c03e00_00")
frames(1)
T.hooks["app.SaveDataManager.loadLevelUsingLoadData"]({})
T.player_addr = 3000
frames(10)
reset_requests()
friend("story c03e00_00 5")
frames(3)
check(requested("c03e00_00"), "the dinner can play again after loading the save from before it")
''',
'loading a save from after the dinner keeps it played': r'''
T.scenes = { "c03e00_00", "c03e00_01", "c03e00_02" }
our_prog(0x9fb77189, 0)
our_scene("c03e00_00")
our_scene("c03e00_01")
our_scene("c03e00_02")
our_prog(0x9fb77189, 100)
frames(1)
T.hooks["app.SaveDataManager.loadLevelUsingLoadData"]({})
T.player_addr = 4000
frames(10)
reset_requests()
friend("story c03e00_00 5")
frames(2)
check(not requested("c03e00_00"), "a save from after the dinner never replays it")
''',
'gates: ours turns on 5 s after it is off while the friend\'s is on': r'''
gate("CanOpenInventory", false)
frames(11)   -- the gate list is read
friend("tcan CanOpenInventory 5 1")
frames(3)
check(T.gates.CanOpenInventory == false, "not at once (the step's own moment)")
frames(4)
check(T.gates.CanOpenInventory == true, "on again once it has been off 5 s while the friend's is on")
''',
'gates: our states go out again every 30 s (a message lost while loading)': r'''
gate("CanOpenInventory", true)
frames(11)
T.sent = {}
frames(31)
check(sent("tcan CanOpenInventory 5 1"), "the unchanged gate is told again within 30 s")
''',
'gates: a story moment here that keeps it off is left alone, then tried again after 30 s': r'''
gate("CanOpenMap", false)
frames(11)
T.hold.CanOpenMap = true
friend("tcan CanOpenMap 5 1")
frames(20)
local n = T.gate_sets or 0
check(n == 2, "turned on twice and turned back off by the game twice, then left alone (sets: " .. n .. ")")
-- The friend's gate flips at a story step: not a reason to fight the hold again.
friend("tcan CanOpenMap 5 0")
frames(1)
friend("tcan CanOpenMap 5 1")
frames(10)
check((T.gate_sets or 0) == n, "the friend's step flip doesn't restart the fight (sets: " .. (T.gate_sets or 0) .. ")")
-- The hold ends but the game doesn't turn the gate on itself (the v0.66 case): the retry after 30 s does.
T.hold.CanOpenMap = false
frames(25)
check(T.gates.CanOpenMap == true, "tried again once the 30 s are up: on, and it stays on")
''',
'gates: the game turning ours on itself ends the give-up at once': r'''
gate("CanChangeWeapon", false)
frames(11)
T.hold.CanChangeWeapon = true
friend("tcan CanChangeWeapon 5 1")
frames(20)
local n = T.gate_sets or 0
T.hold.CanChangeWeapon = false
T.gates.CanChangeWeapon = true     -- our story moment ends: the game turns it on
frames(1)
T.gates.CanChangeWeapon = false    -- and a later moment turns it off again
frames(7)
check(T.gates.CanChangeWeapon == true and (T.gate_sets or 0) == n + 1, "a fresh off after the game's own on is fixed in 5 s, not 30")
''',
'busy: the friend\'s scene waits until we are back': r'''
T.scenes = { "c03e03_00" }
reset_requests()
T.cutscene = true
friend("story c03e03_00 5")
frames(1)
check(not requested("c03e03_00"), "not started while our own cutscene plays")
T.cutscene = false
frames(3)
check(requested("c03e03_00"), "started once our cutscene is over")
''',
}

fails = 0
for name, code in SCENARIOS.items():
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(fake)
    f = L.eval('function(src) local f, e = load(src, "@coop_story.lua") if not f then error(e) end f() end')
    f(src)
    print('==', name)
    L.execute(code)
    fails += int(L.eval('T.fails'))
print('story scenarios:', 'FAILED %d' % fails if fails else 'all passed')
sys.exit(1 if fails else 0)
