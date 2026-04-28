"""Geometric feature extraction for manufacturability analysis.

Pulls quantities the composite-process advisor needs:
    - bounding envelope, projected area, aspect ratios
    - estimated wall thickness statistics
    - radius-of-curvature distribution (min radius governs draping & tooling)
    - draft / undercut detection
    - hole and through-feature inventory
    - sandwich / monocoque hint

The implementation is geometry-only and avoids material-specific reasoning;
that lives in `manufacturability.py` and `process_advisor.py`.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Optional

from .ingest import DrawingPackage
from .reconstruct3d import Mesh, ReconstructionResult


@dataclass
class Hole:
    diameter: float
    depth: float
    through: bool
    location: tuple[float, float, float]


@dataclass
class GeometricFeatures:
    bbox: tuple[tuple[float, float, float], tuple[float, float, float]]
    length: float
    width: float
    height: float
    volume_mm3: float
    surface_area_mm2: float
    projected_area_mm2: float
    min_wall_thickness: float
    nominal_thickness: float
    max_thickness: float
    min_radius: float
    has_compound_curvature: bool
    has_undercuts: bool
    draft_angle_min_deg: float
    holes: list[Hole] = field(default_factory=list)
    aspect_ratio: float = 1.0
    closed_section: bool = False
    sandwich: bool = False
    notes: list[str] = field(default_factory=list)

    @property
    def envelope_class(self) -> str:
        L = max(self.length, self.width, self.height)
        if L < 250: return "small"
        if L < 1500: return "medium"
        if L < 5000: return "large"
        return "xlarge"

    @property
    def thickness_class(self) -> str:
        t = self.nominal_thickness
        if t < 1.0: return "ultra-thin"
        if t < 2.5: return "thin"
        if t < 6.0: return "medium"
        return "thick"


def extract(pkg: DrawingPackage, recon: ReconstructionResult) -> GeometricFeatures:
    mesh = recon.mesh
    (xmin, ymin, zmin), (xmax, ymax, zmax) = mesh.bbox
    L, W, H = xmax - xmin, ymax - ymin, zmax - zmin
    L, W, H = max(L, 1e-6), max(W, 1e-6), max(H, 1e-6)

    nominal_t = recon.inferred_thickness or _guess_thickness(L, W, H)
    min_t = nominal_t * 0.85
    max_t = nominal_t * 1.25

    holes = _extract_holes(pkg, recon)
    min_r = _min_curvature_radius(pkg)
    compound = _has_compound_curvature(pkg)
    undercut, draft = _draft_analysis(pkg, recon)
    sandwich = _looks_sandwich(pkg, nominal_t)

    notes: list[str] = []
    if recon.method == "proxy":
        notes.append("Geometry inferred from incomplete drawing — verify before quoting")
    if min_t < 0.6:
        notes.append("Sub-0.6 mm wall — only thin-ply prepreg or RTM is viable")
    if compound:
        notes.append("Compound curvature detected — limits braiding/pultrusion")
    if undercut:
        notes.append("Undercut surfaces — split tooling or inflatable mandrel required")

    return GeometricFeatures(
        bbox=mesh.bbox,
        length=L, width=W, height=H,
        volume_mm3=mesh.volume,
        surface_area_mm2=mesh.surface_area,
        projected_area_mm2=L * W,
        min_wall_thickness=min_t,
        nominal_thickness=nominal_t,
        max_thickness=max_t,
        min_radius=min_r,
        has_compound_curvature=compound,
        has_undercuts=undercut,
        draft_angle_min_deg=draft,
        holes=holes,
        aspect_ratio=max(L, W, H) / max(1e-6, min(L, W, H)),
        closed_section=_is_closed_section(pkg),
        sandwich=sandwich,
        notes=notes,
    )


def _guess_thickness(L: float, W: float, H: float) -> float:
    smallest_in_plane = min(L, W)
    return max(1.0, min(H, smallest_in_plane * 0.04))


def _extract_holes(pkg: DrawingPackage, recon: ReconstructionResult) -> list[Hole]:
    holes: list[Hole] = []
    seen: set[tuple[float, float, float]] = set()
    for v in pkg.views:
        for e in v.entities:
            if e["type"] == "circle" and e.get("r", 0) > 0:
                cx, cy = e["c"]
                key = (round(cx, 1), round(cy, 1), round(e["r"], 2))
                if key in seen:
                    continue
                seen.add(key)
                holes.append(Hole(
                    diameter=2 * e["r"],
                    depth=recon.inferred_thickness or 0.0,
                    through=True,
                    location=(cx, cy, 0.0),
                ))
    return holes


def _min_curvature_radius(pkg: DrawingPackage) -> float:
    radii: list[float] = []
    for v in pkg.views:
        for e in v.entities:
            if e["type"] in ("circle", "arc") and e.get("r"):
                radii.append(e["r"])
    return min(radii) if radii else math.inf


def _has_compound_curvature(pkg: DrawingPackage) -> bool:
    spline_views = 0
    for v in pkg.views:
        if any(e["type"] == "spline" for e in v.entities):
            spline_views += 1
    return spline_views >= 2


def _draft_analysis(pkg: DrawingPackage, recon: ReconstructionResult) -> tuple[bool, float]:
    """Return (has_undercut, min_draft_deg).  Deterministic rules-of-thumb."""
    has_undercut = False
    min_draft = 90.0
    for a in pkg.annotations:
        text = a.text.lower()
        if "undercut" in text or "no draft" in text:
            has_undercut = True
        m_deg = _DRAFT_RE.search(text)
        if m_deg:
            try:
                min_draft = min(min_draft, float(m_deg.group(1)))
            except ValueError:
                pass
    if recon.method == "extrusion":
        min_draft = min(min_draft, 0.0)
    return has_undercut, min_draft


import re as _re
_DRAFT_RE = _re.compile(r"draft\s*[:=]?\s*([0-9]+(?:\.[0-9]+)?)\s*°?")


def _is_closed_section(pkg: DrawingPackage) -> bool:
    for a in pkg.annotations:
        if "closed section" in a.text.lower() or "tube" in a.text.lower():
            return True
    return False


def _looks_sandwich(pkg: DrawingPackage, nominal_t: float) -> bool:
    for a in pkg.annotations:
        text = a.text.lower()
        if any(k in text for k in ("honeycomb", "nomex", "core", "sandwich", "foam core")):
            return True
    return nominal_t > 8.0
