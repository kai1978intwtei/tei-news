"""Mold-flow / resin infusion analysis.

Built around Darcy's law for flow through a porous fiber preform:

        v = -(K / mu) * grad(P)

For a 1-D radial / linear flow with constant injection pressure ΔP,
fiber volume fraction Vf, and permeability K, the flow front position
follows the analytical relation:

        x(t) = sqrt( (2 K ΔP) / (mu (1 - Vf)) * t )

The module returns:
    - estimated fill time for a given gate-to-vent distance
    - peak injection pressure for a target fill time
    - viscosity development at process temperature (Castro-Macosko)
    - filling map across a coarse 2-D grid that the report can plot
    - vent placement & race-tracking risk score

All formulas are in SI units; convenience wrappers convert from mm/min.
"""
from __future__ import annotations

import logging
import math
from dataclasses import dataclass, field
from pathlib import Path

from .geometry import GeometricFeatures
from .process_advisor import Recommendation

log = logging.getLogger(__name__)


# Permeability (m^2) and processing constants for common CF preforms.
# K_in_plane is the higher of K_xx, K_yy.
@dataclass(frozen=True)
class PreformPermeability:
    name: str
    K_in_plane_m2: float
    K_through_thickness_m2: float
    typical_Vf: float


PREFORMS: dict[str, PreformPermeability] = {
    "NCF_biaxial":      PreformPermeability("Biaxial NCF",       1.5e-11, 5.0e-13, 0.55),
    "NCF_quad":         PreformPermeability("Quadraxial NCF",    1.0e-11, 4.0e-13, 0.55),
    "woven_3K":         PreformPermeability("3K plain weave",    8.0e-12, 3.0e-13, 0.50),
    "woven_12K":        PreformPermeability("12K twill",         1.2e-11, 4.0e-13, 0.52),
    "braid_triaxial":   PreformPermeability("Triaxial braid",    2.0e-11, 6.0e-13, 0.55),
    "3D_woven":         PreformPermeability("3D woven",          5.0e-12, 5.0e-12, 0.55),
    "stitched_chopped": PreformPermeability("Stitched chopped",  3.0e-11, 9.0e-13, 0.45),
}


# Castro-Macosko style viscosity (mu = mu0 * exp(E/RT) * f(α)).  We treat
# α=0 (uncrosslinked) and use representative epoxy infusion data.
@dataclass(frozen=True)
class ResinSystem:
    name: str
    mu0_pas: float           # reference viscosity at injection temp (Pa·s)
    activation_kJmol: float
    cure_temp_c: float
    pot_life_min: float


RESINS: dict[str, ResinSystem] = {
    "RTM6":           ResinSystem("Hexcel RTM6",           0.1, 50, 120, 240),
    "EPIKOTE_05475":  ResinSystem("Hexion Epikote 05475",  0.08, 48, 100, 180),
    "PRISM_EP2400":   ResinSystem("Solvay PRISM EP2400",   0.07, 55, 130, 200),
    "RTM6_2":         ResinSystem("Hexcel RTM6-2",         0.05, 52, 130, 480),
}


@dataclass
class FlowResult:
    process: str
    preform: str
    resin: str
    injection_pressure_bar: float
    flow_distance_mm: float
    estimated_fill_time_s: float
    viscosity_pas: float
    permeability_m2: float
    Vf: float
    risk_race_tracking: float       # 0..1 (1 = high risk)
    recommended_vents: list[str] = field(default_factory=list)
    fill_grid: list[list[float]] = field(default_factory=list)   # arrival time per cell


def estimate_viscosity(resin: ResinSystem, process_temp_c: float) -> float:
    R = 8.314e-3       # kJ/(mol·K)
    T = process_temp_c + 273.15
    Tref = resin.cure_temp_c + 273.15
    return resin.mu0_pas * math.exp(resin.activation_kJmol / R * (1.0 / T - 1.0 / Tref))


def fill_time_seconds(K_m2: float, dP_pa: float, mu_pas: float, Vf: float,
                      flow_distance_m: float) -> float:
    """1-D Darcy linear flow.  Returns time for the flow front to cover
    `flow_distance_m`.  Uses analytical x = sqrt(2KΔP/(μ(1-Vf))·t)."""
    if K_m2 <= 0 or dP_pa <= 0 or mu_pas <= 0:
        return float("inf")
    return (flow_distance_m ** 2) * mu_pas * (1 - Vf) / (2 * K_m2 * dP_pa)


def required_pressure_pa(K_m2: float, mu_pas: float, Vf: float,
                         flow_distance_m: float, target_time_s: float) -> float:
    if target_time_s <= 0:
        return float("inf")
    return (flow_distance_m ** 2) * mu_pas * (1 - Vf) / (2 * K_m2 * target_time_s)


def analyze(geom: GeometricFeatures,
            rec: Recommendation,
            *,
            preform_key: str = "NCF_biaxial",
            resin_key: str = "RTM6",
            injection_pressure_bar: float = 6.0,
            process_temp_c: float = 120.0,
            grid: int = 24) -> FlowResult | None:
    if rec.process.family not in ("rtm", "afp_atl", "oven_vbo"):
        # Mold flow only meaningful for liquid-resin/infusion processes.
        return None

    preform = PREFORMS[preform_key]
    resin = RESINS[resin_key]
    mu = estimate_viscosity(resin, process_temp_c)
    flow_distance_m = max(geom.length, geom.width) / 1000.0
    dP_pa = injection_pressure_bar * 1.0e5

    fill_t = fill_time_seconds(preform.K_in_plane_m2, dP_pa, mu, preform.typical_Vf,
                               flow_distance_m)

    risk = 0.0
    if geom.has_compound_curvature:
        risk += 0.3
    if geom.aspect_ratio > 4:
        risk += 0.3
    if geom.min_radius < 5:
        risk += 0.2
    risk = min(1.0, risk)

    vents: list[str] = ["Vent at farthest extremity"]
    if geom.has_compound_curvature:
        vents.append("Add secondary vent at high-curvature zone")
    if geom.aspect_ratio > 4:
        vents.append("Use central line gate; vent at both ends")
    if geom.closed_section:
        vents.append("Place additional vent at the inboard radius")

    fill_grid = _build_fill_grid(geom, preform, resin, mu, dP_pa, grid)

    return FlowResult(
        process=rec.process.name,
        preform=preform.name,
        resin=resin.name,
        injection_pressure_bar=injection_pressure_bar,
        flow_distance_mm=flow_distance_m * 1000,
        estimated_fill_time_s=fill_t,
        viscosity_pas=mu,
        permeability_m2=preform.K_in_plane_m2,
        Vf=preform.typical_Vf,
        risk_race_tracking=risk,
        recommended_vents=vents,
        fill_grid=fill_grid,
    )


def _build_fill_grid(geom: GeometricFeatures,
                     preform: PreformPermeability,
                     resin: ResinSystem,
                     mu: float,
                     dP_pa: float,
                     n: int) -> list[list[float]]:
    """Cell-centred radial-flow approximation: time to reach each cell from a
    single gate at the centroid.  Useful for quick visual fill-pattern review."""
    L = geom.length / 1000.0
    W = geom.width / 1000.0
    cx, cy = L / 2, W / 2
    grid = [[0.0] * n for _ in range(n)]
    for i in range(n):
        for j in range(n):
            x = (i + 0.5) / n * L
            y = (j + 0.5) / n * W
            r = math.hypot(x - cx, y - cy)
            grid[i][j] = fill_time_seconds(preform.K_in_plane_m2, dP_pa, mu,
                                            preform.typical_Vf, r) if r > 0 else 0.0
    return grid


def render_fill_map(flow: FlowResult, out_path) -> Path | None:
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        import numpy as np
    except ImportError:
        return None
    arr = np.asarray(flow.fill_grid, dtype=float)
    fig, ax = plt.subplots(figsize=(7, 6), dpi=140)
    im = ax.imshow(arr.T, origin="lower", cmap="viridis", aspect="auto")
    cbar = fig.colorbar(im, ax=ax)
    cbar.set_label("Fill arrival time (s)")
    ax.set_title(f"Mould-fill map — {flow.process}\n"
                  f"resin {flow.resin} @ μ={flow.viscosity_pas:.3f} Pa·s, "
                  f"ΔP={flow.injection_pressure_bar:.1f} bar")
    ax.set_xlabel("Length cell")
    ax.set_ylabel("Width cell")
    p = Path(out_path).expanduser().resolve()
    p.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(p, bbox_inches="tight")
    plt.close(fig)
    return p
