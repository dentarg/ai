#!/bin/sh
# Hiding the host agent leaves the VM and its required display running.
set -eu
[ "${AI_VM_SHOW_DISPLAY:-0}" != 1 ] || exit 0
if ! vm_dir=$(limactl list "$1" --format '{{.Dir}}'); then
  echo 'at=warning msg="could not locate macOS VM display"' >&2
  exit 0
fi
echo 'at=info msg="hiding macOS VM display"' >&2
osascript -l JavaScript - "$vm_dir/ha.pid" <<'JXA' &
ObjC.import('AppKit');
ObjC.import('Foundation');
function run(args) {
    const contents = $.NSString.stringWithContentsOfFileEncodingError(
        args[0], $.NSUTF8StringEncoding, null);
    if (!contents) throw new Error('Host agent PID is unavailable');
    const pid = Number(ObjC.unwrap(contents).trim());
    if (!Number.isInteger(pid) || pid <= 0) throw new Error('Invalid host agent PID');
    const app = $.NSRunningApplication.runningApplicationWithProcessIdentifier(pid);
    if (app && (app.isHidden || app.hide)) return;
    // Some command-line applications cannot be hidden through AppKit.
    const processes = Application('System Events').applicationProcesses.whose({unixId: pid})();
    if (processes.length !== 1) throw new Error('VM display process is unavailable');
    processes[0].visible = false;
    if (processes[0].visible()) throw new Error('Could not hide the VM display');
}
JXA
hide_pid=$!
trap 'kill -KILL "$hide_pid" 2>/dev/null || true' 0
trap 'exit 1' HUP INT TERM
# Apple Events and permission dialogs can block indefinitely. This optional
# cosmetic step must not hold up provisioning or session startup.
elapsed=0
while kill -0 "$hide_pid" 2>/dev/null; do
  if [ "$elapsed" -ge 5 ]; then
    kill -KILL "$hide_pid" 2>/dev/null || true
    wait "$hide_pid" 2>/dev/null || true
    trap - 0
    echo 'at=warning msg="timed out hiding macOS VM display; continuing"' >&2
    exit 0
  fi
  sleep 1
  elapsed=$((elapsed + 1))
done
if ! wait "$hide_pid"; then
  echo 'at=warning msg="could not hide macOS VM display"' >&2
fi
trap - 0
