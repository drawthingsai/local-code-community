---
name: answers-charts
description: Create polished data charts as inline images with bundled Python and Matplotlib. Use for bar, line, pie, scatter, and other data-backed plots shown directly in the answer.
---

# Create Charts with Matplotlib

Use the bundled Python runtime with Matplotlib 3.11.1 and Pillow 12.3.0. Do not install packages or use the network.

## Build the chart

- Preserve the supplied labels, ordering, units, and values exactly. Never add observations or silently repair data.
- Put one reusable script at `outputs/chart_task.py`. Write final charts under `outputs/charts/` with descriptive, stable filenames.
- Set the non-interactive backend before importing pyplot:

  ```python
  import matplotlib
  matplotlib.use("Agg")
  import matplotlib.pyplot as plt
  ```

- Prefer `fig, ax = plt.subplots(...)`, `layout="constrained"`, and explicit figure dimensions. Keep labels readable, legends unambiguous, and decoration restrained.
- Use horizontal bars for rankings with long labels, lines for ordered time series, pie or donut charts only for a small part-to-whole set, and scatter plots for paired numeric observations.
- Format axes and annotations in the user's units. Avoid misleading truncated axes for bars, overlapping labels, 3D effects, and color-only distinctions between multiple series.
- Add concise titles and useful axis labels. Annotate exact values when that improves reading without clutter.
- For a mathematical function without a domain, resolution, or permission to choose them, ask for those inputs instead of inventing samples. Keep the clarification brief and ask only for the missing inputs.

## Export and verify

Save both a high-resolution PNG for the answer and an SVG for reuse:

```python
from pathlib import Path
from PIL import Image

output_dir = Path("outputs/charts")
output_dir.mkdir(parents=True, exist_ok=True)
png_path = output_dir / "descriptive-name.png"
svg_path = output_dir / "descriptive-name.svg"
fig.savefig(png_path, dpi=180, bbox_inches="tight", facecolor=fig.get_facecolor())
fig.savefig(svg_path, bbox_inches="tight", facecolor=fig.get_facecolor())
plt.close(fig)

with Image.open(png_path) as image:
    image.verify()
with Image.open(png_path) as image:
    assert image.format == "PNG" and image.width >= 800 and image.height >= 450
assert svg_path.stat().st_size > 0
print(f"verified {png_path} and {svg_path}")
```

Run the project script with the bundled interpreter through Bash:

```sh
python3 outputs/chart_task.py
```

Bash starts in the selected project directory, so keep input/output paths project-relative. Do not change directories, search for Python installations or app bundles, or set `PYTHONPATH`. If the bundled runtime fails, report the actual error instead of probing host paths or other projects.

Before finishing, confirm the script completed successfully, both files exist and are nonempty, Pillow reopened the PNG, and the plotted series have the same counts and values as the source data.

## Show the result inline

Place the PNG on its own line in the final answer using a project-relative Markdown image path:

```markdown
![Concise description of the chart](outputs/charts/descriptive-name.png)
```

Do not use an absolute path or `file://` URL. Briefly summarize the chart and verification, then optionally link the SVG separately for download or editing.
