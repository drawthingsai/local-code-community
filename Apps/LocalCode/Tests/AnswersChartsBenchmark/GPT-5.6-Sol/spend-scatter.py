from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter
from PIL import Image

ad_spend = [10_000, 14_000, 18_000, 22_000, 26_000, 30_000, 34_000, 38_000, 42_000, 46_000]
revenue = [72_000, 88_000, 97_000, 121_000, 134_000, 151_000, 165_000, 181_000, 190_000, 214_000]
assert len(ad_spend) == len(revenue) == 10

fig, ax = plt.subplots(figsize=(10, 6), layout="constrained")
fig.patch.set_facecolor("#f8fafc")
ax.set_facecolor("#f8fafc")
ax.scatter(
    ad_spend,
    revenue,
    s=82,
    color="#2563eb",
    edgecolor="white",
    linewidth=1.2,
    zorder=3,
)
ax.set_title("Ad spend vs revenue", loc="left", fontsize=18, fontweight="bold", pad=16)
ax.set_xlabel("Ad spend (USD)")
ax.set_ylabel("Revenue (USD)")
currency_thousands = FuncFormatter(lambda value, _: f"${value / 1_000:.0f}K")
ax.xaxis.set_major_formatter(currency_thousands)
ax.yaxis.set_major_formatter(currency_thousands)
ax.grid(True, color="#cbd5e1", linewidth=0.8, alpha=0.75)
ax.set_axisbelow(True)
ax.spines[["top", "right"]].set_visible(False)
ax.set_xlim(7_000, 49_000)
ax.set_ylim(60_000, 225_000)
ax.text(
    0.01,
    0.98,
    "10 exact observations • no trend line",
    transform=ax.transAxes,
    va="top",
    fontsize=9,
    color="#475569",
)

output_dir = Path("outputs/charts")
output_dir.mkdir(parents=True, exist_ok=True)
png_path = output_dir / "ad-spend-vs-revenue.png"
svg_path = output_dir / "ad-spend-vs-revenue.svg"
fig.savefig(png_path, dpi=180, bbox_inches="tight", facecolor=fig.get_facecolor())
fig.savefig(svg_path, bbox_inches="tight", facecolor=fig.get_facecolor())
plt.close(fig)
with Image.open(png_path) as image:
    image.verify()
with Image.open(png_path) as image:
    assert image.format == "PNG" and image.width >= 800 and image.height >= 450
assert svg_path.stat().st_size > 0
print(f"verified {png_path} and {svg_path}")
