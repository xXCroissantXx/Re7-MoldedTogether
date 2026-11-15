"""Two stand-in games giving each other items through coop_world.lua. v0.55: a gift is put on the ground in
front of the friend with Kingkiller1195's drop (ItemManager.createDropItemInstance), never pushed into an
inventory (createItemInstance + Inventory.addItem crashed an earlier co-op mod). It leaves the giver only
once it's down; a failed drop, no answer and someone else's gift change nothing; the host's key items and
weapons are put down in front of the one behind. Usage: python give_test.py <scripts dir>."""
import sys, os
import lupa

here = os.path.dirname(os.path.abspath(__file__))
fake = open(os.path.join(here, 'fakegame.lua'), encoding='utf-8').read()
give_stand = open(os.path.join(here, 'give_test.lua'), encoding='utf-8').read()
drop_stand = open(os.path.join(here, 'drop_test.lua'), encoding='utf-8').read()
world = open(os.path.join(sys.argv[1], 'coop_world.lua'), encoding='utf-8').read()

def game(me, inv, mode='steam'):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    g = L.globals()
    g.HARNESS_MODE = 'nil'
    L.execute(fake)
    L.execute('ME = "%s"' % me)
    L.execute('INV = {%s}' % ', '.join('%s = %d' % kv for kv in inv.items()))
    L.execute(give_stand)
    L.execute(drop_stand)
    if mode == 'udp':
        L.execute('function coop_net_state() return { kv = { steamSelf = ME, mode = "udp", peer = "127.0.0.1:27961" } } end')
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
    "the host's key items and weapons are listed: " .. coop_inventory_list())
''')

# 1. A gives 5 bullets to B: they're put on the ground in front of B, then leave A.
A.execute('TOK = coop_give_item("76561198000000002", "HandgunBullet", 5, "Guest") check(TOK ~= nil, "the gift goes out")')
A.execute('check(INV.HandgunBullet == 10, "nothing leaves before the friend says it is down")')
deliver(A, B)
B.execute('''
local w = WORLD[#WORLD]
check(#WORLD == 1 and w.id == "HandgunBullet" and w.n == 5, "the 5 bullets are put down in the friend's game (createDropItemInstance)")
check(w and w.pos and math.abs(w.pos.z - (PLAYER_POS.z + 0.8)) < 0.01 and math.abs(w.pos.x - PLAYER_POS.x) < 0.01,
    "in front of the friend's feet")
check(w and w.parent == nil and w.draw_self == true, "let go of the player and drawn")
check((INV.HandgunBullet or 0) == 0, "nothing is put into the friend's inventory (they pick it up)")
''')
deliver(B, A)
A.execute('check(INV.HandgunBullet == 5, "and then they leave the giver (10 -> 5)")')
A.execute('check(world_sync.give_msg and world_sync.give_msg.text:find("Gave Handgun Bullet x5 to Guest", 1, true), "the giver is told: " .. tostring(world_sync.give_msg and world_sync.give_msg.text))')

# 2. The drop fails in the friend's game: nothing leaves the giver, who is told why.
B.execute('NOT_DRAWN = true')
A.execute('coop_give_item("76561198000000002", "RemedyM", 1, "Guest")')
deliver(A, B)
deliver(B, A)
A.execute('check(INV.RemedyM == 2, "a drop that failed: the giver keeps it")')
A.execute('check(world_sync.give_msg.text:find("you keep it", 1, true) ~= nil, "and is told: " .. world_sync.give_msg.text)')
B.execute('NOT_DRAWN = false')

# 3. Something Give items doesn't offer (a key item) is refused by the friend's game too.
B.execute('local n = #WORLD SENT = {} coop_event_slot = 1 coop_world_on_event("give abc124 76561198000000002 Key 1") coop_event_slot = nil '
          'check(#WORLD == n and SENT[1] and SENT[1]:find("give_no abc124 not_shared", 1, true), "a key item can\'t be given: " .. tostring(SENT[1])) SENT = {}')

# 4. No answer in 10 s: nothing taken, and the giver is told.
A.execute('coop_give_item("76561198000000002", "RemedyM", 1, "Guest") SENT = {} harness_frames(660)')
A.execute('check(INV.RemedyM == 2 and world_sync.give_msg.text:find("didn\'t answer", 1, true), "no answer: nothing taken: " .. world_sync.give_msg.text)')

# 5. A gift for someone else is left alone.
B.execute('coop_event_slot = 1 coop_world_on_event("give abc123 76561198000000099 HandgunBullet 3") coop_event_slot = nil')
B.execute('check(#SENT == 0, "a gift for someone else changes nothing")')

# 6. More than we have: refused before anything is sent.
A.execute('SENT = {} local t, why = coop_give_item("76561198000000002", "RemedyM", 5, "Guest") check(t == nil and #SENT == 0, "can\'t give more than you have: " .. tostring(why))')

# 7. The host's key items and weapons (v0.41-v0.54) are retired: an old version's answer puts nothing anywhere.
B.execute('''
local n0 = #WORLD
local n, why = coop_give_missing("Key:1,Handgun:1")
check(n == 0 and why == "retired" and #WORLD == n0, "the host's key items and weapons: retired, nothing is made (" .. tostring(why) .. ")")
''')

# 7b. A drop that comes out as something nobody can pick up (a weapon's or key item's bare object): removed
# again, refused, and the giver keeps theirs. With the pickup part it goes through as before.
B.execute('NO_PICKUP = true')
A.execute('coop_give_item("76561198000000002", "RemedyM", 1, "Guest")')
deliver(A, B)
B.execute('local w = WORLD[#WORLD] check(w.destroyed == true, "a drop with no pickup part is removed again")')
deliver(B, A)
A.execute('check(INV.RemedyM == 2 and world_sync.give_msg.text:find("put down to pick up", 1, true) ~= nil, "and the giver keeps it: " .. world_sync.give_msg.text)')
B.execute('NO_PICKUP = false PICKUP_PARTS = true')
A.execute('coop_give_item("76561198000000002", "RemedyM", 1, "Guest")')
deliver(A, B)
B.execute('local w = WORLD[#WORLD] check(w.id == "RemedyM" and not w.destroyed, "with the pickup part it stays down")')
deliver(B, A)
A.execute('check(INV.RemedyM == 1, "and leaves the giver (2 -> 1)")')
B.execute('PICKUP_PARTS = false')

# 8. A direct (udp) link: the gift is addressed by the lobby's port id (v0.54) and still arrives.
U = game('76561198000000003', {}, mode='udp')
U.execute('coop_event_slot = 1 coop_world_on_event("give abc125 927961 Herb 1") coop_event_slot = nil '
          'check(#WORLD == 1 and WORLD[1].id == "Herb", "on a direct link a gift to the port id arrives")')

# 9. Never an inventory add, anywhere.
for L, who in ((A, 'giver'), (B, 'friend'), (U, 'udp friend')):
    L.execute('check((ADD_CALLS or 0) == 0 and (MADE_CALLS or 0) == 0, "%s: Inventory.addItem and createItemInstance never called")' % who)

fails = sum(int(L.eval('T.fails')) for L in (A, B, U))
checks = sum(int(L.eval('T.checks')) for L in (A, B, U))
print('give scenarios:', ('FAILED %d of %d' % (fails, checks)) if fails else ('all %d checks passed' % checks))
sys.exit(1 if fails else 0)
