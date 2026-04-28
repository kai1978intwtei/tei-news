"""End-to-end analysis pipeline.

Public entry point: `analyze(path, ctx, out_dir)`.

Flow:
    drawing  ─►  ingest  ─►  reconstruct3d  ─►  geometry
                                                    │
                                  ┌─────────────────┼──────────────────┐
                                  ▼                 ▼                  ▼
                              tolerance      process_advisor      multiview
                                                    │                  │
                                                    ▼                  ▼
                                              carbon_fiber          viewer3d
                                                    │
                                                    ▼
                                                ply_explode
                                                    │
                                                    ▼
                                                moldflow
                                                    │
                                                    ▼
                                                 report
"""
from __future__ import annotations

import logging
from dataclasses import asdict
from pathlib import Path
from typing import Optional

from . import carbon_fiber, geometry, ingest, moldflow, multiview
from . import ply_explode, process_advisor, reconstruct3d, report, tolerance, viewer3d

log = logging.getLogger(__name__)


def analyze(path: str,
            ctx: Optional[process_advisor.ProjectContext] = None,
            out_dir: str | Path = "./cf3d_out",
            *,
            top_n: int = 3,
            run_moldflow: bool = True,
            run_multiview: bool = True,
            run_ply_explode: bool = True) -> report.AnalysisReport:
    """One-call pipeline.  Returns the AnalysisReport and writes artefacts."""
    ctx = ctx or process_advisor.ProjectContext()
    out = Path(out_dir).expanduser().resolve()
    out.mkdir(parents=True, exist_ok=True)

    log.info("Analysing drawing %s", path)
    pkg = ingest.ingest(path)

    recon = reconstruct3d.reconstruct(pkg)
    log.info("Reconstruction: method=%s confidence=%.2f", recon.method, recon.confidence)

    geom = geometry.extract(pkg, recon)
    tol = tolerance.harvest(pkg)
    recs = process_advisor.recommend(geom, ctx, top_n=top_n)
    if not recs:
        raise RuntimeError("No viable composite process found")

    layup = carbon_fiber.design_layup(geom, recs[0], ctx)

    rep = report.build_report(pkg, recon, geom, tol, recs, layup, ctx)

    stem = Path(path).stem
    artefacts: dict[str, str] = {}

    artefacts["stl"] = str(viewer3d.write_stl(recon.mesh, out / f"{stem}.stl"))
    artefacts["obj"] = str(viewer3d.write_obj(recon.mesh, out / f"{stem}.obj"))
    artefacts["ply"] = str(viewer3d.write_ply(recon.mesh, out / f"{stem}.ply"))
    glb = viewer3d.write_glb(recon.mesh, out / f"{stem}.glb")
    if glb:
        artefacts["glb"] = str(glb)

    snap = viewer3d.render_png(recon.mesh, out / f"{stem}_iso.png",
                                title=f"{stem} — ISO view")
    if snap:
        artefacts["snapshot_png"] = str(snap)

    if run_multiview:
        mv = multiview.render_montage(recon.mesh, out / f"{stem}_multiview.png",
                                       title=f"{stem} — Multi-angle inspection",
                                       highlight_undercuts=geom.has_undercuts)
        if mv:
            artefacts["multiview_png"] = str(mv)

    if run_ply_explode:
        view = ply_explode.explode(layup, recon.mesh)
        artefacts["ply_explode_factor"] = str(view.explode_factor)
        ex_png = ply_explode.render_exploded(view,
                                              out / f"{stem}_ply_explode.png",
                                              title=f"{stem} — Ply explode "
                                                    f"({len(layup.plies)} plies, "
                                                    f"{layup.stacking_string()})")
        if ex_png:
            artefacts["ply_explode_png"] = str(ex_png)

        collapsed = view.collapse()
        viewer3d.write_stl(collapsed, out / f"{stem}_laminate.stl")
        artefacts["laminate_collapsed_stl"] = str(out / f"{stem}_laminate.stl")
        exploded = view.explode()
        viewer3d.write_stl(exploded, out / f"{stem}_laminate_exploded.stl")
        artefacts["laminate_exploded_stl"] = str(out / f"{stem}_laminate_exploded.stl")

    if run_moldflow:
        flow = moldflow.analyze(geom, recs[0])
        if flow:
            fmap = moldflow.render_fill_map(flow, out / f"{stem}_moldflow.png")
            if fmap:
                artefacts["moldflow_png"] = str(fmap)
            rep.recommendations[0]["moldflow"] = {
                "preform": flow.preform,
                "resin": flow.resin,
                "viscosity_pas": flow.viscosity_pas,
                "fill_time_s": flow.estimated_fill_time_s,
                "injection_pressure_bar": flow.injection_pressure_bar,
                "race_tracking_risk": flow.risk_race_tracking,
                "vents": flow.recommended_vents,
            }

    rep.artefacts = artefacts
    rep.to_json(out / f"{stem}.report.json")
    rep.to_markdown(out / f"{stem}.report.md")
    snap_path = artefacts.get("snapshot_png")
    rep.to_html(out / f"{stem}.report.html",
                snapshot_png=Path(snap_path) if snap_path else None)

    log.info("Analysis complete; artefacts in %s", out)
    return rep


# Backwards-compatible alias
analyze_drawing = analyze
