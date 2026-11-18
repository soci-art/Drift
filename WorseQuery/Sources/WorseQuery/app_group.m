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

typedef struct __SecTask *SecTaskRef;
typedef SecTaskRef (*SecTaskCreateFromSelfFn)(CFAllocatorRef);
typedef CFTypeRef (*SecTaskCopyEntitlementFn)(SecTaskRef, CFStringRef, CFErrorRef *);

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
    if (!value) return NULL;

    NSMutableArray<NSString *> *groups = [NSMutableArray array];
    CFTypeID type = CFGetTypeID(value);
    if (type == CFArrayGetTypeID()) {
        for (id group in (__bridge NSArray *)value) {
            if ([group isKindOfClass:NSString.class] && [group length]) [groups addObject:group];
        }
    } else if (type == CFStringGetTypeID()) {
        NSString *group = (__bridge NSString *)value;
        if (group.length) [groups addObject:group];
    }
    CFRelease(value);

    // Any granted group whose container opens is enough; the order is the
    // entitlement's own, so nothing here prefers one over another.
    NSFileManager *files = [NSFileManager defaultManager];
    for (NSString *group in groups) {
        if ([files containerURLForSecurityApplicationGroupIdentifier:group]) {
            return strdup(group.UTF8String);
        }
    }
    return NULL;
}

void drift_app_group_free(char *value)
{
    free(value);
}
