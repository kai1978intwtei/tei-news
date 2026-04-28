"""Composite manufacturing process advisor.

Ranks every entry in the process knowledge base against the extracted
geometry + project context, then returns top recommendations with the
reasoning that justified the ranking.
"""
from __future__ import annotations

from dataclasses import dataclass, field

from .data.process_kb import PROCESSES, ProcessEnvelope
from .geometry import GeometricFeatures
from .manufacturability import Finding, evaluate, score


@dataclass
class Recommendation:
    process: ProcessEnvelope
    fitness: float
    findings: list[Finding] = field(default_factory=list)
    rationale: str = ""

    @property
    def viable(self) -> bool:
        return self.fitness > 0.0


@dataclass
class ProjectContext:
    annual_volume: int = 100
    quality_grade: str = "A"           # "A" | "B" | "C"
    target_unit_cost: float | None = None     # USD
    fiber_system: str = "carbon"        # "carbon" | "glass" | "aramid"
    matrix_class: str = "epoxy"         # "epoxy" | "bmi" | "thermoplastic"
    application: str = "structural"     # "structural" | "cosmetic" | "pressure"
    cycle_time_target_min: float | None = None


def recommend(geom: GeometricFeatures,
              ctx: ProjectContext,
              top_n: int = 3) -> list[Recommendation]:
    candidates: list[Recommendation] = []
    for proc in PROCESSES:
        findings = evaluate(geom, proc,
                            annual_volume=ctx.annual_volume,
                            quality_grade=ctx.quality_grade)
        fit = score(findings)
        fit *= _fiber_bias(proc, ctx)
        fit *= _matrix_bias(proc, ctx)
        fit *= _cost_bias(proc, ctx)
        fit *= _cycle_bias(proc, ctx)
        rationale = _rationale(proc, geom, ctx, findings)
        candidates.append(Recommendation(process=proc,
                                          fitness=fit,
                                          findings=findings,
                                          rationale=rationale))
    candidates.sort(key=lambda r: r.fitness, reverse=True)
    return candidates[:top_n]


# ----------------------------------------------------------- bias adjustments
_CARBON_FRIENDLY = {
    "autoclave", "oven_vbo", "rtm", "afp_atl", "winding",
    "pultrusion", "braiding", "thermoplastic",
}


def _fiber_bias(p: ProcessEnvelope, ctx: ProjectContext) -> float:
    if ctx.fiber_system == "carbon":
        return 1.05 if p.family in _CARBON_FRIENDLY else 0.85
    return 1.0


def _matrix_bias(p: ProcessEnvelope, ctx: ProjectContext) -> float:
    if ctx.matrix_class == "thermoplastic":
        return 1.15 if p.family == "thermoplastic" else 0.85
    if ctx.matrix_class == "bmi":
        return 1.1 if p.family in ("autoclave", "rtm") else 0.9
    return 1.0


def _cost_bias(p: ProcessEnvelope, ctx: ProjectContext) -> float:
    if ctx.target_unit_cost is None:
        return 1.0
    return 1.1 if p.typical_unit_cost_pct_of_baseline <= 0.6 else 0.95


def _cycle_bias(p: ProcessEnvelope, ctx: ProjectContext) -> float:
    if ctx.cycle_time_target_min is None:
        return 1.0
    lo, hi = p.cycle_time_min
    if hi <= ctx.cycle_time_target_min:
        return 1.1
    if lo > ctx.cycle_time_target_min * 2:
        return 0.85
    return 1.0


def _rationale(p: ProcessEnvelope,
               geom: GeometricFeatures,
               ctx: ProjectContext,
               findings: list[Finding]) -> str:
    blockers = [f.message for f in findings if f.severity == "block"]
    if blockers:
        return "Blocked: " + "; ".join(blockers)
    parts: list[str] = []
    parts.append(f"{p.family.upper()} family fits a {geom.envelope_class} "
                 f"{geom.thickness_class}-walled part")
    parts.append(f"holds ±{p.dimensional_tolerance_mm} mm at "
                 f"Vf {p.fiber_volume_pct[0]:.0f}–{p.fiber_volume_pct[1]:.0f}%")
    if ctx.fiber_system == "carbon" and p.family in _CARBON_FRIENDLY:
        parts.append("aligned with high-modulus CF roadmap")
    parts.append(f"cycle {p.cycle_time_min[0]:.0f}–{p.cycle_time_min[1]:.0f} min, "
                 f"unit cost {p.typical_unit_cost_pct_of_baseline:.0%} of autoclave baseline")
    return "; ".join(parts)
