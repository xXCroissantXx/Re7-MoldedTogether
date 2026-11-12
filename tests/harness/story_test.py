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
'far away: nothing is started': r'''
T.scenes = { "c03e02_00" }
T.ghost = { x = 40, y = 0, z = 0 }
reset_requests()
friend("story c03e02_00 5")
frames(2)
check(not requested("c03e02_00"), "a friend 40 m away doesn't pull us into their scene")
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
