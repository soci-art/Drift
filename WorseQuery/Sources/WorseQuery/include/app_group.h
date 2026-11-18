#ifndef drift_app_group_h
#define drift_app_group_h

/// The first App Group this process actually carries whose container opens.
///
/// The list comes from SecTask (the process's own entitlements), not from the
/// embedded provisioning profile: a re-signed build has whatever groups the
/// signing certificate granted, and the profile on disk can differ from that.
/// Returns a malloc'd UTF-8 string the caller frees with
/// `drift_app_group_free`, or NULL when no group is granted or opens.
char *drift_app_group(void);

void drift_app_group_free(char *value);

#endif
