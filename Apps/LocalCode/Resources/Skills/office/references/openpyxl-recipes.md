# openpyxl authoring recipes

Adapt these patterns to the requested workbook. Keep output in the selected project and avoid overwriting by default.

## Create an auditable workbook

```python
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill

book = Workbook()
inputs = book.active
inputs.title = "Inputs"
inputs.append(["Month", "Units", "Price"])
inputs.append(["2026-01", 120, 19.5])

summary = book.create_sheet("Summary")
summary.append(["Month", "Revenue"])
summary["A2"] = "='Inputs'!A2"
summary["B2"] = "='Inputs'!B2*'Inputs'!C2"
summary["B2"].number_format = '"$"#,##0.00'

for sheet in (inputs, summary):
    for cell in sheet[1]:
        cell.font = Font(bold=True, color="FFFFFF")
        cell.fill = PatternFill("solid", fgColor="24527A")

book.save("outputs/revenue-model.xlsx")
```

Do not hardcode a computed result beside its formula. openpyxl does not calculate formulas; a workbook application may calculate them when opened.

## Preserve an existing workbook

```python
from copy import copy
from openpyxl import load_workbook

book = load_workbook("inputs/source.xlsx", data_only=False)
sheet = book["Data"]
source = sheet["D2"]
target = sheet["D3"]
target.value = "=B3*C3"
target._style = copy(source._style)
target.number_format = source.number_format
target.alignment = copy(source.alignment)
target.protection = copy(source.protection)
book.save("outputs/source-edited.xlsx")
```

Before editing, inspect merged ranges, conditional formatting, data validation, tables, named ranges, row heights, column widths, freeze panes, and chart references. Extend only structures affected by the requested rows or columns. `insert_rows` moves cells but does not rewrite table ranges, conditional-formatting ranges, formulas, or chart references. Update affected `table.ref` values, remove and re-add affected conditional-formatting rules at their new ranges, and set chart series reference strings such as `series.cat.numRef.f` and `series.val.numRef.f` explicitly. Reopen the output and compare the requested original cells and layout properties with the source. For macro-enabled workbooks, use `keep_vba=True` and preserve the original extension.

## Add a native chart

```python
from openpyxl.chart import BarChart, Reference

chart = BarChart()
chart.type = "col"
chart.title = "Revenue by month"
chart.y_axis.title = "Revenue (USD)"
chart.x_axis.title = "Month"
values = Reference(summary, min_col=2, min_row=1, max_row=13)
categories = Reference(summary, min_col=1, min_row=2, max_row=13)
chart.add_data(values, titles_from_data=True)
chart.set_categories(categories)
summary.add_chart(chart, "D2")
```

Keep the source table visible. After reopening, inspect the chart's series references and confirm they cover the intended rows. This is structural validation, not a visual render.

## CSV and TSV

Use explicit delimiters and dtypes for identifiers:

```python
import pandas as pd

frame = pd.read_csv(
    "inputs/orders.tsv",
    sep="\t",
    dtype={"order_id": "string", "account_id": "string"},
    keep_default_na=True,
)
# Apply only the requested transformations.
frame.to_csv("outputs/orders-clean.tsv", sep="\t", index=False, lineterminator="\n")
check = pd.read_csv(
    "outputs/orders-clean.tsv",
    sep="\t",
    dtype={"order_id": "string", "account_id": "string"},
    keep_default_na=True,
)
assert list(check.columns) == list(frame.columns)
assert check.shape == frame.shape
```

Choose missing-value, date, quoting, encoding, and numeric parsing rules deliberately. A blank value used as zero for one calculation does not need to be rewritten as zero in the exported source column.
