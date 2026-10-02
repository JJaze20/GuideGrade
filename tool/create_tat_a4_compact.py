"""A4 placement trial retaining all header fields and original-size bubbles."""
import json
from pathlib import Path
from reportlab.pdfgen import canvas
from pypdf import PdfReader

ROOT = Path(__file__).resolve().parents[1]
W, H = 595.28, 841.89

def main():
    output = ROOT / 'answer_sheets/TAT-A4-placement-v2.pdf'
    c = canvas.Canvas(str(output), pagesize=(W, H))
    geometry = dict(templateVersion='TAT-A4-placement-v2', pageWidth=W, pageHeight=H,
                    units='PDF points', coordinateOrigin='top-left; x right, y down',
                    status='Print trial; not registered in scanner', fields=[], bubbles=[], fiducials=[])
    def text(x, y, value, size=8, bold=False):
        c.setFillColorRGB(0.08, 0.20, 0.42) if bold else c.setFillColorRGB(0, 0, 0)
        c.setFont('Helvetica-Bold' if bold else 'Helvetica', size)
        c.drawString(x, H-y, value)
        c.setFillColorRGB(0, 0, 0)
    def field(x, y, width, label, height=32):
        c.setLineWidth(.65)
        c.rect(x, H-y-height, width, height)
        text(x+4, y+9, label, 7)
        geometry['fields'].append(dict(name=label,x=x,y=y,width=width,height=height))
    for i, line in enumerate(['Guidance, Honors, and Scholarship Center',
                              'Notre Dame of Marbel University', 'City of Koronadal, South Cotabato']):
        c.setFont('Helvetica-Bold' if i == 1 else 'Helvetica', 11 if i == 1 else 8)
        c.setFillColorRGB(0.08, 0.20, 0.42) if i == 1 else c.setFillColorRGB(0, 0, 0)
        c.drawCentredString(W/2, H-(36+14*i), line)
    c.setFillColorRGB(0, 0, 0)
    x=36
    for label,width in [('Last Name',190),('First Name',190),('Middle Name',143.28)]:
        field(x,76,width,label)
        # Separate the caption cell from the handwriting cell below it.
        c.line(x,H-88,x+width,H-88)
        geometry['fields'][-1].update(y=88,height=20)
        x+=width
    text(36,126,'TEACHING APTITUDE TEST (TAT)',10,True)
    c.setFont('Helvetica',7)
    c.drawRightString(W-36,H-126,'Use a No. 2 pencil. Fill the circle completely.')
    def marker(role,x,y,side):
        c.rect(x-side/2,H-y-side/2,side,side,fill=1,stroke=0)
        geometry['fiducials'].append(dict(role=role,x=x,y=y,side=side))
    for role,x,y in [('topLeft',24,24),('topRight',W-24,24),('bottomLeft',24,H-24),('bottomRight',W-24,H-24)]:
        marker(role,x,y,11)
    def section(name,xs,rows,count,start_y,pitch,choices):
        for col,x in enumerate(xs):
            for row in range(rows):
                n=col*rows+row+1
                if n>count: continue
                y=start_y+pitch*row
                c.setFont('Helvetica',8)
                c.drawRightString(x-15,H-y-2.5,f'{n}.')
                for k,choice in enumerate(choices):
                    bx=x+k*26
                    c.setLineWidth(.7)
                    c.ellipse(bx-8,H-y-5.6,bx+8,H-y+5.6)
                    c.setFont('Helvetica',7)
                    c.drawCentredString(bx,H-y-2.4,choice)
                    geometry['bubbles'].append(dict(section=name,question=n,choice=choice,x=bx,y=y,rx=8,ry=5.6))
    text(36,148,'TEST I',10,True)
    text(382,148,'TEST III',10,True)
    section('Test I',[66,222],15,30,168,19,'ABCD')
    section('Test III',[407,503],10,20,168,266/9,'TF')
    text(36,469,'TEST II',10,True)
    section('Test II',[66,204,342,480],20,80,490,16.4,'TF')
    for i,x in enumerate([110,266,420,518]): marker(f'aboveUpper{i}',x,158,5)
    marker('dividerLeft',24,452,11)
    marker('dividerRight',W-24,452,11)
    marker('centerAtDivider',W/2,452,8)
    marker('aboveTestII21',217,480,5)
    marker('aboveTestII41',355,480,5)
    c.showPage()
    text(36,48,'Additional Information',11,True)
    # These writing fields belong to the reverse, not the scanning geometry.
    front_fields = geometry['fields'].copy()
    field(36,66,523.28,'School Last Attended',28)
    field(36,100,523.28,'Address of School Last Attended',32)
    field(36,138,261.64,'Date Today: Year / Month / Day',28)
    field(297.64,138,261.64,'Birth Date: Year / Month / Day',28)
    field(36,172,180,'Age',26)
    field(216,172,343.28,'Sex: M ( ) F ( )',26)
    geometry['backFields'] = geometry['fields'][len(front_fields):]
    geometry['fields'] = front_fields
    c.showPage(); c.save()
    assert len(geometry['bubbles'])==320
    for b in geometry['bubbles']:
        assert 36 < b['x']-b['rx'] < b['x']+b['rx'] < W-36
        assert 0 < b['y']-b['ry'] < b['y']+b['ry'] < H-24
    assert len(PdfReader(output).pages)==2
    (ROOT/'tool/data/TAT-A4-placement-v2.geometry.json').write_text(json.dumps(geometry,indent=2)+'\n')
    print(f'Created {output}; 130 items, original 8 x 5.6 pt bubble radii')

if __name__=='__main__': main()
