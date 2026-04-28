"""Design-for-manufacturability scoring against a process envelope.

Each rule emits a structured Finding with a numeric impact (-1 .. +1) so
the process advisor can rank candidates deterministically.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable

from .data.process_kb import ProcessEnvelope
from .geometry import GeometricFeatures


@dataclass
class Finding:
    rule: str
    severity: str            # "info" | "warn" | "block"
    impact: float            # -1.0 (blocks) .. +1.0 (boost)
    message: str


def evaluate(geom: GeometricFeatures,
             process: ProcessEnvelope,
             *,
             annual_volume: int = 100,
             quality_grade: str = "A",
             ) -> list[Finding]:
    out: list[Finding] = []

    longest = max(geom.length, geom.width, geom.height)
    if longest > process.max_part_length_mm:
        out.append(Finding("size.too_large", "block", -1.0,
                           f"{longest:.0f} mm exceeds {process.name} envelope "
                           f"({process.max_part_length_mm:.0f} mm)"))
    elif longest > 0.7 * process.max_part_length_mm:
        out.append(Finding("size.near_limit", "warn", -0.2,
                           "Part within 30% of process size limit"))

    t = geom.nominal_thickness
    if t < process.min_thickness_mm:
        out.append(Finding("thickness.too_thin", "block", -1.0,
                           f"Thickness {t:.2f} mm below {process.name} minimum "
                           f"{process.min_thickness_mm} mm"))
    elif t > process.max_thickness_mm:
        out.append(Finding("thickness.too_thick", "block", -1.0,
                           f"Thickness {t:.2f} mm above {process.name} maximum "
                           f"{process.max_thickness_mm} mm"))

    if geom.min_radius < process.min_radius_mm:
        out.append(Finding("radius.too_tight", "warn", -0.4,
                           f"Min radius {geom.min_radius:.1f} mm tighter than "
                           f"{process.name} can drape ({process.min_radius_mm} mm)"))

    if geom.has_compound_curvature and not process.compound_curvature_ok:
        out.append(Finding("compound_curvature.unsupported", "block", -1.0,
                           f"{process.name} cannot form compound curvature"))

    if geom.closed_section and not process.closed_section_ok:
        out.append(Finding("closed_section.unsupported", "block", -0.9,
                           f"{process.name} cannot form a closed section"))

    if geom.has_undercuts and not process.undercut_ok:
        out.append(Finding("undercut.unsupported", "warn", -0.5,
                           "Undercut requires split tooling or inflatable mandrel"))

    if annual_volume < process.typical_volume_low:
        out.append(Finding("volume.below_economical", "warn", -0.3,
                           f"Volume {annual_volume}/yr below economical "
                           f"window for {process.name}"))
    elif annual_volume > process.typical_volume_high:
        out.append(Finding("volume.above_economical", "warn", -0.3,
                           f"Volume {annual_volume}/yr above typical capacity"))
    else:
        out.append(Finding("volume.in_window", "info", +0.4,
                           "Annual volume sits in the process sweet-spot"))

    grade_rank = {"A": 3, "B": 2, "C": 1}
    if grade_rank.get(quality_grade, 2) > grade_rank.get(process.surface_quality, 2):
        out.append(Finding("surface.quality_gap", "warn", -0.3,
                           f"{process.name} delivers Class-{process.surface_quality} "
                           f"surface; project requires Class-{quality_grade}"))
    else:
        out.append(Finding("surface.quality_ok", "info", +0.2,
                           f"Surface quality Class-{process.surface_quality} meets spec"))

    if geom.sandwich and process.family in ("pultrusion", "winding"):
        out.append(Finding("sandwich.unsupported", "block", -0.9,
                           "Sandwich construction incompatible with continuous processes"))

    if process.dimensional_tolerance_mm <= 0.1:
        out.append(Finding("tolerance.tight_capable", "info", +0.3,
                           f"{process.name} holds ±{process.dimensional_tolerance_mm} mm"))

    return out


def score(findings: Iterable[Finding]) -> float:
    """Aggregate findings into a 0..1 fitness score."""
    blockers = [f for f in findings if f.severity == "block"]
    if blockers:
        return 0.0
    s = 0.5 + sum(f.impact for f in findings) * 0.15
    return max(0.0, min(1.0, s))
