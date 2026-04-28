"""Multi-angle visual judgement panel.

Renders 6 orthographic + 1 isometric snapshot of the reconstructed mesh
into a single PNG montage so a reviewer can spot drape, undercut and
draft issues at a glance.
"""
from __future__ import annotations

import logging
from pathlib import Path

from .reconstruct3d import Mesh

log = logging.getLogger(__name__)

VIEWS = [
    ("front",  0,   0),
    ("back",   0, 180),
    ("right",  0,  90),
    ("left",   0, -90),
    ("top",   89,   0),
    ("bottom", -89,   0),
    ("iso-1",  25,  35),
    ("iso-2",  25, -35),
]


def render_montage(mesh: Mesh, out_path, *,
                   title: str = "Multi-angle inspection",
                   highlight_undercuts: bool = False) -> Path | None:
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        from mpl_toolkits.mplot3d.art3d import Poly3DCollection
    except ImportError:
        log.warning("matplotlib not installed — multiview disabled")
        return None

    fig = plt.figure(figsize=(13, 7), dpi=140)
    fig.suptitle(title, color="#1a3a6e")
    polys = [[mesh.vertices[a], mesh.vertices[b], mesh.vertices[c]]
             for (a, b, c) in mesh.triangles]
    (xmin, ymin, zmin), (xmax, ymax, zmax) = mesh.bbox

    for idx, (name, elev, azim) in enumerate(VIEWS, start=1):
        ax = fig.add_subplot(2, 4, idx, projection="3d")
        coll = Poly3DCollection(polys, alpha=0.85,
                                 linewidths=0.25, edgecolors="#1f3a5f")
        coll.set_facecolor("#cc4444" if (highlight_undercuts and "iso" in name)
                           else "#3b6fa3")
        ax.add_collection3d(coll)
        ax.set_xlim(xmin, xmax)
        ax.set_ylim(ymin, ymax)
        ax.set_zlim(zmin, zmax)
        ax.set_box_aspect((max(xmax - xmin, 1),
                           max(ymax - ymin, 1),
                           max(zmax - zmin, 1)))
        ax.view_init(elev, azim)
        ax.set_title(name, fontsize=9)
        ax.set_xticks([]); ax.set_yticks([]); ax.set_zticks([])

    p = Path(out_path).expanduser().resolve()
    p.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(p, bbox_inches="tight", facecolor="#f6f8fb")
    plt.close(fig)
    return p
