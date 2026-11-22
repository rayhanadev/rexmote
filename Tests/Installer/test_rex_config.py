import os
import plistlib
import runpy
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[2] / "scripts/rex-config.py"


class RexConfigurationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.config = self.root / "init.lua"
        self.module = self.root / "rexmote/init.lua"
        self.original = b"-- My Rex settings\n"
        self.config.write_bytes(self.original)

    def configure(self, action, rex="/usr/bin/true", agent=(), reload=False):
        args = [str(SCRIPT), action, str(self.root / "My Apps/Rexmote.app/Contents/MacOS/rexmote")]
        env = {"REX_CONFIG": str(self.config), "REXMOTE_REX_BIN": rex, "REXMOTE_SKIP_RELOAD": "0" if reload else "1"}
        with patch.dict(os.environ, env), patch.object(sys, "argv", args + list(agent)), \
                patch("shutil.which", return_value=None), patch.object(Path, "is_file", return_value=False):
            runpy.run_path(str(SCRIPT))

    def test_uninstall_without_rex_preserves_the_original_configuration(self):
        self.configure("install")
        first = self.config.read_bytes()
        self.configure("install")
        self.assertEqual(self.config.read_bytes(), first)
        self.assertEqual(first.count(b"-- begin rexmote"), 1)
        self.configure("remove", rex="")
        self.assertEqual(self.config.read_bytes(), self.original)
        self.assertFalse(self.module.exists())

    def test_updated_and_unrelated_modules_survive_reinstall_and_uninstall(self):
        self.configure("install")
        configured = self.config.read_bytes()
        module = self.module.read_bytes()
        for custom in [module + b"-- local change\n", b"return { personal = true }\n"]:
            self.module.write_bytes(custom)
            for action in ["install", "remove"]:
                with self.assertRaisesRegex(SystemExit, "customized rexmote module"):
                    self.configure(action)
                self.assertEqual(self.module.read_bytes(), custom)
                self.assertEqual(self.config.read_bytes(), configured)

    def test_legacy_module_upgrades_and_a_failed_validation_rolls_back(self):
        self.module.parent.mkdir()
        original = (SCRIPT.parents[1] / "lua/init.lua").read_bytes()
        self.module.write_bytes(original)
        with self.assertRaisesRegex(SystemExit, "Restored the previous configuration"):
            self.configure("install", rex="/usr/bin/false")
        self.assertEqual(self.module.read_bytes(), original)
        self.assertEqual(self.config.read_bytes(), self.original)
        self.configure("install")
        self.assertTrue(self.module.read_bytes().endswith(original))
        self.assertNotEqual(self.module.read_bytes(), original)

    def test_failed_agent_registration_restores_and_reloads_previous_rex_actions(self):
        reloads = []

        def execute(args, **kwargs):
            if str(args[1]).endswith("viewer-agent.py"):
                raise subprocess.CalledProcessError(1, args)
            if args[1:3] == ["config", "reload"]:
                reloads.append(self.config.read_bytes())
            return subprocess.CompletedProcess(args, 0)

        with patch("subprocess.run", side_effect=execute), self.assertRaisesRegex(SystemExit, "Restored"):
            self.configure("install", agent=("install", str(self.root)), reload=True)
        self.assertEqual(len(reloads), 2)
        self.assertIn(b"-- begin rexmote", reloads[0])
        self.assertEqual(reloads[1], self.original)
        self.assertEqual(self.config.read_bytes(), self.original)
        self.assertFalse(self.module.exists())

    def test_failed_launchctl_bootstrap_restores_the_previous_agent_plist(self):
        app = self.root / "Rexmote.app"
        script = SCRIPT.with_name("viewer-agent.py")
        plist = self.root / "Library/LaunchAgents/dev.rexmote.viewer.plist"
        plist.parent.mkdir(parents=True)
        custom = plistlib.dumps({"Label": "dev.rexmote.viewer", "KeepAlive": False,
                                 "ProgramArguments": [str(app / "Contents/MacOS/rexmote-viewer"), "--follow-rex"]})

        def launchctl(args, **kwargs):
            refused = args[1] == "bootstrap" or args[-1].endswith("/dev.rexmote.viewer")
            return subprocess.CompletedProcess(args, int(refused), stderr="bootstrap failed")

        for previous in [None, custom]:
            if previous is not None:
                plist.write_bytes(previous)
            with patch.object(Path, "home", return_value=self.root), patch.object(sys, "argv", [str(script), "install", str(app)]), \
                    patch("subprocess.run", side_effect=launchctl), patch("subprocess.check_output", return_value=""), \
                    patch("time.sleep"), self.assertRaisesRegex(SystemExit, "bootstrap failed"):
                runpy.run_path(str(script))
            self.assertEqual(plist.read_bytes() if plist.exists() else None, previous)


if __name__ == "__main__":
    unittest.main()
