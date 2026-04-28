"""One-click ply-stack explode and collapse.

Renders the recommended layup as a stack of individual plies translated
along the part normal so the operator can inspect orientation, sequence
and material at a glance.  Provides reversible state via ExplodedView.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field

from .carbon_fiber import LayupPlan
from .reconstruct3d import Mesh


@dataclass
class PlyMesh:
    sequence_idx: int
    angle_deg: int
    material: str
    mesh: Mesh
    z_offset: float
    color_hex: str


@dataclass
class ExplodedView:
    base_thickness_mm: float
    explode_factor: float
    plies: list[PlyMesh] = field(default_factory=list)

    def collapse(self) -> Mesh:
        """One-click 'restore': return the consolidated laminate as a single mesh."""
        return _stack(self.plies, explode=False)

    def explode(self, factor: float | None = None) -> Mesh:
        """Re-render the explode at a new factor (default uses self.explode_factor)."""
        if factor is None:
            factor = self.explode_factor
        return _stack(self.plies, explode=True, factor=factor)


_PLY_COLORS = {
    0:   "#ff5252",
    45:  "#ffd54f",
    -45: "#26c6da",
    90:  "#7e57c2",
    55:  "#66bb6a",
    -55: "#42a5f5",
}


def explode(plan: LayupPlan,
            base_mesh: Mesh,
            explode_factor: float = 4.0) -> ExplodedView:
    """Build an ExplodedView whose plies sit above each other along +Z.

    `explode_factor`==1.0 means plies just touch (real laminate); larger
    values open the stack so a user can visually count and identify each
    layer.  `factor`==0 collapses the laminate.
    """
    if not plan.plies:
        return ExplodedView(base_thickness_mm=0.0, explode_factor=explode_factor)

    base_thk = sum(p.thickness_mm for p in plan.plies)
    plies: list[PlyMesh] = []
    z_running = 0.0
    for p in plan.plies:
        rotated = _rotate_inplane(base_mesh, p.angle_deg)
        offset = z_running + (p.thickness_mm / 2)
        plies.append(PlyMesh(
            sequence_idx=p.sequence_idx,
            angle_deg=p.angle_deg,
            material=p.material,
            mesh=rotated,
            z_offset=offset,
            color_hex=_PLY_COLORS.get(p.angle_deg, "#90a4ae"),
        ))
        z_running += p.thickness_mm

    return ExplodedView(base_thickness_mm=base_thk,
                        explode_factor=explode_factor,
                        plies=plies)


def _rotate_inplane(mesh: Mesh, angle_deg: int) -> Mesh:
    a = math.radians(angle_deg)
    c, s = math.cos(a), math.sin(a)
    (xmin, ymin, _), (xmax, ymax, _) = mesh.bbox
    cx, cy = (xmin + xmax) / 2, (ymin + ymax) / 2
    new_v = []
    for x, y, z in mesh.vertices:
        x0, y0 = x - cx, y - cy
        x1 = c * x0 - s * y0 + cx
        y1 = s * x0 + c * y0 + cy
        new_v.append((x1, y1, z))
    return Mesh(vertices=new_v, triangles=list(mesh.triangles), units=mesh.units)


def _stack(plies: list[PlyMesh], *, explode: bool, factor: float = 4.0) -> Mesh:
    """Concatenate ply meshes into a single mesh in the requested arrangement."""
    out = Mesh(vertices=[], triangles=[])
    if not plies:
        return out
    z_cursor = 0.0
    for ply in plies:
        thk = max(ply.mesh.bbox[1][2] - ply.mesh.bbox[0][2], 0.001)
        if explode:
            z_target = z_cursor
        else:
            z_target = ply.z_offset - thk / 2
        offset_idx = len(out.vertices)
        for x, y, z in ply.mesh.vertices:
            out.vertices.append((x, y, z + z_target))
        for a, b, c in ply.mesh.triangles:
            out.triangles.append((a + offset_idx, b + offset_idx, c + offset_idx))
        if explode:
            z_cursor += thk * factor
        else:
            z_cursor += thk
    return out


def render_exploded(view: ExplodedView,
                    out_path,
                    *,
                    explode_factor: float | None = None,
                    title: str = "Ply explode"):
    """Render an annotated multi-color exploded ply view to PNG."""
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        from mpl_toolkits.mplot3d.art3d import Poly3DCollection
    except ImportError:
        return None

    factor = explode_factor or view.explode_factor
    fig = plt.figure(figsize=(9, 7), dpi=140)
    ax = fig.add_subplot(111, projection="3d")
    z_cursor = 0.0
    z_max = 0.0
    for ply in view.plies:
        thk = ply.mesh.bbox[1][2] - ply.mesh.bbox[0][2]
        z_target = z_cursor
        polys = [
            [(x, y, z - ply.mesh.bbox[0][2] + z_target)
             for (x, y, z) in (ply.mesh.vertices[i] for i in tri)]
            for tri in ply.mesh.triangles
        ]
        coll = Poly3DCollection(polys, alpha=0.8, linewidths=0.3,
                                 edgecolors="#0d1b2a")
        coll.set_facecolor(ply.color_hex)
        ax.add_collection3d(coll)
        z_cursor += thk * factor
        z_max = z_cursor

    (xmin, ymin, _), (xmax, ymax, _) = view.plies[0].mesh.bbox
    ax.set_xlim(xmin, xmax)
    ax.set_ylim(ymin, ymax)
    ax.set_zlim(0, max(z_max, 1.0))
    ax.set_xlabel("X (mm)")
    ax.set_ylabel("Y (mm)")
    ax.set_zlabel("Stack Z (mm)")
    ax.set_title(title)
    legend_lines = [
        f"#{p.sequence_idx:02d}  {p.angle_deg:+4d}°  {p.material}"
        for p in view.plies
    ]
    ax.text2D(0.02, 0.98, "\n".join(legend_lines),
              transform=ax.transAxes, va="top", fontsize=7,
              family="monospace",
              bbox=dict(facecolor="#ffffffaa", edgecolor="#444"))
    from pathlib import Path
    p = Path(out_path).expanduser().resolve()
    p.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(p, bbox_inches="tight")
    plt.close(fig)
    return p
