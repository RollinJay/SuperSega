"""Does the emulator actually implement what the machine profile claims?
Written because the profile is a specification and drift between the two is
invisible to both the wiring audit and the test suite.

Every value a claim names is read from the profile and looked for in the page,
so a change to either side shows up as a mismatch. Claims about behaviour the
profile describes in words (keyboard ghosting, the pointing devices) check that
the code implementing it is present."""
import json, re, sys

if len(sys.argv)<3:
    sys.exit('usage: profile_crosscheck.py emulator.html super_sega_machine_v7.json')
prof=json.load(open(sys.argv[2]))
html=open(sys.argv[1]).read()
js=re.search(r'<script>([\s\S]*)</script>',html).group(1)

def hexlit(v, digits=2):
    """'0x0a', '$0A' or 10 -> '0x0A', the way the page writes hex literals."""
    if isinstance(v, str): v = int(v.replace('$', '0x'), 16)
    return '0x%0*X' % (digits, v)
def first_hex(text):
    """The first $XX / 0xXX value in a profile sentence."""
    m = re.search(r'(?:\$|0x)([0-9A-Fa-f]+)', text)
    return int(m.group(1), 16) if m else None

rows=[]
def chk(claim, ok, detail=''):
    rows.append((claim, bool(ok), detail))

# --- values the profile states that the emulator must match ---
wram=prof['memory']['work_ram']
chk('work RAM %d bytes'%wram['size_bytes'],
    'this.wram=new Uint8Array(0x%X)'%wram['size_bytes'] in js)
chk('work RAM %d banks'%wram['banks'], 'this.wramBank=v&%d;'%(wram['banks']-1) in js, 'bank register masked to the bank count')
chk('work RAM bank port %s'%wram['bank_register_port'], 'case %s: this.wramBank='%hexlit(wram['bank_register_port']) in js)

turbo=prof['cpu']['turbo']
chk('turbo on port %s'%turbo['control_port'], 'case %s:'%hexlit(turbo['control_port']) in js)
chk('turbo NOT on 0x3F', 'turbo=[1,1.25,1.5,1.75,2][((v>>4)&7)' not in js,
    'the v5 placement is gone')

bs=prof['cpu']['bus_synchroniser']['cadence_tstates']
chk('VDP cadence %d/%d T-states'%(bs['active_video'],bs['vblank']),
    'this.vdpActive()? %d : %d'%(bs['active_video'],bs['vblank']) in js)

rs=prof['cpu']['reset_state']
sp=re.search(r'SP \$([0-9A-Fa-f]{4})', rs)
chk('CPU hands over with SP %s'%(sp and '$'+sp.group(1)), sp and 'this.SP=%s;'%hexlit(sp.group(1),4) in js)

kb=prof['input']['keyboard']
kbrd=js[js.find('if(p>=0xC0&&p<=0xDF&&this.kbActive()){'):][:600]   # the PPI read decode
for port,desc in kb['ports'].items():
    n=int(port,16)
    if 'output' in desc:                        # written: row select / cassette / printer
        ok='(p&3)===%d){ this.kb.portC=v'%(n&3) in js
    elif 'not readable' in desc:                # reads $FF
        ok=(n&3)==3 and 'return 0xFF;' in kbrd
    else:                                       # read: matrix data
        ok='(p&3)===%d) return this.kb.port'%(n&3) in kbrd
    chk('keyboard port %s decoded (%s)'%(port, desc.split(',')[0]), 0xC0<=n<=0xDF and ok)
chk('keyboard row select on 0xDE', "(p&3)===2){ this.kb.portC=v" in js)
chk('keyboard control not readable', 'return 0xFF;                                  // $DF' in js)
chk('keyboard ghosting modelled', 'K.ghost=' in js)
chk('keyboard active low', '(~m)&0xFF' in js)

pv=prof['vdp_registers']['power_on_values']
want=[hexlit(pv['R%d'%i]) for i in range(11)]
chk('VDP power-on values R0-R10', '['+','.join(want)+']' in js, ' '.join(want))

det=prof['machine']['detection']
chk('header checked at %s'%', '.join(det['header_offsets']),
    '['+','.join(hexlit(o,4) for o in det['header_offsets'])+']' in js)
for code,name in det['region_codes'].items():
    chk('region %s = %s'%(code,name), "'%s'"%name in js)

mp=prof['media']['mappers']
for fam in [k for k in mp if isinstance(mp[k],dict)]:
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
chk('SF-7000 %d bytes RAM'%sf['ram_bytes'], 'const S={ram:new Uint8Array(0x%X)'%sf['ram_bytes'] in js)
chk('SF-7000 ROM overlay write-through', 'S.write=(a,v)=>{ S.ram[a]=v; }' in js)
chk('SF-7000 bit set/reset on 0xE7', 'S.control=v=>' in js)
g=re.match(r'(\d+) tracks x (\d+) sectors x (\d+) bytes', sf['floppy']['geometry'])
chk('floppy geometry %s'%sf['floppy']['geometry'],
    g and 'tracks:%s, sectors:%s, bytes:%s'%g.groups() in js)

# --- claims that were previously in the profile but untested, so drift went unseen ---
chk('display heights selected by M1-M4 as the profile states (v7: M2 enables, M1 -> 224, M3 -> 240)',
    'const M1=(this.reg[1]>>4)&1' in js and 'if(M4&&M2){ if(M1&&!M3) return 224; if(M3&&!M1) return 240; }' in js,
    'the v6 rule (M4 and M3) had M2 and M3 swapped; MAME sega315_5246 and Gearsystem use M2 as the enable')
chk('224 and 240 reachable', "return 224" in js and "return 240" in js)
m3e=prof['memory']['port_3E_memory_enables']
chk('port 0x3E enables act, not merely stored',
    '$3E bit 2 set disables the joysticks' in js and 'internal RAM disabled' in js,
    'six documented bits')
r3e=first_hex(m3e['reset_value'])
chk('0x3E resets to %s'%hexlit(r3e), 'this.memCtl=%s'%hexlit(r3e) in js)

ptr=prof['input']['pointing_devices']
chk('mouse: relative deltas', 'P.buildMouse=' in js)
chk('trackball: absolute counters', 'P.ballX' in js)
chk('trackball on port A low nibble', "kind==='pad'&&which===0" in js)

p3f=prof['input']['port_3F']
r3f=first_hex(p3f['reset_state'])
chk('0x3F resets to %s'%hexlit(r3f), 'this.ioCtl=%s'%hexlit(r3f) in js)
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
