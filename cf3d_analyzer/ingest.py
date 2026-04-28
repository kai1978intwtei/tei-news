"""Drawing ingestion layer.

Accepts engineering drawings in several common formats and returns a
normalized DrawingPackage that downstream stages can consume without
having to know the source format.

Supported (with graceful fallback when an optional dependency is missing):
    - DXF / DWG   (ezdxf, optional ODA File Converter for DWG)
    - STEP / IGES (pythonocc-core or cadquery, optional)
    - PDF         (PyMuPDF / pdfplumber)
    - Raster (PNG/JPG/TIFF) — vectorized via OpenCV + Hough
"""
from __future__ import annotations

import hashlib
import logging
import math
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

log = logging.getLogger(__name__)

DXF_EXT = {".dxf", ".dwg"}
CAD3D_EXT = {".step", ".stp", ".iges", ".igs", ".x_t", ".x_b"}
PDF_EXT = {".pdf"}
RASTER_EXT = {".png", ".jpg", ".jpeg", ".tif", ".tiff", ".bmp"}


@dataclass
class View:
    """A single orthographic view extracted from a drawing sheet."""
    name: str                            # e.g. "front", "top", "right", "iso"
    entities: list[dict] = field(default_factory=list)   # primitives
    bbox: tuple[float, float, float, float] = (0, 0, 0, 0)
    scale: float = 1.0
    units: str = "mm"


@dataclass
class Annotation:
    kind: str                            # "dimension" | "gdt" | "note" | "title"
    text: str
    value: Optional[float] = None
    tolerance: Optional[tuple[float, float]] = None
    datum: Optional[str] = None
    location: tuple[float, float] = (0.0, 0.0)


@dataclass
class TitleBlock:
    part_no: str = ""
    revision: str = ""
    material: str = ""
    finish: str = ""
    drawn_by: str = ""
    date: str = ""
    sheet: str = ""
    weight: Optional[float] = None
    project: str = ""


@dataclass
class DrawingPackage:
    source: Path
    sha256: str
    units: str
    views: list[View]
    annotations: list[Annotation]
    title_block: TitleBlock
    raw: dict[str, Any] = field(default_factory=dict)

    @property
    def is_3d_native(self) -> bool:
        return any(v.name == "model" for v in self.views)


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def ingest(path: str | os.PathLike) -> DrawingPackage:
    p = Path(path).expanduser().resolve()
    if not p.exists():
        raise FileNotFoundError(p)

    ext = p.suffix.lower()
    digest = _sha256(p)

    if ext in DXF_EXT:
        return _ingest_dxf(p, digest)
    if ext in CAD3D_EXT:
        return _ingest_cad3d(p, digest)
    if ext in PDF_EXT:
        return _ingest_pdf(p, digest)
    if ext in RASTER_EXT:
        return _ingest_raster(p, digest)
    raise ValueError(f"Unsupported drawing format: {ext}")


# ---------------------------------------------------------------- DXF / DWG
def _ingest_dxf(p: Path, digest: str) -> DrawingPackage:
    try:
        import ezdxf  # type: ignore
    except ImportError:
        log.warning("ezdxf not installed — using lightweight DXF reader")
        return _ingest_dxf_lite(p, digest)

    doc = ezdxf.readfile(str(p))
    msp = doc.modelspace()
    units = {1: "in", 4: "mm", 5: "cm", 6: "m"}.get(doc.header.get("$INSUNITS", 4), "mm")

    entities: list[dict] = []
    annotations: list[Annotation] = []

    for e in msp:
        t = e.dxftype()
        if t == "LINE":
            entities.append({"type": "line",
                             "p1": (e.dxf.start.x, e.dxf.start.y),
                             "p2": (e.dxf.end.x, e.dxf.end.y)})
        elif t == "CIRCLE":
            entities.append({"type": "circle",
                             "c": (e.dxf.center.x, e.dxf.center.y),
                             "r": e.dxf.radius})
        elif t == "ARC":
            entities.append({"type": "arc",
                             "c": (e.dxf.center.x, e.dxf.center.y),
                             "r": e.dxf.radius,
                             "start": e.dxf.start_angle,
                             "end": e.dxf.end_angle})
        elif t == "LWPOLYLINE":
            entities.append({"type": "polyline",
                             "pts": [(x, y) for x, y, *_ in e.get_points()]})
        elif t == "SPLINE":
            entities.append({"type": "spline",
                             "ctrl": [(p.x, p.y) for p in e.control_points]})
        elif t == "DIMENSION":
            try:
                v = float(e.get_measurement())
            except Exception:
                v = None
            annotations.append(Annotation(kind="dimension",
                                          text=e.dxf.text or f"{v}",
                                          value=v))
        elif t in ("MTEXT", "TEXT"):
            annotations.append(Annotation(kind="note", text=e.text))

    bbox = _bbox_of(entities)
    front = View(name="front", entities=entities, bbox=bbox, units=units)
    return DrawingPackage(source=p, sha256=digest, units=units,
                          views=[front], annotations=annotations,
                          title_block=_extract_title_block(annotations),
                          raw={"dxf_layers": [l.dxf.name for l in doc.layers]})


def _ingest_dxf_lite(p: Path, digest: str) -> DrawingPackage:
    """Minimal DXF reader for environments without ezdxf.

    Handles LINE/CIRCLE entity groups in ASCII DXF only.  Good enough for
    smoke tests and trivial drawings; production users should install ezdxf.
    """
    entities: list[dict] = []
    cur: dict[str, Any] = {}
    code: Optional[str] = None
    try:
        with p.open("r", errors="ignore") as f:
            for raw in f:
                tok = raw.strip()
                if code is None:
                    code = tok
                    continue
                val = tok
                if code == "0":
                    if cur.get("type") == "LINE" and {"10", "20", "11", "21"} <= cur.keys():
                        entities.append({"type": "line",
                                         "p1": (float(cur["10"]), float(cur["20"])),
                                         "p2": (float(cur["11"]), float(cur["21"]))})
                    elif cur.get("type") == "CIRCLE" and {"10", "20", "40"} <= cur.keys():
                        entities.append({"type": "circle",
                                         "c": (float(cur["10"]), float(cur["20"])),
                                         "r": float(cur["40"])})
                    cur = {"type": val}
                else:
                    cur[code] = val
                code = None
    except Exception as exc:
        log.error("DXF lite parse failed: %s", exc)
    bbox = _bbox_of(entities)
    return DrawingPackage(
        source=p, sha256=digest, units="mm",
        views=[View(name="front", entities=entities, bbox=bbox)],
        annotations=[], title_block=TitleBlock(part_no=p.stem),
    )


# ----------------------------------------------------------- STEP / IGES / X_T
def _ingest_cad3d(p: Path, digest: str) -> DrawingPackage:
    try:
        import cadquery as cq  # type: ignore
        shape = cq.importers.importStep(str(p)) if p.suffix.lower() in {".step", ".stp"} \
            else cq.importers.importIges(str(p))
        bb = shape.val().BoundingBox()
        bbox = (bb.xmin, bb.ymin, bb.xmax, bb.ymax)
        view = View(name="model", entities=[{"type": "brep", "ref": str(p)}],
                    bbox=bbox, units="mm")
        return DrawingPackage(source=p, sha256=digest, units="mm",
                              views=[view], annotations=[],
                              title_block=TitleBlock(part_no=p.stem),
                              raw={"backend": "cadquery"})
    except ImportError:
        log.warning("cadquery not available — surfacing 3D file as opaque ref")
        view = View(name="model", entities=[{"type": "brep", "ref": str(p)}],
                    bbox=(0, 0, 0, 0), units="mm")
        return DrawingPackage(source=p, sha256=digest, units="mm",
                              views=[view], annotations=[],
                              title_block=TitleBlock(part_no=p.stem),
                              raw={"backend": "opaque"})


# ------------------------------------------------------------------------- PDF
def _ingest_pdf(p: Path, digest: str) -> DrawingPackage:
    try:
        import fitz  # PyMuPDF
        doc = fitz.open(str(p))
        annotations: list[Annotation] = []
        all_lines: list[dict] = []
        for page in doc:
            for d in page.get_drawings():
                for item in d.get("items", []):
                    op, *pts = item
                    if op == "l" and len(pts) >= 2:
                        all_lines.append({"type": "line",
                                          "p1": (pts[0].x, pts[0].y),
                                          "p2": (pts[1].x, pts[1].y)})
                    elif op == "re":
                        r = pts[0]
                        all_lines.append({"type": "rect",
                                          "p1": (r.x0, r.y0),
                                          "p2": (r.x1, r.y1)})
            txt = page.get_text("words")
            for w in txt:
                annotations.append(Annotation(kind="note", text=w[4],
                                              location=(w[0], w[1])))
        view = View(name="front", entities=all_lines, bbox=_bbox_of(all_lines))
        return DrawingPackage(source=p, sha256=digest, units="mm",
                              views=[view], annotations=annotations,
                              title_block=_extract_title_block(annotations))
    except ImportError:
        log.warning("PyMuPDF not installed — PDF ingest is degraded")
        return DrawingPackage(
            source=p, sha256=digest, units="mm",
            views=[View(name="front")], annotations=[],
            title_block=TitleBlock(part_no=p.stem),
        )


# ---------------------------------------------------------------------- raster
def _ingest_raster(p: Path, digest: str) -> DrawingPackage:
    try:
        import cv2  # type: ignore
        import numpy as np  # type: ignore
    except ImportError:
        log.warning("OpenCV not installed — raster ingest produces empty geometry")
        return DrawingPackage(
            source=p, sha256=digest, units="mm",
            views=[View(name="front")], annotations=[],
            title_block=TitleBlock(part_no=p.stem),
        )

    img = cv2.imread(str(p), cv2.IMREAD_GRAYSCALE)
    if img is None:
        raise IOError(f"Cannot read image {p}")
    h, w = img.shape
    blur = cv2.GaussianBlur(img, (5, 5), 1.2)
    edges = cv2.Canny(blur, 50, 150)

    entities: list[dict] = []
    lines = cv2.HoughLinesP(edges, 1, math.pi / 360, 80,
                            minLineLength=max(20, w // 60), maxLineGap=6)
    if lines is not None:
        for x1, y1, x2, y2 in lines.reshape(-1, 4):
            entities.append({"type": "line",
                             "p1": (float(x1), float(h - y1)),
                             "p2": (float(x2), float(h - y2))})
    circles = cv2.HoughCircles(blur, cv2.HOUGH_GRADIENT, 1.2, 25,
                               param1=120, param2=35,
                               minRadius=4, maxRadius=min(h, w) // 4)
    if circles is not None:
        for cx, cy, r in circles[0]:
            entities.append({"type": "circle",
                             "c": (float(cx), float(h - cy)),
                             "r": float(r)})

    view = View(name="front", entities=entities, bbox=(0.0, 0.0, float(w), float(h)),
                units="px")
    return DrawingPackage(source=p, sha256=digest, units="px",
                          views=[view], annotations=[],
                          title_block=TitleBlock(part_no=p.stem),
                          raw={"image_size": (w, h)})


# --------------------------------------------------------------- shared helpers
def _bbox_of(entities: list[dict]) -> tuple[float, float, float, float]:
    if not entities:
        return (0.0, 0.0, 0.0, 0.0)
    xs: list[float] = []
    ys: list[float] = []
    for e in entities:
        if e["type"] == "line":
            xs += [e["p1"][0], e["p2"][0]]
            ys += [e["p1"][1], e["p2"][1]]
        elif e["type"] == "circle":
            cx, cy = e["c"]; r = e["r"]
            xs += [cx - r, cx + r]; ys += [cy - r, cy + r]
        elif e["type"] == "arc":
            cx, cy = e["c"]; r = e["r"]
            xs += [cx - r, cx + r]; ys += [cy - r, cy + r]
        elif e["type"] == "polyline":
            for x, y in e["pts"]:
                xs.append(x); ys.append(y)
        elif e["type"] == "rect":
            xs += [e["p1"][0], e["p2"][0]]
            ys += [e["p1"][1], e["p2"][1]]
    if not xs:
        return (0.0, 0.0, 0.0, 0.0)
    return (min(xs), min(ys), max(xs), max(ys))


_KEY_HINTS = {
    "part": ("part_no", str),
    "p/n": ("part_no", str),
    "rev": ("revision", str),
    "material": ("material", str),
    "matl": ("material", str),
    "finish": ("finish", str),
    "drawn": ("drawn_by", str),
    "date": ("date", str),
    "sheet": ("sheet", str),
    "weight": ("weight", float),
    "project": ("project", str),
}


def _extract_title_block(annotations: list[Annotation]) -> TitleBlock:
    tb = TitleBlock()
    for a in annotations:
        text = a.text.lower()
        for hint, (field_name, cast) in _KEY_HINTS.items():
            if hint in text and ":" in a.text:
                _, _, val = a.text.partition(":")
                val = val.strip()
                try:
                    setattr(tb, field_name, cast(val))
                except (ValueError, TypeError):
                    pass
    return tb
