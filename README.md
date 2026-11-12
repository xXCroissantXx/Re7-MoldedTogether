# Molded Together: online co-op for Resident Evil 7 (prototype, v0.48; formerly coop-re7)

Play Resident Evil 7 with a friend over the internet. Each of you sees the other as a full-body character (Ethan,
or anyone you pick in the Lobby) who walks, jogs, crouches, sidesteps, looks around, blocks and acts where they do,
over Steam (no port forwarding).

> **Prototype.** The first real two-player session (2026-11-02) got from the start of the game to the first
> save point after Chapter 3: connecting, seeing each other, fighting Mia together and reviving worked. Much of
> what it found is fixed in this version but hasn't had a second session yet.
> [TWO-PLAYER-TEST.md](TWO-PLAYER-TEST.md) is a checklist for one.

## What's shared

| | |
|---|---|
| **Each other** | Position, movement, crouching, looking around, footsteps, which chapter you're in, and the moves RE7 plays on your body (blocking, weapon swings, both hands, the weapon held up while walking, climbing, getting hit, touching doors). A downed friend lies on the floor. Their weapon or the item they're using in hand. Their voice: grunts when they're hit, block, land or climb, a scream if they die. Their flashlight in the dark (experimental, Options). A marker with the distance, pointing the way when they're off screen. How you look: pick a character in the **Lobby**. |
| **Enemies** (early) | Each enemy is run by the game of the player nearest to it and follows along in the other game; it changes hands when the other player gets clearly closer, and when one of you pauses. Damage and deaths count in both games, and your friend's hits make the enemy flinch (experimental). **Bosses** (Jack's garage car fight and later, found by story progress) run in each game on their own, with shared damage and defeat. |
| **Doors, drawers, boxes, interactions** | A door unlocked, opened or closed in one game does the same in the other. Drawers open and shut for both; a breakable box smashed by one disappears for the other (no pieces), and each of you gets its item. One-off interactions (the fridge, the van, the pot, switches) happen in both games (experimental). |
| **Giving items** | Give your friend ammo, healing or crafting materials from the co-op screen (**Give items**): it leaves your inventory only once it's in theirs. |
| **Supplies** | Each player gets their own ammo, healing and crafting materials. For a harder game, tick **Share supplies** (one setting for both of you): then there's one copy, and whatever one player picks up disappears for the other. Weapons, keys, files and maps always stay for both, so nobody gets stuck; when one of you takes one, the other is told to pick it up too. |
| **Story** (experimental, off by default) | With **Share story** ticked, a cutscene that one of you starts also plays for the other when you're close together (same chapter, about 12 m). Scenes that come in a row (the dinner, then the escape) play in each game in their own time once that game has started them, so nobody skips what's in between. Jack's scripted moments happen in each game when its own player sets them off. **VHS tapes:** when your friend puts one in, you follow them into it. |
| **Deaths** | With your friend connected, a fatal hit puts you **down** instead of a game over, until your friend stands next to you for 3 seconds. |
| **Pausing** | The other player sees "Your friend paused the game"; enemies your game was running carry on in theirs. |
| **Saving** | Each player saves their own game; when one saves, the other is told, so you can both save at the same point. |
| **Pushed objects** (experimental) | Chairs, bottles and other loose props one of you knocks around move for the other too. |
| **Catching up** | Each game keeps a list of the lasting changes it made (doors unlocked, boxes smashed, drawers, switches, supplies taken, Molded killed) for 12 hours. When your friend joins or rejoins, the list is sent and their game catches up, including what you did while they were away. |
| **Talking** | Quick messages with **F5** (ping: "Over here"), **F6** (Come here), **F7** (Wait for me) and **F8** (Help!): your friend sees them at the top of the screen, and a marker for pings, Come here and Help. Each other's **health** shows on the status line and nameplate. |
| Not shared | Item boxes, puzzles. |
| **Gunshots and swings** | Each of your friend's guns makes its own bang (handguns, shotgun, magnum and the rest), with the muzzle flash and smoke at their gun; their reloads and their knife and axe swings are heard too. |

Made with [coop-anything](https://github.com/cranebeaker/coop-anything). MIT licensed.

## Install (both players)

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
your friend, and replaces only the mod files. **Both players need the same version.**

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

**Behind in the story?** The Lobby shows who's behind or ahead. A friend who's behind the host can choose **Get the
host's key items and weapons** (experimental); a friend who's ahead keeps their own. A key item one of you uses up
(the VHS tape in the VCR, a key in its last lock) goes from everyone's inventory.

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
and their shots, flashes and knife swings come from their own character. Enemies are run by the game of whoever
is closest to them, as with two players; if enemies act oddly, untick **Share enemies with 3-4 players**
(Options, the same for everyone) and each game runs its own (damage and kills are still shared). A fatal hit puts you
down, and any friend who is still up can get you back up; it's a real death only when everyone is down. You bump into each
other, except around scripted scenes (so you can stand together where one starts) and when you get stuck on each
other; untick **Bump into your friend** (Options) to always walk through. In boss fights (Mia) one game runs the boss and the other copies her; untick **Share boss
fights** (Options, the same for both) if she acts oddly.

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
the other sees "Your friend saved" so you can both save at the same point.

**Options:**

| Option | What it does |
|---|---|
| **On-screen status** | The top-left status lines (connection, ping, chapter, your friend's health, the last quick message, saving, what your friend just did). |
| **Nameplate over your friend** | Their Steam name, health and distance above their character; when they're off screen, a pointer at the screen edge. |
| **Friend's footsteps** | Hear your friend's footsteps where they walk (walk, jog and crouch sounds). |
| **Friend's voice** | On by default. Their grunts when they're hit, block, land or climb, their scream if they die, getting back up, pouring the First Aid Med: your own character's voice, from where they are. |
| **Friend's flashlight** (experimental) | Off by default. In the dark, your friend's flashlight shines where they look: a copy of your own flashlight's light, so yours has to have been on once. |
| **Share story (cutscenes and progress, experimental; same for both)** | Off by default. One setting for both: when either of you ticks or unticks it, it changes for the other too. When ticked, a story cutscene your friend reaches also plays for you, but only if you're in the same chapter and within about 12 m of them; otherwise you see it yourself when you get there. A later scene of a sequence you've already started isn't pushed on you: your game plays it when you get to that point. Story progress is copied only when you're together and not in the middle of a scene or a sequence, so a player who's behind is never pushed ahead. After either of you loads a save, scenes from after that save can play again. |
| **Show your friend's weapon** | On by default. The weapon or item your friend holds appears in their character's hand. |
| **Heal my friend** (experimental) | Off by default. Use a healing item while standing next to your friend (within about 2.5 m) and it heals them instead of you. |
| **Hide my friend on ladders** | On by default. RE7 has no climbing animation for the body, so your friend's character disappears while they climb and comes back at the top. |
| **Follow my friend into VHS tapes** | On by default. When your friend goes from your chapter into a tape, your game jumps into it after them a few seconds later (saving is switched off first). Never back out: finish the tape. |
| **Share interactions** (experimental) | On by default; one setting for both players. One-off interactions and switches one of you uses happen in the other game too (never saving, tapes or item boxes). Turn off if one ever does something odd. |
| **Share pushed objects** (experimental) | On by default; one setting for both players. Loose props one of you moves are moved in the other game too. |
| **Share phone calls** | On by default; one setting for both players. When one of you answers a phone, the other's phone is answered too (also when they get there later). Turn off if a call ever starts at a bad moment. |
| **Share supplies** | Off by default: each of you gets your own ammo and healing. One setting for both, like Share story. Tick it for a harder game with one copy for both: what one picks up disappears for the other. |

**Help:**

| Button | What it does |
|---|---|
| **Go to my friend's chapter** | Shown when you're in different chapters: jump to the start of theirs. Saving is switched off first. |
| **Teleport to my friend** | Hop to them when you're within 40 m (same chapter). Further away, walk: RE7 only loads the area around you. |
| **Fast-forward this cutscene** | Runs the game 8x while the cutscene plays (nothing is skipped, it's just quicker). |
| **Fix my friend's character** | Rebuilds your friend's character if it looks broken (T-pose, sliding, missing). |
| **Reload last save** | What Continue does. Not after a chapter jump: restart the game instead. |
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

- **One real two-player session so far.** Fixes since then (enemy hand-offs, doors closing, boxes, drawers,
  pausing, the Lobby, blocking, the story rework, everything new in v0.13) were tested alone or with the bot only.
- **Animations:** your friend's character copies the moves RE7 plays on their body. Knife swings are tested (with
  the bot, slightly choppy); other weapons use the same path but are untested. Scripted moments played by other actors (phone calls, the leg
  scene) aren't shown. In VHS tapes the character may slide instead of walking.
- **Characters:** Mia (non-ship) has a gap on her left side and dark eyes, even with the full-model mod. Joe's
  hands are found by trying likely file names; he may still have none.
- **Enemies:** an enemy runs on one player's game and mostly goes after that player. Flinching from your
  friend's hits is a first attempt. Jack's scripted moments (smashing through a wall) happen in each game
  on its own, when that game's player sets them off. During a cutscene, either player's, enemies aren't
  copied between games: the scene moves them in each game.
- **Story:** keys and story items are picked up by each player separately (you're told when your friend takes
  one), because some scripted events follow that player's own pickup. If a cutscene ever hangs and you can't
  move, restart the game and load again (with saving off, nothing is lost).
- **Interactions** are shared by running the game's own "done" step in the other game; it may not show the
  animation, and puzzles aren't included.
- **Deaths:** going down has no fall animation (you crouch). "Both down" and the 90-second limit are untested.
- **Item boxes** are separate per player. **Give items** moves ammo, healing and materials, not weapons or key
  items (those stay for both anyway).
- **Your friend's voice** comes from your own character's sounds, placed where your friend is. If it ever sounds
  as if it's your own character (inside your head), turn off **Friend's voice** and say so in a bug report.
- **Your friend's flashlight** is new and untested in a real game, so it's off by default (Options).
- Tested on RE7's current (ray-tracing) version. The older non-RT version (Steam beta `dx11_non-rt`) should
  work but hasn't been tried; the installer tells you if you're on it.
- The chapter jump is a hidden developer feature of RE7: after many jumps in one session it can break (black
  screen, outside the map). Restart the game if that happens.

## Troubleshooting

| What you see | Try |
|---|---|
| Your friend isn't in the list | They need Molded Together running and to be your Steam friend; or tick **Show all online friends** |
| "Waiting for your friend" | They need to **Accept** in their co-op screen; if their game is closed, it clears by itself after 30 seconds |
| "Friend's packets don't match" | You're on different coop-re7 versions; both install the same release |
| "Friend is in another chapter" | F9 > **Help and fixes** > **Go to your friend's chapter**, or a lobby with **The host's chapter** |
| Their label moves but no body | Wait a few seconds, or F9 > **Help and fixes** > **Fix your friend's character** |
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
that happen once (a kill, a door, a pickup, a cutscene) and 10-a-second enemy updates. The scripts:

| Script | Does |
|---|---|
| `coop_dummy.lua` | Your friend's character, the Lobby, connecting, the Molded Together window, on-screen status, footsteps |
| `coop_enemies.lua` | Shared enemy damage, deaths and movement (who runs each enemy), pausing |
| `coop_world.lua` | Shared doors, drawers, breakable boxes and supplies |
| `coop_talk.lua` | The catch-up list, quick messages, pings and health |
| `coop_menu.lua` | The in-game co-op screen (CO-OP on the title screen, F9 / L3+R3): lobby, friends, quick messages, give items, this session, options, help |
| `coop_gunsound.lua` | Your friend's gunshots, reloads and swings, their voice and their flashlight |
| `coop_story.lua` | Shared story cutscenes and progress; "your friend saved" |
| `coop_revive.lua` | Downed and revive |
| `coop_saveguard.lua` | Blocks saving unless you allow it |
| `CoopNet.cs` | The network plugin (Steam relay, bot, save backups, bug reports) |

Details and everything learned along the way are in [docs/NOTES.md](docs/NOTES.md) and the coop-anything
write-up `games/resident-evil-7`.
