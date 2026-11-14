# KernelDirect

Drift's kernel chain for the 内核直刷 channel (#319): iOS 17.0–17.7.x and
18.0–18.7.1.

The sources are taken verbatim from **QuinnTang74/3106**, directory
`ThreeOneOSSix/kexploit/`:

- `kexploit_opa334.m` / `.h` — the kernel r/w chain, including 3106's
  **longjmp** failure path (`kexploit_abort`): during the exploit phase a
  failure longjmps back to `kexploit_opa334()` and returns a failure code, so
  the app reports the failure instead of dying. (3105 and the unpatched
  FilzaSlop version call `exit()` on failure and are deliberately not used.)
- `krw.m` / `.h` — kernel read/write primitives.
- `kutils.m` / `.h` — process lookup (`proc_self`, `proc_find`, …).
- `offsets.m` / `.h` — the version-band × chip offset table. An unknown
  device is **not** silently mapped onto the oldest table entry; Drift refuses
  it in `KernelDirectPremise` before the chain is ever called.
- `sandbox_escape.m` / `.h` — patches this process's sandbox profile;
  `sandbox_access_is_active()` is the existing write-read-delete criterion.
- `vnode.m` / `.h`, `machine_info.h`, `xpaci.h` — support.

Licence: **GPL-3.0** (`LICENSE`, the upstream copy). Drift is AGPL-3.0; the
attribution is recorded in the repository's `NOTICE`.

Only the verification probe uses this module today: phase one of the
construction order runs the chain and the sandbox self-check and writes no
wallpaper. The write path lands in phase two.
