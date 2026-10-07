#import "../ShackPrep.h"
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc == 3 && !strcmp(argv[1], "--inspect")) {
            NSString *path = @(argv[2]); NSError *error = nil;
            BOOL arm = [ShackPrep hasArm64AtPath:path error:&error];
            NSDictionary *result = @{@"macho": @([ShackPrep isMachOAtPath:path]), @"arm64": @(arm),
                                     @"monoRevision": [ShackPrep monoRevisionAtPath:path] ?: @"",
                                     @"error": error.localizedDescription ?: @""};
            NSData *json = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
            fwrite(json.bytes, 1, json.length, stdout); return 0;
        }
        if (argc != 5) { fprintf(stderr, "usage: shackprep_cli input output executable-directory main(0|1)\n"); return 2; }
        NSError *error = nil;
        BOOL ok = [ShackPrep prepareBinaryAtPath:@(argv[1]) outputPath:@(argv[2]) executableDirectory:@(argv[3])
                                mainExecutable:atoi(argv[4]) != 0 error:&error];
        if (!ok) fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
        return ok ? 0 : 1;
    }
}
