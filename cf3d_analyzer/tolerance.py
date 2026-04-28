"""GD&T tolerance harvesting and capability check.

Pulls dimensional callouts from drawing annotations, normalizes them
into a TolerancePlan, and returns process-capability findings.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field

from .data.process_kb import ProcessEnvelope
from .ingest import DrawingPackage


@dataclass
class ToleranceCallout:
    nominal_mm: float
    plus_mm: float
    minus_mm: float
    raw_text: str

    @property
    def total_band_mm(self) -> float:
        return abs(self.plus_mm) + abs(self.minus_mm)


_DIM_PATTERN = re.compile(
    r"([0-9]+\.?[0-9]*)\s*"
    r"(?:\+\s*([0-9]+\.?[0-9]*))?\s*"
    r"(?:[-/]\s*([0-9]+\.?[0-9]*))?",
)


@dataclass
class TolerancePlan:
    callouts: list[ToleranceCallout] = field(default_factory=list)

    @property
    def tightest_band_mm(self) -> float:
        if not self.callouts:
            return float("inf")
        return min(c.total_band_mm for c in self.callouts if c.total_band_mm > 0)

    def fits(self, proc: ProcessEnvelope) -> bool:
        return self.tightest_band_mm >= proc.dimensional_tolerance_mm * 2


def harvest(pkg: DrawingPackage) -> TolerancePlan:
    out: list[ToleranceCallout] = []
    for a in pkg.annotations:
        if a.kind != "dimension":
            continue
        text = a.text.strip()
        m = _DIM_PATTERN.search(text)
        if not m:
            continue
        try:
            nominal = float(m.group(1))
        except ValueError:
            continue
        plus = float(m.group(2)) if m.group(2) else 0.05
        minus = float(m.group(3)) if m.group(3) else plus
        out.append(ToleranceCallout(nominal, plus, minus, text))
    return TolerancePlan(callouts=out)
