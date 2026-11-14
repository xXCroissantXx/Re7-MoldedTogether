"""v0.52: the Debug section of the Molded Together window (coop_dummy.lua: coop_dbg, coop_note, coop_task, coop_dbg_ui).
Every frame callback and hook of every script is listed and, with Measure on, timed; every one has a description.
python debug_test.py <scripts dir>"""
import sys, os
import lupa

d = sys.argv[1]
here = os.path.dirname(os.path.abspath(__file__))
ORDER = ['coop_dummy.lua', 'coop_enemies.lua', 'coop_gunsound.lua', 'coop_probe.lua', 'coop_revive.lua',
         'coop_saveguard.lua', 'coop_story.lua', 'coop_talk.lua', 'coop_world.lua', 'coop_menu.lua']

L = lupa.LuaRuntime(unpack_returned_tuples=True)
g = L.globals()
g.HARNESS_MODE = 'rich'
g.HARNESS_MENUS = True          # the window's sections and trees open, so the Debug section is drawn
L.execute(open(os.path.join(here, 'fakegame.lua'), encoding='utf-8').read())
g.fsfiles['coopnet_status.txt'] = "mode=steam\npeer=steam:111\npeerName=Friend\nversion=0.35\nlocalId=222\n"
g.fsfiles['coopnet_in.txt'] = ''
for f in ORDER:
    g.harness_load(f, open(os.path.join(d, f), encoding='utf-8').read())

fails = []
def check(cond, msg):
    print(('ok   ' if cond else 'FAIL ') + msg)
    if not cond:
        fails.append(msg)

L.execute('''
function t_rows()
    local out = {}
    for _, r in ipairs(coop_dbg.order) do out[#out + 1] = r end
    return out
end
function t_find(name)
    for _, r in ipairs(coop_dbg.order) do if r.name == name or (r.name and r.name:find(name, 1, true)) then return r end end
end
''')

# 1. Everything that registers is listed, and everything listed is described.
nrows = int(L.eval('#coop_dbg.order'))
nframe = int(L.eval('(function() local n = 0 for _, r in ipairs(coop_dbg.order) do if r.kind == "every frame" then n = n + 1 end end return n end)()'))
check(nrows > 100, 'the registry lists every callback, hook and task (%d rows)' % nrows)
check(nframe >= 60, 'at least the 60-odd frame callbacks are in it (%d)' % nframe)
plain = L.eval('(function() local t = {} for _, r in ipairs(coop_dbg.order) do if r.feature == nil then t[#t + 1] = (r.src or "?") .. ":" .. tostring(r.line) .. " " .. tostring(r.kind) end end return table.concat(t, "; ") end)()')
check(plain == '', 'every callback and hook has a description (a new one needs a coop_note above it): %s' % plain)
check(L.eval('coop_dbg.patch_err') is None, 'the game callbacks could be wrapped')

# 2. A row knows the file and line that registered it (not the wrapper in the script's header).
r = L.eval('(function() for _, r in ipairs(coop_dbg.order) do if r.feature == "Loading guard" then return r end end end)()')
check(r is not None and r.src == 'coop_dummy.lua' and 40 < r.line < 400, 'a callback is labelled with the line that registered it (%s:%s)' % (r and r.src, r and r.line))
r = L.eval('(function() for _, r in ipairs(coop_dbg.order) do if r.feature == "Friend\'s head look" and r.kind:find("PrepareRendering", 1, true) and r.kind:find("before", 1, true) then return r end end end)()')
check(r is not None and r.src == 'coop_dummy.lua', 'a render-step callback is listed with its step in the kind (%s)' % (r and r.kind))
hooks_listed = int(L.eval('(function() local n = 0 for _, r in ipairs(coop_dbg.order) do if r.kind and r.kind:find("when the game calls", 1, true) then n = n + 1 end end return n end)()'))
check(hooks_listed >= 20, 'the hooks are listed by the method they hook (%d; the stand-in game gives every method one name, so some merge)' % hooks_listed)

# 3. With Measure off nothing is recorded.
g.harness_frames(120)
total_n = int(L.eval('(function() local n = 0 for _, r in ipairs(coop_dbg.order) do n = n + r.n end return n end)()'))
check(total_n == 0, 'Measure off: nothing is counted (%d)' % total_n)

# 4. Measure on: runs are counted, and a task with its own timer shows its real cadence.
# (The stand-in game gives a new player object on every read, which the loading guard reads as "the player was
# swapped": the scripts' frame work would wait for ever. Say it is not loading.)
L.execute('coop_busy = function() return false end')
L.execute('coop_dbg_set_measure(true)')
g.harness_frames(600)       # 10 s of the stand-in game
guard = L.eval('(function() for _, r in ipairs(coop_dbg.order) do if r.feature == "Loading guard" then return r end end end)()')
check(guard is not None and 590 <= guard.n <= 610, 'a per-frame callback runs once a frame (%s runs in 600 frames)' % (guard and guard.n))
door = L.eval('t_find("Watch every door")')
scan = L.eval('t_find("Scan the scene for doors")')
check(door is not None and 10 <= door.n <= 45, 'the door poll runs about 4 times a second, not every frame (%s runs in 10 s)' % (door and door.n))
check(scan is not None and 1 <= scan.n <= 5, 'the door scan runs about every 3 s (%s runs in 10 s)' % (scan and scan.n))
check(door is not None and door.total >= 0 and door.max >= 0, 'time is accumulated')

# 5. The report and the window section.
rep = str(L.eval('coop_dbg_report()'))
for want in ('== Doors', '== Follow into VHS tapes', 'looks at:', 'changes:', 'every 0.25 s', 'runs/s'):
    check(want in rep, 'the report has "%s"' % want)
check('Not described yet' not in rep, 'the report has nothing undescribed')
L.execute('''
T_TEXT = {}
local real = imgui.text
imgui.text = function(s) T_TEXT[#T_TEXT + 1] = tostring(s) end
imgui.text_wrapped = imgui.text
coop_dbg_ui()
imgui.text, imgui.text_wrapped = real, nil
''')
shown = [str(v) for v in g.T_TEXT.values()]
check(any('looks at:' in s for s in shown), 'the section lists what each feature looks at (%d lines)' % len(shown))
check(any('Heaviest' in s or 'ms per second of play' in s for s in shown), 'the section totals the cost')
L.execute('coop_dbg_reset()')
check(int(L.eval('(function() local n = 0 for _, r in ipairs(coop_dbg.order) do n = n + r.n end return n end)()')) == 0, 'Reset numbers clears the counts')

# 6. The wrappers are transparent: return values, errors and hook results pass straight through.
L.execute('''
coop_dbg_set_measure(true)
local f = coop_task("T", "swap", function(a, b) return b, a, nil, "x" end, {})
T_A, T_B, T_C, T_D = f(1, 2)
local boom = coop_task("T", "boom", function() error("bang") end, {})
T_OK, T_ERR = pcall(boom)
local m = { name = "fake" }
local seen
sdk.hook(m, function(args) seen = args[1] return sdk.PreHookResult.SKIP_ORIGINAL end, function(r) return r + 1 end)
local h = hooks[#hooks]
T_PRE = h.pre({ 7 })
T_POST = h.post(41)
T_SEEN = seen
''')
check((g.T_A, g.T_B, g.T_D) == (2, 1, 'x'), 'a task returns what its function returns')
check(g.T_OK is False and 'bang' in str(g.T_ERR), 'a task that fails fails the same way')
boom = L.eval('t_find("boom")')
check(boom is not None and boom.n == 1 and boom.errs == 1, 'a run that threw is counted, and counted as an error')
check(g.T_PRE == 1 and g.T_SEEN == 7 and g.T_POST == 42, 'a hook gets its arguments and its results are passed on (skip original, return value)')

# 7. A note belongs to the registration below it, in its own file, and only if close enough.
L.execute('''
coop_note{ feature = "Test feature", name = "Close one", when = "every frame", reads = "a", writes = "b" }
re.on_frame(function() end)
coop_note{ feature = "Test feature", name = "Far one", when = "every frame", reads = "a", writes = "b" }
''' + '\n'.join(['local pad = 1'] * 16) + '''
re.on_frame(function() end)
''')
check(L.eval('t_find("Close one")') is not None, 'a note just above a registration describes it')
check(L.eval('t_find("Far one")') is None, 'a note too far above one is not taken for it')

print()
print('debug scenarios:', ('FAILED %d' % len(fails)) if fails else 'all checks passed')
sys.exit(1 if fails else 0)
