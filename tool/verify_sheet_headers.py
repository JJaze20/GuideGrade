"""Verify header-only PDF edits against a Git revision and optionally render them.

Usage: python tool/verify_sheet_headers.py REV [--preview-dir PATH]
Requires pdfplumber; preview rendering additionally requires pypdfium2.
"""
import argparse
from io import BytesIO
from pathlib import Path
import subprocess

import pdfplumber

ROOT = Path(__file__).resolve().parents[1]


def git_bytes(ref, path):
    return subprocess.check_output([
        'git', '-c', f'safe.directory={ROOT.as_posix()}',
        'show', f'{ref}:{path}',
    ], cwd=ROOT)


def geometry(objects):
    return sorted((round(o['x0'], 3), round(o['top'], 3),
                   round(o['x1'], 3), round(o['bottom'], 3),
                   o.get('text', ''), o.get('fill', False),
                   o.get('stroke', False), round(o.get('linewidth', 0), 3))
                  for o in objects)


def verify(ref, preview_dir=None):
    titles = {
        'AT': 'ADMISSION TEST (AT)',
        'QTM': 'QUALIFYING TEST IN MATHEMATICS (QTM)',
        'TAT-portrait-v5': 'TEACHING APTITUDE TEST (TAT)',
    }
    for name, title in titles.items():
        path = f'answer_sheets/{name}.pdf'
        with pdfplumber.open(BytesIO(git_bytes(ref, path))) as before, \
                pdfplumber.open(ROOT / path) as after:
            assert len(before.pages) == len(after.pages), name
            for i, (a, b) in enumerate(zip(before.pages, after.pages)):
                assert (a.width, a.height) == (b.width, b.height), name
                assert geometry(a.curves) == geometry(b.curves), f'{name}: bubble paths changed'
                assert geometry(a.lines) == geometry(b.lines), f'{name}: table lines changed'
                rects = a.rects
                if name == 'TAT-portrait-v5' and i == 0:
                    rects = [r for r in rects if not (
                        r['x0'] == 48 and r['top'] == 46 and
                        r['width'] == 510 and r['height'] == 46)]
                    assert len(a.rects) - len(rects) == 1
                assert geometry(rects) == geometry(b.rects), f'{name}: markers/fields changed'
                # The old title was vertical; the new title occupies only
                # the previously blank strip above the letterhead.
                old_chars = [c for c in a.chars if i != 0 or c['upright']]
                new_chars = [c for c in b.chars if i != 0 or c['top'] > 44]
                assert geometry(old_chars) == geometry(new_chars), f'{name}: other text moved'
                if i == 0:
                    title_chars = [c for c in b.chars if c['top'] < 44]
                    assert ''.join(c['text'] for c in title_chars) == title, name
                    assert all(c['upright'] and c['top'] >= 24 for c in title_chars)
            print(f'PASS {name}: bubbles, markers, fields, other text and back pages unchanged')
        if preview_dir:
            import pypdfium2 as pdfium
            preview_dir.mkdir(parents=True, exist_ok=True)
            with pdfium.PdfDocument(ROOT / path) as pdf:
                pdf[0].render(scale=1.5).to_pil().save(preview_dir / f'{name}.png')

    for path in ['lib/core/omr/omr_templates.dart',
                 'lib/core/omr/omr_template_tat_v5.dart',
                 'tool/data/TAT-portrait-v5.geometry.json']:
        assert git_bytes(ref, path).replace(b'\r\n', b'\n') == \
            (ROOT / path).read_bytes().replace(b'\r\n', b'\n'), path
    print('PASS scanner template definitions and geometry JSON unchanged')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ref')
    parser.add_argument('--preview-dir', type=Path)
    args = parser.parse_args()
    verify(args.ref, args.preview_dir)
