from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from PIL import Image

labels = ["Organic search", "Paid social", "Partner referrals", "Email", "Events"]
shares = [35, 25, 20, 15, 5]
assert len(labels) == len(shares) == 5 and sum(shares) == 100
colors = ["#2563eb", "#ea580c", "#16a34a", "#9333ea", "#64748b"]

fig, ax = plt.subplots(figsize=(9.5, 6.2), layout="constrained")
fig.patch.set_facecolor("#f8fafc")
ax.set_facecolor("#f8fafc")
wedges, _, percentages = ax.pie(
    shares,
    colors=colors,
    startangle=90,
    counterclock=False,
    autopct=lambda percentage: f"{percentage:.0f}%",
    pctdistance=0.77,
    wedgeprops={"width": 0.48, "edgecolor": "#f8fafc", "linewidth": 2},
    textprops={"fontsize": 10, "fontweight": "bold", "color": "#0f172a"},
)
ax.set_title("Acquisition mix", loc="left", fontsize=18, fontweight="bold", pad=16)
ax.text(0, 0.04, "100%", ha="center", va="center", fontsize=22, fontweight="bold")
ax.text(0, -0.12, "total share", ha="center", va="center", fontsize=10, color="#475569")
legend_labels = [f"{label} — {share}%" for label, share in zip(labels, shares)]
ax.legend(
    wedges,
    legend_labels,
    loc="center left",
    bbox_to_anchor=(1.0, 0.5),
    frameon=False,
    labelspacing=1.1,
)

output_dir = Path("outputs/charts")
output_dir.mkdir(parents=True, exist_ok=True)
png_path = output_dir / "acquisition-mix.png"
svg_path = output_dir / "acquisition-mix.svg"
fig.savefig(png_path, dpi=180, bbox_inches="tight", facecolor=fig.get_facecolor())
fig.savefig(svg_path, bbox_inches="tight", facecolor=fig.get_facecolor())
plt.close(fig)
with Image.open(png_path) as image:
    image.verify()
with Image.open(png_path) as image:
    assert image.format == "PNG" and image.width >= 800 and image.height >= 450
assert svg_path.stat().st_size > 0
print(f"verified {png_path} and {svg_path}")
