#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Build the public tests with ASan/UBSan and rerun the differential corpus.

The Goose compiler emits C; this script wraps the C compiler so every generated
translation unit and link gets `-fsanitize=address,undefined`, then runs the
contract tests and the full oracle corpus against the instrumented binaries.
The wrapper records the exact compiler command lines it executed.
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FLAGS = ["-O1", "-g", "-fno-omit-frame-pointer", "-fsanitize=address,undefined", "-UNDEBUG"]


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inputs(goose: Path, compiler: Path) -> dict:
    files = [ROOT / "msgpack.goose", ROOT / "tests" / "api.goose",
             ROOT / "tests" / "oracle.goose", ROOT / "tests" / "oracle.py",
             ROOT / "examples" / "plan.goose", ROOT / "GOOSE_REVISION"]
    return {
        "goose": {"path": str(goose), "sha256": sha256(goose)},
        "cc": {"path": str(compiler), "sha256": sha256(compiler)},
        "source": {str(p.relative_to(ROOT)): sha256(p) for p in files},
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--goose", type=Path, required=True)
    parser.add_argument("--cc", default="gcc")
    parser.add_argument("--cases", type=int, default=100000)
    parser.add_argument("--output", type=Path, default=ROOT / ".build" / "sanitize.json")
    args = parser.parse_args()

    found = shutil.which(args.cc)
    if found is None:
        parser.error(f"C compiler not found: {args.cc}")
    goose = args.goose.resolve(strict=True)
    compiler = Path(found).resolve(strict=True)
    frozen = inputs(goose, compiler)

    folder = ROOT / ".build" / "sanitize"
    folder.mkdir(parents=True, exist_ok=True)
    invocation = Path(tempfile.mkdtemp(prefix=compiler.name + "-", dir=folder))
    wrapper = invocation / "cc"
    transcript = invocation / "compiler-commands.jsonl"
    wrapper.write_text(
        "#!/usr/bin/env python3\n"
        "import json, os, sys\n"
        f"compiler = {str(compiler)!r}\n"
        f"log = {str(transcript)!r}\n"
        f"flags = {FLAGS!r}\n"
        "args = sys.argv[1:]\n"
        "probe = any(a in args for a in ('-v', '--version', '-dumpversion', '-dumpmachine'))\n"
        "link = not probe and not any(a in args for a in ('-c', '-E', '-S'))\n"
        "effective = [compiler, *args, *([] if probe else flags), *(['-no-pie'] if link else [])]\n"
        "with open(log, 'a') as f:\n"
        "    f.write(json.dumps(effective) + '\\n')\n"
        "os.execv(compiler, effective)\n"
    )
    wrapper.chmod(0o755)

    env = dict(os.environ,
               ASAN_OPTIONS="detect_leaks=1:abort_on_error=1",
               UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1")
    records: list[dict] = []
    binaries: dict[str, dict] = {}

    def execute(command) -> str:
        proc = subprocess.run([str(c) for c in command], cwd=ROOT, env=env,
                              capture_output=True, text=True, timeout=1800)
        records.append({"command": [str(c) for c in command],
                        "returncode": proc.returncode,
                        "stdout": proc.stdout, "stderr": proc.stderr})
        if proc.returncode or proc.stderr:
            raise RuntimeError(
                f"sanitizer run failed: {command!r}: exit={proc.returncode}, "
                f"stdout={proc.stdout[-2000:]!r}, stderr={proc.stderr[-4000:]!r}")
        return proc.stdout

    for name, source, debug in [("api", "api", False), ("api-debug", "api", True),
                                ("oracle", "oracle", False)]:
        binary = invocation / name
        execute([goose, "build", f"tests/{source}.goose", "--standalone",
                 *(["--debug"] if debug else []), "--cc", wrapper, "-o", binary])
        binaries[name] = {"path": str(binary), "sha256": sha256(binary)}

    execute([binaries["api"]["path"]])
    execute([binaries["api-debug"]["path"]])
    oracle_record = invocation / "oracle.json"
    execute([sys.executable, "tests/oracle.py", "--binary", binaries["oracle"]["path"],
             "--cases", str(args.cases), "--output", oracle_record])

    if inputs(goose, compiler) != frozen:
        raise RuntimeError("source or tools changed during execution; results rejected")
    if any(sha256(Path(v["path"])) != v["sha256"] for v in binaries.values()):
        raise RuntimeError("instrumented executable changed; results rejected")

    commands = [json.loads(line) for line in transcript.read_text().splitlines()]
    targets = {v["path"] for v in binaries.values()}
    links = [c for c in commands if "-o" in c and c.index("-o") + 1 < len(c)
             and c[c.index("-o") + 1] in targets]
    if {c[c.index("-o") + 1] for c in links} != targets:
        raise RuntimeError("not every instrumented binary has a recorded link command")
    if any(c[-len(FLAGS) - 1:-1] != FLAGS for c in links):
        raise RuntimeError("a link command lacks the sanitizer flags")

    result = {
        "recorded_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "inputs": frozen,
        "platform": platform.platform(),
        "compiler_commands": commands,
        "compiler_commands_sha256": sha256(transcript),
        "binaries": binaries,
        "executions": records,
        "oracle": json.loads(oracle_record.read_text()),
        "notes": [
            "Instrumented the generated Goose/runtime C; installed system libraries are not rebuilt",
            "The differential corpus is a finite seeded campaign, not coverage-guided fuzzing",
        ],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(f"msgpack sanitizer: contract tests and {result['oracle']['cases']} oracle cases "
          f"passed under ASan/UBSan ({args.cc})")
    print(f"msgpack sanitizer results: {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
