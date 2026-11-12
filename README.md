# Molded Together: online co-op for Resident Evil 7 (v0.50; formerly coop-re7)

Play Resident Evil 7 with up to three friends over the internet. You all share one game: the same Molded and
bosses, which can go for any of you; the same story, doors, puzzles and key items. Each of you sees the others
as full-body characters (Ethan, or anyone you pick in the Lobby) who walk, jog, crouch, look around, block,
climb and fight where they do, over Steam (no port forwarding).

> **Release candidate.** Two real two-player sessions so far (2026-11-02 and 2026-11-10, from the start of the
> game to the Chapter 3 yard), and before every release two copies of RE7 play each other with bots for the
> whole test suite (doors, drawers, puzzles, story steps, the Molded, Jack and Mia). Nobody has played past
> Chapter 3 in co-op yet: see **Known limits**. [TWO-PLAYER-TEST.md](TWO-PLAYER-TEST.md) is a checklist for a
> session; please send a bug report (below) when something doesn't match.

## What's shared

| | |
|---|---|
| **Each other** | Position, movement, crouching, looking around, footsteps, which chapter you're in, and the moves RE7 plays on your body (blocking, weapon swings, both hands, the weapon held up while walking, climbing ladders, getting hit, kicks, scripted moves like the sheet metal). A downed friend lies on the floor. Their weapon or the item they're using in hand. Their voice: grunts when they're hit, block, land or climb, a scream if they die. Their flashlight in the dark (experimental, Options). A marker with the distance, pointing the way when they're off screen. How you look: pick a character in the **Lobby**. |
| **The Molded** | One Molded for all of you. Each one is run by the game of whoever is nearest, with the game's own AI, and every other screen shows it in the same spot doing the same thing. It goes for whoever is nearest and its swings hurt anyone they reach; when another player gets clearly closer, or the one it's after goes down, it turns on them. A Molded that comes out for one of you comes out for everyone; damage and kills count for all. |
| **Bosses** | One boss for all of you: Jack (the garage car fight, the morgue) and Mia are run by the nearest player's game and can hurt any of you. Their health, phases and defeat are shared. |
| **Story** | Story progress one of you makes counts for everyone, step by step, the way the game itself steps. Cutscenes play for everyone in first person; phone calls and scripted moves (the fridge, the pot, the sheet metal) play on the player who does them while the others hear them, and they count for all. The host's game leads; a friend who's behind catches up. **VHS tapes:** when your friend puts one in, you follow them into it. |
| **Doors, drawers, lockers, boxes** | A door unlocked, opened or closed in one game does the same in the others. Drawers and lockers open and shut for all; a breakable box smashed by one disappears for the others (no pieces), and each of you gets its item. Body bags kicked in the morgue swing for everyone. |
| **Puzzles and key items** | A key item used in its lock (the dog heads, the statue) does its job in every game. The shadow puzzles and the basement cremator are solved for everyone. One-off interactions (the fridge, the van, the pot, switches) happen in every game. |
| **Giving items** | Give your friend ammo, healing or crafting materials from the co-op screen (**Give items**): it leaves your inventory only once it's in theirs. |
| **Supplies** | Each player gets their own ammo, healing and crafting materials. For a harder game, tick **Share supplies**: then there's one copy, and whatever one player picks up disappears for the others. Weapons, keys, files and maps always stay for everyone, so nobody gets stuck; when one of you takes one, the others are told to pick it up too. |
| **Deaths** | With a friend connected, a fatal hit (also in a grab or a boss fight) puts you **down** instead of a game over, until a friend stands next to you for 3 seconds. It's a real game over only when everyone is down. |
| **Pausing** | The others see "Your friend paused the game"; enemies your game was running carry on in theirs. |
| **Saving** | Each player saves their own game; when one saves, the others are told, so you can all save at the same point. |
| **Pushed objects** | Chairs, bottles and other loose props one of you knocks around move for the others too. |
| **Catching up** | Each game keeps a list of the lasting changes it made (doors, boxes, drawers, puzzles, story steps, supplies taken, Molded killed) for 12 hours. When your friend joins or rejoins, the list is sent and their game catches up, including what you did while they were away. |
| **Talking** | Quick messages with **F5** (ping: "Over here"), **F6** (Come here), **F7** (Wait for me) and **F8** (Help!): your friend sees them at the top of the screen, and a marker for pings, Come here and Help. Each other's **health** shows on the status line and nameplate. |
| **Gunshots and swings** | Each of your friend's guns makes its own bang (handguns, shotgun, magnum and the rest), with the muzzle flash and smoke at their gun; their reloads and their knife and axe swings are heard too. |
| Not shared | Item boxes (each player has their own). |

Made with [coop-anything](https://github.com/cranebeaker/coop-anything). MIT licensed.

## Install (every player)

1. Have **Resident Evil 7 biohazard on Steam**, fully updated.
2. Download the latest release zip from the **Releases** page and unzip it anywhere.
3. Double-click **Install.cmd**. It will:
   - find RE7 in your Steam libraries and **copy it** to `Documents\RE7-coop` (or `C:\RE7-coop` when your
     Documents folder is synced by OneDrive). Your normal install is not changed; the copy needs as much free
     space as your RE7 install;
   - download **REFramework** and its C# add-on from the official release and **check each file's SHA-256**;
   - install the co-op files, back up your saves, and put a **Start Molded Together** shortcut on your desktop.
4. If the installer says **.NET 10 runtime not found**, install ".NET Runtime 10" (Windows x64) from
   https://dotnet.microsoft.com/download/dotnet/10.0 and run Install.cmd again.

Updating: unzip the new version and run Install.cmd again. It reuses your co-op folder, keeps your settings and
your friends, and replaces only the mod files. **Everyone needs the same version**: the status line and the
Friends list say when someone's is different.

### Optional: full character models

RE7's own full-body player models are incomplete (no real face). For complete characters in the Lobby, each
player can add the Nexus mod **Third Person Full Model Placeholders** (RE7 mod 86, by AfroJackX):

1. Download its **RT** main file from Nexus into your **Downloads** folder (no need to unzip it).
2. With the game closed, double-click **Use full models.cmd** (in this download). It finds the download, copies
   the models into a folder only the co-op mod reads (so your own first-person view stays normal), and switches
   on REFramework's Loose File Loader.

The Lobby then says "Full character models: installed".

## Play

1. Start Steam, then **Start Molded Together** (desktop shortcut). **Never played RE7?** Start a **New Game** and play
   through the opening drive until you can walk around before connecting; joining from the very first screen
   (no save yet) leaves the screen black. If the game asks to create save data, switch on **Allow saving** first
   (co-op menu > Options), then answer Yes.
2. On the title screen, choose **CO-OP** on the tape recorder (under EXIT). In play, press **F9** (or both sticks,
   **L3+R3**, on a controller). The **co-op screen** opens: two sheets of paper like the game's Options, the
   sections on sheet A, the chosen one on sheet B. Keyboard (arrows or WASD, Enter or F, Esc or Backspace), controller
   (D-pad or left stick, A, B) or mouse (point at a row, click to pick it, right click to go back). The first
   time, it explains the basics.
3. **Friends**: pick your friend and **Invite** them. (Friends appear once they've started Molded Together too.)
4. Your friend sees "*<your name>* invited you to co-op: press F9 to answer" at the bottom left. They press F9 and
   **Accept**.
5. The top-left corner shows **Co-op: connected to <name> - <ping> ms**, and they appear with their name over
   their head.
6. **Lobby**: one of you **hosts**. The host picks where to start:
   - **Continue: everyone's own latest save**: whoever is on the title screen loads their latest save, whoever is
     playing carries on (best with matching saves);
   - **The host's chapter**: everyone else goes to the start of the host's chapter;
   - **Chapter 1** (the guest house), **Chapter 3** (the Baker house, from the dinner) or **Chapter 4** (the ship).

   Everyone else marks themselves **Ready**; the host presses **Start**, and every game goes there at once. A
   chapter start needs everyone to have loaded a save first (**Continue** on the title screen): the menu says who
   it's waiting for. Saving switches off for a chapter jump; switch it back on in Options if you want to keep
   progress. Friends can also join a host directly: a friend hosting a lobby is marked in **Friends** (**Join**).
7. **Quick messages** (in the menu, or F5-F8): "Over here", "Come here", "Wait for me", "Go on ahead", "Help!",
   and (in the menu) "I need ammo" and "I need healing": your friend is told to give you some under **Give
   items**, which then has you picked, with your health.
8. **You appear as** (main page): how your friends see you (Ethan, Mia, Mia (ship), Clancy, Zoe, Chris, Joe).
9. **Give items**: pick a friend and how many (one, half or all), then the ammo, healing or material to give.
   Your friend's game puts it in their inventory and says how many arrived; only then does it leave yours (no
   room on their side: nothing moves).
10. **This session**: how long you've played together, and for each of you the enemies taken down, shots, hits
   taken, times down and back up, heals and items given.

**Play on the same difficulty.** Enemies have different health and damage on Casual, Normal and Madhouse, so
the Lobby and This session say when one of you plays on another, and you're told once when it's noticed.

Your friend is remembered, so next time it reconnects by itself. Everything is also in the REFramework window
(Insert), including connecting by SteamID.

**Disconnecting.** **Disconnect from everyone** (Help and fixes) leaves the session and your friends are told at
once. The host can remove a player: pick their row in the Lobby. A friend whose game has closed is disconnected
after 30 seconds; friends you played with in the last week reconnect by themselves when they invite you again.

**Behind in the story?** The host's game leads: its story steps play out in the others' games too, and a friend
who joins later catches up. The Lobby shows who's behind or ahead. A friend who's behind the host can choose
**Get the host's key items and weapons** (experimental); a friend who's ahead keeps their own.

**Meeting up.** If your friend is in another chapter: co-op menu > **Help and fixes** > **Go to your friend's
chapter**: you start at the beginning of their chapter, then walk to each other. Nothing from the jump is saved
(saving is switched off first). **Teleport to your friend** works once you're within 40 m of them.

**The menu key.** If F9 is also your REFramework menu key, pick another in co-op menu > Options > **Key for this
menu** (F10, F11, Home, End). L3+R3 always works. While the menu is open your character and the game's own menus
don't react; the game keeps running behind it.

### Playing with 3 or 4 players

Up to four can play together. Connect to your first friend as above; for the next one, click **Add** next to
their name (instead of Connect). Everyone links up by themselves: when you add two friends, they connect to each
other too, so each of you only needs one connection to the group. **Remove** takes someone out; at four players
the list says "party full". Everyone needs the same version.

With 3-4 players each friend has their own character, nameplate and line on the status line (name and health),
and their shots, flashes and knife swings come from their own character. Enemies and bosses are run by the game of
whoever is closest to them, as with two players; if enemies act oddly, untick **Share enemies with 3-4 players**
(Options, the same for everyone) and each game runs its own (damage and kills are still shared). A fatal hit puts
you down, and any friend who is still up can get you back up; it's a real death only when everyone is down. You
bump into each other, except around scripted scenes (so you can stand together where one starts) and when you get
stuck on each other; untick **Bump into your friend** (Options) to always walk through.

### No Insert key

REFramework opens and closes its menu (and the Molded Together window with it) with Insert only. Without that key the
menu stays on screen, with an extra mouse pointer. Give it another key once: click the REFramework window's title
bar to expand it, open **Configuration**, click **Menu Key** and press a key the game doesn't use, for example
**F10** (F9 opens the co-op menu, F5-F8 are the quick messages). Tick **Remember Menu State** there too, so the menu stays closed when the game
starts. Wherever this guide says Insert, use that key.

### The Molded Together window

Everything in the co-op menu, plus connecting by SteamID and the developer tools. Press **Insert**; the window
opens next to the REFramework menu. Its sections:

| Section | What's in it |
|---|---|
| **Lobby** | Both players, their chapters, and **You appear to your friend as**: Default (whoever you're playing), Ethan, Mia, Mia (ship), Clancy, Zoe, Chris, Joe. Without the full-model mod some lack a face. |
| **Talk and catch up** | Quick-message buttons (the same as F5-F8, plus "Go on ahead"), a switch for the F5-F8 keys, your catch-up list, **Catch up now** (both ways, if something looks out of step), and **Start a fresh list** (when you start a new game together; you're reminded if your list has changes from a later chapter than your friend's). |
| **Connect and saving** | Your Steam friends in Molded Together (**Connect**, **Accept**), **Show all online friends**, connecting by SteamID, **Allow saving** and **Back up saves now**. |
| **Options** | What's shown and what's shared (below). |
| **Help** | **Go to my friend's chapter**, **Teleport to my friend**, **Fast-forward this cutscene**, **Fix my friend's character**, **Reload last save**, **Make a bug report**. |
| **Show developer tools** | Off by default: the test bot and research tools (below). |

**Saving.** **Allow saving** is off by default: nothing you do is saved. Turn it on to save normally. Your save folder is
backed up automatically (at every launch and when you turn this on; the last 20 backups are kept in
`reframework\data\save_backups`). The co-op copy shares Steam Cloud saves with your normal RE7. When one of you saves,
the others see "Your friend saved" so you can all save at the same point.

**Options** (co-op menu > Options). Options marked *same for everyone* change for the whole group when any of you
changes them.

| Option | Default | What it does |
|---|---|---|
| **Share story** (same for everyone) | On | Story progress and cutscenes count for everyone (see *What's shared*). |
| **Share supplies** (same for everyone) | Off | One copy of ammo and healing for everyone: what one picks up disappears for the others. A harder game. |
| **Share interactions** (same for everyone) | On | Fridges, switches, locks, chains and puzzles one of you does are done for all (never saving, tapes or item boxes). |
| **Share phone calls** (same for everyone) | On | When one of you answers a phone, the others' call is answered too (also when they get there later). |
| **Join your friend's scripted moves** | Off | Off: a phone, fridge or pot your friend uses plays on their character and you keep control. On: you're put through it too. Cutscenes always play for everyone. |
| **Share pushed objects** (same for everyone) | On | Loose props one of you moves are moved in the other games too. |
| **Share boss fights** (same for everyone) | On | Mia's fights are one fight for everyone. |
| **One boss for both** (same for everyone) | On | Jack and Mia are run by the nearest player's game and can hurt any of you. Off: each game runs its own; health and defeat are shared. |
| **One Molded for both** (same for everyone) | On | Each Molded is one for everyone, in the same place on every screen (see *What's shared*). Off: each game runs its own; health and deaths are shared. |
| **Molded go after any of you** (same for everyone) | On | Only with "One Molded for both" off: a fighting Molded goes for the nearest of you in every game. |
| **Bump into your friend** | On | You can't walk through each other (lets go in scripted scenes and when you're stuck). |
| **Follow your friend into VHS tapes** | On | When your friend goes into a tape, your game follows a few seconds later (saving is switched off first). Never back out: finish the tape. |
| **Heal your friend** | Off | Use a healing item next to your friend (within about 2.5 m) and it heals them instead of you. |
| **Show your friend's weapon** | On | The weapon or item your friend holds appears in their character's hand. |
| **Hide your friend on ladders** | Off | Your friend climbs with the game's own ladder animation; on hides them while they climb instead. |
| **Nameplate over your friend** | On | Their Steam name, health and distance above their character; when they're off screen, a pointer at the screen edge. |
| **Friend's footsteps** | On | Hear your friend's footsteps where they walk. |
| **Your friend's voice** | On | Their grunts, screams and getting back up, in your own character's voice, from where they are. |
| **Your friend's flashlight** (experimental) | Off | In the dark, their flashlight shines where they look (a copy of your own light, so yours has to have been on once). |
| **One game leads the story** (same for everyone) | On | The host's story scenes play for everyone wherever you are, and the host's progress counts for all. |
| **Enemies chase both players** (same for everyone) | On | Up close, an enemy turns on whichever of you is nearer. |
| **On-screen status** | On | The top-left status lines (connection, ping, chapter, your friend's health, the last quick message, saving, what your friend just did). |

**Help:**

| Button | What it does |
|---|---|
| **Go to my friend's chapter** | Shown when you're in different chapters: jump to the start of theirs. Saving is switched off first. |
| **Teleport to my friend** | Hop to them when you're within 40 m (same chapter). Further away, walk: RE7 only loads the area around you. |
| **Fast-forward this cutscene** | Runs the game 8x while the cutscene plays (nothing is skipped, it's just quicker). |
| **Fix my friend's character** | Rebuilds your friend's character if it looks broken (T-pose, sliding, missing). |
| **Reload last save** | What Continue does. Not during a scene or a load, and not after a chapter jump: restart the game instead. |
| **Make a bug report** | Puts a zip of the co-op logs on your desktop, with SteamIDs, Steam names and your Windows user name blanked out, ready to send. |

**Developer tools** (tick **Show developer tools**; for trying things alone):

| Option | What it does |
|---|---|
| **Test with bot** | A fake player. **Follow me**: it walks the path you walked and waits near you (and can revive you). **Walk in a circle**: it cycles every stance and direction. **Stay here**: it stands still. **Dress the bot as** tries each character on it. |
| **Bot: ...** buttons | The bot "does" what a friend would: take down or hit the nearest enemy, open or unlock the nearest door, smash the nearest box, open or shut the nearest drawer, take the nearest supply, trigger the next story cutscene, pretend to be in another chapter. |
| **Take a fatal hit** | Go down on purpose (the bot revives you). |
| **Fast-forward every cutscene** | Like the Help button, for every cutscene. |
| **Chapter switcher** | Jump straight to any chapter. Only targets ending in `_Start` load into gameplay; saving is switched off first. |
| Research tools | Record and replay an enemy, hand an enemy to the bot, a reload test, and the ghost debug panel (REFramework menu, Script Generated UI). |

## Known limits

- **Played in co-op up to the Chapter 3 yard.** Two real sessions and the bot suite cover Chapter 1, the Baker
  house, the basement and the yard. Later chapters (the old house, the ship, the mines) use the same sharing but
  nobody has played them together yet: please send a bug report from there.
- **Bosses and Molded** are run by the nearest player's game and copied to the others. The copies were checked by
  bots (the same place to within about a metre, usually a few centimetres); a fast lunge can look a little behind on
  the other screen. A Molded's grab and Mia's attacks on a friend haven't been seen in a real session yet.
- **Story:** phone calls and scripted moves play on the friend's character; how that looks on screen hasn't been
  checked in a real session. Keys and story items are picked up by each player separately (you're told when your
  friend takes one), because some scripted events follow that player's own pickup. If a cutscene ever hangs and you
  can't move, restart the game and load again (with saving off, nothing is lost).
- **Animations:** your friend's character copies the moves RE7 plays on their body. In VHS tapes the character may
  slide instead of walking.
- **Characters:** Mia (non-ship) has a gap on her left side and dark eyes, even with the full-model mod. Joe's
  hands are found by trying likely file names; he may still have none.
- **Deaths:** going down has no fall animation (you crouch). The 90-second limit for being down is untested in a
  real session.
- **Item boxes** are separate per player. **Give items** moves ammo, healing and materials, not weapons or key
  items (those stay for everyone anyway).
- **Your friend's voice** comes from your own character's sounds, placed where your friend is. If it ever sounds
  as if it's your own character (inside your head), turn off **Your friend's voice** and say so in a bug report.
- Tested on RE7's current (ray-tracing) version. The older non-RT version (Steam beta `dx11_non-rt`) should
  work but hasn't been tried; the installer tells you if you're on it.
- **A rare crash at the end of a cutscene** was seen twice in the bot tests, both times when a bot was moved far
  away right as a scene finished. Teleporting is held back for 3 seconds after a scene now; if a game ever
  closes at the end of a scene, please send a bug report.
- The chapter jump is a hidden developer feature of RE7: after many jumps in one session it can break (black
  screen, outside the map). Restart the game if that happens.

## Troubleshooting

| What you see | Try |
|---|---|
| "Molded Together's network plugin isn't running" (red, top left), or **Test with bot** / **Invite** do nothing | REFramework's C# plugins didn't load. The usual cause is Windows 11's **Smart App Control**, which blocks REFramework's unsigned files (REFramework's log, `re2_framework_log.txt` in your co-op folder, then says *"An Application Control policy has blocked this file"*; the installer warns when Smart App Control is on). It's a Windows security setting, so it's your call: Windows Security > App & browser control > Smart App Control settings. On many Windows versions it can't be switched back on afterwards without reinstalling Windows. Also check that the **.NET 10 runtime** is installed (see Install). |
| Your friend isn't in the list | They need Molded Together running and to be your Steam friend; or tick **Show all online friends** |
| "Waiting for your friend" | They need to **Accept** in their co-op screen; if their game is closed, it clears by itself after 30 seconds |
| "different version" or "Friend's packets don't match" | You're on different versions; everyone installs the same release |
| "Friend is in another chapter" | F9 > **Help and fixes** > **Go to your friend's chapter**, or a lobby with **The host's chapter** |
| Their label moves but no body | Wait a few seconds, or F9 > **Help and fixes** > **Fix your friend's character** |
| A Molded or boss stands still on your screen | It's being run by your friend's game: it moves again within a few seconds. If not, tell us in a bug report |
| Stuck after a cutscene, can't move | Restart the game and load again |
| Black screen or outside the map after chapter jumps | Restart the game |
| Black screen but you can move, on a brand-new game | Start a **New Game** alone, play the opening until you can walk, then connect |
| "Create save data?" keeps coming back | F9 > **Options** > **Allow saving**, then Yes |
| An extra mouse pointer on screen | The REFramework menu is open: close it with Insert (or your menu key, see *No Insert key*) |
| F9 opens REFramework's menu too | F9 is your REFramework menu key: pick another for the co-op menu (Options > **Key for this menu**) |
| The lobby's Start says "waiting" | It names who it waits for: everyone **Ready**, and for a chapter start everyone in the game (not the title screen) |
| Pause menu won't open | Wait 5 seconds out of any cutscene (the mod clears a stuck video flag), or restart |
| You see the inside of a head in first person | The full-model mod's files are in place but not set up: close the game and run **Use full models.cmd** |

For a bug report, choose **Make a bug report** (co-op menu > Help and fixes, or the Molded Together window) and send the
zip it puts on your desktop. The logs are in your co-op folder's `reframework\data`: `coop_dummy_log.txt`, `coop_menu_log.txt`,
`coop_enemies_log.txt`, `coop_world_log.txt`, `coop_story_log.txt`, `coop_revive_log.txt` and
`coopnet_status.txt`. `coopnet_status.txt` contains your SteamID and Steam name; remove them before posting
publicly (the bug-report zip does this for you).

## How it works

REFramework Lua scripts build the other player from the full-body "shadow" model RE7 keeps for the player
(it renders it only for the player's shadow), or from the character picked in the Lobby, and animate it with
Ethan's own animations, including the upper-body moves your body plays (blocking). A C# plugin sends 30 small
updates a second over Steam's relay network (`ISteamNetworkingMessages`), plus guaranteed messages for things
that happen once (a kill, a door, a pickup, a story step) and 10-a-second enemy updates. Each enemy and boss is
run by one game (the nearest player's) with its own AI; the other games turn that enemy's AI off and move it from
those updates. The scripts:

| Script | Does |
|---|---|
| `coop_dummy.lua` | Your friend's character, the Lobby, connecting, the Molded Together window, on-screen status, footsteps |
| `coop_enemies.lua` | One Molded and one boss for everyone: who runs each enemy, the copies, damage, deaths, pausing |
| `coop_world.lua` | Shared doors, drawers, lockers, breakable boxes, puzzles, key-item locks and supplies |
| `coop_talk.lua` | The catch-up list, quick messages, pings, health and the shared options |
| `coop_menu.lua` | The in-game co-op screen (CO-OP on the title screen, F9 / L3+R3): lobby, friends, quick messages, give items, this session, options, help |
| `coop_gunsound.lua` | Your friend's gunshots, reloads and swings, their voice and their flashlight |
| `coop_story.lua` | Shared story steps, cutscenes and phone calls; "your friend saved" |
| `coop_revive.lua` | Downed and revive |
| `coop_saveguard.lua` | Blocks saving unless you allow it |
| `CoopNet.cs` | The network plugin (Steam relay, bot, save backups, bug reports) |

Details and everything learned along the way are in [docs/NOTES.md](docs/NOTES.md) and the coop-anything
write-up `games/resident-evil-7`.
