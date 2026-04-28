"""CF3D Analyzer — professional-grade drawing-to-3D analyzer with composite
process advisory tuned for high-precision carbon fiber parts.

Public surface:
    analyze(path)            -> AnalysisReport
    watch(folder, on_report) -> blocking folder watcher
"""
from .pipeline import analyze, analyze_drawing
from .watcher import watch
from .report import AnalysisReport

__all__ = ["analyze", "analyze_drawing", "watch", "AnalysisReport"]
__version__ = "1.0.0"
