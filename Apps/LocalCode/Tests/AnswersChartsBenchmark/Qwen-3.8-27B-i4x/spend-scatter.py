import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from pathlib import Path
from PIL import Image

# (ad spend, revenue) in dollars, exactly as supplied
data = [
    (10000, 72000),
    (14000, 88000),
    (18000, 97000),
    (22000, 121000),
    (26000, 134000),
    (30000, 151000),
    (34000, 165000),
    (38000, 181000),
    (42000, 190000),
    (46000, 214000),
]

spend = [d[0] for d in data]
revenue = [d[1] for d in data]

fig, ax = plt.subplots(figsize=(9, 5.5), layout="constrained")
ax.scatter(spend, revenue, s=70, color="#2563eb", edgecolor="white", linewidth=1.2, zorder=3)

ax.set_title("Ad spend vs revenue", fontsize=15, fontweight="bold", pad=14)
ax.set_xlabel("Ad spend (USD)")
ax.set_ylabel("Revenue (USD)")

ax.xaxis.set_major_formatter(lambda x, _: f"${x:,.0f}")
ax.yaxis.set_major_formatter(lambda x, _: f"${x:,.0f}")
ax.grid(True, linestyle="--", alpha=0.4, zorder=0)
ax.set_axisbelow(True)

for x, y in data:
    ax.annotate(f"${y/1000:.0f}k", (x, y), textcoords="offset points",
                xytext=(0, 9), ha="center", fontsize=8, color="#334155")

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
