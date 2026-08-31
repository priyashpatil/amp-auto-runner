# Amp Auto Runner

Amp Auto Runner is an unofficial native macOS desktop app for keeping local
Ampcode runners available across multiple projects. It is an independent
open-source project and is not affiliated with or endorsed by Ampcode.

> [!IMPORTANT]
> Runner management like this may eventually be provided by Ampcode's official
> desktop app. Amp Auto Runner is intended to remain an experimental project,
> not become an official product, and may be discontinued at any time.

<p align="center">
  <img src="https://cdn.priyashpatil.com/products/amp-auto-runner.png" alt="Amp Auto Runner dashboard preview">
</p>

Choose **Add Project** and select a folder. The app saves the project, creates
a stable runner ID, enables Auto Start, and launches its runner immediately.
It also discovers compatible runners that were started manually:

```sh
amp --no-tui --runner-id <project-runner-id> --remote-control-terminal
```

## Current features

- Native SwiftUI desktop dashboard
- One prioritized runner table with auto-start and active runners first
- Direct project-folder addition and removal
- Discovery of headless Ampcode runners started by this app or elsewhere
- Automatic migration of adopted terminal runners into the app
- Compact runner table with persisted project directories
- Editable hostname-safe runner IDs while runners are stopped
- Per-project Auto Start controls for app launch
- Compact start, stop, and remove controls for saved projects
- macOS Launch at Login control
- A single colored terminal view showing the real PTY stdout and stderr from
  all app-launched runners, including ANSI, 256-color, and true-color output
- Runner failure details in the dashboard

## Requirements

- macOS 14 or later
- Xcode 16 or later
- An authenticated Ampcode CLI installation

The app looks for `amp` on `PATH` and in the standard `~/.local/bin`,
Homebrew, and `/usr/local/bin` locations.

## Installation from source

Clone the repository and build a Release app with Xcode:

```sh
git clone https://github.com/priyashpatil/amp-auto-runner.git
cd amp-auto-runner

xcodebuild -project AmpAutoRunner.xcodeproj \
  -scheme AmpAutoRunner \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath build \
  build
```

Quit any existing copy, install the app for your macOS user, and launch it:

```sh
osascript -e 'tell application id "com.priyashpatil.AmpAutoRunner" to quit' \
  2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Amp Auto Runner.app"
ditto "build/Build/Products/Release/Amp Auto Runner.app" \
  "$HOME/Applications/Amp Auto Runner.app"
open "$HOME/Applications/Amp Auto Runner.app"
```

This replaces only the application bundle; saved projects and preferences are
preserved. For a system-wide installation, use `/Applications` instead of
`$HOME/Applications` (administrator permission may be required).

## Development

Open `AmpAutoRunner.xcodeproj` in Xcode, or build and test from the command
line:

```sh
xcodebuild -project AmpAutoRunner.xcodeproj \
  -scheme AmpAutoRunner \
  -destination 'platform=macOS' \
  test
```

The app is intentionally not sandboxed because each Ampcode runner needs to run
commands and modify files in its project directory. When an existing terminal
runner is adopted, Amp Auto Runner stops it and immediately restarts it under
app ownership because macOS cannot retroactively attach to another terminal's
output. Runners launched by the app use a pseudo-terminal so their original
colored output can be displayed directly. Saved stopped runners remain in the
runner table and can be resumed manually.

## License

[MIT](LICENSE)
