#!/usr/bin/env python3
"""Run the pane viewer in the viewing user's graphical login session."""
import os
import plistlib
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

operation, app = sys.argv[1:3]
if operation not in ("install", "remove", "update-host"):
    sys.exit("Expected install, remove or update-host.")
label = "dev.rexmote.viewer"
domain = f"gui/{os.getuid()}"
service = f"{domain}/{label}"
plist = Path.home() / "Library/LaunchAgents" / (label + ".plist")
viewer = Path(app) / "Contents/MacOS/rexmote-viewer"
ctl = "/bin/launchctl"

loaded = subprocess.run([ctl, "print", service], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
previous_plist = plist.read_bytes() if plist.exists() else None
if previous_plist is not None:
    old = plistlib.loads(previous_plist)
    if old.get("Label") != label or old.get("ProgramArguments") != [str(viewer), "--follow-rex"]:
        if operation == "update-host":
            sys.exit(0)
        sys.exit(f"Another launch agent owns {plist}")

if loaded and operation == "remove":
    subprocess.run([ctl, "bootout", service], check=True)
elif loaded and plist.exists():
    # The job keeps its registration while its executable is replaced. Holders can keep using it.
    subprocess.run([ctl, "kickstart", "-k", service], check=True)
    sys.exit(0)

# Replace only an earlier copy of this viewer. Its live holders re-register themselves.
paths = {str(viewer)}
if len(sys.argv) > 3 and sys.argv[3]:
    paths.add(str(Path(sys.argv[3]) / "Contents/MacOS/rexmote-viewer"))
for line in subprocess.check_output(["/bin/ps", "-U", str(os.getuid()), "-o", "pid=,comm="], text=True).splitlines():
    fields = line.strip().split(None, 1)
    if len(fields) == 2 and fields[1] in paths:
        try:
            os.kill(int(fields[0]), signal.SIGTERM)
        except ProcessLookupError:
            pass

if operation == "install":
    plist.parent.mkdir(parents=True, exist_ok=True)
    config = dict(Label=label, ProgramArguments=[str(viewer), "--follow-rex"], KeepAlive=True,
                  LimitLoadToSessionType="Aqua", ThrottleInterval=5)

    def write_plist(data):
        with tempfile.NamedTemporaryFile(dir=plist.parent, delete=False) as tmp:
            tmp.write(data)
        os.replace(tmp.name, plist)

    write_plist(plistlib.dumps(config))
    try:
        if subprocess.run([ctl, "print", domain], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
            for attempt in range(5):
                result = subprocess.run([ctl, "bootstrap", domain, str(plist)], capture_output=True, text=True)
                if result.returncode == 0:
                    break
                if attempt == 4:
                    raise RuntimeError(result.stderr.strip() or "Could not register the Rexmote viewer.")
                time.sleep(0.25)
        # Without a GUI session, launchd reads the plist at the next graphical login.
    except (OSError, RuntimeError) as error:
        if previous_plist is None:
            plist.unlink(missing_ok=True)
        else:
            write_plist(previous_plist)
        sys.exit(str(error))
elif operation == "remove":
    plist.unlink(missing_ok=True)
