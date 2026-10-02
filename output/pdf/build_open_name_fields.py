"""Remove only individual name-cell dividers from supplied vector PDFs."""
from pathlib import Path
import re
import json
from pypdf import PdfReader, PdfWriter
import pdfplumber
import pypdfium2 as pdfium

root = Path(__file__).resolve().parents[2]
out = Path(__file__).parent
source = (root/'lib/core/omr/omr_templates.dart').read_text(encoding='utf-8')
for exam in ['AT', 'QTM']:
    original = root/'answer_sheets'/f'{exam}.pdf'
    template = source.split(f'final OmrExamTemplate _omr{exam} =')[1].split('\nfinal ')[0]
    reader = PdfReader(original)
    page = reader.pages[0]
    w,h = float(page.mediabox.width),float(page.mediabox.height)
    fields = []
    for name in ['lastName','firstName','middleInitial']:
        vals = re.search(name+r'FieldRect: const OmrFieldRect\(([^)]+)\)', template).group(1)
        x,y,fw,fh = map(float, vals.split(','))
        fields.append(dict(name=name,x=x*w,y=y*h,width=fw*w,height=fh*h,boxCount=0))
    stream = page.get_contents()
    ops = stream.operations
    kept=[]; removed=[0,0,0]; i=0
    while i<len(ops):
        if i+2<len(ops) and [ops[i+k][1] for k in range(3)]==[b'm',b'l',b'S']:
            x0,y0=map(float,ops[i][0]); x1,y1=map(float,ops[i+1][0])
            for j,f in enumerate(fields):
                if (abs(x0-x1)<.001 and f['x']+.1<x0<f['x']+f['width']-.1
                    and abs(h-max(y0,y1)-f['y'])<.05
                    and abs(abs(y1-y0)-f['height'])<.05):
                    removed[j]+=1; i+=3; break
            else:
                kept.append(ops[i]); i+=1
            continue
        kept.append(ops[i]); i+=1
    assert removed==[23,19,1], (exam,removed)
    stream.operations=kept
    page.replace_contents(stream)
    version=f'{exam}-open-name-fields-proposed-v2'
    target=out/f'{version}.pdf'
    writer=PdfWriter()
    for p in reader.pages: writer.add_page(p)
    with target.open('wb') as f: writer.write(f)
    with pdfplumber.open(original) as a, pdfplumber.open(target) as b:
        assert len(a.pages)==len(b.pages)==2
        for old,new in zip(a.pages,b.pages):
            assert (old.width,old.height)==(new.width,new.height)
            assert old.extract_text()==new.extract_text()
            assert old.curves==new.curves and old.rects==new.rects
        assert len(a.pages[0].lines)-len(b.pages[0].lines)==43
        assert a.pages[1].lines==b.pages[1].lines
    olddoc=pdfium.PdfDocument(str(original)); newdoc=pdfium.PdfDocument(str(target))
    # Page two must also render identically, including non-text content.
    assert olddoc[1].render(scale=1).to_pil().tobytes()==newdoc[1].render(scale=1).to_pil().tobytes()
    newdoc[0].render(scale=1.4).to_pil().save(out/f'{version}.preview.png')
    (out/f'{version}.name-fields.json').write_text(json.dumps(dict(
        proposedTemplateVersion=version,sourceTemplateVersion=f'{exam}-redesign-v1',
        pageWidthPt=w,pageHeightPt=h,coordinateOrigin='top-left',units='points',
        fields=fields,changes='Only 43 internal letter-cell divider lines removed. All other PDF geometry preserved.',
        scannerIntegration='Set all three name box counts to zero for this new version. Preserve old template metadata for archived scans. Scanner code has not been changed.'),indent=2))
    print(f'PASS {exam}: removed {removed} dividers; text, bubbles, fiducials and page 2 unchanged.')
