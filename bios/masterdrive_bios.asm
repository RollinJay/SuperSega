; MasterDrive BIOS - the console's own start-up program.
;
; Copyright (c) 2026 the MasterDrive project. MIT licence (see LICENSE).
; Written for this project: no Sega code, logo or wording.
;
; It is the 8 KB BIOS ROM that port $3E bit 3 maps (Technical Reference section 20). A cold
; reset puts the machine in MasterDrive mode with $3E = $E0 (the BIOS, work RAM and the
; controllers on; the cartridge off) and starts it here. It reads the platform's information
; through its ports ($18, $19), reads the cartridge's header as the Master System BIOS does
; (switching $3E from a routine in RAM), shows the boot menu (device first: CART, CARD, USB,
; SYSTEM) and waits for Play; holding Start at power-on skips the menu. Play writes the
; chosen machine, clears the video and work RAM it used and launches ($1F): at the next frame
; the hardware resets every block into that machine with $3E = $A8 and the cartridge starts
; in the documented hand-over state. Built by make_bios.py with z80asm 1.8; 8 KB at most.

; ---------------------------------------------------------------- ports
VDP_DATA:	equ 0xBE
VDP_CTRL:	equ 0xBF
VDP_VCOUNT:	equ 0x7E
IO_CTRL:	equ 0x3F		; TH and TR directions and levels
PAD_A:		equ 0xDC		; port A
MEMCTL:		equ 0x3E		; memory enables, active low
MEM_BIOS:	equ 0xE0		; the BIOS, work RAM and controllers on (the cold reset value)
MEM_CART:	equ 0xA8		; the cartridge, work RAM and controllers on
BOOT_IDX:	equ 0x18		; the BIOS's ports while $3E bit 3 is clear (Technical Reference section 20)
BOOT_VAL:	equ 0x19
BOOT_LAUNCH:	equ 0x1F
MACHINE_ID:	equ 0x17
PSG:		equ 0x7F

; settings (Technical Reference section 20)
S_MACHINE:	equ 0
S_BOOSTS:	equ 1		; 1-9
S_FORCE:	equ 16
S_FLAGS:	equ 17
S_SIZE:		equ 18
S_MAPPER:	equ 19
S_REGION:	equ 20
S_MACHINES:	equ 21		; the machines the platform runs, a bit each
F_CART:		equ 0		; flag bits
F_CARD:		equ 1
F_USB:		equ 2
F_PAL:		equ 3

; machine codes
M_SMS:		equ 0
M_GG:		equ 1
M_SG:		equ 2
M_SC:		equ 3
M_SF:		equ 4
M_MD:		equ 5
AUTO:		equ 0xFF

NBOOST:		equ 9
BOOST_TURBO:	equ 3		; boost index of the turbo step (0-4)

; pad bits (active high, as read_pad returns them)
P_UP:		equ 0
P_DOWN:		equ 1
P_LEFT:		equ 2
P_RIGHT:	equ 3
P_B:		equ 4
P_C:		equ 5
P_A:		equ 6
P_START:	equ 7
PAD_SKIP:	equ 0x80	; a launch waits for these to be released: Start on the skip path,
PAD_MENU:	equ 0x90	; Start and B (either launches) from the menu

; ---------------------------------------------------------------- VRAM layout
VR_TILES:	equ 0x0000	; Mode 4 tiles: 0 blank, 1 cursor, 2 rule, $20-$7E the font
VR_TXTPAT:	equ 0x2800	; text window patterns (bank 1 R8 = $28): character c at +c*8
VR_TXTNT:	equ 0x3000	; text window name tables (bank 1 R0 = $30 or $34): 40 bytes a row;
				; one is on screen, the next page is drawn in the other
VR_NT:		equ 0x3800	; Mode 4 name table (R2 = $FF)
VR_SAT:		equ 0x3F00	; sprite table (R5 = $FF)
TXT_ROWS:	equ 21		; screen rows 3-23
TXT_TOP:	equ 3		; the window's split row
STATUS_ROW:	equ 20		; text row of the status line

; ---------------------------------------------------------------- RAM ($C000-, bank 0)
v_frame:	equ 0xC000
v_pad:		equ 0xC001
v_padold:	equ 0xC002
v_press:	equ 0xC003
v_dev:		equ 0xC004	; 0 CART, 1 CARD, 2 USB, 3 SYSTEM
v_item:		equ 0xC005	; cursor on the CART page
v_hdr:		equ 0xC006	; 1: a TMR SEGA header was found
v_detect:	equ 0xC007	; the machine the cartridge asks for
v_choice:	equ 0xC008	; AUTO or a machine code
v_force:	equ 0xC009	; the platform's machine choice
v_flags:	equ 0xC00A
v_size:		equ 0xC00B	; log2 of the cartridge size, 0 unknown
v_region:	equ 0xC00C
v_items:	equ 0xC00D	; items on the CART page
v_mask:		equ 0xC00E	; index 21: the machines the platform runs
v_tbuf:		equ 0xC00F	; 0 or 4: the text name table on screen is at VR_TXTNT + v_tbuf * 256
v_boost:	equ 0xC010	; 9 bytes
v_bi:		equ 0xC019	; the boost being drawn
v_rel:		equ 0xC01A	; the buttons the launch waits to see released
v_test:		equ 0xC01B	; 1: the controller test is running
v_tptr:		equ 0xC01C	; 2 bytes: where tout writes in the text shadow
v_dlo:		equ 0xC01E	; the first and last text rows changed since the last flush
v_dhi:		equ 0xC01F
TXT_SHADOW:	equ 0xC200	; the text window's 21 x 40 characters, copied to VRAM by flush
v_bnew:		equ 0xC040	; 9 bytes: the boosts as read this frame
RAM_CODE:	equ 0xC100	; the header reader runs here (the cartridge replaces the BIOS)
v_hdrbuf:	equ 0xC020	; 16 bytes
v_num:		equ 0xC030	; number formatting

; ================================================================ vectors
	org 0x0000
	di
	im 1
	jp start

	ds 0x0038-$, 0xFF	; frame interrupt (z80asm's org does not pad)
	push af
	in a,(VDP_CTRL)		; acknowledge
	ld a,(v_frame)
	inc a
	ld (v_frame),a
	pop af
	ei
	reti

	ds 0x0066-$, 0xFF	; Pause / Select: nothing to do here
	retn

	ds 0x0080-$, 0xFF
psg_quiet:	db 0x9F, 0xBF, 0xDF, 0xFF
title_text:	db "MASTERDRIVE", 0
version_text:	db "BIOS 1", 0

; ================================================================ start
start:
	ld sp,0xDFF0
	ld hl,psg_quiet		; the PSG's four channels silent (attenuation 15), whatever state
	ld bc,4 << 8 | PSG	; it powered up in
	otir
	ld hl,0xC000		; clear the BIOS's variables
	ld de,0xC001
	ld bc,0x00FF
	ld (hl),0
	ldir
	ld a,0xFF		; no text rows changed yet
	ld (v_dlo),a
	call platform_info
	call read_pad
	ld (v_padold),a		; a button held now is not a new press
	push af
	call detect
	pop af
	bit P_START,a		; Start held at power-on: straight to the game
	jr z,show_menu
	call can_play
	jp nz,play_skip
show_menu:
	call vdp_init
	call draw_all
	ld a,0x60		; display on, frame interrupt on
	ld b,0x81
	call vdp_reg
	ei
menu_loop:
	halt			; wait for the frame interrupt
	call read_boosts	; a change in the platform's own menu shows at once
	ld hl,v_bnew
	ld de,v_boost
	ld b,NBOOST
ml_cmp:	ld a,(de)
	cp (hl)
	jr nz,ml_bch
	inc hl
	inc de
	djnz ml_cmp
	jr ml_pad
ml_bch:	ld hl,v_bnew
	ld de,v_boost
	ld bc,NBOOST
	ldir
	ld a,(v_dev)
	or a
	call z,draw_page
ml_pad:	call read_pad
	ld (v_pad),a
	ld b,a
	ld a,(v_padold)
	xor b			; a change: the SYSTEM page's controller test follows it
	jr z,ml_same
	ld a,(v_dev)
	cp 3
	jr nz,ml_same
	call draw_pad_test
	call flush
ml_same:
	ld a,(v_pad)		; (the controller test does not keep B)
	ld b,a
	ld a,(v_padold)
	cpl
	and b
	ld (v_press),a
	ld a,b
	ld (v_padold),a
	ld a,(v_test)		; in the controller test no button acts but Start + A,
	or a			; which ends it
	jr z,ml_act
	ld a,b
	and 0xC0
	cp 0xC0
	jp nz,menu_loop
	xor a
	ld (v_test),a
	call draw_page
	jp menu_loop
ml_act:	ld a,(v_press)
	or a
	jp z,menu_loop
	bit P_START,a
	jr z,ml_lr
	call can_play
	jp nz,play
	jr menu_loop
ml_lr:	bit P_LEFT,a
	jr z,ml_r
	ld a,(v_dev)
	dec a
	and 3
	jr ml_dev
ml_r:	bit P_RIGHT,a
	jr z,ml_page
	ld a,(v_dev)
	inc a
	and 3
ml_dev:	ld (v_dev),a
	xor a
	ld (v_item),a
	call draw_page		; the new page, shown in a vertical blank ...
	call draw_devrow	; ... in which the device row follows it
	jp menu_loop
ml_page:
	ld a,(v_dev)
	or a
	call z,cart_keys	; the CART page
	ld a,(v_dev)
	cp 3
	jp nz,menu_loop
	ld a,(v_press)		; SYSTEM: B starts the controller test
	bit P_B,a
	jp z,menu_loop
	ld a,1
	ld (v_test),a
	ld hl,s_st_test
	call status
	call flush
	jp menu_loop

; ---------------------------------------------------------------- CART page keys
cart_keys:
	ld a,(v_press)
	bit P_UP,a
	jr z,ck_down
	ld a,(v_item)
	or a
	ret z
	dec a
	jr ck_move
ck_down:
	bit P_DOWN,a
	jr z,ck_c
	ld a,(v_items)
	ld b,a
	ld a,(v_item)
	inc a
	cp b
	ret nc
ck_move:
	ld (v_item),a
	jp place_cursor
ck_c:	bit P_C,a
	jr z,ck_b
	xor a
	jr ck_move
ck_b:	bit P_B,a
	ret z
	ld a,(v_flags)
	bit F_CART,a
	ret z
	ld a,(v_item)
	or a
	jp z,play		; item 0: PLAY
	dec a
	jr nz,ck_boost
	call next_machine	; item 1: Machine
	jp draw_page
ck_boost:
	dec a			; items 2-10: the boosts
	ld b,a
	call machine
	cp M_MD
	ld a,b
	jr nz,ck_bi
	ld a,NBOOST-1		; MasterDrive software: item 2 is True TMS colours
ck_bi:	ld e,a
	ld d,0
	ld hl,v_boost
	add hl,de
	ld b,1			; most are off/on
	cp BOOST_TURBO
	jr nz,ck_bv
	ld b,4			; the turbo step: 0-4
ck_bv:	ld a,(hl)
	inc a
	cp b
	jr c,ck_bset
	jr z,ck_bset
	xor a
ck_bset:
	ld (hl),a		; and at once to its setting (index 1 + E), for the launch
	ld a,e
	inc a
	out (BOOT_IDX),a
	ld a,(hl)
	out (BOOT_VAL),a
	jp draw_page

; Machine: Auto, then each machine the platform runs (index 21), then Auto again; not
; the SF-7000, which starts from its own ROM and disks, not from the cartridge.
next_machine:
	ld a,(v_choice)
nm_inc:	inc a			; AUTO ($FF) steps to 0
	cp M_SF
	jr z,nm_inc
	cp M_MD+1
	jr nc,nm_auto
	ld b,a			; offered when its bit in index 21 is set
	ld c,a
	ld a,(v_mask)
	inc b
nm_bit:	rrca
	djnz nm_bit
	ld a,c
	jr nc,nm_inc
	jr nm_set
nm_auto:
	ld a,AUTO
nm_set:	ld (v_choice),a
	ret

; ================================================================ platform and cartridge
platform_info:
	ld a,S_FORCE
	out (BOOT_IDX),a
	in a,(BOOT_VAL)		; 16: the platform's machine choice
	ld (v_force),a
	ld (v_choice),a		; the platform's choice is the default
	in a,(BOOT_VAL)		; 17: flags
	ld (v_flags),a
	bit F_CART,a		; with a cartridge a choice of the SF-7000, which does not play
	jr z,pi_cart		; it, is Auto
	ld a,(v_choice)
	cp M_SF
	jr nz,pi_cart
	ld a,AUTO
	ld (v_choice),a
pi_cart:
	in a,(BOOT_VAL)		; 18: the cartridge size
	ld (v_size),a
	in a,(BOOT_VAL)		; 19: the mapper (not used by the menu yet)
	in a,(BOOT_VAL)		; 20: the region
	ld (v_region),a
	in a,(BOOT_VAL)		; 21: the machines the platform runs
	ld (v_mask),a
	call read_boosts
	ld hl,v_bnew
	ld de,v_boost
	ld bc,NBOOST
	ldir
	ret

; read_boosts: indices 1-9, the boosts for the next launch, into v_bnew
read_boosts:
	ld a,S_BOOSTS
	out (BOOT_IDX),a
	ld hl,v_bnew
	ld b,NBOOST
	ld c,BOOT_VAL
	inir
	ret

; The header: TMR SEGA at $7FF0, $3FF0 or $1FF0 (Technical Reference section 14). The
; region nibble picks the machine; without a header, 64 KB or less is SG-1000 software.
detect:
	ld a,M_SMS
	ld (v_detect),a
	ld a,(v_flags)
	bit F_CART,a
	ret z
	ld hl,ram_hdr		; the reader goes to RAM: while it reads, the cartridge
	ld de,RAM_CODE		; replaces the BIOS at $0000-$BFFF
	ld bc,ram_hdr_end-ram_hdr
	ldir
	ld hl,hdr_offsets
	ld b,3
dt_loop:
	push bc
	ld e,(hl)
	inc hl
	ld d,(hl)
	inc hl
	push hl
	call peek_header
	pop hl
	pop bc
	jr z,dt_found
	djnz dt_loop
	ld a,(v_size)		; no header
	or a
	ret z			; size unknown: Master System
	cp 17
	ret nc			; more than 64 KB: Master System
	ld a,M_SG
	ld (v_detect),a
	ret
dt_found:
	ld a,1
	ld (v_hdr),a
	ld a,(v_hdrbuf+15)
	rrca
	rrca
	rrca
	rrca
	and 0x0F
	ld b,M_GG
	cp 5
	jr c,dt_sms
	cp 8
	jr c,dt_set
	ld b,M_MD
	jr z,dt_set
dt_sms:	ld b,M_SMS
dt_set:	ld a,b
	ld (v_detect),a
	ret

hdr_offsets:	dw 0x7FF0, 0x3FF0, 0x1FF0
tmr_sega:	db "TMR SEGA"

; Read the 16 bytes at cartridge address DE into v_hdrbuf; Z set if they start with TMR
; SEGA. At a cold reset the mapper's banks put ROM offsets $0000-$7FFF at those addresses.
peek_header:
	di			; the vectors are the cartridge's while it reads
	ex de,hl
	call RAM_CODE
	ld hl,v_hdrbuf
	ld de,tmr_sega
	ld b,8
ph_cmp:	ld a,(de)
	cp (hl)
	ret nz
	inc hl
	inc de
	djnz ph_cmp
	ret			; Z

; copied to RAM_CODE (it uses no relative jump into the BIOS): read 16 bytes at HL with
; the cartridge mapped, then map the BIOS again
ram_hdr:
	ld a,MEM_CART
	out (MEMCTL),a
	ld de,v_hdrbuf
	ld bc,16
	ldir
	ld a,MEM_BIOS
	out (MEMCTL),a
	ret
ram_hdr_end:

; The machine the menu will start: the choice, or what the cartridge asks for.
machine:
	ld a,(v_choice)
	cp AUTO
	ret nz
	ld a,(v_detect)
	ret

; can_play: NZ when Play can start a machine: a cartridge is inserted, or the platform's
; choice is the SF-7000 and it runs one (index 21), which starts from its own ROM and disks
can_play:
	ld a,(v_flags)
	bit F_CART,a
	ret nz
	call sf_play
	ret

; sf_play: NZ when the machine is the SF-7000 and the platform runs one
sf_play:
	call machine
	cp M_SF
	jr nz,sf_no
	ld a,(v_mask)
	and 1 << M_SF
	ret
sf_no:	xor a
	ret

; ================================================================ pad
; Returns A: bit 0 up, 1 down, 2 left, 3 right, 4 B, 5 C, 6 A, 7 Start (1 = pressed), read
; from a Mega Drive pad through port A's TH line (Technical Reference section 6).
read_pad:
	ld a,0xFD		; TH output, high: up down left right B C
	out (IO_CTRL),a
	in a,(PAD_A)
	cpl
	and 0x3F
	ld b,a
	ld a,0xDD		; TH output, low: up down 0 0 A Start
	out (IO_CTRL),a
	in a,(PAD_A)
	cpl
	and 0x30
	rlca
	rlca
	or b
	ld b,a
	ld a,0xFF		; every pin an input again
	out (IO_CTRL),a
	ld a,b
	ret

; ================================================================ launch
; Launch only once the button that asked for it reads released in two frames running, so
; the game does not begin with it held (with Start = Pause on, a held Start would pause
; it). Other buttons may stay held: a game can still read a combination held at power-on.
play_skip:
	ld a,PAD_SKIP
	jr pl_go
play:
	ld a,PAD_MENU
pl_go:	di
	ld sp,0xDFF0		; the same stack from the menu (inside a call) and the skip path
	ld (v_rel),a
pl_rel:	call wait_frame
	call read_pad
	ld hl,v_rel
	and (hl)
	jr nz,pl_rel
	call wait_frame
	call read_pad
	ld hl,v_rel
	and (hl)
	jr nz,pl_rel
	call machine		; index 0: the machine (the boosts were written as they changed)
	ld b,a
	xor a
	out (BOOT_IDX),a
	ld a,b
	out (BOOT_VAL),a
	; Leave what the BIOS used as a direct start finds it: VRAM $0000-$3FFF, the 32
	; colours and work RAM bank 0 zero. First the display, the frame interrupt (R1) and
	; the line interrupt (R0 bit 4, on at power-on) go off, so no interrupt can come;
	; the machine raises no Pause (NMI) while the BIOS runs. The launch resets every
	; register.
	xor a
	out (VDP_CTRL),a
	ld a,0x81
	out (VDP_CTRL),a
	ld a,0x04
	out (VDP_CTRL),a
	ld a,0x80
	out (VDP_CTRL),a
	call vram_clear
	di			; (vram_w turned them on)
	xor a			; CRAM entries 0-31
	out (VDP_CTRL),a
	ld a,0xC0
	out (VDP_CTRL),a
	ld b,32
	xor a
pl_cram:
	call vout
	djnz pl_cram
	ld hl,0xFFFF		; AF' $FFFF: a Z80 reset leaves it alone (the stack's bytes are
	push hl			; cleared with the rest of bank 0 below)
	pop af
	ex af,af'
	ld ix,0			; the other registers a CPU reset leaves alone start at zero
	ld iy,0
	exx
	ld bc,0
	ld de,0
	ld hl,0
	exx
	ld hl,0xC000		; work RAM bank 0, last: nothing may use the stack after this
	ld de,0xC001
	ld bc,0x1FFF
	ld (hl),0
	ldir
	ld hl,0
	ld de,0			; (LDIR left BC zero)
	ld a,0xA5
	out (BOOT_LAUNCH),a
pl_wait:
	halt			; the CPU is held from the launch write until the frame ends
	jr pl_wait

; wait_vblank: wait for line 192, the first below the picture (the V counter reads $C0
; there; in PAL it does again at line 249, also below the picture): the vertical blank
; that follows has at least 60 lines in either standard.
wait_vblank:
	in a,(VDP_VCOUNT)
	cp 0xC0
	jr nz,wait_vblank
	ret

; wait_frame: wait for the VDP to reach line 0, then to leave it. In the 192-line mode
; the BIOS keeps, the V counter (port $7E) reads 0 there and nowhere else in a frame, NTSC
; or PAL (a value above $B9 comes twice in a PAL frame). It works with the display and
; the frame interrupt off.
wait_frame:
	in a,(VDP_VCOUNT)
	or a
	jr nz,wait_frame
wf_on:	in a,(VDP_VCOUNT)
	or a
	jr z,wf_on
	ret

; ================================================================ video
; The control port takes two bytes, and the frame interrupt's status read in between would
; make the VDP take the second byte as a first one; so both routines keep interrupts off
; while they write. A register write also sets the VDP's address: set the address after it.

; vout: write A to the VDP's data port. Every write with the display on goes through it,
; so those writes are at least 29 T-states apart, as the stock VDP needs during the active
; display at 100 % (Technical Reference section 1). With the display off (the set-up and the
; launch's clears) writes come at least 16 T-states apart.
vout:
	out (VDP_DATA),a
	ret

; vdp_reg: write B (register command, $80 | bank << 4 | n) with value A
vdp_reg:
	di
	out (VDP_CTRL),a
	ld a,b
	out (VDP_CTRL),a
	ei
	ret

; vram_w: set the VDP to write at HL
vram_w:
	di
	ld a,l
	out (VDP_CTRL),a
	ld a,h
	or 0x40
	out (VDP_CTRL),a
	ei
	ret

; vram_clear: VRAM $0000-$3FFF to zero, with the display off (about 4.5 frames)
vram_clear:
	ld hl,0x0000
	call vram_w
	ld c,VDP_DATA
	xor a
	ld d,8
vc_256:	ld b,0
vc_8:	out (c),a		; 16 T-states a write: the display is off
	nop
	out (c),a
	nop
	out (c),a
	nop
	out (c),a
	nop
	out (c),a
	nop
	out (c),a
	nop
	out (c),a
	nop
	out (c),a
	djnz vc_8
	dec d
	jr nz,vc_256
	ret

vdp_init:
	ld hl,vdp_regs
	ld b,vdp_regs_end-vdp_regs
	ld c,VDP_CTRL
	otir
	call vram_clear
	ld hl,VR_TILES+0x20*32	; the font as Mode 4 tiles, colour 1
	call vram_w
	ld hl,font
	ld de,95*8
vi_t4:	ld a,(hl)
	call vout
	xor a
	call vout
	call vout
	call vout
	inc hl
	dec de
	ld a,d
	or e
	jr nz,vi_t4
	ld hl,VR_TILES+1*32	; tiles 1 (cursor) and 2 (rule)
	call vram_w
	ld hl,extra_tiles
	ld b,extra_tiles_end-extra_tiles
	ld c,VDP_DATA
	otir
	ld hl,VR_TXTPAT+0x20*8	; the font for the text window
	call vram_w
	ld hl,font
	ld de,95*8
vi_tp:	ld a,(hl)
	call vout
	inc hl
	dec de
	ld a,d
	or e
	jr nz,vi_tp
	ld hl,VR_SAT		; one sprite (the cursor), then the end of the list
	call vram_w
	ld a,0xD0
	call vout
	call vout
	ld a,0x00		; CRAM: the stock 6-bit colours
	out (VDP_CTRL),a
	ld a,0xC0
	out (VDP_CTRL),a
	ld hl,palette
	ld b,32
	ld c,VDP_DATA
	otir
	ret

; R0-R10 as the test ROMs use them, display off; then XRB, the text window in bank 1, the
; window from row 3 down, and the window layer.
vdp_regs:
	db 0x04,0x80, 0x00,0x81, 0xFF,0x82, 0xFF,0x83, 0xFF,0x84, 0xFF,0x85
	db 0xFB,0x86, 0x00,0x87, 0x00,0x88, 0x00,0x89, 0xFF,0x8A
	db 0x20,0x8F			; Feature Enable A: XRB
	db VR_TXTNT>>8,0x90		; bank 1 R0: the window's name table
	db VR_TXTPAT>>8,0x98		; bank 1 R8: text patterns
	db 0x01,0x99			; bank 1 R9: background colour 0, characters colour 1
	db 0x04,0x97			; Feature Enable C: the text window
	db 0x01,0x8D			; R13: from x = 8, so the 40 columns lie at x 8-247
	db TXT_TOP,0x8E			; R14: from row 3 down
	db 0x24,0x8F			; Feature Enable A: XRB and the window layer
vdp_regs_end:

; Palette 0 (background and text): 0 dark blue, 1 white, 2 grey, 3 yellow.
; Palette 1 (sprites, the selected device): 0 dark blue, 1 yellow, 2 white.
palette:
	db 0x10,0x3F,0x2A,0x0F, 0,0,0,0, 0,0,0,0, 0,0,0,0
	db 0x10,0x0F,0x3F,0x00, 0,0,0,0, 0,0,0,0, 0,0,0,0

extra_tiles:
	; tile 1: the cursor, an arrow in colour 1 (plane 0)
	db 0x00,0,0,0, 0x60,0,0,0, 0x78,0,0,0, 0x7E,0,0,0, 0x78,0,0,0, 0x60,0,0,0, 0x00,0,0,0, 0x00,0,0,0
	; tile 2: a rule across the middle in colour 2 (plane 1)
	db 0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0xFF,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0
extra_tiles_end:

font:
	include "font.inc"

; ================================================================ drawing
draw_all:
	call draw_title
	call draw_devrow
	jp draw_page

; The top three rows are Mode 4 tiles: the title, the device row, a rule.
draw_title:
	ld hl,VR_NT		; row 0
	call vram_w
	ld c,0
	ld a,' '
	call nt_char
	ld hl,title_text
	ld c,0
	call nt_str
	ld b,32-1-11-6-1	; spaces up to the version
dt_sp:	ld a,' '
	push bc
	call nt_char
	pop bc
	djnz dt_sp
	ld hl,version_text
	ld c,0
	call nt_str
	ld a,' '
	call nt_char
	ld hl,VR_NT+128		; row 2: the rule
	call vram_w
	ld b,32
dt_rule:
	ld a,2
	call vout
	xor a
	call vout
	djnz dt_rule
	ret

; row 1: the devices, the current one in yellow
draw_devrow:
	ld hl,VR_NT+64
	call vram_w
	ld b,0			; device number
	ld hl,dev_names
dt_dev:	push bc
	ld a,' '
	ld c,0
	call nt_char
	ld a,(v_dev)
	cp b
	ld c,0
	jr nz,dt_pal
	ld c,0x08		; the selected device in palette 1
dt_pal:	call nt_str
	pop bc
	inc b
	ld a,b
	cp 4
	jr nz,dt_dev
	ld b,32-29		; the rest of the row (29 entries so far)
dt_fill:
	ld a,' '
	push bc
	ld c,0
	call nt_char
	pop bc
	djnz dt_fill
	ret

dev_names:	db "[CART]",0,"[CARD]",0,"[USB]",0,"[SYSTEM]",0

; nt_char: one Mode 4 name-table entry, tile A, attribute C
nt_char:
	call vout
	ld a,c
	call vout
	ret

; nt_str: the zero-ended string at HL, attribute C; HL ends after the zero
nt_str:	ld a,(hl)
	inc hl
	or a
	ret z
	call nt_char
	jr nt_str

; ---------------------------------------------------------------- text window
; The text window is drawn into a copy in RAM (TXT_SHADOW) and flush copies the rows
; that changed to VRAM. A whole page goes to the name table that is not on screen, which
; is then shown from a vertical blank: a page change is one frame to the next, never half
; of each page.

; txt_at: write the text window at row D, column E (BC is not kept)
txt_at:
	push hl
	ld a,(v_dlo)		; the rows changed
	cp d
	jr c,ta_lo
	ld a,d
	ld (v_dlo),a
ta_lo:	ld a,(v_dhi)
	cp d
	jr nc,ta_hi
	ld a,d
	ld (v_dhi),a
ta_hi:	call row_off		; HL = row D * 40
	ld c,e
	ld b,0
	add hl,bc
	ld bc,TXT_SHADOW
	add hl,bc
	ld (v_tptr),hl
	pop hl
	ret

; row_off: HL = D * 40 (BC is not kept)
row_off:
	ld l,d
	ld h,0
	add hl,hl		; row * 8
	add hl,hl
	add hl,hl
	ld b,h
	ld c,l
	add hl,hl		; row * 32
	add hl,hl
	add hl,bc		; row * 40
	ret

; tout: write character A at the text position, which steps on (keeps every register)
tout:
	push hl
	ld hl,(v_tptr)
	ld (hl),a
	inc hl
	ld (v_tptr),hl
	pop hl
	ret

; flush: copy the text rows changed since the last flush to VRAM: every row (a page,
; after txt_clear) to the table not on screen, then shown; fewer to the table on screen
flush:
	ld a,(v_dhi)
	ld e,a
	ld a,(v_dlo)
	cp e
	jr z,fl_go
	ret nc			; nothing changed
fl_go:	ld d,a
	ld c,0			; C: 0 the table on screen, 4 the other
	or a
	jr nz,fl_n
	ld a,e
	cp TXT_ROWS-1
	jr nz,fl_n
	ld c,4
fl_n:	ld a,e
	sub d
	inc a
	ld e,a			; rows to copy
	push bc
	call row_off		; HL = the first row's offset
	pop bc
	push hl
	ld a,(v_tbuf)
	xor c
	add a,VR_TXTNT>>8
	add a,h
	ld h,a
	call vram_w
	pop hl
	push bc
	ld bc,TXT_SHADOW
	add hl,bc
fl_row:	ld b,40
fl_ch:	ld a,(hl)
	inc hl
	call vout
	djnz fl_ch
	dec e
	jr nz,fl_row
	pop bc
	ld a,0xFF		; nothing changed
	ld (v_dlo),a
	xor a
	ld (v_dhi),a
	or c
	ret z
	call wait_vblank	; show the other table
	ld a,(v_tbuf)
	xor 4
	ld (v_tbuf),a
	add a,VR_TXTNT>>8
	ld b,0x90		; bank 1 R0
	jp vdp_reg

; txt_str: write the zero-ended string at HL; HL ends after the zero
txt_str:
	ld a,(hl)
	inc hl
	or a
	ret z
	call tout
	jr txt_str

; print: row D, column E, string HL
print:	call txt_at
	jp txt_str

; txt_clear: every text row blank (in the shadow; flush shows it)
txt_clear:
	ld hl,TXT_SHADOW
	ld de,TXT_SHADOW+1
	ld bc,TXT_ROWS*40-1
	ld (hl),' '
	ldir
	xor a
	ld (v_dlo),a
	ld a,TXT_ROWS-1
	ld (v_dhi),a
	ret

; hex8: write A as two hex digits
hex8:	push af
	rrca
	rrca
	rrca
	rrca
	call hex4
	pop af
hex4:	and 0x0F
	add a,'0'
	cp '9'+1
	jr c,hx_out
	add a,'A'-'9'-1
hx_out:	call tout
	ret

; dec8: write A (0-255) in decimal, without leading zeros
dec8:	ld b,100
	ld c,0			; 1 once a digit has been written
	call dec_digit
	ld b,10
	call dec_digit
	add a,'0'
	call tout
	ret
; dec16: write HL (0-65535) in decimal, without leading zeros
dec16:	ld c,0
	ld de,10000
	call dec16_digit
	ld de,1000
	call dec16_digit
	ld de,100
	call dec16_digit
	ld de,10
	call dec16_digit
	ld a,l
	add a,'0'
	call tout
	ret
dec16_digit:
	ld a,'0'-1
d16_lp:	inc a
	or a			; clear carry
	sbc hl,de
	jr nc,d16_lp
	add hl,de
	cp '0'
	jr nz,d16_out
	bit 0,c
	ret z
d16_out:
	call tout
	ld c,1
	ret

dec_digit:
	ld d,'0'-1
dd_lp:	inc d
	sub b
	jr nc,dd_lp
	add a,b
	ld e,a
	ld a,d
	cp '0'
	jr nz,dd_out
	bit 0,c
	jr z,dd_skip
dd_out:	call tout
	ld c,1
dd_skip:
	ld a,e
	ret

; ---------------------------------------------------------------- pages
draw_page:
	call txt_clear
	call dp_page
	call flush
	jp place_cursor
dp_page:
	ld a,(v_dev)
	or a
	jp z,page_cart
	dec a
	jp z,page_card
	dec a
	jp z,page_usb
	jp page_system

status:	ld d,STATUS_ROW		; the status line: HL the device's text
	ld e,1
	call print
	ret

page_card:
	ld a,(v_flags)
	bit F_CARD,a
	ld hl,s_card_in
	jr nz,pc_t
	ld hl,s_no_card
pc_t:	ld de,0x0101
	call print
	ld hl,s_st_card
	jp status

page_usb:
	ld a,(v_flags)
	bit F_USB,a
	ld hl,s_usb
	jr nz,pu_t
	ld hl,s_no_usb
pu_t:	ld de,0x0101
	call print
	ld hl,s_st_usb
	jp status

page_system:
	ld de,0x0101
	ld hl,s_bios
	call print
	ld a,0xA4		; the machine ID, read with the I/O gate open (Feature
	ld b,0x8F		; Enable A: the gate, XRB and the window layer), before
	call vdp_reg		; the text address is set
	in a,(MACHINE_ID)
	push af
	ld a,0x24
	ld b,0x8F
	call vdp_reg
	ld de,0x0201
	ld hl,s_id
	call print
	ld a,'$'
	call tout
	pop af
	call hex8
	ld de,0x0301
	ld hl,s_video
	call print
	ld a,(v_flags)
	bit F_PAL,a
	ld hl,s_ntsc
	jr z,ps_v
	ld hl,s_pal
ps_v:	call txt_str
	ld de,0x0401
	ld hl,s_region
	call print
	ld a,(v_region)
	or a
	ld hl,s_export
	jr z,ps_r
	ld hl,s_japan
ps_r:	call txt_str
	ld de,0x0601
	ld hl,s_padtest
	call print
	ld de,0x0901
	ld hl,s_skip1
	call print
	ld de,0x0A01
	ld hl,s_skip2
	call print
	call draw_pad_test
	ld hl,s_st_system
	jp status

; the SYSTEM page's controller test: the name of each button shown while it is held
draw_pad_test:
	ld de,0x0703
	call txt_at
	ld a,(v_pad)
	ld c,a
	ld hl,s_buttons
	ld b,8
dpt_lp:	push bc
	ld a,c
	and 1
	jr nz,dpt_on
dpt_sp:	; not held: as many spaces as the name has letters
	ld a,(hl)
	inc hl
	or a
	jr z,dpt_nx
	ld a,' '
	call tout
	jr dpt_sp
dpt_on:	call txt_str
dpt_nx:	ld a,' '
	call tout
	pop bc
	srl c
	djnz dpt_lp
	ret

s_buttons:	db "UP",0,"DOWN",0,"LEFT",0,"RIGHT",0,"B",0,"C",0,"A",0,"START",0

page_cart:
	ld a,(v_flags)
	bit F_CART,a
	jr nz,pg_have
	ld de,0x0101
	ld hl,s_no_cart
	call print
	xor a
	ld (v_items),a
	call sf_play
	ld hl,s_st_nocart
	jp z,status
	ld de,0x0201
	ld hl,s_sf_nocart
	call print
	ld hl,s_st_sf
	jp status
pg_have:
	; line 1: the kind of software
	ld de,0x0101
	call txt_at
	ld a,(v_hdr)
	or a
	jr nz,pg_kind
	ld hl,s_nohdr		; what PLAY will launch it as
	call txt_str
	call machine
	call machine_name
	call txt_str
	jr pg_l2
pg_kind:
	ld a,(v_detect)
	call machine_name
	call txt_str
	ld hl,s_software
	call txt_str
	; line 2: product, version, region nibble, checksum
	ld de,0x0201
	ld hl,s_product
	call print
	ld a,(v_hdrbuf+14)	; the remaining digits, if any
	rrca
	rrca
	rrca
	rrca
	and 0x0F
	jr z,pg_p4
	call hex4
pg_p4:	ld a,(v_hdrbuf+13)
	call hex8
	ld a,(v_hdrbuf+12)
	call hex8
	ld hl,s_version
	call txt_str
	ld a,(v_hdrbuf+14)
	and 0x0F
	call hex4
	ld hl,s_regnib
	call txt_str
	ld a,(v_hdrbuf+15)
	rrca
	rrca
	rrca
	rrca
	call hex4
	ld de,0x0301
	ld hl,s_checksum
	call print
	ld a,(v_hdrbuf+11)
	call hex8
	ld a,(v_hdrbuf+10)
	call hex8
pg_l2:	ld a,(v_size)		; the size, when the platform knows it
	or a
	jr z,pg_items
	ld de,0x0401
	ld hl,s_size
	call print
	ld a,(v_size)
	sub 10			; KB = 2^(size-10)
	jr c,pg_items
	ld b,a
	ld hl,1
	jr z,pg_kb
pg_sh:	add hl,hl
	djnz pg_sh
pg_kb:	ld a,h			; 1024 KB and more (H 4 or more): as MB
	cp 4
	jr c,pg_kbs
	srl a
	srl a
	call dec8
	ld hl,s_mb
	call txt_str
	jr pg_items
pg_kbs:	call dec16
	ld hl,s_kb
	call txt_str
pg_items:
	; the items: PLAY, Machine, and for stock software the nine boosts
	ld de,0x0602
	ld hl,s_play
	call print
	ld de,0x0702
	ld hl,s_machine
	call print
	ld a,(v_choice)
	cp AUTO
	jr nz,pg_mc
	ld hl,s_auto		; Auto: as line 1 says
	call txt_str
	jr pg_mb
pg_mc:	call machine_name
	call txt_str
pg_mb:	call machine		; MasterDrive software: only True TMS colours acts on it
	cp M_MD			; (section 15), the last boost
	jr nz,pg_boosts
	ld de,0x0A02
	ld hl,s_md_boosts1
	call print
	ld de,0x0B02
	ld hl,s_md_boosts2
	call print
	ld a,3
	ld (v_items),a
	ld a,NBOOST-1
	jr pg_b1
pg_boosts:
	ld a,2+NBOOST
	ld (v_items),a
	xor a
pg_b1:	ld (v_bi),a		; the first boost drawn: its name, value and row
	ld e,a
	ld d,0
	ld ix,v_boost
	add ix,de
	ld hl,boost_names
	call nth_str
	ld d,8			; text row of the first boost item
pg_bl:	push de
	ld e,2
	call print		; the boost's name; HL moves to the next (BC is not kept)
	push hl
	ld a,(v_bi)
	cp BOOST_TURBO
	jr nz,pg_onoff
	ld a,(ix+0)		; turbo: 100, 125, 150, 175, 200 %
	ld e,a
	ld d,0
	ld hl,turbo_pct
	add hl,de
	ld a,(hl)
	call dec8
	ld a,'%'
	call tout
	jr pg_eff
pg_onoff:
	ld a,(ix+0)
	or a
	ld hl,s_off
	jr z,pg_v
	ld hl,s_on
pg_v:	call txt_str
pg_eff:	ld a,(v_bi)		; a boost that does not act on the machine PLAY starts
	ld e,a
	ld d,0
	ld hl,boost_acts
	add hl,de
	call machine
	ld b,a
	inc b
	ld a,(hl)
pg_ebit:
	rrca
	djnz pg_ebit
	jr c,pg_bn
	ld hl,s_noeff
	call txt_str
pg_bn:	pop hl
	pop de
	inc ix
	inc d
	ld a,(v_bi)
	inc a
	ld (v_bi),a
	cp NBOOST
	jr nz,pg_bl
pg_done:
	ld hl,s_st_cart
	jp status

turbo_pct:	db 100, 125, 150, 175, 200
; the machines each boost acts on, a bit each (Technical Reference section 15): the stock
; overflow flag only in Mode 4, Start = Pause not on the Game Gear (it has a Start of its
; own), the uncrop only on the Game Gear; True TMS colours on MasterDrive software too
boost_acts:	db 0x1F, 0x03, 0x1D, 0x1F, 0x1F, 0x1F, 0x1F, 0x02, 0x3F

; the cursor sprite beside the selected item on the CART page
place_cursor:
	ld hl,VR_SAT
	call vram_w
	ld a,(v_dev)		; only the CART page with items has one
	or a
	jr nz,pc_none
	ld a,(v_items)
	or a
	jr nz,pc_on
pc_none:
	ld a,0xD0		; the end of the list: no sprite
	jp vout
pc_on:
	ld a,(v_item)		; text row 6 + item; screen line (3 + row) * 8, Y = line - 1
	add a,TXT_TOP+6
	add a,a
	add a,a
	add a,a
	dec a
	call vout
	ld a,0xD0
	call vout
	ld hl,VR_SAT+0x80	; X and tile: the arrow just left of the items (text column 2)
	call vram_w
	ld a,12
	call vout
	ld a,1
	call vout
	ret

; machine_name: HL = the name of machine A
machine_name:
	ld hl,machine_names
; nth_str: HL = string A of the zero-ended strings at HL (0 = the first)
nth_str:
	or a
	ret z
	ld b,a
mn_lp:	ld a,(hl)
	inc hl
	or a
	jr nz,mn_lp
	djnz mn_lp
	ret

machine_names:	db "Master System",0,"Game Gear",0,"SG-1000",0,"SC-3000",0,"SF-7000",0,"MasterDrive",0
boost_names:	db "Sprite limit 16     ",0,"Stock overflow flag ",0,"Start = Pause       ",0
		db "Turbo               ",0,"VRAM speed-up       ",0,"Auto-fire           ",0
		db "Pseudo-stereo       ",0,"Game Gear uncrop    ",0,"True TMS colours    ",0

s_noeff:	db " (no effect)",0
s_software:	db " software",0
s_nohdr:	db "No header found: plays as ",0
s_product:	db "Product ",0
s_version:	db "  version ",0
s_regnib:	db "  region ",0
s_checksum:	db "Checksum $",0
s_size:		db "Size ",0
s_kb:		db " KB",0
s_mb:		db " MB",0
s_play:		db "PLAY",0
s_machine:	db "Machine             ",0
s_auto:		db "Auto",0
s_md_boosts1:	db "The other boosts do not act on",0
s_md_boosts2:	db "MasterDrive software.",0
s_on:		db "On",0
s_off:		db "Off",0
s_no_cart:	db "No cartridge.",0
s_no_card:	db "No card in the card slot.",0
s_card_in:	db "A card is in the card slot.",0
s_no_usb:	db "This machine has no USB port.",0
s_usb:		db "USB: nothing to show yet.",0
s_bios:		db "MasterDrive BIOS 1",0
s_id:		db "Machine ID ",0
s_video:	db "Video ",0
s_ntsc:		db "NTSC, 60 Hz",0
s_pal:		db "PAL, 50 Hz",0
s_region:	db "Region ",0
s_export:	db "export",0
s_japan:	db "Japan",0
s_padtest:	db "Controller test: press B",0
s_skip1:	db "Hold Start while switching on to start",0
s_skip2:	db "the game straight away.",0
s_st_cart:	db "CART  START play  B change  C top",0
s_st_nocart:	db "CART  insert a cartridge",0
s_sf_nocart:	db "The SF-7000 starts from its disks.",0
s_st_sf:	db "CART  START SF-7000",0
s_st_card:	db "CARD  <> devices",0
s_st_usb:	db "USB  <> devices",0
s_st_system:	db "SYSTEM  B controller test  <> devices",0
s_st_test:	db "TEST  every button shows; Start+A: end",0
