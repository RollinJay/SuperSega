#!/usr/bin/env python3
"""Consolidated emulator fix, October 2026 (v7 reconciliation).

Every change states which side it belongs to:
  MODEL - the emulator's model of the machine now does what the machine does.
          These are corrections to the emulated hardware, not changes to it.
  APP   - the emulator application only (tooling, comments, UI).

Each anchor must match the stated number of times before anything is written,
so a stale anchor stops the script instead of silently missing an edit.
Usage: fix_emulator_v7.py IN.html OUT.html
"""
import sys

SRC, DST = sys.argv[1], sys.argv[2]
h = open(SRC, encoding='utf-8').read()

FIXES = []
def fix(fid, side, what, old, new, count=1):
    FIXES.append((fid, side, what, old, new, count))

# ---------------------------------------------------------------- Z80
fix('M1', 'MODEL', 'Interrupt taken in HALT returns to the instruction after HALT',
    'if(this.halt){this.halt=0;this.PC=(this.PC+1)&0xFFFF;}',
    'if(this.halt) this.halt=0;   /* PC already points past HALT */',
    count=2)

fix('M2a', 'MODEL', 'EI: interrupts are accepted only after the instruction that follows EI',
    '''  step(){
    if(this.halt){ this.tc+=4; return 4; }''',
    '''  step(){
    /* EI sets eiPend; it survives until the NEXT instruction starts, so the
       interrupt check that follows EI itself sees it and waits one instruction. */
    this.eiPend=0;
    if(this.halt){ this.tc+=4; return 4; }''')
fix('M2b', 'MODEL', 'EI: remove the end-of-step clear that made EI take effect at once',
    '''    this.main(op,idx,d);
    if(this.eiPend){ this.eiPend=0; }
    return this.tc-t0;''',
    '''    this.main(op,idx,d);
    return this.tc-t0;''')

fix('M3', 'MODEL', 'DD/FD: displacement byte only for (IX+d)/(IY+d) memory forms, with their T-states',
    '''      if((op&0xC0)!==0x40 ? ((op&7)===6||((op>>3)&7)===6) : (((op>>3)&7)===6||(op&7)===6)) d=(this.fetch()<<24)>>24;
      else if(op===0x34||op===0x35||op===0x36) d=(this.fetch()<<24)>>24;''',
    '''      /* Only the forms that address (HL) take a displacement: LD r,(HL) and
         LD (HL),r (not HALT), the eight ALU A,(HL), INC/DEC (HL) and LD (HL),n.
         Every other prefixed opcode either uses IX/IY whole or ignores the
         prefix; reading a displacement for those (LD IXH,n, ADD A,n ...) ate the
         operand. (IX+d) costs 8 more T-states than (HL); LD (IX+d),n costs 5. */
      const mem=(op>=0x40&&op<0x80&&op!==0x76&&((op&7)===6||((op>>3)&7)===6))
              ||(op&0xC7)===0x86||op===0x34||op===0x35||op===0x36;
      if(mem){ d=(this.fetch()<<24)>>24; this.tc+=(op===0x36)?5:8; }''')

fix('M16', 'MODEL', 'DD/FD followed by another prefix costs 4 T-states, not 8',
    '''      if(op===0xDD||op===0xFD){ this.PC=(this.PC-1)&0xFFFF; this.tc+=CYC[0]; return this.tc-t0; }''',
    '''      if(op===0xDD||op===0xFD){ this.PC=(this.PC-1)&0xFFFF; return this.tc-t0; }   /* ignored prefix: its own 4 T */''')
fix('M17a', 'MODEL', 'Keep T-states added during CB/ED execution (bus-sync holds and wait states were lost: `tc+=f()` reads tc before f runs)',
    '''      if(op===0xCB){ d=(this.fetch()<<24)>>24; const sub=this.fetch(); this.tc+=this.cb(sub,idx,d,true); return this.tc-t0; }
      if(op===0xED){ this.tc+=this.ed(this.fetch()); return this.tc-t0; }''',
    '''      /* `this.tc+=this.ed(...)` would read tc BEFORE ed() runs and drop any
         hold the bus synchroniser or a wait state adds during it. */
      if(op===0xCB){ d=(this.fetch()<<24)>>24; const sub=this.fetch(); const c=this.cb(sub,idx,d,true); this.tc+=c; return this.tc-t0; }
      if(op===0xED){ const c=this.ed(this.fetch()); this.tc+=c; return this.tc-t0; }''')
fix('M17b', 'MODEL', 'Same for unprefixed CB',
    '''      this.tc+=this.cb(sub,4,0,false); return this.tc-t0;''',
    '''      { const c=this.cb(sub,4,0,false); this.tc+=c; } return this.tc-t0;''')
fix('M17c', 'MODEL', 'Same for unprefixed ED (OUTI/OTIR/IN/OUT (C) reach the VDP here)',
    '''      this.tc+=this.ed(sub); return this.tc-t0;''',
    '''      { const c=this.ed(sub); this.tc+=c; } return this.tc-t0;''')
fix('M4', 'MODEL', 'DDCB/FDCB: 20 T-states for BIT, 23 for the rest (prefix T-states already counted)',
    'v=this.rb(a); cost=(k===1)?20:23;',
    'v=this.rb(a); cost=(k===1)?16:19;   /* +4 for the DD/FD prefix = 20/23 */')

# ---------------------------------------------------------------- VDP
fix('M6a', 'MODEL', 'Scroll latches: initialised at reset',
    '''    this.line=0; this.lineCtr=0; this.status=0; this.irqLine=0;
    this.fb=new Uint32Array(W*H);''',
    '''    this.line=0; this.lineCtr=0; this.status=0; this.irqLine=0;
    /* Horizontal scroll is latched once per line before the line is drawn and
       vertical scroll once per frame: a write lands on the NEXT line or frame. */
    this.hsLatch=0; this.vsLatch=0;
    this.fb=new Uint32Array(W*H);''')
fix('M6b', 'MODEL', 'Renderer reads the latched scroll values',
    '    let hsc=this.reg[8], vsc=this.reg[9];',
    '    let hsc=this.hsLatch, vsc=this.vsLatch;')
fix('M6c', 'MODEL', 'Latch H scroll at each line boundary and V scroll at the frame boundary',
    '''    if(this.line===h){ this.status|=0x80; }
    this.line++;
    const total=this.m.pal?313:262;
    if(this.line>=total){ this.line=0; return true; }
    return false;''',
    '''    if(this.line===h){ this.status|=0x80; }
    this.line++;
    this.hsLatch=this.reg[8];
    const total=this.m.pal?313:262;
    if(this.line>=total){ this.line=0; this.vsLatch=this.reg[9]; return true; }
    return false;''')

fix('M5', 'MODEL', 'Horizontal scroll moves the background right: screen x = map x + scroll',
    'if(!inWin && !rowLock) sx=(sx-(hsc&255)+256)&255;',
    'if(!inWin && !rowLock) sx=(sx+(hsc&255))&255;')

fix('M7a', 'MODEL', 'Sprite Y: a sprite starts on line Y+1, and Y+1 of 241-256 wraps to the top',
    '''      if(sy===0xD0 && this.height()===192) break;
      sy=(sy+1)&255;''',
    '''      if(sy===0xD0 && this.height()===192) break;
      /* A sprite starts on line Y+1. When Y+1 is 241-256 it starts at Y+1-256
         instead, so Y = $F0-$FF shows the sprite's lower rows at the top of the
         screen. Gearsystem and MAME rule; a plain 8-bit compare differs only for
         32-line magnified sprites at Y = $E0-$EF. */
      let top=sy+1; if(top>240) top-=256;
      const dy=y-top;''')
fix('M7b', 'MODEL', 'Sprite Y: use the row offset from the (possibly wrapped) top line',
    '''      if(y<sy||y>=sy+sh) continue;''',
    '''      if(dy<0||dy>=sh) continue;''')
fix('M7c', 'MODEL', 'Sprite Y: row within the sprite from the wrapped offset',
    '''      let row=Math.floor((y-sy)/zm);''',
    '''      let row=Math.floor(dy/zm);''')

# ---------------------------------------------------------------- counters
fix('M8', 'MODEL', 'V counter follows the hardware jump table; H counter follows the line position',
    '''    if(p<0x80) return (p&1)? (this.vdp.line&0xFF) : (this.vdp.line&0xFF);''',
    '''    if(p<0x80) return (p&1)? this.hCounter() : this.vCounter();''')
fix('M8b', 'MODEL', 'V/H counter helpers',
    '''  /* SC-3000 keyboard: always live in SG/SC-3000 mode, and on Super Sega when''',
    '''  /* V counter. The 8-bit counter cannot count 262 or 313 lines, so it jumps
     back once per frame. Values from Charles MacDonald's VDP documentation:
       NTSC 192: 00-DA, D5-FF      NTSC 224: 00-EA, E5-FF     NTSC 240: 00-FF, 00-06
       PAL  192: 00-F2, BA-FF      PAL  224: 00-FF, 00-02, CA-FF
       PAL  240: 00-FF, 00-0A, D2-FF                                                  */
  vCounter(){
    const ln=this.vdp.line, hgt=this.vdp.height();
    if(!this.pal){
      if(hgt===192) return (ln<=0xDA? ln : ln-6)&0xFF;
      if(hgt===224) return (ln<=0xEA? ln : ln-6)&0xFF;
      return ln&0xFF;
    }
    if(hgt===192) return (ln<=0xF2? ln : ln-57)&0xFF;
    if(hgt===224) return (ln<=0x102? ln : ln-57)&0xFF;
    return (ln<=0x10A? ln : ln-57)&0xFF;
  }
  /* H counter: counts pixel pairs, 00-93 then E9-FF (171 values per line).
     Taken from the CPU's position in the current line. Hardware latches it on a
     TH edge (light gun); the live value is what an unlatched read approximates. */
  hCounter(){
    const mult=(this.mode==='ss')?(this.turbo||1):1;
    const pix=Math.floor(((this.lineT||0)/mult)*1.5);       // 342 pixel clocks / 228 CPU
    const hc=Math.min(170,pix>>1);
    return hc<=0x93? hc : (hc+0x55)&0xFF;
  }
  /* SC-3000 keyboard: always live in SG/SC-3000 mode, and on Super Sega when''')

fix('M18', 'MODEL', 'CRAM writes: Game Gear (and Super Sega native 12-bit) use byte addresses: even byte latched, odd byte commits the entry. GG colours were being written as SMS 6-bit values',
    '''      if(this.ss() && (this.fa()&0x01)){        // native 12-bit, byte latched
        const idx=(this.addr & (ext?0xFF:0x1F));
        if(this.cLatch<0){ this.cLatch=idx; this.cLo=v; }
        else { const e=this.cLatch; this.cram[e*2]=this.cLo; this.cram[e*2+1]=v&0x0F;
               this.pw[0]|=(1<<((e>>4)&15)); this.cLatch=-1; }
        this.addr=(this.addr+1)&0x3FFF; return;
      }''',
    '''      /* Game Gear CRAM is 64 bytes, two per entry (GGGGRRRR, ----BBBB). A write
         to an even address is held in a latch; the write to the odd address
         stores both bytes. Super Sega native mode is the same scheme over 512
         bytes when extended CRAM is on. (The native path used to index entries
         by byte address while the address advanced per byte, so sequential
         writes filled every other entry.) */
      if(this.m.mode==='gg' || (this.ss() && (this.fa()&0x01))){
        const a=this.addr & ((this.m.mode==='gg')?0x3F:(ext?0x1FF:0x3F));
        if(!(a&1)) this.cLo=v;
        else { const e=a>>1; this.cram[e*2]=this.cLo; this.cram[e*2+1]=v&0x0F;
               this.pw[0]|=(1<<((e>>4)&15)); }
        this.addr=(this.addr+1)&0x3FFF; return;
      }''')

fix('M23', 'MODEL', 'Sprite priority: the lowest-numbered sprite is on top. Every sprite pixel was drawn, so the LAST overlapping sprite won',
    '''          if(covered[fx]) hit=1;
          covered[fx]=1;
          if(pr && opaque[fx]) continue;''',
    '''          if(covered[fx]){ hit=1; continue; }   /* an earlier sprite already owns this pixel */
          covered[fx]=1;
          if(pr && opaque[fx]) continue;''')

# ---------------------------------------------------------------- frame loop
fix('M9', 'MODEL', 'Frame loop: interrupts between instructions, line overrun carried, frame flag kept until read',
    '''    V.status&=~0x80;
    let vbAt=0;
    for(let l=0;l<lines;l++){
      let t=0;
      while(t<per){
        if(this.cpu.halt && !b.halted){ b.halted=true; b.workEnd=this.frameCycles; b.synced=true; }
        const c=this.cpu.step(); t+=c; this.frameCycles+=c;
      }
      const wrapped=V.scanline();
      if(V.line===V.height()+1) vbAt=this.frameCycles;
      if(V.irqPending()) this.cpu.irq();
    }''',
    '''    /* The frame interrupt flag is NOT cleared here: it stays set until the
       status register is read, as on hardware. */
    let vbAt=0;
    const C=this.cpu;
    for(let l=0;l<lines;l++){
      /* The overrun of the last instruction of a line belongs to the next line;
         dropping it gave every line up to ~20 extra CPU cycles. */
      let t=this.lineCarry||0;
      while(t<per){
        this.lineT=t;
        if(C.halt && !b.halted){ b.halted=true; b.workEnd=this.frameCycles; b.synced=true; }
        let c=C.step();
        /* Interrupts are sampled between instructions, not once per line, and
           not in the instruction that follows EI. */
        if(C.IFF1 && !C.eiPend && V.irqPending()) c+=C.irq();
        t+=c; this.frameCycles+=c;
      }
      this.lineCarry=t-per;
      V.scanline();
      if(V.line===V.height()+1) vbAt=this.frameCycles;
    }''')
fix('M9b', 'MODEL', 'Frame loop state reset with the machine',
    '''    this.frameCycles=0;
  }
  loadCart(buf){''',
    '''    this.frameCycles=0;
    this.lineCarry=0; this.lineT=0;
  }
  loadCart(buf){''')

# ---------------------------------------------------------------- I/O reads
fix('M10', 'MODEL', 'I/O reads: Game Gear ports only in GG and Super Sega modes; GG $00 format; FM $F2 before the I/O-chip disable; Super Sega registers before the controller mirror',
    '''  inp(port){
    const p=port&0xFF;
    if(this.mode!=='sms'&&p<=0x06){
      if(p===0x00){ let v=0xFF; if(this.btn.start) v&=~0x80; return v; }
      return this.ggReg[p]||0xFF;
    }''',
    '''  inp(port){
    const p=port&0xFF;
    /* Game Gear low ports. Super Sega adopts the GG scheme, so a GG title retagged
       to Super Sega still reads Start at $00. Port $00: bit 7 Start (0 = pressed),
       bit 6 region (1 = export), bits 5-0 read 0 (bit 5 = NTSC). */
    if((this.mode==='gg'||this.mode==='ss')&&p<=0x06){
      if(p===0x00) return (this.jpRegion?0x00:0x40)|(this.btn.start?0x00:0x80);
      return this.ggReg[p];
    }
    /* Super Sega registers inside the $00-$3F mirror range are decoded by the
       FPGA, so they must answer before the controller-port mirror does. Ports in
       $07-$16 with nothing readable return $FF. */
    if(this.mode==='ss'&&p>=0x07&&p<=0x16){
      if(p===0x08) return (this.pcm.fifo.length<<4)&0x70;
      if(p===0x09) return this.slotSel;
      if(p===0x0B) return this.cardBank;
      if(p===0x0E) return 0;
      if(p===0x0F) return this.mathRes&0xFF;
      if(p===0x10) return (this.mathRes>>8)&0xFF;
      if(p===0x16) return 0x81;              // pad detected, detection complete
      return 0xFF;
    }
    /* FM latch. Japanese software disables the I/O chip ($3E bit 2) before reading
       $F2 so the chip does not fight the FM unit for the bus; the latch must still
       answer then. Bits 1-0 return the last value written. */
    if(p===0xF2&&this.fmPresent&&this.mode!=='sg') return this.fmReg&0x03;''')
fix('M10b', 'MODEL', 'I/O-chip disable: affects only the controller decode; not on Game Gear; not the fully decoded Super Sega window',
    '''    if((this.memCtl&0x04)&&(p===0xDC||p===0xDD||(p>=0xC0&&p<=0xFF))) return 0xFF;''',
    '''    if((this.memCtl&0x04)&&(this.mode==='sms'||this.mode==='ss')&&p>=0xC0
       &&!(this.mode==='ss'&&p>=0xF0&&p<=0xFA)) return 0xFF;''')
fix('M10c', 'MODEL', 'Remove the unreachable duplicate Super Sega read block',
    '''    if(this.mode==='ss'){
      if(p===0x08){ return (this.pcm.fifo.length<<4)&0x70; }
      if(p===0x09) return this.slotSel;
      if(p===0x0B) return this.cardBank;
      if(p===0x0E) return 0;
      if(p===0x0F) return this.mathRes&0xFF;
      if(p===0x10) return (this.mathRes>>8)&0xFF;
      if(p===0x16) return 0x81;              // pad detected, detection complete
      if(p>=0xF4&&p<=0xFA) return this.dma[p-0xF4];
    }
    if(p===0xF2) return this.fmPresent? (this.fmReg&0xFF) : 0xFF;''',
    '''    /* Super Sega decodes $F0-$FA fully: no controller mirror answers there. */
    if(this.mode==='ss'&&p>=0xF0&&p<=0xFA) return (p>=0xF4)? this.dma[p-0xF4] : 0xFF;''')
fix('M10d', 'MODEL', 'Remove the unreachable GG Start path (port $00 is handled at the top)',
    '''    if(p===0x00&&this.mode==='gg') return this.ggStart();
''', '')
fix('M11', 'MODEL', 'Game Gear serial registers $01-$05 power-on values ($7F, $FF, $00, $FF, $00); $06 stereo $FF',
    'this.turbo=1; this.ggReg=new Uint8Array(8);',
    'this.turbo=1; this.ggReg=Uint8Array.from([0xC0,0x7F,0xFF,0x00,0xFF,0x00,0xFF,0xFF]);')
fix('M11b', 'MODEL', 'GG writes: GG and Super Sega modes only; $00 read-only; $06 write-only',
    '''    if(this.mode!=='sms'&&p<=0x06){
      if(p===0x06){ (this.psgTarget||this.psg).stereo=v; return; }
      this.ggReg[p]=v; return;
    }''',
    '''    if((this.mode==='gg'||this.mode==='ss')&&p<=0x06){
      if(p===0x06){ (this.psgTarget||this.psg).stereo=v; return; }   /* write-only */
      if(p!==0x00) this.ggReg[p]=v;   /* $00 is read-only */
      return;
    }''')

# ---------------------------------------------------------------- bus sync
fix('M12', 'MODEL', 'Bus synchroniser measures the CPU\'s own T-state count and really holds the CPU',
    '''    const vdpNow=this.cycles/mult;              /* convert to the VDP's own time base */''',
    '''    /* The CPU's T-state count is the clock; the old code read a counter that
       nothing advanced, so every wait came out NaN and the CPU was never held. */
    const vdpNow=this.cpu.tc/mult;              /* convert to the VDP's own time base */''')
fix('M12b', 'MODEL', 'Bus synchroniser: the hold is CPU time, so it lengthens the instruction',
    '''    this.cycles+=waitCpu;''',
    '''    this.cpu.tc+=waitCpu;''')
fix('M12c', 'MODEL', 'Bus synchroniser: active display uses the real display height',
    '''    const h=(V.onB&&V.onB(0xC0))?((V.reg[16+2]>>6)&3)===2?240:224:192;
    return V.line>=0 && V.line<h;''',
    '''    return V.line>=0 && V.line<V.height();''')
fix('M13', 'MODEL', 'Cartridge-timing wait states lengthen the access instead of only being counted',
    '''    if(this.ws && a<0xC000){ this.waitPenalty+=this.ws; if(this.fpga) this.fpga.did('romWait'); }''',
    '''    if(this.ws && a<0xC000){ this.waitPenalty+=this.ws; this.cpu.tc+=this.ws;
      if(this.fpga) this.fpga.did('romWait'); }''')

fix('M12d', 'MODEL', 'Bus synchroniser also holds the CPU for VDP reads, not only writes',
    '''    if(p<0xC0) return (p&1)? this.vdp.ctrlR() : this.vdp.dataR();''',
    '''    if(p<0xC0){ this.busSync(); return (p&1)? this.vdp.ctrlR() : this.vdp.dataR(); }''')
fix('M14', 'MODEL', 'DMA from RAM reads work RAM (it read an array nothing writes, so it copied zeros)',
    '''      else if(sel===2) b=this.ram[0x8000+((src+i)&0x1FFF)];''',
    '''      else if(sel===2) b=this.wram[this.wramBank*0x2000+((src+i)&0x1FFF)];   /* work RAM, current bank */''')
fix('M15', 'MODEL', 'SG/SC/SF: writes to $00-$06 stay no-ops (they reached the GG registers before)',
    '''    if(this.mode==='ss'){
      switch(p){
        case 0x07:''',
    '''    if((this.mode==='sg'||this.mode==='sc'||this.mode==='sf')&&p<=0x06) return;
    if(this.mode==='ss'){
      switch(p){
        case 0x07:''')

# ---------------------------------------------------------------- app: state capture
fix('A2', 'APP', 'Save states include the 128 KB work RAM and the new CPU/VDP timing state',
    '''    ggReg:Array.from(m.ggReg), dma:Array.from(m.dma), mathRes:m.mathRes};
}''',
    '''    ggReg:Array.from(m.ggReg), dma:Array.from(m.dma), mathRes:m.mathRes,
    wram:b64(m.wram), eiPend:C.eiPend, lineCarry:m.lineCarry||0,
    hsLatch:V.hsLatch, vsLatch:V.vsLatch};
}''')
fix('A2b', 'APP', 'Load states restore them (older states without them still load)',
    '''  m.ggReg.set(st.ggReg); m.dma.set(st.dma);
}''',
    '''  m.ggReg.set(st.ggReg); m.dma.set(st.dma);
  if(st.wram) m.wram.set(unb64(st.wram));
  C.eiPend=st.eiPend||0; m.lineCarry=st.lineCarry||0;
  if(st.hsLatch!==undefined){ V.hsLatch=st.hsLatch; V.vsLatch=st.vsLatch; }
  else { V.hsLatch=V.reg[8]; V.vsLatch=V.reg[9]; }
}''')
fix('A3', 'APP', 'Dual-run FM capture snapshot holds work RAM (the shadow run leaked into the main run)',
    '''  mkSnap(){ return {ram:new Uint8Array(0x10000),vram:new Uint8Array(0x8000),''',
    '''  mkSnap(){ return {ram:new Uint8Array(0x10000),wram:new Uint8Array(0x20000),vram:new Uint8Array(0x8000),''')
fix('A3b', 'APP', 'Dual-run snapshot: capture',
    '''    s.ram.set(this.ram); s.vram.set(this.vdp.vram); s.cram.set(this.vdp.cram);''',
    '''    s.ram.set(this.ram); s.wram.set(this.wram); s.vram.set(this.vdp.vram); s.cram.set(this.vdp.cram);''')
fix('A3c', 'APP', 'Dual-run snapshot: timing state',
    '''      wramBank:this.wramBank,slotSel:this.slotSel,cardBank:this.cardBank,fmReg:this.fmReg};''',
    '''      wramBank:this.wramBank,slotSel:this.slotSel,cardBank:this.cardBank,fmReg:this.fmReg,
      ei:C.eiPend,lc:this.lineCarry||0,hl:V.hsLatch,vl:V.vsLatch};''')
fix('A3d', 'APP', 'Dual-run snapshot: restore',
    '''    this.ram.set(s.ram); this.vdp.vram.set(s.vram); this.vdp.cram.set(s.cram);''',
    '''    this.ram.set(s.ram); this.wram.set(s.wram); this.vdp.vram.set(s.vram); this.vdp.cram.set(s.cram);''')
fix('A3e', 'APP', 'Dual-run snapshot: restore timing state',
    '''    this.wramBank=o.wramBank;this.slotSel=o.slotSel;this.cardBank=o.cardBank;this.fmReg=o.fmReg;''',
    '''    this.wramBank=o.wramBank;this.slotSel=o.slotSel;this.cardBank=o.cardBank;this.fmReg=o.fmReg;
    C.eiPend=o.ei;this.lineCarry=o.lc;V.hsLatch=o.hl;V.vsLatch=o.vl;''')
fix('A4', 'APP', 'RAM search reads the work RAM the CPU sees (it read an unused array)',
    '''function ramSnap(){ return m.ram.slice(0x8000,0xA000); }''',
    '''function ramSnap(){ const b=m.wramBank*0x2000; return m.wram.slice(b,b+0x2000); }''')
fix('A4b', 'APP', 'RAM search table shows work RAM values',
    '''h+='<tr><td class="v">$'+addr.toString(16).toUpperCase()+'</td><td class="v">'+m.ram[0x8000+i]+''',
    '''h+='<tr><td class="v">$'+addr.toString(16).toUpperCase()+'</td><td class="v">'+m.wram[m.wramBank*0x2000+i]+''')
fix('A4c', 'APP', 'RAM freeze records the work RAM value',
    '''      else HACK.rs.freeze.push({i,v:m.ram[0x8000+i]});''',
    '''      else HACK.rs.freeze.push({i,v:m.wram[m.wramBank*0x2000+i]});''')
fix('A4d', 'APP', 'RAM freeze writes work RAM',
    '''      for(const f of HACK.rs.freeze) this.ram[0x8000+f.i]=f.v;''',
    '''      for(const f of HACK.rs.freeze) this.wram[this.wramBank*0x2000+f.i]=f.v;''')

fix('A5', 'APP', 'Self-test "SPRITES render" read framebuffer line 0 after drawing line 22 (false failure)',
    '''      V.renderLine(22);
      let n=0; for(let x=40;x<48;x++) if((V.fb[x]&0xFFFFFF)!==0) n++;''',
    '''      V.renderLine(22);
      let n=0; for(let x=40;x<48;x++) if((V.fb[22*W+x]&0xFFFFFF)!==0) n++;''')

# ---------------------------------------------------------------- PSG
fix('M20', 'MODEL', 'PSG noise: the shift register advances once per two counter periods (it ran an octave high)',
    '''    while(this.cnt[3]<=0){ this.cnt[3]+=nper;''',
    '''    /* The noise counter toggles a flip-flop exactly like a tone channel; the
       shift register advances on its rising edge, once per two counter periods.
       Shifting on every reload played all noise an octave high. */
    while(this.cnt[3]<=0){ this.cnt[3]+=nper; this.nff^=1; if(!this.nff) continue;''')
fix('M20b', 'MODEL', 'PSG noise: flip-flop cleared at reset',
    '''this.cnt=[0,0,0,0]; this.out=[1,1,1,1]; this.sr=0x8000; this.stereo=0xFF;''',
    '''this.cnt=[0,0,0,0]; this.out=[1,1,1,1]; this.sr=0x8000; this.stereo=0xFF; this.nff=0;''')
fix('M21', 'MODEL', 'PSG volume: 2 dB per attenuation step, step 15 silent (the curve was linear)',
    '''class PSG{''',
    '''/* SN76489 attenuation: 2 dB per step, 15 = off. Amplitude = 10^(-2v/20). */
const PSG_VOL=Array.from({length:16},(_,v)=>v===15?0:Math.pow(10,-v/10));
class PSG{''')
fix('M21b', 'MODEL', 'PSG volume table: tone channels',
    '''const a=(15-this.vol[c])/15*this.out[c]*0.16*this.gain[c]*this.master;''',
    '''const a=PSG_VOL[this.vol[c]&15]*this.out[c]*0.16*this.gain[c]*this.master;''')
fix('M21c', 'MODEL', 'PSG volume table: noise channel',
    '''const na=(15-this.vol[3])/15*this.out[3]*0.16*this.gain[3]*this.master;''',
    '''const na=PSG_VOL[this.vol[3]&15]*this.out[3]*0.16*this.gain[3]*this.master;''')

# ---------------------------------------------------------------- keyboard PPI
fix('M22', 'MODEL', 'Keyboard ghosting: take the closure over every row (it stopped after three passes)',
    '''for(let pass=0;pass<3;pass++){''',
    '''for(let pass=0;pass<8;pass++){      /* until no row joins: the full closure */''')
fix('M27', 'MODEL', 'Keyboard PPI reset state: all ports input, port C pulled up, so row 7 (the pads) is selected; software that never touches the PPI reads the pads',
    '''const K={down:Object.create(null), row:0, portC:0x07, ctrl:0x92, ghosting:true};''',
    '''/* Reset: the 8255 comes up with every port an input. Port C's pull-ups then
     select row 7, the pads, so SG-1000 software that never touches the PPI still
     reads its controllers with the keyboard attached. */
  const K={down:Object.create(null), row:7, portC:0x00, ctrl:0x9B, ghosting:true};''')
fix('M27b', 'MODEL', 'Keyboard PPI port C write: rows come from the latch only while port C (lower) is an output',
    '''if((p&3)===2){ this.kb.portC=v; this.kb.row=v&7;''',
    '''if((p&3)===2){ this.kb.portC=v; this.kb.row=(this.kb.ctrl&1)?7:(v&7);''')
fix('M27c', 'MODEL', 'Keyboard PPI control: a mode word clears the output latches (8255); bit 7 clear is bit set/reset on port C',
    '''if((p&3)===3){ this.kb.ctrl=v; return; }''',
    '''if((p&3)===3){                                // $DF : control register
        const K=this.kb;
        if(v&0x80){ K.ctrl=v; K.portC=0; }          // mode set: 8255 clears its output latches
        else { const b=(v>>1)&7; K.portC=(v&1)?(K.portC|(1<<b)):(K.portC&~(1<<b)); }  // bit set/reset
        K.row=(K.ctrl&1)?7:(K.portC&7);             // port C lower as input floats high: row 7
        return; }''')
fix('M28', 'MODEL', 'SF-7000 PPI: a mode word clears port C (8255), which also maps the IPL back in',
    '''if(v&0x80){ S.ctrl=v; return; }''',
    '''if(v&0x80){ S.ctrl=v; S.portCWrite(0); return; }   /* mode set clears the output latches */''')

# ---------------------------------------------------------------- controller ports
fix('M25', 'MODEL', 'Port A TR configured as an output reads back the level driven ($DC bit 5)',
    '''        if(b.a)v&=~0x10; if(b.b)v&=~0x20;
      }
      return v;
    }''',
    '''        if(b.a)v&=~0x10; if(b.b)v&=~0x20;
      }
      if(this.mode!=='gg' && !(this.ioCtl&0x01)) v=(v&~0x20)|((this.ioCtl>>4)&1)<<5;   /* TR A output */
      return v;
    }''')
fix('M25b', 'MODEL', 'Port B TR configured as an output reads back the level driven ($DD bit 3); Game Gear $DD bits 7-6 are $3F bits 7-6',
    '''      if(this.jpRegion || !this.th[1]) v&=~0x80;
    }
    return v;''',
    '''      if(this.jpRegion || !this.th[1]) v&=~0x80;
    }
    if(this.mode!=='gg' && !(this.ioCtl&0x04)) v=(v&~0x08)|((this.ioCtl>>6)&1)<<3;   /* TR B output */
    if(this.mode==='gg') v=(v&0x3F)|(this.ioCtl&0xC0);
    return v;''')
fix('M26', 'MODEL', 'Reads of $00-$3F not decoded as registers return $FF on SMS, GG and Super Sega (the controller mirror answered)',
    '''if(p<0x40){ return (p&1)?this.padIn(1):this.padIn(0); }''',
    '''if(p<0x40){
      if(this.mode==='sg'||this.mode==='sc'||this.mode==='sf') return (p&1)?this.padIn(1):this.padIn(0);
      return 0xFF; }''')
fix('M30', 'MODEL', 'Game Gear decodes only $C0/$DC (port A) and $C1/$DD (port B) above $C0; the rest read $FF',
    '''if(p>=0xC0&&p<=0xDF&&this.kbActive()){
      const padFn=n=>this.padBit(n);''',
    '''if(this.mode==='gg'&&p>=0xC0&&!(p===0xF2&&this.fmPresent)){
      if(p===0xC0||p===0xDC) return this.padIn(0);
      if(p===0xC1||p===0xDD) return this.padIn(1);
      return 0xFF; }
    if(p>=0xC0&&p<=0xDF&&this.kbActive()){
      const padFn=n=>this.padBit(n);''')

# ---------------------------------------------------------------- 224/240-line modes
fix('M29', 'MODEL', 'Frame buffer holds 240 lines; 224/240-line modes rendered only their first 192 lines',
    '''const W=256,H=192;''',
    '''const W=256,H=240;      /* tallest mode; the screen shows height() lines */''')
fix('M29e', 'APP', 'Comment: extra-height mode bits: M2 enables them, then M1 gives 224 lines and M3 gives 240 (the M3/M2 roles were swapped, so $36/$70 stayed at 192)',
    '''       M4=1 M3=1 M2=0 M1=1 -> 224 lines
       M4=1 M3=1 M2=1 M1=0 -> 240 lines''',
    '''       M4=1 M2=1 M1=1 M3=0 -> 224 lines
       M4=1 M2=1 M3=1 M1=0 -> 240 lines
     M2 is the enable: with M2 clear, Mode 4 is 192 lines whatever M1 and M3
     say (MAME sega315_5246 select_extended_res_mode4, Gearsystem).''')
fix('M29f', 'MODEL', 'Extra-height mode bits: decode',
    '''    if(M4&&M3){ if(M1&&!M2) return 224; if(M2&&!M1) return 240; }''',
    '''    if(M4&&M2){ if(M1&&!M3) return 224; if(M3&&!M1) return 240; }''')
fix('M29b', 'MODEL', '224/240-line modes: 32x32 name table at (R2 bits 3-2) x $1000 + $700',
    '''const ntBase=((this.reg[2]>>1)&7)*0x800;''',
    '''/* 224/240-line modes use a 32x32 name table at (R2 bits 3-2) x $1000 + $700
       and the map wraps at 256 lines; 192-line mode uses 32x28, wrapping at 224 */
    const ext=this.height()!==192;
    const ntBase=ext? ((((this.reg[2]>>2)&3)<<12)|0x700) : ((this.reg[2]>>1)&7)*0x800;''')
fix('M29c', 'MODEL', '224/240-line modes: map rows wrap at 32',
    '''const rowIdx=((ry>>3))%28;''',
    '''const rowIdx=ext? ((ry>>3)&31) : ((ry>>3)%28);''')
fix('M29d', 'MODEL', 'Window tilemap is 32x32 (rows 28-29 wrapped to 0-1 in the tall modes)',
    '''if(inWin) ntAddr=winBase+((y>>3)%28)*64+col*2;''',
    '''if(inWin) ntAddr=winBase+((y>>3)&31)*64+col*2;''')

fix('A6', 'APP', 'Self-test "height modes" used the swapped mode bits',
    '''      V.reg[0]=0x04; V.reg[1]=0x60|0x18; const a=V.height();''',
    '''      V.reg[0]=0x06; V.reg[1]=0x60|0x10; const a=V.height();''')

fix('A7', 'APP', 'Self-test "SK-1100 matrix": write the PPI mode word first, as software does (port C is an input until then)',
    '''      m.out(0xDE,0); m.kb.set('a',1); const held=m.inp(0xDC);''',
    '''      m.out(0xDF,0x92); m.out(0xDE,0); m.kb.set('a',1); const held=m.inp(0xDC);''')
fix('A7b', 'APP', 'Self-test "matrix ghosting": write the PPI mode word first',
    '''      m.kb.set('2',1); m.out(0xDE,1); const v=m.inp(0xDC);''',
    '''      m.kb.set('2',1); m.out(0xDF,0x92); m.out(0xDE,1); const v=m.inp(0xDC);''')

# ---------------------------------------------------------------- mappers
fix('M31', 'MODEL', 'Codemasters mapper powers up with banks 0, 1, 0 (machine profile; Gearsystem)',
    '''    this.cmRam=0;                               // Codemasters on-cart RAM enable''',
    '''    this.cmRam=0;                               // Codemasters on-cart RAM enable
    if(this.mapper==='codemasters') this.page=[0,1,0];''')
fix('M31b', 'MODEL', 'Codemasters registers decode at exactly $0000, $4000 and $8000 (Gearsystem, MAME); other ROM writes do nothing',
    '''      /* registers occupy the whole of each slot; games write the lowest address */
      if(a<0x4000){ this.page[0]=v; return; }
      if(a<0x8000){ this.page[1]=v; this.cmRam=(v&0x80)?1:0; return; }
      if(a<0xC000){
        if(this.cmRam && a>=0xA000){ this.ram[0x2000+(a&0x1FFF)]=v;
          this.sramDirty|=(1<<(((a&0x1FFF)>>8)&31)); return; }
        this.page[2]=v; return; }''',
    '''      /* registers at exactly $0000, $4000 and $8000 (Gearsystem and MAME decode
         the full address; every known title writes there) */
      if(a===0x0000){ this.page[0]=v; return; }
      if(a===0x4000){ this.page[1]=v; this.cmRam=(v&0x80)?1:0; return; }
      if(a===0x8000){ this.page[2]=v; return; }
      if(a<0xC000){
        if(this.cmRam && a>=0xA000){ this.ram[0x2000+(a&0x1FFF)]=v;
          this.sramDirty|=(1<<(((a&0x1FFF)>>8)&31)); }
        return; }''')
fix('M31c', 'MODEL', 'Korean mapper register decodes at exactly $A000 (Gearsystem, MAME)',
    '''      if(a>=0xA000&&a<0xC000){ this.page[2]=v; return; }''',
    '''      if(a===0xA000){ this.page[2]=v; return; }
      if(a<0xC000) return;''')

# ---------------------------------------------------------------- enhancement layer
fix('M32', 'MODEL', 'AEL pseudo-stereo: wrote $99 to the panning register, which silenced PSG tones 1 and 2. Now tone 0 left, tone 1 right, tone 2 and noise centre, applied only until software writes $06 (same as the RTL)',
    '''this.cnt=[0,0,0,0]; this.out=[1,1,1,1]; this.sr=0x8000; this.stereo=0xFF; this.nff=0;''',
    '''this.cnt=[0,0,0,0]; this.out=[1,1,1,1]; this.sr=0x8000; this.stereo=0xFF; this.nff=0;
    this.stereoSet=0;   /* software has written $06 since reset */''')
fix('M32b', 'MODEL', 'AEL pseudo-stereo: tone channels use the effective panning',
    '''      if(this.stereo&(0x10<<c)) L+=a*Math.min(1,1-p);
      if(this.stereo&(1<<c)) R+=a*Math.min(1,1+p);''',
    '''      if(st&(0x10<<c)) L+=a*Math.min(1,1-p);
      if(st&(1<<c)) R+=a*Math.min(1,1+p);''')
fix('M32c', 'MODEL', 'AEL pseudo-stereo: noise channel uses the effective panning',
    '''    if(this.stereo&0x80) L+=na*Math.min(1,1-pn);
    if(this.stereo&0x08) R+=na*Math.min(1,1+pn);''',
    '''    if(st&0x80) L+=na*Math.min(1,1-pn);
    if(st&0x08) R+=na*Math.min(1,1+pn);''')
fix('M32d', 'MODEL', 'AEL pseudo-stereo: effective panning computed per sample',
    '''  sample(step){
    let L=0,R=0;''',
    '''  sample(step){
    let L=0,R=0;
    const st=(this.pstereo&&!this.stereoSet)?0xDE:this.stereo;   /* AEL pseudo-stereo until $06 is written */''')
fix('M32e', 'MODEL', 'AEL pseudo-stereo: a $06 write marks the panning as software-owned',
    '''      if(p===0x06){ (this.psgTarget||this.psg).stereo=v; return; }   /* write-only */''',
    '''      if(p===0x06){ const P=(this.psgTarget||this.psg); P.stereo=v; P.stereoSet=1; return; }   /* write-only */''')
fix('M32f', 'MODEL', 'AEL pseudo-stereo: the setting survives a machine reset; stock modes only (Super Sega software sets its own panning)',
    '''    this.ael=this.ael||{sprlimit:false,ovf:false,tmscol:true,ggwide:false,startpause:false,autofire:false,stereo:false};''',
    '''    this.ael=this.ael||{sprlimit:false,ovf:false,tmscol:true,ggwide:false,startpause:false,autofire:false,stereo:false};
    this.psg.pstereo=!!this.ael.stereo&&this.mode!=='ss';''')
fix('M32g', 'MODEL', 'AEL pseudo-stereo toggle sets the flag (stock modes only) instead of writing $99 to the panning register',
    '''  if(k==='stereo') m.psg.stereo=m.ael.stereo?0x99:0xFF;''',
    '''  if(k==='stereo') m.psg.pstereo=m.ael.stereo&&m.mode!=='ss';''')

fix('A8', 'APP', 'Save states keep whether software owns the PSG panning',
    '''      cnt:P.cnt.slice(),out:P.out.slice(),sr:P.sr,stereo:P.stereo},''',
    '''      cnt:P.cnt.slice(),out:P.out.slice(),sr:P.sr,stereo:P.stereo,stereoSet:P.stereoSet||0},''')
fix('A8b', 'APP', 'Load states restore it',
    '''  P.out=st.psg.out.slice(); P.sr=st.psg.sr; P.stereo=st.psg.stereo;''',
    '''  P.out=st.psg.out.slice(); P.sr=st.psg.sr; P.stereo=st.psg.stereo; P.stereoSet=st.psg.stereoSet||0;''')

fix('M33', 'MODEL', 'AEL sprite-limit boost and stock overflow flag apply to stock software only; Super Sega software sets its own limit (Feature Enable A bit 4)',
    '''  spriteLimit(){ if(this.m.ael&&this.m.ael.sprlimit) return 16; return this.on(0x10)?16:8; }
  legacySprLimit(){ if(this.m.ael&&this.m.ael.sprlimit) return this.spriteLimit(); return this.onC(0x02)?this.spriteLimit():4; }''',
    '''  /* Enhancement-layer boosts are for stock software: in Super Sega mode the
     software's own Feature Enable bits decide. */
  spriteLimit(){ if(this.m.ael&&this.m.ael.sprlimit&&!this.ss()) return 16; return this.on(0x10)?16:8; }
  legacySprLimit(){ if(this.m.ael&&this.m.ael.sprlimit&&!this.ss()) return this.spriteLimit(); return this.onC(0x02)?this.spriteLimit():4; }''')
fix('M33b', 'MODEL', 'AEL stock overflow flag: stock software only',
    '''      if(drawn>=8 && this.m.ael&&this.m.ael.ovf&&limit>8){''',
    '''      if(drawn>=8 && this.m.ael&&this.m.ael.ovf&&limit>8&&!this.ss()){''')
fix('M34', 'MODEL', 'FM detection latch at $F2 only in Master System and Super Sega modes (a Game Gear has no FM; on the SC-3000 $F2 is the PPI mirror)',
    '''    this.fmPresent=(this.mode!=='sg'); this.fmReg=0;''',
    '''    this.fmPresent=(this.mode==='sms'||this.mode==='ss'); this.fmReg=0;''')
fix('A9', 'APP', 'Dual-run FM capture restores the mode\'s FM presence instead of forcing it on',
    '''    this.psgTarget=null; this.noRender=false; this.fmPresent=true;''',
    '''    this.psgTarget=null; this.noRender=false; this.fmPresent=(this.mode==='sms'||this.mode==='ss');''')

# ---------------------------------------------------------------- input and debug ports
fix('M35', 'MODEL', 'AEL auto-fire: stock modes only (Super Sega software reads C as a button of its own); computed per read instead of overwriting the pad state, which left button 2 held when C was released mid-toggle',
    '''  padIn(which){
    const b=this.btn;
    if(this.ael&&this.ael.autofire&&b.c){ b.b=(this.afTick>>1)&1; }''',
    '''  /* Enhancement-layer auto-fire, stock modes only: while C is held, button 2
     toggles every two frames. Computed per read; the pad state is not changed. */
  effBtn(){
    const b=this.btn;
    if(this.ael&&this.ael.autofire&&b.c&&this.mode!=='ss') return Object.assign({},b,{b:(this.afTick>>1)&1});
    return b;
  }
  padIn(which){
    const b=this.effBtn();''')
fix('M35b', 'MODEL', 'AEL auto-fire also reaches the pads read through the SK-1100 PPI (row 7) in SG-1000/SC-3000 modes',
    '''  padBit(name){
    const b=this.btn;''',
    '''  padBit(name){
    const b=this.effBtn();''')
fix('M36', 'MODEL', 'Debug unit reads at $FB-$FF only in Super Sega mode; in the stock modes those ports read as on the stock machine (controller mirror, $FF on the Game Gear). Writes still reach the debug unit in every mode, which stock hardware ignores',
    '''    if(p>=0xFB&&this.dbg) return this.dbg.read(p);''',
    '''    if(p>=0xFB&&this.dbg&&this.mode==='ss') return this.dbg.read(p);''')

# ---------------------------------------------------------------- enhancement layer: turbo and VRAM speed-up
fix('M37', 'MODEL', 'AEL turbo for stock software: the CPU clock multiplier is the $F3 step in Super Sega mode and the enhancement-layer step in the stock modes (only the $F3 step existed, and only in Super Sega mode)',
    '''  hCounter(){
    const mult=(this.mode==='ss')?(this.turbo||1):1;''',
    '''  /* CPU clock multiplier. Super Sega software sets its own step through $F3; the
     enhancement layer's turbo step is for stock software (machine profile v7). */
  cpuMult(){ return this.mode==='ss' ? (this.turbo||1) : ((this.ael&&this.ael.turbo)||1); }
  hCounter(){
    const mult=this.cpuMult();''')
fix('M37b', 'MODEL', 'Bus synchroniser uses the effective multiplier; AEL VRAM speed-up (stock software only) removes the access wait',
    '''  busSync(){
    const mult=(this.mode==='ss')?(this.turbo||1):1;
    if(mult<=1) return 0;                       /* at base clock the CPU cannot outrun it */''',
    '''  busSync(){
    const mult=this.cpuMult();
    if(mult<=1) return 0;                       /* at base clock the CPU cannot outrun it */
    /* Enhancement-layer VRAM speed-up (stock software only): no access wait */
    if(this.ael&&this.ael.vramboost&&this.mode!=='ss') return 0;''')
fix('M37c', 'MODEL', 'Cartridge wait states use the effective multiplier',
    '''    const mult=(this.mode==='ss')?(this.turbo||1):1;   // turbo is a multiplier, not a step''',
    '''    const mult=this.cpuMult();                          // turbo is a multiplier, not a step''')
fix('M37d', 'MODEL', 'Frame loop: CPU cycles per line use the effective multiplier',
    '''    const mult=(this.mode==='ss')?this.turbo:1;
    const per=Math.round(base*mult);''',
    '''    const mult=this.cpuMult();
    const per=Math.round(base*mult);''')
fix('M37e', 'MODEL', 'Enhancement-layer settings gain the VRAM speed-up switch and the turbo step for stock software (off and 100 % by default)',
    '''    this.ael=this.ael||{sprlimit:false,ovf:false,tmscol:true,ggwide:false,startpause:false,autofire:false,stereo:false};''',
    '''    this.ael=this.ael||{sprlimit:false,ovf:false,tmscol:true,ggwide:false,startpause:false,autofire:false,stereo:false,vramboost:false,turbo:1};''')
fix('A10', 'APP', 'Turbo selector sets the enhancement-layer step for stock software',
    '''    <select id="turbo" title="Turbo step (Super Sega only)">''',
    '''    <select id="turbo" title="Turbo boost for stock software (Super Sega titles set their own step through $F3)">''')
fix('A10b', 'APP', 'Turbo selector handler writes the enhancement-layer step, not the $F3 step',
    '''document.getElementById('turbo').onchange=e=>{ m.turbo=parseFloat(e.target.value);
  document.getElementById('bt').textContent=Math.round(m.turbo*100)+'%'; };''',
    '''document.getElementById('turbo').onchange=e=>{ m.ael.turbo=parseFloat(e.target.value);
  document.getElementById('bt').textContent=Math.round(m.cpuMult()*100)+'%'; };''')
fix('A10c', 'APP', 'Budget panel shows the effective clock (cycles per frame, step)',
    '''  document.getElementById('bp').textContent=Math.round(228*(m.mode==='ss'?m.turbo:1)*V.height()).toLocaleString();''',
    '''  document.getElementById('bp').textContent=Math.round(228*m.cpuMult()*V.height()).toLocaleString();''')
fix('A10d', 'APP', 'Budget panel step display',
    '''  document.getElementById('bt').textContent=Math.round((m.mode==='ss'?m.turbo:1)*100)+'%';''',
    '''  document.getElementById('bt').textContent=Math.round(m.cpuMult()*100)+'%';''')
fix('A10e', 'APP', 'Debug views show the effective turbo step',
    '''  ft+='<tr><td>Turbo step</td><td class="v">'+Math.round((m.mode==='ss'?m.turbo:1)*100)+'%</td></tr>';''',
    '''  ft+='<tr><td>Turbo step</td><td class="v">'+Math.round(m.cpuMult()*100)+'%</td></tr>';''')
fix('A10f', 'APP', 'Cycles-per-line display uses the effective multiplier',
    '''  document.getElementById('cyc').textContent=Math.round(228*(m.mode==='ss'?m.turbo:1))+' cyc/line';''',
    '''  document.getElementById('cyc').textContent=Math.round(228*m.cpuMult())+' cyc/line';''')
fix('A10g', 'APP', 'Overlay, status and hardware panels show the effective turbo step',
    '''         '  '+V.height()+' LINES  '+Math.round((m.turbo||1)*100)+'PCT');''',
    '''         '  '+V.height()+' LINES  '+Math.round(m.cpuMult()*100)+'PCT');''')
fix('A10h', 'APP', 'Status line turbo value',
    '''          {t:'TURBO',d:Math.round((m.turbo||1)*100)+'%'},''',
    '''          {t:'TURBO',d:Math.round(m.cpuMult()*100)+'%'},''')
fix('A10i', 'APP', 'Hardware panel turbo value',
    '''      ['Turbo',Math.round((m.turbo||1)*100)+'%'],''',
    '''      ['Turbo',Math.round(m.cpuMult()*100)+'%'],''')
fix('A10j', 'APP', 'ROM-size advice uses the effective multiplier',
    '''  const mult=(m.mode==='ss')?(m.turbo||1):1;''',
    '''  const mult=m.cpuMult();''')
fix('A10k', 'APP', 'Per-game settings keep the enhancement layer (which now holds the turbo step) and no longer restore the $F3 step, which software sets',
    '''  store.set('cfg_'+m.romId, JSON.stringify({ael:m.ael,turbo:m.turbo,mode:m.mode})); return true; }''',
    '''  store.set('cfg_'+m.romId, JSON.stringify({ael:m.ael,mode:m.mode})); return true; }''')
fix('A10l', 'APP', 'Per-game settings load: an older stored "turbo" (the $F3 step) is ignored',
    '''    if(c.turbo)m.turbo=c.turbo; return c; }catch(e){ return null; } }''',
    '''    return c; }catch(e){ return null; } }''')
fix('A10m', 'APP', 'AEL panel: auto-fire text names button 2; VRAM speed-up switch added',
    ''' ['autofire','Auto-fire on C','Repeats B while C is held.','y'],''',
    ''' ['autofire','Auto-fire on C','Button 2 repeats while C is held.','y'],
 ['vramboost','VRAM speed-up','No VDP access wait while a turbo step is active.','g'],''')

# ---------------------------------------------------------------- comments
fix('A1', 'APP', 'Stale comment: turbo lives at $F3, not $0B',
    '''           silently change the clock, and Super Sega software could never use both.
           Turbo moved to its own port $0B. */''',
    '''           silently change the clock, and Super Sega software could never use both.
           Turbo is on its own port, $F3. */''')

# ---------------------------------------------------------------- apply
# Edits apply in order, each anchor checked against the text as it stands
# after the edits before it, so overlapping edits cannot silently miss.
errors = []
for fid, side, what, old, new, count in FIXES:
    n = h.count(old)
    if n != count:
        errors.append(f'{fid}: anchor found {n} times, expected {count}: {what}')
        continue
    h = h.replace(old, new)
if errors:
    print('\n'.join(errors)); sys.exit(1)
open(DST, 'w', encoding='utf-8').write(h)
for fid, side, what, *_ in FIXES:
    print(f'{fid:5} {side:5} {what}')
print(f'{len(FIXES)} edits applied')
