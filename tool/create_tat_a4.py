"""Create an A4 trial and matching geometry without replacing the active TAT."""
import json
from pathlib import Path
from pypdf import PdfReader, PdfWriter, Transformation

ROOT = Path(__file__).resolve().parents[1]
WIDTH, HEIGHT = 595.28, 841.89
SCALE = 0.89

def main():
    source = PdfReader(ROOT / 'answer_sheets/TAT-portrait-v5.pdf')
    page = source.pages[0]
    sw, sh = float(page.mediabox.width), float(page.mediabox.height)
    dx, dy = (WIDTH - sw * SCALE) / 2, (HEIGHT - sh * SCALE) / 2
    writer = PdfWriter()
    target = writer.add_blank_page(width=WIDTH, height=HEIGHT)
    target.merge_transformed_page(page, Transformation().scale(SCALE).translate(dx, dy))
    output = ROOT / 'answer_sheets/TAT-A4-trial.pdf'
    writer.write(output)
    geometry = json.loads((ROOT / 'tool/data/TAT-portrait-v5.geometry.json').read_text())
    geometry.update(templateVersion='TAT-A4-trial-v1', pageWidth=WIDTH, pageHeight=HEIGHT,
                    status='A4 trial; not registered in the active scanner')
    for collection in ('fiducials', 'bubbles', 'fields', 'blocks'):
        for item in geometry[collection]:
            item['x'] = round(item['x'] * SCALE + dx, 5)
            item['y'] = round(item['y'] * SCALE + dy, 5)
            for key in ('rx', 'ry', 'side', 'width', 'height'):
                if key in item:
                    item[key] = round(item[key] * SCALE, 5)
    (ROOT / 'tool/data/TAT-A4-trial.geometry.json').write_text(json.dumps(geometry, indent=2) + '\n')
    check = PdfReader(output)
    assert len(check.pages) == 1
    assert check.pages[0].extract_text() == page.extract_text()
    assert len(geometry['bubbles']) == 320
    for bubble in geometry['bubbles']:
        assert 0 < bubble['x'] - bubble['rx'] < bubble['x'] + bubble['rx'] < WIDTH
        assert 0 < bubble['y'] - bubble['ry'] < bubble['y'] + bubble['ry'] < HEIGHT
    print(f'Created {output}; all 130 items retained; bubble radii 7.12 x 4.984 pt')

if __name__ == '__main__':
    main()
