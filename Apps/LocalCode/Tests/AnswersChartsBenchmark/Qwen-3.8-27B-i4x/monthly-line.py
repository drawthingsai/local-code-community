"""Line chart: actual vs planned monthly revenue."""

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from pathlib import Path
from PIL import Image

months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
          "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
actual = [120000, 128000, 135000, 141000, 149000, 155000,
          162000, 170000, 178000, 187000, 196000, 208000]
planned = [125000, 130000, 134000, 140000, 148000, 156000,
           164000, 171000, 180000, 188000, 198000, 210000]

fig, ax = plt.subplots(figsize=(10, 5.5), layout="constrained")
ax.plot(months, actual, marker="o", linewidth=2, color="#1f77b4", label="Actual")
ax.plot(months, planned, marker="s", linewidth=2, color="#d62728",
        linestyle="--", label="Planned")

ax.set_title("Monthly revenue")
ax.set_xlabel("Month")
ax.set_ylabel("Revenue (USD)")
ax.yaxis.set_major_formatter(lambda v, _: f"${v:,.0f}")
ax.grid(True, axis="y", linestyle=":", alpha=0.6)
ax.legend(title="Series")

output_dir = Path("outputs/charts")
output_dir.mkdir(parents=True, exist_ok=True)
png_path = output_dir / "monthly-revenue-actual-vs-planned.png"
svg_path = output_dir / "monthly-revenue-actual-vs-planned.svg"
fig.savefig(png_path, dpi=180, bbox_inches="tight", facecolor=fig.get_facecolor())
fig.savefig(svg_path, bbox_inches="tight", facecolor=fig.get_facecolor())
plt.close(fig)

with Image.open(png_path) as image:
    image.verify()
with Image.open(png_path) as image:
    assert image.format == "PNG" and image.width >= 800 and image.height >= 450
assert svg_path.stat().st_size > 0
print(f"verified {png_path} and {svg_path}")
