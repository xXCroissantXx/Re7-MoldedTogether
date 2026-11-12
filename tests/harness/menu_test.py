"""Drives coop_menu.lua (v0.41) like two players: a host and a friend, each in its own stand-in
game, their lobby messages passed across. Usage: python menu_test.py <scripts dir>."""
import sys, os
import lupa

here = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(sys.argv[1], 'coop_menu.lua'), encoding='utf-8').read()
fake = open(os.path.join(here, 'menu_test.lua'), encoding='utf-8').read()

def game(me, peer, name):
    L = lupa.LuaRuntime(unpack_returned_tuples=True)
    L.execute(fake)
    L.execute('T.me, T.peer, T.name, T.connected = "%s", "%s", "%s", true' % (me, peer, name))
    load = L.eval('function(src) local f, e = load(src, "@coop_menu.lua") if not f then error(e) end f() end')
    load(src)
    return L

A = game('76561198000000001', '76561198000000002', 'Host')
B = game('76561198000000002', '76561198000000001', 'Guest')

def exchange():
    for src_, dst in ((A, B), (B, A)):
        sent = list(src_.eval('T.sent').values())
        src_.execute('T.sent = {}')
        for text in sent:
            dst.globals().coop_event_slot = 1
            dst.globals().coop_menu_on_event(text)
            dst.globals().coop_event_slot = None
        # CoopNet takes the queued command.
        cmd = src_.eval('T.files["coopnet_command.txt"]')
        if cmd:
            src_.execute('T.taken = T.taken or {} T.taken[#T.taken + 1] = T.files["coopnet_command.txt"] T.files["coopnet_command.txt"] = nil')

def step(seconds=0.5):
    n = int(seconds / 0.1) or 1
    for _ in range(n):
        A.execute('frames(0.1)')
        B.execute('frames(0.1)')
        exchange()

def taken(L, prefix):
    t = L.eval('T.taken')
    return any(str(v).startswith(prefix) for v in (t.values() if t else []))

# 1. Opening the menu holds the game; closing gives it back.
A.execute('press("f9")')
A.execute('check(coop_menu.open, "F9 opens the menu")')
A.execute('check(called("setPlayerOperatableFlag(System.Boolean, System.String)", false), "the player is held (keyed flag)")')
A.execute('check(called("setCameraOperatableFlag(System.Boolean, System.String)", false), "the camera is held")')
A.execute('check(called("setInputLevel(app.UICommand.InputLevel)", 6), "the game\'s menus are held (input level NormalHigh)")')
A.execute('check(drew("Molded Together"), "the menu is drawn (sheet A)")')
A.execute('check(coop_menu.page == "welcome", "the first time, it opens on the welcome page")')
A.execute('choose("Got it") check(coop_menu.focus == "A" and settings.menu_welcomed, "Got it goes on to the sections (sheet A), and it is remembered")')
B.execute('settings.menu_welcomed = true')

# 2. The host hosts a lobby.
A.execute('open_cat("Lobby")')
A.execute('check(coop_menu.page == "lobby" and coop_menu.focus == "B", "Lobby opens on sheet B")')
A.execute('choose("Host a lobby")')
A.execute('check(coop_lobby.state == "open" and coop_lobby.host == T.me, "hosting a lobby")')
step(3)
print('ok   presence set for friends' if taken(A, 'presence lobby') else 'FAIL presence not set')
fails_extra = 0 if taken(A, 'presence lobby') else 1

# 3. The friend sees it and gets ready.
B.execute('check(coop_lobby.state == "open" and coop_lobby.host == T.peer, "the friend sees the host\'s lobby")')
B.execute('T.texts = {} frames(0.1) check(drew("lobby is waiting"), "the friend is told to get ready (menu closed)")')
B.execute('press("f9") open_cat("Lobby") choose("Ready")')
B.execute('check(coop_lobby.ready, "the friend is ready")')
step(3)
A.execute('local i = coop_lobby.info[1] check(i and i.ready and i.where == "game", "the host sees the friend ready, in the game")')

# 4. Start where everyone is (no jump).
A.execute('''
local t, items = coop_menu_debug_items()
local start_btn
for _, it in ipairs(items) do if (it.text == "Start" or it.text == "Start again") and it.left == nil then start_btn = it end end
check(start_btn ~= nil and start_btn.off == nil, "Start can be pressed (everyone ready)")
if start_btn then start_btn.on() end
''')
step(1)
A.execute('check(coop_lobby.state == "started", "the host started")')
B.execute('check(coop_lobby.state == "started" and coop_lobby.go and coop_lobby.go.done, "the friend started too (no jump)")')

# 5. The host picks Chapter 3: the friend has to get ready again; then everyone jumps.
A.execute('''
local t, items = coop_menu_debug_items()
for _, it in ipairs(items) do if it.text == "Where to start" and it.left then
    for _ = 1, 3 do it.right() local t2, i2 = coop_menu_debug_items() for _, x in ipairs(i2) do if x.text == "Where to start" and x.left then it = x end end
        if coop_lobby.start == "Chapter3_Start" then break end end
end end
check(coop_lobby.start == "Chapter3_Start", "the host picks Chapter 3")
''')
step(3)
B.execute('check(coop_lobby.start == "Chapter3_Start" and not coop_lobby.ready, "the friend sees Chapter 3 and isn\'t ready for it yet")')
B.execute('''
local t, items = coop_menu_debug_items()
for _, it in ipairs(items) do if it.text == "Ready" then it.on() end end
check(coop_lobby.ready, "the friend is ready for Chapter 3")
''')
step(3)
A.execute('''
local t, items = coop_menu_debug_items()
local start_btn
for _, it in ipairs(items) do if (it.text == "Start" or it.text == "Start again") and it.left == nil then start_btn = it end end
check(start_btn and start_btn.off == nil, "Start can be pressed for Chapter 3")
start_btn.on()
check(coop_menu.confirm ~= nil, "a chapter jump asks first")
coop_menu.confirm.fn()
''')
step(3)
A.execute('check(T.jumps[#T.jumps] == "Chapter3_Start", "the host jumps to Chapter 3")')
B.execute('check(T.jumps[#T.jumps] == "Chapter3_Start", "the friend jumps to Chapter 3")')
A.execute('check(not coop_menu.open, "the menu closed for the jump")')
A.execute('check(called("setPlayerOperatableFlag(System.Boolean, System.String)", true), "the player is given back")')
A.execute('check(called("resetInputLevel(app.UICommand.InputLevel)", 6), "the game\'s menus are given back")')

# 6. A friend on the title screen blocks a chapter jump.
B.execute('T.title = true')
step(3)
A.execute('''
local why
for _ = 1, 1 do
    local ok, w = pcall(function() return nil end)
end
coop_menu_set_open(true)
coop_menu.page = "lobby"
local t, items = coop_menu_debug_items()
for _, it in ipairs(items) do if (it.text == "Start" or it.text == "Start again") and it.left == nil then why = it.off end end
check(why ~= nil and why:find("title screen", 1, true) ~= nil, "a friend on the title screen holds the jump: " .. tostring(why))
coop_menu_set_open(false)
''')

# 7. Back closes the menu from the main page; nothing stays held.
B.execute('T.title = false coop_menu_set_open(true) press("back")')
B.execute('check(not coop_menu.open and not coop_menu.locked, "Back on sheet A closes it, nothing held")')
B.execute('coop_menu_set_open(true) open_cat("Options") press("back") check(coop_menu.open and coop_menu.focus == "A", "Back on sheet B goes back to sheet A") press("back")')

# 8. Both host at once: the lower SteamID keeps the lobby, the other joins it.
A.execute('coop_lobby.state = nil coop_lobby.host = nil')
B.execute('coop_lobby.state = nil coop_lobby.host = nil')
A.execute('coop_menu_set_open(true) coop_menu.page = "lobby" local t, items = coop_menu_debug_items() for _, it in ipairs(items) do if it.text == "Host a lobby" then it.on() end end coop_menu_set_open(false)')
B.execute('coop_menu_set_open(true) coop_menu.page = "lobby" local t, items = coop_menu_debug_items() for _, it in ipairs(items) do if it.text == "Host a lobby" then it.on() end end coop_menu_set_open(false)')
step(4)
A.execute('check(coop_lobby.host == T.me, "two hosts: the lower SteamID keeps hosting")')
B.execute('check(coop_lobby.host == T.peer and coop_lobby.state == "open", "two hosts: the other joins that lobby")')

# 9. The host closes the lobby: it's gone for the friend too.
A.execute('coop_menu_set_open(true) coop_menu.page = "lobby" local t, items = coop_menu_debug_items() for _, it in ipairs(items) do if it.text == "Close the lobby" then it.on() end end coop_menu.confirm.fn() coop_menu_set_open(false)')
step(2)
B.execute('check(coop_lobby.state == nil, "the host closed the lobby: gone for the friend too")')

# 10. Another key for the menu (REFramework's own menu key may be F9).
B.execute('settings.menu_key = 0x79 press("f9") check(not coop_menu.open, "with F10 picked, F9 does nothing") press("f10") check(coop_menu.open, "F10 opens it") press("f10") check(not coop_menu.open, "F10 closes it")')

# 12. Kicking: the host removes the friend, whose game then leaves everyone.
A.execute('coop_lobby.state = nil coop_lobby.host = nil')
B.execute('coop_lobby.state = nil coop_lobby.host = nil')
A.execute('coop_menu_set_open(true) coop_menu.page = "lobby" local t, items = coop_menu_debug_items() for _, it in ipairs(items) do if it.text == "Host a lobby" then it.on() end end')
step(3)
A.execute('''
local t, items = coop_menu_debug_items()
local row
for _, it in ipairs(items) do if it.text:find("Friend:", 1, true) and it.on then row = it end end
check(row ~= nil, "the host can pick a player's row")
if row then row.on() coop_menu.confirm.fn() end
coop_menu_set_open(false)
''')
step(1)
print('ok   the host drops the kicked friend' if taken(A, 'steamremove 76561198000000002') else 'FAIL the host kept the kicked friend')
print('ok   the kicked friend leaves everyone' if taken(B, 'steamleave') else 'FAIL the kicked friend stayed')
fails_extra += 0 if (taken(A, 'steamremove 76561198000000002') and taken(B, 'steamleave')) else 1

# 13. A friend whose game closed is dropped after 30 s (not "waiting" all night).
D = game('76561198000000004', '76561198000000005', 'Alone')
D.execute('T.silent = true friends.list = {} T.taken = {}')
for _ in range(400):
    D.execute('frames(0.1) if T.files["coopnet_command.txt"] then T.taken[#T.taken + 1] = T.files["coopnet_command.txt"] T.files["coopnet_command.txt"] = nil end')
print('ok   a friend who closed the game is disconnected' if taken(D, 'steamremove 76561198000000005') else 'FAIL the silent friend stayed connected')
fails_extra += 0 if taken(D, 'steamremove 76561198000000005') else 1

# 11. The CO-OP row on the tape recorder (a stand-in of the title menu's list).
C = game('76561198000000003', '76561198000000001', 'Title')
C.execute('settings.menu_welcomed = true T.title = true install_title() frames(1.5)')
C.execute('check(#TM.steps == 8 and TM.item_max == 8, "the title list gets an eighth row")')
C.execute('check(coop_menu_debug_title().idx == 7, "it is row 8 (index 7)")')
C.execute('TM.slots[2].li = 7 frames(0.2) check(TM.slots[2].text.msg == "CO-OP", "the slot showing it says CO-OP")')
C.execute('TM.slots[2].li = 0 frames(0.2) check(TM.slots[2].text.msg == nil and TM.slots[2].text.id == "msg_newgame", "after scrolling on, that slot gets its own text back")')
# v0.48: mid-scroll the slot passes through row 0 for a frame before it settles on QUIT (row 6). It used to
# keep NEW GAME's text ("scrolling turns everything to New Game").
C.execute('TM.slots[2].li = 7 frames(0.2) TM.slots[2].li = 0 frames(1/30) TM.slots[2].li = 6 frames(0.3) '
          'check(TM.slots[2].text.msg == nil and TM.slots[2].text.id == "msg_quit", "a slot that passed row 0 mid-scroll ends with its own row\'s text (" .. tostring(TM.slots[2].text.id) .. ")")')
# v0.48: the scene's component list without get_elements (always so on the test copies' title screen) still
# finds the menu, so the CO-OP row keeps its text instead of going blank.
C.execute('TM.real_scene = sdk.call_native_func')
C.execute('local tsm = TM.tsm sdk.call_native_func = function() return { call = function(self, m) return { call = function(_, k, i) '
          'if k == "get_Count" then return 1 end if k == "get_Item" then return tsm end end } end } end '
          'TM.slots[1].li = 7 TM.slots[1].text.msg = nil frames(2.5) check(TM.slots[1].text.msg == "CO-OP", "the CO-OP row keeps its text when the list has no get_elements")')
C.execute('sdk.call_native_func = TM.real_scene TM.slots[1].li = 0 frames(0.3)')
C.execute('TM.slots[3].li = 7 TM.selected = 7 frames(0.2) check(coop_menu_debug_title().selected, "CO-OP highlighted")')
C.execute('press("enter") check(coop_menu.open, "Enter on CO-OP opens the co-op menu")')
C.execute('frames(0.1) check(TM.cam == 2 and coop_menu.table_mode, "the camera goes to the Options table")')
C.execute('press("back") check(not coop_menu.open, "Back closes it again")')
C.execute('frames(0.1) check(TM.cam == 3 and not coop_menu.table_mode, "and back to the tape recorder")')
C.execute('frames(2.5) check(#TM.steps == 8, "the row is added once, not again")')
C.execute('coop_event_slot = 1 coop_menu_on_event("lobby go 76561198000000001 1 here 5") coop_event_slot = nil frames(1.5)')
C.execute('check(TM.selected == 1, "Continue from the lobby highlights CONTINUE")')
C.execute('check(TM.step_change == TM.steps[2].f.Step, "and asks the title menu for its own Continue step")')

# 14. v0.42: "Close" highlighted on sheet A has its own page (v0.41 failed every frame there).
B.execute('''
coop_menu_set_open(true)
coop_menu.focus, coop_menu.confirm = "A", nil
for i, c in ipairs(coop_menu.cats) do if c.page == nil then coop_menu.cat = i coop_menu.page = nil end end
T.texts = {} frames(1.5)
check(coop_menu_debug_items() == "Close", "Close highlighted: sheet B shows its own page")
check(drew("Back to the game"), "and it's drawn")
check(not (T.files["coop_menu_log.txt"] or ""):find("frame ERR", 1, true), "no frame errors logged")
press("enter")
check(not coop_menu.open, "Enter on Close closes the menu")
''')

# 15. v0.42: Give items lists what can be given and asks before giving.
B.execute('''
GIVEN = {}
coop_shareable_items = function() return { { id = "HandgunBullet", n = 10, name = "Handgun Ammo", cat = 2 }, { id = "RemedyM", n = 2, name = "First Aid Med", cat = 3 } } end
coop_give_item = function(to, id, n, name) GIVEN[#GIVEN + 1] = { to = to, id = id, n = n } return "t1" end
coop_menu_set_open(true)
open_cat("Give items")
check(coop_menu.page == "give", "Give items opens")
local t, items = coop_menu_debug_items()
local ammo
for _, it in ipairs(items) do if it.text == "Handgun Ammo" then ammo = it end end
check(ammo ~= nil and ammo.value == "x10", "the ammo is listed with its count")
for _, it in ipairs(items) do if it.text == "How many" then it.right() it.right() end end   -- One -> Half -> All
t, items = coop_menu_debug_items()
for _, it in ipairs(items) do if it.text == "Handgun Ammo" then ammo = it end end
ammo.on()
check(coop_menu.confirm ~= nil and coop_menu.confirm.question:find("x10", 1, true), "All: it asks to give all 10")
coop_menu.confirm.fn()
check(#GIVEN == 1 and GIVEN[1].to == T.peer and GIVEN[1].id == "HandgunBullet" and GIVEN[1].n == 10, "and gives them to the friend")
coop_menu_set_open(false)
''')

# 16. v0.42: This session shows our counts and the friend's, and ours go out every 20 s.
B.execute('''
coop_stat("kills") coop_stat("kills") coop_stat("shots", 12)
coop_event_slot = 1 coop_menu_on_event("stats 3 40 2 1 1 0 5") coop_event_slot = nil
coop_menu_set_open(true)
open_cat("This session")
local t, items = coop_menu_debug_items()
local mine, theirs
for _, it in ipairs(items) do
    if it.text:find("You: 2 enemies, 12 shots", 1, true) then mine = true end
    if it.text:find("3 enemies, 40 shots", 1, true) then theirs = true end
end
check(mine, "our own counts are shown")
check(theirs, "the friend's counts (from their game) are shown")
coop_menu_set_open(false)
T.sent = {}
''')
B.execute('frames(21)')
B.execute('''
local got
for _, s in ipairs(T.sent) do if s:find("^stats 2 12 ") then got = true end end
check(got, "our counts go to the friend every 20 s")
''')

# 17. v0.42: the options have the friend's voice.
B.execute('''
coop_menu_set_open(true)
open_cat("Options")
local t, items = coop_menu_debug_items()
local v
for _, it in ipairs(items) do if it.text == "Your friend's voice" then v = it end end
check(v ~= nil and v.value == "On", "Options: Your friend's voice, on by default")
coop_menu_set_open(false)
''')

# 18. v0.43: "I need ammo" and "I need healing" in Quick messages.
B.execute('''
TALKED = {}
coop_talk_send = function(k) TALKED[#TALKED + 1] = k end
coop_menu_set_open(true)
open_cat("Quick messages")
local t, items = coop_menu_debug_items()
local ammo, meds
for _, it in ipairs(items) do
    if it.text == "I need ammo" then ammo = it end
    if it.text == "I need healing" then meds = it end
end
check(ammo ~= nil and meds ~= nil, "Quick messages: I need ammo and I need healing")
ammo.on()
check(TALKED[1] == "ammo" and not coop_menu.open, "I need ammo sends the ammo request and closes the screen")
''')

# 19. v0.43: Give items picks the friend who asked, and shows their health.
B.execute('''
coop_friend_health = function(slot) return 40 end
coop_give_ask = { slot = 1, kind = "meds", t = os.clock() }
coop_menu_set_open(true)
open_cat("Give items")
local t, items = coop_menu_debug_items()
local to
for _, it in ipairs(items) do if it.text == "Give to" then to = it.value end end
check(to ~= nil and to:find("(health 40%)", 1, true), "Give to shows the friend's health")
check(coop_give_ask.used == true, "the friend who asked is picked (once)")
coop_menu_set_open(false)
coop_friend_health = nil
''')

# 20. v0.43: the game fills its list over several frames. CO-OP waits for it, goes after EXIT,
# and a CO-OP row left before EXIT (v0.42 did that: "row 7 of 7") moves to the end.
D = game('76561198000000004', '76561198000000001', 'Title2')
D.execute('''
settings.menu_welcomed = true T.title = true install_title()
local quit = table.remove(TM.steps)
frames(0.5)
check(#TM.steps == 6 and coop_menu_debug_title().idx == nil, "no row is added while the game's list is still filling")
TM.steps[#TM.steps + 1] = quit
frames(1.5)
check(#TM.steps == 8 and TM.steps[7].f.GUIElemName == "quit" and TM.steps[8].f.GUIElemName == "coop", "CO-OP goes after EXIT")
check(TM.item_max == 8 and coop_menu_debug_title().idx == 7, "and is row 8 of 8")
local coop = table.remove(TM.steps) table.insert(TM.steps, 7, coop)
frames(0.2)
check(#TM.steps == 8 and TM.steps[7].f.GUIElemName == "quit" and TM.steps[8].f.GUIElemName == "coop", "a CO-OP row before EXIT moves to the end")
check(coop_menu_debug_title().idx == 7, "and is found there")
TM.item_max = 7 frames(0.2)
check(TM.item_max == 8, "the row count is set again when the game sets its own")
TM.selected = 7 frames(0.2)
MDOWN = true frames(0.05) MDOWN = false frames(0.05)
check(coop_menu.open, "a click with CO-OP highlighted opens the co-op menu")
coop_menu_set_open(false) frames(0.1)
''')

# 21. v0.43: the mouse on the co-op screen.
B.execute('''
MX, MY = 3, 3 frames(0.1)
coop_menu_set_open(true) frames(0.1)
local hit = coop_menu.hit
local r = hit and hit.a[7]
check(r ~= nil and #hit.a == 9, "the sections' places are kept for the mouse")
MX, MY = (r[1] + r[3]) / 2, (r[2] + r[4]) / 2 frames(0.1)
check(coop_menu.cat == 7 and coop_menu.focus == "A", "pointing at Options highlights it")
MDOWN = true frames(0.05) MDOWN = false frames(0.05)
check(coop_menu.focus == "B" and coop_menu_debug_items() == "Options", "a click opens Options")
local _, items = coop_menu_debug_items()
local b = coop_menu.hit.b[2]
MX, MY = (b[1] + b[3]) / 2, (b[2] + b[4]) / 2 frames(0.1)
check(coop_menu.sel[coop_menu.page] == b[6], "pointing at a row highlights it")
local vr
for _, h in ipairs(coop_menu.hit.b) do if items[h[5]] and items[h[5]].text == "Your friend's voice" then vr = h end end
check(vr ~= nil, "Your friend's voice is on screen")
if vr then
    local before = settings.friend_voice ~= false
    MX, MY = (vr[1] + vr[3]) / 2, (vr[2] + vr[4]) / 2 frames(0.1)
    MDOWN = true frames(0.05) MDOWN = false frames(0.05)
    check((settings.friend_voice ~= false) ~= before, "a click on it changes it")
    MDOWN = true frames(0.05) MDOWN = false frames(0.05)
end
check(drew("Right click: back"), "the controls line tells the mouse buttons")
MRDOWN = true frames(0.05) MRDOWN = false frames(0.05)
check(coop_menu.focus == "A", "a right click goes back")
MRDOWN = true frames(0.05) MRDOWN = false frames(0.05)
check(not coop_menu.open, "and another closes the screen")
''')

# 22. v0.43b: the game's keys. F picks like Enter; Esc goes back a sheet, then closes the screen.
B.execute('''
coop_menu_set_open(true) frames(0.1)
press("f")
check(coop_menu.focus == "B", "F opens the highlighted section, like the game's OK")
press("esc")
check(coop_menu.open and coop_menu.focus == "A", "Esc goes back to sheet A first")
press("esc")
check(not coop_menu.open, "and then closes the co-op screen")
settings.menu_key = 0x79
check(coop_menu_key_name() == "F10", "the chosen menu key's name is there for the status line")
settings.menu_key = nil
''')

fails = int(A.eval('T.fails')) + int(B.eval('T.fails')) + int(C.eval('T.fails')) + int(D.eval('T.fails')) + fails_extra
checks = int(A.eval('T.checks')) + int(B.eval('T.checks')) + int(C.eval('T.checks')) + int(D.eval('T.checks'))
print('menu scenarios:', ('FAILED %d of %d' % (fails, checks)) if fails else ('all %d checks passed' % checks))
sys.exit(1 if fails else 0)
