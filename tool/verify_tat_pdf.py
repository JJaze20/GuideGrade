"""Compare the production TAT template to PDF vector geometry, not a screenshot.

Usage: python tool/verify_tat_pdf.py [path/to/TAT.pdf]
Requires pdfplumber. The repository PDF is also the rendered-fixture source.
"""
from pathlib import Path
import hashlib
import re
import sys
import pdfplumber

root = Path(__file__).resolve().parents[1]
path = Path(sys.argv[1]) if len(sys.argv) > 1 else root / 'answer_sheets/TAT.pdf'
source = (root / 'lib/core/omr/omr_templates.dart').read_text(encoding='utf-8')
tat = source.split('final OmrExamTemplate _omrTAT = ')[1].split('final OmrExamTemplate _omrQTM')[0]
with pdfplumber.open(path) as doc:
    assert len(doc.pages) == 1
    p = doc.pages[0]
    assert (p.width, p.height) == (612, 936)
    squares = [(r['x0']+r['width']/2, r['top']+r['height']/2, r['width']/2)
               for r in p.rects if r['fill'] and abs(r['width']-r['height']) < .01
               and 3 < r['width'] < 30]
    assert len(squares) == 14, squares
    definitions = [(float(x)*612, float(y)*936, 7.0)
                   for x, y in re.findall(r'OmrCorner\(([\d.]+), ([\d.]+)\)', tat)]
    definitions += [(float(x)*612, float(y)*936, float(h)) for x,y,h in
                    re.findall(r'OmrFiducial\(OmrFiducialRole\.\w+, ([\d.]+), ([\d.]+), ([\d.]+)\)', tat)]
    assert len(definitions) + 2 == len(squares)  # second edge-marker pair is printed, unregistered
    for x,y,h in definitions:
        assert any(abs(x-a)<.01 and abs(y-b)<.01 and abs(h-c)<.01 for a,b,c in squares), (x,y,h)
    outlines = [(r['x0']+r['width']/2,r['top']+r['height']/2) for r in p.curves
                if abs(r['width']-16)<.01 and abs(r['height']-12.8)<.01]
    bubbles = [(float(x)*612,float(y)*936) for x,y in
               re.findall(r'BubblePos\("[A-Z]", ([\d.]+), ([\d.]+)\)', tat)]
    assert len(bubbles) == len(outlines) == 320
    for x,y in bubbles:
        assert any(abs(x-a)<.01 and abs(y-b)<.01 for a,b in outlines), (x,y)
    # Verify each ring's printed letter at its vector location, independently
    # of the generated template's labels.
    letters = [c for c in p.chars if c['text'] in ('A','B','C','D','T','F')]
    definitions = re.findall(r'BubblePos\("([A-Z])", ([\d.]+), ([\d.]+)\)', tat)
    for label,x,y in definitions:
        cx,cy=float(x)*612,float(y)*936
        nearby=[c for c in letters if abs((c['x0']+c['x1'])/2-cx)<3 and abs((c['top']+c['bottom'])/2-cy)<4]
        assert any(c['text']==label for c in nearby), (label,cx,cy)
print('PASS: PDF dimensions, 14 printed (12 registered) marker centers/sizes, 320 oval centers/radii and printed choice letters.')
print('PDF SHA256:', hashlib.sha256(path.read_bytes()).hexdigest())
