#import "ShackSteamSetup.h"
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>

// libarchive ships in iOS and macOS (libarchive.tbd, -larchive) without headers in either SDK: the calls used here, as
// libarchive 3's archive.h and archive_entry.h declare them.
struct archive;
struct archive_entry;
struct archive *archive_read_new(void);
int archive_read_support_format_zip(struct archive *);
int archive_read_support_format_tar(struct archive *);
int archive_read_support_filter_gzip(struct archive *);
int archive_read_open_filename(struct archive *, const char *, size_t);
int archive_read_next_header(struct archive *, struct archive_entry **);
int archive_read_extract2(struct archive *, struct archive_entry *, struct archive *);
int archive_read_free(struct archive *);
struct archive *archive_write_disk_new(void);
int archive_write_disk_set_options(struct archive *, int);
int archive_write_free(struct archive *);
const char *archive_error_string(struct archive *);
const char *archive_entry_pathname(struct archive_entry *);
void archive_entry_copy_pathname(struct archive_entry *, const char *);
const char *archive_entry_symlink(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
void archive_entry_set_perm(struct archive_entry *, mode_t);
#define ARCHIVE_OK 0
#define ARCHIVE_EOF 1
#define ARCHIVE_WARN (-20)
#define ARCHIVE_EXTRACT_UNLINK 0x0010
#define ARCHIVE_EXTRACT_SECURE_SYMLINKS 0x0100
#define ARCHIVE_EXTRACT_SECURE_NODOTDOT 0x0200
#define AE_IFLNK 0120000
#define AE_IFDIR 0040000

// The entry's path as Valve means it (`\` separates too), or nil when it is absolute or has a `..` component.
static NSString *CleanPath(const char *raw) {
    NSString *path = [@(raw ?: "") stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    if (!path.length || [path hasPrefix:@"/"]) return nil;
    for (NSString *part in [path componentsSeparatedByString:@"/"])
        if ([part isEqualToString:@".."]) return nil;
    return path;
}

// A symlink's target, walked from the link's folder, never climbs above the root. The folders above a link are real
// (SECURE_SYMLINKS refuses writing through a link), so this walk is the real one.
// ponytail: lexical; a target that steps through another link to "." could still climb. Valve's sha256-checked
// packages have none; resolve with realpath after unpacking if untrusted archives ever come through here.
static BOOL InsideRoot(NSString *link, NSString *target) {
    if (!target.length || [target hasPrefix:@"/"]) return NO;
    NSInteger depth = (NSInteger)[link componentsSeparatedByString:@"/"].count - 1;
    for (NSString *part in [target componentsSeparatedByString:@"/"]) {
        if ([part isEqualToString:@".."]) { if (--depth < 0) return NO; }
        else if (part.length && ![part isEqualToString:@"."]) depth++;
    }
    return YES;
}

// Writes the entries of `in` under root: each at its own path, or at the path `keep` gives (nil skips it).
static NSString *Extract(struct archive *in, NSString *root, NSString *_Nullable (^_Nullable keep)(NSString *path)) {
    char real[PATH_MAX];
    if (!realpath(root.fileSystemRepresentation, real)) return [NSString stringWithFormat:@"%@: %s", root, strerror(errno)];
    NSString *base = @(real);   // no link above the tree (iOS's /var is one), else SECURE_SYMLINKS refuses every entry
    struct archive *out = archive_write_disk_new();
    archive_write_disk_set_options(out, ARCHIVE_EXTRACT_UNLINK | ARCHIVE_EXTRACT_SECURE_SYMLINKS | ARCHIVE_EXTRACT_SECURE_NODOTDOT);
    NSString *failure = nil;
    struct archive_entry *entry;
    int r;
    while ((r = archive_read_next_header(in, &entry)) == ARCHIVE_OK || r == ARCHIVE_WARN) {
        NSString *path = CleanPath(archive_entry_pathname(entry));
        if (!path) { failure = [NSString stringWithFormat:@"unsafe entry %s", archive_entry_pathname(entry) ?: "?"]; break; }
        if (keep) { path = keep(path); if (!path) continue; }
        mode_t type = archive_entry_filetype(entry);
        if (type == AE_IFLNK && !InsideRoot(path, @(archive_entry_symlink(entry) ?: ""))) {
            failure = [NSString stringWithFormat:@"symlink %@ points outside", path]; break;
        }
        archive_entry_set_perm(entry, 0755);   // Valve's folders carry no permission bits; files as on a Mac's Steam (0755)
        archive_entry_copy_pathname(entry, [base stringByAppendingPathComponent:path].fileSystemRepresentation);
        if ((r = archive_read_extract2(in, entry, out)) < ARCHIVE_WARN) {
            failure = [NSString stringWithFormat:@"%@: %s", path, archive_error_string(out) ?: archive_error_string(in) ?: "write failed"];
            break;
        }
    }
    if (!failure && r != ARCHIVE_EOF) failure = [NSString stringWithFormat:@"read: %s", archive_error_string(in) ?: "damaged archive"];
    if (archive_write_free(out) != ARCHIVE_OK && !failure) failure = @"could not finish writing the unpacked files";
    return failure;
}

// One archive file (formats: zip, or tar.gz) under dir, through Extract.
static NSString *Unpack(NSString *file, NSString *dir, BOOL tarGz, NSString *_Nullable (^_Nullable keep)(NSString *path)) {
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    struct archive *in = archive_read_new();
    if (tarGz) { archive_read_support_filter_gzip(in); archive_read_support_format_tar(in); }
    else archive_read_support_format_zip(in);
    NSString *failure = archive_read_open_filename(in, file.fileSystemRepresentation, 1 << 16) == ARCHIVE_OK ? Extract(in, dir, keep) :
        [NSString stringWithFormat:@"%@: %s", file.lastPathComponent, archive_error_string(in) ?: "cannot open"];
    archive_read_free(in);
    return failure;
}

NSString *ShackSteamUnzip(NSString *zip, NSString *dir) { return Unpack(zip, dir, NO, nil); }

NSString *ShackSteamUnpackSkeleton(NSString *tarGz, NSString *contents) {
    NSSet *wanted = [NSSet setWithArray:@[@"Info.plist", @"embedded.provisionprofile", @"Resources/Assets.car", @"Resources/Steam.icns"]];
    NSString *prefix = @"Steam.app/Contents/";
    NSString *failure = Unpack(tarGz, contents, YES, ^NSString *(NSString *path) {
        NSString *inside = [path hasPrefix:prefix] ? [path substringFromIndex:prefix.length] : nil;
        return inside && [wanted containsObject:inside] ? inside : nil;
    });
    if (failure) return failure;
    for (NSString *name in [[wanted allObjects] sortedArrayUsingSelector:@selector(compare:)]) {
        if (![NSFileManager.defaultManager fileExistsAtPath:[contents stringByAppendingPathComponent:name]]) {
            return [NSString stringWithFormat:@"SteamMacBootstrapper.tar.gz has no %@", name];
        }
    }
    return nil;
}
