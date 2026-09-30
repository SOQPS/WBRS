"""Synthetic media-copy guards; no S3, Timeweb API or user files are touched."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


HERE = Path(__file__).resolve().parent


def write(path: Path, content: str, mode: int = 0o600) -> None:
    path.write_text(content)
    path.chmod(mode)


class MediaPrivacyTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="clrs-media-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.calls = self.root / "calls.txt"
        self.backup_env = self.root / "media-backup.env"
        self.restore_env = self.root / "media-restore.env"
        common = (
            "AWS_ACCESS_KEY_ID=synthetic-access\n"
            "AWS_SECRET_ACCESS_KEY=synthetic-secret\n"
            "AWS_DEFAULT_REGION=ru-1\n"
            "S3_ENDPOINT=https://s3.twcstorage.ru/\n"
            "TIMEWEB_API_TOKEN=synthetic-token\n"
            "MEDIA_S3_BUCKET=private-media\n"
            "BACKUP_S3_BUCKET=private-backup\n"
            "BACKUP_MEDIA_PREFIX=media/current\n"
        )
        write(self.backup_env, common + "BACKUP_S3_BUCKET_ID=17\n")
        write(self.restore_env, common + "RESTORE_S3_BUCKET_ID=18\n")
        write(self.bin / "node", """#!/usr/bin/env bash
set -euo pipefail
[[ $1 == */check-private-media-bucket.mjs ]]
printf 'privacy %s %s\\n' "$2" "$3" >> "$FAKE_CALLS"
[[ ${FAKE_PRIVACY_FAIL:-0} != 1 ]]
""", 0o755)
        write(self.bin / "aws", """#!/usr/bin/env bash
set -euo pipefail
if [[ " $* " == *' get-bucket-versioning '* ]]; then
  printf '%s\\n' Enabled
elif [[ " $* " == *' list-objects-v2 '* ]]; then
  printf '%s\\n' 0
elif [[ " $* " == *' s3 sync '* ]]; then
  printf '%s\\n' sync >> "$FAKE_CALLS"
else
  exit 2
fi
""", 0o755)
        self.env = dict(os.environ,
                        PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        CLRS_MEDIA_BACKUP_ENV_FILE=str(self.backup_env),
                        CLRS_MEDIA_RESTORE_ENV_FILE=str(self.restore_env),
                        FAKE_CALLS=str(self.calls))

    def run_script(self, name: str, *args: str, fail_privacy=False):
        env = dict(self.env, FAKE_PRIVACY_FAIL="1" if fail_privacy else "0")
        return subprocess.run(["bash", str(HERE / name), *args], env=env,
                              capture_output=True, text=True, timeout=10,
                              check=False)

    def test_backup_checks_destination_before_and_after_copy(self) -> None:
        blocked = self.run_script("backup-media.sh", "--execute", fail_privacy=True)
        self.assertNotEqual(blocked.returncode, 0)
        self.assertEqual(self.calls.read_text().splitlines(), ["privacy private-backup 17"])
        self.assertNotIn("synthetic-secret", blocked.stdout + blocked.stderr)

        self.calls.unlink()
        copied = self.run_script("backup-media.sh", "--execute")
        self.assertEqual(copied.returncode, 0, copied.stderr)
        self.assertEqual(self.calls.read_text().splitlines(),
                         ["privacy private-backup 17", "sync", "privacy private-backup 17"])

    def test_restore_checks_test_bucket_before_and_after_copy(self) -> None:
        blocked = self.run_script("restore-media.sh", "--target-bucket",
                                  "clrs-restore-test", "--execute", "--confirm-target",
                                  "clrs-restore-test", fail_privacy=True)
        self.assertNotEqual(blocked.returncode, 0)
        self.assertEqual(self.calls.read_text().splitlines(),
                         ["privacy clrs-restore-test 18"])

        self.calls.unlink()
        copied = self.run_script("restore-media.sh", "--target-bucket",
                                 "clrs-restore-test", "--execute", "--confirm-target",
                                 "clrs-restore-test")
        self.assertEqual(copied.returncode, 0, copied.stderr)
        self.assertEqual(self.calls.read_text().splitlines(),
                         ["privacy clrs-restore-test 18", "sync",
                          "privacy clrs-restore-test 18"])


if __name__ == "__main__":
    unittest.main()
