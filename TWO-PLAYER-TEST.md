# coop-re7: two-player session checklist

Everything in coop-re7 has so far been tested on one PC against a simulated player (the bot). This list walks
two real players through every shared feature once, so problems show up in a known order. It takes about
45 minutes. Tick things off as you go and note anything odd (what you saw, roughly when).

**Before you start (both players)**

- [ ] Both installed the same coop-re7 release (the friend list warns if your versions differ).
- [ ] *Allow saving*: off by default (nothing kept). To keep your progress, both tick it before playing.
- [ ] A player starting RE7 for the first time plays the opening alone first (joining during it leaves a black
      screen), then connects.
- [ ] Voice chat open (Discord or Steam) so you can say what you see.

## 1. Connect (5 min)

- [ ] Both start **Start Molded Together** and load any save.
- [ ] Each sees the other under *Your Steam friends in Molded Together*.
- [ ] Player A clicks **Connect** next to Player B. Player B sees "*A* invited you to co-op" at the top left.
- [ ] Player B presses Insert and clicks **Accept**.
- [ ] Both see **Co-op: connected to *name* - *ping* ms** at the top left. Note the ping: ____ ms

## 2. Meet up in Chapter 3 (5 min)

- [ ] Both tick **Show developer tools**, open **Developer tools → Chapter switcher** and click **Chapter3**, once each. (Or: one player clicks it,
      the other uses **Go to my friend's chapter**.)
- [ ] Watch the dinner (fast-forward is fine) until you can both move.
- [ ] Each can see the other's Ethan, with their name above it. Walk, jog and crouch around each other.
- [ ] You hear each other's footsteps.
- [ ] You can't walk through each other.

## 3. Doors and items (5 min)

- [ ] Player A pushes a door open. It swings open on Player B's screen too.
- [ ] Player A picks up some ammo, a herb or a chemical. It disappears from Player B's world.
- [ ] A key item, file or map stays for both (each picks up their own).

## 4. Enemies (10 min)

Jack appears soon after dinner. Saving is off, so getting hurt costs nothing.

- [ ] Both see Jack in the same place, doing the same thing.
- [ ] Shooting Jack on one screen lowers his health on the other (the Molded Together window, *Developer tools*, shows
      "Enemy sync" with his health).
- [ ] Knocking Jack down on one screen knocks him down on the other.
- [ ] Walk away from Jack while your friend stays near him. He should keep chasing the nearer player
      (enemies change hands when the other player is 3 m closer).

## 5. Going down and reviving (5 min)

- [ ] Let Jack hit Player A until a fatal hit. Player A goes **down** (crouched, black and white, can't move)
      instead of a game over. Player B sees "Your friend is down!" with the distance.
- [ ] Player B stands next to Player A for 3 seconds. Player A gets back up.
- [ ] (Optional) Both get downed at once: that should be a normal game over for both.

## 6. Story (10 min)

- [ ] Follow the objective until a story cutscene starts for one of you. The other player's game should play
      the same cutscene (they're pulled into the scene).
- [ ] After it, both carry on normally. If someone is stuck and can't move, restart the game (nothing was
      saved) and note which cutscene it was.

## 7. Leaving (2 min)

- [ ] Player B closes the game. Player A's view of B disappears within a few seconds; enemies B was running
      come back to Player A within 3 seconds.
- [ ] Player B starts again and reconnects. A sees B again.

## 8. New since the first session (v0.12-v0.27), in the order you'll meet them

Playing from the start of the game. Note for each: works / doesn't / looks odd.

- [ ] **Talk** (new): A presses **F6** (Come here). B sees "Your friend: Come here (*n* m)" at the top of the
      screen and a marker where A stood. Try **F5** (ping), **F7** (wait), **F8** (help).
- [ ] **Health** (new): the status line and nameplate show the other player's health (green, yellow, red).
- [ ] **Lobby**: each picks a character; the other sees the change within a few seconds.
- [ ] **Doors** (v0.27): A opens a main-house door with its handle (one press cracks it, the second opens it); it
      opens on B's screen too, smoothly. A walks into a door so it swings partway: B's copy swings the same amount.
      A lets the door shut by itself: it shuts for B at the same time (B's copy doesn't shut on its own). B stands
      in the doorway of a door A opened: it doesn't shut on B.
- [ ] **Lockpicks** (v0.27): A picks a lock on a drawer or box. On B's screen the lockpick sound plays, the lock
      comes off and B can open it without picking it. B's own menu doesn't open.
- [ ] **Interactions**: A opens the van or the fridge, stirs the pot, flips a switch. Does it happen for B?
- [ ] **Drawers and boxes**: A opens a drawer; A smashes a breakable box. On B's screen the box disappears and
      its item lies where it stood. **Both** can pick up an item from it.
- [ ] **Pushed objects** (v0.27): A knocks a chair or bottle around. Does it move for B? (The bug report says
      "moved" or "DIDN'T MOVE" for each of the first moves.)
- [ ] **Supplies**: A picks up ammo. It stays for B (each gets their own). Then A ticks **Share supplies**
      (Options; it turns on for B too) and A picks up another: now it disappears for B. A walks into another area and back: B's other
      supplies must still be there.
- [ ] **Keys**: A picks up a key. B is told to pick it up too, and it's still there for B.
- [ ] **VHS tape**: A puts a tape in (B nearby). B's game follows into the tape a few seconds later.
- [ ] **Moves**: A blocks, swings the knife, aims and shoots the handgun, climbs a ladder. Which does B see?
      Each of A's shots: B hears the bang (handgun so far) and sees the muzzle flash and smoke at A's gun; each
      knife swing: B hears the whoosh.
- [ ] **Enemies**: A hits Jack or a Molded. On B's screen it loses health and flinches. Walk closer to it one at
      a time: it should keep moving smoothly and go after the nearer player.
- [ ] **Pausing**: A pauses near an enemy. B sees "Your friend paused the game"; the enemy keeps moving for B.
- [ ] **Downed**: A takes a fatal hit and lies on the floor; B walks over and A gets up.
- [ ] **Garage fight (boss mode)**: each player gets the whole fight in their own game. Jack's hits by one player
      count for both, and when he goes down for one, he goes down for both.
- [ ] **Rejoin catch-up** (new): B quits the game while A carries on (unlock a door, smash a box, take a herb).
      B starts again and reconnects. Within a few seconds B sees "Caught up with *n* changes from your friend",
      and A's changes are there in B's world.

## 9. Three or four players (v0.29)

- [ ] **Joining**: A connects to B, then clicks **Add** next to C. Within a few seconds B and C see each other
      too (each sees two characters with nameplates, and two names on the status line).
- [ ] **Moves**: everyone walks, aims, shoots and swings. Each character copies its own player; each shot's bang,
      flash and smoke come from the right person.
- [ ] **Enemies**: a Molded near C: does it chase C, and move the same on everyone's screen? Walk it over to A:
      does it move smoothly when A's game takes it over? If enemies act oddly, untick **Share enemies with 3-4
      players** (Options) and note what happened.
- [ ] **Story** (Share story on): the player who walks into a story moment first starts it for the others who
      are close (about 12 m).
- [ ] **Leaving**: one player quits; the others keep playing; they come back and reconnect by themselves.

## 10. New in v0.32-v0.35

- [ ] **Joining**: load your save first. On the title screen, **Go to my friend's chapter** says "load your save
      first" instead of jumping.
- [ ] **Bumping**: walk into each other: you bump. Stand together where a scripted scene starts: no pushing, and
      the scene starts for both. Get caught in a doorway: you pass through after about half a second.
- [ ] **Crates**: smash a crate with no item in it: it's gone for the friend too.
- [ ] **Doors after a reload**: one of you dies and reloads; the other opens a door that was locked: it opens for
      both (nobody walks through a shut door).
- [ ] **Mia's fight** (Share boss fights on): one Mia, moving the same on both screens; her chainsaw in her hand.
      Note whether she can hurt the player whose game copies her.
- [ ] **End of the Mia fight**: both of you go on to the next chapter without a black screen.
- [ ] **Reviving with 3 players**: one goes down; either of the others gets them up.
- [ ] **Pushed objects**: push a chair: it moves for the friend; the knife Mia carries doesn't jump around.
- [ ] **Bug report**: no busy mouse pointer appears over the game while it's made.
- [ ] **Chains (v0.38)**: one of you cuts the cabinet chain with the bolt cutters: within 10 seconds it's cut
      for the other too, and the cabinet opens for them. Also try it with the friend joining after the cut.
- [ ] **Chapter 3 (v0.38)**: after the dinner, Jack turns up for both of you.

## 11. New in v0.39

- [ ] **The dinner (Chapter 3)**: sit down together. Each of you rocks your own chair; the escape plays in each
      game when that player gets free. Afterwards Jack turns up for both of you.
- [ ] **A scene your friend starts first**: walk into a story scene a few steps apart. It plays for both; if one of
      you is further on in it, the other sees the rest on getting there (the status line says so).
- [ ] **Jack's wall**: each of you picks up the hatch key; Jack breaks through in each game.
- [ ] **Loading a save**: both load the same save from before a scene; the scene plays again for both.
- [ ] **Enemies in a cutscene**: one of you watches a cutscene while the other fights; nothing jumps around, and
      the enemies follow again once it ends.
- [ ] **A long load**: one of you reloads while the other walks into a scene; the scene doesn't start late
      for the one who loaded.

## 12. New in v0.40: the co-op menu and lobbies

- [ ] **The menu**: on the title screen press F9. It opens; arrows, Enter and Backspace move around it. The game's
      own title menu behind it does NOT move or react (note it if it does). F9 closes it.
- [ ] **Controller**: press both sticks (L3+R3): it opens. D-pad and left stick move (note it if the stick is upside
      down), A chooses, B goes back.
- [ ] **In play**: open it; your character and the camera stay still; close it and you can move again.
- [ ] **Inviting**: Friends > your friend > Invite; they see the invite at the bottom left, press F9, Accept.
- [ ] **A lobby, no jump**: one hosts (Lobby > Host a lobby); the other sees "lobby is waiting", opens the menu,
      Ready; the host presses Start ("Where each of you is now").
- [ ] **A lobby, Chapter 3**: both load a save (Continue); the host picks Chapter 3; both Ready; Start: both games
      go to Chapter 3 and the dinner starts for both. Try pressing Start while one of you is on the title screen:
      it waits and says so.
- [ ] **Joining a host**: the host closes the lobby and hosts again; the other picks them in Friends (Join): they're
      let in by themselves.
- [ ] **Quick messages** from the menu with a controller.
- [ ] **Key for this menu** (Options): pick F10; F10 opens it.

## 13. New in v0.41

- [ ] **CO-OP on the tape recorder**: on the title screen, scroll the list: CO-OP is under EXIT, every row keeps its
      own name while you scroll, and Enter (A) on CO-OP opens the co-op screen (paper sheets).
- [ ] **Your friend's guns**: they fire the shotgun, the magnum, the M19: you hear each one's own shot. Reloads too.
      Their axe swings are heard.
- [ ] **Disconnecting**: one of you closes the game: within about 30 seconds the other's status says not
      connected. Start again: you reconnect (one invite). Try **Disconnect from everyone** and a host's remove.
- [ ] **Lobby Continue**: both on the title screen; the host hosts, picks "Continue", both Ready, Start: both games
      load their latest save. Note it if the title screen doesn't load (then choose CONTINUE yourself).
- [ ] **The VHS tape**: one of you puts a tape in the VCR: the other follows into it, and afterwards the tape is
      gone from both inventories.
- [ ] **Behind the host**: the one behind uses Lobby > "Get the host's key items and weapons" (experimental).

## 14. New in v0.42

- [ ] **Your friend's voice**: let an enemy hit your friend, or have them block: you hear their grunt from where
      they are (not as if it's you). Their scream if they die, a grunt when they drop down or climb up, a sound
      when they're revived. If it sounds like it's inside your head, note it and turn off **Friend's voice**.
- [ ] **Give items**: co-op screen > **Give items**: give your friend one handgun ammo. It arrives in their
      inventory and leaves yours. Try **All** with healing; try giving when their inventory is full (nothing moves).
- [ ] **This session**: after a fight, both of you open **This session**: each sees their own counts and the
      other's (theirs show after about 20 seconds).
- [ ] **Difficulty**: if you play on different difficulties, the Lobby says so (in red) and a message tells you.
- [ ] **Your friend's flashlight** (experimental): both tick Options > **Your friend's flashlight**, go somewhere
      dark where the flashlight comes on: you see your friend's beam where they look. Note it if the game stutters
      or the light points the wrong way.
- [ ] **Get the host's key items and weapons** (it found nothing before v0.42): the one behind tries it again.
- [ ] **Close**: on sheet A, highlight Close: sheet B says "Back to the game".

## 15. New in v0.43

- [ ] **CO-OP on the tape recorder**: on the title screen, scroll through the whole list: EXIT is there and
      says EXIT, CO-OP comes after it, and no line is blank. Scroll up and down past both a few times.
- [ ] **The table**: pick CO-OP on the tape recorder: the camera moves to the Options table and the co-op
      sheets show on it; close it (Esc): the camera goes back to the tape recorder and the list works.
- [ ] **The mouse**: open the co-op screen (CO-OP or F9) and move the mouse: the row under it lights up and a
      small dot shows where it is. Click a section, click a setting (it changes), right click to go back.
      Note it if nothing moves (the game may keep the mouse to itself in play; the keys still work).
- [ ] **Esc and F**: on sheet B, Esc goes back to sheet A, Esc again closes; F picks like Enter. The top-left
      line names the menu key you picked (Options).
- [ ] **I need ammo / I need healing**: one of you picks it under Quick messages; the other sees the message,
      opens **Give items**, and the one who asked is already picked, with their health.
- [ ] **The new name**: the co-op screen says Molded Together, and the installer leaves one "Start Molded
      Together" shortcut on the desktop (the old "Start RE7 Co-op" one is gone).

## 16. New in v0.44

- [ ] **Give, then load**: give your friend some ammo, then both load a save (or the one who got it does):
      no crash. Give again after the load.
- [ ] **A door while you stand in it**: your friend closes a door you're standing in: it stays open for you
      until you step out, then closes, so it ends up shut in both games.
- [ ] **Loading**: load a save while connected: your friend hears no grunts from you as you appear.

## 17. New in v0.45

- [ ] **A lockpick box**: one of you opens a lockpick box with a lockpick; within about 8 seconds it's open
      for the other too, and what's inside can be taken.
- [ ] **A cutscene far away**: one of you starts a cutscene while the other is in another room: the other
      isn't pulled in, and sees it when they get there.

## 18. New in v0.46

- [ ] **The co-op screen's look**: pick CO-OP on the tape recorder: two stained sheets on the Options table,
      the printed form at the top of each, settings with < and > at the ends. Everything still reads clearly
      (note anything hard to read, and at which screen size).

## 19. New in v0.47

- [ ] **Jack follows between games**: while Jack hunts one of you, the other sees him in the same place doing
      the same thing. When the other one gets well closer to him, he goes for them instead.
- [ ] **The Molded**: kill one: it dies in your friend's game too, and only that one. Hit one and check it
      dies after about the same number of shots in both games. A Molded may be in a different place on each
      screen (each game runs its own).
- [ ] **Your moves on your friend's screen**: climb a ladder, drop down a ledge, answer a phone, get grabbed
      by Jack (or a Molded), and in the morgue fight with Jack kick the body bags, while the other one watches
      your character. Note which moves show and which don't; the bug report's log names every move that
      couldn't be shown.
- [ ] **One game leads the story** (experimental): both switch it on (Options). The host walks into a story
      scene while the other is in another room: the other is pulled into it too, and when it ends both can
      move. Note any scene that leaves someone stuck.
- [ ] **Enemies chase both players** (experimental): both switch it on (Options). Up close to Jack, he goes
      for whichever of you is nearer. Note anything odd (he freezes for a moment, swaps back and forth).

## 20. New in v0.48

- [ ] **Items**: both put a key item in at the same time (the pendulum, a dog head), and one of you uses a
      coin cage while the other is in the inventory: no crash, and nobody loses an item they didn't use.
- [ ] **Loading**: finish the Mia tape together, and load a save right after a scene: no stuck loading screen.
- [ ] **Molded for both**: when a Molded comes out for one of you, the other sees one come out at the same spot.
- [ ] **One Molded**: fight a Molded together: it's in the same spot doing the same thing on both screens, it
      goes for whoever is nearer, and it can hurt either of you. Walk away from it: it turns on the other player.
- [ ] **Cremator puzzle** (the morgue's incinerator trays): one of you solves it: the other's trays match
      and their key tray opens too, even if they got there later.
- [ ] **Title screen**: scroll the tape recorder's list up and down a few times: every row keeps its own
      name, and CO-OP is never blank.
- [ ] **Objectives**: one of you completes an objective: it's checked off for both.
- [ ] **Key items**: one of you places a dog head (or the statue's shotgun, the pendulum): it shows in the
      other game too, the other player keeps their own items, and the door opens for both.
- [ ] **Story moves on**: after a story beat one of you triggers (a door, a boss, a phone call), both of
      you get the next objective.
- [ ] **Boss fight deaths**: let Jack grab and kill one of you while the other is up: that player goes
      down, can be helped up, and is still in the same fight.
- [ ] **Phones and cutscenes** (Share story on): one of you answers a phone: the other keeps control and
      hears the call. A real cutscene still plays for both of you.
- [ ] **Puzzles and tapes**: one of you solves a shadow puzzle: it's solved for the other. One of you puts
      a tape in: the other is taken into it within half a minute.
- [ ] **Scripted moves**: one of you pulls the sheet metal under the deck or lifts a pot lid: the other sees
      that character do it, keeps control, and finds it opened.
- [ ] **Quick moves**: kick a body bag in the morgue fight: your friend sees you stay on screen.
- [ ] **Mouse on the co-op screen during play**: point and click work.
- [ ] **Stuck in a scene**: Teleport to your friend still works; Reload last save refuses and says why.

## Afterwards

Each player clicks **Make a bug report** (Molded Together window, *Help*) and sends the zip
it puts on their desktop. SteamIDs and names are already blanked out.
