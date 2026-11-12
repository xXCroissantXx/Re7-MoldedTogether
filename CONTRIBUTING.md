# Contributing to Molded Together

Thanks for helping. The short version: work on a branch, run the checks, open a pull request.

## Setup

1. Have Resident Evil 7 on Steam and install the mod once with **Install.cmd** (see the README). That gives you a
   co-op copy of the game in `Documents\RE7-coop` with REFramework.
2. Clone this repo (or your fork) and install the test tools (Python 3.12):

   ```
   pip install -r tools/requirements.txt
   ```

If you code with Claude (Claude Code), open it in this folder: it reads `CLAUDE.md`, which has the project's
rules. Please read that file yourself too; the "Rules for the game" list is how earlier builds crashed RE7.

## Making a change

1. Create a branch: `git checkout -b short-name-for-the-change`.
2. Change the scripts in `reframework/autorun/` (or the plugin in `reframework/plugins/source/`).
3. Run the checks: `python tools/check.py` must say "all checks passed". If you changed story, menu, giving,
   voice, flashlight or plugin-status logic, add a scenario to the matching file in `tests/harness/`.
4. Try it in the game: copy your scripts into `Documents\RE7-coop\reframework\autorun`, start the game, and use
   the co-op menu's developer tools (the test bot) or a friend.
5. Open a pull request into `main`. Say what you changed, why, and what you tested in the game. GitHub runs the
   checks on it automatically.

The maintainer reviews it, runs the two-game bot tests on their PC, and puts it in the next release. Please don't
change the version number or write the CHANGELOG entry: that's done at release time.

## Never

- Put personal information in the repo: SteamIDs, Steam names, Windows user names, e-mail addresses, or paths
  from your PC. Bug-report zips blank these out; logs you paste into an issue may not.
- Add tools that run code sent from outside the game.
