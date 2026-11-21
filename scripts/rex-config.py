#!/usr/bin/env python3
"""Install the Rex action module, validating edits with the user's Rex binary."""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

command, binary = sys.argv[1:3]
host_only = command.endswith("-host")
command = command.removesuffix("-host")
config = Path(os.environ.get("REX_CONFIG") or
              Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "rex/init.lua")
module = config.parent / "rexmote/init.lua"
source = Path(__file__).resolve().parents[1] / "lua/init.lua"
begin, end = "-- begin rexmote", "-- end rexmote"
marker = re.compile(r"(?ms)^" + begin + r"\n.*?^" + end + r"(?:\n|$)")
requires = re.compile(r"""(?m)^\s*require\s*\(?\s*["']rexmote["']""")
old_config = config.read_bytes() if config.exists() else None
old_module = module.read_bytes() if module.exists() else None
original = (old_config or b"").decode()
text = original
bundles = [base / (name + ".app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex")
           for base in (Path("/Applications"), Path.home() / "Applications")
           for name in ("Rex", "Rex Beta")]
rex = os.environ.get("REXMOTE_REX_BIN") or shutil.which("rex") or next((p for p in bundles if p.is_file()), None)
if not rex and host_only and command == "install":
    sys.exit(0)
if not rex and not host_only:
    sys.exit("Rex CLI missing. Install Rex or use ./install.sh --host-only.")

def write(path, data):
    if data is None:
        path.unlink(missing_ok=True)
        return
    if path.is_symlink():
        path = path.resolve()
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = path.stat().st_mode & 0o777 if path.exists() else 0o600
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as out:
        tmp = Path(out.name)
        try:
            out.write(data)
            out.flush()
            os.chmod(tmp, mode)
            os.replace(tmp, path)
        finally:
            tmp.unlink(missing_ok=True)

default = str(Path.home() / "Applications/Rexmote.app/Contents/MacOS/rexmote")
if command == "install":
    if not requires.search(text):
        options = "{}" if binary == default else "{ holder = " + json.dumps(str(Path(binary).parents[1] / "Resources/rexmote-pane"), ensure_ascii=False) + " }"
        entry = begin + '\nrequire("rexmote").setup' + options + "\n" + end + "\n"
        text = text + ("" if not text or text.endswith("\n") else "\n") + entry
    new_module = source.read_bytes()
elif command == "remove":
    text = marker.sub("", original)
    if requires.search(text):
        sys.exit("Remove the custom require for rexmote from " + str(config) + " before uninstalling.")
    new_module = None
    if old_module is not None and old_module != source.read_bytes():
        sys.exit("A customized rexmote module exists at " + str(module) + ". Move it before uninstalling.")
else:
    sys.exit("Expected install or remove.")

new_config = text.encode() if text or old_config is not None else None
changed = (new_config, new_module) != (old_config, old_module)
try:
    if changed:
        write(module, new_module)
        write(config, new_config)
    if rex:
        subprocess.run([rex, "config", "check", config], check=True)
    # Staging configurations may belong to a different Rex server.
    if rex and os.environ.get("REXMOTE_SKIP_RELOAD") != "1":
        subprocess.run([rex, "config", "reload"], check=True)
except (OSError, subprocess.CalledProcessError) as error:
    if changed:
        write(config, old_config)
        write(module, old_module)
    sys.exit(f"Rex configuration failed. Restored the previous configuration. {error}")

if command == "remove" and module.parent.is_dir() and not any(module.parent.iterdir()):
    module.parent.rmdir()
