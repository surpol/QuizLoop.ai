from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.enums import TA_LEFT
from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import inch
from reportlab.platypus import ListFlowable, ListItem, Paragraph, SimpleDocTemplate, Spacer


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "docs" / "kaggle-report.md"
OUTPUT = ROOT / "docs" / "QuizLoop-Kaggle-Report.pdf"


def inline(text: str) -> str:
    return (
        text.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace("QuizLoop.ai", "<b>QuizLoop.ai</b>")
        .replace("Gemma 4", "<b>Gemma 4</b>")
        .replace("SQLite", "<b>SQLite</b>")
        .replace("Ollama", "<b>Ollama</b>")
    )


def build():
    styles = getSampleStyleSheet()
    title = ParagraphStyle(
        "ReportTitle",
        parent=styles["Title"],
        fontName="Helvetica-Bold",
        fontSize=24,
        leading=28,
        alignment=TA_LEFT,
        textColor=colors.HexColor("#202124"),
        spaceAfter=10,
    )
    subtitle = ParagraphStyle(
        "Subtitle",
        parent=styles["BodyText"],
        fontName="Helvetica",
        fontSize=10.5,
        leading=15,
        textColor=colors.HexColor("#5f6368"),
        spaceAfter=12,
    )
    heading = ParagraphStyle(
        "Heading",
        parent=styles["Heading2"],
        fontName="Helvetica-Bold",
        fontSize=13.5,
        leading=17,
        textColor=colors.HexColor("#1a73e8"),
        spaceBefore=10,
        spaceAfter=6,
    )
    body = ParagraphStyle(
        "Body",
        parent=styles["BodyText"],
        fontName="Helvetica",
        fontSize=10,
        leading=14,
        textColor=colors.HexColor("#202124"),
        spaceAfter=7,
    )
    bullet_style = ParagraphStyle(
        "Bullet",
        parent=body,
        leftIndent=0,
        firstLineIndent=0,
        spaceAfter=4,
    )

    story = []
    bullet_items = []

    def flush_bullets():
        nonlocal bullet_items
        if bullet_items:
            story.append(
                ListFlowable(
                    [ListItem(Paragraph(inline(item), bullet_style), leftIndent=12) for item in bullet_items],
                    bulletType="bullet",
                    leftIndent=18,
                    bulletFontName="Helvetica",
                    bulletFontSize=8,
                    bulletColor=colors.HexColor("#1a73e8"),
                )
            )
            story.append(Spacer(1, 4))
            bullet_items = []

    for raw in SOURCE.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line:
            flush_bullets()
            continue
        if line.startswith("# "):
            flush_bullets()
            story.append(Paragraph(inline(line[2:]), title))
            continue
        if line.startswith("Subtitle:") or line.startswith("Track:"):
            flush_bullets()
            story.append(Paragraph(inline(line), subtitle))
            continue
        if line.startswith("## "):
            flush_bullets()
            story.append(Paragraph(inline(line[3:]), heading))
            continue
        if line.startswith("- "):
            bullet_items.append(line[2:])
            continue
        flush_bullets()
        story.append(Paragraph(inline(line), body))

    flush_bullets()

    doc = SimpleDocTemplate(
        str(OUTPUT),
        pagesize=letter,
        rightMargin=0.72 * inch,
        leftMargin=0.72 * inch,
        topMargin=0.65 * inch,
        bottomMargin=0.65 * inch,
        title="QuizLoop.ai Kaggle Report",
        author="Surya",
    )
    doc.build(story)
    print(OUTPUT)


if __name__ == "__main__":
    build()
