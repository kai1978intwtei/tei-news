"""Lightweight ASCII STEP (AP203/AP214/AP242) parser.

We do not attempt full B-Rep evaluation; instead we extract the
geometric primitives that are sufficient to drive the downstream
CF3D analysis:

    - all CARTESIAN_POINT coordinates → real bounding box
    - CIRCLE / CYLINDRICAL_SURFACE radii + axis points → hole inventory
    - B_SPLINE / NURBS hint → compound curvature flag

This works on the ASCII Part 21 form (the default for STP files) and
keeps zero third-party dependencies, so .stp imports succeed on a
fresh Python install — important for Windows shop-floor PCs that
cannot easily install cadquery / pythonocc.
"""
from __future__ import annotations

import logging
import re
from dataclasses import dataclass, field
from pathlib import Path

log = logging.getLogger(__name__)

_POINT_RE = re.compile(
    r"CARTESIAN_POINT\s*\(\s*'[^']*'\s*,\s*\(\s*"
    r"(-?\d+(?:\.\d+)?(?:E[+\-]?\d+)?)\s*,\s*"
    r"(-?\d+(?:\.\d+)?(?:E[+\-]?\d+)?)\s*,\s*"
    r"(-?\d+(?:\.\d+)?(?:E[+\-]?\d+)?)\s*\)\s*\)",
    re.IGNORECASE,
)
_CIRCLE_RE = re.compile(
    r"CIRCLE\s*\(\s*'[^']*'\s*,\s*#\d+\s*,\s*"
    r"(-?\d+(?:\.\d+)?(?:E[+\-]?\d+)?)\s*\)",
    re.IGNORECASE,
)
_CYL_RE = re.compile(
    r"CYLINDRICAL_SURFACE\s*\(\s*'[^']*'\s*,\s*#\d+\s*,\s*"
    r"(-?\d+(?:\.\d+)?(?:E[+\-]?\d+)?)\s*\)",
    re.IGNORECASE,
)
_BSPLINE_RE = re.compile(r"B_SPLINE_SURFACE", re.IGNORECASE)
_HEADER_NAME_RE = re.compile(r"FILE_NAME\s*\(\s*'([^']*)'", re.IGNORECASE)
_UNIT_RE = re.compile(
    r"\(SI_UNIT\(\s*\.?\w*\.?\s*,\s*\.(METRE|MILLI_METRE|INCH)\.\)\)",
    re.IGNORECASE,
)


@dataclass
class StepSummary:
    points: list[tuple[float, float, float]] = field(default_factory=list)
    circle_radii: list[float] = field(default_factory=list)
    cylinder_radii: list[float] = field(default_factory=list)
    has_bspline: bool = False
    units: str = "mm"
    file_name: str = ""

    @property
    def bbox(self) -> tuple[tuple[float, float, float],
                            tuple[float, float, float]]:
        if not self.points:
            return ((0.0, 0.0, 0.0), (0.0, 0.0, 0.0))
        xs = [p[0] for p in self.points]
        ys = [p[1] for p in self.points]
        zs = [p[2] for p in self.points]
        return ((min(xs), min(ys), min(zs)),
                (max(xs), max(ys), max(zs)))

    @property
    def min_radius(self) -> float:
        radii = [r for r in (self.circle_radii + self.cylinder_radii) if r > 0]
        return min(radii) if radii else float("inf")


def parse(path: str | Path) -> StepSummary:
    p = Path(path)
    text = _read_text(p)

    summary = StepSummary()
    m = _HEADER_NAME_RE.search(text)
    if m:
        summary.file_name = m.group(1)

    unit_match = _UNIT_RE.search(text)
    if unit_match:
        u = unit_match.group(1).upper()
        if u == "INCH":
            summary.units = "in"
        elif u == "METRE":
            summary.units = "m"
        else:
            summary.units = "mm"

    for match in _POINT_RE.finditer(text):
        try:
            summary.points.append((float(match.group(1)),
                                    float(match.group(2)),
                                    float(match.group(3))))
        except ValueError:
            continue

    for match in _CIRCLE_RE.finditer(text):
        try:
            summary.circle_radii.append(float(match.group(1)))
        except ValueError:
            pass
    for match in _CYL_RE.finditer(text):
        try:
            summary.cylinder_radii.append(float(match.group(1)))
        except ValueError:
            pass

    summary.has_bspline = bool(_BSPLINE_RE.search(text))

    if summary.units == "m":
        summary.points = [(x * 1000, y * 1000, z * 1000) for x, y, z in summary.points]
        summary.circle_radii = [r * 1000 for r in summary.circle_radii]
        summary.cylinder_radii = [r * 1000 for r in summary.cylinder_radii]
        summary.units = "mm"
    elif summary.units == "in":
        summary.points = [(x * 25.4, y * 25.4, z * 25.4) for x, y, z in summary.points]
        summary.circle_radii = [r * 25.4 for r in summary.circle_radii]
        summary.cylinder_radii = [r * 25.4 for r in summary.cylinder_radii]
        summary.units = "mm"

    log.info("STEP summary: %d pts, %d circles, %d cylinders, bspline=%s",
             len(summary.points), len(summary.circle_radii),
             len(summary.cylinder_radii), summary.has_bspline)
    return summary


def _read_text(path: Path) -> str:
    """STEP files are ASCII; tolerate Windows-1252 / Latin-1 stray bytes."""
    raw = path.read_bytes()
    for enc in ("utf-8", "latin-1", "cp1252"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", errors="ignore")
