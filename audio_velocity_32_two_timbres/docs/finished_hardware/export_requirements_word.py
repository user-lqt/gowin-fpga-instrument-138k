"""Export the team's requirements status Markdown as a readable Word report."""

from pathlib import Path
import re
import argparse

from docx import Document
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Cm, Pt, RGBColor
from docx.enum.table import WD_CELL_VERTICAL_ALIGNMENT


ROOT = Path(__file__).parent
parser = argparse.ArgumentParser()
parser.add_argument("--source", type=Path, default=ROOT / "requirements_completion_status.md")
parser.add_argument("--output", type=Path, default=ROOT / "赛题二要求完成情况_详细执行版.docx")
args = parser.parse_args()
SOURCE = args.source
OUTPUT = args.output
doc = Document()
section = doc.sections[0]
section.page_width = Cm(29.7)
section.page_height = Cm(21)
section.top_margin = section.bottom_margin = Cm(1.5)
section.left_margin = section.right_margin = Cm(1.7)

for name, size in (("Normal", 10), ("Title", 21), ("Heading 1", 15), ("Heading 2", 12)):
    style = doc.styles[name]
    style.font.name = "Microsoft YaHei"
    style.font.size = Pt(size)
    style.font.color.rgb = RGBColor(0, 0, 0)
    style.element.get_or_add_rPr().rFonts.set(qn("w:eastAsia"), "Microsoft YaHei")
    style.paragraph_format.space_after = Pt(6)
doc.styles["Normal"].paragraph_format.line_spacing = 1.15


def table(rows):
    result = doc.add_table(rows=0, cols=len(rows[0]))
    result.autofit = False
    widths = {4: [5.2, 7.7, 5.0, 8.4], 3: [5.2, 10.2, 10.9]}.get(
        len(rows[0]), [26.3 / len(rows[0])] * len(rows[0])
    )
    for column, width in zip(result.columns, widths):
        column.width = Cm(width)
    for index, values in enumerate(rows):
        cells = result.add_row().cells
        for column, value in enumerate(values):
            cell = cells[column]
            cell.width = Cm(widths[column])
            cell.vertical_alignment = WD_CELL_VERTICAL_ALIGNMENT.CENTER
            p = cell.paragraphs[0]
            p.paragraph_format.space_after = Pt(4)
            p.paragraph_format.space_before = Pt(4)
            run = p.add_run(value)
            run.font.size = Pt(9)
            run.bold = index == 0
            properties = cell._tc.get_or_add_tcPr()
            shading = OxmlElement("w:shd")
            shading.set(qn("w:fill"), "E7EDF3" if index == 0 else ("F7F7F7" if index % 2 == 0 else "FFFFFF"))
            properties.append(shading)
            borders = OxmlElement("w:tcBorders")
            for edge in ("top", "left", "bottom", "right"):
                border = OxmlElement("w:" + edge)
                for key, val in (("val", "single"), ("sz", "4"), ("color", "D9D9D9")):
                    border.set(qn("w:" + key), val)
                borders.append(border)
            properties.append(borders)
        if index == 0:
            repeat = OxmlElement("w:tblHeader")
            result.rows[index]._tr.get_or_add_trPr().append(repeat)
        no_split = OxmlElement("w:cantSplit")
        result.rows[index]._tr.get_or_add_trPr().append(no_split)
    doc.add_paragraph()


lines = SOURCE.read_text(encoding="utf-8").splitlines()
title = next(line[2:] for line in lines if line.startswith("# "))
i = 0
while i < len(lines):
    line = lines[i].strip()
    if line.startswith("|"):
        rows = []
        while i < len(lines) and lines[i].strip().startswith("|"):
            cells = [c.strip() for c in lines[i].strip().strip("|").split("|")]
            if not all(re.fullmatch(r":?-+:?", c) for c in cells):
                rows.append(cells)
            i += 1
        table(rows)
        continue
    if line.startswith("# "):
        doc.add_paragraph(line[2:], style="Title")
    elif line.startswith("## "):
        doc.add_heading(line[3:], level=1)
    elif line.startswith("### "):
        doc.add_heading(line[4:], level=2)
    elif re.match(r"^\d+[A-Z]? ", line):
        doc.add_heading(line, level=1)
    elif line.startswith("- "):
        doc.add_paragraph(line[2:], style="List Bullet")
    elif line and line != "---":
        doc.add_paragraph(line.lstrip("> ").replace("**", "").replace("`", ""))
    i += 1

doc.core_properties.title = title
doc.core_properties.subject = "基础要求 拓展目标 硬件进度与成员分工"
doc.save(OUTPUT)
check = Document(OUTPUT)
assert len(check.tables) == sum(
    line.startswith("|") and (index == 0 or not lines[index - 1].startswith("|"))
    for index, line in enumerate(lines)
)
assert check.paragraphs[0].text == title
assert all(len(row.cells) == len(t.columns) for t in check.tables for row in t.rows)
print(OUTPUT)
print(f"Verified: {len(check.paragraphs)} paragraphs, {len(check.tables)} tables")
