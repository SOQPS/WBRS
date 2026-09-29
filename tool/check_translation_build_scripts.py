"""Exercise build-script argv without running Flutter or modifying the checkout."""
from pathlib import Path
import json
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="clrs-build-script-") as temporary:
    directory = Path(temporary)
    binary = directory / "flutter"
    binary.write_text("#!/usr/bin/env python3\nimport json,os,sys\n"
                      "with open(os.environ['CLRS_TEST_ARGV'], 'a') as log: "
                      "log.write(json.dumps(sys.argv[1:])+'\\n')\n")
    binary.chmod(0o755)
    for name in ("BUILD_APK.command", "build_android_release.sh"):
        script = directory / name
        script.write_bytes((root / name).read_bytes())
        for endpoint in ("", "https://example.invalid/translate?region=eu&mode=text"):
            log = directory / "argv.jsonl"
            log.write_text("")
            environment = dict(os.environ, PATH=f"{directory}:{os.environ['PATH']}",
                               CLRS_TEST_ARGV=str(log), CLRS_TRANSLATION_ENDPOINT=endpoint)
            result = subprocess.run(["bash", str(script)], env=environment,
                                    capture_output=True, text=True, timeout=20)
            assert result.returncode == 0, f"{name}: build wrapper failed"
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            expected = ["build", "apk", "--release", "--flavor", "production"]
            if endpoint:
                expected.append(f"--dart-define=CLRS_TRANSLATION_ENDPOINT={endpoint}")
            assert calls == [["pub", "get"], expected], f"{name}: incorrect argv"
            print(f"PASS: {name}, endpoint {'configured' if endpoint else 'absent'}")
