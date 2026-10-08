#!/usr/bin/env python3
"""Finds where Steam Play's switches sit in a macOS steamclient.dylib (arm64 slice), for MacShack's prepare-time patches.

    python3 prep/steam-onehost/steamplay_sites.py <steamclient.dylib>

Each function is found by a string only it references (ADRP+ADD to the string, then back to the function's prologue);
the anchor strings are facts about Valve's client, as NotProton (the Mac Steam Play add-on, GPL) documents them. Prints
the virtual addresses and original instruction words MacShack's patch table (host/ShackSteamPlay.m) needs. Mac only,
needs capstone (pip install capstone).
"""
import struct
import sys

from capstone import CS_ARCH_ARM64, CS_MODE_ARM, Cs
from capstone.arm64 import ARM64_OP_MEM

FAT_MAGIC, MH_MAGIC_64, CPU_ARM64 = 0xCAFEBABE, 0xFEEDFACF, 0x0100000C
LC_SEGMENT_64 = 0x19


def arm64_slice(data):
    if struct.unpack_from('>I', data)[0] == FAT_MAGIC:
        for i in range(struct.unpack_from('>I', data, 4)[0]):
            cpu, _, off, size, _ = struct.unpack_from('>iiIII', data, 8 + 20 * i)
            if cpu == CPU_ARM64:
                return data[off:off + size]
        sys.exit('no arm64 slice')
    return data


def sections(macho):
    assert struct.unpack_from('<I', macho)[0] == MH_MAGIC_64
    ncmds = struct.unpack_from('<I', macho, 16)[0]
    off, out = 32, {}
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', macho, off)
        if cmd == LC_SEGMENT_64:
            nsects = struct.unpack_from('<I', macho, off + 64)[0]
            for s in range(nsects):
                base = off + 72 + 80 * s
                sect = macho[base:base + 16].rstrip(b'\0').decode()
                seg = macho[base + 16:base + 32].rstrip(b'\0').decode()
                addr, size_, fileoff = struct.unpack_from('<QQI', macho, base + 32)
                out[(seg, sect)] = (addr, size_, fileoff)
        off += size
    return out


def word(macho, text, addr):
    taddr, _, toff = text
    return struct.unpack_from('<I', macho, toff + addr - taddr)[0]


def main(path):
    macho = arm64_slice(open(path, 'rb').read())
    secs = sections(macho)
    text, cstr = secs[('__TEXT', '__text')], secs[('__TEXT', '__cstring')]
    taddr, tsize, toff = text
    code = macho[toff:toff + tsize]

    def string_addr(s):
        caddr, csize, coff = cstr
        blob = macho[coff:coff + csize]
        i = blob.find(b'\0' + s.encode() + b'\0')
        if i < 0:
            sys.exit(f'string not found: {s!r}')
        return caddr + i + 1

    # Every ADRP+ADD pair in __text, once: target address -> instruction addresses of the ADD.
    xrefs = {}
    words = struct.unpack_from(f'<{tsize // 4}I', code)
    for i in range(len(words) - 1):
        w = words[i]
        if (w & 0x9F000000) != 0x90000000:   # ADRP
            continue
        rd = w & 0x1F
        imm = ((w >> 29) & 3) | (((w >> 5) & 0x7FFFF) << 2)
        if imm & (1 << 20):
            imm -= 1 << 21
        pc = taddr + 4 * i
        page = (pc & ~0xFFF) + (imm << 12)
        for j in range(i + 1, min(i + 4, len(words))):   # the ADD may be a few instructions later
            a = words[j]
            if (a & 0xFFC00000) == 0x91000000 and (a >> 5) & 0x1F == rd:   # ADD Xd, Xrd, #imm12
                xrefs.setdefault(page + ((a >> 10) & 0xFFF), []).append(taddr + 4 * j)
                break

    def function_start(addr):   # back to the prologue: SUB SP / STP pre-index / PACIBSP
        a = addr
        while a > taddr:
            w = word(macho, text, a)
            if (w & 0xFF8003FF) == 0xD10003FF or (w & 0xFFC003E0) == 0xA98003E0 or w == 0xD503237F:
                # the frame's first instruction: keep going while the previous one is also prologue work
                p = word(macho, text, a - 4)
                if (p & 0xFFC003E0) == 0xA98003E0 or p == 0xD503237F:
                    a -= 4
                    continue
                return a
            a -= 4
        sys.exit(f'no prologue before 0x{addr:x}')

    def function_of(s, nth=0):
        refs = sorted(xrefs.get(string_addr(s), []))
        if len(refs) <= nth:
            sys.exit(f'no xref #{nth} to {s!r}')
        return function_start(refs[nth])

    md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    md.detail = True

    def body(start, limit=4000):   # a function's instructions, to its last RET within `limit`
        o = toff + start - taddr
        out, last_ret = [], 0
        for ins in md.disasm(macho[o:o + 4 * limit], start):
            out.append(ins)
            if ins.mnemonic == 'ret':
                last_ret = len(out)
        return out[:last_ret] if last_ret else out

    def mem(ins, disp):
        return len(ins.operands) > 1 and ins.operands[1].type == ARM64_OP_MEM and ins.operands[1].mem.disp == disp

    sites = []   # (name, address, original word, replacement word, what it does)

    # The enabled byte's offset: BIsCompatibilityToolEnabled's first LDRB.
    getter = function_of('CCompatManager::BIsCompatibilityToolEnabled')
    offset = next(i.operands[1].mem.disp for i in body(getter, 200) if i.mnemonic == 'ldrb' and i.operands[1].type == ARM64_OP_MEM)

    # 1. Init stores (platform == "linux") into it: `cset wN, eq` right before `strb wN, [x, #offset]` -> `mov wN, #1`.
    init = body(function_of('STEAM_COMPAT_TOOL_MAPPINGS'))
    hits = [(a, b) for a, b in zip(init, init[1:]) if b.mnemonic == 'strb' and mem(b, offset) and a.mnemonic == 'cset'
            and a.op_str.endswith(', eq') and a.op_str.split(',')[0] == b.op_str.split(',')[0]]
    if len(hits) != 1:
        sys.exit(f'Init: {len(hits)} cset+strb of the enabled byte')
    cset = hits[0][0]
    reg = int(cset.op_str.split(',')[0][1:])
    sites.append(('steam-play-enabled', cset.address, word(macho, text, cset.address), 0x52800020 | reg,
                  f'Init: enabled = (platform == "linux") -> enabled = 1 ({cset.mnemonic} {cset.op_str} -> mov w{reg}, #1)'))

    # 2. "Disabling compatibility layer." then `strb wzr, [x, #offset]` -> nop.
    off_fn = body(function_of('Disabling compatibility layer.'), 200)
    hits = [i for i in off_fn if i.mnemonic == 'strb' and i.op_str.startswith('wzr,') and mem(i, offset)]
    if len(hits) != 1:
        sys.exit(f'disable: {len(hits)} zero stores of the enabled byte')
    sites.append(('steam-play-stays-on', hits[0].address, word(macho, text, hits[0].address), 0xD503201F,
                  '"Disabling compatibility layer." no longer clears the enabled byte (strb wzr -> nop)'))

    # 3. GetOSListOverrideForApp: the tool's to_oslist (+0x78) is matched against the platform (BL), CBZ X0 returns
    # "no override" when it does not match, else the override is the tool's from_oslist (+0x70). CBZ -> nop.
    found = []
    for ref in sorted(xrefs.get(string_addr('pTool != nullptr'), [])):
        o = toff + ref - taddr
        window = list(md.disasm(macho[o - 4 * 40:o], ref - 4 * 40))
        for k in range(1, len(window) - 3):
            bl, cbz = window[k - 1], window[k]
            if not (bl.mnemonic == 'bl' and cbz.mnemonic == 'cbz' and cbz.op_str.startswith('x0,')):
                continue
            before = window[max(0, k - 8):k - 1]
            after = window[k + 1:k + 4]
            if any(mem(i, 0x78) for i in before if i.mnemonic == 'ldr') and any(mem(i, 0x70) for i in after if i.mnemonic == 'ldr'):
                found.append(cbz)
    if len(found) != 1:
        sys.exit(f'oslist gate: {len(found)} candidates')
    sites.append(('windows-depots', found[0].address, word(macho, text, found[0].address), 0xD503201F,
                  "GetOSListOverrideForApp: the tool's from_oslist always overrides (cbz x0 -> nop): Windows depots download"))

    print(f'enabled byte at +0x{offset:x} (BIsCompatibilityToolEnabled 0x{getter:x})')
    for name, addr, orig, new, what in sites:
        print(f'{name}: 0x{addr:x} 0x{orig:08x} -> 0x{new:08x}  {what}')


if __name__ == '__main__':
    main(sys.argv[1])
