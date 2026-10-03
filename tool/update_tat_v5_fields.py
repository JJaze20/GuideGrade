"""Update v5 name cells and move other information to a reverse page.

Preserves the original answer and marker drawing commands verbatim.
"""
from io import BytesIO
import json
from pathlib import Path

from pypdf import PdfReader, PdfWriter
from pypdf.generic import DecodedStreamObject, NameObject
from reportlab.pdfgen import canvas

ROOT = Path(__file__).resolve().parents[1]
PDF = ROOT / 'answer_sheets/TAT-portrait-v5.pdf'
GEOMETRY = ROOT / 'tool/data/TAT-portrait-v5.geometry.json'
WIDTH, HEIGHT = 612, 936


def cell(c, label, x, top, width, height=32):
    c.setStrokeColorRGB(0, 0, 0)
    c.setFillColorRGB(0, 0, 0)
    c.setLineWidth(.5)
    c.rect(x, HEIGHT - top - height, width, height)
    c.line(x, HEIGHT - top - 10, x + width, HEIGHT - top - 10)
    c.setFont('Helvetica', 6)
    c.drawString(x + 3, HEIGHT - top - 7, label)
    return dict(name=label, x=x, y=top + 10, width=width, height=height - 10)


def update():
    reader = PdfReader(BytesIO(PDF.read_bytes()))
    if len(reader.pages) == 2 and 'Middle Name' in reader.pages[0].extract_text():
        print('TAT v5 fields already updated')
        return
    original = reader.pages[0].get_contents().get_data()
    start = original.index(b'0 0 0 RG\n.5 w\nn 48 808 ')
    end = original.index(b'0 0 0 rg\nBT /F1 7 Tf 8.4 TL ET\nBT 1 0 0 1 420.6810 760 Tm')
    front_buffer = BytesIO()
    c = canvas.Canvas(front_buffer, pagesize=(WIDTH, HEIGHT))
    fields = [cell(c, 'Last Name', 48, 96, 210),
              cell(c, 'First Name', 258, 96, 150),
              cell(c, 'Middle Name', 408, 96, 150)]
    c.save()
    replacement = PdfReader(front_buffer).pages[0].get_contents().get_data()
    updated = original[:start] + replacement + original[end:]
    writer = PdfWriter()
    writer.add_page(reader.pages[0])
    stream = DecodedStreamObject()
    stream.set_data(updated)
    writer.pages[0][NameObject('/Contents')] = writer._add_object(stream)

    back_buffer = BytesIO()
    c = canvas.Canvas(back_buffer, pagesize=(WIDTH, HEIGHT))
    c.setFillColorRGB(.082353, .227451, .521569)
    c.setFont('Helvetica-Bold', 10)
    c.drawString(48, HEIGHT - 59, 'Additional Information')
    back_fields = [cell(c, 'School Last Attended', 48, 76, 510),
                   cell(c, 'Address of School Last Attended', 48, 114, 510, 38),
                   cell(c, 'Date Today', 48, 158, 255),
                   cell(c, 'Birth Date', 303, 158, 255),
                   cell(c, 'Age', 48, 196, 150),
                   cell(c, 'Sex', 198, 196, 360)]
    c.setFont('Helvetica', 7)
    c.drawString(201, HEIGHT - 219, 'M ( )  F ( )')
    c.save()
    writer.add_page(PdfReader(back_buffer).pages[0])
    writer.pages[0].compress_content_streams()
    output = BytesIO()
    writer.write(output)
    check = PdfReader(BytesIO(output.getvalue()))
    assert len(check.pages) == 2
    assert check.pages[0].get_contents().get_data() == updated
    assert check.pages[0].get_contents().get_data().endswith(original[end:])
    assert 'M.I.' not in check.pages[0].extract_text()
    assert fields[1]['width'] == fields[2]['width']
    PDF.write_bytes(output.getvalue())
    geometry = json.loads(GEOMETRY.read_text())
    geometry['fields'] = fields
    geometry['backFields'] = back_fields
    GEOMETRY.write_text(json.dumps(geometry, indent=2) + '\n')
    print('Updated two-page v5 sheet; answer and fiducial commands preserved.')


if __name__ == '__main__':
    update()
