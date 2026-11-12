# Molded Together: notes for Claude (and anyone coding on it)

Online co-op mod for Resident Evil 7 (Steam, RE Engine), made of REFramework Lua scripts plus one C# plugin.
Read this first, then `docs/NOTES.md` for what has already been learned about each game system before probing
it again.

## Layout

| Path | What |
|---|---|
| `reframework/autorun/coop_*.lua` | The mod. Each script is one area (see the README's "How it works"). |
| `reframework/plugins/source/CoopNet.cs` | The network plugin: Steam relay / UDP link, messages, save backups, bug reports. REFramework compiles it when the game starts. |
| `tests/harness/` | A stand-in game (`fakegame.lua`) and scenario tests that run the scripts without RE7. |
| `tools/check.py` | Every check the release build runs. Must pass before a pull request. |
| `install-coop-re7.ps1`, `Install.cmd` | The installer (copies RE7, installs REFramework, the mod and a shortcut). |
| `docs/NOTES.md` | Findings, dead ends and evidence, oldest first. Long; search it. |
| `README.md`, `CHANGELOG.md`, `TWO-PLAYER-TEST.md` | Player docs. |

How the games talk: each script sends short text events (`send_event("kill <id> <chapter> <name>")` in
coop_enemies, `send("story <scene> <chapter>")` in coop_story, ...), CoopNet.cs carries them, and the other
game's script parses them in its `on_event`. Options that must match in every game are in coop_talk's
`SHARED_OPTS`. Enemies and bosses are run by one game (the nearest player's) and copied in the others
(coop_enemies: `moves_shared`, `puppetize`, `drive`, `check_handoffs`).

## Testing

- `pip install -r tools/requirements.txt`, then `python tools/check.py`. It must say "all checks passed".
  GitHub runs it on every pull request.
- A change to story, menu, giving, voice, light or plugin-status logic gets a scenario in the matching
  `tests/harness/*_test.py` (see the existing ones: each is a few lines of Lua driving two stand-in games).
- In the game: copy your `reframework/autorun/*.lua` into a co-op install made by `Install.cmd`
  (`Documents\RE7-coop\reframework\autorun`) and restart RE7. The co-op menu's developer tools have a test bot.
- The maintainer also runs a two-game bot suite and a story playthrough on their PC before releasing; say in the
  pull request what you couldn't test in the game.

## Rules for the game (each of these crashed RE7 or broke a save before)

- Never call `RigidBodyDestruct.setBreak` or `EPVExpertMuzzleFlush.play()`.
- Never attach a real weapon object to the friend's character (the ghost); it shows a copy.
- Never call `Inventory.addItem` on an item lying in the world, and never take items out of a player's inventory
  for the friend's use (three crashes in one evening, v0.48).
- Never load a save while the game is in an event (cutscene, scripted move).
- On an enemy, never switch on "all components": some start off on purpose and it broke the Molded.
- When exploring an unknown object, call only `get_*`/`is*` methods. No blind calls to methods with no arguments.
- Never replay the game's system-state sounds.
- A managed array may have no `get_elements` (about one read in 50, every read on the title screen): use the
  script's `arr_items()` / `elems()` helper, never `arr:get_elements()` directly.
- Every game call that can fail goes through `pcall`/`safe(...)`; nothing may throw out of an `on_frame`.

## Rules for the design (the project owner's)

- Everyone shares one game: one Molded and one boss for all players (run by the nearest player's game, able to
  hurt anyone), the same story, doors, puzzles and key items.
- Real cutscenes play for every player, in first person. Phone calls and scripted world interactions (fridge,
  pot, sheet metal) play on the player who does them; the others keep control, hear it, and it counts for all.
- A shared option must be in coop_talk's `SHARED_OPTS`, so changing it changes it for everyone.

## Rules for the repo

- No personal information anywhere: no SteamIDs, Steam names, Windows user names, e-mail addresses or real paths
  from someone's PC, in code, comments, tests or docs. Tests use made-up IDs like `76561198000000001`.
- No debug executors or research tools in `reframework/` (nothing that runs code sent from outside the game).
- Don't change the version (`const string Version` in CoopNet.cs, the README title) or write the CHANGELOG entry:
  the maintainer does that when releasing. Describe your change in the pull request instead.
- Work on a branch and open a pull request into `main`; never force-push `main`.

## Style

- Comments say why, with the version and the evidence, e.g. `-- v0.50 (bot playthrough): ... (c04e12_01 played
  before _00 in both games)`. The code's history lives in these comments and in docs/NOTES.md.
- Player-facing text (on screen, menus, README, changelog) is plain English for players, not programmers.
- Each script logs through its own `log()`; a line a bug report will need says what happened and why.
