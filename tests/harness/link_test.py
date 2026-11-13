"""v0.52: the friend's playback delay follows the link (coop_dummy net.update_delay / net.slew_delay), and the
sample file is only parsed when it changed.
python link_test.py <scripts dir>

The stand-in plugin writes coopnet_in.txt the way CoopNet.cs does: the newest 32 samples, one per line,
"seq t px py pz qx qy qz qw flags chapter echo yaw pitch" (t is the sender's clock). The sender's clock here
is the receiver's minus a fixed 10 s, so only the differences matter, as on two real PCs."""
import sys, os
import lupa

d = sys.argv[1]
ORDER = ['coop_dummy.lua', 'coop_enemies.lua', 'coop_gunsound.lua', 'coop_probe.lua', 'coop_revive.lua',
         'coop_saveguard.lua', 'coop_story.lua', 'coop_talk.lua', 'coop_world.lua', 'coop_menu.lua']
CLOCK_SKEW = 10.0


def new_game():
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    g = L.globals()
    g.HARNESS_MODE = 'rich'
    g.HARNESS_MENUS = False
    here = os.path.dirname(os.path.abspath(__file__))
    L.execute(open(os.path.join(here, 'fakegame.lua'), encoding='utf-8').read())
    g.fsfiles['coopnet_status.txt'] = "mode=steam\npeer=steam:76561198000000001\nversion=0.52\ntime=12:00:00\n"
    g.fsfiles['coopnet_in.txt'] = ''
    for f in ORDER:
        p = os.path.join(d, f)
        if os.path.exists(p):
            g.harness_load(f, open(p, encoding='utf-8').read())
    # The stand-in game never says a load is over: without this every script's frame work waits.
    L.execute('coop_busy = function() return false end')
    return L, g


fails = []
def check(cond, msg):
    print(('ok   ' if cond else 'FAIL ') + msg)
    if not cond:
        fails.append(msg)


def run_link(seconds, late_every=0, late_by=0.0, mutate=None):
    """A friend sending 30 samples a second over one path, so a hold-up delays everything behind it too
    (samples reach us in order, as Steam's channel delivers them). Every late_every-th sample is held
    late_by seconds, and what was sent in that time arrives with it."""
    L, g = new_game()
    net = g.coop_net_state()
    lines, seq, pending, prev_release = [], 0, [], 0.0
    frames = int(seconds * 60)
    for i in range(frames):
        now = g.FAKE_T + 1 / 60            # the clock the game will see in this frame
        if i % 2 == 0:
            seq += 1
            sent = now - 0.03 - CLOCK_SKEW          # 30 ms one way, the sender's clock is 10 s behind
            line = "%d %.4f 1.0 0.0 %.3f 0 0 0 1 4 1 0 0 0" % (seq, sent, seq * 0.01)
            release = now + (late_by if late_every and seq % late_every == 0 else 0.0)
            release = max(release, prev_release)
            prev_release = release
            pending.append((release, line))
        due = [p for p in pending if p[0] <= now]
        pending = [p for p in pending if p[0] > now]
        lines += [p[1] for p in due]
        lines = lines[-32:]
        g.fsfiles['coopnet_in.txt'] = "\n".join(lines) + "\n"
        if mutate:
            mutate(net, i)
        g.harness_frames(1)
    return L, g, net


# 1. A clean link: the delay comes down from the old fixed 0.15 s to the floor and stays there.
L, g, net = run_link(12)
check(abs(net.DELAY_MIN - 0.08) < 1e-9, 'the floor is 80 ms')
check(net.delay <= 0.09 and net.delay >= 0.08, 'clean link: delay settled at the floor (%.3f s)' % net.delay)
check(net.jitter is not None and net.jitter < 0.03, 'clean link: late tail measured small (%.3f s)' % (net.jitter or -1))
check(len(net.history) > 20, 'clean link: samples reach the history (%d)' % len(net.history))

# 2. A link that holds one sample in ten back 120 ms: the delay rises to cover it, quickly.
L, g, net = run_link(8, late_every=10, late_by=0.12)
check(0.15 <= net.delay <= 0.2, 'late tail 120 ms: delay rose to cover it (%.3f s, wanted %.3f)' % (net.delay, net.delay_target))
check(0.11 <= net.jitter <= 0.14, 'late tail 120 ms: measured as such (%.3f s)' % net.jitter)

# 3. A very bad link: the delay is capped.
L, g, net = run_link(15, late_every=4, late_by=0.6)
check(abs(net.delay - 0.30) < 1e-6, 'very late samples: delay capped at 0.30 s (%.3f)' % net.delay)

# 4. By hand (the debug buttons): the delay is left alone.
def fixed(net, i):
    if i == 0:
        net.adaptive, net.delay = False, 0.15
L, g, net = run_link(10, mutate=fixed)
check(abs(net.delay - 0.15) < 1e-9, 'fixed mode: delay not touched (%.3f s)' % net.delay)

# 5. It rises faster than it falls (an underrun is a stutter; a long delay is only a lag).
check(net.RISE_PER_S > 3 * net.FALL_PER_S, 'rises faster than it falls')

# 6. The file is parsed only when it changed: a file that stays the same adds no samples.
L, g, net = run_link(3)
n0, seen0, p0 = net.rx_count, len(net.history), net.parses
g.harness_frames(120)
check(net.rx_count == n0 and len(net.history) == seen0 and net.parses == p0,
      'unchanged file: not parsed again in 2 s (%d parses so far, %d samples)' % (net.parses, net.rx_count or 0))

# 7. One line about the link every 30 s for bug reports, and nothing more often.
L, g, net = run_link(75)
g.harness_frames(300)
log = g.fsfiles['coop_dummy_log.txt'] or ''
n = log.count('link: round trip')
check(2 <= n <= 3, 'a link line about every 30 s (%d in 75 s)' % n)

print('link scenarios: ' + ('all %d checks passed' % 12 if not fails else '%d failed' % len(fails)))
sys.exit(1 if fails else 0)
