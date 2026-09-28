"""Move the v5 TAT title beside the pencil instruction and remove its border.

Run from the repository root: python tool/update_tat_v5_header.py
Requires pypdf and reportlab. The v5 sheet is a checked-in vector PDF, not
an output of generate_sheets.dart. Only the title, instruction and border change;
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
    rotated_transform = b'0 -1 1 0 584 832 cm'
    title = 'TEACHING APTITUDE TEST (TAT)'
    width = stringWidth(title, 'Helvetica-Bold', 10)
    above_header_transform = f'1 0 0 1 {303 - width / 2:.4f} 896 cm'.encode('ascii')
    right_title_transform = f'1 0 0 1 {558 - width:.4f} 760 cm'.encode('ascii')
    # Title on the left; pencil instruction right-aligned on the same baseline.
    new_transform = b'1 0 0 1 48 760 cm'
    instruction = 'Use a No. 2 pencil. Fill the circle completely.'
    instruction_x = 558 - stringWidth(instruction, 'Helvetica', 7)
    old_instruction = b'1 0 0 1 48 760 Tm'
    new_instruction = f'1 0 0 1 {instruction_x:.4f} 760 Tm'.encode('ascii')
    if border not in content and new_transform in content and new_instruction in content:
        print('TAT v5 header already updated')
        return
    candidates = [rotated_transform, above_header_transform, right_title_transform]
    matches = [value for value in candidates if value in content]
    assert len(matches) == 1, 'Unexpected TAT title position'
    old_transform = matches[0]
    assert content.count(border) <= 1, 'Unexpected TAT letterhead border'
    assert content.count(old_transform) == 1, 'Unexpected TAT title transform'
    assert content.count(old_instruction) == 1, 'Unexpected pencil instruction position'
    # Do not perform a general PDF re-layout or rasterize the sheet.
    updated = content.replace(border, b'').replace(old_transform, new_transform)
    updated = updated.replace(old_instruction, new_instruction)
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
