#!/usr/bin/env python3
"""CI-only isolated fixtures: no builds, production services, or databases."""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SHA = "a" * 40


class CompatibleBinaryUpdateTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.install = self.base / "install"
        self.old = self.install / "releases" / "old"
        (self.old / "bin").mkdir(parents=True)
        (self.old / "frontend").mkdir()
        (self.old / "frontend/index.html").write_text("old frontend")
        self.executable(self.old / "bin/aether-gateway", "#!/bin/sh\nexit 0\n")
        (self.install / "current").symlink_to(self.old)
        self.fake = self.base / "fake"
        self.fake.mkdir()
        self.tools = self.base / "tools"
        self.tools.mkdir()
        for name in ["install-compatible-binary-update.sh", "rollback-compatible-binary-update.sh"]:
            text = (ROOT / ".cm" / name).read_text().replace(
                'export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"',
                'export PATH="' + str(self.fake) + ':/usr/bin:/bin"',
            )
            self.executable(self.tools / name, text)
        self.executable(self.fake / "id", "#!/bin/sh\necho 0\n")
        self.executable(self.fake / "sleep", "#!/bin/sh\nexit 0\n")
        self.executable(self.fake / "systemctl", """#!/bin/sh
printf '%s\n' "$*" >> "$FIXTURE/service.log"
case "$1" in
  stop) touch "$FIXTURE/stopped" ;;
  start) rm -f "$FIXTURE/stopped" ;;
  is-active) test ! -f "$FIXTURE/stopped" ;;
  show) echo 123 ;;
  *) exit 1 ;;
esac
""")
        self.executable(self.fake / "curl", """#!/bin/sh
test ! -f "$FIXTURE/stopped" || exit 1
case "$(readlink -f "$FIXTURE/install/current")" in
  */old) exit 0 ;;
  *) test ! -f "$FIXTURE/fail-new-health" ;;
esac
""")
        self.executable(self.fake / "sha256sum", """#!/bin/sh
case "$1" in
  /proc/*/exe) exec /usr/bin/sha256sum "$AETHER_VERIFIED_BINARY" ;;
  *) exec /usr/bin/sha256sum "$@" ;;
esac
""")
        self.binary = self.base / "verified-gateway"
        self.executable(self.binary, """#!/bin/sh
printf '%s\n' "$*" >> "$FIXTURE/binary.log"
test "$*" = 'db status' || exit 1
if test -f "$FIXTURE/pending"; then
  echo 'pending migrations: 1'
else
  echo 'pending migrations: 0'
fi
""")
        self.envfile = self.base / "production.env"
        self.envfile.write_text("APP_PORT=12345\n")
        self.env = dict(
            os.environ,
            FIXTURE=str(self.base),
            INSTALL_ROOT=str(self.install),
            AETHER_ENV_FILE=str(self.envfile),
            AETHER_UPDATE_STATE_ROOT=str(self.base / "state"),
            AETHER_INSTALL_LOCK=str(self.base / "install.lock"),
            AETHER_VERIFIED_BINARY=str(self.binary),
            AETHER_EXPECTED_BUILD_SHA=SHA,
            AETHER_EXPECTED_GATEWAY_SHA256=hashlib.sha256(self.binary.read_bytes()).hexdigest(),
        )

    @staticmethod
    def executable(path, text):
        path.write_text(text)
        path.chmod(0o755)

    def install_update(self):
        return subprocess.run(
            ["bash", str(self.tools / "install-compatible-binary-update.sh")],
            env=self.env, text=True, capture_output=True,
        )

    def test_success_and_manual_rollback_preserve_frontend_and_environment(self):
        before = self.envfile.read_bytes()
        result = self.install_update()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        new = (self.install / "current").resolve()
        self.assertNotEqual(new, self.old)
        self.assertEqual((new / "bin/aether-gateway").read_bytes(), self.binary.read_bytes())
        self.assertEqual((new / "frontend").resolve(), self.old / "frontend")
        self.assertEqual(self.envfile.read_bytes(), before)
        state = Path((self.base / "state/last-success").read_text().strip())
        self.assertEqual((state / "STATUS").read_text().strip(), "success")
        rollback = subprocess.run(["bash", str(state / "rollback.sh")], env=self.env, capture_output=True, text=True)
        self.assertEqual(rollback.returncode, 0, rollback.stdout + rollback.stderr)
        self.assertEqual((self.install / "current").resolve(), self.old)
        self.assertEqual((self.base / "binary.log").read_text().strip(), "db status")

    def test_unhealthy_new_service_rolls_back_automatically(self):
        (self.base / "fail-new-health").touch()
        result = self.install_update()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.install / "current").resolve(), self.old)
        self.assertFalse((self.base / "stopped").exists())
        state = next((self.base / "state").iterdir())
        self.assertEqual((state / "STATUS").read_text().strip(), "rolled_back")

    def test_pending_migration_aborts_before_stopping_service(self):
        (self.base / "pending").touch()
        result = self.install_update()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.install / "current").resolve(), self.old)
        self.assertNotIn("stop ", (self.base / "service.log").read_text())

    def test_wrong_digest_aborts_before_stopping_service(self):
        self.env["AETHER_EXPECTED_GATEWAY_SHA256"] = "0" * 64
        result = self.install_update()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.install / "current").resolve(), self.old)
        self.assertNotIn("stop ", (self.base / "service.log").read_text())


if __name__ == "__main__":
    unittest.main()
