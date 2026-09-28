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
                    assert len(a.rects) - len(rects) in (0, 1)
                assert geometry(rects) == geometry(b.rects), f'{name}: markers/fields changed'
                def split_title(page):
                    chars = page.chars
                    if i != 0:
                        return chars, []
                    text = ''.join(c['text'] for c in chars)
                    assert text.count(title) == 1, name
                    start = text.index(title)
                    assert all(len(c['text']) == 1 for c in chars)
                    return chars[:start] + chars[start + len(title):], chars[start:start + len(title)]

                old_chars, _ = split_title(a)
                new_chars, title_chars = split_title(b)
                if name == 'TAT-portrait-v5' and i == 0:
                    instruction = 'Use a No. 2 pencil. Fill the circle completely.'
                    def split_instruction(chars):
                        text = ''.join(c['text'] for c in chars)
                        assert text.count(instruction) == 1
                        start = text.index(instruction)
                        return chars[:start] + chars[start + len(instruction):], chars[start:start + len(instruction)]
                    old_chars, old_instruction = split_instruction(old_chars)
                    new_chars, new_instruction = split_instruction(new_chars)
                    assert [round(c['top'], 3) for c in old_instruction] == [round(c['top'], 3) for c in new_instruction]
                    assert min(c['x0'] for c in new_instruction) > max(c['x1'] for c in title_chars) + 20
                    assert abs(max(c['x1'] for c in new_instruction) - 558) < .01
                assert geometry(old_chars) == geometry(new_chars), f'{name}: other text moved'
                if i == 0:
                    assert ''.join(c['text'] for c in title_chars) == title, name
                    assert all(c['upright'] for c in title_chars)
                    top, bottom = min(c['top'] for c in title_chars), max(c['bottom'] for c in title_chars)
                    if name == 'TAT-portrait-v5':
                        assert 164 < top < bottom < 180
                        assert abs(min(c['x0'] for c in title_chars) - 48) < .01
                    else:
                        assert (124 if name == 'AT' else 130) < top < bottom < 165
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
