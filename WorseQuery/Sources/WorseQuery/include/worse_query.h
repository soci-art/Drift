//
//  worse_query.h
//  worse_query
//
//  Created by Taj C on 8/20/26.
//

/*
     worse_query - A sandbox escape PoC for iOS 26 and 27, again.
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

#ifndef worse_query_h
#define worse_query_h

#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stdbool.h>

/// Consume a sandbox extension for `path`.
///
/// `group` must be an App Group identifier the running app is entitled to; the
/// escape stages its symlink inside that group's `Library/Caches` and asks
/// containermanagerd to resolve it. `alt_flags` selects the flag set iOS 26.x
/// needs for App Group paths (see `WorseQuery.swift` for the rule), and
/// `create_dir` skips the existence check for a path the caller is about to
/// create.
///
/// Returns a positive handle on success, or one of the negative codes the
/// Swift wrapper maps to a message (-1 group unavailable, -2 symbols missing,
/// -3 query, -4 symlink, -5 rejected, -6 no extension, -255 target missing).
int64_t worse_query(NSString *path, NSString *group, bool alt_flags, bool create_dir);

/// Release a handle returned by `worse_query`. Safe to call only on a positive
/// handle; the wrapper checks that.
void worse_query_release(int64_t handle);

#endif /* worse_query_h */
