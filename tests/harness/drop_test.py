"""Two stand-in games dropping discarded items for each other through coop_world.lua (v0.51): a supply
one player discards in the inventory lands on the ground at the same spot in the other game, and
nothing is ever made in or taken out of an inventory. Key items, malformed messages, the option switched
off, nobody connected, a friend too far away or in another chapter, an object that isn't drawn and no
answer in 10 s change nothing. Usage: python drop_test.py <scripts dir>."""
import sys, os
import lupa

here = os.path.dirname(os.path.abspath(__file__))
fake = open(os.path.join(here, 'fakegame.lua'), encoding='utf-8').read()
give_stand = open(os.path.join(here, 'give_test.lua'), encoding='utf-8').read()
drop_stand = open(os.path.join(here, 'drop_test.lua'), encoding='utf-8').read()
world = open(os.path.join(sys.argv[1], 'coop_world.lua'), encoding='utf-8').read()


def game(me, inv, pos):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    g = L.globals()
    g.HARNESS_MODE = 'nil'
    L.execute(fake)
    L.execute('ME = "%s"' % me)
    L.execute('INV = {%s}' % ', '.join('%s = %d' % kv for kv in inv.items()))
    L.execute(give_stand)
    L.execute(drop_stand)
    L.execute('PLAYER_POS = { x = %s, y = %s, z = %s }' % pos)
    g.harness_load('coop_world.lua', world)
    rep = g.harness_report()
    assert not rep, rep
    L.execute('harness_hooks_done = true')   # the discard hook is installed at load; harness_hooks() isn't run here
    return L


A = game('76561198000000001', {'Herb': 3, 'HandgunBullet': 20, 'Key': 1, 'Handgun': 1}, (10, 0, 5))
B = game('76561198000000002', {}, (10, 0, 6))


def deliver(src, dst):
    sent = list(src.eval('SENT').values())
    src.execute('SENT = {}')
    for t in sent:
        dst.globals().coop_event_slot = 1
        dst.globals().coop_world_on_event(t)
        dst.globals().coop_event_slot = None
    return sent


def frames(game_, n=30):
    game_.globals().harness_frames(n)


def count(game_, expr):
    return int(game_.eval(expr))


# 1. A discards a Herb: it lands in front of A, and the same spot in B; B answers; nothing in an inventory moves.
A.execute('discard("Herb", 1)')
A.execute('check(#WORLD == 0, "nothing is done inside the game\'s own discard call")')
frames(A)
A.execute('check(#WORLD == 1 and WORLD[1].id == "Herb" and WORLD[1].n == 1, "the discarded Herb is on A\'s ground")')
A.execute('check(WORLD[1].parent == nil and WORLD[1].draw_self == true and WORLD[1].update_self == true, "let go of the player, drawn and updated")')
A.execute('check(math.abs(WORLD[1].pos.x - 10) < 0.01 and math.abs(WORLD[1].pos.z - 5.8) < 0.01 and math.abs(WORLD[1].pos.y - 0.1) < 0.01, "0.8 m in front, 0.1 m up: " .. WORLD[1].pos.x .. " " .. WORLD[1].pos.y .. " " .. WORLD[1].pos.z)')
sent = deliver(A, B)
assert len(sent) == 1 and sent[0].startswith('drop '), sent
B.execute('check(#WORLD == 1 and WORLD[1].id == "Herb" and WORLD[1].n == 1, "the same item is on B\'s ground")')
B.execute('check(math.abs(WORLD[1].pos.x - 10) < 0.01 and math.abs(WORLD[1].pos.z - 5.8) < 0.01, "at the same spot")')
B.execute('check(next(INV) == nil and DESTROYED == 0, "B\'s inventory is untouched and nothing is destroyed")')
B.execute('check(world_sync.msg and world_sync.msg:find("dropped Herb x1", 1, true), "B is told: " .. tostring(world_sync.msg))')
back = deliver(B, A)
assert len(back) == 1 and back[0].startswith('dropok '), back
A.execute('check(next(world_sync.drop_out) == nil, "A\'s drop is answered and closed")')
A.execute('check(INV.Herb == 3, "A\'s inventory is not touched by the mod (the game removed the item itself)")')

# 2. A discard that didn't go through is nothing.
A.execute('WORLD = {} SENT = {} discard("Herb", 1, false)')
frames(A)
A.execute('check(#WORLD == 0 and #SENT == 0, "a discard the game refused drops nothing")')

# 3. The same discard seen twice within 3 s is one drop; a later one is another.
A.execute('WORLD = {} SENT = {} discard("HandgunBullet", 5) discard("HandgunBullet", 5)')
frames(A)
A.execute('check(#WORLD == 1 and #SENT == 1, "the same discard twice in a row is one drop")')
A.execute('harness_frames(240) discard("HandgunBullet", 5)')
frames(A)
A.execute('check(#WORLD == 2, "the same discard 4 s later is a new one")')
A.execute('SENT = {}')

# 4. Key items, weapons: each player's own.
A.execute('WORLD = {} SENT = {} discard("Key", 1) discard("Handgun", 1)')
frames(A)
A.execute('check(#WORLD == 0 and #SENT == 0, "key items and weapons are not dropped")')

# 5. The option off: the discard stays the game's own.
A.execute('settings.drop_on_discard = false discard("Herb", 2)')
frames(A)
A.execute('check(#WORLD == 0 and #SENT == 0, "Drop discarded items off: nothing is put down or sent")')
A.execute('settings.drop_on_discard = nil')

# 6. Nobody connected: a discard is the game's own.
A.execute('PEER = "steam:0" discard("Herb", 1)')
frames(A)
A.execute('check(#WORLD == 0 and #SENT == 0, "alone, a discard stays a discard")')
A.execute('PEER = "-" discard("Herb", 1)')
frames(A)
A.execute('check(#WORLD == 0 and #SENT == 0, "no peer at all: the same")')
A.execute('PEER = "steam:76561198000000009"')

# 7. The friend is far away, or in another chapter, or has it switched off: they say why, A is told, A keeps its own copy.
A.execute('WORLD = {} SENT = {} harness_frames(240) discard("Herb", 1)')
frames(A)
far = game('76561198000000003', {}, (500, 0, 500))
for t in list(A.eval('SENT').values()):
    far.globals().coop_event_slot = 1
    far.globals().coop_world_on_event(t)
far.execute('check(#WORLD == 0, "a friend 700 m away puts nothing down")')
refuse = list(far.eval('SENT').values())
assert len(refuse) == 1 and refuse[0].startswith('dropno ') and 'too_far' in refuse[0], refuse
A.execute('SENT = {}')
A.globals().coop_event_slot = 1
A.globals().coop_world_on_event(refuse[0])
A.globals().coop_event_slot = None
A.execute('check(world_sync.msg:find("too far away", 1, true) ~= nil, "A is told: " .. tostring(world_sync.msg))')
A.execute('check(#WORLD == 1, "and A\'s own copy stays on A\'s ground")')

B.execute('WORLD = {} SENT = {} world_sync.drop_seen = {}')
B.globals().coop_event_slot = 1
B.globals().coop_world_on_event('drop abc123 Herb 1 10.00 0.10 5.80 4')
B.globals().coop_event_slot = None
B.execute('check(#WORLD == 0 and SENT[1] == "dropno abc123 other_chapter", "another chapter: nothing is put down: " .. tostring(SENT[1]))')
B.execute('SENT = {} settings.drop_on_discard = false')
B.globals().coop_event_slot = 1
B.globals().coop_world_on_event('drop abc124 Herb 1 10.00 0.10 5.80 0')
B.globals().coop_event_slot = None
B.execute('check(#WORLD == 0 and SENT[1] == "dropno abc124 switched_off", "switched off: nothing put down: " .. tostring(SENT[1]))')
B.execute('settings.drop_on_discard = nil SENT = {}')

# 8. A key item sent by a changed copy is refused by the receiver.
B.globals().coop_event_slot = 1
B.globals().coop_world_on_event('drop abc125 Key 1 10.00 0.10 5.80 0')
B.globals().coop_event_slot = None
B.execute('check(#WORLD == 0 and SENT[1] == "dropno abc125 not_shared", "a key item isn\'t put down by the receiver either: " .. tostring(SENT[1]))')
B.execute('SENT = {}')

# 9. Malformed messages do nothing at all (no object, no answer).
bad = ['drop abc200 Herb 0 1.0 2.0 3.0 0', 'drop abc201 Herb 1000 1.0 2.0 3.0 0', 'drop abc202 Herb;x 1 1.0 2.0 3.0 0',
       'drop abc203 Herb 1 1.0 2.0 0', 'drop abc204 Herb 1 one 2.0 3.0 0', 'drop abc205 Herb 1 1.0 2.0 3.0', 'drop abc206 Herb -1 1.0 2.0 3.0 0',
       'drop zzz Herb 1 1.0 2.0 3.0 0', 'dropno', 'dropok', 'dropok not_hex', 'drop']
B.execute('WORLD = {} SENT = {}')
for t in bad:
    B.globals().coop_event_slot = 1
    B.globals().coop_world_on_event(t)
    B.globals().coop_event_slot = None
B.execute('check(#WORLD == 0 and #SENT == 0, "malformed drop messages change nothing (%d tried)")' % len(bad))

# 10. The same message twice is one item.
B.execute('WORLD = {} SENT = {}')
for _ in range(2):
    B.globals().coop_event_slot = 1
    B.globals().coop_world_on_event('drop abc300 Herb 2 10.00 0.10 5.80 0')
    B.globals().coop_event_slot = None
B.execute('check(#WORLD == 1 and WORLD[1].n == 2, "the same message twice puts one item down")')
B.execute('SENT = {}')

# 11. The game makes no object, or one that isn't drawn: the friend says so and A is told.
B.execute('WORLD = {} SENT = {} NOT_DRAWN = true')
B.globals().coop_event_slot = 1
B.globals().coop_world_on_event('drop abc301 Herb 1 10.00 0.10 5.80 0')
B.globals().coop_event_slot = None
B.execute('check(SENT[1] == "dropno abc301 not_drawn", "an object nobody can see is a failure: " .. tostring(SENT[1]))')
B.execute('SENT = {} NOT_DRAWN = false NO_OBJECT = true')
B.globals().coop_event_slot = 1
B.globals().coop_world_on_event('drop abc302 Herb 1 10.00 0.10 5.80 0')
B.globals().coop_event_slot = None
B.execute('check(SENT[1] == "dropno abc302 no_object", "the game made no object: " .. tostring(SENT[1]))')
B.execute('SENT = {} NO_OBJECT = false')

# 12. An answer to a drop that isn't ours is ignored; no answer in 10 s says so.
A.execute('WORLD = {} SENT = {} world_sync.msg = nil')
A.globals().coop_event_slot = 1
A.globals().coop_world_on_event('dropno ffff too_far')
A.globals().coop_event_slot = None
A.execute('check(world_sync.msg == nil, "an answer to nothing of ours is ignored")')
A.execute('harness_frames(240) discard("Herb", 1) harness_frames(30)')
A.execute('check(next(world_sync.drop_out) ~= nil, "the drop waits for an answer")')
A.execute('harness_frames(660)')
A.execute('check(next(world_sync.drop_out) == nil and world_sync.msg:find("didn\'t answer", 1, true) ~= nil, "no answer in 10 s: " .. tostring(world_sync.msg))')

# 13. A's own ground can't be made: nothing is sent, nothing breaks.
A.execute('WORLD = {} SENT = {} NO_OBJECT = true harness_frames(240) discard("Herb", 1) harness_frames(30)')
A.execute('check(#WORLD == 0 and #SENT == 0, "when our own copy can\'t be made, nothing is sent")')
A.execute('NO_OBJECT = false')

# 14. The mod made no inventory calls of its own on either side.
A.execute('check(INV.Herb == 3 and INV.HandgunBullet == 20, "A\'s inventory is as the game left it")')
B.execute('check(next(INV) == nil, "B\'s inventory is empty: nothing was ever made in it")')

fails = count(A, 'T.fails') + count(B, 'T.fails') + count(far, 'T.fails')
checks = count(A, 'T.checks') + count(B, 'T.checks') + count(far, 'T.checks')
print('drop scenarios:', ('FAILED %d of %d' % (fails, checks)) if fails else ('all %d checks passed' % checks))
sys.exit(1 if fails else 0)
