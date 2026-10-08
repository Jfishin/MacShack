#import "ShackVAReport.h"
#import <os/proc.h>
#import <mach/mach.h>
#import <sys/mman.h>

extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

static NSString *gb(uint64_t v) { return [NSString stringWithFormat:@"%.1f GB", v / 1073741824.0]; }

// Numbers to compare across devices and builds (usable band 448-512 GB on iOS 27 with increased-memory-limit).
NSString *ShackVAReport(BOOL reserve) {
    NSMutableString *o = [NSMutableString string];
    const uint64_t GB = 1ull << 30;
    mach_port_t task = mach_task_self();

    NSMutableData *blob = [NSMutableData dataWithLength:65536];   // CS_OPS_ENTITLEMENTS_BLOB: 8-byte header, then XML
    NSDictionary *ents = nil;
    if (csops(getpid(), 7, blob.mutableBytes, blob.length) == 0) {
        uint32_t len = ntohl(*(uint32_t *)((uint8_t *)blob.mutableBytes + 4));
        if (len > 8 && len <= blob.length)
            ents = [NSPropertyListSerialization propertyListWithData:[blob subdataWithRange:NSMakeRange(8, len - 8)]
                                                             options:0 format:NULL error:NULL];
    }
    [o appendFormat:@"pid %d, entitlements:", getpid()];
    for (NSString *k in [ents.allKeys sortedArrayUsingSelector:@selector(compare:)])
        if ([k containsString:@"memory"] || [k containsString:@"virtual"] || [k isEqual:@"get-task-allow"])
            [o appendFormat:@" %@=%@", k, ents[k]];
    [o appendString:ents ? @"\n" : @" (unreadable)\n"];

    task_vm_info_data_t vi = {0}; mach_msg_type_number_t cnt = TASK_VM_INFO_COUNT;
    task_info(task, TASK_VM_INFO, (task_info_t)&vi, &cnt);
    [o appendFormat:@"VA max 0x%llx (%@), virtual %@, footprint %@, limit remaining %@, os_proc_available_memory %@\n",
        vi.max_address, gb(vi.max_address), gb(vi.virtual_size), gb(vi.phys_footprint), gb(vi.limit_bytes_remaining),
        gb(os_proc_available_memory())];

    [o appendString:@"map, top level (regions and free gaps >= 1 GB):\n"];
    vm_address_t addr = 0, prevEnd = (vm_address_t)vi.min_address;
    uint64_t freeTotal = 0;
    for (;;) {
        vm_size_t size = 0; natural_t depth = 0;
        vm_region_submap_info_data_64_t info; mach_msg_type_number_t c = VM_REGION_SUBMAP_INFO_COUNT_64;
        if (vm_region_recurse_64(task, &addr, &size, &depth, (vm_region_recurse_info_t)&info, &c) != KERN_SUCCESS) break;
        if (addr > prevEnd) {
            freeTotal += addr - prevEnd;
            if (addr - prevEnd >= GB) [o appendFormat:@"  0x%010lx-0x%010lx %9@  free\n", prevEnd, addr, gb(addr - prevEnd)];
        }
        if (size >= GB) [o appendFormat:@"  0x%010lx-0x%010lx %9@  tag %u%s\n", addr, addr + size, gb(size), info.user_tag,
                                         info.is_submap ? " submap" : ""];
        prevEnd = addr + size; addr += size;
    }
    if (vi.max_address > prevEnd) {
        freeTotal += vi.max_address - prevEnd;
        [o appendFormat:@"  0x%010lx-0x%010llx %9@  free (to max)\n", prevEnd, vi.max_address, gb(vi.max_address - prevEnd)];
    }
    [o appendFormat:@"free inside [min,max): %@\n", gb(freeTotal)];
    if (!reserve) return o;

    [o appendString:@"fixed 1 GB scan, 4 GB - 1 TB (vm_allocate FIXED, freed at once):"];
    long run = -1;
    for (uint64_t g = 4; g <= 1024; g++) {
        vm_address_t a = (vm_address_t)(g * GB);
        BOOL ok = g < 1024 && vm_allocate(task, &a, GB, VM_FLAGS_FIXED) == KERN_SUCCESS;
        if (ok) vm_deallocate(task, a, GB);
        if (ok && run < 0) run = (long)g;
        if (!ok && run >= 0) { [o appendFormat:@" free %ld-%llu GB;", run, g]; run = -1; }
    }
    uint64_t lo = 0, hi = 1024;   // largest single reservation, in whole GB
    while (lo < hi) {
        uint64_t mid = (lo + hi + 1) / 2;
        void *p = mmap(NULL, mid * GB, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (p != MAP_FAILED) { munmap(p, mid * GB); lo = mid; } else hi = mid - 1;
    }
    static void *chunks[1024]; int k = 0;   // Apple's jumbo test: entitled processes reach >= 51 here
    while (k < 1024 && (chunks[k] = mmap(NULL, GB, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0)) != MAP_FAILED) k++;
    [o appendFormat:@"\nlargest single PROT_NONE mmap %llu GB; cumulative 1 GB mmaps %d\n", lo, k];
    while (k) munmap(chunks[--k], GB);
    return o;
}
