#!/usr/bin/env python3
"""Check the core's Pocket definition files against the platform's limits and
against the RTL.

usage: check_core_json.py        (from anywhere; paths are relative to this file)

input.json drives the Pocket's own button remapper (Core Settings > Controls):
at most 4 controller blocks of 8 mappings, names of 19 characters or fewer, and
only the eight remappable keys. Each key must be a button pocket/mdr_pocket.v
reads, or remapping it would do nothing.
interact.json is the core settings menu: at most 16 entries, names of 23
characters or fewer, unique ids and addresses, lists of at most 16 options with
a default inside the list, and every address one that mdr_pocket.v decodes.
Limits are from Analogue's openFPGA documentation (input.json, interact.json).
Exit status 0 when everything passes, 1 otherwise.
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CORE = os.path.join(HERE, '..', 'pocket')
DIST = os.path.join(CORE, 'dist', 'Cores', 'MasterDrive.MasterDrive')

# APF pad word bit for each remappable input.json key
KEYBIT = {'pad_btn_a': 4, 'pad_btn_b': 5, 'pad_btn_x': 6, 'pad_btn_y': 7,
          'pad_trig_l': 8, 'pad_trig_r': 9, 'pad_btn_select': 14, 'pad_btn_start': 15}
INTERACT_TYPES = {'check', 'radio', 'slider_u32', 'list', 'action', 'number_u32'}

problems = []


def bad(msg):
    problems.append(msg)


rtl = open(os.path.join(CORE, 'mdr_pocket.v'), encoding='utf-8').read()
m = re.search(r'function \[7:0\] padmap;(.*?)endfunction', rtl, re.S)
read_bits = {int(b) for b in re.findall(r'\bk\[(\d+)\]', m.group(1))} if m else set()
read_bits |= {int(b) for b in re.findall(r'pause_btn\s*<=.*?\bk1\[(\d+)\]', rtl)}
decoded = {int(a, 16) for a in re.findall(r"12'h([0-9A-Fa-f]{3}):", rtl)}
if not read_bits:
    bad('could not find padmap or pause_btn in mdr_pocket.v')

inp = json.load(open(os.path.join(DIST, 'input.json')))['input']
ctrls = inp.get('controllers', [])
if not 1 <= len(ctrls) <= 4:
    bad(f'input.json: {len(ctrls)} controller blocks (1-4 allowed)')
for c in ctrls:
    maps = c.get('mappings', [])
    if c.get('type') != 'default':
        bad(f"input.json: controller type {c.get('type')!r} (only 'default')")
    if len(maps) > 8:
        bad(f'input.json: {len(maps)} mappings (8 allowed)')
    ids, keys = [x['id'] for x in maps], [x['key'] for x in maps]
    if len(set(ids)) != len(ids):
        bad('input.json: duplicate mapping ids')
    if len(set(keys)) != len(keys):
        bad('input.json: a key is mapped twice')
    for x in maps:
        if len(x['name']) > 19:
            bad(f"input.json: name {x['name']!r} is {len(x['name'])} characters (19 allowed)")
        if x['key'] not in KEYBIT:
            bad(f"input.json: key {x['key']!r} is not remappable")
        elif KEYBIT[x['key']] not in read_bits:
            bad(f"input.json: {x['name']!r} uses {x['key']}, pad bit {KEYBIT[x['key']]}, which mdr_pocket.v never reads")

var = json.load(open(os.path.join(DIST, 'interact.json')))['interact']['variables']
if len(var) > 16:
    bad(f'interact.json: {len(var)} entries (16 allowed)')
ids = [v['id'] for v in var]
addrs = [int(v['address'], 16) for v in var]
if len(set(ids)) != len(ids):
    bad('interact.json: duplicate ids')
if len(set(addrs)) != len(addrs):
    bad('interact.json: duplicate addresses')
for v, a in zip(var, addrs):
    n = v['name']
    if len(n) > 23:
        bad(f'interact.json: name {n!r} is {len(n)} characters (23 allowed)')
    if v['type'] not in INTERACT_TYPES:
        bad(f"interact.json: {n!r} has unknown type {v['type']!r}")
    if a >> 12 or (a & 0xFFF) not in decoded:
        bad(f'interact.json: {n!r} writes 0x{a:X}, which mdr_pocket.v does not decode')
    if v['type'] == 'list':
        opts = v.get('options', [])
        if not 1 <= len(opts) <= 16:
            bad(f'interact.json: {n!r} has {len(opts)} options (1-16 allowed)')
        if not 0 <= v.get('defaultval', 0) < len(opts):
            bad(f"interact.json: {n!r} default {v.get('defaultval')} is outside its {len(opts)} options")

# the data slots hold what the machine defines: the largest cartridge (Q2) plus a
# 512-byte copier header, and the cartridge save RAM (Q3)
prof = json.load(open(os.path.join(HERE, '..', '..', 'machine', 'masterdrive_machine_v7.json'), encoding='utf-8'))
slots = {s_['name']: s_ for s_ in json.load(open(os.path.join(DIST, 'data.json')))['data']['data_slots']}
cart_max = prof['media']['cartridge_slot']['max_size_bytes']
if int(slots['Cartridge']['size_maximum'], 16) != cart_max + 512:
    bad(f"data.json: the Cartridge slot holds {slots['Cartridge']['size_maximum']}; the machine takes "
        f"{cart_max} bytes plus a 512-byte header")
sav = prof['memory']['cartridge_ram']['size_bytes']
if int(slots['Save']['size_maximum'], 16) != sav:
    bad(f"data.json: the Save slot holds {slots['Save']['size_maximum']}; cartridge RAM is {sav} bytes")

for p in problems:
    print('PROBLEM', p)
nmap = sum(len(c.get('mappings', [])) for c in ctrls)
print(f'input.json: {nmap} mappings; interact.json: {len(var)} of 16 entries; '
      f'{len(problems)} problem{"" if len(problems) == 1 else "s"}')
sys.exit(1 if problems else 0)
