#import "ShackSigner.h"
#import <Security/Security.h>
#import <dlfcn.h>
#import <CommonCrypto/CommonDigest.h>
#include "common.h"
#include "macho.h"
#include <openssl/pkcs12.h>
#include <openssl/x509.h>
#include <openssl/provider.h>
#include <openssl/err.h>

static id Fail(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"ShackSigner" code:1
                                       userInfo:@{NSLocalizedDescriptionKey: message}];
    return nil;
}

// Read at load: once a game runs, the identity hooks make mainBundle answer for the game, and a download that
// finishes after play would be signed from the game's bundle ("no embedded development profile").
static NSBundle *gHostBundle;
__attribute__((constructor)) static void captureHostBundle(void) { gHostBundle = NSBundle.mainBundle; }

static NSDictionary *Profile(NSError **error) {
    NSURL *url = [gHostBundle URLForResource:@"embedded" withExtension:@"mobileprovision"];
    NSData *data = url ? [NSData dataWithContentsOfURL:url options:0 error:error] : nil;
    if (!data) return Fail(error, @"MacShack has no embedded development profile.");
    string xml;
    if (!ZSignAsset::GetCMSContent(string((const char *)data.bytes, data.length), xml))
        return Fail(error, @"Cannot decode MacShack's installed profile.");
    id profile = [NSPropertyListSerialization propertyListWithData:[NSData dataWithBytes:xml.data() length:xml.size()]
                                                         options:NSPropertyListImmutable format:nil error:error];
    if (![profile isKindOfClass:NSDictionary.class]) return Fail(error, @"Invalid development profile.");
    NSDate *expiry = profile[@"ExpirationDate"];
    NSDictionary *ent = profile[@"Entitlements"];
    NSString *team = [profile[@"TeamIdentifier"] firstObject];
    NSString *expected = [NSString stringWithFormat:@"%@.%@", team, gHostBundle.bundleIdentifier];
    if (![expiry isKindOfClass:NSDate.class] || expiry.timeIntervalSinceNow <= 0)
        return Fail(error, @"MacShack's profile expired. Refresh MacShack before signing libraries.");
    if (![ent[@"get-task-allow"] boolValue] || ![ent[@"application-identifier"] isEqual:expected])
        return Fail(error, @"Signing requires a development profile for MacShack's exact bundle identifier.");
    return profile;
}

static BOOL ValidateIdentity(NSData *data, NSString *password, NSDictionary *profile, NSError **error) {
    if (!data.length || data.length > 1024 * 1024 ||
        strlen(password.UTF8String) != [password lengthOfBytesUsingEncoding:NSUTF8StringEncoding])
        return Fail(error, @"Invalid certificate file or password.") != nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        OSSL_PROVIDER_load(NULL, "default");
        OSSL_PROVIDER_load(NULL, "legacy");
        ZLog::SetLogLever(ZLog::E_ERROR);
    });
    const unsigned char *cursor = (const unsigned char *)data.bytes;
    PKCS12 *p12 = d2i_PKCS12(NULL, &cursor, (long)data.length);
    EVP_PKEY *key = NULL;
    X509 *cert = NULL;
    STACK_OF(X509) *chain = NULL;
    BOOL valid = p12 && cursor == (const unsigned char *)data.bytes + data.length &&
        PKCS12_parse(p12, password.UTF8String, &key, &cert, &chain) == 1;
    NSString *message = @"Cannot open the .p12. Check its password and that it contains a private key.";
    if (valid) {
        valid = X509_check_private_key(cert, key) == 1 && X509_cmp_current_time(X509_get0_notBefore(cert)) < 0 &&
            X509_cmp_current_time(X509_get0_notAfter(cert)) > 0;
        message = @"The signing certificate is expired, not yet valid, or does not match its private key.";
    }
    if (valid) {
        valid = NO;
        for (NSData *allowed in profile[@"DeveloperCertificates"]) {
            if (![allowed isKindOfClass:NSData.class]) continue;
            const unsigned char *bytes = (const unsigned char *)allowed.bytes;
            X509 *candidate = d2i_X509(NULL, &bytes, (long)allowed.length);
            BOOL matches = candidate && X509_cmp(candidate, cert) == 0;
            X509_free(candidate);
            if (matches) { valid = YES; break; }
        }
        message = @"This certificate is not authorized by MacShack's installed profile. Import its development identity.";
    }
    sk_X509_pop_free(chain, X509_free);
    X509_free(cert);
    EVP_PKEY_free(key);
    PKCS12_free(p12);
    ERR_clear_error();
    if (!valid) Fail(error, message);
    return valid;
}

static NSDictionary *KeychainQuery(void) {
    return @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
             (__bridge id)kSecAttrService: @"com.macshack.signing",
             (__bridge id)kSecAttrAccount: @"development-identity"};
}

static NSDictionary *ReadIdentity(NSDictionary *profile, NSError **error) {
    NSMutableDictionary *query = [KeychainQuery() mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess)
        return Fail(error, status == errSecItemNotFound ? @"Import MacShack's development .p12 first." :
            [NSString stringWithFormat:@"Cannot read signing identity (%d). Unlock the device and retry.", (int)status]);
    NSData *stored = CFBridgingRelease(result);
    NSDictionary *identity = [NSPropertyListSerialization propertyListWithData:stored options:0 format:nil error:error];
    NSData *p12 = identity[@"p12"];
    NSString *password = identity[@"password"];
    if (![p12 isKindOfClass:NSData.class] || ![password isKindOfClass:NSString.class])
        return Fail(error, @"Invalid saved identity; import the certificate again.");
    if (!ValidateIdentity(p12, password, profile, error)) return nil;
    return identity;
}

@implementation ShackSigner
+ (BOOL)importCertificateData:(NSData *)data password:(NSString *)password error:(NSError **)error {
    @synchronized(self) {
        NSDictionary *profile = Profile(error);
        if (!profile || !ValidateIdentity(data, password, profile, error)) return NO;
        NSData *stored = [NSPropertyListSerialization dataWithPropertyList:@{@"p12": data, @"password": password}
                                                                    format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
        if (!stored) return NO;
        NSDictionary *values = @{(__bridge id)kSecValueData: stored,
                                 (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly};
        OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)KeychainQuery(), (__bridge CFDictionaryRef)values);
        if (status == errSecItemNotFound) {
            NSMutableDictionary *item = [KeychainQuery() mutableCopy];
            [item addEntriesFromDictionary:values];
            status = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
        }
        if (status != errSecSuccess) {
            Fail(error, [NSString stringWithFormat:@"Keychain import failed (%d).", (int)status]);
            return NO;
        }
        return YES;
    }
}


+ (NSDictionary *)signingContextWithError:(NSError **)error {
    @synchronized(self) {
        NSDictionary *profile = Profile(error);
        if (!profile || !ReadIdentity(profile, error)) return nil;
        NSData *data = [NSData dataWithContentsOfURL:[gHostBundle URLForResource:@"embedded" withExtension:@"mobileprovision"]];
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
        NSMutableString *hash = [NSMutableString string];
        for (NSUInteger i = 0; i < sizeof digest; i++) [hash appendFormat:@"%02x", digest[i]];
        return @{@"identifier": gHostBundle.bundleIdentifier,
                 @"profileExpiration": profile[@"ExpirationDate"], @"profileHash": hash};
    }
}

+ (BOOL)signBinaryAtPath:(NSString *)inputPath outputPath:(NSString *)outputPath error:(NSError **)error {
    return [self signBinaryAtPath:inputPath outputPath:outputPath identifier:gHostBundle.bundleIdentifier error:error];
}

+ (BOOL)signBinaryAtPath:(NSString *)inputPath outputPath:(NSString *)outputPath identifier:(NSString *)identifier error:(NSError **)error {
    @synchronized(self) {
        NSDictionary *profile = Profile(error);
        NSDictionary *identity = profile ? ReadIdentity(profile, error) : nil;
        if (!identity) return NO;
        NSFileManager *fm = NSFileManager.defaultManager;
        if ([fm fileExistsAtPath:outputPath]) {
            Fail(error, @"Signing output already exists; a fresh destination is required.");
            return NO;
        }
        NSURL *work = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
        if (![fm createDirectoryAtURL:work withIntermediateDirectories:NO
                           attributes:@{NSFileProtectionKey: NSFileProtectionComplete} error:error]) return NO;
        NSURL *keyFile = [work URLByAppendingPathComponent:@"identity.p12"];
        NSURL *binary = [work URLByAppendingPathComponent:@"unsigned.dylib"];
        BOOL ok = NO;
        @try {
            if (![identity[@"p12"] writeToURL:keyFile options:NSDataWritingFileProtectionComplete error:error] ||
                ![fm copyItemAtPath:inputPath toPath:binary.path error:error]) return NO;
            // Finish and unmap ZSign's in-place writes before publishing a fresh inode.
            {
                ZSignAsset asset;
                NSURL *provision = [gHostBundle URLForResource:@"embedded" withExtension:@"mobileprovision"];
                if (!asset.Init("", keyFile.fileSystemRepresentation, provision.fileSystemRepresentation, "",
                                [identity[@"password"] UTF8String], false, true, true)) {
                    Fail(error, @"Could not initialize the on-device signer."); return NO;
                }
                ZMachO macho;
                if (!macho.Init(binary.fileSystemRepresentation) ||
                    !macho.Sign(&asset, true, identifier.UTF8String, "", "", "")) {
                    Fail(error, @"On-device Mach-O signing failed."); return NO;
                }
            }
            ok = [fm copyItemAtPath:binary.path toPath:outputPath error:error];
        } @finally {
            NSError *cleanup = nil;
            if (![fm removeItemAtURL:work error:&cleanup]) {
                if (ok) [fm removeItemAtPath:outputPath error:nil];
                ok = NO;
                Fail(error, @"Could not remove temporary signing files.");
            }
        }
        return ok;
    }
}

+ (NSString *)runProbeWithError:(NSError **)error {
    @synchronized(self) {
        NSDictionary *profile = Profile(error);
        if (!profile) return nil;
        NSURL *fixture = [gHostBundle URLForResource:@"signing-fixture" withExtension:@"dylib"];
        NSMutableData *bytes = fixture ? [NSMutableData dataWithContentsOfURL:fixture options:0 error:error] : nil;
        if (!bytes) return Fail(error, @"Signing fixture is missing from this build.");
        const uint32_t marker = 0x13572468, replacement = 42;
        NSData *needle = [NSData dataWithBytes:&marker length:sizeof marker];
        NSRange match = [bytes rangeOfData:needle options:0 range:NSMakeRange(0, bytes.length)];
        if (match.location == NSNotFound || [bytes rangeOfData:needle options:0
            range:NSMakeRange(NSMaxRange(match), bytes.length - NSMaxRange(match))].location != NSNotFound)
            return Fail(error, @"Signing fixture must contain exactly one test value.");
        [bytes replaceBytesInRange:match withBytes:&replacement];
        NSFileManager *fm = NSFileManager.defaultManager;
        NSURL *root = [[fm URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask][0]
                       URLByAppendingPathComponent:@"SigningProof" isDirectory:YES];
        if (![fm createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:error]) return nil;
        if (![root setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:error]) return nil;
        NSURL *work = [root URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
        if (![fm createDirectoryAtURL:work withIntermediateDirectories:NO
                           attributes:@{NSFileProtectionKey: NSFileProtectionComplete} error:error]) return nil;
        NSURL *output = [work URLByAppendingPathComponent:@"probe.dylib"];
        NSURL *published = [work URLByAppendingPathComponent:@"published.dylib"];
        if (![bytes writeToURL:output options:NSDataWritingFileProtectionComplete error:error] ||
            ![self signBinaryAtPath:output.path outputPath:published.path error:error]) return nil;
        dlerror();
        void *handle = dlopen(published.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
        if (!handle) {
            const char *reason = dlerror();
            return Fail(error, [NSString stringWithFormat:@"Signed on device, but dlopen refused it: %s", reason ?: "unknown error"]);
        }
        int (*probe)(void) = (int (*)(void))dlsym(handle, "shack_probe");
        if (!probe) return Fail(error, @"Signed library loaded but its test symbol is missing.");
        int value = probe();
        if (value != 42) return Fail(error, [NSString stringWithFormat:@"Loaded library returned %d instead of 42.", value]);
        NSString *report = [NSString stringWithFormat:@"PASS %@\nChanged test value: 0x13572468 -> 42\nSigned on device with identifier: %@\nLoaded: %@\nshack_probe() = %d\n",
                            NSDate.date, gHostBundle.bundleIdentifier, published.path, value];
        NSURL *docs = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask][0];
        NSURL *logs = [docs URLByAppendingPathComponent:@"Logs" isDirectory:YES];
        if (![fm createDirectoryAtURL:logs withIntermediateDirectories:YES attributes:nil error:error] ||
            ![report writeToURL:[logs URLByAppendingPathComponent:@"on-device-signing.log"]
                    atomically:YES encoding:NSUTF8StringEncoding error:error]) return nil;
        return report;
    }
}
@end
