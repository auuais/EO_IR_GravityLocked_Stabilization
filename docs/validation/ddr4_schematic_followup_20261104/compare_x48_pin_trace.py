from pathlib import Path
import csv,hashlib,json,re
out=Path(r'C:/Users/USER/AppData/Local/Temp/ddr4_schematic_audit_20261104')
a=json.loads((out/'schematic_extracted_nets.json').read_text())
root=Path(r'E:/Xylinx/EO_IR_GravityLocked_Stabilization')
xdc=root/'constraints/ddr4_sub64_firstpass.xdc'
def target(port):
 m=re.fullmatch(r'c0_ddr4_dq\[(\d+)\]',port)
 if m:
  n=int(m[1])+16;return 'FU_DDR4_DQ'+str(n),'M'+str(n//16+1),'DQ'+str(n%16)
 m=re.fullmatch(r'c0_ddr4_dm_dbi_n\[(\d+)\]',port)
 if m:
  n=int(m[1])+2;return 'FU_DDR4_DM_DBI'+str(n)+'_N','M'+str(n//2+1),('L' if n%2==0 else 'U')+'DM_N/DBI_N'
 m=re.fullmatch(r'c0_ddr4_dqs_([tc])\[(\d+)\]',port)
 if m:
  n=int(m[2])+2;return 'FU_DDR4_DQS'+str(n)+'_'+m[1].upper(),'M'+str(n//2+1),('L' if n%2==0 else 'U')+'DQS_'+m[1].upper()
 m=re.fullmatch(r'c0_ddr4_adr\[(\d+)\]',port)
 if m:
  n=int(m[1]);return 'FU_DDR4_A'+str(n)+({14:'_WE_N',15:'_CAS_N',16:'_RAS_N'}.get(n,'')),'M1-M5','A'+str(n)
 suffix={'c0_sys_clk_p':'SYSCLK_P','c0_sys_clk_n':'SYSCLK_N','c0_ddr4_reset_n':'RESET_N','c0_ddr4_act_n':'ACT_N','c0_ddr4_cs_n[0]':'CS_N','c0_ddr4_cke[0]':'CKE','c0_ddr4_odt[0]':'ODT','c0_ddr4_ck_t[0]':'CK_T','c0_ddr4_ck_c[0]':'CK_C','c0_ddr4_bg[0]':'BG0','c0_ddr4_ba[0]':'BA0','c0_ddr4_ba[1]':'BA1'}[port]
 return 'FU_DDR4_'+suffix,('Y2' if suffix.startswith('SYSCLK') else 'M1-M5'),suffix
rows=[]
for line,s in enumerate(xdc.read_text().splitlines(),1):
 m=re.fullmatch(r'set_property PACKAGE_PIN (\w+) \[get_ports (.*)\]',s.strip())
 if not m:continue
 pin,port=m.groups();port=port.strip('{}')
 net,comp,terminal=target(port);p=a['fpga'][net]
 if comp=='Y2':
  balls='4 OUT+' if terminal=='SYSCLK_P' else '5 OUT-'; pages='11'
 else:
  comps=list(a['dram']) if comp=='M1-M5' else [comp]
  q=[a['dram'][c][net] for c in comps];balls=','.join(sorted(set(v['pin'] for v in q)));pages=','.join(map(str,sorted(set(v['pdf_page'] for v in q))))
 rows.append(dict(mig_port=port,fpga_package_pin=pin,schematic_fpga_pin=p['pin'],schematic_net=net,dram_component=comp,dram_terminal=terminal,component_ball=balls,fpga_pdf_page=11,dram_pdf_pages=pages,xdc_line=line,match=pin==p['pin']))
assert len(rows)==95
assert all(r['match'] for r in rows),[r for r in rows if not r['match']]
checks=json.load(open(r'C:/Users/USER/AppData/Local/Temp/ddr4_dci_audit_20261104_65781/query_summary.json'))['checkpoints']
byport={r['mig_port']:r for r in rows}
for c in checks:
 for p in c['ports']:assert byport[p['port']]['fpga_package_pin']==p['package_pin']
with (out/'current_x48_pin_trace.csv').open('w',newline='') as f:
 w=csv.DictWriter(f,fieldnames=list(rows[0]));w.writeheader();w.writerows(rows)
m4=[r for r in rows if r['dram_component']=='M4']
with (out/'m4_old_dq48_63_pin_trace.csv').open('w',newline='') as f:
 w=csv.DictWriter(f,fieldnames=list(rows[0]));w.writeheader();w.writerows(m4)
xci=root/'ip/ddr4_sub64/ddr4_sub64.xci'
params=json.loads(xci.read_text())['ip_inst']['parameters']['component_parameters']
want=['C0.DDR4_MemoryPart','C0.DDR4_DataWidth','C0.DDR4_TimePeriod','C0.DDR4_InputClockPeriod','C0.DDR4_PhyClockRatio','C0.DDR4_CasLatency','C0.DDR4_CasWriteLatency','C0.DDR4_DataMask','C0.DDR4_Ecc','C0.DDR4_MCS_ECC','DCI_Cascade']
summary=dict(scope='Schematic net/pin trace plus current XDC and two previously queried routed checkpoints; no board inspection or electrical margin measurement.',pdf=a['pdf'],pdf_sha256=a['pdf_sha256'],xdc=str(xdc),xdc_sha256=hashlib.sha256(xdc.read_bytes()).hexdigest(),xci=str(xci),xci_sha256=hashlib.sha256(xci.read_bytes()).hexdigest(),mapped_ports_checked=95,data_dq_checked=48,data_dm_checked=6,data_dqs_wires_checked=12,control_address_ck_reset_checked=27,reference_clock_wires_checked=2,mismatches=[],routed_port_mappings_cross_checked_per_checkpoint=93,routed_checkpoints=[dict(path=c['routed_checkpoint'],sha256=c['sha256']) for c in checks],physical_mapping=[dict(component='M'+str(i+1),old_dq=[16*i,16*i+15],old_byte_lanes=[2*i,2*i+1],current_mig_logical_dq=([16*(i-1),16*i-1] if 1<=i<=3 else None),image_payload_used=i in (1,2),pdf_page=17 if i<2 else 18) for i in range(5)],m4_current_ports=m4,schematic_part_label='MT40A512M16TB-062E_R',schematic_density='8Gbit; 512M x16',selected_ip_parameters={k:params[k][0]['value'] for k in want},timing_note='Generated RTL is configured for tCK=1071ps, CL13, CWL10, tRCD13tCK, tRP13tCK, tRAS30tCK, tRFC327tCK. Schematic itself provides no independent timing or measured margin evidence. Exact base memory part and 8Gb x16 density agree; this is not a physical board-population or timing-signoff assertion.',clock_schematic=dict(pdf_page=11,oscillator='Y2 590BD200M000DG',supply='FU_3V3_VCCO',out_p='Y2.4 through C523=0.1uF to FU_DDR4_SYSCLK_P / FPGA.AR32',out_n='Y2.5 through C522=0.1uF to FU_DDR4_SYSCLK_N / FPGA.AT32',bias='R634/R635 and R637/R638: each leg 1k to1.2V and1k toGND; nominal0.6V common mode',differential_resistor='R636=100ohm 1% between SYSCLK_P/N'),limitations=['Current XDC top comment still describes lowerx64; executable assignments and later comment implement remappedx48.','M1 and M5 data are omitted from MIG but their shared CA/clock/control connections remain on the schematic.','Mapping M4 to historically faulty lanes does not prove a defective M4 die; solder, PCB, power, timing and FPGA IO remain possible fault locations.','Schematic labels and controller setup do not prove actual populated parts or board rework.','No PCB routing/length/impedance, waveform, temperature, voltage margin or loaded bitstream verification was performed.'])
(out/'schematic_mapping_audit.json').write_text(json.dumps(summary,indent=2))
print(json.dumps({k:summary[k] for k in ['mapped_ports_checked','data_dq_checked','data_dm_checked','data_dqs_wires_checked','control_address_ck_reset_checked','reference_clock_wires_checked','mismatches']},indent=2))
print('M4')
for r in m4:print(r['mig_port'],r['fpga_package_pin'],r['schematic_net'],r['dram_terminal'],r['component_ball'])

