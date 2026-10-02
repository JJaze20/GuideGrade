from pathlib import Path
import json
import sys
from reportlab.pdfgen import canvas
from reportlab.lib.colors import HexColor, black
import pdfplumber
import pypdfium2 as pdfium

OUT = Path(__file__).parent
W, H = 612, 936
wide_center = '--wide-center' in sys.argv
test1_marks = '--test1-marks' in sys.argv or wide_center
centered = '--centered' in sys.argv or test1_marks
revised = '--revised' in sys.argv or centered
version = 'TAT-portrait-proposed-v3' if centered else ('TAT-portrait-proposed-v2' if revised else 'TAT-portrait-proposed-v1')
marker_count = 12 if centered else (11 if revised else 13)
if test1_marks:
    version = 'TAT-portrait-proposed-v4'
    marker_count = 14
if wide_center:
    version = 'TAT-portrait-proposed-v5'
pdf = OUT / f'{version}.pdf'
c = canvas.Canvas(str(pdf), pagesize=(W,H))
c.setTitle(f'{version} - 8.5 x 13 inches')
blue = HexColor('#153a85')
geometry = dict(templateVersion=version, units='PDF points',
    coordinateOrigin='top-left; x right, y down', pageWidth= W, pageHeight=H,
    status='Proposed; not implemented in scanner', fiducials=[], bubbles=[], fields=[], blocks=[])
def text(x,y,s,size=7,bold=False,color=black,center=False):
    c.setFillColor(color); c.setFont('Helvetica-Bold' if bold else 'Helvetica',size)
    (c.drawCentredString if center else c.drawString)(x,H-y,s)
def rect(x,y,w,h):
    c.setStrokeColor(black); c.setLineWidth(.5); c.rect(x,H-y-h,w,h,fill=0)
def mark(name,x,y,side):
    c.setFillColor(black); c.rect(x-side/2,H-y-side/2,side,side,stroke=0,fill=1)
    geometry['fiducials'].append(dict(role=name,x=x,y=y,side=side))
edge_marks = [('topLeft',36,36),('topRight',576,36),('bottomLeft',36,906),('bottomRight',576,906)]
edge_marks += ([('midLeft',36,H/2),('midRight',576,H/2)] if revised else [('divider1Left',36,399),('divider1Right',576,399),('divider2Left',36,798),('divider2Right',576,798)])
for name,x,y in edge_marks: mark(name,x,y,11)
rect(48,46,510,46)
text(303,59,'Guidance, Honors, and Scholarship Center',7,color=blue,center=True)
text(303,72,'Notre Dame of Marbel University',12,True,blue,True)
text(303,84,'City of Koronadal, South Cotabato',7,center=True)
def fields(y,spec):
    x=48
    for label,w in spec:
        rect(x,y,w,32)
        c.line(x,H-y-10,x+w,H-y-10)
        text(x+3,y+7,label,6)
        geometry['fields'].append(dict(name=label,x=x,y=y+10,width=w,height=22))
        if label=='Sex': text(x+3,y+23,'M ( )  F ( )',7)
        x+=w
fields(96,[('Last Name',150),('First Name',150),('M.I.',36),('Age',44),('Sex',130)])
fields(132,[('School Last Attended',146),('Address of School Last Attended',172),('Date Today',96),('Birth Date',96)])
text(48,176,'Use a No. 2 pencil. Fill the circle completely.',7)
c.saveState(); c.translate(584,H-104); c.rotate(-90)
c.setFillColor(blue); c.setFont('Helvetica-Bold',10); c.drawString(0,0,'TEACHING APTITUDE TEST (TAT)'); c.restoreState()
def block(section,start,count,x,y,choices,pitch):
    geometry['blocks'].append(dict(section=section,first=start,last=start+count-1,x=x-4,y=y-9,width=26+(len(choices)-1)*29+10,height=(count-1)*pitch+18))
    for row in range(count):
        n=start+row; cy=y+row*pitch
        text(x,cy+2.4,str(n)+'.',7)
        for j,ch in enumerate(choices):
            cx=x+26+j*29
            c.setStrokeColor(black); c.setLineWidth(.65)
            c.ellipse(cx-8,H-cy-5.6,cx+8,H-cy+5.6,stroke=1,fill=0)
            text(cx,cy+2,ch,6,True,center=True)
            geometry['bubbles'].append(dict(section=section,question=n,choice=ch,x=cx,y=cy,rx=8,ry=5.6))
text(48,197,'TEST I',10,True,blue)
for x,start in [(65,1),(237,11),(409,21)]: block('Test I',start,10,x,215,'ABCD',19)
text(48,418,'TEST II',10,True,blue)
test2_columns = [(65,1),(182 if wide_center else 194,21),(335 if wide_center else 323,41),(452,61)]
for x,start in test2_columns: block('Test II',start,20,x,435,'TF',18.3)
text(48,818,'TEST III',10,True,blue)
for x,start in [(65,1),(194,6),(323,11),(452,16)]: block('Test III',start,5,x,835,'TF',15)
for name,x,y in [('aboveTestI11',237,195),('aboveTestII21',194,416),('aboveTestII41',323,416),('aboveTestIII6',194,816),('aboveTestIII11',323,816)]:
    if wide_center and name in ('aboveTestII21','aboveTestII41'):
        x += -12 if name=='aboveTestII21' else 12
    if centered:
        # Center over all choices: B/C midpoint for A-D, T/F midpoint otherwise.
        x += 26 + (3*29/2 if name=='aboveTestI11' else 29/2)
    mark(name,x,y,6)
if centered:
    mark('centerTestII23And43', W/2, H/2, 11)
if test1_marks:
    for name,x in [('aboveTestI1',65),('aboveTestI21',409)]:
        mark(name,x+26+3*29/2,195,6)
c.showPage(); c.save()
assert len(geometry['bubbles'])==320 and len(geometry['fiducials'])==marker_count
for section,count,choices in [('Test I',30,'ABCD'),('Test II',80,'TF'),('Test III',20,'TF')]:
    for n in range(1,count+1):
        assert ''.join(b['choice'] for b in geometry['bubbles'] if b['section']==section and b['question']==n)==choices
with pdfplumber.open(pdf) as doc:
    p=doc.pages[0]
    assert len(doc.pages)==1 and (p.width,p.height)==(W,H)
    assert len(p.curves)==320
    assert len([r for r in p.rects if r['fill']])==marker_count
    for m in geometry['fiducials']:
        assert any(abs((r['x0']+r['x1'])/2-m['x'])<.01 and abs((r['top']+r['bottom'])/2-m['y'])<.01 for r in p.rects if r['fill'])
    for b in geometry['bubbles']:
        assert any(abs((r['x0']+r['x1'])/2-b['x'])<.01 and abs((r['top']+r['bottom'])/2-b['y'])<.01 for r in p.curves)
    # Markers must not overlap either printed text or answer outlines.
    for m in geometry['fiducials']:
        half=m['side']/2
        x0,y0,x1,y1=m['x']-half,m['y']-half,m['x']+half,m['y']+half
        for obj in p.chars+p.curves:
            assert x1 <= obj['x0'] or x0 >= obj['x1'] or y1 <= obj['top'] or y0 >= obj['bottom'], (m['role'],obj)
(OUT/f'{version}.geometry.json').write_text(json.dumps(geometry,indent=2))
doc=pdfium.PdfDocument(str(pdf)); doc[0].render(scale=1.5).to_pil().save(OUT/f'{version}.preview.png')
handoff = '''# TAT portrait proposed v1

Use the PDF and accompanying geometry JSON as the source of truth, not the AI mockups. This PDF has exactly 130 questions / 320 oval bubbles and 13 fiducials. Long bond paper: 8.5 x 13 inches (612 x 936 PDF points). Print Actual Size / 100%, not Legal or Fit.

Coordinates in JSON are top-left origin, in points. PDF native coordinates use bottom-left origin: convert y with 936-y. Name-field rectangles exclude the printed captions. Bubble numbering restarts per section. Test I: 30 A-D; Test II: 80 T/F; Test III: 20 T/F. All numbering was regenerated deterministically.

New small marks are above the question numbers Test I 11, Test II 21/41, Test III 6/11. There are eight edge marks. Header and margins are based on the approved mockup concept, not measurements of an existing physical sheet.

This is a NEW proposed template, not currently supported by the app. Implement a separate template version and explicit selection; preserve existing TAT/AT/QTM and archived coordinates. Do not overwrite legacy definitions. Preserve scoring rules. Use identical mapping for sampling and review overlays. Crop names for manual entry; do not enable OCR automatically.

Measure and validate these vector positions independently. Marks at section boundaries do not fully constrain bending inside tall Test II columns. Validate against printed geometry and real device captures. Verify orientation discrimination rather than assuming all layouts uniquely identify direction. Test print margins, actual-size output, 130-question mapping, saved name crops, rotated/tilted capture, and archive compatibility before production use.
'''
if revised:
    handoff = handoff.replace('proposed v1', 'proposed v2').replace('13 fiducials','11 fiducials').replace('There are eight edge marks.', 'There are six edge marks: four corners plus a side pair at y=468pt, the physical page midpoint. The former pair above Test III is removed. This revision preserves v1 question and field positions; it is distinct from answer_sheets/TAT.pdf and the current app template.')
if centered:
    handoff = handoff.replace('proposed v2','proposed v3').replace('11 fiducials','12 fiducials').replace('New small marks are above the question numbers Test I 11, Test II 21/41, Test III 6/11.', 'Five 6pt small marks are centered above the answer groups: Test I 11 at the B/C midpoint, Test II 21/41 and Test III 6/11 at their T/F midpoints. A new 11pt square at (306,468) lies in the central gutter between Test II 23 and 43, level with the side pair. It is 3.6pt above those rows\' bubble centers (y=471.6), preserving the side pair at the physical page midpoint.')
if test1_marks:
    handoff = handoff.replace('proposed v3','proposed v4').replace('12 fiducials','14 fiducials').replace('Five 6pt small marks','Seven 6pt small marks').replace('Test I 11 at the B/C midpoint','Test I 1/11/21 at their B/C midpoints')
if wide_center:
    handoff = handoff.replace('proposed v4','proposed v5').replace('This revision preserves v1 question and field positions;', 'Test II questions 21-40 move 12pt left and 41-60 move 12pt right relative to v4; their small upper markers move with them. All other question and field positions are preserved;')
(OUT/(f'{version}-Claude-handoff.md' if revised else 'TAT-portrait-Claude-handoff.md')).write_text(handoff,encoding='utf-8')
print(f'PASS: one 612x936pt page, 130 questions, 320 vector bubbles, {marker_count} solid square markers')
