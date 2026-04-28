"""Folder watcher — analyses any new drawing the moment it lands.

Pure-stdlib polling so it works in environments where watchdog/inotify
is unavailable.  Drop drawings into the watched folder and a fresh
report directory is generated automatically.
"""
from __future__ import annotations

import logging
import os
import time
from pathlib import Path
from typing import Callable, Iterable, Optional

from .pipeline import analyze
from .process_advisor import ProjectContext
from .report import AnalysisReport

log = logging.getLogger(__name__)

WATCH_EXTS = {".dxf", ".dwg", ".step", ".stp", ".iges", ".igs",
              ".pdf", ".png", ".jpg", ".jpeg", ".tif", ".tiff", ".x_t", ".x_b"}


def watch(folder: str | os.PathLike,
          on_report: Optional[Callable[[AnalysisReport], None]] = None,
          *,
          ctx: Optional[ProjectContext] = None,
          out_dir: str | os.PathLike = "./cf3d_out",
          poll_seconds: float = 1.5,
          stop_after: Optional[int] = None,
          ignore_existing: bool = False) -> None:
    """Block-watch `folder`; whenever a new supported drawing appears
    (with size stable across two polls), run the full pipeline.

    `on_report` is called with the AnalysisReport for each completed run
    and can be used by GUIs to refresh.  Pass `stop_after` (seconds) to
    break out of the loop — useful for tests.
    """
    folder = Path(folder).expanduser().resolve()
    folder.mkdir(parents=True, exist_ok=True)
    log.info("CF3D watcher armed on %s (polling every %.1fs)", folder, poll_seconds)

    seen: dict[Path, int] = {}    # path -> last observed size
    processed: set[Path] = set()
    if ignore_existing:
        for p in _scan(folder):
            processed.add(p)

    started = time.monotonic()
    while True:
        for p in _scan(folder):
            if p in processed:
                continue
            try:
                size = p.stat().st_size
            except FileNotFoundError:
                continue
            if seen.get(p) == size and size > 0:
                _process(p, on_report, ctx, out_dir)
                processed.add(p)
                seen.pop(p, None)
            else:
                seen[p] = size

        if stop_after is not None and (time.monotonic() - started) >= stop_after:
            log.info("Watcher stop_after reached; exiting")
            return
        time.sleep(poll_seconds)


def _scan(folder: Path) -> Iterable[Path]:
    for entry in folder.iterdir():
        if entry.is_file() and entry.suffix.lower() in WATCH_EXTS:
            yield entry


def _process(p: Path,
             on_report: Optional[Callable[[AnalysisReport], None]],
             ctx: Optional[ProjectContext],
             out_dir: str | os.PathLike) -> None:
    log.info("New drawing detected → %s", p.name)
    try:
        rep = analyze(str(p), ctx=ctx, out_dir=out_dir)
        if on_report:
            on_report(rep)
    except Exception:
        log.exception("Pipeline failed on %s", p)
