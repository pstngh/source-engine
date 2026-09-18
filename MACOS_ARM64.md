# Counter-Strike: Source on Apple Silicon

The repository's only GitHub Actions workflow builds the `cstrike` client and
server for macOS on Apple Silicon. It verifies that every generated Mach-O file
is arm64-only and uploads a permission-preserving `.tar.gz` build artifact.

## GitHub Actions

Open the repository's **Actions** tab, select **Counter-Strike Source - macOS
arm64**, and choose **Run workflow**. The workflow also runs on every push and
pull request. Download the
`counter-strike-source-macos-arm64-<commit>.tar.gz` artifact after the build
finishes.

## Local build

Run the build on an Apple Silicon Mac with Homebrew installed:

```sh
bash scripts/build-macos-arm64-cstrike.sh
```

The result is installed to `out/cstrike-macos-arm64` by default. Set
`BUILD_PREFIX` to choose a different output directory.

## Running a downloaded build

GitHub Actions artifacts are not signed with an Apple Developer ID or notarized,
so Gatekeeper may quarantine them after download. After extracting an artifact
you built and trust, run:

```sh
cd /path/to/cstrike-macos-arm64
xattr -dr com.apple.quarantine .
./launch-cstrike.command
```

The launcher now resolves `bin/launcher.dylib` relative to its own location, so
it also works when invoked by an absolute path or from Finder. The included
`launch-cstrike.command` wrapper supplies `-game cstrike` automatically.

The build bundles the Homebrew libraries it uses, rewrites every packaged
Mach-O dependency to a relative path, and applies an ad-hoc signature after
relocation. This includes SDL3, which Homebrew's SDL2 compatibility library
loads dynamically. The launcher wrapper exposes the private runtime-library
directory before starting the game. The artifact does not depend on paths from
the GitHub Actions build machine or require Homebrew on the destination Mac.

The artifact contains engine and game-code binaries only. It does not include
Valve's copyrighted Counter-Strike: Source game assets. A legally owned game
installation is still required.

## Custom gameplay defaults

This branch enables the following server-controlled settings by default:

- `sv_infinite_money 1` keeps each player's balance at the normal $16,000 cap.
- `sv_infinite_ammo 1` prevents firearms and grenades from consuming ammo.
- `weapon_no_spread 1` removes bullet inaccuracy and spread.
- `weapon_recoil_scale 0.35` reduces weapon view recoil to 35% of stock.
- `sv_damage_kickback 0` disables the stock view punch caused by taking damage.

Set the first three variables to `0` in the server console to restore their
original behavior. Set `weapon_recoil_scale` to `1` for stock recoil or `0` for
no recoil, and set `sv_damage_kickback` to `1` to restore damage view punch.

Mouse-wheel weapon cycling selects the highlighted weapon immediately. The
`+leanleft` and `+leanright` commands use OpenMoHAA's Allied Assault multiplayer
lean angle, timing, camera pivot, roll, and collision dimensions. For example:

```text
bind z +leanleft
bind c +leanright
```

## Local practice modes

Games created from the menu start in free-for-all mode by default, with automatic
respawning and no freeze time. On a local/listen server, open the developer
console and use:

- `sv_cheats 1; god` to toggle working invulnerability for the host player.
- `tdm` to start team deathmatch with automatic respawning.
- `ffa` to start free-for-all; all other players and bots become enemies.
- `classic` to restore the normal team and round rules.

TDM and FFA respawn players after 1.5 seconds and keep the round running. Change
the delay with `mp_deathmatch_respawn_time`, for example
`mp_deathmatch_respawn_time 0.5`. Add bots with `bot_quota 9`, or use
`bot_quota_mode fill; bot_quota 10` to keep ten total players in the session.
