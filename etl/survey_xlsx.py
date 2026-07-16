#!/usr/bin/env python3
"""Survey every .xlsx under /xlsx: sheets, dimensions, and the first rows,
so we can classify tabular data vs. document-style sheets before loading."""
import glob, openpyxl

def cell_str(v):
    if v is None: return ""
    s = str(v).replace("\n", "\\n")
    return s[:38] + "…" if len(s) > 38 else s

for path in sorted(glob.glob("/xlsx/*.xlsx")):
    print(f"\n{'='*100}\nFILE: {path.split('/')[-1]}")
    try:
        wb = openpyxl.load_workbook(path, read_only=True, data_only=True)
    except Exception as e:
        print(f"  !! cannot open: {e}"); continue
    for ws in wb.worksheets:
        vis = "" if ws.sheet_state == "visible" else f" [{ws.sheet_state}]"
        print(f"\n  SHEET: {ws.title!r}{vis}  dims={ws.calculate_dimension()} "
              f"rows={ws.max_row} cols={ws.max_column}")
        for i, row in enumerate(ws.iter_rows(min_row=1, max_row=4, max_col=12, values_only=True)):
            cells = [cell_str(v) for v in row]
            while cells and cells[-1] == "": cells.pop()
            print(f"    r{i+1}: {cells}")
    wb.close()
