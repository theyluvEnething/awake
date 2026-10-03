#!/bin/bash
# Installs awake: builds it, puts Awake.app in ~/Applications, starts it at login through launchd
# and adds its Codex hooks. Re-running updates everything in place. The sudo parts live in
# mac-setup's scripts/admin.sh.
#   ./install.sh              install or update
#   ./install.sh --uninstall  remove what this script installed
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
app="$HOME/Applications/Awake.app"
bin="$app/Contents/MacOS/awake"
agents="$HOME/Library/LaunchAgents"
domain="gui/$(id -u)"
labels=(toybox.awake toybox.awake.reconcile)

# Adds or removes awake's entries in ~/.codex/hooks.json and leaves every other hook alone.
# Codex asks to trust a hook again when its definition or position changes, so an existing
# awake entry is replaced where it stands and the command string never changes.
codex_hooks() {
  /usr/bin/python3 - "$1" "$bin" <<'EOF'
import json, pathlib, shlex, sys

mode, binary = sys.argv[1], sys.argv[2]
path = pathlib.Path.home() / ".codex/hooks.json"
q = shlex.quote(binary)
handler = {"type": "command", "command": f"[ -x {q} ] && exec {q} hook codex; exit 0"}
wanted = {} if mode == "uninstall" else {
    "UserPromptSubmit": {"hooks": [{**handler, "async": True}]},
    "PreToolUse": {"matcher": "*", "hooks": [{**handler, "async": True}]},
    "PostToolUse": {"matcher": "*", "hooks": [{**handler, "async": True}]},
    "Stop": {"hooks": [{**handler, "async": True}]},
    "Interrupt": {"hooks": [{**handler, "async": True}]},
    # Codex always runs SessionEnd synchronously and warns about "async" there.
    "SessionEnd": {"hooks": [handler]},
}

def ours(group):
    return any("Awake.app/Contents/MacOS/awake" in h.get("command", "") for h in group.get("hooks", []))

doc = json.loads(path.read_text()) if path.exists() else {}
hooks = doc.setdefault("hooks", {})
for event in sorted(set(hooks) | set(wanted)):
    groups = hooks.get(event, [])
    at = next((i for i, g in enumerate(groups) if ours(g)), len(groups))
    groups = [g for g in groups if not ours(g)]
    if event in wanted:
        groups.insert(at, wanted[event])
    if groups:
        hooks[event] = groups
    else:
        hooks.pop(event, None)

if not hooks and len(doc) == 1:
    path.unlink(missing_ok=True)
else:
    text = json.dumps(doc, indent=2) + "\n"
    if not path.exists() or path.read_text() != text:
        path.write_text(text)
EOF
}

stop_agents() {
  for label in "${labels[@]}"; do
    launchctl bootout "$domain/$label" 2>/dev/null || true
  done
}

if [ "${1:-}" = "--uninstall" ]; then
  # Off first: the switch goes back to 0 and an energy mode awake changed comes back.
  if [ -x "$bin" ]; then "$bin" set off >/dev/null || true; fi
  stop_agents
  for label in "${labels[@]}"; do rm -f "$agents/$label.plist"; done
  codex_hooks uninstall
  rm -rf "$app" "$HOME/Library/Application Support/awake" "$HOME/Library/Logs/awake.log"
  echo "Removed Awake.app, its login items, its state and log, and its Codex hooks."
  echo "The root parts stay until you run mac-setup's scripts/admin.sh again; without Awake.app it"
  echo "drops awake's Claude hooks, /etc/sudoers.d/awake and the boot-time reset. By hand instead:"
  echo "  sudo rm /etc/sudoers.d/awake"
  echo "  sudo launchctl bootout system/toybox.awake.reset; sudo rm /Library/LaunchDaemons/toybox.awake.reset.plist"
  exit 0
fi

swift build -c release --package-path "$here" --scratch-path "$here/build"
built="$(swift build -c release --package-path "$here" --scratch-path "$here/build" --show-bin-path)/awake"

# Assemble and sign next to the old bundle, then swap, so a hook firing meanwhile either finds
# the complete old app, the complete new one, or no binary (and exits quietly).
new="$app.new"
rm -rf "$new" "$app.old"
mkdir -p "$new/Contents/MacOS"
cp "$built" "$new/Contents/MacOS/awake"
cat > "$new/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>     <string>awake</string>
    <key>CFBundleIdentifier</key>     <string>toybox.awake</string>
    <key>CFBundleName</key>           <string>Awake</string>
    <key>CFBundlePackageType</key>    <string>APPL</string>
    <key>LSMinimumSystemVersion</key> <string>26.0</string>
    <key>LSUIElement</key>            <true/>
</dict>
</plist>
EOF
codesign --force --sign - "$new"
stop_agents
if [ -d "$app" ]; then mv "$app" "$app.old"; fi
mv "$new" "$app"
rm -rf "$app.old"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"

# The menu starts at login and comes back only after a crash; Quit stays quit. The reconcile
# runs every 30 seconds for the guards and expiry, with or without the menu.
mkdir -p "$agents"
cat > "$agents/toybox.awake.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>                  <string>toybox.awake</string>
    <key>ProgramArguments</key>       <array><string>$bin</string></array>
    <key>RunAtLoad</key>              <true/>
    <key>KeepAlive</key>              <dict><key>SuccessfulExit</key><false/></dict>
    <key>LimitLoadToSessionType</key> <string>Aqua</string>
    <key>ProcessType</key>            <string>Interactive</string>
</dict>
</plist>
EOF
cat > "$agents/toybox.awake.reconcile.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>                  <string>toybox.awake.reconcile</string>
    <key>ProgramArguments</key>       <array><string>$bin</string><string>reconcile</string></array>
    <key>StartInterval</key>          <integer>30</integer>
    <key>RunAtLoad</key>              <true/>
    <key>LimitLoadToSessionType</key> <string>Aqua</string>
    <key>ProcessType</key>            <string>Background</string>
</dict>
</plist>
EOF
for label in "${labels[@]}"; do
  # A service that was just booted out can take a moment to go away.
  for attempt in 1 2 3 4 5; do
    launchctl bootstrap "$domain" "$agents/$label.plist" 2>/dev/null && break
    [ "$attempt" = 5 ] && { echo "launchctl bootstrap $label failed" >&2; exit 1; }
    sleep 1
  done
done

codex_hooks install
echo "Installed $app. The cup in the menu bar shows what closing the lid does."
