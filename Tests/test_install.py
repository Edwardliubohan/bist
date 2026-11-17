"""Exercise installation failures without touching the user's Applications folder."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="bist install test ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.destination = self.root / "Applications with spaces"
        self.installed = self.destination / "bist.app"
        self.installed.mkdir(parents=True)
        (self.installed / "previous.txt").write_text("previous app")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        if (ROOT / "install.sh").is_file():
            shutil.copy2(ROOT / "install.sh", self.root / "install.sh")
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        INSTALL_TEST_LOG=str(self.root / "operations.log"))
        self.script(self.root / "build.sh", r'''
print build >> "$INSTALL_TEST_LOG"
[[ ${BUILD_FAIL:-0} != 1 ]] || exit 23
mkdir -p build/bist.app/Contents/MacOS
if [[ ${MISSING_EXECUTABLE:-0} != 1 ]]; then
    print '#!/bin/sh' > build/bist.app/Contents/MacOS/bist
    chmod +x build/bist.app/Contents/MacOS/bist
fi
cat > build/bist.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>bist</string>
</dict></plist>
PLIST
if [[ ${BAD_PLIST:-0} == 1 ]]; then
    print invalid > build/bist.app/Contents/Info.plist
fi
''')
        self.script(self.bin / "codesign", r'''
print verify >> "$INSTALL_TEST_LOG"
[[ ${BAD_SIGNATURE:-0} != 1 ]]
''')
        self.script(self.bin / "ditto", r'''
print copy >> "$INSTALL_TEST_LOG"
[[ ${COPY_FAIL:-0} != 1 ]] || exit 24
/usr/bin/ditto "$@"
''')
        self.script(self.bin / "open", r'''
print -r -- "open $*" >> "$INSTALL_TEST_LOG"
''')
        self.script(self.bin / "ps", r'''
[[ -z ${RUNNING_EXECUTABLE:-} ]] || print -r -- "$RUNNING_EXECUTABLE"
exit 0
''')
        self.script(self.bin / "mv", r'''
if [[ ${PUBLISH_FAIL:-0} == 1 && $1 == */.bist-install.*/bist.app ]]; then
    exit 25
fi
/bin/mv "$@"
''')

    def script(self, path, source):
        path.write_text("#!/bin/zsh\nset -eu\n" + source)
        path.chmod(0o755)

    def run_install(self, *args, **env):
        return subprocess.run(
            ["/bin/zsh", str(self.root / "install.sh"),
             "--destination", str(self.destination), *args],
            cwd="/", env=dict(self.env, **env), text=True, capture_output=True)

    def operations(self):
        log = self.root / "operations.log"
        return log.read_text().splitlines() if log.exists() else []

    def assert_previous_intact(self):
        self.assertEqual((self.installed / "previous.txt").read_text(), "previous app")
        self.assertEqual(list(self.destination.glob(".bist-install.*")), [])
        self.assertFalse(any(line.startswith("open ") for line in self.operations()))

    def test_build_failure_stops_before_copy(self):
        result = self.run_install(BUILD_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("build", self.operations())
        self.assertNotIn("copy", self.operations())
        self.assert_previous_intact()

    def test_missing_executable_stops_before_copy(self):
        result = self.run_install(MISSING_EXECUTABLE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("executable", result.stderr.lower())
        self.assertNotIn("copy", self.operations())
        self.assert_previous_intact()

    def test_invalid_plist_stops_before_copy(self):
        result = self.run_install(BAD_PLIST="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("build", self.operations())
        self.assertNotIn("copy", self.operations())
        self.assert_previous_intact()

    def test_bad_signature_stops_before_copy(self):
        result = self.run_install(BAD_SIGNATURE="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("verify", self.operations())
        self.assertNotIn("copy", self.operations())
        self.assert_previous_intact()

    def test_copy_failure_preserves_previous_app(self):
        result = self.run_install(COPY_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("copy", self.operations())
        self.assert_previous_intact()

    def test_publish_failure_restores_previous_app(self):
        result = self.run_install(PUBLISH_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("copy", self.operations())
        self.assert_previous_intact()

    def test_running_installed_app_is_left_alone(self):
        result = self.run_install(
            RUNNING_EXECUTABLE=str(self.installed / "Contents/MacOS/bist"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("quit", result.stderr.lower())
        self.assertNotIn("copy", self.operations())
        self.assert_previous_intact()

    def test_success_replaces_app_and_opens_installed_bundle(self):
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(os.access(self.installed / "Contents/MacOS/bist", os.X_OK))
        self.assertFalse((self.installed / "previous.txt").exists())
        self.assertEqual(self.operations()[-1], f"open {self.installed}")
        self.assertEqual(list(self.destination.glob(".bist-install.*")), [])

    def test_no_open_installs_without_launching(self):
        result = self.run_install("--no-open")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(os.access(self.installed / "Contents/MacOS/bist", os.X_OK))
        self.assertFalse(any(line.startswith("open ") for line in self.operations()))

    def test_fresh_install_creates_destination(self):
        shutil.rmtree(self.destination)
        result = self.run_install("--no-open")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(os.access(self.installed / "Contents/MacOS/bist", os.X_OK))


if __name__ == "__main__":
    unittest.main()
