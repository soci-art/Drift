#ifndef drift_kernel_direct_h
#define drift_kernel_direct_h

// The two entry points the app uses:
//
//  * kexploit_opa334()      — establish kernel read/write (0 on success).
//  * sandbox_escape(proc)   — patch this process's sandbox profile (0 on
//                             success); sandbox_access_is_active() is the
//                             write-read-delete self-check it ends with.
//
// Everything else in this module (krw, kutils, offsets, vnode) is internal
// machinery those two functions call.
#import "kexploit_opa334.h"
#import "sandbox_escape.h"
#import "kutils.h"

#endif
