"""Carbon-fiber-specific knowledge.

Used to derive a ply-book recommendation, layup orientation, fiber grade
selection, and consolidation hints for the chosen process.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field

from .geometry import GeometricFeatures
from .process_advisor import ProjectContext, Recommendation


@dataclass
class FiberGrade:
    code: str
    tensile_modulus_gpa: float
    tensile_strength_mpa: float
    density_g_cc: float
    typical_use: str


GRADES: tuple[FiberGrade, ...] = (
    FiberGrade("T300/3K",     230, 3530, 1.76, "general structural"),
    FiberGrade("T700S/12K",   230, 4900, 1.80, "high-strength prepreg"),
    FiberGrade("T800S/24K",   294, 5880, 1.81, "aerospace primary structure"),
    FiberGrade("T1000G",      294, 6370, 1.80, "ultra-high tensile"),
    FiberGrade("M40J",        377, 4400, 1.77, "high-modulus stiffness-driven"),
    FiberGrade("M55J",        540, 4020, 1.91, "satellite/space structures"),
    FiberGrade("HexTow IM7",  276, 5670, 1.78, "aerospace primary"),
    FiberGrade("HexTow IM10", 310, 6964, 1.79, "next-gen aero primary"),
    FiberGrade("Pitch K13D2U", 935, 3700, 2.20, "thermal management / space"),
)


@dataclass
class Ply:
    sequence_idx: int
    angle_deg: int
    material: str
    thickness_mm: float
    fiber_form: str
    notes: str = ""


@dataclass
class LayupPlan:
    grade: FiberGrade
    fiber_form: str
    nominal_ply_thickness_mm: float
    plies: list[Ply] = field(default_factory=list)
    symmetric: bool = True
    balanced: bool = True
    target_thickness_mm: float = 0.0
    fiber_volume_pct: float = 60.0

    def stacking_string(self) -> str:
        if not self.plies:
            return "[]"
        half = self.plies[: len(self.plies) // 2 if self.symmetric else len(self.plies)]
        body = "/".join(f"{p.angle_deg:+d}" for p in half)
        return f"[{body}]{'s' if self.symmetric else ''}"

    @property
    def cured_thickness_mm(self) -> float:
        return sum(p.thickness_mm for p in self.plies)


def select_grade(ctx: ProjectContext, geom: GeometricFeatures) -> FiberGrade:
    if ctx.application == "pressure":
        return _grade("T1000G")
    if "satellite" in (ctx.application or "").lower() or geom.envelope_class == "xlarge":
        return _grade("M55J")
    if ctx.quality_grade == "A" and ctx.fiber_system == "carbon":
        if geom.thickness_class in ("thin", "ultra-thin"):
            return _grade("HexTow IM7")
        return _grade("T800S/24K")
    return _grade("T700S/12K")


def _grade(code: str) -> FiberGrade:
    for g in GRADES:
        if g.code == code:
            return g
    return GRADES[0]


def design_layup(geom: GeometricFeatures,
                 rec: Recommendation,
                 ctx: ProjectContext) -> LayupPlan:
    grade = select_grade(ctx, geom)
    form, ply_t = _form_for(rec, geom)
    target_t = geom.nominal_thickness
    n_plies = max(4, int(round(target_t / ply_t)))
    if n_plies % 2:
        n_plies += 1     # keep symmetric

    angles = _angles_for(ctx, geom, n_plies)
    plies = [
        Ply(sequence_idx=i,
            angle_deg=a,
            material=f"{grade.code} / {form}",
            thickness_mm=ply_t,
            fiber_form=form)
        for i, a in enumerate(angles)
    ]

    return LayupPlan(
        grade=grade,
        fiber_form=form,
        nominal_ply_thickness_mm=ply_t,
        plies=plies,
        symmetric=True,
        balanced=_is_balanced(angles),
        target_thickness_mm=target_t,
        fiber_volume_pct=(rec.process.fiber_volume_pct[0]
                          + rec.process.fiber_volume_pct[1]) / 2,
    )


def _form_for(rec: Recommendation, geom: GeometricFeatures) -> tuple[str, float]:
    fam = rec.process.family
    if fam in ("autoclave", "oven_vbo", "afp_atl"):
        if geom.thickness_class in ("ultra-thin", "thin"):
            return "Thin-ply UD prepreg (0.06 mm)", 0.06
        return "UD prepreg (0.13 mm)", 0.13
    if fam == "rtm":
        return "Stitched NCF preform (0.25 mm)", 0.25
    if fam == "winding":
        return "Wet roving (0.20 mm/wrap)", 0.20
    if fam == "pultrusion":
        return "Roving + CFM (0.30 mm/layer)", 0.30
    if fam == "braiding":
        return "Triaxial braid (0.40 mm)", 0.40
    if fam == "thermoplastic":
        return "CF/PEEK organosheet (0.20 mm/ply)", 0.20
    if fam == "compression":
        return "Prepreg (0.13 mm) or 50K SMC", 0.13
    return "UD prepreg (0.13 mm)", 0.13


def _angles_for(ctx: ProjectContext, geom: GeometricFeatures, n: int) -> list[int]:
    """Return a balanced symmetric stack."""
    half = n // 2
    base = [0, 45, -45, 90]
    if ctx.application == "pressure":
        base = [55, -55, 0, 90]
    if geom.aspect_ratio > 4:
        base = [0, 0, 45, -45, 90]      # bias to fiber direction
    seq = []
    for i in range(half):
        seq.append(base[i % len(base)])
    return seq + list(reversed(seq))


def _is_balanced(angles: list[int]) -> bool:
    counts: dict[int, int] = {}
    for a in angles:
        counts[a] = counts.get(a, 0) + 1
    for a, c in counts.items():
        if a not in (0, 90) and counts.get(-a, 0) != c:
            return False
    return True


# ------------------------------------------------------------ stiffness helper
def equivalent_modulus_gpa(plan: LayupPlan) -> float:
    """First-order rule-of-mixtures + Halpin-Tsai scaled by ply orientations."""
    Vf = plan.fiber_volume_pct / 100.0
    Em = 3.5
    Ef = plan.grade.tensile_modulus_gpa
    E11 = Vf * Ef + (1 - Vf) * Em
    E22 = Em / max(0.001, (1 - Vf * (1 - Em / Ef)))
    G12 = 0.4 * E22

    eq = 0.0
    for p in plan.plies:
        a = math.radians(p.angle_deg)
        c4 = math.cos(a) ** 4
        s4 = math.sin(a) ** 4
        cs2 = (math.cos(a) * math.sin(a)) ** 2
        Ex = 1.0 / (c4 / E11 + s4 / E22 + (1.0 / G12 - 2 * 0.3 / E11) * cs2)
        eq += Ex
    return eq / max(1, len(plan.plies))
