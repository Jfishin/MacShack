// Mac check of the game start MacShack and MacShack Play share (host/ShackGameLaunch.m): a game's .args.
//   clang -fobjc-arc -Ihost host/ShackGameLaunch.m host/probe/test_game_launch.m -framework Foundation \
//     -Wl,-undefined,dynamic_lookup -o /tmp/t && /tmp/t
// expect `game launch ok` (the rest of the file needs the iOS host; nothing here calls it).
#import "ShackGameLaunch.h"

static void check(BOOL ok, const char *what) {
    if (!ok) { fprintf(stderr, "FAIL: %s\n", what); exit(1); }
}

int main(void) {
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [fm createDirectoryAtPath:[dir stringByAppendingPathComponent:@"Unity.app/Contents/Resources/Data"] withIntermediateDirectories:YES attributes:nil error:NULL];
        [fm createDirectoryAtPath:[dir stringByAppendingPathComponent:@"Plain.app/Contents/MacOS"] withIntermediateDirectories:YES attributes:nil error:NULL];
        BOOL watch = YES; int jit = 0, trace = 0;
        // No .args yet: Unity's flags for a Unity game, written so the user can edit them; nothing for other games.
        NSString *unity = [dir stringByAppendingPathComponent:@"Unity.args"], *plain = [dir stringByAppendingPathComponent:@"Plain.args"];
        check([ShackGuestArgs(unity, &watch, &jit, &trace) isEqual:(@[@"-stdout", @"-FullStdOutLogOutput", @"-nosplash"])] && !watch && !jit && !trace, "Unity defaults");
        check([[NSString stringWithContentsOfFile:unity encoding:NSUTF8StringEncoding error:NULL] hasPrefix:@"-stdout\n"], "Unity defaults written");
        check([ShackGuestArgs(plain, &watch, &jit, &trace) isEqual:@[]], "no defaults for a non-Unity game");
        // MacShack's tokens are applied and stripped; spaces and blank lines go.
        [@"  --shack-watch\n-windowed \n\n--shack-jit-mb=256\n--shack-env=SHACK_TEST_ENV=a=b\n--shack-gputrace=5\n--shack-jit-mb=4\n"
            writeToFile:plain atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        check([ShackGuestArgs(plain, &watch, &jit, &trace) isEqual:@[@"-windowed"]], "tokens stripped");
        check(watch && trace == 5, "--shack-watch and --shack-gputrace=5");
        check(jit == 128, "a JIT size outside 16-1024 falls back to 128 (the last token wins)");
        check(!strcmp(getenv("SHACK_TEST_ENV") ?: "", "a=b"), "--shack-env sets the variable");
        [@"--shack-gputrace\n--shack-jit-mb=256\n" writeToFile:plain atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        check([ShackGuestArgs(plain, &watch, &jit, &trace) isEqual:@[]] && trace == -1 && jit == 256, "GPU traces on request, JIT size");
        // A launch from Steam carries Steam's arguments: used as they are, no .args file read or written.
        NSString *never = [dir stringByAppendingPathComponent:@"Never.args"];
        watch = YES; jit = 7; trace = 7;
        check([ShackLaunchArgs(@{@"args": @[@"-x", @"--shack-watch"], @"argsFile": never}, &watch, &jit, &trace) isEqual:(@[@"-x", @"--shack-watch"])] &&
              !watch && !jit && !trace && ![fm fileExistsAtPath:never], "Steam's arguments as they are");
        [@"-windowed\n" writeToFile:plain atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        check([ShackLaunchArgs(@{@"argsFile": plain}, &watch, &jit, &trace) isEqual:@[@"-windowed"]], "else the game's .args");
        [fm removeItemAtPath:dir error:NULL];
        puts("game launch ok");
    }
}
