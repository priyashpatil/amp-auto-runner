# Amp Auto Runner

Amp Auto Runner is an unofficial native macOS desktop app for keeping local
Amp runners available across multiple projects. It is an independent
open-source project and is not affiliated with or endorsed by Amp.

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
- Discovery of headless Amp runners started by this app or elsewhere
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
- An authenticated Amp CLI installation

The app looks for `amp` on `PATH` and in the standard `~/.local/bin`,
Homebrew, and `/usr/local/bin` locations.

## Development

Open `AmpAutoRunner.xcodeproj` in Xcode, or build and test from the command
line:

```sh
xcodebuild -project AmpAutoRunner.xcodeproj \
  -scheme AmpAutoRunner \
  -destination 'platform=macOS' \
  test
```

The app is intentionally not sandboxed because each Amp runner needs to run
commands and modify files in its project directory. When an existing terminal
runner is adopted, Amp Auto Runner stops it and immediately restarts it under
app ownership because macOS cannot retroactively attach to another terminal's
output. Runners launched by the app use a pseudo-terminal so their original
colored output can be displayed directly. Saved stopped runners remain in the
runner table and can be resumed manually.

## License

[MIT](LICENSE)
