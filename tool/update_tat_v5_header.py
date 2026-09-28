"""Move the v5 TAT title above the letterhead and remove its border.

Run from the repository root: python tool/update_tat_v5_header.py
Requires pypdf and reportlab. The v5 sheet is a checked-in vector PDF, not
an output of generate_sheets.dart. Only two known drawing commands change;
all other content bytes (including bubbles and fiducials) are preserved.
"""
from io import BytesIO
from pathlib import Path

from pypdf import PdfReader, PdfWriter
from pypdf.generic import DecodedStreamObject, NameObject
from reportlab.pdfbase.pdfmetrics import stringWidth


def update(path: Path):
    reader = PdfReader(BytesIO(path.read_bytes()))
    page = reader.pages[0]
    content = page.get_contents().get_data()
    border = b'n 48 844 510 46 re S'
    old_transform = b'0 -1 1 0 584 832 cm'
    title = 'TEACHING APTITUDE TEST (TAT)'
    # Center over the existing 48..558pt letterhead, baseline 40pt from top.
    x = 303 - stringWidth(title, 'Helvetica-Bold', 10) / 2
    new_transform = f'1 0 0 1 {x:.4f} 896 cm'.encode('ascii')
    if border not in content and new_transform in content:
        print('TAT v5 header already updated')
        return
    assert content.count(border) == 1, 'Unexpected TAT letterhead border'
    assert content.count(old_transform) == 1, 'Unexpected TAT title transform'
    # Do not perform a general PDF re-layout or rasterize the sheet.
    updated = content.replace(border, b'').replace(old_transform, new_transform)
    stream = DecodedStreamObject()
    stream.set_data(updated)
    writer = PdfWriter()
    writer.append(reader)
    writer.pages[0][NameObject('/Contents')] = writer._add_object(stream)
    writer.pages[0].compress_content_streams()
    output = BytesIO()
    writer.write(output)
    check = PdfReader(BytesIO(output.getvalue())).pages[0].get_contents().get_data()
    assert check == updated
    path.write_bytes(output.getvalue())
    print('Updated TAT v5 title and letterhead border; other drawing commands unchanged')


if __name__ == '__main__':
    update(Path(__file__).resolve().parents[1] / 'answer_sheets/TAT-portrait-v5.pdf')
