from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter
from PIL import Image

months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
actual = [120_000, 128_000, 135_000, 141_000, 149_000, 155_000, 162_000, 170_000, 178_000, 187_000, 196_000, 208_000]
planned = [125_000, 130_000, 134_000, 140_000, 148_000, 156_000, 164_000, 171_000, 180_000, 188_000, 198_000, 210_000]
assert len(months) == len(actual) == len(planned) == 12

fig, ax = plt.subplots(figsize=(11, 5.8), layout="constrained")
fig.patch.set_facecolor("#f8fafc")
ax.set_facecolor("#f8fafc")
ax.plot(months, actual, color="#2563eb", marker="o", linewidth=2.5, label="Actual")
ax.plot(
    months,
    planned,
    color="#ea580c",
    marker="s",
    linewidth=2.2,
    linestyle="--",
    label="Planned",
)
ax.set_title("Monthly revenue", loc="left", fontsize=18, fontweight="bold", pad=16)
ax.set_ylabel("Revenue (USD)")
ax.yaxis.set_major_formatter(FuncFormatter(lambda value, _: f"${value / 1_000:.0f}K"))
ax.yaxis.grid(True, color="#cbd5e1", linewidth=0.8, alpha=0.75)
ax.set_axisbelow(True)
ax.spines[["top", "right"]].set_visible(False)
ax.legend(frameon=False, ncols=2, loc="upper left")
ax.set_ylim(110_000, 220_000)
for values, color in ((actual, "#2563eb"), (planned, "#ea580c")):
    ax.annotate(
        f"${values[-1] / 1_000:.0f}K",
        (months[-1], values[-1]),
        xytext=(7, 0),
        textcoords="offset points",
        va="center",
        color=color,
        fontweight="bold",
    )

output_dir = Path("outputs/charts")
output_dir.mkdir(parents=True, exist_ok=True)
png_path = output_dir / "monthly-revenue.png"
svg_path = output_dir / "monthly-revenue.svg"
fig.savefig(png_path, dpi=180, bbox_inches="tight", facecolor=fig.get_facecolor())
fig.savefig(svg_path, bbox_inches="tight", facecolor=fig.get_facecolor())
plt.close(fig)
with Image.open(png_path) as image:
    image.verify()
with Image.open(png_path) as image:
    assert image.format == "PNG" and image.width >= 800 and image.height >= 450
assert svg_path.stat().st_size > 0
print(f"verified {png_path} and {svg_path}")
