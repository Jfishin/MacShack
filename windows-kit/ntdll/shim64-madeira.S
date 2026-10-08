// Entry shim for NotProton's build_module steamclient detour (its ntdll-patch/detour.c) in Madeira's ARM64EC ntdll.
// Modeled on NotProton's shim64.S (GPL-3.0, the CrossOver FEX build): the same frame, the same ctx table
// {get_dll_handle, load_dll, protect} and call. Differences, each for Madeira: one hook site (one loader, so no
// return-address test between two), and x18 is neither saved nor restored (on iOS it is the platform register, and
// Madeira rewrites PE code that touches it; detour.c is built with -ffixed-x18, so nothing below changes it).
// The hook replaces build_module's nop with `bl shim_entry64`: x0 holds the MODREF (resolve checks nothing writes it
// on the way), the caller's load_path is in its frame at [x29 + LOAD_PATH], and x30 is dead there (written by a bl
// before any read).

    .text
    .globl shim_entry64

    .set S_NZCV, 0x90
    .set S_X30,  0xa0
    .set S_CTX,  0xb0
    .set FRAME,  0xd0

shim_entry64:
    sub     sp, sp, #FRAME
    stp     x0, x1, [sp, #0x00]
    stp     x2, x3, [sp, #0x10]
    stp     x4, x5, [sp, #0x20]
    stp     x6, x7, [sp, #0x30]
    stp     x8, x9, [sp, #0x40]
    stp     x10, x11, [sp, #0x50]
    stp     x12, x13, [sp, #0x60]
    stp     x14, x15, [sp, #0x70]
    stp     x16, x17, [sp, #0x80]
    mrs     x1, nzcv
    str     x1, [sp, #S_NZCV]
    str     x30, [sp, #S_X30]

    /* ctx table {get_dll_handle, load_dll, protect} */
    adrp    x8, LDR_GETDLLHANDLE
    add     x8, x8, :lo12:LDR_GETDLLHANDLE
    adrp    x9, LDR_LOADDLL
    add     x9, x9, :lo12:LDR_LOADDLL
    stp     x8, x9, [sp, #S_CTX]
    adrp    x8, NT_PROTECT
    add     x8, x8, :lo12:NT_PROTECT
    str     x8, [sp, #(S_CTX + 16)]

    add     x0, sp, #S_CTX
    ldr     x1, [sp, #0x00]
    ldur    x2, [x29, #LOAD_PATH]
    bl      detour_build_module

    ldr     x30, [sp, #S_X30]
    ldr     x1, [sp, #S_NZCV]
    msr     nzcv, x1
    ldp     x16, x17, [sp, #0x80]
    ldp     x14, x15, [sp, #0x70]
    ldp     x12, x13, [sp, #0x60]
    ldp     x10, x11, [sp, #0x50]
    ldp     x8, x9, [sp, #0x40]
    ldp     x6, x7, [sp, #0x30]
    ldp     x4, x5, [sp, #0x20]
    ldp     x2, x3, [sp, #0x10]
    ldp     x0, x1, [sp, #0x00]
    add     sp, sp, #FRAME
    ret
