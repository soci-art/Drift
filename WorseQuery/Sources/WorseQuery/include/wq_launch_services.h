//
//  wq_launch_services.h
//  Drift / WorseQuery
//
//  Bounded LaunchServices CSStore reader, adapted from LaunchShield's
//  WQLaunchServices parser. GPL-3.0-or-later.
//
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Resolves an installed app's data-container path from the LaunchServices
/// CSStore. Uses the current process's entitled App Group to obtain a
/// read-only sandbox extension for the database. Returns nil on any
/// discovery, authorization, or parse failure; callers must retain their
/// existing discovery fallbacks.
NSString * _Nullable wq_ls_container_path_for_bundle_id(NSString *bundleID,
                                                        NSString *appGroup,
                                                        BOOL preferAlternativeFlags);

NS_ASSUME_NONNULL_END
