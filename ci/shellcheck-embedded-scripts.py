"""Run shellcheck on every step `script:` embedded in the Task manifests.

Two rules on top of shellcheck:
  * a script must not contain $(params.*) -- params go through env: so a value coming from a
    webhook cannot inject shell code;
  * the remaining Tekton variables ($(workspaces.*), $(results.*)) are replaced by a plain
    path so shellcheck can parse the script.
"""
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

failed = False
for manifest in sorted(Path(sys.argv[1]).glob("*.y*ml")):
    for doc in yaml.safe_load_all(manifest.read_text()):
        if not doc or doc.get("kind") != "Task":
            continue
        for step in doc["spec"].get("steps", []):
            script = step.get("script")
            if not script:
                continue
            label = f"{manifest}: step {step['name']}"
            if "$(params." in script:
                print(f"FAIL {label}: $(params.*) inside script; pass it through env")
                failed = True
            body = re.sub(r"\$\((workspaces|results)\.[A-Za-z0-9_.-]+\)", "/tekton/placeholder", script)
            with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as handle:
                handle.write(body)
            shell = "bash" if body.startswith("#!/bin/bash") else "sh"
            result = subprocess.run(["shellcheck", "-s", shell, handle.name],
                                    capture_output=True, text=True)
            Path(handle.name).unlink()
            if result.returncode != 0:
                print(f"FAIL {label}\n{result.stdout}")
                failed = True
            else:
                print(f"ok   {label}")
sys.exit(1 if failed else 0)
