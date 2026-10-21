import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from pathlib import Path
from PIL import Image

categories = [
    "Enterprise platform subscriptions",
    "Professional implementation services",
    "Managed data operations",
    "Security and compliance packages",
    "Analytics and reporting add-ons",
    "Developer productivity extensions",
    "Training and enablement programs",
    "Premium customer support",
]
values = [985000, 870000, 760000, 650000, 540000, 430000, 320000, 210000]

fig, ax = plt.subplots(figsize=(11, 6.5), layout="constrained")
y_pos = range(len(categories))
bars = ax.barh(y_pos, values, color="#3b7dd8", edgecolor="white")
ax.set_yticks(list(y_pos))
ax.set_yticklabels(categories)
ax.invert_yaxis()
ax.set_xlim(0, max(values) * 1.12)
ax.set_xlabel("Revenue (USD)")
ax.xaxis.set_major_formatter(
    plt.FuncFormatter(lambda x, _: f"${x:,.0f}")
)
ax.set_title("Revenue ranking")
ax.text(
    0.0, 1.02,
    "Exact revenue by category",
    transform=ax.transAxes,
    fontsize=11,
    color="#444444",
)
for bar, value in zip(bars, values):
    ax.text(
        bar.get_width() + max(values) * 0.01,
        bar.get_y() + bar.get_height() / 2,
        f"${value:,.0f}",
        va="center",
        ha="left",
        fontsize=10,
    )
ax.spines[["top", "right"]].set_visible(False)
ax.grid(axis="x", linestyle=":", alpha=0.5)

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
