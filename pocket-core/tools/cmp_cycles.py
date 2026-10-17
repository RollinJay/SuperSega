#!/usr/bin/env python3
"""Compare the core's instruction timing with the emulator's on a ROM run at 100 %.

usage: cmp_cycles.py core.bin emulator.bin rom [--no-dma] [--count N]

core.bin comes from sim/sys/tb_mdr -trace, emulator.bin from
../emulator/tools/jstrace.js: one record per instruction (PC, SP, A, F, cycle
count, line). Both must run the same instructions, and the difference between
their cycle counts must stay what it was at the first instruction. The one
exception is a DMA transfer: the emulator charges it to the instruction that
starts it (an OUT to $FA), the core holds the CPU in the next instruction's
opcode fetch, so the difference may move for that one instruction and must be
back at the next. Stops at the first OUT ($F3),A, a turbo step, after which
the core's count (base cycles) is no longer in T-states. Used by sim/check.sh
on roms/dma.sms, where a run with no DMA transfer is an error, and with --no-dma on
the BIOS (rom being bios/masterdrive_bios.rom), which makes none: there the
difference may never move. --count N: exactly N instructions must be compared
(both traces at least that long), so a short trace cannot pass."""
import struct
import sys

REC = struct.Struct('<HHBBIH')


def load(path):
    d = open(path, 'rb').read()
    return [REC.unpack_from(d, i * REC.size) for i in range(len(d) // REC.size)]


def is_out(rom, pc):
    """An instruction that writes a port (a DMA start is one of these)."""
    if pc >= len(rom):
        return False
    op = rom[pc]
    return op == 0xD3 or (op == 0xED and pc + 1 < len(rom) and rom[pc + 1] in
                          (0xA3, 0xAB, 0xB3, 0xBB, 0x41, 0x49, 0x51, 0x59, 0x61, 0x69, 0x79))


def more(x):
    return f'{x} cycles more' if x > 0 else f'{-x} cycles fewer'


def main():
    core, emu, rom = load(sys.argv[1]), load(sys.argv[2]), open(sys.argv[3], 'rb').read()
    opts = sys.argv[4:]
    no_dma = '--no-dma' in opts
    want = int(opts[opts.index('--count') + 1]) if '--count' in opts else None
    n = min(len(core), len(emu))
    if want is not None:
        if n < want:
            sys.exit(f'WRONG: {want} instructions wanted, the traces have {len(core)} (core) and {len(emu)} (emulator)')
        n = want
    base = emu[0][4] - core[0][4]
    moved = checked = 0
    for i in range(n):
        pc = emu[i][0]
        if core[i][0] != pc or core[i][1] != emu[i][1]:
            sys.exit(f'WRONG: instruction {i}: the core is at PC ${core[i][0]:04X}, the emulator at ${pc:04X}')
        if i and emu[i - 1][0] < len(rom) - 1 and rom[emu[i - 1][0]] == 0xD3 and rom[emu[i - 1][0] + 1] == 0xF3:
            break                                  # a turbo step: stop
        d = emu[i][4] - core[i][4] - base
        checked += 1
        if d == 0:
            continue
        nxt = emu[i + 1][4] - core[i + 1][4] - base if i + 1 < n else None
        after_out = i and is_out(rom, emu[i - 1][0])
        if after_out and nxt == 0 and not no_dma:
            moved += 1
            continue
        if after_out and nxt is not None and not no_dma:
            sys.exit(f'WRONG: after the output at PC ${emu[i - 1][0]:04X} (instruction {i - 1}) the core has '
                     f'spent {more(-nxt)} than the emulator')
        sys.exit(f'WRONG: at instruction {i} (PC ${pc:04X}) the core has spent {more(-d)} than the emulator')
    if want is not None and checked != want:
        sys.exit(f'WRONG: {checked} instructions compared, {want} wanted (a turbo step came first)')
    if no_dma:
        print(f'{checked} instructions: same time as the emulator')
        return
    if moved == 0:
        sys.exit(f'WRONG: {checked} instructions compared and no DMA transfer seen')
    print(f'{checked} instructions, {moved} transfers: same time as the emulator')


if __name__ == '__main__':
    main()
