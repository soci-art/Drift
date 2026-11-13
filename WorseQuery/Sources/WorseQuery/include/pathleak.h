//
//  pathleak.h
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

#ifndef pathleak_h
#define pathleak_h

#import <Foundation/Foundation.h>

/// Immediate children of `filter` on the volume `filter` lives on, found by
/// brute-forcing inode numbers through `fsgetpath`.
///
/// `max_inode` bounds the walk. The app derives it from a file it just created
/// on the same volume, which is what upstream's own demo does. Returns nil when
/// the directory cannot be examined.
///
/// This exists because a container directory is not readable before the escape
/// has opened *something*, and the escape needs a path to open. It is the
/// upstream fallback for exactly that chicken-and-egg case; the normal path in
/// this app is a directory listing under the Application root's extension.
NSArray<NSString *> * _Nullable pathleak(NSString *filter, uint64_t max_inode);

/// Same enumeration as `pathleak`, split into `threadCount` contiguous inode
/// ranges and run concurrently. Results are merged in inode order and
/// deduplicated. This is the probe-only entry point; the normal apply path
/// keeps calling `pathleak` above.
NSArray<NSString *> * _Nullable pathleak_parallel(NSString *filter,
                                                  uint64_t max_inode,
                                                  NSUInteger threadCount);

#endif /* pathleak_h */
