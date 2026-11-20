//
//  app_group.m
//  Drift
//
//  The App Group half of QuinnTang74/3106's sandbox access layer
//  (ThreeOneOSSix/exploit/worse_query.m, worse_query_app_group), GPL-3.0.
//  Drift returns the group identifier instead of only checking it, so the
//  Swift bridge can log which group was chosen and pass it to worse_query.
//
//  Why SecTask instead of the embedded provisioning profile: the profile on
//  disk is not what the process runs with. SideStore / AltStore / a p12
//  re-sign replaces the signed entitlements, and the profile can be absent
//  entirely while the process still carries real groups. SecTask answers for
//  the process itself, which is the question worse_query needs answered.
//

#include "app_group.h"
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#import <mach-o/loader.h>

typedef struct __SecTask *SecTaskRef;
typedef SecTaskRef (*SecTaskCreateFromSelfFn)(CFAllocatorRef);
typedef CFTypeRef (*SecTaskCopyEntitlementFn)(SecTaskRef, CFStringRef, CFErrorRef *);


static uint32_t wq_read_be32(const uint8_t *bytes, size_t length, size_t offset)
{
    if (!bytes || offset > length || length - offset < 4) return 0;
    uint32_t value = 0;
    memcpy(&value, bytes + offset, sizeof(value));
    return CFSwapInt32BigToHost(value);
}

// Erosion-CN fallback: read the signed Mach-O entitlements only when SecTask
// does not expose application-groups. This is a fallback source, not a claim
// that a provisioning profile alone grants runtime access.
static NSArray<NSString *> *wq_macho_app_groups(void)
{
    NSString *path = NSBundle.mainBundle.executablePath;
    NSData *image = path.length ? [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil] : nil;
    if (image.length < 32) return @[];
    const uint8_t *bytes = image.bytes;
    size_t length = image.length;

    uint32_t magic = 0;
    memcpy(&magic, bytes, sizeof(magic));
    size_t headerSize = 0;
    if (magic == MH_MAGIC_64) headerSize = sizeof(struct mach_header_64);
    else if (magic == MH_MAGIC) headerSize = sizeof(struct mach_header);
    else return @[]; // The installed main executable is expected to be a thin arm64 Mach-O.

    if (length < headerSize) return @[];
    uint32_t commandCount = 0, commandBytes = 0;
    memcpy(&commandCount, bytes + 16, sizeof(commandCount));
    memcpy(&commandBytes, bytes + 20, sizeof(commandBytes));
    if (commandBytes > length - headerSize || commandCount > commandBytes / sizeof(struct load_command)) return @[];

    size_t cursor = headerSize;
    size_t commandEnd = headerSize + commandBytes;
    size_t signatureOffset = 0, signatureLength = 0;
    for (uint32_t i = 0; i < commandCount; i++) {
        if (cursor > commandEnd || commandEnd - cursor < sizeof(struct load_command)) return @[];
        struct load_command command;
        memcpy(&command, bytes + cursor, sizeof(command));
        if (command.cmdsize < sizeof(struct load_command) || command.cmdsize > commandEnd - cursor) return @[];
        if (command.cmd == LC_CODE_SIGNATURE && command.cmdsize >= sizeof(struct linkedit_data_command)) {
            struct linkedit_data_command signature;
            memcpy(&signature, bytes + cursor, sizeof(signature));
            signatureOffset = signature.dataoff;
            signatureLength = signature.datasize;
            break;
        }
        cursor += command.cmdsize;
    }
    if (!signatureLength || signatureOffset > length || signatureLength > length - signatureOffset) return @[];

    const uint8_t *superBlob = bytes + signatureOffset;
    size_t superLength = signatureLength;
    if (wq_read_be32(superBlob, superLength, 0) != 0xfade0cc0) return @[];
    uint32_t blobLength = wq_read_be32(superBlob, superLength, 4);
    uint32_t blobCount = wq_read_be32(superBlob, superLength, 8);
    if (blobLength > superLength || blobLength < 12 || blobCount > (blobLength - 12) / 8) return @[];

    for (uint32_t i = 0; i < blobCount; i++) {
        size_t indexOffset = 12 + (size_t)i * 8;
        uint32_t entitlementOffset = wq_read_be32(superBlob, blobLength, indexOffset + 4);
        if (entitlementOffset > blobLength || blobLength - entitlementOffset < 8) continue;
        uint32_t entitlementMagic = wq_read_be32(superBlob, blobLength, entitlementOffset);
        uint32_t entitlementLength = wq_read_be32(superBlob, blobLength, entitlementOffset + 4);
        if (entitlementMagic != 0xfade7171 || entitlementLength < 8 ||
            entitlementLength > blobLength - entitlementOffset) continue;

        NSData *plistData = [NSData dataWithBytes:superBlob + entitlementOffset + 8
                                           length:entitlementLength - 8];
        id plist = [NSPropertyListSerialization propertyListWithData:plistData options:0 format:nil error:nil];
        id groups = [plist isKindOfClass:NSDictionary.class]
            ? ((NSDictionary *)plist)[@"com.apple.security.application-groups"] : nil;
        if (![groups isKindOfClass:NSArray.class]) continue;
        NSMutableArray<NSString *> *result = [NSMutableArray array];
        for (id group in (NSArray *)groups) {
            if ([group isKindOfClass:NSString.class] && [group hasPrefix:@"group."] &&
                [group length] && ![result containsObject:group]) [result addObject:group];
        }
        return result;
    }
    return @[];
}

char *drift_app_group(void)
{
    static SecTaskCreateFromSelfFn createTask;
    static SecTaskCopyEntitlementFn copyEntitlement;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY);
        if (!security) return;
        createTask = (SecTaskCreateFromSelfFn)dlsym(security, "SecTaskCreateFromSelf");
        copyEntitlement = (SecTaskCopyEntitlementFn)dlsym(security, "SecTaskCopyValueForEntitlement");
    });
    if (!createTask || !copyEntitlement) return NULL;

    SecTaskRef task = createTask(kCFAllocatorDefault);
    if (!task) return NULL;
    CFTypeRef value = copyEntitlement(task, CFSTR("com.apple.security.application-groups"), NULL);
    CFRelease(task);
    NSMutableArray<NSString *> *groups = [NSMutableArray array];
    if (value) {
        CFTypeID type = CFGetTypeID(value);
        if (type == CFArrayGetTypeID()) {
            for (id group in (__bridge NSArray *)value) {
                if ([group isKindOfClass:NSString.class] && [group hasPrefix:@"group."] &&
                    [group length] && ![groups containsObject:group]) [groups addObject:group];
            }
        } else if (type == CFStringGetTypeID()) {
            NSString *group = (__bridge NSString *)value;
            if ([group hasPrefix:@"group."] && group.length) [groups addObject:group];
        }
        CFRelease(value);
    }

    // Match Erosion-CN's source order: prefer the app's own bundle-derived
    // group, then its declared Drift group, then every other signed group.
    // If SecTask has no value, inspect the executable's signed entitlements.
    if (!groups.count) [groups addObjectsFromArray:wq_macho_app_groups()];
    NSString *bundleGroup = [@"group." stringByAppendingString:NSBundle.mainBundle.bundleIdentifier ?: @""];
    NSString *defaultGroup = @"group.com.sociart.drift";
    NSMutableArray<NSString *> *ordered = [NSMutableArray array];
    for (NSString *preferred in @[bundleGroup, defaultGroup]) {
        if (preferred.length > 6 && [groups containsObject:preferred] && ![ordered containsObject:preferred])
            [ordered addObject:preferred];
    }
    for (NSString *group in groups) {
        if (![ordered containsObject:group]) [ordered addObject:group];
    }

    NSFileManager *files = [NSFileManager defaultManager];
    for (NSString *group in ordered) {
        if ([files containerURLForSecurityApplicationGroupIdentifier:group]) {
            return strdup(group.UTF8String);
        }
    }
    // Erosion-CN keeps its declared default group as a last-resort candidate;
    // Drift declares the same identifier in its app entitlements.
    if (ordered.count) return strdup(ordered.firstObject.UTF8String);
    return strdup(defaultGroup.UTF8String);
}

void drift_app_group_free(char *value)
{
    free(value);
}
