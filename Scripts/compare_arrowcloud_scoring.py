#!/usr/bin/env python3
"""Compare local Simply Love ArrowCloud scoring against the Arrow Cloud theme.

This does not execute theme Lua directly because both themes depend on the
ITGmania runtime.  Instead it reads the scoring constants from each theme and
applies the same deterministic fixtures to both implementations.
"""

from __future__ import annotations

import argparse
import math
import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


DEFAULT_LOCAL_THEME = Path("Themes/Simply Love")
DEFAULT_ARROW_THEME = Path(
    os.environ.get("ARROW_CLOUD_THEME", "../Arrow Cloud Theme")
)

HARD_EX_KEYS = ("W010", "W110", "W2", "W3", "W4", "W5", "Miss", "Held", "LetGo", "HitMine")


@dataclass(frozen=True)
class ThemeScoring:
    name: str
    root: Path
    hardex_weights: dict[str, float]
    w010_window_ms: float


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def parse_lua_number_table(source: str, table_name: str) -> dict[str, float]:
    table_match = re.search(rf"{re.escape(table_name)}\s*=\s*\{{(?P<body>.*?)\n\s*\}}", source, re.S)
    if not table_match:
        raise ValueError(f"Could not find Lua table {table_name}")

    values: dict[str, float] = {}
    for key, value in re.findall(r"([A-Za-z0-9_]+)\s*=\s*(-?\d+(?:\.\d+)?)", table_match.group("body")):
        values[key] = float(value)
    return values


def parse_w010_window_ms(source: str) -> float:
    function_match = re.search(r"IsW010Judgment\s*=\s*function\(.*?\nend", source, re.S)
    if not function_match:
        raise ValueError("Could not find IsW010Judgment")

    # Arrow Cloud currently names this local W0, our port names it W010.
    window_match = re.search(
        r"local\s+W(?:0|010)\s*=\s*(\d+(?:\.\d+)?)\s*\*\s*scale\s*\+",
        function_match.group(0),
    )
    if not window_match:
        raise ValueError("Could not find IsW010Judgment timing expression")
    return float(window_match.group(1)) * 1000.0


def load_theme(name: str, root: Path) -> ThemeScoring:
    scripts = root / "Scripts"
    init_source = read_text(scripts / "SL_Init.lua")
    helpers_source = read_text(scripts / "SL-Helpers.lua")
    return ThemeScoring(
        name=name,
        root=root,
        hardex_weights=parse_lua_number_table(init_source, "HardExWeights"),
        w010_window_ms=parse_w010_window_ms(helpers_source),
    )


def hardex_from_counts(theme: ThemeScoring, counts: dict[str, float], total_steps: int, total_holds: int = 0, total_rolls: int = 0) -> float:
    max_points = total_steps * theme.hardex_weights["W010"] + (total_holds + total_rolls) * theme.hardex_weights["Held"]
    if max_points <= 0:
        return 0.0

    points = 0.0
    for key in HARD_EX_KEYS:
        points += counts.get(key, 0.0) * theme.hardex_weights.get(key, 0.0)

    if "Holds" in counts or "Rolls" in counts:
        points += (counts.get("Holds", 0.0) + counts.get("Rolls", 0.0)) * theme.hardex_weights["Held"]
    if "Mines" in counts:
        points += counts.get("Mines", 0.0) * theme.hardex_weights["HitMine"]

    return max(0.0, math.floor(points / max_points * 10000.0) / 100.0)


def counts_from_offsets(theme: ThemeScoring, offsets_ms: Iterable[float], holds: int = 0, rolls: int = 0, mines: int = 0) -> dict[str, float]:
    counts = {key: 0.0 for key in HARD_EX_KEYS}
    for offset in offsets_ms:
        offset = abs(float(offset))
        if offset <= theme.w010_window_ms:
            counts["W010"] += 1
        elif offset <= 23.0:
            counts["W110"] += 1
        elif offset <= 44.5:
            counts["W2"] += 1
        elif offset <= 103.5:
            counts["W3"] += 1
        elif offset <= 136.5:
            counts["W4"] += 1
        elif offset <= 181.5:
            counts["W5"] += 1
        else:
            counts["Miss"] += 1

    counts["Held"] = holds + rolls
    counts["HitMine"] = mines
    return counts


def compare_value(label: str, left: float, right: float, tolerance: float = 0.0001) -> bool:
    ok = abs(left - right) <= tolerance
    status = "OK" if ok else "DIFF"
    print(f"{status:4} {label:<34} local={left:8.3f} arrow={right:8.3f}")
    return ok


def main() -> int:
    parser = argparse.ArgumentParser(description="Compare local and Arrow Cloud H.EX scoring.")
    parser.add_argument("--local-theme", type=Path, default=DEFAULT_LOCAL_THEME)
    parser.add_argument("--arrow-theme", type=Path, default=DEFAULT_ARROW_THEME)
    args = parser.parse_args()

    local = load_theme("local", args.local_theme)
    arrow = load_theme("arrow", args.arrow_theme)

    print("Theme inputs")
    print(f"  local: {local.root}")
    print(f"  arrow: {arrow.root}")
    print()

    passed = True
    for key in HARD_EX_KEYS:
        passed &= compare_value(f"HardExWeights.{key}", local.hardex_weights.get(key, 0.0), arrow.hardex_weights.get(key, 0.0))
    passed &= compare_value("IsW010Judgment window ms", local.w010_window_ms, arrow.w010_window_ms)
    print()

    count_fixtures = [
        ("all inner fantastic", dict(W010=100), 100, 0, 0),
        ("white fantastic mix", dict(W010=80, W110=20), 100, 0, 0),
        ("mixed taps", dict(W010=50, W110=20, W2=15, W3=10, W4=3, W5=1, Miss=1), 100, 0, 0),
        ("holds rolls mines", dict(W010=90, W110=5, W2=5, Held=12, HitMine=2), 100, 8, 4),
        ("radar style counts", dict(W010=90, W110=5, W2=5, Holds=8, Rolls=4, Mines=2), 100, 8, 4),
    ]
    for label, counts, total_steps, total_holds, total_rolls in count_fixtures:
        passed &= compare_value(
            f"counts: {label}",
            hardex_from_counts(local, counts, total_steps, total_holds, total_rolls),
            hardex_from_counts(arrow, counts, total_steps, total_holds, total_rolls),
        )
    print()

    offset_fixtures = [
        ("boundary inner", [0, 5, 8.4, 8.6, 9.9, 10.0, 10.1, 22.9, 23.1]),
        ("full spread", [1, 7, 12, 18, 28, 43, 60, 100, 120, 160, 190]),
        ("excellent chart", [3, 6, 9, 14, 20, 22, 30, 39, 43, 80]),
    ]
    for label, offsets in offset_fixtures:
        local_counts = counts_from_offsets(local, offsets)
        arrow_counts = counts_from_offsets(arrow, offsets)
        passed &= compare_value(
            f"offsets: {label}",
            hardex_from_counts(local, local_counts, len(offsets)),
            hardex_from_counts(arrow, arrow_counts, len(offsets)),
        )

    print()
    print("PASS" if passed else "FAIL")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
