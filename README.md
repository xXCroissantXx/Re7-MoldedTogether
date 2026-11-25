# Molded Together: online co-op for Resident Evil 7 (v0.66; formerly coop-re7)
Created by xXCroissantXx & Kingkiller1195

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
| **Giving items** | Discard ammo, healing or materials in your inventory and it lands on your friend's ground too, to pick up. |
| **Supplies** | Each player gets their own ammo, healing and crafting materials. For a harder game, tick **Share supplies**: then there's one copy, and whatever one player picks up disappears for the others. Weapons, keys, files and maps always stay for everyone, so nobody gets stuck; when one of you takes one, the others are told to pick it up too. |
| **Deaths** | With a friend connected, a fatal hit (also in a grab or a boss fight) puts you **down** instead of a game over, until a friend stands next to you for 3 seconds. It's a real game over only when everyone is down. |
| **Pausing** | The others see "Your friend paused the game"; enemies your game was running carry on in theirs. |
| **Saving** | Each player saves their own game; when one saves, the others are told, so you can all save at the same point. |
| **Pushed objects** | Chairs, bottles and other loose props one of you knocks around move for the others too. |
| **Catching up** | Each game keeps a list of the lasting changes it made (doors, boxes, drawers, puzzles, story steps, supplies taken, Molded killed) for 12 hours. When your friend joins or rejoins, the list is sent and their game catches up, including what you did while they were away. |
| **Talking** | Quick messages with **F5** (ping: "Over here"), **F6** (Come here), **F7** (Wait for me) and **F8** (Help!): your friend sees them at the top of the screen, and a marker for pings, Come here and Help. Each other's **health** shows on the nameplate (and the corner status text, if you switch it on). |
| **Gunshots and swings** | Each of your friend's guns makes its own bang (handguns, shotgun, magnum and the rest), with the muzzle flash and smoke at their gun; their reloads and their knife and axe swings are heard too. |
| Not shared | Item boxes (each player has their own). |

Made with [coop-anything](https://github.com/cranebeaker/coop-anything). MIT licensed. Want to help? See
[CONTRIBUTING.md](CONTRIBUTING.md).

## Install (every player)

1. Have **Resident Evil 7 biohazard on Steam**, fully updated, and close the game.
2. Download **molded-together-vX.zip** from the **Releases** page and unzip it anywhere.
3. Double-click **Install.cmd**. That's it. It finds RE7 in your Steam libraries and puts **REFramework** (from
   its official release, each file's SHA-256 checked) and Molded Together straight into RE7's own Steam folder.
   Nothing is copied, and your saves are backed up first.
   - No **.NET 10 runtime** yet? The installer offers to install it for you (press Enter). Without Windows'
     package manager it gives you the download link instead: ".NET Runtime 10" (Windows x64) from
     https://dotnet.microsoft.com/download/dotnet/10.0.
   - If the Steam folder needs administrator rights, Windows asks you to allow it, and the install carries on
     in a new window.
   - Another multiplayer mod, **RE7MP**, can't run alongside it: the installer moves RE7MP's reframework folder
     aside (renamed `reframework.re7mp-backup-<date>`, nothing is deleted). An **REFramework version** it doesn't
     know (put there by another mod) is replaced only if you say yes; the old one is kept as a backup.
   - **Full character models** (see below) are set up in the same run: the installer opens the mod's Nexus page,
     waits while you click **Manual download**, and carries on by itself when the file is in your Downloads folder.
4. Start RE7 from **Steam** as usual (**Play**): the mod loads with it. The very first start takes a few minutes
   longer while REFramework sets itself up.

Saving is on, as in normal RE7, and your save folder is backed up at every launch. To play without saving, switch
off **Allow saving** (co-op menu > Options).

**Playing RE7 without the mod:** double-click **Normal RE7 (mod off).cmd**. Your co-op settings stay; run
**Install.cmd** again to switch it back on.

**Updating:** unzip the new version and run **Install.cmd** again. It keeps your settings and your friends and
replaces only the mod files. **Everyone needs the same version**: the status line and the Friends list say when
someone's is different. Steam's updates and "Verify integrity of game files" leave the mod's files alone; if an
update ever stops the mod loading, run Install.cmd again.

**Coming from v0.50 or older?** Those made a separate copy of the game in `Documents\RE7-coop` (or
`C:\RE7-coop`). You don't need it any more: run the new Install.cmd, then delete that folder and its **Start
Molded Together** desktop shortcut to get the space back (your saves aren't in it).

### Full character models (set up by Install.cmd)

RE7's own full-body player models are incomplete (no real face). For complete characters in the Lobby, **Install.cmd**
sets up the Nexus mod **Third Person Full Model Placeholders** (RE7 mod 86), made by **AfroJackX**; all credit
for the models and their setup goes to them. Please endorse the mod on its
[Nexus page](https://www.nexusmods.com/residentevil7/mods/86). The file used is **Third Person Full Model
Placeholders RT (2022)**.

Its files belong to their author, so this download doesn't contain them, and an installer can't fetch them for
you: Nexus Mods only lets a signed-in account download (a free one is enough) and doesn't allow scripts to do it.
So Install.cmd asks to open the page; click **Manual download** on that file and leave the installer window open:
it notices the file in your Downloads folder (no need to unzip it), copies the models in, moves them to a
folder only the co-op mod reads (so your own first-person view stays normal), and switches on REFramework's
Loose File Loader. If you already have the zip in Downloads, it just goes ahead. You can say no and add them later:
download the file and run **Install.cmd** again.

The Lobby then says "Full character models: installed".

## Play

1. Start RE7 from Steam (**Play**). **Never played RE7?** Start a **New Game** and play
   through the opening drive until you can walk around before connecting; joining from the very first screen
   (no save yet) leaves the screen black. If the game asks to create save data, answer Yes.
2. On the title screen, choose **CO-OP** on the tape recorder (under EXIT). In play, press **F9** (or both sticks,
   **L3+R3**, on a controller). The **co-op screen** opens: two sheets of paper like the game's Options, the
   sections on sheet A, the chosen one on sheet B. Keyboard (arrows or WASD, Enter or F, Esc or Backspace), controller
   (D-pad or left stick, A, B) or mouse (point at a row, click to pick it, right click to go back). The first
   time, it explains the basics.
3. **Friends**: pick your friend and **Invite** them. (Friends appear once they've started Molded Together too.)
4. Your friend sees "*<your name>* invited you to co-op: press F9 to answer" at the top of the screen. They press F9
   and **Accept**.
5. They appear with their name over their head; the co-op menu shows the connection and the ping. (Since v0.64
   nothing is written in the corners of the screen; Options > **Status text in the corners** brings it back.)
6. **Lobby**: once you're connected, open the co-op menu (or **CO-OP** on the title screen's tape recorder) and
   pick **Lobby**: whoever opens it first is the host, and everyone else is in it and ready by themselves. The
   host picks where to start:
   - **Continue (own saves)**: whoever is on the title screen loads their latest save, whoever is playing carries
     on (best with matching saves);
   - **New Game**: everyone starts a new game together, from the opening;
   - **The host's chapter**: everyone else goes to the start of the host's chapter;
   - **Chapter 1** (the guest house), **Chapter 3** (the Baker house, from the dinner) or **Chapter 4** (the ship).

   The host presses **Start**, and every game goes there at once, **from the title screen too**: a game on the
   title screen loads its latest save first (or starts a New Game if it has none) and then goes to the chapter.
   Anyone can set **Ready** to No to hold the start back. Saving switches off for a chapter jump or a New Game,
   and comes back on by itself once you're playing in the story again. Friends can also join a host directly: a friend
   hosting a lobby is marked in **Friends** (**Join**).
7. **Quick messages** (F5-F8): "Over here", "Come here", "Wait for me" and "Help!"; your friend sees them on
   screen.
8. **You appear as** (main page): how your friends see you (Ethan, Mia, Mia (ship), Clancy, Zoe, Chris, Joe).
9. **This session**: how long you've played together, and for each of you the enemies taken down, shots, hits
   taken, times down and back up, heals and items given.

**Play on the same difficulty.** Enemies have different health and damage on Casual, Normal and Madhouse, so
the Lobby and This session say when one of you plays on another, and you're told once when it's noticed.

Your friend is remembered, so next time it reconnects by itself. Everything is also in the REFramework window
(Insert), including connecting by SteamID.

**Disconnecting.** **Disconnect from everyone** (Help and fixes) leaves the session and your friends are told at
once. The host can remove a player: pick their row in the Lobby. A friend whose game has closed is disconnected
after 30 seconds; friends you played with in the last week reconnect by themselves when they invite you again.

**Behind in the story?** The host's game leads: its story steps play out in the others' games too, and a friend
who joins later catches up. The Lobby shows who's behind or ahead. Key items and weapons are each player's own
(the experimental "Get the host's key items and weapons" was removed in v0.55: the game can't put them down to
pick up, and the other way in could crash the game).

**Dropping in.** Connect while your friend is already playing and your game brings you to them (since v0.63): in
another chapter, a note counts down and you go to the start of theirs; the story catches up; then you're warped
next to them. Your inventory stays your own. From the title screen your latest save loads first (since v0.65).
With three or four of you, a guest joins the host. A friend who leaves or whose game closes hands back what their
game ran within about 5 seconds.

**Meeting up.** If your friend is in another chapter: co-op menu > **Help and fixes** > **Go to your friend's
chapter**: you start at the beginning of their chapter, then walk to each other. Saving is switched off for the
jump and comes back on by itself about 20 seconds after you're in the story. **Teleport to your friend** works once you're within 40 m of them.

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

**Saving.** **Allow saving** is on by default: you save as in normal RE7. Turn it off to play without saving. Your save
folder is backed up automatically (at every launch and when you turn saving on; the last 20 backups are kept in
`reframework\data\save_backups`). Co-op and normal RE7 use the same saves (Steam Cloud too). When one of you saves,
the others see "Your friend saved" so you can all save at the same point.

**Options** (co-op menu > Options). Only the settings that change how the game plays, and the experimental ones,
are here; the rest of co-op (shared story, doors and interactions, phones, pushed objects, bosses, one Molded for
everyone, enemies chasing both players, following into tapes) is simply on. Options marked *same for everyone*
change for the whole group when any of you changes them.

| Option | Default | What it does |
|---|---|---|
| **Share supplies** (same for everyone) | Off | One copy of ammo and healing for everyone: what one picks up disappears for the others. A harder game. |
| **Drop discarded items for your friend** (same for everyone) | On | An item you discard in the inventory also lands on your friend's ground to pick up (supplies only). |
| **Join your friend's scripted moves** | Off | Off: a phone, fridge or pot your friend uses plays on their character and you keep control. On: you're put through it too. Cutscenes always play for everyone. |
| **Bump into your friend** | On | You can't walk through each other (lets go in scripted scenes and when you're stuck). |
| **Heal your friend** | Off | Use a healing item next to your friend (within about 2.5 m) and it heals them instead of you. |
| **Your friend's flashlight** (experimental) | Off | In the dark, their flashlight shines where they look (a copy of your own light, so yours has to have been on once). |
| **Host runs every enemy** (experimental, same for everyone) | Off | The host's game runs every enemy and they go after whichever of you is nearer; your friend's game shows copies that hit them where they really are. No enemy changes games mid-fight. |
| **Cutscenes wait for both** (experimental) | Off | A cutscene or VHS tape you start waits a moment for your friend's game, then starts for both together. Each of you sets it. |
| **Menu text size** | Large | Normal, Large or Extra large. |
| **Key for this menu** | F9 | F9, F10, F11, Home or End. |
| **Allow saving** | On | Save as in normal RE7 (your saves are backed up at every launch). A chapter jump switches it off for the jump; it comes back on by itself. |

The settings that left this page still work: they're in `coop_settings.json` (co-op folder, `reframework\data`)
and in REFramework's **Molded Together** window, with the same names as before (the nameplate, footsteps, voice,
your friend's weapon in hand, ladders, on-screen status and the shared switches).

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

- **Played in co-op up to the Chapter 3 yard.** Real sessions cover Chapter 1, the Baker house, the basement and
  the yard. The bots have stepped through the rest of the story together (all of Chapter 3, Chapter 4 on the
  ship and after, and the first tape) with both games at the same step every time, and every kind of interaction
  in those areas is shared, but nobody has played the later chapters together yet: please send a bug report.
- **Later bosses** (the old house, the ship and the end of the game) share their health and defeat, but each
  game runs its own copy of the fight; Jack, Mia and Marguerite (since v0.62) are run by one game for both.
- **Bosses and Molded** are run by the nearest player's game and copied to the others. The copies were checked by
  bots (the same place to within about a metre, usually a few centimetres); a fast lunge can look a little behind on
  the other screen. Jack's grabs play on the other screen too (since v0.59). A Molded's grab and Mia's attacks on
  a friend haven't been seen in a real session yet.
- **Story:** phone calls and scripted moves play on the friend's character; how that looks on screen hasn't been
  checked in a real session. Keys and story items are picked up by each player separately (you're told when your
  friend takes one), because some scripted events follow that player's own pickup. If a cutscene ever hangs and you
  can't move, restart the game and load your last save.
- **Animations:** your friend's character copies the moves RE7 plays on their body. In a grab RE7 mostly moves the
  camera, not the body, so a grabbed friend looks like they're standing still.
- **Characters:** Mia (non-ship) has a gap on her left side and dark eyes, even with the full-model mod. Joe's
  hands are found by trying likely file names; he may still have none.
- **Deaths:** going down has no fall animation (you crouch). The 90-second limit for being down is untested in a
  real session.
- **Item boxes** are separate per player. To pass ammo, healing or materials, discard them: they land on your
  friend's ground too. Weapons and key items stay each player's own.
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
| "Molded Together's network plugin isn't running" (red, at the top of the screen once a minute), or **Test with bot** / **Invite** do nothing | REFramework's C# plugins didn't load. Run **Install.cmd** again (with the game closed). If that doesn't help, the usual cause is Windows 11's **Smart App Control**, which blocks REFramework's unsigned files (REFramework's log, `re2_framework_log.txt` in RE7's Steam folder, then says *"An Application Control policy has blocked this file"*; the installer warns when Smart App Control is on). It's a Windows security setting, so it's your call: Windows Security > App & browser control > Smart App Control settings. On many Windows versions it can't be switched back on afterwards without reinstalling Windows. Also check that the **.NET 10 runtime** is installed (see Install). |
| Your friend isn't in the list | They need Molded Together running and to be your Steam friend; or tick **Show all online friends** |
| "Waiting for your friend" | They need to **Accept** in their co-op screen; if their game is closed, it clears by itself after 30 seconds |
| "different version" or "Friend's packets don't match" | You're on different versions; everyone installs the same release |
| "Friend is in another chapter" | F9 > **Help and fixes** > **Go to your friend's chapter**, or a lobby with **The host's chapter** |
| Their label moves but no body | Wait a few seconds, or F9 > **Help and fixes** > **Fix your friend's character** |
| A Molded or boss stands still on your screen | It's being run by your friend's game: it moves again within a few seconds. If not, tell us in a bug report |
| Stuck after a cutscene, can't move | Restart the game and load again |
| Black screen or outside the map after chapter jumps | Restart the game |
| Black screen but you can move, on a brand-new game | Fixed in v0.52 (you can connect before New Game). If it still happens, it fades back in by itself after 25 seconds; tell us in a bug report |
| "Create save data?" keeps coming back | F9 > **Options**: check **Allow saving** is on, then Yes |
| An extra mouse pointer on screen | The REFramework menu is open: close it with Insert (or your menu key, see *No Insert key*) |
| The co-op menu's text is too small (or too big) | Options > **Menu text size**: Normal, Large (the default) or Extra large. It also follows your screen's size, and the corner status text (if on) uses it too |
| F9 opens REFramework's menu too | F9 is your REFramework menu key: pick another for the co-op menu (Options > **Key for this menu**) |
| The lobby's Start says "waiting" | It names who it waits for: a friend who hasn't been heard from yet (wait a few seconds) or who set **Ready** to No |
| Pause menu won't open | Wait 5 seconds out of any cutscene (the mod clears a stuck video flag), or restart |
| You see the inside of a head in first person | The full-model mod's files are in place but not set up: close the game and run **Install.cmd** again |
| The Lobby says "Full character models: not installed" | Download **Third Person Full Model Placeholders RT (2022)** from [Nexus](https://www.nexusmods.com/residentevil7/mods/86?tab=files) into Downloads and run **Install.cmd** again |

For a bug report, choose **Make a bug report** (co-op menu > Help and fixes, or the Molded Together window) and send the
zip it puts on your desktop. The logs are in RE7's Steam folder (Steam > RE7 > Manage > Browse local files), in `reframework\data`: `coop_dummy_log.txt`, `coop_menu_log.txt`,
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
| `coop_menu.lua` | The in-game co-op screen (CO-OP on the title screen, F9 / L3+R3): lobby, friends, this session, options, help |
| `coop_gunsound.lua` | Your friend's gunshots, reloads and swings, their voice and their flashlight |
| `coop_story.lua` | Shared story steps, cutscenes and phone calls; "your friend saved" |
| `coop_revive.lua` | Downed and revive |
| `coop_saveguard.lua` | Blocks saving when you switch it off |
| `CoopNet.cs` | The network plugin (Steam relay, bot, save backups, bug reports) |

Details and everything learned along the way are in [docs/NOTES.md](docs/NOTES.md) and the coop-anything
write-up `games/resident-evil-7`.

## Credits

- **xXCroissantXx** and **Kingkiller1195**: Molded Together's developers.
- **AfroJackX**: [Third Person Full Model Placeholders](https://www.nexusmods.com/residentevil7/mods/86) (Nexus RE7
  mod 86), the complete character models that **Install.cmd** sets up for the Lobby (the **RT (2022)** file). Not
  included in this download: each player gets it from Nexus. The mod's page credits the people its own work builds
  on; please see it there.
- **praydog**: [REFramework](https://github.com/praydog/REFramework), which this mod runs on (installed by
  Install.cmd from its official release).
