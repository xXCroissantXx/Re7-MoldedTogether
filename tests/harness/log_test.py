"""v0.52: repeated log lines are limited, and the log files are cut and written sparingly
(coop_dummy.lua: coop_log_gate / coop_log_flush, used by every script's log()).
python log_test.py <scripts dir>"""
import sys, os
import lupa

d = sys.argv[1]
here = os.path.dirname(os.path.abspath(__file__))
L = lupa.LuaRuntime(unpack_returned_tuples=True)
g = L.globals()
g.HARNESS_MODE = 'rich'
g.HARNESS_MENUS = False
L.execute(open(os.path.join(here, 'fakegame.lua'), encoding='utf-8').read())
g.harness_load('coop_dummy.lua', open(os.path.join(d, 'coop_dummy.lua'), encoding='utf-8').read())

fails = []
def check(cond, msg):
    print(('ok   ' if cond else 'FAIL ') + msg)
    if not cond:
        fails.append(msg)

L.execute('''
LOG_READS = 0
local real_read = fs.read
fs.read = function(p) LOG_READS = LOG_READS + 1 return real_read(p) end
function t_run(who, file, n, make, step)
    -- n log() calls from a script (make(i) is the line), flushed after each simulated step
    local buf, t = {}, 0
    for i = 1, n do
        if coop_log_gate(who, make(i)) then buf[#buf + 1] = "00:00:00 " .. make(i) end
    end
    return buf, t
end
function t_wait(s) FAKE_T = FAKE_T + s end
function t_flush(who, file, buf, t) return coop_log_flush(who, file, buf, t) end
''')

def lines_of(name):
    return [l for l in (g.fsfiles[name] or '').split('\n') if l]

# 1. A line logged on every frame (or a failing call logged on every try): 5 kept, the rest counted.
g.fsfiles['a_log.txt'] = ''
buf, t = g.t_run('a', 'a_log.txt', 1000, L.eval('function(i) return "net ERR attempt " .. i .. " failed" end'), 0)
check(len(buf) == 5, 'a flood of one kind: the first 5 are kept (%d)' % len(buf))
g.t_wait(11)
buf, t = g.t_flush('a', 'a_log.txt', buf, t)
out = lines_of('a_log.txt')
left = [l for l in out if 'left out: 995 more like "net ERR attempt' in l]
check(len(out) == 6 and len(left) == 1, 'one line says 995 more were left out (%d lines written)' % len(out))

# 2. Numbers don't make a new kind; after the window the kind is allowed again.
g.fsfiles['b_log.txt'] = ''
g.t_run('b', 'b_log.txt', 5, L.eval('function(i) return "kill " .. i .. " c01 Molded" end'), 0)
buf, t = g.t_run('b', 'b_log.txt', 5, L.eval('function(i) return "kill " .. (i + 50) .. " c01 Molded" end'), 0)
check(len(buf) == 0, 'the same line with other numbers counts as the same kind')
g.t_wait(11)
buf, t = g.t_run('b', 'b_log.txt', 3, L.eval('function(i) return "kill " .. i .. " c01 Molded" end'), 0)
check(len(buf) == 3, 'a new window allows the kind again')

# 3. Different kinds are not touched, up to 150 lines in a window; then the rest is counted.
g.t_wait(11)
g.fsfiles['c_log.txt'] = ''
buf, t = g.t_run('c', 'c_log.txt', 100, L.eval('function(i) return string.char(97 + i % 26, 97 + (i // 26) % 26) .. " event happened" end'), 0)
check(len(buf) == 100, 'a hundred different lines are all kept (%d)' % len(buf))
g.t_wait(11)
buf, t = g.t_run('c', 'c_log.txt', 400, L.eval('function(i) return string.char(97 + i % 26, 97 + (i // 26) % 26, 97 + (i // 676) % 26) .. " other kind" end'), 0)
check(len(buf) == 150, 'at most 150 lines in 10 s from one script (%d)' % len(buf))
g.t_wait(11)
buf, t = g.t_flush('c', 'c_log.txt', buf, t)
check(any('left out: 250 other lines' in l for l in lines_of('c_log.txt')), 'the rest is counted in one line')

# 4. Scripts are limited separately: one script's flood doesn't silence another's lines.
g.t_wait(11)
g.t_run('noisy', 'n_log.txt', 500, L.eval('function(i) return string.char(97 + i % 26, 97 + (i // 26) % 26) .. " spam" end'), 0)
buf, t = g.t_run('quiet', 'q_log.txt', 3, L.eval('function(i) return string.char(97 + i % 26, 97 + (i // 26) % 26) .. " something happened" end'), 0)
check(len(buf) == 3, "one script's flood doesn't silence another script")

# 5. The file: read once, then its tail is kept in memory; cut to the newest 60 KB at 120 KB, at a line start.
g.fsfiles['big_log.txt'] = ''
g.LOG_READS = 0
buf, t = [], 0
big = L.eval('function(n) local b = {} for i = 1, n do b[i] = string.format("%08d ", i) .. string.rep("w", 90) end return b end')
t_buf = L.table_from(list(big(1300).values()))
t_buf, t = g.t_flush('big', 'big_log.txt', t_buf, 0)
g.t_wait(6)
t_buf = L.table_from(list(big(300).values()))
t_buf, t = g.t_flush('big', 'big_log.txt', t_buf, t)
size = len(g.fsfiles['big_log.txt'])
first = lines_of('big_log.txt')[0]
check(size <= 120000, 'the file stays under 120 KB (%d bytes)' % size)
check(first.startswith('0000') and len(first) == 99, 'cut at a line start (first line is whole)')
check(g.LOG_READS == 1, 'the file is read once, not on every write (%d reads)' % g.LOG_READS)

# 6. A big file is written less often than a small one (each write is the whole file).
g.fsfiles['small_log.txt'] = ''
sb = L.table_from(['x'])
sb, t = g.t_flush('small', 'small_log.txt', sb, 0)
g.t_wait(1.2)
sb = L.table_from(['y'])
sb, t = g.t_flush('small', 'small_log.txt', sb, t)
check(len(lines_of('small_log.txt')) == 2, 'a small file is written again after about a second')
bb = L.table_from(['z'])
g.t_wait(1.2)
bb, t = g.t_flush('big', 'big_log.txt', bb, t)
check(len(bb) == 1, 'a 100 KB file is not rewritten after only a second (kept in the buffer)')
g.t_wait(5)
bb, t = g.t_flush('big', 'big_log.txt', bb, t)
check(len(bb) == 0 and lines_of('big_log.txt')[-1] == 'z', 'and is written within 5 seconds')

# 7. The real scripts use it: after a stand-in session their logs exist and nothing floods.
L2 = lupa.LuaRuntime(unpack_returned_tuples=True)
g2 = L2.globals()
g2.HARNESS_MODE = 'rich'
g2.HARNESS_MENUS = False
L2.execute(open(os.path.join(here, 'fakegame.lua'), encoding='utf-8').read())
for f in ['coop_dummy.lua', 'coop_enemies.lua', 'coop_gunsound.lua', 'coop_probe.lua', 'coop_revive.lua',
          'coop_saveguard.lua', 'coop_story.lua', 'coop_talk.lua', 'coop_world.lua', 'coop_menu.lua']:
    p = os.path.join(d, f)
    if os.path.exists(p):
        g2.harness_load(f, open(p, encoding='utf-8').read())
L2.execute('coop_busy = function() return false end')
g2.harness_frames(60 * 20)
sizes = {k: len(v or '') for k, v in g2.fsfiles.items() if str(k).endswith('_log.txt')}
check(sizes.get('coop_dummy_log.txt', 0) > 0, 'the main script wrote its log (%d bytes)' % sizes.get('coop_dummy_log.txt', 0))
check(all(v < 120000 for v in sizes.values()), 'no log is over 120 KB after a session')

print('log scenarios: ' + ('all %d checks passed' % 16 if not fails else '%d failed' % len(fails)))
sys.exit(1 if fails else 0)
