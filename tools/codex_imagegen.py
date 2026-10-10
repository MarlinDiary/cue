#!/usr/bin/env python3
"""Generate images with Codex CLI's built-in $imagegen skill.

It runs one `codex exec` per image, several in parallel. Codex uses your ChatGPT login,
so no API key is needed, but it spends that plan's usage. Use the OpenAI API for bulk runs.

    python3 tools/codex_imagegen.py jobs.json out_dir [--parallel 4]

jobs.json is a list of {"name": "file-stem", "prompt": "what to draw and in which style"}.
"""
import argparse
import concurrent.futures
import json
import pathlib
import shutil
import subprocess
import time

CODEX = shutil.which("codex", path="/opt/homebrew/bin") or "codex"

TEMPLATE = (
    "Use $imagegen to generate exactly one image, then stop. Use the highest quality available. "
    "Square image, PNG with a fully transparent background, the subject centered with nothing touching the edges, "
    "no text or letters anywhere. {prompt} "
    "Save the final file as ./{name}.png in the current directory and do not create any other files."
)


def generate(job: dict, out: pathlib.Path) -> tuple[str, bool, float]:
    start = time.time()
    subprocess.run(
        [CODEX, "exec", "--skip-git-repo-check", "--sandbox", "workspace-write", "-C", str(out), TEMPLATE.format(**job)],
        stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=1200,
    )
    return job["name"], (out / f"{job['name']}.png").exists(), time.time() - start


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("jobs")
    parser.add_argument("out")
    parser.add_argument("--parallel", type=int, default=4)
    args = parser.parse_args()

    jobs = json.loads(pathlib.Path(args.jobs).read_text())
    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    with concurrent.futures.ThreadPoolExecutor(args.parallel) as pool:
        for name, ok, seconds in pool.map(lambda job: generate(job, out), jobs):
            print(f"{'ok  ' if ok else 'FAIL'} {name} ({seconds:.0f}s)", flush=True)


if __name__ == "__main__":
    main()
