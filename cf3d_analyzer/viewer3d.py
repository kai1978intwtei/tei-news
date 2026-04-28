"""3D rendering and mesh export.

Multiple back-ends are supported with graceful fallback:
    - STL / OBJ / PLY writers (always available, pure-python)
    - matplotlib 3D static / interactive viewer (recommended fallback)
    - trimesh viewer (preferred when installed)
    - GLB/GLTF export (when trimesh installed)

The viewer always also writes a static PNG snapshot so headless / CI
environments still produce an artefact.
"""
from __future__ import annotations

import logging
import math
import os
import struct
from pathlib import Path

from .reconstruct3d import Mesh

log = logging.getLogger(__name__)


def write_stl(mesh: Mesh, path: str | os.PathLike) -> Path:
    p = Path(path).expanduser().resolve()
    p.parent.mkdir(parents=True, exist_ok=True)
    with p.open("wb") as f:
        f.write(b"\x00" * 80)
        f.write(struct.pack("<I", len(mesh.triangles)))
        for a, b, c in mesh.triangles:
            ax, ay, az = mesh.vertices[a]
            bx, by, bz = mesh.vertices[b]
            cx, cy, cz = mesh.vertices[c]
            ux, uy, uz = bx - ax, by - ay, bz - az
            vx, vy, vz = cx - ax, cy - ay, cz - az
            nx = uy * vz - uz * vy
            ny = uz * vx - ux * vz
            nz = ux * vy - uy * vx
            ln = math.sqrt(nx * nx + ny * ny + nz * nz) or 1.0
            f.write(struct.pack("<fff", nx / ln, ny / ln, nz / ln))
            f.write(struct.pack("<fff", ax, ay, az))
            f.write(struct.pack("<fff", bx, by, bz))
            f.write(struct.pack("<fff", cx, cy, cz))
            f.write(b"\x00\x00")
    return p


def write_obj(mesh: Mesh, path: str | os.PathLike) -> Path:
    p = Path(path).expanduser().resolve()
    p.parent.mkdir(parents=True, exist_ok=True)
    lines: list[str] = ["# CF3D Analyzer mesh export"]
    for x, y, z in mesh.vertices:
        lines.append(f"v {x:.6f} {y:.6f} {z:.6f}")
    for a, b, c in mesh.triangles:
        lines.append(f"f {a + 1} {b + 1} {c + 1}")
    p.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return p


def write_ply(mesh: Mesh, path: str | os.PathLike) -> Path:
    p = Path(path).expanduser().resolve()
    p.parent.mkdir(parents=True, exist_ok=True)
    with p.open("w", encoding="utf-8") as f:
        f.write("ply\nformat ascii 1.0\n")
        f.write(f"element vertex {len(mesh.vertices)}\n")
        f.write("property float x\nproperty float y\nproperty float z\n")
        f.write(f"element face {len(mesh.triangles)}\n")
        f.write("property list uchar int vertex_indices\nend_header\n")
        for x, y, z in mesh.vertices:
            f.write(f"{x:.6f} {y:.6f} {z:.6f}\n")
        for a, b, c in mesh.triangles:
            f.write(f"3 {a} {b} {c}\n")
    return p


def write_glb(mesh: Mesh, path: str | os.PathLike) -> Path | None:
    try:
        import numpy as np
        import trimesh
    except ImportError:
        log.info("trimesh unavailable — skipping GLB export")
        return None
    tm = trimesh.Trimesh(vertices=np.asarray(mesh.vertices, dtype=float),
                         faces=np.asarray(mesh.triangles, dtype=int),
                         process=False)
    p = Path(path).expanduser().resolve()
    p.parent.mkdir(parents=True, exist_ok=True)
    tm.export(str(p))
    return p


def render_png(mesh: Mesh, path: str | os.PathLike, *, title: str = "CF3D model",
               elevation: float = 22, azimuth: float = 35) -> Path | None:
    """Render the mesh to a PNG snapshot using matplotlib (headless safe)."""
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        from mpl_toolkits.mplot3d.art3d import Poly3DCollection
    except ImportError:
        log.warning("matplotlib not installed — PNG snapshot skipped")
        return None

    fig = plt.figure(figsize=(8, 6), dpi=140)
    ax = fig.add_subplot(111, projection="3d")
    polys = [[mesh.vertices[a], mesh.vertices[b], mesh.vertices[c]]
             for a, b, c in mesh.triangles]
    coll = Poly3DCollection(polys, alpha=0.85,
                             linewidths=0.4, edgecolors="#1f3a5f")
    coll.set_facecolor("#0d1b2a")
    ax.add_collection3d(coll)

    (xmin, ymin, zmin), (xmax, ymax, zmax) = mesh.bbox
    ax.set_xlim(xmin, xmax)
    ax.set_ylim(ymin, ymax)
    ax.set_zlim(zmin, zmax)
    ax.set_box_aspect((max(xmax - xmin, 1),
                       max(ymax - ymin, 1),
                       max(zmax - zmin, 1)))
    ax.set_xlabel("X (mm)")
    ax.set_ylabel("Y (mm)")
    ax.set_zlabel("Z (mm)")
    ax.set_title(title)
    ax.view_init(elevation, azimuth)
    p = Path(path).expanduser().resolve()
    p.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(p, bbox_inches="tight")
    plt.close(fig)
    return p


def show_interactive(mesh: Mesh, *, title: str = "CF3D model") -> None:
    """Open an interactive 3D window.  Falls back gracefully when no display."""
    try:
        import trimesh
        import numpy as np
        tm = trimesh.Trimesh(vertices=np.asarray(mesh.vertices, dtype=float),
                             faces=np.asarray(mesh.triangles, dtype=int),
                             process=False)
        tm.show()
        return
    except Exception as exc:
        log.info("trimesh viewer unavailable (%s) — falling back to matplotlib", exc)

    try:
        import matplotlib.pyplot as plt
        from mpl_toolkits.mplot3d.art3d import Poly3DCollection
    except ImportError:
        log.error("No 3D viewer available; install matplotlib or trimesh")
        return

    fig = plt.figure(figsize=(9, 7))
    ax = fig.add_subplot(111, projection="3d")
    polys = [[mesh.vertices[a], mesh.vertices[b], mesh.vertices[c]]
             for a, b, c in mesh.triangles]
    coll = Poly3DCollection(polys, alpha=0.9, linewidths=0.4,
                             edgecolors="#1f3a5f")
    coll.set_facecolor("#243b55")
    ax.add_collection3d(coll)
    (xmin, ymin, zmin), (xmax, ymax, zmax) = mesh.bbox
    ax.set_xlim(xmin, xmax)
    ax.set_ylim(ymin, ymax)
    ax.set_zlim(zmin, zmax)
    ax.set_box_aspect((max(xmax - xmin, 1),
                       max(ymax - ymin, 1),
                       max(zmax - zmin, 1)))
    ax.set_title(title)
    plt.show()
