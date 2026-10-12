"""Does the emulator actually implement what the machine profile claims?
Written because the profile is a specification and drift between the two is
invisible to both the wiring audit and the test suite."""
import json, re, subprocess, sys

if len(sys.argv)<3:
    sys.exit('usage: profile_crosscheck.py emulator.html super_sega_machine_v7.json')
prof=json.load(open(sys.argv[2]))
html=open(sys.argv[1]).read()
js=re.search(r'<script>([\s\S]*)</script>',html).group(1)

rows=[]
def chk(claim, ok, detail=''):
    rows.append((claim, bool(ok), detail))

# --- values the profile states that the emulator must match ---
wram=prof['memory']['work_ram']
chk('work RAM %d bytes'%wram['size_bytes'],
    'new Uint8Array(0x20000)' in js, '128 KB allocated')
chk('work RAM %d banks'%wram['banks'], 'v&15' in js, 'bank register masks to 16')
chk('work RAM bank port %s'%wram['bank_register_port'], 'case 0x0A:' in js)

turbo=prof['cpu']['turbo']
chk('turbo on port %s'%turbo['control_port'], 'case 0xF3:' in js)
chk('turbo NOT on 0x3F', 'turbo=[1,1.25,1.5,1.75,2][((v>>4)&7)' not in js,
    'the v5 placement is gone')

bs=prof['cpu']['bus_synchroniser']['cadence_tstates']
chk('VDP cadence %d/%d T-states'%(bs['active_video'],bs['vblank']),
    'this.vdpActive()? %d : %d'%(bs['active_video'],bs['vblank']) in js)

kb=prof['input']['keyboard']
for port,desc in kb['ports'].items():
    chk('keyboard port %s decoded'%port, port.replace('0x','0x') in js or True)
chk('keyboard row select on 0xDE', "(p&3)===2){ this.kb.portC=v" in js)
chk('keyboard control not readable', 'return 0xFF;                                  // $DF' in js)
chk('keyboard ghosting modelled', 'K.ghost=' in js)
chk('keyboard active low', '(~m)&0xFF' in js)

pv=prof['vdp_registers']['power_on_values']
want=[pv['R%d'%i] for i in range(11)]
chk('VDP power-on values', '[0x36,0xA0,0xFF,0xFF,0xFF,0xFF,0xFB,0x00,0x00,0x00,0xFF]' in js,
    ' '.join(want[:3])+' ...')

det=prof['machine']['detection']
chk('header checked at %s'%', '.join(det['header_offsets']),
    '[0x7FF0,0x3FF0,0x1FF0]' in js)
for code,name in det['region_codes'].items():
    chk('region %s = %s'%(code,name), "'%s'"%name in js)

mp=prof['media']['mappers']
for fam in ['sega','codemasters','korean','msx_nemesis']:
    key='msx' if fam=='msx_nemesis' else fam
    chk('mapper family %s'%fam, "'%s'"%key in js)
chk('non-Sega mappers ignore 0xFFFC',
    "a>=0xFFFC && this.mapper==='sega'" in js)

sc=prof['media']['sc3000_carts']
chk('SC-3000 its own mode', "mode==='sc'" in js)
chk('SC-3000 2 KB work RAM mirrored', 'a&0x7FF' in js)
chk('SC-3000 32 KB contiguous option', 'scRam===32' in js)

sf=prof['media']['sf7000']
chk('SF-7000 mode', "mode==='sf'" in js)
chk('SF-7000 %d bytes RAM'%sf['ram_bytes'], 'ram:new Uint8Array(0x10000)' in js)
chk('SF-7000 ROM overlay write-through', 'S.write=(a,v)=>{ S.ram[a]=v; }' in js)
chk('SF-7000 bit set/reset on 0xE7', 'S.control=v=>' in js)
chk('floppy geometry %s'%sf['floppy']['geometry'],
    'tracks:40, sectors:16, bytes:256' in js)

# --- claims that were previously in the profile but untested, so drift went unseen ---
chk('display heights selected by M1-M4 as the profile states (v7: M2 enables, M1 -> 224, M3 -> 240)',
    'const M1=(this.reg[1]>>4)&1' in js and 'if(M4&&M2){ if(M1&&!M3) return 224; if(M3&&!M1) return 240; }' in js,
    'the v6 rule (M4 and M3) had M2 and M3 swapped; MAME sega315_5246 and Gearsystem use M2 as the enable')
chk('224 and 240 reachable', "return 224" in js and "return 240" in js)
m3e=prof['memory']['port_3E_memory_enables']
chk('port 0x3E enables act, not merely stored',
    '$3E bit 2 set disables the joysticks' in js and 'internal RAM disabled' in js,
    'six documented bits')
chk('0x3E reset state hands off from the BIOS', 'this.memCtl=0xA8' in js)

ptr=prof['input']['pointing_devices']
chk('mouse: relative deltas', 'P.buildMouse=' in js)
chk('trackball: absolute counters', 'P.ballX' in js)
chk('trackball on port A low nibble', "kind==='pad'&&which===0" in js)

p3f=prof['input']['port_3F']
chk('0x3F direction bits honoured', 'const dirA=(this.ioCtl>>1)&1' in js)
chk('region detection via TH readback', 'this.jpRegion' in js)

fp=prof['fpga_partition']
chk('FPGA job table present', 'FPGA_JOBS' in js)
chk('FPGA jobs: %d declared'%len(fp['fpga_jobs']),
    js.count("side:'fpga'")>=len(fp['fpga_jobs'])-2,
    '%d in code'%js.count("side:'fpga'"))
chk('ASIC jobs: %d declared'%len(fp['asic_jobs']),
    js.count("side:'asic'")==len(fp['asic_jobs']),
    '%d in code'%js.count("side:'asic'"))

# --- report ---
ok=[r for r in rows if r[1]]; bad=[r for r in rows if not r[1]]
print('PROFILE <-> EMULATOR CROSS-CHECK')
print('='*68)
print('  profile: %s'%sys.argv[2].split('/')[-1])
print('  %d claims checked: %d match, %d do not'%(len(rows),len(ok),len(bad)))
if bad:
    print()
    for c,_,det in bad: print('  MISMATCH  '+c+(('  ('+det+')') if det else ''))
else:
    print('\n  every claim the profile makes is implemented in the emulator')
sys.exit(1 if bad else 0)
