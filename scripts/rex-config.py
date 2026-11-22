#!/usr/bin/env python3
"""Update Rex actions and the viewer agent together, rolling back failed changes."""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

command, binary, *agent_args = sys.argv[1:]
host_only = command.endswith("-host")
command = command.removesuffix("-host")
config = Path(os.environ.get("REX_CONFIG") or
              Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "rex/init.lua")
module = config.parent / "rexmote/init.lua"
source = Path(__file__).resolve().parents[1] / "lua/init.lua"
begin, end = "-- begin rexmote", "-- end rexmote"
marker = re.compile(r"(?ms)^" + begin + r"\n.*?^" + end + r"(?:\n|$)")
requires = re.compile(r"""(?m)^\s*require\s*\(?\s*["']rexmote["']""")
bundles = [base / (name + ".app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex")
           for base in (Path("/Applications"), Path.home() / "Applications")
           for name in ("Rex", "Rex Beta")]
rex = os.environ.get("REXMOTE_REX_BIN") or shutil.which("rex") or next((p for p in bundles if p.is_file()), None)


def update_agent():
    if agent_args:
        subprocess.run([sys.executable, Path(__file__).with_name("viewer-agent.py"), *agent_args], check=True)


if not rex and host_only and command == "install":
    update_agent()
    sys.exit(0)
if not rex and not host_only and command == "install":
    sys.exit("Rex CLI missing. Install Rex or use ./install.sh --host-only.")

def write(path, data):
    if path.is_symlink():
        path = path.resolve()
    if data is None:
        path.unlink(missing_ok=True)
        return
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

def managed_module(body):
    digest = hashlib.sha256(body).hexdigest().encode()
    return b"-- Installed by Rexmote. Content SHA-256: " + digest + b"\n" + body


upstream = source.read_bytes()
if module.is_symlink():
    sys.exit(f"A symlink owns {module}. Move it before changing the Rexmote installation.")
old_config = config.read_bytes() if config.exists() else None
old_module = module.read_bytes() if module.exists() else None
original = (old_config or b"").decode()
text = original
if old_module is not None:
    _, _, body = old_module.partition(b"\n")
    # 0.7.0–0.7.2 installed this upstream module without an ownership header.
    original_release = "765fcd57f67dc51e488b0fdd99a5b313b32d8d325ec0701a27696885c447a526"
    known = old_module == upstream or hashlib.sha256(old_module).hexdigest() == original_release
    if not known and old_module != managed_module(body):
        sys.exit(f"A customized rexmote module exists at {module}. Move it before changing the installation.")

default = str(Path.home() / "Applications/Rexmote.app/Contents/MacOS/rexmote")
if command == "install":
    if not requires.search(text):
        options = "{}" if binary == default else "{ holder = " + json.dumps(str(Path(binary).parents[1] / "Resources/rexmote-pane"), ensure_ascii=False) + " }"
        entry = begin + '\nrequire("rexmote").setup' + options + "\n" + end + "\n"
        text = text + ("" if not text or text.endswith("\n") else "\n") + entry
    new_module = managed_module(upstream)
elif command == "remove":
    text = marker.sub("", original)
    if requires.search(text):
        sys.exit("Remove the custom require for rexmote from " + str(config) + " before uninstalling.")
    new_module = None
else:
    sys.exit("Expected install or remove.")

new_config = text.encode() if text or old_config is not None else None
changed = (new_config, new_module) != (old_config, old_module)
reload_attempted = False
try:
    if changed:
        write(module, new_module)
        write(config, new_config)
    validate = rex and (command == "install" or changed) and config.exists()
    if validate:
        subprocess.run([rex, "config", "check", config], check=True)
    # Staging configurations may belong to a different Rex server.
    if validate and os.environ.get("REXMOTE_SKIP_RELOAD") != "1":
        reload_attempted = True
        subprocess.run([rex, "config", "reload"], check=True)
    update_agent()
except (OSError, subprocess.CalledProcessError) as error:
    if changed:
        write(config, old_config)
        write(module, old_module)
        if reload_attempted:
            subprocess.run([rex, "config", "reload"], check=False)
    sys.exit(f"Rexmote setup failed. Restored the previous configuration. {error}")

if command == "remove" and module.parent.is_dir() and not any(module.parent.iterdir()):
    module.parent.rmdir()
