import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from pathlib import Path
from PIL import Image

labels = ["Organic search", "Paid social", "Partner referrals", "Email", "Events"]
values = [35, 25, 20, 15, 5]
assert sum(values) == 100

colors = ["#4C72B0", "#DD8452", "#55A868", "#C44E52", "#8172B3"]

fig, ax = plt.subplots(figsize=(8, 5.5), layout="constrained")
wedges, texts, autotexts = ax.pie(
    values,
    labels=labels,
    colors=colors,
    autopct="%d%%",
    startangle=90,
    counterclock=False,
    pctdistance=0.72,
    labeldistance=1.12,
    wedgeprops={"edgecolor": "white", "linewidth": 1.5},
    textprops={"fontsize": 11},
)
for at in autotexts:
    at.set_color("white")
    at.set_fontweight("bold")
    at.set_fontsize(11)

ax.set_title("Acquisition mix", fontsize=16, fontweight="bold", pad=18)
fig.text(
    0.5,
    0.02,
    "Channel shares total 100%.",
    ha="center",
    fontsize=10,
    color="#555555",
)

output_dir = Path("outputs/charts")
output_dir.mkdir(parents=True, exist_ok=True)
png_path = output_dir / "acquisition-mix-pie.png"
svg_path = output_dir / "acquisition-mix-pie.svg"
fig.savefig(png_path, dpi=180, bbox_inches="tight", facecolor=fig.get_facecolor())
fig.savefig(svg_path, bbox_inches="tight", facecolor=fig.get_facecolor())
plt.close(fig)

with Image.open(png_path) as image:
    image.verify()
with Image.open(png_path) as image:
    assert image.format == "PNG" and image.width >= 800 and image.height >= 450
assert svg_path.stat().st_size > 0
print(f"verified {png_path} and {svg_path}")
