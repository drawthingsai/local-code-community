from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter
from PIL import Image

labels = [
    "Enterprise platform subscriptions",
    "Professional implementation services",
    "Managed data operations",
    "Security and compliance packages",
    "Analytics and reporting add-ons",
    "Developer productivity extensions",
    "Training and enablement programs",
    "Premium customer support",
]
values = [985_000, 870_000, 760_000, 650_000, 540_000, 430_000, 320_000, 210_000]
assert len(labels) == len(values) == 8

fig, ax = plt.subplots(figsize=(11.5, 6.4), layout="constrained")
fig.patch.set_facecolor("#f8fafc")
ax.set_facecolor("#f8fafc")
bars = ax.barh(labels, values, color="#2563eb", height=0.66)
ax.invert_yaxis()
ax.set_title("Revenue ranking", loc="left", fontsize=18, fontweight="bold", pad=16)
ax.set_xlabel("Revenue (USD)")
ax.xaxis.set_major_formatter(FuncFormatter(lambda value, _: f"${value / 1_000_000:.1f}M"))
ax.xaxis.grid(True, color="#cbd5e1", linewidth=0.8, alpha=0.75)
ax.set_axisbelow(True)
ax.spines[["top", "right", "left"]].set_visible(False)
ax.tick_params(axis="y", length=0, labelsize=10)
ax.set_xlim(0, 1_100_000)
for bar, value in zip(bars, values):
    ax.text(
        value + 16_000,
        bar.get_y() + bar.get_height() / 2,
        f"${value:,.0f}",
        va="center",
        fontsize=9,
        color="#0f172a",
    )
fig.text(0.01, 0.01, "Exact revenue by category", fontsize=9, color="#475569")

output_dir = Path("outputs/charts")
output_dir.mkdir(parents=True, exist_ok=True)
png_path = output_dir / "revenue-ranking.png"
svg_path = output_dir / "revenue-ranking.svg"
fig.savefig(png_path, dpi=180, bbox_inches="tight", facecolor=fig.get_facecolor())
fig.savefig(svg_path, bbox_inches="tight", facecolor=fig.get_facecolor())
plt.close(fig)
with Image.open(png_path) as image:
    image.verify()
with Image.open(png_path) as image:
    assert image.format == "PNG" and image.width >= 800 and image.height >= 450
assert svg_path.stat().st_size > 0
print(f"verified {png_path} and {svg_path}")
