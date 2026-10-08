#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface ShackSigner : NSObject
+ (BOOL)importCertificateData:(NSData *)data password:(NSString *)password error:(NSError **)error
    NS_SWIFT_NAME(importCertificate(data:password:));
/// Validates the saved identity against the current profile, without exposing secrets.
+ (nullable NSDictionary *)signingContextWithError:(NSError **)error;
/// Sign a private work copy and publish to a new inode. Output must not exist.
+ (BOOL)signBinaryAtPath:(NSString *)inputPath outputPath:(NSString *)outputPath error:(NSError **)error;
/// The same with another code-signing identifier: MacShack Play signs with its own identifier.
+ (BOOL)signBinaryAtPath:(NSString *)inputPath outputPath:(NSString *)outputPath identifier:(NSString *)identifier error:(NSError **)error;
+ (nullable NSString *)runProbeWithError:(NSError **)error NS_SWIFT_NAME(runProbe());
@end
NS_ASSUME_NONNULL_END
