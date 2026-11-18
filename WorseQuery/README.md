# WorseQuery

`worse_query` — an in-process sandbox escape for iOS 26.0 – 26.7.2 and 27.x up
to 27.2, by [Taj C (forcequit)](https://github.com/forcequitOS/worse_query).
The sources under `Sources/WorseQuery` are copied from that repository; the
only edit is a note in `worse_query.m` saying so.

## Licence

worse_query is **GPL-3.0** (`Copyright (C) 2026 Taj C`). Drift is AGPL-3.0 and
the two are compatible: GPL-3.0 §13 permits combining a GPL-3.0 work with an
AGPL-3.0 work, and the result is distributed under AGPL-3.0. The licence
headers stay in each source file, and Drift's README credits the project.

## What Drift uses it for

One thing only: consuming a sandbox extension for PosterBoard's data container,
so a wallpaper pack can be written into
`…/PRBPosterExtensionDataStore/<version>/Extensions/…/descriptors/` from inside
the app. The alternative route (AirLift) needs a pairing record and a live
tunnel; this one does not. iOS 26.0–26.6.1 takes the `bad_query` backend (no
App Group needed); 26.7–26.7.2 and 27.0–27.3 take `worse_query`.

## Requirements, split by system (3106's routing)

- **iOS 26.0–26.6.1 — `bad_query`.** `bad_query.c` is copied verbatim from
  QuinnTang74/3106 (`ThreeOneOSSix/exploit/bad_query.c`, GPL-3.0). It anchors
  the container query at `systemgroup.com.apple.mobilegestaltcache` (class 13)
  with a relative part domain, so it needs no App Group and no signing
  entitlement beyond the app itself.
- **iOS 26.7–26.7.2 and 27.0–27.3 — `worse_query`.** It stages a symlink
  inside an App Group container the process actually carries, and asks
  containermanagerd to resolve it.

The group is **not** read from the embedded provisioning profile. `app_group.m`
(also from 3106) asks SecTask for
`com.apple.security.application-groups` on the running process, then tries every
group in that list and keeps the first whose container opens. A re-sign that
carries real groups therefore works even when the profile on disk is missing or
lists a different set. When the process carries no openable group the worse
route reports itself unavailable and Drift falls back to AirLift or the
protected-backup route instead of failing a run.
