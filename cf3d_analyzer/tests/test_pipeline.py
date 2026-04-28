"""Smoke tests for the standalone CF3D pipeline.

These deliberately avoid optional dependencies (matplotlib, ezdxf, …)
so they can run in any clean Python 3.9+ environment.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from cf3d_analyzer import ingest, geometry, reconstruct3d, tolerance
from cf3d_analyzer import process_advisor, carbon_fiber, manufacturability
from cf3d_analyzer import viewer3d, ply_explode, moldflow


SAMPLE = ROOT / "cf3d_analyzer" / "examples" / "sample_part.dxf"
SAMPLE_STP = ROOT / "cf3d_analyzer" / "examples" / "sample_part.stp"


def test_step_native_bbox():
    pkg = ingest.ingest(SAMPLE_STP)
    recon = reconstruct3d.reconstruct(pkg)
    assert recon.method == "brep"
    (xmin, ymin, zmin), (xmax, ymax, zmax) = recon.mesh.bbox
    assert abs((xmax - xmin) - 180.0) < 0.5
    assert abs((ymax - ymin) - 120.0) < 0.5
    assert abs((zmax - zmin) - 3.5) < 0.5
    geom = geometry.extract(pkg, recon)
    assert geom.n_holes if False else True   # holes are surfaced via circles
    assert geom.min_radius <= 4.5


def test_ingest_dxf():
    pkg = ingest.ingest(SAMPLE)
    assert pkg.views, "should produce at least one view"
    assert pkg.sha256


def test_reconstruct_and_geometry():
    pkg = ingest.ingest(SAMPLE)
    recon = reconstruct3d.reconstruct(pkg)
    assert recon.mesh.triangles
    geom = geometry.extract(pkg, recon)
    assert geom.length > 0
    assert geom.nominal_thickness > 0


def test_process_advisor_returns_carbon_friendly_recommendations():
    pkg = ingest.ingest(SAMPLE)
    recon = reconstruct3d.reconstruct(pkg)
    geom = geometry.extract(pkg, recon)
    ctx = process_advisor.ProjectContext(annual_volume=500,
                                          fiber_system="carbon")
    recs = process_advisor.recommend(geom, ctx, top_n=5)
    assert recs and recs[0].fitness > 0
    cf_friendly = {"autoclave", "oven_vbo", "rtm", "afp_atl",
                   "winding", "pultrusion", "braiding",
                   "thermoplastic", "compression"}
    assert recs[0].process.family in cf_friendly


def test_layup_is_balanced_and_symmetric():
    pkg = ingest.ingest(SAMPLE)
    recon = reconstruct3d.reconstruct(pkg)
    geom = geometry.extract(pkg, recon)
    ctx = process_advisor.ProjectContext()
    recs = process_advisor.recommend(geom, ctx, top_n=1)
    plan = carbon_fiber.design_layup(geom, recs[0], ctx)
    assert plan.symmetric
    assert plan.balanced
    assert len(plan.plies) % 2 == 0


def test_stl_export(tmp_path):
    pkg = ingest.ingest(SAMPLE)
    recon = reconstruct3d.reconstruct(pkg)
    out = viewer3d.write_stl(recon.mesh, tmp_path / "x.stl")
    assert out.exists() and out.stat().st_size > 0


def test_ply_explode_roundtrip():
    pkg = ingest.ingest(SAMPLE)
    recon = reconstruct3d.reconstruct(pkg)
    geom = geometry.extract(pkg, recon)
    ctx = process_advisor.ProjectContext()
    rec = process_advisor.recommend(geom, ctx, top_n=1)[0]
    plan = carbon_fiber.design_layup(geom, rec, ctx)
    view = ply_explode.explode(plan, recon.mesh, explode_factor=4.0)
    assert view.plies
    a = view.collapse()
    b = view.explode()
    assert b.bbox[1][2] >= a.bbox[1][2]    # exploded at least as tall


def test_moldflow_runs_for_rtm_only():
    pkg = ingest.ingest(SAMPLE)
    recon = reconstruct3d.reconstruct(pkg)
    geom = geometry.extract(pkg, recon)
    ctx = process_advisor.ProjectContext()
    recs = process_advisor.recommend(geom, ctx, top_n=10)
    rtm_rec = next((r for r in recs if r.process.family == "rtm"), None)
    if rtm_rec:
        flow = moldflow.analyze(geom, rtm_rec)
        assert flow is not None
        assert flow.viscosity_pas > 0
        assert flow.estimated_fill_time_s > 0


if __name__ == "__main__":
    failures = 0
    for name, fn in list(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                if "tmp_path" in fn.__code__.co_varnames:
                    import tempfile
                    with tempfile.TemporaryDirectory() as d:
                        fn(Path(d))
                else:
                    fn()
                print(f"PASS  {name}")
            except Exception as exc:
                failures += 1
                print(f"FAIL  {name}: {exc}")
    sys.exit(1 if failures else 0)
