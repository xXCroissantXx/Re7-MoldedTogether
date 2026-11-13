"""v0.52: the friend's head no longer leans sideways when it looks to a side and up or down.
python look_test.py <scripts dir>

The ghost's neck and head each get a share (40 % / 60 %) of the friend's look turn, written as local
rotations; the engine then composes them down the skeleton. What the player sees is that composition, so the
test composes the two shares exactly the way the engine does (world turn of the neck, then of the head) and
measures the roll of the result: how far the head's own right-hand axis leaves the horizontal plane."""
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
local function qmul(a, b)
    return { x = a.w*b.x + a.x*b.w + a.y*b.z - a.z*b.y, y = a.w*b.y - a.x*b.z + a.y*b.w + a.z*b.x,
             z = a.w*b.z + a.x*b.y - a.y*b.x + a.z*b.w, w = a.w*b.w - a.x*b.x - a.y*b.y - a.z*b.z }
end
local function axis(ax, ay, az, ang) local s = math.sin(ang/2) return { x = ax*s, y = ay*s, z = az*s, w = math.cos(ang/2) } end
local function rot(q, x, y, z)       -- q * v * conj(q)
    local r = qmul(qmul(q, { x = x, y = y, z = z, w = 0 }), { x = -q.x, y = -q.y, z = -q.z, w = q.w })
    return r.x, r.y, r.z
end
local BODY = { x = 0, y = 0, z = 0, w = 1 }        -- facing +z, right-hand axis +x
-- The intended turn: yaw about up, then pitch about the right axis the yaw left.
function test_intended(yaw, pitch)
    return qmul(axis(0, 1, 0, yaw), axis(1, 0, 0, -pitch))
end
-- Until v0.51: yaw and pitch each split 40/60 between neck and head, then multiplied.
function test_old(yaw, pitch)
    local function d(share) return qmul(axis(0, 1, 0, yaw * share), axis(1, 0, 0, -pitch * share)) end
    return qmul(d(0.4), d(0.6))               -- neck's world turn, then the head's
end
function test_new(yaw, pitch)
    return qmul(coop_look_turn(BODY, yaw, pitch, 0.4), coop_look_turn(BODY, yaw, pitch, 0.6))
end
-- Roll in degrees: how far the turned right-hand axis (+x) leaves the horizontal plane.
function test_roll(q)
    local _, ry = rot(q, 1, 0, 0)
    return math.deg(math.asin(math.max(-1, math.min(1, ry))))
end
-- Angle between two turns in degrees.
function test_gap(a, b)
    local dot = math.abs(a.x*b.x + a.y*b.y + a.z*b.z + a.w*b.w)
    return math.deg(2 * math.acos(math.min(1, dot)))
end
function test_single(yaw, pitch, share) return coop_look_turn(BODY, yaw, pitch, share) end
''')

yaws = [-1.2, -0.8, -0.4, 0.4, 0.8, 1.2]
pitches = [-0.7, -0.35, 0.35, 0.7]
old_worst = new_worst = gap_worst = 0.0
for y in yaws:
    for p in pitches:
        want = g.test_intended(y, p)
        old_worst = max(old_worst, abs(g.test_roll(g.test_old(y, p))))
        new_worst = max(new_worst, abs(g.test_roll(g.test_new(y, p))))
        gap_worst = max(gap_worst, g.test_gap(g.test_new(y, p), want))

check(old_worst > 4.0, 'the old split leaned the head: up to %.1f degrees of roll over the look range' % old_worst)
check(new_worst < 0.01, 'neck + head now add up with no roll (worst %.4f degrees)' % new_worst)
check(gap_worst < 0.01, 'neck + head now add up to exactly the friend\'s look (worst gap %.4f degrees)' % gap_worst)

# Looking straight ahead: no turn at all; no turn for a zero share; the whole turn for share 1.
ident = g.test_single(0, 0, 0.6)
check(g.test_gap(ident, {'x': 0, 'y': 0, 'z': 0, 'w': 1}) < 1e-6, 'looking straight ahead adds no turn')
check(g.test_gap(g.test_single(0.9, 0.3, 0), {'x': 0, 'y': 0, 'z': 0, 'w': 1}) < 1e-6, 'a zero share adds no turn')
check(g.test_gap(g.test_single(0.9, 0.3, 1), g.test_intended(0.9, 0.3)) < 1e-6, 'a whole share is the whole turn')

# The clamps are as before (70 and 40 degrees): a wild look value can't twist the head further.
check(g.test_gap(g.test_single(3.0, 2.0, 1), g.test_intended(1.2, 0.7)) < 1e-6, 'extreme look values are clamped to 70 / 40 degrees')

# A yaw alone and a pitch alone are plain turns (nothing else changed for the usual look).
check(abs(g.test_roll(g.test_single(0.8, 0.0, 1))) < 1e-6, 'a yaw alone has no roll')
check(abs(g.test_roll(g.test_single(0.0, 0.5, 1))) < 1e-6, 'a pitch alone has no roll')

print('look scenarios: ' + ('all %d checks passed' % 9 if not fails else '%d failed' % len(fails)))
sys.exit(1 if fails else 0)
