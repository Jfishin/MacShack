// macOS-only Security calls (keychain files, trust settings, import/export). Re-exports Security.
// ponytail: there is no macOS keychain here; each call reports "unimplemented" or "none", so Mono/Unity/Galaxy
// fall back to their bundled roots. Implement for real if TLS certificate validation shows up broken.
#import <Security/Security.h>

const CFStringRef kSecUseKeychain = CFSTR("u_KeychainRef");   // Firebase Analytics plugin (Coromon); no keychain files here
const CFStringRef kSecOIDX509V1IssuerName = CFSTR("2.16.840.1.113741.2.1.1.1.5");
const CFStringRef kSecOIDX509V1SubjectName = CFSTR("2.16.840.1.113741.2.1.1.1.8");

static OSStatus Unimplemented(void **out) { if (out) *out = NULL; return errSecUnimplemented; }

OSStatus SecKeychainOpen(const char *path, void **keychain) { return Unimplemented(keychain); }
OSStatus SecKeychainSearchCreateFromAttributes(CFTypeRef keychains, uint32_t itemClass, const void *attrs, void **search) { return Unimplemented(search); }
OSStatus SecKeychainSearchCopyNext(void *search, void **item) { if (item) *item = NULL; return errSecItemNotFound; }
OSStatus SecKeychainItemCopyContent(void *item, uint32_t *itemClass, void *attrs, uint32_t *length, void **data) {
    if (length) *length = 0;
    return Unimplemented(data);
}
OSStatus SecKeychainItemFreeContent(void *attrs, void *data) { return errSecSuccess; }   // nothing we handed out
// macOS answers "no trust settings" for an empty domain, which callers treat as "none", not as a failure.
OSStatus SecTrustCopyAnchorCertificates(CFArrayRef *anchors) { return Unimplemented((void **)anchors); }   // Godot 4 → bundled roots
OSStatus SecTrustSettingsCopyCertificates(uint32_t domain, CFArrayRef *certs) { if (certs) *certs = NULL; return errSecNoTrustSettings; }
OSStatus SecTrustSettingsCopyTrustSettings(SecCertificateRef cert, uint32_t domain, CFArrayRef *settings) {
    if (settings) *settings = NULL;
    return errSecItemNotFound;
}
CFDictionaryRef SecCertificateCopyValues(SecCertificateRef cert, CFArrayRef keys, CFErrorRef *error) { if (error) *error = NULL; return NULL; }
OSStatus SecCertificateGetData(SecCertificateRef cert, void *cssmData) { return errSecUnimplemented; }
CFStringRef SecCertificateCopyLongDescription(CFAllocatorRef a, SecCertificateRef cert, CFErrorRef *error) {
    if (error) *error = NULL;
    return cert ? SecCertificateCopySubjectSummary(cert) : NULL;
}
OSStatus SecIdentityCreateWithCertificate(CFTypeRef keychains, SecCertificateRef cert, SecIdentityRef *identity) { return Unimplemented((void **)identity); }
OSStatus SecItemImport(CFDataRef data, CFStringRef ext, void *format, void *type, uint32_t flags, const void *params, void *keychain, CFArrayRef *items) {
    return Unimplemented((void **)items);
}
OSStatus SecItemExport(CFTypeRef items, uint32_t format, uint32_t flags, const void *params, CFDataRef *data) { return Unimplemented((void **)data); }
