#!/bin/zsh
set -euo pipefail

# One-shot, idempotent replacement for the locally installed Mac app.
# If launchd (or a user) invokes this more than once, an already-running app
# is treated as success and the script exits without opening another instance.

source_app='/tmp/CodeAnywhereLatestMacBuild/Build/Products/Release/CodeAnywhere Mac.app'
target_app='/Applications/CodeAnywhere Mac.app'
target_executable="$target_app/Contents/MacOS/CodeAnywhere Mac"
log_file='/tmp/codeanywhere-mac-replace-latest.log'
lock_dir='/tmp/codeanywhere-mac-replace-latest.lock'

exec >> "$log_file" 2>&1
print "replace_started=$(date '+%Y-%m-%d %H:%M:%S %z') pid=$$"

# Do not allow overlapping launchd/manual invocations.
if ! mkdir "$lock_dir" 2>/dev/null; then
    print 'another_replacement_is_running_or_already_finished'
    exit 0
fi
trap 'rmdir "$lock_dir" 2>/dev/null || true' EXIT

running_pids() {
    local -a pids
    pids=(${(f)$(pgrep -f -- "$target_executable" 2>/dev/null || true)})
    print -r -- "${pids[@]}"
}

if [[ ! -d "$source_app" ]]; then
    print "source_missing=$source_app"
    exit 2
fi

print 'resigning_latest_build'
codesign --force --deep --options runtime \
    --sign 'Developer ID Application: lei feng (SA4L8J8X2M)' "$source_app"
codesign --verify --deep --strict "$source_app"

print 'quitting_old_app'
osascript -e 'tell application "CodeAnywhere Mac" to quit' || true
for _ in {1..80}; do
    if [[ -z "$(running_pids)" ]]; then
        break
    fi
    sleep 0.25
done

if [[ -n "$(running_pids)" ]]; then
    print 'old_app_did_not_exit_gracefully; refusing to force-kill or relaunch'
    exit 3
fi

print 'replacing_app_bundle_without_backup'
rm -rf "$target_app"
ditto --rsrc --extattr "$source_app" "$target_app"
codesign --verify --deep --strict "$target_app"

print 'launching_replaced_app_once'
open "$target_app"
for _ in {1..80}; do
    if [[ -n "$(running_pids)" ]]; then
        print 'replaced_app_started'
        print "replace_finished=$(date '+%Y-%m-%d %H:%M:%S %z')"
        exit 0
    fi
    sleep 0.25
done

print 'replaced_app_did_not_start'
exit 4
