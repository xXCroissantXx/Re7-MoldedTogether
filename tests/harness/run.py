"""Run the mod's Lua scripts in the stand-in game (fakegame.lua) and print every error that
escapes the scripts' own pcalls. Usage: python run.py <scripts dir> [mode] [menus]"""
import sys, os
import lupa

d = sys.argv[1]
mode = sys.argv[2] if len(sys.argv) > 2 else 'nil'
menus = len(sys.argv) > 3 and sys.argv[3] == 'menus'
ORDER = ['coop_dummy.lua', 'coop_enemies.lua', 'coop_gunsound.lua', 'coop_probe.lua', 'coop_revive.lua',
         'coop_saveguard.lua', 'coop_story.lua', 'coop_talk.lua', 'coop_world.lua', 'coop_menu.lua']

L = lupa.LuaRuntime(unpack_returned_tuples=True)
g = L.globals()
g.HARNESS_MODE = mode
g.HARNESS_MENUS = menus
here = os.path.dirname(os.path.abspath(__file__))
L.execute(open(os.path.join(here, 'fakegame.lua'), encoding='utf-8').read())
status = ("mode=steam\npeer=steam:111\npeerName=Friend\nversion=0.35\nlocalId=222\n")
g.fsfiles['coopnet_status.txt'] = status
g.fsfiles['coopnet_in.txt'] = ''
for f in ORDER:
    p = os.path.join(d, f)
    if os.path.exists(p):
        g.harness_load(f, open(p, encoding='utf-8').read())
g.harness_frames(300)
g.harness_hooks()
# friend events of every kind
events = [
    'story c01e01_00 4', 'prog 46ba27ae 500 4', 'evend 46ba27ae 4', 'saved auto 4',
    'open 4e75531d-addd-47da-b860c9ac6c4ccc49 4', 'close 4e75531d-addd-47da-b860c9ac6c4ccc49 4',
    'unlock 4e75531d-addd-47da-b860c9ac6c4ccc49 4', 'dang 4e75531d-addd-47da-b860c9ac6c4ccc49 45.0 0 4',
    'break b1 4', 'dbreak Box01@1.0,2.0,3.0 4', 'drawer d1 1 4', 'switch s1 1 4', 'intr i1 4', 'intr i2 4 phone', 'intr i3 4 lock',
    'phys Chair@1.0,0.0,1.0 1.2 0.0 1.1 1 0 0 0 4', 'took t1 4 Herb', 'got g1 4 Key',
    'dmg g:abc 4 100.0 Em2000', 'kill g:abc 4 Em2000', 'own g:abc 4 Em2000', 'own g:abc 4 Em2000 333',
    'down 4', 'up', 'gameover', 'pause 1', 'pause 0', 'hp 55', 'look ethan', 'bank 100',
    'grip -0.1 -0.05 0.02 0.56 0.58 -0.46 -0.35 R_Wep', 'weapon Weapon/wp1210 Weapon/wp1210',
    'gsnd wp1210 a.wcc;b.wel', 'gfx wp1210 a.efx b.efx', 'gshot wp1210', 'gswing wp1190', 'greload wp1210', 'gshot wp1230', 'gswing wp0040',
    'opt share_story 1 1793759224', 'ver 0.35', 'catchup_req', 'rewind 4 300', 'story em3000_10 4', 'catchup drawer d1 1 4|unlock u1 4',
    'lobby ethan', 'lobby open 76561198000000009 1 Chapter3_Start 5', 'lobby me 1 game here', 'lobby go 76561198000000009 2 here 5', 'lobby closed 76561198000000009', 'kused Key 1 4', 'inv_req 222', 'inv Key:1,Handgun:1', 'spos 4 300', 'lobby bye 76561198000000009', 'ping 1 2 3', 'report_req', 'heal 10', 'ehp g:abc 4 500',
    '@2 story c01e01_00 4', '@2 down 4', '@2 up', '@3 hp 10', '@2 gshot wp1210', '@3 own g:abc 4 Em2000 444',
    # v0.42
    'pv dmg_s', 'pv guard', 'pv land', 'pv up', 'pv death', 'pv heal', 'pv bogus', 'light 1', 'light 0', 'light 1',
    'stats 1 2 3 4 5 6 7', 'spos 4 300 1', 'spos 4 300 2', 'give abc123 222 HandgunBullet 5', 'give_ok abc123 5',
    'give_no abc123 no_room', '@2 pv dmg_m', '@2 light 1', '@3 stats 9 9 9 9 9 9 9',
    # v0.43
    'talk ammo 4 1 2 3', 'talk meds 4 1 2 3', '@2 talk meds 4 1 2 3', 'talk bogus 4 1 2 3',
    # v0.47: banks the friend's game added to their body
    'mbank 3 1 Animation/Player/pl0000/pl0000_test.motlist', 'mbank 3 1 Animation/Player/pl0000/pl0000_test.motlist',
    '@2 mbank 10 0 Animation/Player/pl0000/other.motlist', 'mbank bad',
]
import re as _re
if len(sys.argv) > 5:
    # The stand-in game is in chapter 0, and story sharing on, so every handler runs.
    events = [_re.sub(r' 4( |$)', r' 0\1', e) for e in events]
    events = ['opt share_story 1 1793759224'] + events
g.harness_events(L.table_from(events))
g.harness_frames(600)
g.harness_hooks()
# The cutscene ends: held changes are applied.
L.execute('local_cutscene = function() return false end; coop_scene_t = nil')
g.harness_frames(300)
print('mode', mode, 'menus', menus, 'callbacks', len(g.callbacks.frame), 'hooks', len(g.hooks))
print(g.harness_report())
if len(sys.argv) > 4:
    for k in sorted(g.fsfiles.keys()):
        v = g.fsfiles[k]
        if 'log' in k:
            print('====', k)
            print('\n'.join(str(v).split('\n')[-int(sys.argv[4]):]))
