//
//  wq_launch_services.h
//  Drift / WorseQuery
//
//  Bounded LaunchServices CSStore reader, adapted from LaunchShield's
//  WQLaunchServices parser. GPL-3.0-or-later.
//
#import <Foundation/Foundation.h>
#import <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// Resolves an installed app's data-container path from the LaunchServices
/// CSStore. Uses the current process's entitled App Group to obtain a
/// read-only sandbox extension for the database. Returns nil on any
/// discovery, authorization, or parse failure; callers must retain their
/// existing discovery fallbacks.
NSString * _Nullable wq_ls_container_path_for_bundle_id(NSString *bundleID,
                                                        NSString *appGroup,
                                                        BOOL preferAlternativeFlags);

/// Status codes for the diagnostic variant. `Found` means the returned path
/// is a match; every other code explains why the path is nil. NS_ENUM keeps
/// the values in one place: Swift reads the same cases instead of keeping a
/// hand-synced copy.
typedef NS_ENUM(int32_t, WQLSStatus) {
    WQLSStatusFound = 0,
    WQLSStatusInvalidArguments = 1,
    WQLSStatusStoreNotFound = 2,
    WQLSStatusStoreReadFailed = 3,
    WQLSStatusStoreParseFailed = 4,
    WQLSStatusBundleNotFound = 5,
};

/// Same query as above, but reports why it failed. `status` may be NULL.
NSString * _Nullable wq_ls_container_path_for_bundle_id_status(NSString *bundleID,
                                                              NSString *appGroup,
                                                              BOOL preferAlternativeFlags,
                                                              int32_t * _Nullable status);

NS_ASSUME_NONNULL_END
