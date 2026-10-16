// Mac check for the case-insensitive path fallback in host/ShackHooks.m (the block from "Case-insensitive fallback"
// to "Unity dlopens Mono"), on a case-sensitive APFS image like the phone's volume:
// awk '/^\/\/ Case-insensitive fallback for the guest/{on=1} /^\/\/ Unity dlopens Mono/{on=0} on' host/ShackHooks.m > /tmp/resolve.inc \
//   && clang -O2 -fobjc-arc -I/tmp host/probe/test_case_paths.m -framework Foundation -o /tmp/t && /tmp/t
// -O2 as the apps' Release builds: a root pointing into a dead block's array passed at -O0 and failed there.
#import <Foundation/Foundation.h>
#include <stdarg.h>
// ShackHooks.m's second guest (a game Steam started); only its root is read by this block.
static struct { char root[PATH_MAX]; } gSecond;
#include "resolve.inc"
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL %d: %s (errno %d)\n", __LINE__, #x, errno); return 1; } } while (0)

// iOS's sandbox answers a path in another app's container (MacShack's, read from MacShack Play) with EPERM, not
// ENOENT; this Mac has no such paths, so open says so for them.
static int sandboxed_open(const char *p, int f, ...) {
    va_list ap; va_start(ap, f); int m = (f & O_CREAT) ? va_arg(ap, int) : 0; va_end(ap);
    if (!strncmp(p, "/var/mobile/Containers/Data/Application/", 40) || !strncmp(p, "/denied/", 8)) { errno = EPERM; return -1; }
    return open(p, f, m);
}

static int sandboxed_rename(const char *a, const char *b) {
    if (!strncmp(a, "/var/mobile/Containers/Data/Application/", 40) || !strncmp(b, "/var/mobile/Containers/Data/Application/", 40)) { errno = EPERM; return -1; }
    return rename(a, b);
}

static int run(const char *vol) {
    o_open = open; o_stat = stat; o_lstat = lstat; o_access = access; o_opendir = opendir; o_fopen = fopen;
    o_mkdir = mkdir; o_unlink = unlink; o_rmdir = rmdir; o_remove = remove; o_rename = rename;
    snprintf(gHome, sizeof gHome, "%s/Home", vol); realpath(vol, gHomeReal); strlcat(gHomeReal, "/Home", sizeof gHomeReal);
    snprintf(gGuestRoot, sizeof gGuestRoot, "%s/Documents/Games/X.app", gHomeReal);
    char p[PATH_MAX], lower[PATH_MAX], cmd[3 * PATH_MAX], real[PATH_MAX]; struct stat st;
    snprintf(real, sizeof real, "%s/Library/Application Support/Pearl Abyss/CD/save/1/slot0", gHome);
    snprintf(cmd, sizeof cmd, "mkdir -p '%s' && echo hi > '%s/save.save'", real, real); CHECK(system(cmd) == 0);
    snprintf(lower, sizeof lower, "%s", gHome); for (char *c = lower; *c; c++) *c = tolower(*c);
    // An existing save through a wholly lowercased path (Crimson Desert: /var/mobile/containers/.../library/...)
    snprintf(p, sizeof p, "%s/library/application support/pearl abyss/cd/save/1/slot0/save.save", lower);
    CHECK(o_open(p, O_RDONLY) < 0 && errno == ENOENT);   // native: missing on a case-sensitive volume
    int fd = ci_open(p, O_RDONLY); CHECK(fd >= 0); close(fd);
    FILE *f = ci_fopen(p, "r"); CHECK(f); fclose(f);
    CHECK(ci_stat(p, &st) == 0 && ci_access(p, R_OK) == 0);
    // A new save: slot directory, temp file renamed over the save, then removed again
    snprintf(p, sizeof p, "%s/library/application support/pearl abyss/cd/save/1/slot3", lower);
    CHECK(ci_mkdir(p, 0755) == 0);
    char tmp[PATH_MAX], dst[PATH_MAX], made[PATH_MAX];
    snprintf(made, sizeof made, "%s/Library/Application Support/Pearl Abyss/CD/save/1/slot3/save.save", gHome);
    snprintf(tmp, sizeof tmp, "%s/save.tmp", p); snprintf(dst, sizeof dst, "%s/save.save", p);
    f = ci_fopen(tmp, "w"); CHECK(f); fputs("new", f); fclose(f);
    fd = ci_open(dst, O_WRONLY | O_CREAT | O_TRUNC, 0644); CHECK(fd >= 0); close(fd);
    CHECK(ci_rename(tmp, dst) == 0 && stat(made, &st) == 0 && st.st_size == 3);
    CHECK(ci_remove(dst) == 0 && stat(made, &st) != 0);
    CHECK(ci_rmdir(p) == 0);
    // Misses stay misses: a missing middle directory, a path outside the container, a missing file
    snprintf(p, sizeof p, "%s/library/nosuchdir/file", lower);
    CHECK(ci_open(p, O_WRONLY | O_CREAT, 0644) < 0 && errno == ENOENT);
    CHECK(ci_unlink("/tmp/macshack-no-such-dir/x") < 0 && errno == ENOENT);
    snprintf(p, sizeof p, "%s/library/application support/pearl abyss/cd/save/1/slot0/missing.save", lower);
    CHECK(ci_open(p, O_RDONLY) < 0 && errno == ENOENT && ci_unlink(p) < 0 && errno == ENOENT);
    // A game outside the container (the App Group's Steam library) whose root realpath spells /private/..., asked for
    // under the spelling NSString gives (no /private), lowercased inside the bundle.
    char group[PATH_MAX];
    snprintf(group, sizeof group, "%s/Group/Steam/steamapps/common/Game.app/Contents/Resources", vol);
    snprintf(cmd, sizeof cmd, "mkdir -p '%s' && echo hi > '%s/Shaders.metallib'", group, group); CHECK(system(cmd) == 0);
    snprintf(cmd, sizeof cmd, "%s/Group/Steam/steamapps/common/Game.app", vol); CHECK(realpath(cmd, gSecond.root));
    CHECK(!strncmp(gSecond.root, "/private/", 9));
    snprintf(p, sizeof p, "%s/contents/resources/shaders.metallib", gSecond.root + 8);
    fd = ci_open(p, O_RDONLY); CHECK(fd >= 0); close(fd);
    // Another app's container (MacShack's Steam folder, as Play is told it): the same place under this app's home.
    o_open = sandboxed_open;
    snprintf(p, sizeof p, "/var/mobile/Containers/Data/Application/0F0F0F0F-0F0F-0F0F-0F0F-0F0F0F0F0F0F/Library/Application Support/Pearl Abyss/CD/save/1/slot0/save.save");
    fd = ci_open(p, O_RDONLY); CHECK(fd >= 0); close(fd);
    // A "not permitted" outside any app container is not retried and stays one.
    CHECK(ci_open("/denied/x", O_RDONLY) < 0 && errno == EPERM);
    o_open = open;
    // Steam's own files written through another app's container spelling: a temp file renamed over its target.
    o_rename = sandboxed_rename;
    snprintf(cmd, sizeof cmd, "echo t > '%s/Library/Application Support/Pearl Abyss/CD/save/1/slot0/steam.tmp'", gHome); CHECK(system(cmd) == 0);
    char from[PATH_MAX], to[PATH_MAX];
    snprintf(from, sizeof from, "/var/mobile/Containers/Data/Application/0F0F0F0F-0F0F-0F0F-0F0F-0F0F0F0F0F0F/Library/Application Support/Pearl Abyss/CD/save/1/slot0/steam.tmp");
    snprintf(to, sizeof to, "/var/mobile/Containers/Data/Application/0F0F0F0F-0F0F-0F0F-0F0F-0F0F0F0F0F0F/Library/Application Support/Pearl Abyss/CD/save/1/slot0/steam.cfg");
    CHECK(ci_rename(from, to) == 0);
    snprintf(made, sizeof made, "%s/Library/Application Support/Pearl Abyss/CD/save/1/slot0/steam.cfg", gHome); CHECK(stat(made, &st) == 0);
    o_rename = rename;
    // MacShack Play: the game's .app in the App Group's Games, its data beside it (Batman's BMAAData/BmGame, asked for
    // as BMGame) outside the home: the folder holding the .app is the game's too.
    char rv[PATH_MAX]; realpath(vol, rv);
    snprintf(gGuestRoot, sizeof gGuestRoot, "%s/Group/Games/Batman.app", rv);
    snprintf(cmd, sizeof cmd, "mkdir -p '%s/Group/Games/Batman.app' '%s/Group/Games/BMAAData/BmGame/Splash/PC' && echo b > '%s/Group/Games/BMAAData/BmGame/Splash/PC/Splash.bmp'", vol, vol, vol);
    CHECK(system(cmd) == 0);
    snprintf(p, sizeof p, "%s/Group/Games/BMAAData/BMGame/Splash/PC/Splash.bmp", vol);
    CHECK(ci_stat(p, &st) == 0);
    return 0;
}

int main(void) {
    char dir[] = "/tmp/case-paths-XXXXXX"; if (!mkdtemp(dir)) return 1;
    char cmd[512];
    snprintf(cmd, sizeof cmd, "hdiutil create -quiet -size 20m -fs 'Case-sensitive APFS' -volname CaseTest %s/cs.dmg"
                              " && hdiutil attach -quiet -nobrowse -mountpoint %s/vol %s/cs.dmg", dir, dir, dir);
    if (system(cmd)) { fprintf(stderr, "FAIL: case-sensitive image\n"); return 1; }
    snprintf(cmd, sizeof cmd, "%s/vol", dir);
    int r = run(cmd);
    snprintf(cmd, sizeof cmd, "hdiutil detach -quiet %s/vol; rm -rf %s", dir, dir); system(cmd);
    if (!r) puts("case paths ok");
    return r;
}
