#!/usr/bin/env python3
"""Replay a trusted chart script in a fresh project and inspect the saved artists.

Usage: python3 inspect_chart.py outputs/chart_task.py inspection.json
Run through StaticInlinePythonMacOS for the embedded Python runtime used by agents.
Never replay in the original benchmark project: keep its evidence unchanged.
"""

import hashlib
import json
import runpy
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
from matplotlib.figure import Figure
from matplotlib.patches import Wedge
from PIL import Image, __version__ as pillow_version


def inspect_axes(ax):
    legend = ax.get_legend()
    return {
        "titles": [ax.get_title(loc=loc) for loc in ("left", "center", "right")],
        "xlabel": ax.get_xlabel(), "ylabel": ax.get_ylabel(),
        "xscale": ax.get_xscale(), "yscale": ax.get_yscale(),
        "xticks": [t.get_text() for t in ax.get_xticklabels()],
        "yticks": [t.get_text() for t in ax.get_yticklabels()],
        "texts": [t.get_text() for t in ax.texts],
        "legend": [t.get_text() for t in legend.get_texts()] if legend else [],
        "bars": [
            {"orientation": container.orientation,
             "values": [float(v) for v in container.datavalues]}
            for container in ax.containers if hasattr(container, "datavalues")
        ],
        "lines": [
            {"label": line.get_label(), "x": line.get_xdata(orig=True).tolist(),
             "y": line.get_ydata(orig=True).tolist()}
            for line in ax.lines
        ],
        "scatter": [collection.get_offsets().tolist() for collection in ax.collections],
        "pie_percentages": [
            (wedge.theta2 - wedge.theta1) / 3.6
            for wedge in ax.patches if isinstance(wedge, Wedge)
        ],
    }


def main():
    script_path, report_path = (Path(p).resolve() for p in sys.argv[1:])
    figures = []
    original_savefig = Figure.savefig

    def savefig(fig, filename, *args, **kwargs):
        original_savefig(fig, filename, *args, **kwargs)
        path = Path(filename)
        if path.suffix.lower() != ".png":
            return
        with Image.open(path) as image:
            image.verify()
        with Image.open(path) as image:
            size = list(image.size)
        figures.append({
            "png": {"name": path.name, "size": size,
                    "sha256": hashlib.sha256(path.read_bytes()).hexdigest()},
            "axes": [inspect_axes(ax) for ax in fig.axes],
        })

    Figure.savefig = savefig
    try:
        sys.argv = [str(script_path)]
        runpy.run_path(str(script_path), run_name="__main__")
    finally:
        Figure.savefig = original_savefig
    report = {
        "runtime": {"python": sys.version, "matplotlib": matplotlib.__version__,
                    "pillow": pillow_version, "backend": matplotlib.get_backend()},
        "script_sha256": hashlib.sha256(script_path.read_bytes()).hexdigest(),
        "figures": figures,
    }
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
