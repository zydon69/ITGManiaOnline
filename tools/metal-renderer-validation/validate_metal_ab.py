#!/usr/bin/env python3
"""Run a small OpenGL vs Metal visual validation pass for macOS ITGmania.

This is intentionally conservative:
- preferences are backed up and restored;
- each renderer is launched separately;
- screenshots, stdout, a copy of log.txt, and a markdown summary are written;
- pixel comparison is optional and only used when Pillow is installed.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time
from typing import Dict, List, Optional


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_APP = REPO_ROOT / "ITGmania.app" / "Contents" / "MacOS" / "ITGmania"
DEFAULT_PREFS = (
    Path.home()
    / "Library"
    / "Application Support"
    / "ITGmania"
    / "Save"
    / "Preferences.ini"
)
DEFAULT_LOG = (
    Path.home()
    / "Library"
    / "Application Support"
    / "ITGmania"
    / "Logs"
    / "log.txt"
)

BAD_LOG_PATTERNS = [
    re.compile(pattern, re.IGNORECASE)
    for pattern in [
        r"\bcrash\b",
        r"\berror\b(?![.\w/-]*\.ogg)(?!\s*=\s*0\b)",
        r"pipeline unavailable",
        r"shader compilation",
        r"\bfailed\b(?!\s*=\s*0\b)",
        r"EXC_",
        r"Unknown video renderer",
    ]
]

RENDERER_PREFS = {
    "opengl": {
        "VideoRenderers": "opengl",
        "MacOSPresentBackend": "opengl",
    },
    "metal": {
        "VideoRenderers": "metal,opengl",
        "MacOSPresentBackend": "opengl",
    },
}


def set_pref(text: str, key: str, value: str) -> str:
    replacement = f"{key}={value}"
    if re.search(rf"^{re.escape(key)}=.*$", text, flags=re.MULTILINE):
        return re.sub(
            rf"^{re.escape(key)}=.*$",
            replacement,
            text,
            flags=re.MULTILINE,
        )
    suffix = "" if text.endswith("\n") else "\n"
    return f"{text}{suffix}{replacement}\n"


def write_renderer_prefs(pref_path: Path, renderer: str) -> None:
    text = pref_path.read_text(encoding="utf-8", errors="replace")
    for key, value in RENDERER_PREFS[renderer].items():
        text = set_pref(text, key, value)
    pref_path.write_text(text, encoding="utf-8")


def run_command(args: List[str], timeout: int = 20) -> subprocess.CompletedProcess:
    return subprocess.run(
        args,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=timeout,
        check=False,
    )


def capture_screen(path: Path) -> Dict[str, object]:
    if sys.platform != "darwin":
        return {"ok": False, "reason": "screencapture is macOS-only"}
    result = run_command(["screencapture", "-x", str(path)], timeout=20)
    return {
        "ok": result.returncode == 0 and path.exists() and path.stat().st_size > 0,
        "returncode": result.returncode,
        "output": result.stdout.strip(),
    }


def launch_renderer(
    app_path: Path,
    pref_path: Path,
    log_path: Path,
    output_dir: Path,
    renderer: str,
    wait_seconds: float,
    screenshot: bool,
) -> Dict[str, object]:
    run_dir = output_dir / renderer
    run_dir.mkdir(parents=True, exist_ok=True)
    write_renderer_prefs(pref_path, renderer)

    stdout_path = run_dir / "stdout.txt"
    screenshot_path = run_dir / "screen.png"
    with stdout_path.open("w", encoding="utf-8") as stdout:
        process = subprocess.Popen(
            [str(app_path)],
            cwd=str(REPO_ROOT),
            stdout=stdout,
            stderr=subprocess.STDOUT,
        )

    time.sleep(wait_seconds)

    capture_result: Optional[Dict[str, object]] = None
    if screenshot:
        capture_result = capture_screen(screenshot_path)

    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)

    log_copy_path = run_dir / "log.txt"
    if log_path.exists():
        shutil.copy2(log_path, log_copy_path)

    stdout_text = stdout_path.read_text(encoding="utf-8", errors="replace")
    log_text = log_copy_path.read_text(encoding="utf-8", errors="replace") if log_copy_path.exists() else ""
    combined = f"{stdout_text}\n{log_text}"
    bad_lines = [
        line
        for line in combined.splitlines()
        if any(pattern.search(line) for pattern in BAD_LOG_PATTERNS)
        and "MemoryCardManager error.ogg" not in line
        and " error=0" not in line
    ]
    metal_initialized = "RageDisplay_Metal initialized" in combined
    renderer_seen = (
        metal_initialized
        if renderer == "metal"
        else "OGL Renderer:" in combined and not metal_initialized
    )

    expected_shutdown_codes = (0, -signal.SIGTERM)
    automated_ok = (
        process.returncode in expected_shutdown_codes
        and renderer_seen
        and (renderer != "metal" or metal_initialized)
        and not bad_lines
        and (
            not screenshot
            or (
                capture_result is not None
                and bool(capture_result.get("ok"))
            )
        )
    )

    return {
        "renderer": renderer,
        "exit_code": process.returncode,
        "stdout": str(stdout_path),
        "log": str(log_copy_path) if log_copy_path.exists() else None,
        "screenshot": str(screenshot_path) if screenshot_path.exists() else None,
        "capture": capture_result,
        "renderer_seen": renderer_seen,
        "metal_initialized": metal_initialized,
        "bad_line_count": len(bad_lines),
        "bad_lines": bad_lines[:40],
        "automated_ok": automated_ok,
    }


def compare_images(opengl_png: Path, metal_png: Path) -> Dict[str, object]:
    try:
        from PIL import Image, ImageChops, ImageStat  # type: ignore
    except Exception as exc:  # pragma: no cover - optional dependency.
        return {"available": False, "reason": f"Pillow unavailable: {exc}"}

    if not opengl_png.exists() or not metal_png.exists():
        return {"available": True, "ok": False, "reason": "missing screenshot"}

    with Image.open(opengl_png).convert("RGBA") as a, Image.open(metal_png).convert("RGBA") as b:
        if a.size != b.size:
            return {"available": True, "ok": False, "reason": f"size mismatch {a.size} vs {b.size}"}
        diff = ImageChops.difference(a, b)
        stat = ImageStat.Stat(diff)
        mean = sum(stat.mean) / len(stat.mean)
        extrema = diff.getextrema()
        changed = 0
        for pixel in diff.getdata():
            if pixel != (0, 0, 0, 0):
                changed += 1
        total = a.size[0] * a.size[1]
        return {
            "available": True,
            "ok": True,
            "mean_abs_channel_delta": mean,
            "changed_pixel_pct": (changed / total) * 100.0 if total else 0.0,
            "extrema": extrema,
        }


def write_summary(output_dir: Path, results: Dict[str, object]) -> None:
    summary_json = output_dir / "summary.json"
    summary_json.write_text(
        json.dumps(results, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )

    lines = [
        "# Metal Phase 8 A/B Validation",
        "",
        f"- Generated: {time.strftime('%Y-%m-%d %H:%M:%S')}",
        f"- Output: `{output_dir}`",
        "",
        "## Automated Smoke Results",
        "",
    ]
    for renderer, result in results["runs"].items():
        lines.extend(
            [
                f"### {renderer}",
                f"- Exit code: `{result['exit_code']}`",
                f"- Renderer marker seen: `{result['renderer_seen']}`",
                f"- Metal initialized: `{result['metal_initialized']}`",
                f"- Bad log lines: `{result['bad_line_count']}`",
                f"- Automated smoke gate: `{result['automated_ok']}`",
                f"- Screenshot: `{result['screenshot']}`",
                "",
            ]
        )
        if result["bad_lines"]:
            lines.append("First bad lines:")
            for line in result["bad_lines"][:10]:
                lines.append(f"- `{line}`")
            lines.append("")

    lines.extend(
        [
            "## Image Comparison",
            "",
            f"```json\n{json.dumps(results['image_compare'], indent=2, ensure_ascii=False)}\n```",
            "",
            "## Manual Phase 8 Checklist",
            "",
            "- [ ] Title/menu visual parity",
            "- [ ] Song Select left pane, banners, jackets, score panels",
            "- [ ] Song Select preview music/video behavior",
            "- [ ] Gameplay noteskins, receptors, holds, mines, judgments, combo",
            "- [ ] Dense chart gameplay",
            "- [ ] BGA/video chart gameplay",
            "- [ ] Failed chart flow",
            "- [ ] Evaluation screen panes and screenshot animation",
            "- [ ] Render-to-texture visual styles / ActorFrameTexture",
            "- [ ] One 3D/background/model scene",
            "- [ ] Fullscreen and windowed visual parity",
            "",
        ]
    )
    (output_dir / "summary.md").write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=DEFAULT_APP)
    parser.add_argument("--prefs", type=Path, default=DEFAULT_PREFS)
    parser.add_argument("--log", type=Path, default=DEFAULT_LOG)
    parser.add_argument("--output", type=Path, default=REPO_ROOT / "MetalValidation")
    parser.add_argument("--wait", type=float, default=8.0)
    parser.add_argument("--no-screenshot", action="store_true")
    args = parser.parse_args()

    if not args.app.exists():
        print(f"App binary not found: {args.app}", file=sys.stderr)
        return 2
    if not args.prefs.exists():
        print(f"Preferences not found: {args.prefs}", file=sys.stderr)
        return 2

    stamp = time.strftime("%Y%m%d-%H%M%S")
    output_dir = args.output / stamp
    output_dir.mkdir(parents=True, exist_ok=True)

    pref_backup = output_dir / "Preferences.ini.before"
    shutil.copy2(args.prefs, pref_backup)

    results: Dict[str, object] = {"runs": {}, "image_compare": {}}
    try:
        for renderer in ("opengl", "metal"):
            results["runs"][renderer] = launch_renderer(
                args.app,
                args.prefs,
                args.log,
                output_dir,
                renderer,
                args.wait,
                not args.no_screenshot,
            )
        if not args.no_screenshot:
            results["image_compare"] = compare_images(
                output_dir / "opengl" / "screen.png",
                output_dir / "metal" / "screen.png",
            )
    finally:
        shutil.copy2(pref_backup, args.prefs)

    write_summary(output_dir, results)
    print(output_dir)
    runs_ok = all(
        bool(result.get("automated_ok"))
        for result in results["runs"].values()
    )
    image_compare = results["image_compare"]
    images_ok = (
        args.no_screenshot
        or not bool(image_compare.get("available"))
        or bool(image_compare.get("ok"))
    )
    return 0 if runs_ok and images_ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
