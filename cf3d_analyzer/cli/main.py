"""Standalone command-line interface."""
from __future__ import annotations

import argparse
import json
import logging
import sys
from pathlib import Path

from .. import __version__
from ..pipeline import analyze
from ..process_advisor import ProjectContext
from ..watcher import watch


def _common(p: argparse.ArgumentParser) -> None:
    p.add_argument("--annual-volume", type=int, default=200,
                   help="Annual production volume (parts/yr)")
    p.add_argument("--quality", choices=["A", "B", "C"], default="A",
                   help="Required surface quality grade")
    p.add_argument("--application",
                   choices=["structural", "cosmetic", "pressure"],
                   default="structural")
    p.add_argument("--matrix",
                   choices=["epoxy", "bmi", "thermoplastic"],
                   default="epoxy")
    p.add_argument("--cycle", type=float, default=None,
                   help="Target cycle time (minutes); biases recommendation")
    p.add_argument("--cost", type=float, default=None,
                   help="Target unit cost (USD); biases recommendation")
    p.add_argument("--top", type=int, default=3,
                   help="Top N processes to return")
    p.add_argument("--out", default="./cf3d_out",
                   help="Output directory for artefacts")
    p.add_argument("--no-moldflow", action="store_true")
    p.add_argument("--no-multiview", action="store_true")
    p.add_argument("--no-explode", action="store_true")
    p.add_argument("-v", "--verbose", action="store_true")


def _ctx(args: argparse.Namespace) -> ProjectContext:
    return ProjectContext(
        annual_volume=args.annual_volume,
        quality_grade=args.quality,
        target_unit_cost=args.cost,
        fiber_system="carbon",
        matrix_class=args.matrix,
        application=args.application,
        cycle_time_target_min=args.cycle,
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="cf3d",
        description=("CF3D Analyzer — drawing → 3D model → composite "
                     "process recommendation for high-precision carbon fiber parts"),
    )
    parser.add_argument("--version", action="version",
                        version=f"cf3d {__version__}")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_analyze = sub.add_parser("analyze",
                                help="Analyse a single drawing now")
    p_analyze.add_argument("drawing", help="Path to drawing")
    _common(p_analyze)

    p_watch = sub.add_parser("watch",
                              help="Watch a folder and analyse new drawings")
    p_watch.add_argument("folder", help="Folder to watch")
    p_watch.add_argument("--ignore-existing", action="store_true",
                          help="Skip files already in the folder at startup")
    p_watch.add_argument("--poll", type=float, default=1.5,
                          help="Poll interval in seconds")
    _common(p_watch)

    p_gui = sub.add_parser("gui", help="Launch the desktop GUI")

    args = parser.parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if getattr(args, "verbose", False) else logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )

    if args.cmd == "analyze":
        ctx = _ctx(args)
        rep = analyze(args.drawing, ctx=ctx, out_dir=args.out,
                      top_n=args.top,
                      run_moldflow=not args.no_moldflow,
                      run_multiview=not args.no_multiview,
                      run_ply_explode=not args.no_explode)
        print(json.dumps({
            "report_json": str(Path(args.out) / f"{Path(args.drawing).stem}.report.json"),
            "top_process": rep.recommendations[0]["process"]
                            if rep.recommendations else None,
            "fitness": rep.recommendations[0]["fitness"]
                        if rep.recommendations else None,
            "artefacts": rep.artefacts,
        }, indent=2, ensure_ascii=False))
        return 0

    if args.cmd == "watch":
        ctx = _ctx(args)
        watch(args.folder, ctx=ctx, out_dir=args.out,
              poll_seconds=args.poll,
              ignore_existing=args.ignore_existing)
        return 0

    if args.cmd == "gui":
        from ..gui import launch
        launch()
        return 0

    parser.error(f"Unknown command {args.cmd}")
    return 2


if __name__ == "__main__":
    sys.exit(main())
