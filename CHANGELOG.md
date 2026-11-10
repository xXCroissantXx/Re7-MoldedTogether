# Changelog

## v0.43 (2026-11-09)
- **Fixed: CO-OP on the tape recorder took EXIT's place**, with a blank line under it. The game fills its
  list over several frames, and CO-OP was added before the game had added EXIT. CO-OP now waits until the
  list is complete, goes after EXIT, and moves back to the end if a row ever comes after it.
- **The mouse works on the co-op screen.** Point at a row to highlight it, click to pick it (like Enter / A),
  right click to go back (like Backspace / B); click "more above" / "more below" to scroll. A click with CO-OP
  highlighted on the tape recorder opens the co-op screen. Pointing only moves the highlight when the mouse
  moves, so it never fights the keys or the controller.
- **"I need ammo" and "I need healing"** in Quick messages. Your friend sees it with "co-op screen > Give
  items", and their Give items has you picked, with your health shown next to your name.

## v0.43 (2026-11-09)
- **Fixed: CO-OP on the tape recorder took EXIT's place**, with a blank line under it. The game fills its
  list over several frames, and CO-OP was added before the game had added EXIT. CO-OP now waits until the
  list is complete, goes after EXIT, and moves back to the end if a row ever comes after it.
- **The mouse works on the co-op screen.** Point at a row to highlight it, click to pick it (like Enter / A),
  right click to go back (like Backspace / B); click "more above" / "more below" to scroll. A click with CO-OP
  highlighted on the tape recorder opens the co-op screen. Pointing only moves the highlight when the mouse
  moves, so it never fights the keys or the controller.
- **On the title screen the co-op screen sits on the Options table**: CO-OP moves the camera from the tape
  recorder to the table (the game's own camera move), the sheets lie there without the dark cover, and
  closing moves the camera back.
- **Esc goes back** a sheet and then closes the co-op screen, and **F** picks, like on the game's own screens.
- **The top-left line names your menu key** (it always said F9).
- **CO-OP's text while scrolling**: set on every text of the row, and again right before the title menu is
  drawn (it could go blank when scrolling).
- **"I need ammo" and "I need healing"** in Quick messages. Your friend sees it with "co-op screen > Give
  items", and their Give items has you picked, with your health shown next to your name.

## v0.42 (2026-11-09)
Your friend's voice, giving items, a session page, difficulty checks, and fixes found in the game's own code.
Tested in stand-in games (new tests for each part), not yet in a real session.
- **Your friend's voice.** You hear them grunt when they're hit (light and heavy hits), block, land from a drop
  or climb up, scream if they die, and get back up after being revived; and pour the First Aid Med. The game
  picks these moves in its own code (the damage, guard, landing and climbing moves), which is caught and sent;
  your game plays the same sound from your own character's voice, where your friend is. Options: **Friend's
  voice**.
- **Give items.** A new section of the co-op screen: give a friend ammo, healing or crafting materials (one,
  half or all). Their game puts it in their inventory with the game's own calls and counts what arrived; only
  then does it leave yours. No room, no answer within 10 seconds, or anything that didn't arrive: nothing moves.
- **This session.** Another new section: time together, and for each of you enemies taken down, shots, hits
  taken, times down and back up, heals and items given (each game counts its own and tells the others).
- **Difficulty check.** Each game says which difficulty it plays (Casual, Normal, Madhouse); the Lobby marks a
  friend on another one, and you're told once, since enemies won't match.
- **Your friend's flashlight** (experimental, off by default: Options). In dark places, a copy of your own
  flashlight's light shines from your friend's head where they look.
- **Item names.** "Your friend picked up ..." and "took ..." now use the game's own item names (in your
  language) instead of internal ones like Chapter1Map.
- **Fixed: Get the host's key items and weapons always found nothing.** It read the item's id from the wrong
  place in the game's inventory list, so the list was always empty; it now reads it from the item itself.
- **Fixed: the co-op screen with Close highlighted.** Sheet B showed the Lobby and the menu stopped drawing it
  properly (an error every frame); it now shows "Back to the game". Each different menu error is now logged.

## v0.41 (2026-11-09)
The co-op menu moves onto the tape recorder; disconnecting; every gun's sound. Partly tested live.
- **CO-OP on the title screen's tape recorder.** A CO-OP row in the game's own list and lettering, under EXIT;
  picking it opens the co-op screen (worked out and tried live on the title screen; F9 and L3+R3 still work).
- **The co-op screen looks like the game's Options and Extra Content**: two sheets of paper, sections on sheet A
  (Lobby, Friends, Quick messages, Your character, Options, Help and fixes), the chosen one on sheet B.
- **Every gun is heard.** The game names its sounds, and every gun's shot has the same name (and every blade's
  swing): your friend's shotgun, magnum, M19 handgun and the rest now play their own shot, the axe its own swing,
  and reloads are heard too. The handgun's bang stands in if a gun's own sound files don't have it.
- **Disconnecting.** A friend whose game has closed is disconnected after 30 seconds (it no longer says "waiting
  for your friend" all night); one who lost connection after 3 minutes. Friends you played with in the last week
  reconnect by themselves when they invite you. **Disconnect from everyone** (Help and fixes) tells your friends
  at once, and the host can remove a player from the lobby (pick their row).
- **Lobby: Continue.** "Continue: everyone's own latest save": whoever is on the title screen loads their
  latest save when the host starts; whoever is playing carries on.
- **Key items used up go for everyone.** When one of you uses a key item on something (the VHS tape in the VCR,
  a key in its last lock) and it's gone, it's taken from your friends' inventories too.
- **Catching up with the host.** The lobby shows who's behind or ahead in the story; a friend who's behind can
  get the host's key items and weapons (experimental). A friend who's ahead keeps their own.

## v0.40 (2026-11-09)
An in-game co-op menu and lobbies. Untested in play.
- **The co-op menu: F9, or both sticks (L3+R3) on a controller.** Drawn over the game, on the title screen and in
  play, with the keyboard (arrows or WASD, Enter, Backspace) or the controller (D-pad or left stick, A, B); no
  REFramework window needed. Pages: Lobby, Friends, Quick messages, You appear as, Options, Help and fixes. The
  first time it opens, a welcome page explains the basics. The key can be changed (Options), for when F9 is your
  REFramework menu key.
- **Lobbies.** One of you hosts and picks where to start: where each of you is now, the host's chapter, or Chapter
  1, 3 or 4 from its start. Friends join by accepting the host's invite or choosing **Join** on a friend who hosts
  (the host's game lets them in). Everyone marks themselves ready, the host presses Start, and every game goes
  there together. A chapter start waits until everyone has loaded a save (a jump from the title screen leaves a
  black screen), and the menu says who it's waiting for.
- **The game holds still while the menu is open.** Your character, the camera and the game's own menus (title,
  pause) don't react to the keys you use in it, through the game's own switches; all given back when it closes.
- **A chapter start is a clean start.** The story's played scenes, the world changes still waiting for that
  chapter, and your catch-up list for it start over, for **Go to my friend's chapter** too.
- **Friendlier names**: chapters show as "Chapter 3 (the Baker house)"; the status lines point to the menu and
  use the menu's larger font, with a shadow.
- Controller players can send quick messages (from the menu).

## v0.39 (2026-11-09)
A sync overhaul from every log and note so far. Untested in play.
- **Scenes in a row play in order.** Once your game has started a run of scenes (the dinner, then the escape),
  it plays the rest itself as you get to each one; your friend's later scene is no longer forced into the
  middle of yours. If you haven't started that run yet, it starts from its first scene. This is what kept the
  chapter from moving on after the dinner, so Jack never came.
- **Story progress waits while your own run of scenes is still playing out** (it skipped the chair before).
- **Loading a save works with the story.** After either of you loads an earlier save, the scenes from after
  that save can play again for both of you, and your catch-up list stops sending changes from after it, so
  your friend's game doesn't get changes your world no longer has.
- **Enemies aren't copied during cutscenes.** While either of you is in a cutscene, or between the scenes of a run
  (rocking the chair at the dinner), enemies run in each game on their own: the scene moves them. Following picks
  up again when it ends. Bosses like Mia are still copied between the scenes of a run.
- **Jack's scripted moments happen in each game when its own player sets them off** (each of you picks up the
  hatch key). Starting them in the other game moved that game's Jack out of whatever he was doing.
- **No lost or half messages.** The network plugin now sends only whole messages: one read halfway through a
  write sent half a message before. More messages are kept between sends, so a burst no longer loses the oldest.
- **Rooms full of enemies keep following.** An update with more than about 11 enemies was dropped every time;
  now up to 24 (the nearest) go in each one.
- **Old messages after a long load are skipped.** A friend's scene or enemy hand-off from a minute ago no longer
  starts when your load finishes; lasting changes (doors, drawers, pickups) still apply.
- **The logs show when each scene starts and ends**, and flag one still running after 5 minutes.

## v0.38 (2026-11-09)
Untested in play.
- **Chains cut with the bolt cutters are cut for everyone.** Before, the friend's game counted the chain as used
  but left it hanging (the cabinet chain in Chapter 1). Now the chain's own cut runs there; if it's still there
  10 seconds later, it's taken away.
- **Late joiners get cut chains and picked locks.** They're kept in the catch-up list, and remembered for an area
  the friend hasn't loaded yet.
- **Jack shows up in Chapter 3.** After the dinner neither game moved the chapter on, so Jack never came. Two causes,
  both fixed: the friend's tied-up chair was copied onto yours while your escape scene played (scene props are no
  longer copied), and your escape scenes were forced into the friend's game in the middle of their dinner (a scene
  from a sequence your own game is already playing now plays in its own time).

## v0.37 (2026-11-09)
More of what led to the Mia crash, closed off. Untested in play.
- **Your cutscene is left alone.** While a cutscene plays in your game, your friend's doors, drawers, switches,
  crates, pickups, takedowns and catch-ups wait, and are applied a second after it ends; their pushed objects and
  hits are dropped (the scene moves those itself).
- **A friend's scene waits until you're free.** It no longer starts in your game while you're paused, in a menu,
  down, loading or in another cutscene; it starts when you're back (for up to 2 minutes, if they're still near).

## v0.36 (2026-11-09)
Fixes the crash when Mia throws Ethan through the wall. Untested in play.
- **No copied damage in scripted scenes.** The wall throw takes 1300 of Mia's health as part of the scene; that
  was sent to the other game as a normal hit and applied there, with a forced hit reaction (the crawling
  animation you saw), in the same second the scene started there, and the game crashed soon after. Damage, boss
  takedowns and hit reactions are no longer sent or applied while a scene plays or just started: each game's scene
  does its own.
- **Bosses never get a forced hit reaction** from the friend's hits (their reactions are scripted).
- **Hands off while a scene sets up.** For a moment after a scripted scene starts, the mod touches no enemies,
  doors or objects (the scene swaps characters in and out; reading one that was just removed damaged the game's
  state), then looks everything up again.

## v0.35 (2026-11-08)
Untested in play.
- **Bug reports** are zipped by the mod itself instead of a hidden PowerShell window, which showed Windows' busy
  mouse pointer over the game.
- Every script now goes through a stand-in game before each build: it loads them, runs their frames and menus,
  and feeds them every kind of friend event (nothing escaped the scripts' own error handling). The plugin is
  compiled against REFramework before each build too.
- The two-player test list has a section for everything new since v0.32.

## v0.34 (2026-11-08)
Untested in play.
- **Bumping into each other is back on, and lets go when it matters.** No bumping while a cutscene plays for
  either of you, or for 10 s after a scripted scene starts (yours or your friend's), so you can both stand where
  a scene starts and watch it together. If you get caught on each other (a doorway, a scene spot), you walk
  through after about half a second, until you're apart again. Options: **Bump into your friend**.

## v0.33 (2026-11-08)
Overhaul pass over every report so far. Untested in play.
- **Reviving with 3-4 players.** Any friend who is still up can get you up (stand next to them for 3 s); it's a
  real death only when everyone is down or nobody comes within 90 s. The screen shows the nearest friend who is
  down.
- **Pushed objects**: only what your own player pushes is sent. Knives an enemy carries and props a cutscene moves
  (the dinner chair) were sent too, and both games fought over them. A prop you are pushing yourself isn't moved by
  the friend's game at the same time.
- **Catch-up** goes once, not five times in a row, when a reconnect, the button and the friend's request come
  together; smashed crates are part of it.
- Two script errors from the reports fixed (a scene list read while loading, the friend's animation read while
  their character was being rebuilt).
- Checked every script for names used before they exist (a new build check).

## v0.32 (2026-11-08)
Fixes from the session on v0.31 (2 players, Mia fight into Chapter 3). Untested in play.
- **One Mia for both players.** In her boss fights one game (the host) runs Mia and the other copies her
  moves, attacks and chainsaw; before, each game ran its own Mia and only her health was shared. Options:
  **Share boss fights** (the same for both) turns it off if she acts oddly.
- **No black screen at the end of a chapter.** A story step from the friend is no longer copied while your own
  cutscene plays or in the 8 s after it: copying it in the second your game was about to take that step itself
  stopped your game from loading the next chapter (end of the Mia fight).
- **Boxes and crates without an item** break for both players (only boxes with an item were shared).
- **Doors**: a door your friend opens is unlocked first if it's still locked in your game (after one of you
  reloaded), so they no longer walk through a shut door.
- **Connecting while loading**: nothing from the friend is applied until your game has loaded and you have been
  in control for 5 s (it waits, nothing is lost).
- If your friend goes on to the next chapter and your game doesn't follow within 40 s, a message tells you to
  press **Go to my friend's chapter**.

## v0.31 (2026-11-08)
Fixes from the second session on v0.30 (2 players). Untested in play.
- **No black screen from the title screen**: **Go to my friend's chapter** (and following into a tape) waits
  until a save is loaded; it says "load your save first" instead of jumping with no game loaded.
- **No invisible walls after scenes you both played** (Mia's kidnap room): story steps are copied while you
  stand together (within about 12 m), not only right after a shared cutscene. Steps that arrive while you are
  apart are kept and copied when you meet up in the same chapter.

## v0.30 (2026-11-08)
Fixes from the first session on v0.29 (2 players). Untested in play.
- **Following into VHS tapes retries** for up to 30 s: the one try came while the game was loading, and the
  friend went into the tape alone.
- **Story moments after a long shared cutscene go through**: a story step is accepted until 30 s after the
  shared cutscene ends (it was 30 s after it started; Mia froze for one player after a 31 s scene).
- **You can stand in the same spot**: bumping into each other is off by default (it pushed one player off the
  spot where a scripted scene starts); Options: **Bump into your friend**.
- **Pushed chairs and other props stay matched** after an area reloads: a move for a prop the other game knows
  by another name now finds the same prop nearby.

## v0.29 (2026-11-08)
Tested on one PC with 3 bots; enemy hand-offs between 3-4 games are untested.
- **Up to 4 players.** Connect to one friend, then **Add** up to two more; everyone links to each other by
  themselves (a party list goes around every 3 s). Each friend gets their own character, nameplate, status line
  (name and health), and their own gunshots, flashes, smoke and knife swings.
- **Enemies with 3-4 players**: each enemy is run by the game of whoever is closest and copied by everyone else;
  hand-offs name the new owner, the lowest SteamID starts as host. Fallback switch **Share enemies with 3-4
  players** (Options, the same for everyone).
- **Story with 3-4 players**: a friend's cutscene checks the distance to that friend.
- Downed-and-revive stays a 2-player feature; with more players a fatal hit is a normal death.
- Bot testing: **Bots: 1 / 2 / 3** next to Test with bot (developer tools).

## v0.28 (2026-11-04)
Tested on one PC with the bot.
- **Your friend's gunshots are heard and seen**: each shot plays the gun's real bang, muzzle flash and powder
  smoke at your friend's gun. Their game sends the gun's sound and effect files once; yours builds them and plays
  them on every shot, whatever gun you hold yourself. The bang is known for the handgun so far; other guns show
  the flash and smoke, and their bangs will be added.
- **Your friend's knife swings are heard**: each swing plays the knife's whoosh at their hand (through your own
  knife, which every player carries).

## v0.27 (2026-11-04)
Tested live on one PC: doors (opened, closed and pushed as if by the friend, and the player's own use sent) and
lockpicks (the study desk).
- **Doors your friend opens or closes now open and close for you**, swinging smoothly, including the latched
  main-house doors that ignored them before (most of the house).
- **Closing a door with its handle is sent again** (v0.25 had stopped it along with doors that shut by
  themselves); doors that shut by themselves stay local.
- A close from your friend never shuts a door on you while you're right next to it (1.5 m).
- **Doors pushed open with your body match on both screens**: the door's angle is sent while it's pushed, and the
  other copy glides to the same angle (tested live, no stalls).
- **One game owns each door's self-close**: whoever opened a door, their game shuts it and tells the other; the
  other copy waits instead of shutting on its own timer, and the owner's door waits while the other player stands in
  the doorway (the last part untested).
- **Lockpicked drawers and boxes open for both**: when your friend picks a lock, your copy runs the lock's own
  "picked" sequence (lockpick sound, the lock comes off, the drawer opens), without touching you or opening a menu.
  Tested live on the study desk, including one left half-open by last session's version.
- **Pushed objects (chairs, bottles) are moved through their physics body**: before, every move was undone by the
  physics. Untested on a live object; the bug report says for each move whether it stuck.

## v0.26 (2026-11-04)
- **No more weapons overlapping in your friend's hand.** When their character was rebuilt (a load or a Lobby look
  change) while a weapon message arrived, the old weapon copy stayed stuck on the hand and overlapped every weapon
  after it (a pistol held up by the head, next to the knife). Every copy is now tracked and removed.

## v0.25 (2026-11-04)
Door fixes from the third session (short, v0.24). Untested in play.
- **Doors that swing shut by themselves no longer close on the other player**: only a door a player shuts is sent,
  and a close never applies while you're standing in that doorway.
- **Latched doors get more tries**: an open from your friend that doesn't take is retried from the door's other
  sides, and the log says when a door needs its handle instead (most main-house doors), for the next fix.
- The bug report lists what doors and lockpicked drawers can do, so they can be shared properly next.
- Fixed a rare error while a load starts.

## v0.24 (2026-11-04)
Untested in play. Use v0.24 on both sides (the game now tells you when the versions differ).
- **Version check**: the status line names both versions when you and your friend run different ones.
- **All the sharing switches are one setting for both players**: Share phone calls, Share interactions and Share
  pushed objects now work like Share story and Share supplies.
- **Heal my friend** (Options, off by default): a healing item used next to your friend heals them instead.
- **Your friend is hidden while climbing a ladder** instead of floating up it (Options: Hide my friend on ladders).
- **Molded health check-in**: every 3 s both games compare each Molded's health and keep the lower one, so a lost
  damage message can't leave them out of step. Jack and other bosses are left alone.
- **Make a bug report makes one on both games** at once, and it now includes the catch-up list and the last
  events each way.
- Doors: no more errors when a door's area unloads, and each open or close is sent once (it went out twice).

## v0.23 (2026-11-04)
Fixes from the first long session (2026-11-03). Use v0.23 on both sides.
- **Share story and Share supplies are one setting for both players.** Ticking or unticking either changes it
  for your friend too. Last session had Share story on for one player and off for the other, so the other game
  ignored every story step: the wall never broke, the garage and shadow puzzle stayed locked, chapter 3 replayed.
- **The shotgun on the hall statue is no longer shared**, nor anything else that hands out a weapon or item: the
  friend could take the shotgun without swapping in the broken one.
- **The knife no longer shows** in your friend's hand when they hold a gun or heal.
- **No more T-pose** when your friend does a move their character has no animation for (Jack lifting Ethan, the
  bathroom scene): the character keeps standing or walking instead.
- **Molded you don't control are visible**: one handed to your friend before it climbed out of the wall stayed
  invisible on your screen while it attacked you.
- **Smoother enemies** on the other player's screen (more updates and a bigger buffer; Jack was jittery).
- **Story drift warning**: when one of you is two or more story steps ahead in the same chapter, the status
  line says so (even with Share story off), so you notice before a wall or a door doesn't match.
- **Car and puzzle interactions stay per player**: getting into or out of the car and starting the shadow puzzle
  are no longer run on the other game.
- **Fewer game exceptions at doors**: the pushed-objects check touched chairs and bottles the game had just
  unloaded (about 565 errors per game last session, and three warnings that can end in a crash).
- Interactions that aren't shared yet (like the garage-door button) are now named in the bug report, so they can
  be added next.
- Fixed: "your friend paused the game" never got through (an error in both logs).

## v0.22 (2026-11-03)
Untested in play (a small change). Works with v0.21; set Share supplies the same on both sides.
- **Each player gets their own supplies** by default (ammo, healing, crafting materials). **Share supplies** in
  Options brings back one copy for both, for a harder game (both players should set it the same).

## v0.21 (2026-11-03)
The window cleanup was checked in game; the rest is small and tested offline. Works with v0.20.
- **Tidier RE7 Co-op window**: Lobby, Talk and catch up, Connect and saving, **Options** (what's shown and
  shared), **Help** (go to your friend's chapter, teleport, fast-forward a cutscene, fix your friend's
  character, reload, bug report). The test bot and research tools are hidden behind **Show developer tools**;
  no more buttons listed twice.
- **Share phone calls** switch (on by default) in Options.
- **Last quick message** stays on the status line for 20 seconds.
- **Fresh-list reminder**: when your friend connects and your catch-up list has changes from a later chapter than
  theirs (a new game?), you're offered **Start a fresh list**.

## v0.20 (2026-11-03)
Tested with the bot: both hands, weapon up while walking, the item in hand. Phone sharing needs two players. Both players need v0.20 for the new moves (v0.19 still connects).
- **Both hands move**: RE7 often plays one arm's move on one layer and the other arm's on another; only one
  was shared, so your friend's left hand stayed still. A second move now goes along (in spare bits of the
  movement update, so v0.19 still understands the rest) and plays on its own layer.
- **The item in hand shows sooner** (checked 4 times a second instead of once).
- **Weapon up while walking and running**: your friend's character carries their weapon raised while moving, not
  only when standing still (tested with the knife).
- **Phone calls are shared**: when one of you answers a phone, the other's phone is answered too, so you don't
  both have to take every call to move on (also when they get there later, and after a rejoin). Untested
  between two players.
- **Fixed: things that must never be shared could be.** The list (saving at tape recorders, VHS tapes, item
  boxes, cutscene triggers) checked the wrong object name and never matched.
- Fixed: after switching characters in the Lobby with a weapon out, your friend's character could stay sliding
  or T-posed (the animation watchdog wasn't allowed to rebuild it while a weapon was out).

## v0.19 (2026-11-03)
Both players need v0.19. Tested with the bot: quick messages, pings, health and the catch-up button work; the rest was tested offline (a simulated game, 21 checks).
- **Catching up after a rejoin**: each game keeps a list of the lasting changes it made (doors unlocked, boxes
  smashed, drawers, switches, supplies taken, Molded killed), on disk for 12 hours. When your friend connects or
  comes back after a gap (a restart, a crash, a dropped connection), the list is sent and their game catches up,
  including what you did while they were away. Areas they haven't reached yet catch up when they get there.
  **Catch up now** in the new *Talk and catch up* section does it on demand, both ways; **Start a fresh list**
  is for starting a new game together. (The first two-player session went "totally out of sync" after a rejoin.)
- **Quick messages and pings**: **F5** ping ("Over here"), **F6** Come here, **F7** Wait for me, **F8** Help!
  (or the buttons in *Talk and catch up*, plus "Go on ahead"). Your friend sees the message at the top of the
  screen with the distance, and for pings, Come here and Help, a marker where you stood (a pointer at the edge
  when it's off screen) for 25 seconds. The keys can be switched off.
- **Your friend's health** on the status line and their nameplate, green, yellow or red.
- **More of your friend's moves show**: climbing up and dropping down ledges, crawling, getting hit, knock-backs
  and enemy grabs (full-body moves were only shared from motion number 1000 up, which left these out).
- **Items in hand**: the healing bottle (and other items your friend holds, like one they're inspecting) shows
  in their hand, not just weapons. The healing animation itself is retried in the item animation set when the
  friend's current set doesn't have it (untested).
- Ladders: their animation comes from another animation set the movement update can't carry yet; the log now
  records it, so a later version can add it.
- Testing: the bot echoes quick messages and catch-up lists, so they can be tried alone.
- The two-player checklist (TWO-PLAYER-TEST.md) is rewritten for a play-through from the start.

## v0.18 (2026-11-03)
Fixes from a solo run through Jack's garage fight; not yet tested between two players. Both players need v0.18.
- **Boss mode now covers Jack's garage fight.** The garage Jack is the same enemy as the stalker Jack, so the
  fight is recognised by story progress instead: from the garage cutscene until Jack goes down, each game runs
  its own Jack.
- **Enemy flinch fixed**: the hit reaction for your friend's hits couldn't be created at all ("no
  ResistResultSet" in the log); it's now built the right way. Still untested in play.
- **Fixed: your friend's character rebuilt itself (T-pose for a moment) while they held the handgun.** The
  handgun's walk animation is longer than the bare-hands one, and the animation check took that for a broken
  animation.

## v0.17 (2026-11-03)
Fixes found in the logs; not yet tested in play. Works with v0.16, but update both sides: the supplies fix is in the game that sends.
- **Fixed: leaving an area could take your friend's supplies away.** RE7 hides an area's items when you leave it,
  the same way it hides a picked-up item, so the mod sent "took" for items you never touched. Now only an item
  within reach of you counts as a pickup, and each item is reported once.
- **Changes in areas the other player hasn't loaded yet** are remembered and applied when they get there: doors
  your friend unlocked, boxes they smashed (with the item), drawers and switches.
- Less stutter after area changes: pushed-object tracking stopped asking unloaded objects for their position
  (thousands of game errors a minute).

## v0.16 (2026-11-03)
Weapon swings, the held weapon and boxes were tested with the bot; boss mode is untested. Both players need v0.16.
- **Boss mode**: in boss fights (Jack in the garage car fight and later) each game runs its own boss, so the
  scripted fight works on both screens; damage and the defeat are still shared. Only the stalker Jack and the
  Molded have their movement copied between games.
- **Use full models.cmd** finds the mod download by itself (zip or folder, in Downloads, on the Desktop or next to
  the script): no more copying its "natives" folder by hand.
- **Weapon swings show**: your friend's character plays the right weapon's moves (knife swings tested with the
  bot). Each weapon has its own animation set; the friend's body now uses the same one as yours.
- **Weapon sits in the hand** at the right angle (it was stuck in the wrist).
- **Smashed boxes are shared**: when your friend smashes one, it disappears in your game (no pieces: RE7 won't
  redraw it as broken) and its item is left where it stood. Both players get a box's item (each game rolls its
  own from the box's loot table, so they can differ).
- Testing: the bot no longer vanishes when you swing, block or touch a door, and it holds what you hold.

## v0.15 (2026-11-03)
First attempts at the remaining gaps; all untested in play, each with a way to see what happened in the logs:
- **Enemies flinch from your friend's hits**: the enemy's own hit reaction is requested when your friend's damage
  arrives (a bigger reaction for big hits).
- **Pushed objects** (experimental, option *Share pushed objects*): chairs, bottles and other loose props you
  knock around move in your friend's game too.
- **Joe's hands**: a few likely hand files are tried in turn until one loads.
- Weapon sounds: the log now records what each weapon you hold is made of, to build sound sharing on next.

## v0.14 (2026-11-03)
- **Your friend's weapon in their hand** (experimental, option *Show your friend's weapon*): the weapon your
  character holds is shown in your character's right hand on your friend's screen. Untested: tell us what you see.
- **Friend marker**: the nameplate shows how far away your friend is, and when they're off screen a pointer at
  the edge of the screen shows which way to turn (or "behind you").
- **Safer shared interactions**: saving (tape recorders), VHS tapes, phones and item boxes are never shared.
- Works together with v0.13 (only the weapon needs v0.14 on both sides).

## v0.13 (2026-11-03)
- **More of your friend's moves show**: every move RE7 plays on your body is now mirrored, not just blocking:
  anything on the upper-body and hand layers (weapon swings and shots if RE7 plays them there) and full-body
  moves such as climbing a ladder or interacting. Untested with weapons: tell us what you see.
- **A downed friend lies on the floor** on your screen until you revive them (instead of crouching).
- **Following into VHS tapes**: when your friend puts a tape in, your game follows them into it a few seconds
  later (option *Follow my friend into VHS tapes*, on by default). It never jumps you back out; finish the tape.
- **Shared interactions** (experimental, option *Share interactions*, on by default): one-off actions like
  opening the fridge or the van, stirring the pot, long-press actions and switches happen in both games.
- **Key and weapon pickups**: when your friend picks one up, you're told to pick it up too (it stays for you, so
  your own story moments still happen).
- **Jack's scripted moments** (smashing through a wall) are shared along with cutscenes when *Share story* is on
  and you're close together.
- Both players need v0.13 (the movement update changed again).

## v0.12 (after the first two-player session, 2026-11-02)
- **Lobby**: see both players and their chapters, and pick how you look to your friend: Ethan, Mia, Mia (ship),
  Clancy, Zoe, Chris, Joe. Works with RE7's own models; with the Nexus mod "Third Person Full Model
  Placeholders" set up by **Use full models.cmd**, they're complete characters (your own view stays normal).
- **Blocking shows**: your friend's character blocks when they do (and plays the other upper-body moves RE7 puts
  on the player's body, like touching a door), on top of walking. Both players need v0.12.
- **Enemy hand-offs work between two real games**: both games now send enemy movement (before, only one
  did, so an enemy handed to the other player was taken back after 3 seconds: Jack flickered and only chased
  one player).
- **Doors close for both**, not just open. **Breakable boxes** and **drawers** are shared (new, untested).
- **Pausing**: your enemies are handed to your friend while you're paused, and they see "Your friend paused
  the game".
- **Weapons stay for both players** (picking one up froze the other player mid-pickup).
- **Share story reworked and off by default** (experimental): a friend's cutscene only pulls you in when you're in
  the same chapter and within about 12 m; story progress is only copied for 30 seconds after a cutscene you
  shared. (It used to push the player who was behind: a tape ended early, a chapter change got stuck.)
- Fixes: friend sliding after a tape; friend vanishing after the basement ladder (a background story event
  counted as a cutscene); stuck pause menu after a cut-short cutscene; Jack bouncing between games; save
  guard briefly blocking saves when the settings file was read mid-write; installer avoids OneDrive folders.
- Testing: bot buttons to smash the nearest box and open/shut the nearest drawer.
- **Make a bug report** button: a zip of the logs on your desktop, personal details blanked out.
- Logs are written once a second instead of on every line (less stutter late in a session); no more pile of
  coop_dummy_log_HHMMSS files (the previous run is kept as coop_dummy_log_prev.txt).
- **Reload last save** refuses after a chapter jump (it hung on the loading icon); restart and Continue instead.
- Enemy copies hold the same weapon as the original.

## v0.11 (2026-10-31)
- **Saving together**: when one player's game saves (tape recorder or autosave, with Allow saving on), the other
  sees "Your friend saved..." (and is told if their own saving is off), so you can both keep matching saves.
- **Safer saves**: enemies your game is copying from your friend's get their own AI back while a save is being
  prepared, so a save can't store them frozen. Following resumes a few seconds later.
- Not yet tested with a real save (only the notice, with a simulated friend).

## v0.10 (2026-10-31)
- **Downed and revive**: with your friend connected, a fatal hit puts you down instead of ending your game. You
  crouch, can't move, and the screen goes black and white, with a 90-second countdown. Your friend sees "Your
  friend is down!" with the distance; when they stand next to you for 3 seconds you get back up with 35% health.
  Both down, or nobody coming in 90 seconds, is a normal game over. Playing alone, nothing changes.
- Testing: "Take a fatal hit" button; the follow-me bot can revive you.

## v0.9 (2026-10-31)
- **Shared story** (early): when one player reaches a story cutscene, the other player's game plays the same
  one (started by name; you're pulled into the scene wherever you are). Story progress and finished story
  events are copied, and progress only ever moves forward. Each cutscene plays once per side; the list of
  played cutscenes survives script resets, so a finished scene is never replayed.
- **Share story** switch in the RE7 Co-op window (on by default) to turn it off.
- Testing: the bot can trigger the next story cutscene in your area.

## v0.8 (2026-10-31)
- **Shared doors**: a door unlocked in one game (with a key, or a one-way door from the other side) unlocks in
  the other; a door pushed open swings open on the other player's screen too.
- **Shared supplies**: ammo, healing items, crafting materials and weapons picked up by one player disappear
  from the other player's world (also in areas they reach later). Keys, files and maps stay in both worlds, so
  nobody gets stuck without a key.
- Testing: the bot can open the nearest door, unlock the nearest locked door, or take the nearest supply.

## v0.7 (2026-10-31)
- **Enemy movement** (early): each enemy is run by the game of the player nearest to it; the other game turns
  that enemy's own AI off and has it follow the running game (position and animation, 10 updates a second).
  When the other player gets clearly closer (3 m), the enemy is handed over, so enemies always chase a real
  player and their hits land on the right person. If the other game goes quiet, enemies come back after 3 s.
- **Fixed: your friend could disappear for good after they restarted their game** (their clock restarted and
  every update looked stale). Same fix for enemy updates.
- Fixed: your friend's Ethan could get stuck hidden, or visible but frozen without a nameplate, after a
  cutscene or a rebuild during loading.
- **Bot**: new "follow me" mode (walks your path, waits near you, copies your stance); "stay here" mode.
- **Testing**: fast-forward cutscenes (8x); record an enemy and replay it with its AI off; hand an enemy to
  the bot and back.

## v0.6 (2026-10-31)
- **Shared enemy damage and deaths** (first step of enemy sync). When you hurt an enemy, it loses the same
  health in your friend's game; when you kill it (or knock Jack down), it goes down there too. A regular
  enemy your friend killed in an area you haven't reached yet is already dead when you get there. Only
  between players in the same chapter.
- These events use Steam's guaranteed delivery, so a kill can't get lost.
- On screen: "Enemies: your friend took down ..." for a few seconds.
- Testing: the bot can hit or take down the enemy nearest to you.
- Not yet: enemies still move separately in each game, and hits don't make them flinch on the other screen.

## v0.5 (2026-10-31)
- **Footsteps**: you hear your friend's footsteps where they walk, using RE7's own walk, jog and crouch
  sounds. Switch off with **Friend's footsteps** in the RE7 Co-op window.
- **Installer**: warns when RE7 is on the older non-RT version (Steam beta `dx11_non-rt`), which is untested;
  its closing steps now describe the friend list.
- Checked: Steam names in Russian, Chinese, Japanese and Korean already show correctly on the nameplate and
  in the friend list.

## v0.4 (2026-10-31)
- **Pick your friend from a list**: the RE7 Co-op window lists your Steam friends who are running RE7 Co-op,
  each with a **Connect** button. No more copying SteamIDs (still possible under *Connect with a SteamID
  instead*).
- **Invites**: connecting to a friend shows them "*<name>* invited you to co-op" on screen; they click
  **Accept**. Uses Steam rich presence, so nothing else needs setting up.
- **Go to my friend's chapter**: jumps to the start of your friend's chapter (saving is switched off first).
  Chapter names are shown instead of numbers.
- **Teleport to my friend** now lands on ground your friend walked on, and only within 40 m (RE7 only loads
  the area around you, so long warps could land outside the map).
- The friend list warns when your friend runs a different coop-re7 version.
- Fixed: a script error while a chapter was loading. Testing: the bot can pretend to be in another chapter.

## v0.3 (2026-10-29)
- **One-click installer** (`Install.cmd`): finds RE7 in Steam, copies it to a co-op folder, downloads
  REFramework + C# add-on from the official release with SHA-256 checks, installs the mod, backs up saves,
  creates a desktop shortcut. Re-running it updates the mod and keeps your settings.
- **Allow saving** switch (off by default) with automatic save backups at every launch and on demand; the
  newest 20 are kept.
- **On-screen status** in the top-left: connection, friend's name, ping, "friend is in another chapter",
  version-mismatch warning, saving state.
- **Nameplate** with your friend's Steam name over their Ethan.
- **Teleport to my friend** button.
- **RE7 Co-op window**: a floating window (opens with the REFramework menu) with Connect, saving and display
  options, and a Testing section.
- **Chapter switcher** (Testing): jump to any chapter with RE7's own chapter jump. Saving is switched off first
  so a test jump is never saved. Starting together in the same chapter is the easiest way to meet up.
- Fixed: the ghost could separate from its position while crouching (the crouch idle clip jammed the
  animation, and a blend was mistaken for an error).
- Fixed: head look stopped working after Rebuild Ethan.
- Bot: follows you to new chapters and after loads or teleports.
- **Save protection fix:** with saving off, chapter jumps could still write your save files through internal
  save paths. These are now blocked too (verified: save files unchanged across a chapter jump). If you used
  an earlier test build's chapter switcher, restore your saves from the backup the installer made.
- The co-op ghost also works in sections played as other characters (e.g. the videotapes).
- The other player is hidden while you watch a cutscene, and while they watch one (shown as "Friend is
  watching a cutscene").
- Chapter switcher allows one jump at a time (rapid jumps could leave cutscenes invisible and you outside
  the map). Collision never pushes you during cutscenes or loads.
- The packet now carries the chapter and a round-trip echo, used for the ping (the format is unchanged in size,
  but v0.2 and v0.3 players won't understand each other's chapter and ping).

## v0.2 (2026-10-29)
- Ethan builds himself automatically. Walk, jog and crouch in four directions, idle, head look, smoothed turns
  and blends.
- Can't walk through the other player.
- Ghost rebuilds after save loads, deaths and area changes, and hides when the other player's data stops.
- In-game **Connect** panel (copy your SteamID, paste your friend's).

## v0.1 (2026-10-29)
- First prototype: the other player as a ghost body over Steam relay.
