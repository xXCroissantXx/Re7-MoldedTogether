"""Every check the release build runs, against the scripts in this repo. Run it before every pull request:

    pip install -r tools/requirements.txt
    python tools/check.py

It needs no game: the scripts run in a stand-in game (tests/harness/fakegame.lua) through lupa (Lua 5.4, as in
REFramework). What it checks:
  1. no global is read that nothing defines (a typo, a use before a local exists, a broken edit);
  2. every script loads and runs 300+ frames in the stand-in game in four modes, and logs no "ERR";
  3. the story, menu, give, voice, light and plugin scenarios (two stand-in games talking to each other).
The C# plugin (reframework/plugins/source/CoopNet.cs) is compiled when RE7 starts; check it in the game.
"""
import os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(ROOT, 'reframework', 'autorun')
HARNESS = os.path.join(ROOT, 'tests', 'harness')
LUA_ALL = ['coop_dummy.lua', 'coop_enemies.lua', 'coop_world.lua', 'coop_story.lua', 'coop_talk.lua',
           'coop_gunsound.lua', 'coop_revive.lua', 'coop_saveguard.lua', 'coop_probe.lua', 'coop_menu.lua']
failed = []


def run(args):
    return subprocess.run([sys.executable] + args, capture_output=True, text=True, cwd=ROOT)


def step(name, ok, detail=''):
    print(('ok    ' if ok else 'FAIL  ') + name + ('' if ok or not detail else '\n      ' + detail.strip()[-1500:].replace('\n', '\n      ')))
    if not ok:
        failed.append(name)


g = run([os.path.join(ROOT, 'tools', 'globals_check.py'), SCRIPTS] + LUA_ALL)
bad = [l for l in g.stdout.splitlines() if l.startswith(('UNDEFINED', 'PARSE')) and 'continue' not in l]
step('globals: nothing read that nothing defines', not bad and g.returncode == 0, '\n'.join(bad) + g.stderr)

for args in (['empty'], ['nil'], ['rich'], ['rich', 'menus', '0', 'ch0']):
    r = run([os.path.join(HARNESS, 'run.py'), SCRIPTS] + args)
    lines = [l for l in r.stdout.splitlines()[1:] if l.strip() and not l.startswith('====')]
    errs = [l for l in lines if ' x ' in l]
    step('stand-in game, mode %s: no errors' % ' '.join(args), r.returncode == 0 and not errs, '\n'.join(errs[:10]) + r.stderr[-800:])

for args in (['empty', 'x', '100000'], ['rich', 'x', '100000'], ['rich', 'menus', '100000', 'ch0']):
    r = run([os.path.join(HARNESS, 'run.py'), SCRIPTS] + args)
    logged = [l for l in r.stdout.splitlines() if ' ERR ' in l or l.split(' ', 1)[-1].startswith('ERR')]
    step('stand-in game, mode %s: nothing logged as ERR' % ' '.join(args[:1] + args[3:]), r.returncode == 0 and not logged,
         '\n'.join(logged[:10]) + r.stderr[-800:])

for test, marker in (('story_test.py', 'all passed'), ('menu_test.py', 'checks passed'), ('give_test.py', 'checks passed'),
                     ('drop_test.py', 'checks passed'),
                     ('voice_test.py', 'checks passed'), ('light_test.py', 'checks passed'), ('plugin_test.py', 'checks passed')):
    r = run([os.path.join(HARNESS, test), SCRIPTS])
    fails = [l for l in r.stdout.splitlines() if l.startswith('FAIL')]
    step(test.replace('_test.py', '') + ' scenarios', r.returncode == 0 and marker in r.stdout,
         '\n'.join(fails[:15]) + '\n' + r.stdout[-400:] + r.stderr[-800:])

print()
print('all checks passed' if not failed else '%d check(s) failed: %s' % (len(failed), ', '.join(failed)))
sys.exit(1 if failed else 0)
