#!/usr/bin/env python3
"""Shellcheck the ``run:`` blocks of a composite action.

actionlint extracts and shellchecks every ``run:`` block it finds, but it only
looks at workflows under ``.github/workflows``. A composite action's steps are
shell too, and in this repository they are the longer half of it, so without
this they are the one place shell can rot unchecked.

Each block is written out with the shebang its ``shell:`` implies and handed to
shellcheck, so what is checked is what GitHub will run.

$SHELLCHECK selects the checker, defaulting to a plain ``shellcheck`` on PATH.
CI sets it to the same digest-pinned container the .sh files go through, so one
linter judges every line of shell in the repository. That container mounts the
repository, which is why the extracted blocks are written inside it rather than
into /tmp: a path the checker cannot see is a check that silently passes.

Usage: shellcheck-composite.py <action.yml> [<action.yml> ...]
"""

import os
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

SHEBANGS = {
    "bash": "#!/usr/bin/env bash",
    "sh": "#!/bin/sh",
}


def _steps(document):
    """Yield (name, shell, script) for every run step of a composite action."""
    runs = document.get("runs") or {}

    if runs.get("using") != "composite":
        return

    for index, step in enumerate(runs.get("steps") or []):
        if "run" not in step:
            continue

        yield (step.get("name") or f"step {index}", step.get("shell", "bash"),
               step["run"])


def check(path):
    try:
        with open(path, encoding="utf-8") as handle:
            document = yaml.safe_load(handle)
    except (OSError, yaml.YAMLError) as exc:
        print(f"FAIL {path}: {exc}", file=sys.stderr)
        return False

    ok = True
    checked = 0

    for name, shell, script in _steps(document):
        shebang = SHEBANGS.get(shell)

        # A shell shellcheck cannot reason about is reported rather than
        # skipped: silently passing over it is how a block stops being checked
        # without anyone deciding that it should.
        if shebang is None:
            print(f"FAIL {path}: {name!r} uses unsupported shell {shell!r}",
                  file=sys.stderr)
            ok = False
            continue

        checker = shlex.split(os.environ.get("SHELLCHECK", "shellcheck"))

        # Prefixed rather than anonymous: this repository has no .gitignore, so
        # anything a killed run leaves behind should name itself in git status
        # rather than look like a source directory.
        with tempfile.TemporaryDirectory(dir=".", prefix=".shellcheck-tmp-") as tmp:
            script_path = Path(tmp) / "step.sh"
            script_path.write_text(f"{shebang}\n{script}", encoding="utf-8")
            # Relative, so it resolves the same inside a container that mounted
            # this directory as it does on a plain PATH lookup.
            result = subprocess.run(checker + [os.path.relpath(script_path)],
                                    capture_output=True, text=True,
                                    check=False)

        checked += 1

        if result.returncode != 0:
            print(f"FAIL {path}: {name}", file=sys.stderr)
            print(result.stdout.replace(str(script_path), name),
                  file=sys.stderr)
            ok = False

    if ok:
        print(f"ok   {path} ({checked} run block(s))")

    return ok


def main(paths):
    if not paths:
        print(__doc__, file=sys.stderr)
        return 2

    return 0 if all([check(path) for path in paths]) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
