"""v0.58: saving on by default, and back on after a chapter jump the co-op made (coop_dummy.lua jump_to_chapter and
"Saving back on after a jump"; coop_saveguard.lua's default).
python save_test.py <scripts dir>"""
import sys, os
import lupa

d = sys.argv[1]
here = os.path.dirname(os.path.abspath(__file__))
ORDER = ['coop_dummy.lua', 'coop_enemies.lua', 'coop_gunsound.lua', 'coop_probe.lua', 'coop_revive.lua',
         'coop_saveguard.lua', 'coop_story.lua', 'coop_talk.lua', 'coop_world.lua', 'coop_menu.lua']

fails = []
def check(cond, msg):
    print(('ok   ' if cond else 'FAIL ') + msg)
    if not cond:
        fails.append(msg)

def fresh(settings_json=None):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    g = L.globals()
    g.HARNESS_MODE = 'rich'
    L.execute(open(os.path.join(here, 'fakegame.lua'), encoding='utf-8').read())
    g.fsfiles['coopnet_status.txt'] = "mode=steam\npeer=steam:111\npeerName=Friend\nversion=0.58\nlocalId=222\n"
    g.fsfiles['coopnet_in.txt'] = ''
    if settings_json is not None:   # the stand-in game has no JSON: the file's settings as a Lua table
        L.execute('json.load_file = function(p) if p == "coop_settings.json" then return %s end end' % settings_json)
    for f in ORDER:
        g.harness_load(f, open(os.path.join(d, f), encoding='utf-8').read())
    # Settled in a main chapter: no cutscene, nothing busy (the stand-in game's chapter reads 0).
    L.execute('local_cutscene = function() return false end coop_busy = function() return false end '
              'jump_busy = function() return nil end local_chapter = function() return 5 end')
    g.harness_frames(5)
    return L, g

def seconds(g, s):
    g.harness_frames(int(s * 60))

JUMP = '{ name = "Chapter 3", key = "Chapter3_Start", value = 5 }'

# 1. No settings file at all (the owner's Steam install): saving is on.
L, g = fresh()
check(L.eval('settings.allow_saving') is True, 'no settings file: Allow saving is on')

# 2. A jump the co-op makes (lobby, tape or chapter follow): off for the jump, back on once settled.
L.execute('jump_to_chapter(%s)' % JUMP)
check(L.eval('settings.allow_saving') is False, 'a co-op jump switches saving off first')
check(L.eval('settings.saving_off_for_jump') is True, '... and remembers it was switched off for the jump')
seconds(g, 3)
check(L.eval('chapters.pending') is None, 'the jump itself runs about 2.5 s later')
check(L.eval('settings.allow_saving') is False, 'saving is still off right after the jump')
seconds(g, 30)
check(L.eval('settings.allow_saving') is False, 'still off 30 s after: 20 s since the jump, then 20 s settled')
seconds(g, 15)
check(L.eval('settings.allow_saving') is True, 'back on about 40 s after the jump')
check(L.eval('settings.saving_off_for_jump') is None, '... and the reminder is cleared')

# 3. In a cutscene: it waits until the scene is over.
L, g = fresh()
L.execute('jump_to_chapter(%s)' % JUMP)
L.execute('local_cutscene = function() return true end')
seconds(g, 90)
check(L.eval('settings.allow_saving') is False, 'not switched back on during a cutscene')
L.execute('local_cutscene = function() return false end')
seconds(g, 25)
check(L.eval('settings.allow_saving') is True, 'switched back on 20 s after the cutscene ends')

# 4. The developer chapter switcher's test jump: stays off.
L, g = fresh()
L.execute('jump_to_chapter(%s, true)' % JUMP)
seconds(g, 3)
check(L.eval('settings.saving_off_for_jump') is None, 'a test jump leaves no reminder')
seconds(g, 90)
check(L.eval('settings.allow_saving') is False, 'a test jump leaves saving off')

# 5. The player switched saving off themselves: a jump never turns it on.
L, g = fresh('{ allow_saving = false }')
check(L.eval('settings.allow_saving') is False, 'allow_saving false in the settings file is kept')
L.execute('jump_to_chapter(%s)' % JUMP)
seconds(g, 90)
check(L.eval('settings.allow_saving') is False, "saving the player turned off stays off after a jump")

# 6. On the title screen or in a tape: never switched back on there.
L, g = fresh()
L.execute('jump_to_chapter(%s)' % JUMP)
for ch, what in ((3, 'the title screen'), (10, 'a tape'), (0, 'the boot logo')):
    L.execute('local_chapter = function() return %d end' % ch)
    seconds(g, 60)
    check(L.eval('settings.allow_saving') is False, 'not switched back on in %s (chapter %d)' % (what, ch))
L.execute('local_chapter = function() return 4 end')
seconds(g, 25)
check(L.eval('settings.allow_saving') is True, 'switched back on once in Chapter 1 again')

# 7. The player turns it back on by hand meanwhile: the reminder is dropped.
L, g = fresh()
L.execute('jump_to_chapter(%s)' % JUMP)
seconds(g, 5)
L.execute('settings.allow_saving = true')
seconds(g, 2)
check(L.eval('settings.saving_off_for_jump') is None, 'turned on by hand: the reminder is dropped')

# 8. Following the host into the ending (v0.60, chapter 17, a movie): back on soon after, even during the movie, so the
#    game's clear save at its end can be written.
L, g = fresh()
L.execute('jump_to_chapter(%s)' % JUMP)
L.execute('local_chapter = function() return 17 end')
L.execute('local_cutscene = function() return true end')
seconds(g, 8)
check(L.eval('settings.allow_saving') is False, 'still off right after the jump into the ending')
seconds(g, 10)
check(L.eval('settings.allow_saving') is True, 'back on in the ending, though its movie is playing')
L, g = fresh()
L.execute('jump_to_chapter(%s, true)' % JUMP)
L.execute('local_chapter = function() return 17 end')
seconds(g, 60)
check(L.eval('settings.allow_saving') is False, "a test jump into the ending leaves saving off")

print('save scenarios: ' + ('all checks passed' if not fails else '%d FAILED' % len(fails)))
sys.exit(1 if fails else 0)
