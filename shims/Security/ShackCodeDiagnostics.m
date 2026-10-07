// SHACK_CODELOG=1 observes guest checks through real Security. SHACK_MAC_CODESIGN=1 opts into native Developer ID
// validation for the iOS embedded-policy trust failure only; real content checks and signing metadata are preserved.
#import <Security/Security.h>
#include "ShackMacCodeTrust.h"
#import <TargetConditionals.h>
#import <dispatch/dispatch.h>
#include <dlfcn.h>
#include <limits.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#if !TARGET_OS_OSX
// Exported by iOS Security, but omitted from its public headers. Match the macOS opaque types and 32-bit flags.
typedef struct __SecCode const *SecStaticCodeRef;
typedef struct __SecRequirement const *SecRequirementRef;
typedef uint32_t SecCSFlags;
#endif

static void *SystemSecurity(void) {
    static void *handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY | RTLD_LOCAL);
    });
    return handle;
}

static BOOL TraceCode(void) {
    static BOOL enabled;
    static dispatch_once_t once;
    static atomic_uint count;
    dispatch_once(&once, ^{ const char *value = getenv("SHACK_CODELOG"); enabled = value && atoi(value) != 0; });
    return enabled && atomic_fetch_add_explicit(&count, 1, memory_order_relaxed) < 64;
}

static const char *Caller(void *address, char *out, size_t size) {
    Dl_info info = {0};
    if (dladdr(address, &info) && info.dli_fbase) {
        const char *name = info.dli_fname ?: "?", *slash = strrchr(name, '/');
        snprintf(out, size, "%s+0x%llx", slash ? slash + 1 : name,
                 (unsigned long long)((uintptr_t)address - (uintptr_t)info.dli_fbase));
    } else snprintf(out, size, "%p", address);
    return out;
}

static CFTypeRef CodeInfoValue(void *handle, CFDictionaryRef information, const char *symbol) {
    const CFStringRef *key = handle ? (const CFStringRef *)dlsym(handle, symbol) : NULL;
    return information && key && *key ? CFDictionaryGetValue(information, *key) : NULL;
}

static void TraceValue(const char *label, CFTypeRef value) {
    if (!value) { fprintf(stderr, "[ShackSecurity] %s=<missing>\n", label); return; }
    CFStringRef description = CFCopyDescription(value);
    if (!description) return;
    char text[4096]; CFIndex used = 0;
    CFStringGetBytes(description, CFRangeMake(0, CFStringGetLength(description)), kCFStringEncodingUTF8,
                     '?', false, (UInt8 *)text, sizeof text - 1, &used);
    text[used] = 0;
    fprintf(stderr, "[ShackSecurity] %s=%s\n", label, text);
    CFRelease(description);
}

static void TraceCodeSigningPolicy(CFArrayRef certificates, SecTrustRef originalTrust) {
    SecPolicyRef policy = SecPolicyCreateWithProperties(kSecPolicyAppleCodeSigning, NULL);
    SecTrustRef trust = NULL;
    OSStatus status = policy ? SecTrustCreateWithCertificates(certificates, policy, &trust) : errSecUnimplemented;
    fprintf(stderr, "[ShackSecurity] independent code-signing trust create=%d\n", (int)status);
    if (status == errSecSuccess && trust) {
        CFAbsoluteTime time = originalTrust ? SecTrustGetVerifyTime(originalTrust) : 0;
        if (time != 0) {
            CFDateRef date = CFDateCreate(NULL, time);
            SecTrustSetVerifyDate(trust, date);
            CFRelease(date);
        }
        SecTrustSetNetworkFetchAllowed(trust, false);
        CFErrorRef error = NULL;
        BOOL accepted = SecTrustEvaluateWithError(trust, &error);
        fprintf(stderr, "[ShackSecurity] independent code-signing trust accepted=%d verifyTime=%.0f\n", accepted, time);
        TraceValue("independent code-signing error", error);
        CFDictionaryRef result = SecTrustCopyResult(trust);
        TraceValue("independent code-signing result", result);
        if (result) CFRelease(result);
        if (error) CFRelease(error);
        CFRelease(trust);
    }
    if (policy) CFRelease(policy);
}

static void TraceFixture(void *handle, const char *variable) {
    const char *relative = getenv(variable), *homeDir = getenv("HOME");
    if (!relative || !homeDir) return;
    char path[PATH_MAX];
    if ((size_t)snprintf(path, sizeof path, "%s/%s", homeDir, relative) >= sizeof path) return;
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), false);
    typedef OSStatus (*Create)(CFURLRef, SecCSFlags, SecStaticCodeRef *);
    typedef OSStatus (*Check)(SecStaticCodeRef, SecCSFlags, SecRequirementRef);
    Create create = handle ? (Create)dlsym(handle, "SecStaticCodeCreateWithPath") : NULL;
    Check check = handle ? (Check)dlsym(handle, "SecStaticCodeCheckValidity") : NULL;
    SecStaticCodeRef code = NULL;
    OSStatus status = url && create ? create(url, 0, &code) : errSecUnimplemented;
    OSStatus validity = status == errSecSuccess && check ? check(code, 1, NULL) : status;
    fprintf(stderr, "[ShackSecurity] fixture %s create=%d validity=%d path=%s\n", variable, (int)status, (int)validity, path);
    if (status == errSecSuccess && code)
        fprintf(stderr, "[ShackSecurity] fixture %s independent Developer ID validation=%d\n", variable,
                (int)ShackMacCodeTrustValidate((CFTypeRef)code, true));
    if (code) CFRelease(code);
    if (url) CFRelease(url);
}

// A failed validity check stops Crimson Desert before it asks for signing information. Inspect the real metadata
// only in diagnostic mode; leave the original result and the framework's cached trust object untouched.
static void TraceFailure(void *handle, SecStaticCodeRef code) {
    typedef OSStatus (*Function)(SecStaticCodeRef, SecCSFlags, CFDictionaryRef *);
    Function real = handle ? (Function)dlsym(handle, "SecCodeCopySigningInformation") : NULL;
    CFDictionaryRef information = NULL;
    OSStatus status = real ? real(code, 2, &information) : errSecUnimplemented;
    fprintf(stderr, "[ShackSecurity] failure signing information status=%d\n", (int)status);
    if (status != errSecSuccess || !information) return;
    TraceValue("failure team", CodeInfoValue(handle, information, "kSecCodeInfoTeamIdentifier"));
    TraceValue("failure timestamp", CodeInfoValue(handle, information, "kSecCodeInfoTimestamp"));
    CFArrayRef certificates = CodeInfoValue(handle, information, "kSecCodeInfoCertificates");
    if (certificates && CFGetTypeID(certificates) == CFArrayGetTypeID()) {
        fprintf(stderr, "[ShackSecurity] failure certificate count=%ld\n", (long)CFArrayGetCount(certificates));
        for (CFIndex i = 0; i < CFArrayGetCount(certificates) && i < 8; i++) {
            CFStringRef subject = SecCertificateCopySubjectSummary((SecCertificateRef)CFArrayGetValueAtIndex(certificates, i));
            TraceValue("failure certificate subject", subject);
            if (subject) CFRelease(subject);
        }
    }
    SecTrustRef trust = (SecTrustRef)CodeInfoValue(handle, information, "kSecCodeInfoTrust");
    if (trust && CFGetTypeID(trust) == SecTrustGetTypeID()) {
        CFArrayRef policies = NULL;
        if (SecTrustCopyPolicies(trust, &policies) == errSecSuccess && policies) {
            for (CFIndex i = 0; i < CFArrayGetCount(policies) && i < 8; i++) {
                CFDictionaryRef properties = SecPolicyCopyProperties((SecPolicyRef)CFArrayGetValueAtIndex(policies, i));
                TraceValue("failure policy", properties);
                if (properties) CFRelease(properties);
            }
            CFRelease(policies);
        }
        CFDictionaryRef result = SecTrustCopyResult(trust);
        TraceValue("failure trust result", result);
        if (result) CFRelease(result);
    } else fprintf(stderr, "[ShackSecurity] failure trust=<missing>\n");
    if (certificates && CFGetTypeID(certificates) == CFArrayGetTypeID()) TraceCodeSigningPolicy(certificates, trust);
    TraceFixture(handle, "SHACK_CODEPROBE_ARM64");
    TraceFixture(handle, "SHACK_CODEPROBE_X86");
    fprintf(stderr, "[ShackSecurity] independent Developer ID validation=%d\n",
            (int)ShackMacCodeTrustValidate((CFTypeRef)code, true));
    CFRelease(information);
}

OSStatus SecStaticCodeCreateWithPath(CFURLRef path, SecCSFlags flags, SecStaticCodeRef *code) {
    typedef OSStatus (*Function)(CFURLRef, SecCSFlags, SecStaticCodeRef *);
    void *handle = SystemSecurity();
    Function real = handle ? (Function)dlsym(handle, "SecStaticCodeCreateWithPath") : NULL;
    OSStatus result;
    if (real) result = real(path, flags, code);
    else { if (code) *code = NULL; result = errSecUnimplemented; }
    if (TraceCode()) {
        char file[PATH_MAX] = "<unavailable>", caller[256];
        CFStringRef text = path ? CFURLCopyFileSystemPath(path, kCFURLPOSIXPathStyle) : NULL;
        if (text) {
            if (!CFStringGetCString(text, file, sizeof file, kCFStringEncodingUTF8)) snprintf(file, sizeof file, "<conversion failed>");
            CFRelease(text);
        }
        fprintf(stderr, "[ShackSecurity] SecStaticCodeCreateWithPath flags=%u status=%d code=%p path=%s from %s\n",
                (unsigned)flags, (int)result, result == errSecSuccess && code ? *code : NULL, file,
                Caller(__builtin_return_address(0), caller, sizeof caller));
    }
    return result;
}

OSStatus SecStaticCodeCheckValidity(SecStaticCodeRef code, SecCSFlags flags, SecRequirementRef requirement) {
    typedef OSStatus (*Function)(SecStaticCodeRef, SecCSFlags, SecRequirementRef);
    void *handle = SystemSecurity();
    Function real = handle ? (Function)dlsym(handle, "SecStaticCodeCheckValidity") : NULL;
    OSStatus result = real ? real(code, flags, requirement) : errSecUnimplemented;
    const char *macSigning = getenv("SHACK_MAC_CODESIGN");
    // flags=1 checks every architecture. Do not weaken an explicit requirement or replace any other failure.
    if (result == -66996 && flags == 1 && !requirement && macSigning && strcmp(macSigning, "1") == 0) {
        OSStatus compatibility = ShackMacCodeTrustValidate((CFTypeRef)code, false);
        if (compatibility == errSecSuccess) result = errSecSuccess;
        fprintf(stderr, "[ShackSecurity] macOS Developer ID validation native=-66996 status=%d\n", (int)result);
    }
    if (TraceCode()) {
        char caller[256];
        fprintf(stderr, "[ShackSecurity] SecStaticCodeCheckValidity flags=%u status=%d code=%p requirement=%p from %s\n",
                (unsigned)flags, (int)result, code, requirement,
                Caller(__builtin_return_address(0), caller, sizeof caller));
        if (result != errSecSuccess) TraceFailure(handle, code);
    }
    return result;
}

OSStatus SecCodeCopySigningInformation(SecStaticCodeRef code, SecCSFlags flags, CFDictionaryRef *information) {
    typedef OSStatus (*Function)(SecStaticCodeRef, SecCSFlags, CFDictionaryRef *);
    void *handle = SystemSecurity();
    Function real = handle ? (Function)dlsym(handle, "SecCodeCopySigningInformation") : NULL;
    OSStatus result;
    if (real) result = real(code, flags, information);
    else { if (information) *information = NULL; result = errSecUnimplemented; }
    if (TraceCode()) {
        char team[256] = "<missing>", caller[256];
        CFDictionaryRef info = result == errSecSuccess && information ? *information : NULL;
        const CFStringRef *key = handle ? (const CFStringRef *)dlsym(handle, "kSecCodeInfoTeamIdentifier") : NULL;
        CFTypeRef value = info && key ? CFDictionaryGetValue(info, *key) : NULL;
        if (value && CFGetTypeID(value) == CFStringGetTypeID() &&
            !CFStringGetCString(value, team, sizeof team, kCFStringEncodingUTF8)) snprintf(team, sizeof team, "<conversion failed>");
        fprintf(stderr, "[ShackSecurity] SecCodeCopySigningInformation flags=%u status=%d code=%p information=%p team=%s from %s\n",
                (unsigned)flags, (int)result, code, info, team,
                Caller(__builtin_return_address(0), caller, sizeof caller));
    }
    return result;
}
