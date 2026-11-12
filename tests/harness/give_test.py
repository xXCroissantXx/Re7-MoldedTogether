"""Two stand-in games giving each other items through coop_world.lua (v0.42): the item arrives,
and only then leaves the giver; no room, no answer and someone else's gift change nothing; the
v0.41 key-item list now sees the inventory. Usage: python give_test.py <scripts dir>."""
import sys, os
import lupa

here = os.path.dirname(os.path.abspath(__file__))
fake = open(os.path.join(here, 'fakegame.lua'), encoding='utf-8').read()
stand = open(os.path.join(here, 'give_test.lua'), encoding='utf-8').read()
world = open(os.path.join(sys.argv[1], 'coop_world.lua'), encoding='utf-8').read()

def game(me, inv):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    g = L.globals()
    g.HARNESS_MODE = 'nil'
    L.execute(fake)
    L.execute('ME = "%s"' % me)
    L.execute('INV = {%s}' % ', '.join('%s = %d' % kv for kv in inv.items()))
    L.execute(stand)
    g.harness_load('coop_world.lua', world)
    rep = g.harness_report()
    assert not rep, rep
    return L

A = game('76561198000000001', {'HandgunBullet': 10, 'RemedyM': 2, 'Key': 1, 'Handgun': 1})
B = game('76561198000000002', {})

def deliver(src, dst):
    sent = list(src.eval('SENT').values())
    src.execute('SENT = {}')
    for t in sent:
        dst.globals().coop_event_slot = 1
        dst.globals().coop_world_on_event(t)
        dst.globals().coop_event_slot = None
    return sent

A.execute('''
local list = coop_shareable_items()
local names = {}
for _, e in ipairs(list) do names[e.id] = e end
check(names.HandgunBullet and names.HandgunBullet.n == 10, "ammo is in the list to give (x10)")
check(names.RemedyM and names.RemedyM.n == 2, "healing is in the list (x2)")
check(names.Key == nil and names.Handgun == nil, "key items and weapons aren't")
check(names.HandgunBullet and names.HandgunBullet.name == "Handgun Bullet", "a name from the id: " .. tostring(names.HandgunBullet and names.HandgunBullet.name))
check(coop_inventory_list():find("Key:1", 1, true) ~= nil and coop_inventory_list():find("Handgun:1", 1, true) ~= nil,
    "the host's key items and weapons are listed (empty in v0.41): " .. coop_inventory_list())
''')

# 1. A gives 5 bullets to B.
A.execute('TOK = coop_give_item("76561198000000002", "HandgunBullet", 5, "Guest") check(TOK ~= nil, "the gift goes out")')
A.execute('check(INV.HandgunBullet == 10, "nothing leaves before the friend says it arrived")')
out = deliver(A, B)
B.execute('check(INV.HandgunBullet == 5, "the friend has the 5 bullets")')
back = deliver(B, A)
A.execute('check(INV.HandgunBullet == 5, "and then they leave the giver (10 -> 5)")')
A.execute('check(world_sync.give_msg and world_sync.give_msg.text:find("Gave Handgun Bullet x5 to Guest", 1, true), "the giver is told: " .. tostring(world_sync.give_msg and world_sync.give_msg.text))')

# 2. No room: nothing moves.
B.execute('ROOM = false')
A.execute('coop_give_item("76561198000000002", "RemedyM", 1, "Guest")')
deliver(A, B)
B.execute('check((INV.RemedyM or 0) == 0, "no room: the friend gets nothing")')
deliver(B, A)
A.execute('check(INV.RemedyM == 2, "no room: the giver keeps it")')
A.execute('check(world_sync.give_msg.text:find("no room", 1, true), "and is told why: " .. world_sync.give_msg.text)')
B.execute('ROOM = true')

# 3. addItem says nothing went in: the new object is destroyed, nothing taken.
B.execute('ADD_WORKS = false')
A.execute('coop_give_item("76561198000000002", "RemedyM", 1, "Guest")')
deliver(A, B)
B.execute('check(DESTROYED >= 1, "an item that didn\'t go in is removed from the world")')
deliver(B, A)
A.execute('check(INV.RemedyM == 2, "it didn\'t arrive: the giver keeps it")')
# 3b. The game says it was put in but the count didn't move: the object is left alone.
B.execute('ADD_RESULT = 0 DESTROYED = 0')
A.execute('coop_give_item("76561198000000002", "RemedyM", 1, "Guest")')
deliver(A, B)
B.execute('check(DESTROYED == 0, "an item the game says it added is never destroyed")')
deliver(B, A)
A.execute('check(INV.RemedyM == 2, "and the giver keeps theirs (it wasn\'t counted)")')
B.execute('ADD_WORKS = true ADD_RESULT = nil')

# 4. No answer in 10 s: nothing taken, and the giver is told.
A.execute('coop_give_item("76561198000000002", "RemedyM", 1, "Guest") SENT = {} harness_frames(660)')
A.execute('check(INV.RemedyM == 2 and world_sync.give_msg.text:find("didn\'t answer", 1, true), "no answer: nothing taken: " .. world_sync.give_msg.text)')

# 5. A gift for someone else is left alone.
B.execute('coop_event_slot = 1 coop_world_on_event("give abc123 76561198000000099 HandgunBullet 3") coop_event_slot = nil')
B.execute('check(INV.HandgunBullet == 5 and #SENT == 0, "a gift for someone else changes nothing")')

# 6. More than we have: refused before anything is sent.
A.execute('SENT = {} local t, why = coop_give_item("76561198000000002", "RemedyM", 5, "Guest") check(t == nil and #SENT == 0, "can\'t give more than you have: " .. tostring(why))')

fails = int(A.eval('T.fails')) + int(B.eval('T.fails'))
checks = int(A.eval('T.checks')) + int(B.eval('T.checks'))
print('give scenarios:', ('FAILED %d of %d' % (fails, checks)) if fails else ('all %d checks passed' % checks))
sys.exit(1 if fails else 0)
