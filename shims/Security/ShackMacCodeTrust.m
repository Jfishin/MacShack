#include "ShackMacCodeTrust.h"
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

enum { Untrusted = -66996, MaxSlices = 64 };
typedef struct { uint64_t offset, size; } Slice;
typedef struct {
    void *handle;
    OSStatus (*information)(CFTypeRef, uint32_t, CFDictionaryRef *);
    OSStatus (*create)(CFURLRef, uint32_t, CFDictionaryRef, CFTypeRef *);
    SecPolicyRef (*macPolicy)(void);
    CFArrayRef (*organizationalUnits)(SecCertificateRef);
    CFDataRef (*extension)(SecCertificateRef, CFTypeRef, bool *);
    OSStatus (*validate)(CFTypeRef, uint32_t, CFTypeRef);
    CFStringRef executableKey, teamKey, certificatesKey, offsetKey;
} NativeAPI;

static CFStringRef Constant(void *handle, const char *name) {
    const CFStringRef *value = dlsym(handle, name);
    return value ? *value : NULL;
}

static const NativeAPI *Native(void) {
    static NativeAPI api;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        api.handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW | RTLD_LOCAL);
        if (!api.handle) return;
        api.information = dlsym(api.handle, "SecCodeCopySigningInformation");
        api.create = dlsym(api.handle, "SecStaticCodeCreateWithPathAndAttributes");
        api.macPolicy = dlsym(api.handle, "SecPolicyCreateMacOSProfileApplicationSigning");
        api.organizationalUnits = dlsym(api.handle, "SecCertificateCopyOrganizationalUnit");
        api.extension = dlsym(api.handle, "SecCertificateCopyExtensionValue");
        api.validate = dlsym(api.handle, "SecStaticCodeCheckValidity");
        api.executableKey = Constant(api.handle, "kSecCodeInfoMainExecutable");
        api.teamKey = Constant(api.handle, "kSecCodeInfoTeamIdentifier");
        api.certificatesKey = Constant(api.handle, "kSecCodeInfoCertificates");
        api.offsetKey = Constant(api.handle, "kSecCodeAttributeUniversalFileOffset");
    });
    return api.information && api.create && api.macPolicy && api.organizationalUnits && api.extension &&
        api.validate && api.executableKey &&
        api.teamKey && api.certificatesKey && api.offsetKey ? &api : NULL;
}

static uint32_t Read32(const uint8_t *p, bool little) {
    if (little) return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
    return (uint32_t)p[3] | (uint32_t)p[2] << 8 | (uint32_t)p[1] << 16 | (uint32_t)p[0] << 24;
}
static uint64_t Read64(const uint8_t *p, bool little) {
    return little ? (uint64_t)Read32(p, true) | (uint64_t)Read32(p + 4, true) << 32 :
        (uint64_t)Read32(p, false) << 32 | Read32(p + 4, false);
}
static bool ReadAt(int fd, void *data, size_t size, uint64_t offset) {
    return offset <= INT64_MAX && pread(fd, data, size, (off_t)offset) == (ssize_t)size;
}
static bool MachHeader(int fd, Slice slice, uint32_t *cpu, uint32_t *subtype) {
    uint8_t bytes[12];
    if (slice.size < 28 || !ReadAt(fd, bytes, sizeof bytes, slice.offset)) return false;
    uint32_t magic = Read32(bytes, true);
    bool little = magic == 0xfeedface || magic == 0xfeedfacf;
    if (!little && magic != 0xcefaedfe && magic != 0xcffaedfe) return false;
    if ((magic == 0xfeedfacf || magic == 0xcffaedfe) && slice.size < 32) return false;
    *cpu = Read32(bytes + 4, little); *subtype = Read32(bytes + 8, little);
    return true;
}

// Only enumerate slice boundaries; Security remains responsible for Mach-O/signature parsing.
static bool ReadSlices(int fd, uint64_t size, Slice slices[MaxSlices], unsigned *count) {
    uint8_t header[8], table[MaxSlices * 32];
    if (!ReadAt(fd, header, sizeof header, 0)) return false;
    uint32_t magic = Read32(header, false), cpu, subtype;
    bool fat64 = magic == 0xcafebabf || magic == 0xbfbafeca;
    bool little = magic == 0xbebafeca || magic == 0xbfbafeca;
    if (!fat64 && magic != 0xcafebabe && magic != 0xbebafeca) {
        slices[0] = (Slice){0, size}; *count = 1;
        return MachHeader(fd, slices[0], &cpu, &subtype);
    }
    unsigned n = Read32(header + 4, little), stride = fat64 ? 32 : 20;
    uint64_t end = 8 + (uint64_t)n * stride;
    if (!n || n > MaxSlices || end > size || !ReadAt(fd, table, n * stride, 8)) return false;
    for (unsigned i = 0; i < n; i++) {
        const uint8_t *entry = table + i * stride;
        uint64_t offset = fat64 ? Read64(entry + 8, little) : Read32(entry + 8, little);
        uint64_t length = fat64 ? Read64(entry + 16, little) : Read32(entry + 12, little);
        // Apple's attribute implementation reads a signed int, including for FAT64 inputs.
        if (offset < end || offset > INT_MAX || offset > size || !length || length > size - offset) return false;
        slices[i] = (Slice){offset, length};
        if (!MachHeader(fd, slices[i], &cpu, &subtype) || cpu != Read32(entry, little) ||
            subtype != Read32(entry + 4, little)) return false;
        for (unsigned j = 0; j < i; j++)
            if (offset < slices[j].offset + slices[j].size && slices[j].offset < offset + length) return false;
    }
    *count = n;
    return true;
}

static bool ReadTeam(CFTypeRef value, char team[11]) {
    if (!value || CFGetTypeID(value) != CFStringGetTypeID() || CFStringGetLength(value) != 10 ||
        !CFStringGetCString(value, team, 11, kCFStringEncodingASCII)) return false;
    for (unsigned i = 0; i < 10; i++)
        if (!((team[i] >= 'A' && team[i] <= 'Z') || (team[i] >= '0' && team[i] <= '9'))) return false;
    return true;
}

// Use native certificate accessors: certificate requirement operators are unavailable on iOS.
static bool HasMarker(const NativeAPI *api, SecCertificateRef certificate, CFStringRef oid) {
    CFDataRef value = api->extension(certificate, oid, NULL);
    bool present = value && CFGetTypeID(value) == CFDataGetTypeID();
    if (value) CFRelease(value);
    return present;
}

static bool ValidateSlice(const NativeAPI *api, CFURLRef path, Slice slice, unsigned index, bool wrongTeam) {
    bool accepted = false, leafMarker = false, issuerMarker = false, teamMatch = false, wrongRejected = false;
    int offset = (int)slice.offset;
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberIntType, &offset);
    CFDictionaryRef attributes = number ? CFDictionaryCreate(NULL, (const void **)&api->offsetKey,
        (const void **)&number, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks) : NULL;
    CFTypeRef code = NULL;
    CFDictionaryRef info = NULL;
    CFArrayRef units = NULL, policies = NULL, evaluatedChain = NULL;
    SecPolicyRef codePolicy = NULL, applePolicy = NULL;
    SecTrustRef trust = NULL;
    CFDateRef now = NULL;
    CFErrorRef error = NULL;
    char team[11] = "", ou[11] = "";
    OSStatus native = Untrusted, trustStatus = Untrusted;
    if (!attributes || api->create(path, 0, attributes, &code) != 0 || !code) goto done;
    // A fresh code object must pass CMS/content/resource checks before its metadata is trusted.
    native = api->validate(code, 0, NULL);
    if (native != 0 && native != Untrusted) goto done;
    if (api->information(code, 2, &info) != 0 || !info || CFGetTypeID(info) != CFDictionaryGetTypeID()) goto done;
    if (!ReadTeam(CFDictionaryGetValue(info, api->teamKey), team)) goto done;
    CFTypeRef certificates = CFDictionaryGetValue(info, api->certificatesKey);
    if (!certificates || CFGetTypeID(certificates) != CFArrayGetTypeID() || CFArrayGetCount(certificates) != 3) goto done;
    for (CFIndex i = 0; i < CFArrayGetCount(certificates); i++)
        if (CFGetTypeID(CFArrayGetValueAtIndex(certificates, i)) != SecCertificateGetTypeID()) goto done;
    SecCertificateRef leaf = (SecCertificateRef)CFArrayGetValueAtIndex(certificates, 0);
    SecCertificateRef issuer = (SecCertificateRef)CFArrayGetValueAtIndex(certificates, 1);
    units = api->organizationalUnits(leaf);
    if (!units || CFGetTypeID(units) != CFArrayGetTypeID() || CFArrayGetCount(units) != 1 ||
        !ReadTeam(CFArrayGetValueAtIndex(units, 0), ou)) goto done;
    teamMatch = strcmp(team, ou) == 0;
    if (!teamMatch) goto done;
    if (wrongTeam) {
        char wrong[11]; memcpy(wrong, team, sizeof wrong); wrong[0] = team[0] == 'A' ? 'B' : 'A';
        wrongRejected = strcmp(wrong, ou) != 0;
        if (!wrongRejected) goto done;
    }
    leafMarker = HasMarker(api, leaf, CFSTR("1.2.840.113635.100.6.1.13"));
    issuerMarker = HasMarker(api, issuer, CFSTR("1.2.840.113635.100.6.2.6"));
    if (!leafMarker || !issuerMarker) goto done;
    // The private profile policy supplies Apple anchoring, EKU, chain length and revocation.
    // The public code-signing policy also enforces expiry at NOW (no timestamp equivalence claimed).
    codePolicy = SecPolicyCreateWithProperties(kSecPolicyAppleCodeSigning, NULL);
    applePolicy = api->macPolicy();
    if (!codePolicy || !applePolicy) goto done;
    const void *values[] = { codePolicy, applePolicy };
    policies = CFArrayCreate(NULL, values, 2, &kCFTypeArrayCallBacks);
    trustStatus = policies ? SecTrustCreateWithCertificates(certificates, policies, &trust) : Untrusted;
    if (trustStatus != 0 || !trust) goto done;
    now = CFDateCreate(NULL, CFAbsoluteTimeGetCurrent());
    if (!now) goto done;
    trustStatus = SecTrustSetVerifyDate(trust, now);
    if (trustStatus != 0) goto done;
    trustStatus = SecTrustSetNetworkFetchAllowed(trust, false);
    if (trustStatus != 0) goto done;
    bool trusted = SecTrustEvaluateWithError(trust, &error);
    trustStatus = trusted ? 0 : error ? (OSStatus)CFErrorGetCode(error) : Untrusted;
    if (!trusted) goto done;
    // Bind the inspected marker-bearing certificates to the chain that actually passed trust.
    evaluatedChain = SecTrustCopyCertificateChain(trust);
    if (!evaluatedChain || CFArrayGetCount(evaluatedChain) != 3) goto done;
    for (CFIndex i = 0; i < 3; i++)
        if (!CFEqual(CFArrayGetValueAtIndex(certificates, i), CFArrayGetValueAtIndex(evaluatedChain, i))) goto done;
    accepted = true;
done:
    fprintf(stderr, "[ShackMacCodeTrust] slice=%u offset=0x%llx native=%d leafMarker=%d issuerMarker=%d "
        "team=%s ou=%s teamMatch=%d wrongTeamRejected=%d probe=%d trust=%d accepted=%d\n",
        index, (unsigned long long)slice.offset, (int)native, leafMarker, issuerMarker,
        team, ou, teamMatch, wrongRejected, wrongTeam, (int)trustStatus, accepted);
    if (evaluatedChain) CFRelease(evaluatedChain);
    if (error) CFRelease(error);
    if (now) CFRelease(now);
    if (trust) CFRelease(trust);
    if (policies) CFRelease(policies);
    if (applePolicy) CFRelease(applePolicy);
    if (codePolicy) CFRelease(codePolicy);
    if (units) CFRelease(units);
    if (info) CFRelease(info);
    if (code) CFRelease(code);
    if (attributes) CFRelease(attributes);
    if (number) CFRelease(number);
    return accepted;
}

static bool SameFile(const struct stat *a, const struct stat *b) {
    return a->st_dev == b->st_dev && a->st_ino == b->st_ino && a->st_size == b->st_size &&
        a->st_mtimespec.tv_sec == b->st_mtimespec.tv_sec && a->st_mtimespec.tv_nsec == b->st_mtimespec.tv_nsec &&
        a->st_ctimespec.tv_sec == b->st_ctimespec.tv_sec && a->st_ctimespec.tv_nsec == b->st_ctimespec.tv_nsec;
}

OSStatus ShackMacCodeTrustValidate(CFTypeRef originalCode, bool probeWrongTeam) {
    const NativeAPI *api = Native();
    CFDictionaryRef info = NULL;
    int fd = -1;
    OSStatus result = Untrusted;
    if (!api || !originalCode) return result;
    // Retain all original resource checks, including when the supplied object represents a bundle.
    OSStatus original = api->validate(originalCode, 1, NULL);
    if (original != 0 && original != Untrusted) {
        fprintf(stderr, "[ShackMacCodeTrust] original native=%d rejected\n", (int)original);
        return result;
    }
    if (api->information(originalCode, 2, &info) != 0 || !info || CFGetTypeID(info) != CFDictionaryGetTypeID()) goto done;
    CFTypeRef url = CFDictionaryGetValue(info, api->executableKey);
    char path[PATH_MAX]; struct stat before, after, named;
    Slice slices[MaxSlices]; unsigned count;
    if (!url || CFGetTypeID(url) != CFURLGetTypeID() || !CFURLGetFileSystemRepresentation(url, true, (UInt8 *)path, sizeof path)) goto done;
    fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0 || fstat(fd, &before) != 0 || !S_ISREG(before.st_mode) || before.st_size < 8 ||
        !ReadSlices(fd, (uint64_t)before.st_size, slices, &count)) goto done;
    for (unsigned i = 0; i < count; i++)
        if (!ValidateSlice(api, url, slices[i], i, probeWrongTeam)) goto done;
    if (fstat(fd, &after) != 0 || stat(path, &named) != 0 || !SameFile(&before, &after) || !SameFile(&before, &named)) goto done;
    result = 0;
done:
    if (fd >= 0) close(fd);
    if (info) CFRelease(info);
    fprintf(stderr, "[ShackMacCodeTrust] result=%d wrongTeamProbe=%d\n", (int)result, probeWrongTeam);
    return result;
}
