"""High-end web UI server.

Spins up a FastAPI app on http://127.0.0.1:8765 that exposes:

    GET  /                     dashboard (modern HTML + Three.js viewer)
    POST /api/analyze          multipart upload, returns JSON report
    GET  /api/jobs/{job_id}    job status + report
    GET  /api/mesh/{job_id}    GLB mesh (or STL fallback) for the viewer
    GET  /api/snapshot/{job_id}/{artefact}  PNG artefacts
    GET  /static/...           CSS / JS / fonts

Designed to feel like Linear/Onshape/Vercel: glass morphism cards,
smooth motion, dark theme with cyan accents, live 3D viewer with
orbit controls.
"""
from __future__ import annotations

import asyncio
import logging
import shutil
import tempfile
import uuid
import webbrowser
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict
from pathlib import Path
from typing import Optional

try:
    from fastapi import FastAPI, File, Form, HTTPException, UploadFile
    from fastapi.responses import (FileResponse, HTMLResponse, JSONResponse)
    from fastapi.staticfiles import StaticFiles
    _HAS_FASTAPI = True
except ImportError:
    _HAS_FASTAPI = False

log = logging.getLogger(__name__)

_HERE = Path(__file__).resolve().parent
_STATIC = _HERE / "static"
_JOBS: dict[str, dict] = {}
_executor = ThreadPoolExecutor(max_workers=2)


def _build_app():
    if not _HAS_FASTAPI:
        raise RuntimeError("fastapi not installed.  pip install -e .[web]")

    from ..pipeline import analyze
    from ..process_advisor import ProjectContext

    app = FastAPI(title="CF3D Studio", version="1.0.0")
    app.mount("/static", StaticFiles(directory=str(_STATIC)), name="static")

    @app.get("/", response_class=HTMLResponse)
    async def index() -> str:
        return (_STATIC / "index.html").read_text(encoding="utf-8")

    @app.post("/api/analyze")
    async def api_analyze(
        file: UploadFile = File(...),
        annual_volume: int = Form(500),
        quality: str = Form("A"),
        application: str = Form("structural"),
        matrix: str = Form("epoxy"),
        cycle: Optional[float] = Form(None),
    ):
        if not file.filename:
            raise HTTPException(status_code=400, detail="No file uploaded")
        job_id = uuid.uuid4().hex[:12]
        job_dir = Path(tempfile.gettempdir()) / "cf3d_jobs" / job_id
        job_dir.mkdir(parents=True, exist_ok=True)
        target = job_dir / file.filename
        with target.open("wb") as f:
            shutil.copyfileobj(file.file, f)
        ctx = ProjectContext(
            annual_volume=annual_volume,
            quality_grade=quality,
            application=application,
            matrix_class=matrix,
            cycle_time_target_min=cycle,
            fiber_system="carbon",
        )
        _JOBS[job_id] = {"job_id": job_id, "status": "running",
                          "drawing": str(target), "out_dir": str(job_dir)}

        loop = asyncio.get_event_loop()

        def _run() -> None:
            try:
                rep = analyze(str(target), ctx=ctx, out_dir=str(job_dir))
                _JOBS[job_id]["status"] = "ok"
                _JOBS[job_id]["report"] = asdict(rep)
            except Exception as exc:
                log.exception("Analyse failed")
                _JOBS[job_id]["status"] = "error"
                _JOBS[job_id]["error"] = str(exc)

        await loop.run_in_executor(_executor, _run)
        return JSONResponse(_JOBS[job_id])

    @app.get("/api/jobs/{job_id}")
    async def api_job(job_id: str):
        job = _JOBS.get(job_id)
        if not job:
            raise HTTPException(status_code=404, detail="Job not found")
        return job

    @app.get("/api/mesh/{job_id}")
    async def api_mesh(job_id: str):
        job = _JOBS.get(job_id)
        if not job or job.get("status") != "ok":
            raise HTTPException(status_code=404, detail="Mesh not ready")
        artefacts = job["report"]["artefacts"]
        for key in ("glb", "stl", "obj"):
            if key in artefacts and Path(artefacts[key]).exists():
                return FileResponse(artefacts[key])
        raise HTTPException(status_code=404, detail="Mesh missing")

    @app.get("/api/snapshot/{job_id}/{artefact}")
    async def api_snap(job_id: str, artefact: str):
        job = _JOBS.get(job_id)
        if not job or job.get("status") != "ok":
            raise HTTPException(status_code=404, detail="Job not ready")
        path = job["report"]["artefacts"].get(artefact)
        if not path or not Path(path).exists():
            raise HTTPException(status_code=404, detail=f"{artefact} missing")
        return FileResponse(path)

    @app.get("/api/report/{job_id}")
    async def api_report(job_id: str):
        job = _JOBS.get(job_id)
        if not job or job.get("status") != "ok":
            raise HTTPException(status_code=404, detail="Report not ready")
        stem = Path(job["drawing"]).stem
        html = Path(job["out_dir"]) / f"{stem}.report.html"
        if html.exists():
            return FileResponse(html, media_type="text/html")
        raise HTTPException(status_code=404, detail="Report HTML missing")

    return app


def serve(host: str = "127.0.0.1", port: int = 8765, *,
          open_browser: bool = True) -> None:
    """Run uvicorn and (optionally) open the browser."""
    try:
        import uvicorn
    except ImportError as exc:
        raise RuntimeError("uvicorn not installed.  pip install -e .[web]") from exc

    app = _build_app()
    url = f"http://{host}:{port}/"
    if open_browser:
        try:
            webbrowser.open(url)
        except Exception:
            pass
    log.info("CF3D Studio running on %s", url)
    uvicorn.run(app, host=host, port=port, log_level="info")
