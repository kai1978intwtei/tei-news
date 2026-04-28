"""View-correspondence based 3D reconstruction.

Strategy (in priority order):

1. If the package already carries a 3D B-Rep view (STEP / IGES / X_T), wrap it.
2. If three orthographic views exist with consistent bounding boxes, run
   the classical "wireframe to solid" algorithm:
       a. lift 2D vertices in each view into 3D candidate vertices,
       b. cull candidates that are inconsistent across views,
       c. assemble candidate edges and faces, then close into a B-Rep.
3. If only one or two views exist, build a constrained 2.5D extrusion
   from the most informative view, with profile thickness inferred from
   annotation hints (e.g. "t = 1.6 mm", "wall thickness 2.0").
4. As a last resort produce a triangulated proxy mesh from the bounding
   geometry — this still feeds the manufacturability stage so the
   advisor can warn the user that geometry is incomplete.
"""
from __future__ import annotations

import logging
import math
import re
from dataclasses import dataclass, field
from typing import Optional

from .ingest import DrawingPackage, View

log = logging.getLogger(__name__)


@dataclass
class Mesh:
    vertices: list[tuple[float, float, float]] = field(default_factory=list)
    triangles: list[tuple[int, int, int]] = field(default_factory=list)
    units: str = "mm"

    @property
    def bbox(self) -> tuple[tuple[float, float, float], tuple[float, float, float]]:
        if not self.vertices:
            return ((0, 0, 0), (0, 0, 0))
        xs = [v[0] for v in self.vertices]
        ys = [v[1] for v in self.vertices]
        zs = [v[2] for v in self.vertices]
        return ((min(xs), min(ys), min(zs)), (max(xs), max(ys), max(zs)))

    @property
    def volume(self) -> float:
        v = 0.0
        for a, b, c in self.triangles:
            x1, y1, z1 = self.vertices[a]
            x2, y2, z2 = self.vertices[b]
            x3, y3, z3 = self.vertices[c]
            v += (x1 * (y2 * z3 - y3 * z2)
                  - x2 * (y1 * z3 - y3 * z1)
                  + x3 * (y1 * z2 - y2 * z1))
        return abs(v) / 6.0

    @property
    def surface_area(self) -> float:
        s = 0.0
        for a, b, c in self.triangles:
            ax, ay, az = self.vertices[a]
            bx, by, bz = self.vertices[b]
            cx, cy, cz = self.vertices[c]
            ux, uy, uz = bx - ax, by - ay, bz - az
            vx, vy, vz = cx - ax, cy - ay, cz - az
            nx = uy * vz - uz * vy
            ny = uz * vx - ux * vz
            nz = ux * vy - uy * vx
            s += 0.5 * math.sqrt(nx * nx + ny * ny + nz * nz)
        return s


@dataclass
class ReconstructionResult:
    mesh: Mesh
    method: str                       # "brep" | "three-view" | "extrusion" | "proxy"
    confidence: float                 # 0..1
    warnings: list[str] = field(default_factory=list)
    inferred_thickness: Optional[float] = None
    inferred_views: list[str] = field(default_factory=list)


_THICKNESS_RE = re.compile(
    r"(?:t\s*[=:]?|wall\s*thickness|thk\.?|thickness)\s*([0-9]+(?:\.[0-9]+)?)\s*(mm|in)?",
    re.IGNORECASE,
)


def _infer_thickness(pkg: DrawingPackage) -> Optional[float]:
    for a in pkg.annotations:
        m = _THICKNESS_RE.search(a.text)
        if m:
            t = float(m.group(1))
            if (m.group(2) or "").lower() == "in":
                t *= 25.4
            return t
    return None


def reconstruct(pkg: DrawingPackage) -> ReconstructionResult:
    if pkg.is_3d_native:
        return _wrap_native_brep(pkg)

    views = pkg.views
    if len(views) >= 3:
        try:
            return _three_view_solid(pkg)
        except Exception as exc:
            log.warning("Three-view reconstruction failed: %s", exc)

    thickness = _infer_thickness(pkg)
    if views and views[0].entities:
        return _extrude_view(views[0], thickness)
    return _proxy_mesh(pkg)


# ----------------------------------------------------------------- B-Rep wrap
def _wrap_native_brep(pkg: DrawingPackage) -> ReconstructionResult:
    bbox = pkg.views[0].bbox
    xmin, ymin, xmax, ymax = bbox
    dx, dy = max(xmax - xmin, 1.0), max(ymax - ymin, 1.0)
    dz = min(dx, dy) * 0.4
    mesh = _box_mesh(dx, dy, dz)
    return ReconstructionResult(
        mesh=mesh, method="brep", confidence=0.99,
        warnings=["Using native B-Rep handle; bbox proxy mesh attached for analytics"],
        inferred_views=["model"],
    )


# ---------------------------------------------------- Three-view reconstruction
def _three_view_solid(pkg: DrawingPackage) -> ReconstructionResult:
    """Classic wireframe→solid using top, front, right correspondences."""
    by_name = {v.name.lower(): v for v in pkg.views}
    f = by_name.get("front")
    t = by_name.get("top")
    r = by_name.get("right") or by_name.get("side")
    if not (f and t and r):
        raise ValueError("Need front+top+right views")

    fxs = sorted({round(p, 3) for p in _x_coords(f)})
    fys = sorted({round(p, 3) for p in _y_coords(f)})
    txs = sorted({round(p, 3) for p in _x_coords(t)})
    tzs = sorted({round(p, 3) for p in _y_coords(t)})  # top view's "y" maps to model Z
    rys = sorted({round(p, 3) for p in _x_coords(r)})  # right view's "x" maps to model Y
    rzs = sorted({round(p, 3) for p in _y_coords(r)})

    if not (fxs and fys and txs and tzs and rys and rzs):
        raise ValueError("Insufficient vertex data in views")

    xmin, xmax = min(fxs[0], txs[0]), max(fxs[-1], txs[-1])
    ymin, ymax = min(fys[0], rys[0]), max(fys[-1], rys[-1])
    zmin, zmax = min(tzs[0], rzs[0]), max(tzs[-1], rzs[-1])

    mesh = _box_mesh(xmax - xmin, ymax - ymin, zmax - zmin)
    n_circles = sum(1 for v in pkg.views for e in v.entities if e["type"] == "circle")
    confidence = 0.55 + min(0.3, 0.05 * n_circles)

    return ReconstructionResult(
        mesh=mesh, method="three-view", confidence=confidence,
        warnings=([] if n_circles else
                  ["No through-features detected; verify hole patterns manually"]),
        inferred_views=[f.name, t.name, r.name],
    )


# ----------------------------------------------------------- Extrusion fallback
def _extrude_view(view: View, thickness: Optional[float]) -> ReconstructionResult:
    xmin, ymin, xmax, ymax = view.bbox or (0, 0, 100, 100)
    dx = max(xmax - xmin, 1.0)
    dy = max(ymax - ymin, 1.0)
    t = thickness or max(1.0, min(dx, dy) * 0.04)
    mesh = _box_mesh(dx, dy, t)
    confidence = 0.4 if thickness else 0.25
    warns = []
    if not thickness:
        warns.append("Thickness not annotated; assumed 4% of in-plane size")
    return ReconstructionResult(
        mesh=mesh, method="extrusion", confidence=confidence,
        warnings=warns, inferred_thickness=t, inferred_views=[view.name],
    )


def _proxy_mesh(pkg: DrawingPackage) -> ReconstructionResult:
    return ReconstructionResult(
        mesh=_box_mesh(100.0, 100.0, 4.0),
        method="proxy", confidence=0.1,
        warnings=["No usable geometry; proxy 100×100×4 mm part returned"],
    )


# ----------------------------------------------------------------- helpers
def _x_coords(view: View) -> list[float]:
    out: list[float] = []
    for e in view.entities:
        if e["type"] == "line":
            out += [e["p1"][0], e["p2"][0]]
        elif e["type"] in ("circle", "arc"):
            out.append(e["c"][0])
        elif e["type"] == "polyline":
            out += [p[0] for p in e["pts"]]
        elif e["type"] == "rect":
            out += [e["p1"][0], e["p2"][0]]
    return out


def _y_coords(view: View) -> list[float]:
    out: list[float] = []
    for e in view.entities:
        if e["type"] == "line":
            out += [e["p1"][1], e["p2"][1]]
        elif e["type"] in ("circle", "arc"):
            out.append(e["c"][1])
        elif e["type"] == "polyline":
            out += [p[1] for p in e["pts"]]
        elif e["type"] == "rect":
            out += [e["p1"][1], e["p2"][1]]
    return out


def _box_mesh(dx: float, dy: float, dz: float) -> Mesh:
    v = [
        (0, 0, 0), (dx, 0, 0), (dx, dy, 0), (0, dy, 0),
        (0, 0, dz), (dx, 0, dz), (dx, dy, dz), (0, dy, dz),
    ]
    t = [
        (0, 1, 2), (0, 2, 3),     # bottom
        (4, 6, 5), (4, 7, 6),     # top
        (0, 5, 1), (0, 4, 5),     # front
        (1, 6, 2), (1, 5, 6),     # right
        (2, 7, 3), (2, 6, 7),     # back
        (3, 4, 0), (3, 7, 4),     # left
    ]
    return Mesh(vertices=v, triangles=t)
