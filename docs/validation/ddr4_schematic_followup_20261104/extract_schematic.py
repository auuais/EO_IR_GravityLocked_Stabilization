from pathlib import Path
import fitz,json,re,csv,hashlib
out=Path(r'C:/Users/USER/AppData/Local/Temp/ddr4_schematic_audit_20261104')
out.mkdir(exist_ok=True)
src=Path(r'C:/SVNProjects/IMU_Stabilize_v40/Circuit Diagram/tbt_camerasystem_251106.pdf')
doc=fitz.open(src)
def words(n):
    p=doc[n-1]
    return [dict(rect=list(fitz.Rect(a[:4])*p.rotation_matrix),text=a[4]) for a in p.get_text('words')]
def pin_near(ws,y,xrange):
    candidates=[a for a in ws if xrange[0] <= a['rect'][0] <= xrange[1] and re.fullmatch(r'[A-Z]{1,2}[0-9]{1,2}',a['text'])]
    candidates.sort(key=lambda a:abs(a['rect'][1]-(y-2.22)))
    a=candidates[0]
    error=abs(a['rect'][1]-(y-2.22))
    if error>2.6: raise ValueError((y,xrange,a,error))
    return a['text'],round(error,4)
fpga={}
ws=words(11)
for a in ws:
    net=a['text'];x,y=a['rect'][:2]
    if not net.startswith('FU_DDR4_'):continue
    xr=(240,257) if 300<x<450 and y<500 else (916,935) if 990<x<1150 and y<390 else (612,630) if 650<x<800 and y>400 else None
    if xr:
        pin,err=pin_near(ws,y,xr)
        if net in fpga: raise ValueError(net)
        fpga[net]=dict(pin=pin,pdf_page=11,pin_alignment_error=err,net_bbox=a['rect'])
# Symbol terminal labels are matched by independent page geometry, not XDC expectations.
parts={}
for name,n,left,right,pinleft,pinright,ylo,yhi in [
 ('M1',17,(0,235),(400,520),(230,240),(358,369),80,290),
 ('M2',17,(520,755),(940,1040),(750,760),(878,889),80,290),
 ('M3',18,(0,118),(270,355),(109,119),(237,250),89,300),
 ('M4',18,(350,469),(600,710),(459,470),(588,600),86,297),
 ('M5',18,(720,853),(990,1100),(842,853),(971,984),67,278)]:
    ws=words(n);nets={}
    for a in ws:
        x,y=a['rect'][:2];net=a['text']
        if not net.startswith('FU_DDR4_') or not ylo<y<yhi:continue
        xr=pinleft if left[0]<x<left[1] else pinright if right[0]<x<right[1] else None
        if xr:
            pin,err=pin_near(ws,y,xr)
            if net in nets:raise ValueError((name,net))
            nets[net]=dict(pin=pin,pdf_page=n,pin_alignment_error=err,net_bbox=a['rect'])
    parts[name]=nets
(out/'schematic_extracted_nets.json').write_text(json.dumps(dict(pdf=str(src),pdf_sha256=hashlib.sha256(src.read_bytes()).hexdigest(),fpga=fpga,dram=parts),indent=2))
for name,n,rect in [
 ('fpga_bank66',11,(45,25,400,415)),('fpga_bank68',11,(735,15,1100,410)),('fpga_bank67',11,(425,405,780,785)),
 ('dram_m1',17,(90,40,515,450)),('dram_m2',17,(610,40,1040,440)),
 ('dram_m3',18,(10,40,355,445)),('dram_m4',18,(360,35,705,445)),('dram_m5',18,(725,20,1090,425))]:
    doc[n-1].get_pixmap(matrix=fitz.Matrix(3,3),clip=fitz.Rect(rect),alpha=False).save(out/(name+'.png'))
print('FPGA_NETS',len(fpga))
for name,nets in parts.items():print(name,len(nets),nets.get('FU_DDR4_CK_T'),nets.get('FU_DDR4_RESET_N'))
print('OUTPUT',out)

