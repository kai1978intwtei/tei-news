# CF3D Analyzer

> Production-grade, **stand-alone** desktop / CLI software that ingests an
> engineering drawing, builds a 3-D model, and recommends suitable
> **carbon-fiber composite manufacturing processes** — with ply-book design,
> multi-angle visual inspection, mould-flow analysis, and one-click
> ply-stack explode / restore.

It runs entirely offline as its own Python package — it has no
relationship to the host repository's news website.

---

## What it does

1. **Ingest** — DXF / DWG / STEP / IGES / PDF / PNG / JPG / TIFF.
2. **Reconstruct 3-D** — three-view → solid, or extrude / B-Rep wrap.
3. **Geometric analysis** — wall thickness, min radius, compound
   curvature, undercut, draft, holes, sandwich detection.
4. **Process advisor** — ranks 10 carbon-fiber processes
   (Autoclave, OOA, RTM, VARTM, Compression, AFP/ATL, Filament Winding,
   Pultrusion, Braiding, Thermoplastic Press) against the geometry,
   project volume, surface grade, matrix family, cycle-time / cost
   targets.
5. **Carbon-fiber specifics** — fiber-grade selector (T300, T700S,
   T800S, T1000G, IM7, IM10, M40J, M55J, K13D2U), balanced-symmetric
   ply-book, in-plane equivalent modulus.
6. **Ply explode** — one-click visual explode and one-click restore of
   the laminate stack with per-angle colour coding.
7. **Multi-angle visual judgement** — 8-up orthographic + isometric
   montage so reviewers can spot draft / undercut / drape problems at a
   glance.
8. **Mould-flow analysis** — Darcy-law fill simulation, viscosity at
   process temperature, vent placement and race-tracking risk.
9. **Reports** — JSON, Markdown, and HTML dashboard with embedded 3-D
   snapshot.
10. **Folder watcher** — drop drawings into a folder, get reports
    automatically.

## Install

```bash
cd cf3d_analyzer
pip install -e .[all]    # pulls in matplotlib / numpy / Pillow / ezdxf / etc.
```

The base install has zero third-party dependencies and still produces
STL / OBJ / PLY meshes plus JSON / Markdown reports. Install the `all`
extra to enable the 3-D viewer, multi-view montage, ply-explode PNG and
mould-flow heat-map.

## Run

```bash
# desktop GUI (recommended for engineers)
cf3d gui

# one-shot analysis
cf3d analyze ./drawings/wing_skin.step \
     --annual-volume 500 --quality A --application structural \
     --matrix epoxy --cycle 30

# folder watcher (analysis on drop)
cf3d watch ./incoming --out ./cf3d_out

# also runnable as a module
python -m cf3d_analyzer analyze ./drawings/bracket.dxf
```

## Output

Each run writes (under `--out`, default `./cf3d_out`):

```
<part>.stl                # raw 3-D mesh
<part>.obj                # raw 3-D mesh
<part>.ply                # raw 3-D mesh
<part>.glb                # web-ready 3-D (when trimesh installed)
<part>_iso.png            # isometric snapshot
<part>_multiview.png      # 8-angle montage
<part>_ply_explode.png    # exploded laminate
<part>_laminate.stl       # collapsed laminate
<part>_laminate_exploded.stl
<part>_moldflow.png       # Darcy fill-time map (if RTM/infusion picked)
<part>.report.json
<part>.report.md
<part>.report.html
```

## Library API

```python
from cf3d_analyzer import analyze
from cf3d_analyzer.process_advisor import ProjectContext

rep = analyze(
    "drawings/spoiler.step",
    ctx=ProjectContext(annual_volume=2000, quality_grade="A",
                       application="structural", matrix_class="epoxy"),
    out_dir="./cf3d_out",
)
print(rep.recommendations[0]["process"])
print(rep.layup["stacking"])
```

## Folder watch from Python

```python
from cf3d_analyzer import watch
watch("./incoming", on_report=lambda r: print("done:", r.source))
```
