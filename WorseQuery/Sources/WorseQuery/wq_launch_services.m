//
//  wq_launch_services.m
//  Drift / WorseQuery
//
//  iOS 26.1 CSStore container resolver, adapted from LaunchShield's
//  WQLaunchServices parser. The parser keeps String and Alias tables separate;
//  this is required for the overlapping IDs in the verified 26.1 layout.
//  GPL-3.0-or-later.
//
#import "wq_launch_services.h"
#import "worse_query.h"
#import <dispatch/dispatch.h>
#import <fcntl.h>
#import <stdlib.h>
#import <string.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <sys/fsgetpath.h>
#import <unistd.h>
#import <errno.h>

extern ssize_t fsgetpath(char *buf, size_t buflen, fsid_t *fsid, uint64_t objid);

static const size_t kWQLSMinStoreBytes = 0x1000;
static const size_t kWQLSMaxStoreBytes = 64u * 1024u * 1024u;
static const uint32_t kWQLSMaxStringID = 0x01000000u;
static const NSUInteger kWQLSMaxBundleRecords = 100000;
static const NSUInteger kWQLSMaxDecodedStrings = 200000;
static const NSUInteger kWQLSMaxDecodedStringBytes = 8u * 1024u * 1024u;

// Record layouts by release. Offsets are from the record body (after the
// 8-byte header). The 26.1 layout is measured against the supplied 16,220,160-byte
// device sample; its String and Alias tables are decoded independently.
typedef struct {
    const char *label;
    uint32_t bundleSize, bundleID, container, name, displayName, bundlePath;
    uint32_t pluginSize, pluginBundleID, pluginContainer;
} WQLSLayout;
static const WQLSLayout kWQLSLayouts[] = {
    { "27.0", 0x250, 0x0c, 0x68, 0x6c, 0x74, 0x00, 0x118, 0x00, 0x54 },
    // iOS 26.1: Bundle 0x238 / Plugin 0xec. Both records reference the
    // Alias table for container paths at +0x60; String refs remain separate.
    { "26.1", 0x238, 0x0c, 0x60, 0x64, 0x6c, 0x00, 0x0ec, 0x0c, 0x60 },
    { "26",   0x23c, 0x0c, 0x64, 0x68, 0x70, 0x00, 0x104, 0x00, 0x50 },
    // iOS 27.2 (from a device's layout hint): container fields 4 bytes later
    // than on 27.0. Whether the bundle id moved too isn't known yet, so both
    // positions are tried; the one that maps the most containers wins.
    { "27.2", 0x25c, 0x0c, 0x6c, 0x70, 0x78, 0x00, 0x120, 0x00, 0x58 },
    { "27.2b", 0x25c, 0x10, 0x6c, 0x70, 0x78, 0x00, 0x120, 0x04, 0x58 },
    { "27.2c", 0x25c, 0x0c, 0x6c, 0x70, 0x78, 0x00, 0x120, 0x04, 0x58 },
    { "27.2d", 0x25c, 0x10, 0x6c, 0x70, 0x78, 0x00, 0x120, 0x00, 0x58 },
};
static const size_t kWQLSLayoutCount = sizeof(kWQLSLayouts) / sizeof(kWQLSLayouts[0]);
static const size_t kWQLSMaxRecordSize = 0x25c;

static uint32_t wq_rd32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }

static NSString *wq_cs_string(const uint8_t *b, size_t n, size_t o)
{
    if (o > n || n - o < 8) return nil;
    uint32_t len = wq_rd32(b + o + 4);
    // Strings are padded with zero bytes to a multiple of 4. One whose length
    // is already a multiple of 4 has no terminator (container paths are 84 or
    // 88 bytes), so only shorter ones must end in a zero byte. A string must
    // still end before the buffer does.
    if (len == 0 || len >= 0x800 || len >= n - o - 8 || (len % 4 && b[o + 8 + len] != 0)) return nil;
    if (memchr(b + o + 8, 0, len)) return nil;
    NSString *s = [[NSString alloc] initWithBytes:b + o + 8 length:len encoding:NSUTF8StringEncoding];
    return s;
}

static BOOL wq_looks_like_bundle_id(NSString *s)
{
    static NSCharacterSet *bad;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bad = [[NSCharacterSet characterSetWithCharactersInString:
                @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"] invertedSet];
    });
    return s.length > 2 && [s containsString:@"."] && ![s hasPrefix:@"."]
        && [s rangeOfCharacterFromSet:bad].location == NSNotFound;
}

// Unicode format characters include bidi overrides/isolates, zero-width
// characters, and BOM-like markers. They are replaced visibly while ordinary
// international letters, accents, and scripts remain unchanged.
static BOOL wq_is_name_format_scalar(uint32_t c)
{
    return c == 0x00ad || (c >= 0x0600 && c <= 0x0605) || c == 0x061c || c == 0x06dd ||
        c == 0x070f || (c >= 0x0890 && c <= 0x0891) || c == 0x08e2 || c == 0x180e ||
        (c >= 0x200b && c <= 0x200f) || (c >= 0x202a && c <= 0x202e) ||
        (c >= 0x2060 && c <= 0x206f) || c == 0xfeff;
}

static NSString *wq_safe_name(NSString *value)
{
    if (!value.length) return nil;
    NSMutableString *safe = [NSMutableString stringWithCapacity:value.length];
    for (NSUInteger i = 0; i < value.length;) {
        uint32_t scalar = [value characterAtIndex:i++];
        if (scalar >= 0xd800 && scalar <= 0xdbff) {
            if (i >= value.length) return nil;
            unichar low = [value characterAtIndex:i++];
            if (low < 0xdc00 || low > 0xdfff) return nil;
            scalar = 0x10000u + ((scalar - 0xd800u) << 10) + (low - 0xdc00u);
        } else if (scalar >= 0xdc00 && scalar <= 0xdfff) {
            return nil;
        }

        if (wq_is_name_format_scalar(scalar) || scalar == 0x2028 || scalar == 0x2029) {
            [safe appendString:@"\uFFFD"];
        } else if (scalar <= 0xffff) {
            [safe appendFormat:@"%C", (unichar)scalar];
        } else {
            scalar -= 0x10000u;
            [safe appendFormat:@"%C%C", (unichar)(0xd800u + (scalar >> 10)),
             (unichar)(0xdc00u + (scalar & 0x3ffu))];
        }
    }

    NSString *normalized = [safe precomposedStringWithCanonicalMapping];
    normalized = [normalized stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!normalized.length || [normalized hasPrefix:@"/"] || [normalized containsString:@".app/"]) return nil;
    if ([normalized rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return nil;
    return normalized;
}

// Data container path -> bundle id. Field offsets are supplied by the
// selected release layout. On systems where container metadata cannot provide
// an identifier, this maps the database's path reference back to its bundle id.
static BOOL wq_is_data_container_path(NSString *path)
{
    static NSArray<NSString *> *prefixes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        prefixes = @[@"/private/var/mobile/Containers/Data/Application/",
                     @"/private/var/mobile/Containers/Data/PluginKitPlugin/"];
    });
    for (NSString *prefix in prefixes) {
        if (![path hasPrefix:prefix] || path.length != prefix.length + 36) continue;
        return [[NSUUID alloc] initWithUUIDString:[path substringFromIndex:prefix.length]] != nil;
    }
    return NO;
}

// Diagnostics: how many container paths the store holds, and which record
// sizes and offsets refer to them. Only sizes and offsets are logged (no
// names), so a Log from a release with a new layout shows where it moved.
static int wq_u32_cmp(const void *a, const void *b)
{
    uint32_t x = *(const uint32_t *)a, y = *(const uint32_t *)b;
    return x < y ? -1 : x > y;
}

static void wq_ls_log_summary(const uint8_t *b, size_t n, NSString *layout, NSUInteger bundleRecords,
                              NSUInteger pluginRecords, NSUInteger names, NSUInteger mapped)
{
    NSMutableData *refData = [NSMutableData new];
    static const char needle[] = "/var/mobile/Containers/Data/";
    const size_t needleLen = sizeof(needle) - 1;
    const uint8_t *cursor = b, *end = b + n;
    while (cursor < end) {
        const uint8_t *hit = memmem(cursor, (size_t)(end - cursor), needle, needleLen);
        if (!hit) break;
        cursor = hit + needleLen;
        const uint8_t *start = hit;
        if ((size_t)(hit - b) >= 8 && memcmp(hit - 8, "/private", 8) == 0) start = hit - 8;
        size_t o = (size_t)(start - b);
        if (o < 8 || o % 4) continue;
        uint32_t len = wq_rd32(start - 4);
        if (len < needleLen || len > 0x100 || len > (size_t)(end - start)) continue;
        uint32_t ref = wq_rd32(start - 8) << 2;
        if (ref) [refData appendBytes:&ref length:sizeof(ref)];
        if (refData.length / sizeof(uint32_t) >= 20000) break;
    }
    NSUInteger pathCount = refData.length / sizeof(uint32_t);
    uint32_t *refs = refData.mutableBytes;
    if (pathCount) qsort(refs, pathCount, sizeof(uint32_t), wq_u32_cmp);
    NSLog(@"names: store %.1f MB, layout %@: %lu bundle and %lu plugin records, %lu names, %lu of %lu container paths mapped",
           n / 1048576.0, layout, (unsigned long)bundleRecords, (unsigned long)pluginRecords, (unsigned long)names,
           (unsigned long)mapped, (unsigned long)pathCount);
    if (!pathCount || mapped * 2 >= pathCount) return;

    // Vote for (record size, offset of the container reference).
    NSCountedSet<NSNumber *> *votes = [NSCountedSet new];
    for (size_t q = 0; q + 4 <= n; q += 4) {
        uint32_t v = wq_rd32(b + q);
        if (!v || (v & 3) || !bsearch(&v, refs, pathCount, sizeof(uint32_t), wq_u32_cmp)) continue;
        for (size_t k = 0; k < 0x400 && q >= 8 + k; k += 4) {
            uint32_t size = wq_rd32(b + q - 8 - k + 4);
            if (size >= 0x40 && size <= 0x800 && size % 4 == 0 && k < size)
                [votes addObject:@((uint64_t)size << 16 | k)];
        }
    }
    NSArray *top = [votes.allObjects sortedArrayUsingComparator:^NSComparisonResult(NSNumber *x, NSNumber *y) {
        NSUInteger cx = [votes countForObject:x], cy = [votes countForObject:y];
        return cx > cy ? NSOrderedAscending : cx < cy ? NSOrderedDescending : [x compare:y];
    }];
    NSMutableArray *parts = [NSMutableArray new];
    for (NSNumber *key in [top subarrayWithRange:NSMakeRange(0, MIN(top.count, (NSUInteger)8))]) {
        uint64_t value = key.unsignedLongLongValue;
        [parts addObject:[NSString stringWithFormat:@"0x%llx@0x%llx x%lu", value >> 16, value & 0xffff,
                          (unsigned long)[votes countForObject:key]]];
    }
    NSLog(@"names: layout hint (record size@container offset): %@", [parts componentsJoinedByString:@", "]);
}

static BOOL wq_parse_ls_store(NSData *data, NSDictionary **displayOut,
                              NSDictionary **bundleNameOut, NSDictionary **containersOut,
                              NSDictionary **bundlePathsOut)
{
    if (bundlePathsOut) *bundlePathsOut = nil;
    if (displayOut) *displayOut = nil;
    if (bundleNameOut) *bundleNameOut = nil;
    if (containersOut) *containersOut = nil;

    const uint8_t *b = data.bytes;
    size_t n = data.length;
    if (n < kWQLSMinStoreBytes || !b || memcmp(b, "bdsl", 4) != 0) {
        NSLog(@"names: not a LaunchServices store");
        return NO;
    }
    NSRange heapRange = [data rangeOfData:[NSData dataWithBytes:"<string>" length:8]
                                  options:0 range:NSMakeRange(0, n)];
    BOOL hasStringTable = heapRange.location != NSNotFound;
    size_t heap = hasStringTable ? heapRange.location : 0;

    // Pass 1: Bundle and plug-in records of every known layout, and which
    // string ids they need. The layout that maps the most containers wins.
    const uint32_t kIDs = kWQLSMaxStringID;
    size_t bitsetBytes = kIDs / 8;
    uint8_t *need = calloc(bitsetBytes, 1), *inHeap = calloc(bitsetBytes, 1);
    NSMutableArray<NSMutableData *> *layoutRecs = [NSMutableArray new], *layoutPlugins = [NSMutableArray new];
    for (size_t l = 0; l < kWQLSLayoutCount; l++) {
        [layoutRecs addObject:[NSMutableData new]];
        [layoutPlugins addObject:[NSMutableData new]];   // pairs: bundle id ref, container path ref
    }
    if (!need || !inHeap) {
        free(need);
        free(inHeap);
        NSLog(@"names: LaunchServices parser allocation failed");
        return NO;
    }

    BOOL tooManyRecords = NO;
    for (size_t o = 0; o + 8 + kWQLSMaxRecordSize <= n && !tooManyRecords; o += 4) {
        uint32_t size = wq_rd32(b + o + 4);
        const uint8_t *u = b + o + 8;
        for (size_t l = 0; l < kWQLSLayoutCount; l++) {
            const WQLSLayout *L = &kWQLSLayouts[l];
            if (size == L->pluginSize) {
                NSMutableData *plugins = layoutPlugins[l];
                uint32_t p[2] = { wq_rd32(u + L->pluginBundleID), wq_rd32(u + L->pluginContainer) };
                if (p[0] && !(p[0] & 3) && (p[0] >> 2) < kIDs && p[1] && !(p[1] & 3) && (p[1] >> 2) < kIDs &&
                    plugins.length / sizeof(p) < kWQLSMaxBundleRecords) {
                    [plugins appendBytes:p length:sizeof(p)];
                    for (int i = 0; i < 2; i++) need[(p[i] >> 2) / 8] |= 1 << ((p[i] >> 2) % 8);
                }
            }
            if (size != L->bundleSize) continue;
            NSMutableData *recs = layoutRecs[l];
            if (recs.length / (5 * sizeof(uint32_t)) >= kWQLSMaxBundleRecords) {
                tooManyRecords = YES;
                break;
            }
            uint32_t r[5] = { wq_rd32(u + L->bundleID), wq_rd32(u + L->name), wq_rd32(u + L->displayName), wq_rd32(u + L->container),
                              wq_rd32(u + L->bundlePath) };
            if (!r[0] || (r[0] & 3) || (r[0] >> 2) >= kIDs) continue;
            [recs appendBytes:r length:sizeof(r)];
            for (int i = 0; i < 5; i++) {
                if (r[i] && !(r[i] & 3) && (r[i] >> 2) < kIDs)
                    need[(r[i] >> 2) / 8] |= 1 << ((r[i] >> 2) % 8);
            }
        }
    }
    if (tooManyRecords) {
        free(need);
        free(inHeap);
        NSLog(@"names: LaunchServices store exceeds record limit");
        return NO;
    }

    // Pass 2: decode the CSStore tables independently. The <string> marker
    // starts the String table; path-like Alias entries before it are retained
    // in separate maps. This is essential on iOS 26.1, where Alias and String
    // IDs overlap and must never be merged.
    NSMutableDictionary<NSNumber *, NSString *> *strings = [NSMutableDictionary new];
    NSMutableDictionary<NSNumber *, id> *pathStrings = [NSMutableDictionary new];
    NSMutableDictionary<NSNumber *, id> *appPathStrings = [NSMutableDictionary new];
    NSUInteger decodedStringBytes = 0;
    BOOL tooManyStrings = NO;
    for (size_t o = 0; o <= n - 8; o += 4) {
        uint32_t sid = wq_rd32(b + o);
        if (!sid || sid >= kIDs || !(need[sid / 8] & (1 << (sid % 8)))) continue;
        BOOL here = !hasStringTable || o >= heap, had = strings[@(sid)] != nil;
        // String and Alias are independent CSStore tables. Never let a
        // pre-<string> Alias entry occupy or overwrite a String-table id.
        BOOL keepGeneral = here && (!had || !(inHeap[sid / 8] & (1 << (sid % 8))));
        uint32_t peekLen = o + 8 <= n ? wq_rd32(b + o + 4) : 0;
        BOOL maybePath = peekLen >= 6 && peekLen < 0x400 && o + 8 < n && b[o + 8] == '/';
        BOOL aliasPath = maybePath && (!hasStringTable || !here);
        if (!keepGeneral && !aliasPath) continue;
        NSString *s = wq_cs_string(b, n, o);
        if (!s) continue;
        if (aliasPath) {
            NSMutableDictionary *table = [s containsString:@"/mobile/Containers/Data/"] ? pathStrings
                : ([s hasSuffix:@".app"] || [s hasSuffix:@".app/"]) ? appPathStrings : nil;
            id previous = table[@(sid)];
            if (table && !previous) table[@(sid)] = s;
            else if (table && ![previous isEqual:s]) table[@(sid)] = NSNull.null;
        }
        if (!keepGeneral) continue;
        if (!had && (strings.count >= kWQLSMaxDecodedStrings ||
                     s.length > kWQLSMaxDecodedStringBytes - decodedStringBytes)) {
            tooManyStrings = YES;
            break;
        }
        strings[@(sid)] = s;
        if (!had) decodedStringBytes += s.length;
        if (here) inHeap[sid / 8] |= 1 << (sid % 8);
    }
    free(need);
    free(inHeap);
    if (tooManyStrings) {
        NSLog(@"names: LaunchServices store exceeds string limit");
        return NO;
    }
    NSUInteger anyRecords = 0, anyPlugins = 0;
    for (size_t l = 0; l < kWQLSLayoutCount; l++) {
        anyRecords += layoutRecs[l].length / (5 * sizeof(uint32_t));
        anyPlugins += layoutPlugins[l].length / (2 * sizeof(uint32_t));
    }
    if (!anyRecords) {
        wq_ls_log_summary(b, n, @"none", 0, anyPlugins, 0, 0);
        NSLog(@"names: LaunchServices store contains no bundle records");
        return NO;
    }

    NSString *(^pathFor)(uint32_t) = ^NSString *(uint32_t ref) {
        id path = pathStrings[@(ref >> 2)];
        if (path == NSNull.null) return nil;
        return path ?: strings[@(ref >> 2)];
    };
    NSDictionary *display = nil, *bundleName = nil, *containers = nil, *bundlePaths = nil;
    size_t chosen = 0;
    for (size_t l = 0; l < kWQLSLayoutCount; l++) {
        NSMutableDictionary *layoutDisplay = [NSMutableDictionary new], *layoutBundleName = [NSMutableDictionary new];
        NSMutableDictionary *layoutBundlePaths = [NSMutableDictionary new];
        NSMutableDictionary<NSString *, id> *layoutContainers = [NSMutableDictionary new];
        // A path claimed by two different bundle ids is left out rather than guessed.
        // Plug-in records only claim extension containers and bundle records
        // only app containers, so a record type that happens to share a size
        // can't knock out the other table's paths.
        void (^claim)(NSString *, NSString *, NSString *) = ^(NSString *path, NSString *bid, NSString *kind) {
            // iOS 26 stores container paths with a trailing slash; lookups
            // use the /private/var form without one.
            if ([path hasSuffix:@"/"]) path = [path substringToIndex:path.length - 1];
            if ([path hasPrefix:@"/var/"]) path = [@"/private" stringByAppendingString:path];
            if (!wq_is_data_container_path(path) || !wq_looks_like_bundle_id(bid) || ![path containsString:kind]) return;
            id known = layoutContainers[path];
            if (!known) layoutContainers[path] = bid;
            else if (![known isEqual:bid]) layoutContainers[path] = NSNull.null;
        };
        NSData *plugins = layoutPlugins[l], *recs = layoutRecs[l];
        const uint32_t *pr = plugins.bytes;
        for (NSUInteger i = 0; i < plugins.length / sizeof(uint32_t); i += 2)
            claim(pathFor(pr[i + 1]), strings[@(pr[i] >> 2)], @"/Data/PluginKitPlugin/");
        const uint32_t *r = recs.bytes;
        for (NSUInteger i = 0; i < recs.length / sizeof(uint32_t); i += 5) {
            NSString *bid = strings[@(r[i] >> 2)];
            if (!wq_looks_like_bundle_id(bid)) continue;
            if (r[i + 3] && !(r[i + 3] & 3)) claim(pathFor(r[i + 3]), bid, @"/Data/Application/");
            NSString *nm = (r[i + 1] & 3) ? nil : strings[@(r[i + 1] >> 2)];
            NSString *dn = (r[i + 2] & 3) ? nil : strings[@(r[i + 2] >> 2)];
            NSString *safeDisplay = wq_safe_name(dn);
            NSString *safeBundleName = wq_safe_name(nm);
            if (safeDisplay && !layoutDisplay[bid]) layoutDisplay[bid] = safeDisplay;
            if (safeBundleName && !layoutBundleName[bid]) layoutBundleName[bid] = safeBundleName;
            id appPath = (r[i + 4] && !(r[i + 4] & 3)) ? appPathStrings[@(r[i + 4] >> 2)] : nil;
            BOOL appPathAmbiguous = appPath == NSNull.null;
            if (appPathAmbiguous) appPath = nil;
            if (!appPath && !appPathAmbiguous && r[i + 4] && !(r[i + 4] & 3)) {
                NSString *stringPath = strings[@(r[i + 4] >> 2)];
                if ([stringPath hasSuffix:@".app"] || [stringPath hasSuffix:@".app/"]) appPath = stringPath;
            }
            if ([appPath isKindOfClass:NSString.class] && !layoutBundlePaths[bid]) {
                NSString *clean = [appPath hasSuffix:@"/"] ? [appPath substringToIndex:[appPath length] - 1] : appPath;
                if ([clean hasPrefix:@"/var/"]) clean = [@"/private" stringByAppendingString:clean];
                layoutBundlePaths[bid] = clean;
            }
        }
        for (NSString *path in layoutContainers.allKeys)
            if (layoutContainers[path] == NSNull.null) [layoutContainers removeObjectForKey:path];
        if (!containers || layoutContainers.count > containers.count ||
            (layoutContainers.count == containers.count && layoutDisplay.count > display.count)) {
            display = layoutDisplay;
            bundleName = layoutBundleName;
            bundlePaths = layoutBundlePaths;
            containers = layoutContainers;
            chosen = l;
        }
    }
    // A few Apple apps' names, to check the name fields of a new layout.
    NSMutableArray *samples = [NSMutableArray new];
    for (NSString *bid in @[@"com.apple.mobilesafari", @"com.apple.Preferences", @"com.apple.camera", @"com.apple.mobilenotes"]) {
        NSString *name = display[bid] ?: bundleName[bid];
        if (name) [samples addObject:[NSString stringWithFormat:@"%@ = %@", bid, name]];
    }
    if (samples.count) NSLog(@"names: sample: %@", [samples componentsJoinedByString:@", "]);
    wq_ls_log_summary(b, n, @(kWQLSLayouts[chosen].label), layoutRecs[chosen].length / (5 * sizeof(uint32_t)),
                      layoutPlugins[chosen].length / (2 * sizeof(uint32_t)), display.count, containers.count);
    if (bundlePathsOut) *bundlePathsOut = [bundlePaths copy];
    if (displayOut) *displayOut = [display copy];
    if (bundleNameOut) *bundleNameOut = [bundleName copy];
    if (containersOut) *containersOut = [containers copy];
    return YES;
}

#pragma mark - Bounded store discovery and read-only access

static NSString *const kWQPosterBoardStorePathKey = @"DriftLaunchServicesCSStorePath";
static const int64_t kWQLSInodeMargin = 100000;
static const int64_t kWQLSScanChunk = 32768;
static const CFTimeInterval kWQLSScanLimit = 20.0;

static BOOL wq_ls_is_store_path(const char *path)
{
    if (!path) return NO;
    const char *name = strrchr(path, '/');
    name = name ? name + 1 : path;
    size_t length = strlen(name);
    if (length <= 33 || strncmp(name, "com.apple.LaunchServices-", 25) != 0 ||
        strcmp(name + length - 8, ".csstore") != 0) return NO;
    return strstr(path, "/Containers/Data/InternalDaemon/") != NULL &&
           strstr(path, "/Library/Caches/") != NULL;
}

/// Obtain access to the containing Caches directory, then read a bounded,
/// stable regular file. The alternate flag is tried first on iOS 26; the
/// other flag set is a fallback for releases/signing combinations that differ.
static NSData *wq_ls_read_store(NSString *path, NSString *group, BOOL preferAlternative,
                                struct stat *resultStat)
{
    if (!path.length || !group.length) return nil;
    NSString *parent = path.stringByDeletingLastPathComponent;
    for (NSUInteger attempt = 0; attempt < 2; attempt++) {
        BOOL alternate = attempt == 0 ? preferAlternative : !preferAlternative;
        int64_t handle = worse_query(parent, group, alternate, true);
        if (handle <= 0) continue;

        int fd = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
        if (fd < 0) {
            worse_query_release(handle);
            continue;
        }
        struct stat before = {0}, after = {0};
        BOOL valid = fstat(fd, &before) == 0 && S_ISREG(before.st_mode) &&
            before.st_size >= (off_t)kWQLSMinStoreBytes &&
            before.st_size <= (off_t)kWQLSMaxStoreBytes;
        NSMutableData *data = valid ? [NSMutableData dataWithCapacity:(NSUInteger)before.st_size] : nil;
        uint8_t buffer[65536];
        while (valid) {
            ssize_t count = read(fd, buffer, sizeof(buffer));
            if (count < 0 && errno == EINTR) continue;
            if (count < 0) { valid = NO; break; }
            if (count == 0) break;
            if (data.length > kWQLSMaxStoreBytes - (NSUInteger)count) { valid = NO; break; }
            [data appendBytes:buffer length:(NSUInteger)count];
        }
        if (fstat(fd, &after) != 0 || before.st_dev != after.st_dev ||
            before.st_ino != after.st_ino || before.st_size != after.st_size ||
            before.st_mtimespec.tv_sec != after.st_mtimespec.tv_sec ||
            before.st_mtimespec.tv_nsec != after.st_mtimespec.tv_nsec) valid = NO;
        close(fd);
        worse_query_release(handle);
        if (!valid || data.length < kWQLSMinStoreBytes ||
            memcmp(data.bytes, "bdsl", 4) != 0) continue;
        if (resultStat) *resultStat = after;
        return data;
    }
    return nil;
}

static int64_t wq_ls_volume_limit(fsid_t *resultFSID)
{
    NSString *directory = NSTemporaryDirectory();
    if (!directory.length) return 0;
    NSString *probe = [directory stringByAppendingPathComponent:
        [NSString stringWithFormat:@".drift-ls-inode-%u", arc4random()]];
    int fd = open(probe.fileSystemRepresentation, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0600);
    if (fd < 0) return 0;
    struct stat st = {0};
    struct statfs fs = {0};
    BOOL ok = fstat(fd, &st) == 0 && fstatfs(fd, &fs) == 0;
    int savedErrno = errno;
    close(fd);
    unlink(probe.fileSystemRepresentation);
    errno = savedErrno;
    if (!ok || st.st_ino <= 0 || st.st_ino > INT64_MAX - kWQLSInodeMargin) return 0;
    if (resultFSID) *resultFSID = fs.f_fsid;
    return (int64_t)st.st_ino + kWQLSInodeMargin;
}

static NSString *wq_ls_scan_for_store(NSString *group, BOOL preferAlternative)
{
    fsid_t fsid = {0};
    int64_t maxInode = wq_ls_volume_limit(&fsid);
    if (maxInode <= 0) {
        NSLog(@"[Drift CSStore] cannot determine the data-volume inode bound");
        return nil;
    }

    CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
    int64_t chunks = (maxInode + kWQLSScanChunk - 1) / kWQLSScanChunk;
    __block int64_t nextChunk = 0;
    NSLock *lock = [NSLock new];
    NSMutableArray<NSDictionary *> *candidates = [NSMutableArray new];
    NSUInteger cores = NSProcessInfo.processInfo.activeProcessorCount;
    size_t workers = (size_t)MAX((NSUInteger)1, MIN((NSUInteger)4, cores / 2));

    dispatch_apply(workers, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(size_t __unused worker) {
        fsid_t volume = fsid;
        char buffer[PATH_MAX];
        for (;;) {
            [lock lock];
            int64_t chunk = nextChunk++;
            [lock unlock];
            if (chunk >= chunks || CFAbsoluteTimeGetCurrent() - started >= kWQLSScanLimit) return;

            int64_t last = maxInode - chunk * kWQLSScanChunk;
            int64_t first = MAX((int64_t)1, last - kWQLSScanChunk + 1);
            for (int64_t inode = last; inode >= first; inode--) {
                if ((inode & 127) == 0 && CFAbsoluteTimeGetCurrent() - started >= kWQLSScanLimit) return;
                if (fsgetpath(buffer, sizeof(buffer), &volume, (uint64_t)inode) <= 0 ||
                    !wq_ls_is_store_path(buffer)) continue;
                NSString *candidate = [NSString stringWithUTF8String:buffer];
                if (!candidate) continue;
                [lock lock];
                [candidates addObject:@{ @"path": candidate, @"inode": @(inode) }];
                [lock unlock];
                break; // This worker found the newest matching file in its chunk.
            }
        }
    });

    [candidates sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"inode"] compare:a[@"inode"]];
    }];
    for (NSDictionary *candidate in candidates) {
        NSString *path = candidate[@"path"];
        NSData *data = wq_ls_read_store(path, group, preferAlternative, NULL);
        if (data) {
            NSLog(@"[Drift CSStore] found readable LaunchServices database in %.2f s",
                  CFAbsoluteTimeGetCurrent() - started);
            return path;
        }
    }
    NSLog(@"[Drift CSStore] no readable LaunchServices database found in %.2f s",
          CFAbsoluteTimeGetCurrent() - started);
    return nil;
}

static void wq_ls_record_status(int32_t *status, int32_t value)
{
    if (!status) return;
    if (*status == WQLSStatusFound) return;
    // StoreNotFound is the least specific failure. Keep the first specific
    // one, so a later "scan found no store" cannot erase an earlier
    // read/parse/bundle failure.
    if (*status == WQLSStatusStoreNotFound) *status = value;
}

static NSString *wq_ls_resolve_from_data(NSData *data, NSString *bundleID,
                                          int32_t *status)
{
    NSDictionary *containers = nil;
    if (!wq_parse_ls_store(data, NULL, NULL, &containers, NULL) || !containers.count) {
        wq_ls_record_status(status, WQLSStatusStoreParseFailed);
        return nil;
    }
    for (NSString *path in containers) {
        if ([containers[path] isEqualToString:bundleID] &&
            [path hasPrefix:@"/private/var/mobile/Containers/Data/Application/"]) {
            NSString *uuid = path.lastPathComponent;
            if ([[NSUUID alloc] initWithUUIDString:uuid]) {
                if (status) *status = WQLSStatusFound;
                return path;
            }
        }
    }
    wq_ls_record_status(status, WQLSStatusBundleNotFound);
    return nil;
}

NSString *wq_ls_container_path_for_bundle_id(NSString *bundleID, NSString *appGroup,
                                              BOOL preferAlternativeFlags)
{
    return wq_ls_container_path_for_bundle_id_status(bundleID, appGroup,
                                                     preferAlternativeFlags, NULL);
}

NSString *wq_ls_container_path_for_bundle_id_status(NSString *bundleID, NSString *appGroup,
                                                     BOOL preferAlternativeFlags,
                                                     int32_t *status)
{
    if (status) *status = WQLSStatusInvalidArguments;
    if (!bundleID.length || !appGroup.length) return nil;

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *cached = [defaults stringForKey:kWQPosterBoardStorePathKey];
    NSString *path = cached;
    int32_t failure = WQLSStatusStoreNotFound;
    NSData *data = path.length ? wq_ls_read_store(path, appGroup, preferAlternativeFlags, NULL) : nil;
    NSString *container = nil;
    if (data) {
        container = wq_ls_resolve_from_data(data, bundleID, &failure);
    } else if (path.length) {
        wq_ls_record_status(&failure, WQLSStatusStoreReadFailed);
    }

    if (!container) {
        path = wq_ls_scan_for_store(appGroup, preferAlternativeFlags);
        if (!path) {
            wq_ls_record_status(&failure, WQLSStatusStoreNotFound);
        } else {
            data = wq_ls_read_store(path, appGroup, preferAlternativeFlags, NULL);
            if (!data) {
                wq_ls_record_status(&failure, WQLSStatusStoreReadFailed);
            } else {
                // This store was read successfully; its resolve verdict
                // (bundle found / parse failed / bundle absent) is the one
                // that describes the final attempt, not a stale read failure
                // from the cached path.
                failure = WQLSStatusStoreNotFound;
                container = wq_ls_resolve_from_data(data, bundleID, &failure);
            }
        }
    }
    if (container && path.length) {
        [defaults setObject:path forKey:kWQPosterBoardStorePathKey];
        if (status) *status = WQLSStatusFound;
        NSLog(@"[Drift CSStore] %@ -> %@", bundleID, container);
        return container;
    }
    if (status) *status = failure;
    return nil;
}
