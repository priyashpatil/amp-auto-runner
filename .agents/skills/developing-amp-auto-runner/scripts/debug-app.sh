#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
DERIVED_DATA="$ROOT/build"
DEBUG_APP="$DERIVED_DATA/Build/Products/Debug/Amp Auto Runner.app"
DEBUG_BUNDLE_ID="com.priyashpatil.AmpAutoRunner.debug"
DEBUG_EXECUTABLE="$DEBUG_APP/Contents/MacOS/Amp Auto Runner"
PRODUCTION_EXECUTABLE="$HOME/Applications/Amp Auto Runner.app/Contents/MacOS/Amp Auto Runner"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"

build() {
    xcodebuild \
        -project "$ROOT/AmpAutoRunner.xcodeproj" \
        -scheme AmpAutoRunner \
        -configuration Debug \
        -destination 'platform=macOS' \
        -derivedDataPath "$DERIVED_DATA" \
        ENABLE_USER_SCRIPT_SANDBOXING=NO \
        build
}

test_debug() {
    xcodebuild \
        -project "$ROOT/AmpAutoRunner.xcodeproj" \
        -scheme AmpAutoRunner \
        -destination 'platform=macOS' \
        -derivedDataPath "$DERIVED_DATA" \
        ENABLE_USER_SCRIPT_SANDBOXING=NO \
        test
}

unregister_stale_debug_apps() {
    while IFS= read -r app; do
        [[ -n "$app" && "$app" != "$DEBUG_APP" ]] || continue
        "$LSREGISTER" -u "$app" 2>/dev/null || true
    done < <(mdfind "kMDItemCFBundleIdentifier == '$DEBUG_BUNDLE_ID'" 2>/dev/null || true)
}

status() {
    printf '%s\n' 'Production:'
    pgrep -afil "^${PRODUCTION_EXECUTABLE}$" || printf '%s\n' 'not running'
    printf '%s\n' 'Debug:'
    pgrep -afil "^${DEBUG_EXECUTABLE}$" || printf '%s\n' 'not running'
}

run_debug() {
    build

    actual_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEBUG_APP/Contents/Info.plist")"
    if [[ "$actual_bundle_id" != "$DEBUG_BUNDLE_ID" ]]; then
        printf 'Refusing to launch unexpected bundle ID: %s\n' "$actual_bundle_id" >&2
        exit 1
    fi

    unregister_stale_debug_apps

    if pgrep -f "^${DEBUG_EXECUTABLE}$" >/dev/null; then
        osascript -e "tell application id \"$DEBUG_BUNDLE_ID\" to quit" 2>/dev/null || true
        for _ in {1..30}; do
            pgrep -f "^${DEBUG_EXECUTABLE}$" >/dev/null || break
            sleep 0.2
        done
    fi

    open -na "$DEBUG_APP"
    sleep 2
    status
}

case "${1:-}" in
    build) build ;;
    test) test_debug ;;
    run) run_debug ;;
    status) status ;;
    *)
        printf 'Usage: %s {build|test|run|status}\n' "$0" >&2
        exit 2
        ;;
esac
