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

The artifact contains engine and game-code binaries only. It does not include
Valve's copyrighted Counter-Strike: Source game assets. A legally owned game
installation is still required, along with the Homebrew runtime libraries
installed by the script.
