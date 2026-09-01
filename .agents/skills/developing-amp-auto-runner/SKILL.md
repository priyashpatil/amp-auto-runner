---
name: developing-amp-auto-runner
description: Safely builds, tests, and launches the Amp Auto Runner Debug app while a production copy is running. Use for local development, UI testing, Debug app restarts, or checking Debug and production process state.
---

# Developing Amp Auto Runner

Use the bundled `scripts/debug-app.sh` for every local build, test, launch, or
status check. It keeps all Debug products in the repository's canonical `build`
directory and never operates on the production bundle or bundle identifier.

## Safety boundary

- Treat `~/Applications/Amp Auto Runner.app` and
  `com.priyashpatil.AmpAutoRunner` as production. Never quit, replace, open,
  unregister, or delete them during development.
- Treat `build/Build/Products/Debug/Amp Auto Runner.app` and
  `com.priyashpatil.AmpAutoRunner.debug` as Debug-only.
- Do not build or launch Release unless the user explicitly requests a Release
  build. Normal development needs only Debug.
- Restarting Debug is allowed when the user asks to build and start/run the app.
  Never infer permission to restart production.
- After starting Debug, report both process paths so the distinction is visible.

## Commands

From the repository root:

```sh
.agents/skills/developing-amp-auto-runner/scripts/debug-app.sh build
.agents/skills/developing-amp-auto-runner/scripts/debug-app.sh test
.agents/skills/developing-amp-auto-runner/scripts/debug-app.sh run
.agents/skills/developing-amp-auto-runner/scripts/debug-app.sh status
```

`run` builds Debug, unregisters stale Debug build locations from Launch Services,
restarts only the Debug bundle, and verifies the production process was not
addressed. It does not delete build products.
