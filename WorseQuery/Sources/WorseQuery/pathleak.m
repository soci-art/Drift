//
//  pathleak.m
//  worse_query
//
//  Created by Taj C on 9/2/26.
//

/*
     pathleak - The dumbest arbitrary path enumeration.
     Copyright (C) 2026 Taj C (forcequit)

     This program is free software: you can redistribute it and/or modify
     it under the terms of the GNU General Public License as published by
     the Free Software Foundation, either version 3 of the License, or
     (at your option) any later version.

     This program is distributed in the hope that it will be useful,
     but WITHOUT ANY WARRANTY; without even the implied warranty of
     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
     GNU General Public License for more details.

     You should have received a copy of the GNU General Public License
     along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/

// Copied from forcequitOS/worse_query (main), like worse_query.m (only
// trailing whitespace stripped). The
// brute-force loop and the fsgetpath call are the whole utility; do not
// "optimise" them without measuring on a device.

#import <Foundation/Foundation.h>
#include <dispatch/dispatch.h>
#include <stdlib.h>
#include <string.h>
#include <sys/fsgetpath.h>
#include <sys/mount.h>

// This is just a rewrite of bad_query_list to return an NSString array and run faster
// The way this works is literally just brute-forcing inodes and doing fsgetpath until it gets a matching path, lol.
// Which is still, obviously, dramatically faster than brute-forcing UUIDs.

// It might be possible to derive a sane inode value automagically by just creating a file, doing stat() on it, getting *that* file's inode, then using that for the max_inode count.

NSArray<NSString *> *pathleak(NSString *path, uint64_t max_inode) {
    // Sanity checks
    if (path.length == 0 || max_inode < 1) return nil;
    NSString *dir = path;
    while (dir.length > 1 && [dir hasSuffix: @"/"]) { // Trim trailing slash (if present)
        dir = [dir substringToIndex: dir.length - 1];
    }

    // Set everything up
    struct statfs sfs;
    if (statfs(dir.fileSystemRepresentation, &sfs) != 0) return nil;
    fsid_t fsid = sfs.f_fsid;

    char prefix[PATH_MAX];
    if (![dir getFileSystemRepresentation: prefix maxLength: sizeof(prefix)]) return nil;
    size_t prefix_length = strlen(prefix);
    if (prefix_length == 1 && prefix[0] == '/') prefix_length = 0;

    NSFileManager *files = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    char buffer[PATH_MAX];

    // Brute-force inodes to their corresponding paths
    // I'd like to make this multithreaded at some point, but I don't think it'll help.
    for (uint64_t inode = 1; inode <= max_inode; inode++) {
        ssize_t n = fsgetpath(buffer, sizeof(buffer), &fsid, inode);
        if (n <= 0) continue;

        if (strncmp(buffer, prefix, prefix_length) != 0) continue;
        if (buffer[prefix_length] != '/') continue;
        if (strchr(buffer + prefix_length + 1, '/')) continue;

        NSString *string = [files stringWithFileSystemRepresentation: buffer length: strlen(buffer)];
        if (string) [result addObject: string];
    }
    return result;
}

// Probe-only range worker. The loop body is deliberately identical to the one
// above; keeping it separate is what leaves pathleak() itself untouched.
static void pathleak_scan_range(NSString *dir, fsid_t fsid,
                                const char *prefix, size_t prefix_length,
                                uint64_t start, uint64_t end,
                                NSMutableArray<NSString *> *result) {
    if (start > end) return;

    NSFileManager *files = [NSFileManager defaultManager];
    char buffer[PATH_MAX];

    for (uint64_t inode = start; inode <= end; inode++) {
        ssize_t n = fsgetpath(buffer, sizeof(buffer), &fsid, inode);
        if (n <= 0) continue;

        if (strncmp(buffer, prefix, prefix_length) != 0) continue;
        if (buffer[prefix_length] != '/') continue;
        if (strchr(buffer + prefix_length + 1, '/')) continue;

        NSString *string = [files stringWithFileSystemRepresentation: buffer length: strlen(buffer)];
        if (string) [result addObject: string];
    }
}

NSArray<NSString *> *pathleak_range(NSString *path, uint64_t start_inode,
                                    uint64_t end_inode) {
    if (path.length == 0 || start_inode < 1 || end_inode < start_inode) return nil;
    NSString *dir = path;
    while (dir.length > 1 && [dir hasSuffix: @"/"]) {
        dir = [dir substringToIndex: dir.length - 1];
    }

    struct statfs sfs;
    if (statfs(dir.fileSystemRepresentation, &sfs) != 0) return nil;
    fsid_t fsid = sfs.f_fsid;

    char prefix[PATH_MAX];
    if (![dir getFileSystemRepresentation: prefix maxLength: sizeof(prefix)]) return nil;
    size_t prefix_length = strlen(prefix);
    if (prefix_length == 1 && prefix[0] == '/') prefix_length = 0;

    NSMutableArray<NSString *> *result = [NSMutableArray array];
    pathleak_scan_range(dir, fsid, prefix, prefix_length,
                        start_inode, end_inode, result);
    return result;
}

NSArray<NSString *> *pathleak_parallel(NSString *path, uint64_t max_inode,
                                       NSUInteger threadCount) {
    if (path.length == 0 || max_inode < 1) return nil;
    NSString *dir = path;
    while (dir.length > 1 && [dir hasSuffix: @"/"]) {
        dir = [dir substringToIndex: dir.length - 1];
    }

    struct statfs sfs;
    if (statfs(dir.fileSystemRepresentation, &sfs) != 0) return nil;
    fsid_t fsid = sfs.f_fsid;

    char prefix[PATH_MAX];
    if (![dir getFileSystemRepresentation: prefix maxLength: sizeof(prefix)]) return nil;
    size_t prefix_length = strlen(prefix);
    if (prefix_length == 1 && prefix[0] == '/') prefix_length = 0;

    NSUInteger workers = threadCount < 1 ? 1 : threadCount;
    if (workers > 64) workers = 64;
    if ((uint64_t)workers > max_inode) workers = (NSUInteger)max_inode;
    if (workers == 0) workers = 1;

    uint64_t chunk = max_inode / (uint64_t)workers;
    if (max_inode % (uint64_t)workers != 0) chunk += 1;

    // Blocks capture this copy, not the stack array above; it lives until the
    // group has finished and is freed exactly once.
    char *shared_prefix = strdup(prefix);
    if (shared_prefix == NULL) return nil;

    NSMutableArray<NSMutableArray<NSString *> *> *parts = [NSMutableArray arrayWithCapacity: workers];
    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);

    for (NSUInteger i = 0; i < workers; i++) {
        uint64_t start = (uint64_t)i * chunk + 1;
        uint64_t end = ((uint64_t)i + 1) * chunk;
        if (end > max_inode) end = max_inode;
        if (start > max_inode) continue;

        NSMutableArray<NSString *> *part = [NSMutableArray array];
        [parts addObject: part];
        dispatch_group_async(group, queue, ^{
            @autoreleasepool {
                pathleak_scan_range(dir, fsid, shared_prefix, prefix_length, start, end, part);
            }
        });
    }

    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    free(shared_prefix);

    // Each part is already in inode order, so appending parts in range order
    // preserves the single-threaded order. The ordered set only removes an
    // accidental duplicate, without sorting or changing the first occurrence.
    NSMutableOrderedSet<NSString *> *merged = [NSMutableOrderedSet orderedSet];
    for (NSMutableArray<NSString *> *part in parts) {
        [merged addObjectsFromArray: part];
    }
    return merged.array;
}
