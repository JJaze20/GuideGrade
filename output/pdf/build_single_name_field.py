from pathlib import Path
from io import BytesIO
import json
import sys
from pypdf import PdfReader, PdfWriter
from reportlab.pdfgen import canvas
import pdfplumber
import pypdfium2 as pdfium

out=Path(__file__).parent
full_middle = '--full-middle' in sys.argv
name_row = '--name-row' in sys.argv or full_middle
for exam in ['AT','QTM']:
    source=out/f'{exam}-open-name-fields-proposed-v2.pdf'
    meta=json.loads(source.with_suffix('.name-fields.json').read_text())
    w,h=meta['pageWidthPt'],meta['pageHeightPt']
    fields=meta['fields']
    # Recover exact printed outer borders, avoiding rounded template fractions.
    with pdfplumber.open(source) as doc:
        rects=[r for r in doc.pages[0].rects if not r['fill'] and
               abs(r['x0']-fields[0]['x'])<.05 and
               abs(r['height']-34)<.05 and
               any(abs(r['bottom']-(f['y']+f['height']))<.05 for f in fields)]
        assert len(rects)==2
        left=min(r['x0'] for r in rects); right=max(r['x1'] for r in rects)
        top=min(r['top'] for r in rects); bottom=max(r['bottom'] for r in rects)
    def inside(x,y):
        return left-.05<=x<=right+.05 and top-.05<=h-y<=bottom+.05
    writer=PdfWriter(clone_from=str(source)); page=writer.pages[0]
    stream=page.get_contents(); ops=stream.operations; kept=[]; i=0; removed_labels=0
    while i<len(ops):
        args,op=ops[i]
        if op==b'BT':
            end=i+1
            while ops[end][1]!=b'ET': end+=1
            run=ops[i:end+1]
            label=''.join(str(v) for a,o in run if o==b'TJ' for v in a[0] if isinstance(v,str))
            if label in ['Last Name','First Name','MI']:
                removed_labels+=1; i=end+1; continue
        if op==b're' and i+1<len(ops) and ops[i+1][1]==b'S':
            x,y,rw,rh=map(float,args)
            if inside(x,y) and inside(x+rw,y+rh): i+=2; continue
        if op==b'm' and i+2<len(ops) and ops[i+1][1]==b'l' and ops[i+2][1]==b'S':
            if inside(*map(float,args)) and inside(*map(float,ops[i+1][0])): i+=3; continue
        kept.append(ops[i]); i+=1
    assert removed_labels==3
    stream.operations=kept; page.replace_contents(stream)
    buf=BytesIO(); c=canvas.Canvas(buf,pagesize=(w,h))
    row_bottom = top+34 if name_row else bottom
    c.setLineWidth(1); c.rect(left,h-row_bottom,right-left,row_bottom-top)
    c.setLineWidth(.75); c.line(left,h-top-14,right,h-top-14)
    c.setFont('Helvetica',8); c.setFillColorRGB(.46,.46,.46)
    row_fields=[]
    if name_row:
        x=left
        columns = ([('Last Name','lastName',.34),('First Name','firstName',.34),('Middle Name','middleName',.32)] if full_middle else [('Last Name','lastName',.45),('First Name','firstName',.45),('MI','middleInitial',.1)])
        for label,key,fraction in columns:
            fw=(right-left)*fraction
            if x>left:
                c.setStrokeColorRGB(0,0,0); c.setLineWidth(1)
                c.line(x,h-top,x,h-row_bottom)
            c.drawString(x+3,h-top-10,label)
            row_fields.append(dict(name=key,x=x,y=top+14,width=fw,height=20,boxCount=0))
            x+=fw
    else:
        c.drawString(left+3,h-top-10,'Name')
    c.save(); buf.seek(0); page.merge_page(PdfReader(buf).pages[0])
    version=f'{exam}-name-row-proposed-v4' if name_row else f'{exam}-single-name-field-proposed-v3'
    if full_middle:
        version=f'{exam}-full-middle-name-proposed-v5'
    target=out/f'{version}.pdf'
    with target.open('wb') as f: writer.write(f)
    old=pdfium.PdfDocument(str(source)); new=pdfium.PdfDocument(str(target))
    assert len(new)==2
    assert old[1].render().to_pil().tobytes()==new[1].render().to_pil().tobytes()
    with pdfplumber.open(source) as a,pdfplumber.open(target) as b:
        assert a.pages[0].curves==b.pages[0].curves
        assert [r for r in a.pages[0].rects if r['fill']]==[r for r in b.pages[0].rects if r['fill']]
        text=b.pages[0].extract_text()
        if name_row:
            assert all(label in text for label in ['Last Name','First Name','Middle Name' if full_middle else 'MI'])
            for field in row_fields:
                chars=b.pages[0].crop((field['x']+1,field['y']+1,field['x']+field['width']-1,field['y']+field['height']-1)).chars
                assert not chars, 'Writing area must be empty'
        else:
            assert 'Last Name' not in text and 'First Name' not in text and 'Name' in text
    new[0].render(scale=1.3).to_pil().save(out/f'{version}.preview.png')
    (out/f'{version}.name-field.json').write_text(json.dumps(dict(
        proposedTemplateVersion=version,pageWidthPt=w,pageHeightPt=h,
        coordinateOrigin='top-left',units='points',
        fields=row_fields if name_row else [dict(name='fullName',x=left,y=top+14,width=right-left,height=bottom-top-14)],
        scannerIntegration=('Three separate crops in one row; use these new rectangles with box counts zero. Existing app templates not changed.' if name_row else 'New combined crop rectangle; implement explicitly for this version. Do not crop as separate Last/First/MI fields. Existing app templates not changed.')),indent=2))
    print(f'PASS {exam}: {"three separate name fields in one row" if name_row else "one Name field"}, answer geometry preserved, page 2 identical.')
