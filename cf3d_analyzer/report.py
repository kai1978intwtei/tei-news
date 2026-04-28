"""Report objects and serializers.

Produces:
    - structured AnalysisReport (Python object the API returns)
    - JSON file for downstream tooling / PLM integration
    - Markdown summary
    - HTML dashboard (with embedded PNG mesh snapshot)
"""
from __future__ import annotations

import base64
import json
import textwrap
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .carbon_fiber import LayupPlan, equivalent_modulus_gpa
from .geometry import GeometricFeatures
from .ingest import DrawingPackage
from .process_advisor import ProjectContext, Recommendation
from .reconstruct3d import ReconstructionResult
from .tolerance import TolerancePlan


@dataclass
class AnalysisReport:
    source: str
    sha256: str
    generated_at: str
    drawing_summary: dict
    reconstruction: dict
    geometry: dict
    tolerance: dict
    recommendations: list[dict]
    layup: dict
    artefacts: dict[str, str] = field(default_factory=dict)
    warnings: list[str] = field(default_factory=list)

    def to_json(self, path: Path) -> Path:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(asdict(self), indent=2, ensure_ascii=False),
                        encoding="utf-8")
        return path

    def to_markdown(self, path: Path) -> Path:
        md = _markdown(self)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(md, encoding="utf-8")
        return path

    def to_html(self, path: Path, snapshot_png: Path | None = None) -> Path:
        html = _html(self, snapshot_png)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(html, encoding="utf-8")
        return path


def build_report(pkg: DrawingPackage,
                 recon: ReconstructionResult,
                 geom: GeometricFeatures,
                 tol: TolerancePlan,
                 recs: list[Recommendation],
                 layup: LayupPlan,
                 ctx: ProjectContext) -> AnalysisReport:
    return AnalysisReport(
        source=str(pkg.source),
        sha256=pkg.sha256,
        generated_at=datetime.now(timezone.utc).isoformat(),
        drawing_summary={
            "title_block": asdict(pkg.title_block),
            "n_views": len(pkg.views),
            "n_annotations": len(pkg.annotations),
            "is_3d_native": pkg.is_3d_native,
            "units": pkg.units,
        },
        reconstruction={
            "method": recon.method,
            "confidence": recon.confidence,
            "warnings": recon.warnings,
            "inferred_thickness_mm": recon.inferred_thickness,
            "inferred_views": recon.inferred_views,
            "bbox_mm": geom.bbox,
        },
        geometry={
            "length_mm": geom.length,
            "width_mm": geom.width,
            "height_mm": geom.height,
            "volume_mm3": geom.volume_mm3,
            "surface_area_mm2": geom.surface_area_mm2,
            "min_wall_thickness_mm": geom.min_wall_thickness,
            "nominal_thickness_mm": geom.nominal_thickness,
            "min_radius_mm": geom.min_radius if geom.min_radius != float("inf") else None,
            "compound_curvature": geom.has_compound_curvature,
            "undercuts": geom.has_undercuts,
            "closed_section": geom.closed_section,
            "sandwich": geom.sandwich,
            "n_holes": len(geom.holes),
            "envelope_class": geom.envelope_class,
            "thickness_class": geom.thickness_class,
            "notes": geom.notes,
        },
        tolerance={
            "n_callouts": len(tol.callouts),
            "tightest_band_mm": (None if tol.tightest_band_mm == float("inf")
                                  else tol.tightest_band_mm),
        },
        recommendations=[
            {
                "rank": i + 1,
                "process": r.process.name,
                "family": r.process.family,
                "fitness": round(r.fitness, 3),
                "viable": r.viable,
                "fiber_volume_pct": r.process.fiber_volume_pct,
                "void_content_pct": r.process.void_content_pct,
                "cycle_time_min": r.process.cycle_time_min,
                "tolerance_capability_mm": r.process.dimensional_tolerance_mm,
                "rationale": r.rationale,
                "findings": [
                    {"rule": f.rule, "severity": f.severity,
                     "impact": f.impact, "message": f.message}
                    for f in r.findings
                ],
                "process_notes": list(r.process.notes),
            }
            for i, r in enumerate(recs)
        ],
        layup={
            "fiber_grade": layup.grade.code,
            "fiber_modulus_gpa": layup.grade.tensile_modulus_gpa,
            "fiber_strength_mpa": layup.grade.tensile_strength_mpa,
            "fiber_density_g_cc": layup.grade.density_g_cc,
            "fiber_form": layup.fiber_form,
            "n_plies": len(layup.plies),
            "stacking": layup.stacking_string(),
            "cured_thickness_mm": layup.cured_thickness_mm,
            "target_thickness_mm": layup.target_thickness_mm,
            "fiber_volume_pct": layup.fiber_volume_pct,
            "balanced": layup.balanced,
            "symmetric": layup.symmetric,
            "equivalent_modulus_gpa": round(equivalent_modulus_gpa(layup), 1),
            "ply_book": [
                {"idx": p.sequence_idx, "angle_deg": p.angle_deg,
                 "material": p.material, "thickness_mm": p.thickness_mm,
                 "fiber_form": p.fiber_form, "notes": p.notes}
                for p in layup.plies
            ],
        },
        artefacts={},
        warnings=list(recon.warnings) + list(geom.notes),
    )


# ----------------------------------------------------------- formatters
def _markdown(r: AnalysisReport) -> str:
    g = r.geometry
    lines: list[str] = []
    lines.append(f"# CF3D Analysis Report — {Path(r.source).name}")
    lines.append("")
    lines.append(f"- Generated: {r.generated_at}")
    lines.append(f"- SHA-256: `{r.sha256[:16]}…`")
    lines.append(f"- Reconstruction: **{r.reconstruction['method']}** "
                 f"(confidence {r.reconstruction['confidence']:.0%})")
    lines.append("")
    lines.append("## Geometry")
    lines.append(f"- Envelope: {g['length_mm']:.1f} × {g['width_mm']:.1f} × "
                 f"{g['height_mm']:.1f} mm  ({g['envelope_class']})")
    lines.append(f"- Wall: {g['min_wall_thickness_mm']:.2f} – "
                 f"{g['nominal_thickness_mm']:.2f} mm  ({g['thickness_class']})")
    lines.append(f"- Volume: {g['volume_mm3']:.0f} mm³  |  "
                 f"Surface: {g['surface_area_mm2']:.0f} mm²")
    lines.append(f"- Compound curvature: {g['compound_curvature']}  |  "
                 f"Undercuts: {g['undercuts']}  |  Closed: {g['closed_section']}")
    lines.append("")
    lines.append("## Recommended composite processes")
    for rec in r.recommendations:
        lines.append(f"### #{rec['rank']} — {rec['process']}  "
                     f"(fitness {rec['fitness']:.2f})")
        lines.append(f"- Family: {rec['family']}")
        lines.append(f"- Vf {rec['fiber_volume_pct'][0]:.0f}–"
                     f"{rec['fiber_volume_pct'][1]:.0f} % | "
                     f"Voids ≤ {rec['void_content_pct'][1]:.1f} %")
        lines.append(f"- Tolerance ±{rec['tolerance_capability_mm']:.2f} mm | "
                     f"Cycle {rec['cycle_time_min'][0]:.0f}–"
                     f"{rec['cycle_time_min'][1]:.0f} min")
        lines.append(f"- Rationale: {rec['rationale']}")
        for note in rec["process_notes"]:
            lines.append(f"  - {note}")
        lines.append("")
    lines.append("## Suggested CF layup")
    lyp = r.layup
    lines.append(f"- Fiber: **{lyp['fiber_grade']}**  "
                 f"({lyp['fiber_modulus_gpa']} GPa / "
                 f"{lyp['fiber_strength_mpa']} MPa)")
    lines.append(f"- Form: {lyp['fiber_form']}")
    lines.append(f"- Stacking: `{lyp['stacking']}` ({lyp['n_plies']} plies)")
    lines.append(f"- Cured thickness: {lyp['cured_thickness_mm']:.2f} mm "
                 f"(target {lyp['target_thickness_mm']:.2f})")
    lines.append(f"- Equivalent modulus (rule-of-mixtures, in-plane): "
                 f"{lyp['equivalent_modulus_gpa']} GPa")
    if r.warnings:
        lines.append("")
        lines.append("## Warnings")
        for w in r.warnings:
            lines.append(f"- {w}")
    return "\n".join(lines) + "\n"


def _html(r: AnalysisReport, snapshot_png: Path | None) -> str:
    img_block = ""
    if snapshot_png and snapshot_png.exists():
        b64 = base64.b64encode(snapshot_png.read_bytes()).decode("ascii")
        img_block = (f'<img alt="3D model" src="data:image/png;base64,{b64}" '
                     f'style="max-width:100%;border:1px solid #335;border-radius:8px"/>')
    rec_html = ""
    for rec in r.recommendations:
        notes = "".join(f"<li>{n}</li>" for n in rec["process_notes"])
        rec_html += textwrap.dedent(f"""
        <article>
          <h3>#{rec['rank']} — {rec['process']}</h3>
          <p><strong>Fitness:</strong> {rec['fitness']:.2f} &middot;
             <strong>Family:</strong> {rec['family']} &middot;
             <strong>Vf:</strong> {rec['fiber_volume_pct'][0]:.0f}–
             {rec['fiber_volume_pct'][1]:.0f}% &middot;
             <strong>Tol:</strong> ±{rec['tolerance_capability_mm']:.2f} mm</p>
          <p>{rec['rationale']}</p>
          <ul>{notes}</ul>
        </article>""")
    g = r.geometry
    lyp = r.layup
    return textwrap.dedent(f"""
    <!doctype html><html lang="en"><head><meta charset="utf-8"/>
    <title>CF3D Analysis — {Path(r.source).name}</title>
    <style>
      :root {{ color-scheme: light dark; }}
      body {{ font-family: -apple-system, Segoe UI, Roboto, sans-serif;
              max-width: 1100px; margin: 24px auto; padding: 0 18px;
              background: #0d1b2a; color: #f0f5ff; }}
      h1, h2, h3 {{ color: #87c3ff; }}
      article {{ background: #142840; padding: 14px 18px;
                 border-radius: 10px; margin: 10px 0;
                 box-shadow: 0 1px 4px rgba(0,0,0,.4); }}
      table {{ border-collapse: collapse; width: 100%; margin-top: 8px; }}
      th, td {{ border-bottom: 1px solid #2c4a6e; padding: 6px 10px;
                text-align: left; }}
      .grid {{ display: grid; grid-template-columns: 1.4fr 1fr; gap: 18px; }}
      code {{ background: #08111c; padding: 2px 6px; border-radius: 4px; }}
    </style></head><body>
    <h1>CF3D Analysis Report</h1>
    <p>Source: <code>{r.source}</code> &middot;
       SHA-256: <code>{r.sha256[:24]}…</code> &middot;
       Generated: {r.generated_at}</p>

    <div class="grid">
      <div>
        <h2>Geometry</h2>
        <table>
          <tr><th>Bounding box (mm)</th>
              <td>{g['length_mm']:.1f} × {g['width_mm']:.1f} × {g['height_mm']:.1f}
                  ({g['envelope_class']})</td></tr>
          <tr><th>Wall thickness</th>
              <td>{g['nominal_thickness_mm']:.2f} mm ({g['thickness_class']})</td></tr>
          <tr><th>Volume / Surface</th>
              <td>{g['volume_mm3']:.0f} mm³ / {g['surface_area_mm2']:.0f} mm²</td></tr>
          <tr><th>Compound curvature</th><td>{g['compound_curvature']}</td></tr>
          <tr><th>Undercut</th><td>{g['undercuts']}</td></tr>
          <tr><th>Closed section</th><td>{g['closed_section']}</td></tr>
          <tr><th>Holes</th><td>{g['n_holes']}</td></tr>
        </table>
      </div>
      <div>
        <h2>3D Model</h2>
        {img_block}
        <p>Reconstruction: <code>{r.reconstruction['method']}</code>
           (confidence {r.reconstruction['confidence']:.0%})</p>
      </div>
    </div>

    <h2>Recommended Processes</h2>
    {rec_html}

    <h2>Carbon Fiber Layup</h2>
    <article>
      <p><strong>{lyp['fiber_grade']}</strong> &middot;
         {lyp['fiber_form']}</p>
      <p>Stacking: <code>{lyp['stacking']}</code>
         ({lyp['n_plies']} plies, cured {lyp['cured_thickness_mm']:.2f} mm)</p>
      <p>Equivalent in-plane modulus: <strong>
         {lyp['equivalent_modulus_gpa']} GPa</strong>
         &middot; Vf {lyp['fiber_volume_pct']:.0f}%</p>
    </article>
    </body></html>
    """).strip()
