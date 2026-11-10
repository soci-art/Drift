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
tunnel; this one does not, which is why it also works on iOS 26.0 – 26.1 and on
27.2 builds where AirLift is blocked.

## Requirement: an App Group entitlement

`worse_query` is not an entitlement bypass. It stages a symlink inside an App
Group container the app is entitled to, and asks containermanagerd to resolve
it — so the app's signing profile must contain
`com.apple.security.application-groups` with the identifier Drift asks for
(`group.com.sociart.drift`, see `Nugget/Core/WorseQuery.swift`).

In practice that means a paid Apple Developer account: free "personal team"
profiles cannot register App Groups. A sideloaded build survives, because the
signer applies its own profile's entitlements; when the group is absent the
mode reports itself unavailable and Drift falls back to AirLift or the
protected-backup route instead of failing a run.
