"""v0.49: the scripts notice when the network plugin isn't running (its status file stops changing).
python plugin_test.py <scripts dir>"""
import sys, os
import lupa

d = sys.argv[1]
ORDER = ['coop_dummy.lua', 'coop_enemies.lua', 'coop_gunsound.lua', 'coop_probe.lua', 'coop_revive.lua',
         'coop_saveguard.lua', 'coop_story.lua', 'coop_talk.lua', 'coop_world.lua', 'coop_menu.lua']
L = lupa.LuaRuntime(unpack_returned_tuples=True)
g = L.globals()
g.HARNESS_MODE = 'nil'
g.HARNESS_MENUS = False
here = os.path.dirname(os.path.abspath(__file__))
L.execute(open(os.path.join(here, 'fakegame.lua'), encoding='utf-8').read())
g.fsfiles['coopnet_status.txt'] = "mode=steam\npeer=-\nversion=0.49\ntime=12:00:00\n"
g.fsfiles['coopnet_in.txt'] = ''
for f in ORDER:
    p = os.path.join(d, f)
    if os.path.exists(p):
        g.harness_load(f, open(p, encoding='utf-8').read())

fails = []
def check(cond, msg):
    print(('ok   ' if cond else 'FAIL ') + msg)
    if not cond:
        fails.append(msg)

dead = lambda: bool(L.eval('coop_plugin_dead and coop_plugin_dead()'))
g.harness_frames(60 * 10)
check(not dead(), 'plugin counted as running in the first 25 s')
# A plugin that's running rewrites its status (the time field) every second.
for s in range(40):
    g.fsfiles['coopnet_status.txt'] = "mode=steam\npeer=-\nversion=0.49\ntime=12:00:%02d\n" % s
    g.harness_frames(60)
check(not dead(), 'a status that keeps changing: running')
g.harness_frames(60 * 15)
check(dead(), 'a status frozen for 15 s: not running')
g.fsfiles['coopnet_status.txt'] = "mode=steam\npeer=-\nversion=0.49\ntime=12:01:00\n"
g.harness_frames(90)
check(not dead(), 'it changes again: running again')
g.fsfiles['coopnet_status.txt'] = None
g.harness_frames(60 * 15)
check(dead(), 'no status file at all: not running')
print('plugin scenarios: ' + ('all %d checks passed' % 5 if not fails else '%d failed' % len(fails)))
sys.exit(1 if fails else 0)
