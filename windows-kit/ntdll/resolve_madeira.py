#!/usr/bin/env python3
"""NotProton's build_module steamclient detour for Madeira's ARM64EC ntdll.dll (MacShack Play, N2).

    resolve_madeira.py --sh <ntdll.dll>                    shell assignments for build.sh
    resolve_madeira.py --apply <ntdll.dll> <out> <payload>  write the patched copy
    resolve_madeira.py <ntdll.dll>                         report (and self-test against the pinned build)

NotProton (windows-kit/build/notproton, v1.0.3, GPL-3.0) patches CrossOver's shipped ntdll: a `bl` from build_module
into a code cave that, for steamclient64.dll, loads lsteamclient.dll and points every export of Valve's DLL at
lsteamclient's (its ntdll-patch/detour.c). Its resolve.py is imported from that checkout ($NOTPROTON), not copied,
and does the work it already does for CrossOver's FEX ntdll (the hook site: the nop where alloc_module's id block
joins; the MODREF register; the load_path frame slot; the cave). Only what differs on Madeira's ARM64EC image is
here:
- its header says AMD64 (every ARM64EC image does) while its code is ARM64: resolved as aarch64;
- one loader, not CrossOver's native + guest pair: one site;
- exports point at .hexpthk x64 thunks (mov rax, rsp; ...; jmp <ARM64EC body>): LdrGetDllHandle and LdrLoadDll are
  those jump targets;
- NtProtectVirtualMemory's export is the x64 syscall stub: the ARM64EC thunk into it that build_module itself calls
  (NotProton's guest-syscall search, as for its guest copy);
- the cave ends where .text is mapped (VirtualSize, page-rounded): Madeira executes .text from a copy in its JIT pool
  made of those pages only.
"""
import hashlib
import os
import struct
import sys

NOTPROTON = os.environ.get('NOTPROTON', os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'build', 'notproton'))
sys.path.insert(0, os.path.join(NOTPROTON, 'ntdll-patch'))
import resolve as NP  # noqa: E402  (NotProton's)

PAYLOAD_MAX = 1024   # NotProton's aarch64 payload is 868 bytes; ours drops the second site
PAGE = 0x1000

# Madeira v0.1.3's arm64ec-windows/ntdll.dll (windows-kit/fetch.sh): the values this resolver found, kept as a self-test.
PINNED = {
    '59c1523792cef4f5d4cbffdd62d8c7d9682be8c718fb7d65db2dcf711e3f7e51':
        {'hookRVA': 0x375a8, 'wm': 'x22', 'load_path': -0x80, 'build_module': 0x370fc,
         'LdrGetDllHandle': 0x2ce3c, 'LdrLoadDll': 0x2e964, 'NtProtectVirtualMemory': 0x80e60},
}


def thunk_target(pe, rva):
    """The ARM64EC body an .hexpthk x64 export thunk jumps to (its last instruction, jmp rel32)."""
    o = pe.off(rva)
    head = bytes.fromhex('488bc448895820555de9')   # mov rax, rsp; mov [rax+0x20], rbx; push rbp; pop rbp; jmp
    if pe.d[o:o + len(head)] != head:
        raise SystemExit(f"{pe.path}: export at {rva:#x} is not an x64 export thunk")
    return rva + len(head) + 4 + struct.unpack_from('<i', pe.d, o + len(head))[0]


def resolve(path):
    pe = NP.PE(path)
    if pe.machine != 0x8664 or not any(s[0] == '.hexpthk' for s in pe.secs):
        raise SystemExit(f"{path}: not an ARM64EC image (machine {pe.machine:#x}, no .hexpthk)")
    pe.machine = 0xaa64   # ARM64EC code is ARM64: NotProton's aarch64 path reads it
    md = pe.cs()
    refs = NP.aarch64_literal_refs(pe, ('build_module', 'alloc_module'))
    allocs = {NP.aarch64_open(pe, md, a[0]) for n, a in refs.values() if n == 'alloc_module'}
    sites = [NP.aarch64_hook(pe, md, a[0], allocs) for n, a in refs.values() if n == 'build_module']
    if len({s['hookRVA'] for s in sites}) != 1:
        raise SystemExit(f"{path}: {len(sites)} build_module copies, Madeira's ntdll has one loader")
    site = sites[0]

    ex = pe.exports()
    get_handle, load_dll = thunk_target(pe, ex['LdrGetDllHandle']), thunk_target(pe, ex['LdrLoadDll'])
    thunks = syscall_thunks(pe, md, ex["NtProtectVirtualMemory"])
    bm = site['build_module']
    called = {int(i.op_str.lstrip('#'), 0) for i in NP.aarch64_body(pe, md, bm, bm + 0x1000) if i.mnemonic == 'bl'}
    protect = thunks & called
    if len(protect) != 1:
        raise SystemExit(f"{path}: build_module calls {len(protect)} NtProtectVirtualMemory thunks, want 1")

    _, vrva, vsize, roff, rsize = pe.sec('.text')
    cave = vrva + vsize
    payload = (cave + 15) & ~15
    mapped_end = (cave + PAGE - 1) & ~(PAGE - 1)
    return {**site, 'pe': pe, 'imageBase': pe.imagebase, 'sha256': hashlib.sha256(pe.d).hexdigest(),
            'LdrGetDllHandle': get_handle, 'LdrLoadDll': load_dll, 'NtProtectVirtualMemory': protect.pop(),
            'caveRVA': cave, 'payloadRVA': payload, 'room': mapped_end - payload, 'fill': pe.d[roff + vsize]}


def syscall_thunks(pe, md, stub):
    """ARM64EC functions that load the x64 syscall stub's address into x11 and call into it (NotProton's
    aarch64_guest_syscall, from the stub itself: there is no native copy to read the number from)."""
    tv, text = pe.text()
    body = list(NP.aarch64_walk(md, text, tv))
    found = set()
    for n, i in enumerate(body[:-1]):
        nx = body[n + 1]
        if i.mnemonic != 'adrp' or not i.op_str.startswith('x11, '):
            continue
        if nx.mnemonic != 'add' or not nx.op_str.startswith('x11, x11, #'):
            continue
        if int(i.op_str.split('#')[1], 0) + int(nx.op_str.split('#')[1], 0) != stub:
            continue
        entry = i.address - 8
        head = NP.aarch64_body(pe, md, entry, entry + 4)
        if head and head[0].mnemonic == 'str' and head[0].op_str.startswith('x30, [sp, #-'):
            found.add(entry)
    if not found:
        raise SystemExit(f"{pe.path}: no ARM64EC thunk into the syscall stub at {stub:#x}")
    return found


def shell_vars(path):
    r = resolve(path)
    va = lambda rva: f"{r['imageBase'] + rva:#x}"   # noqa: E731
    return {'NP_SHA256': r['sha256'], 'NP_IMAGEBASE': f"{r['imageBase']:#x}",
            'NP_HOOK_RVA': f"{r['hookRVA']:#x}", 'NP_STOLEN': r['stolen'], 'NP_RESUME_VA': va(r['resume']),
            'NP_LOAD_PATH': f"{r['load_path']:#x}", 'NP_WM': r['wm'],
            'NP_CAVE_RVA': f"{r['caveRVA']:#x}", 'NP_PAYLOAD_RVA': f"{r['payloadRVA']:#x}",
            'NP_PAYLOAD_VA': va(r['payloadRVA']), 'NP_CAVE_ROOM': str(r['room']), 'NP_FILL': f"{r['fill']:#04x}",
            'NP_LDR_GET_DLL_HANDLE': va(r['LdrGetDllHandle']), 'NP_LDR_LOAD_DLL': va(r['LdrLoadDll']),
            'NP_NT_PROTECT_VIRTUAL_MEMORY': va(r['NtProtectVirtualMemory'])}


def apply(src, dst, payload_path):
    """NotProton's apply.py, its aarch64 branch: payload into the cave, the nop at the hook becomes `bl cave`."""
    r = resolve(src)
    detour = open(payload_path, 'rb').read()
    if len(detour) > r['room']:
        raise SystemExit(f"payload is {len(detour)} bytes, the mapped cave holds {r['room']}")
    pe, d = r['pe'], bytearray(r['pe'].d)
    cave_off = pe.off(r['payloadRVA'])
    if any(b != r['fill'] for b in d[cave_off:cave_off + len(detour)]):
        raise SystemExit(f"cave at {cave_off:#x} is not {r['fill']:#02x} pad for {len(detour)} bytes")
    d[cave_off:cave_off + len(detour)] = detour
    hook_off = pe.off(r['hookRVA'])
    if d[hook_off:hook_off + 4] != bytes.fromhex(r['stolen']):
        raise SystemExit(f"unexpected hook site at {r['hookRVA']:#x}: {d[hook_off:hook_off + 4].hex()}")
    rel = r['payloadRVA'] - r['hookRVA']
    if rel % 4 or not -(1 << 27) <= rel < (1 << 27):
        raise SystemExit(f"cave is {rel:#x} from the hook, out of bl range")
    d[hook_off:hook_off + 4] = (0x94000000 | ((rel >> 2) & 0x03ffffff)).to_bytes(4, 'little')
    tmp = dst + '.tmp'
    with open(tmp, 'wb') as f:
        f.write(d)
    os.replace(tmp, dst)
    print(f"patched {src} -> {dst}: payload {len(detour)} bytes at rva {r['payloadRVA']:#x}, "
          f"hook {r['hookRVA']:#x} bl rel {rel:#x}")


def report(path):
    r = resolve(path)
    pin = PINNED.get(r['sha256'], {})
    ok = True
    print(f"{path}\n  sha256 {r['sha256']}{' (pinned build)' if pin else ' (not a pinned build)'}")
    for key in ('build_module', 'hookRVA', 'wm', 'load_path', 'LdrGetDllHandle', 'LdrLoadDll', 'NtProtectVirtualMemory'):
        got = r[key]
        tag = '' if key not in pin else '  MATCH' if pin[key] == got else f"  MISMATCH (pinned {pin[key]})"
        ok = ok and 'MISMATCH' not in tag
        print(f"  {key:24} {got if isinstance(got, str) else hex(got)}{tag}")
    print(f"  cave {r['caveRVA']:#x}, payload at {r['payloadRVA']:#x}, {r['room']} bytes mapped, fill {r['fill']:#04x}")
    return ok


if __name__ == '__main__':
    a = sys.argv[1:]
    if a[:1] == ['--sh'] and len(a) == 2:
        for k, v in shell_vars(a[1]).items():
            print(f"{k}='{v}'")
    elif a[:1] == ['--apply'] and len(a) == 4:
        apply(a[1], a[2], a[3])
    elif len(a) == 1:
        sys.exit(0 if report(a[0]) else 1)
    else:
        raise SystemExit(__doc__)
