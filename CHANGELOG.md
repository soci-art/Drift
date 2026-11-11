# Drift 3.0.1

- 本机直刷定位修复：不再把「应用容器根目录」的沙盒扩展当门槛，先 pathleak 逐容器查找，根目录扩展只作可选加速；consume/withAccess 失败不再静默吞掉，日志带路径、组名与返回码。
- 刷入记录合并为一张列表（运行记录 + 本机/隧道回执，按时间倒序），新增「清空记录」；只清 ApplyHistory，不动回执。
- 新增「管理刷入的壁纸」页面：只列有回执的条目，按通道对账与删除；隧道删除需配对 + LocalDevVPN + 设备可读，本机删除走现有商店删除；不自动注销或重启。
- 回执结构增加 channel：本机直刷 / 免注销直刷 / 注销直刷；3.0.0 的旧回执缺字段按本机直刷解码。隧道回执只在写后核验通过时记录。
- 隧道商店原语只覆盖合集类 provider；其他 provider 的回执显示「暂不支持核对/删除」。3.0.0 及更早的隧道刷入没有回执，不在管理范围。
- 恢复刷仍封存。

# Drift 3.0.0

- 刷入方式四项定版：自动选择 / 免注销直刷 / 注销直刷 / 本机直刷；三条通道独立写入与生效，手动选定后不可用不替换。
- 免注销直刷刷新未确认只提示并可手动注销；注销直刷重新独立。
- 本机直刷按 3106 实现重做：真实代际扫描、描述符自报落点、暂存校验 + 原子改名 + fsync、三处标识重写、Mercury 保留原名；不写偏好文件与 sqlite。
- 本机直刷生效改为「上滑关闭 PosterBoard」；新增写入回执与按回执删除。
- 本机直刷范围扩到 27.2.1 与 27.3 测试版 1（24C5037i，实验）。
- 刷入记录分开记所选方式、实际通道、生效方式与核验结论。
- 源码目录与引擎标识统一为 Drift；界面与发行说明不再出现第三方应用名。
- 恢复刷仍封存。

# GoldenNugget Mobile — Desktop 9.7.2 Sync

## HotLoad and updates

- Port HotLoad safety rules with offline caching, device/app version scopes, feature hiding, daemon overrides, warnings and mandatory-update gates.
- Check mobile GitHub releases automatically and from Settings, with release notes and IPA download links.
- Keep rule and release channels specific to GoldenNugget Mobile. Install updates using the existing sideloading workflow.

## General

- Add experimental Siri AI eligibility overrides for unsupported regions, plus a dedicated reset. Available on iPhones running iOS 27.x; upstream verification covers only iPhone 16 Pro, build 24A437. Requires Siri language English (US), an unencrypted protective backup, and a reboot.
- Expand the preference catalog to 258 tweaks, including a 60 FPS limit and the replacement Home Screen search setting for iOS 27.1+.
- Remove obsolete Apple Watch, NanoTimeKit, Translate, DeviceCheck and Decisiond daemon controls, matching desktop's 53 groups.
- Mirror managed preferences into HomeDomain on iOS 27; reset both copies with valid empty plists on every supported iOS version.
- Validate the complete AFC media inventory before restore and keep originals that change during copying. Incomplete restores report a failure while keeping local copies.
- Show untested catalog markers, import standalone community templates from Templates, and link to Batter Builder.
- Add an option to enable untested preference tweaks on iOS 26. Hardware restrictions and the stricter Siri AI requirements remain enforced.
- Improve iOS 27 network badges and cellular signal controls, including separate SIM settings and explicit zero-bar overrides.

## Media

- Copy the device's photos and videos into the app container automatically when the setup guide is finished, and top the copy up once per launch afterwards. Only files that changed are streamed again, so a launch costs a directory walk rather than a second copy of the library.
- Add a **Restore media** button to the home page, next to the counts of what the container holds, which writes every kept photo and video back to the device and verifies each one. The Media page keeps its manual survey, pull and empty tools. The automatic copy never deletes originals; that stays behind the Media page's own switch.
- Skip a media stage that would collide with an automatic copy in progress instead of reporting a failure, so an apply still runs while photos are being copied.

## PosterBoard

- Fix Full Reset failing with a `sqlite_sequence` error on empty databases.
- Deliver the PosterBoard database in WAL mode, which is the mode the device's own store declares — including the empty store a Full Reset installs. PosterBoard opens the store read-only and immediately runs `PRAGMA journal_mode=WAL`; on a DELETE-mode database that pragma is a write and fails with "attempt to write a readonly database", after which the store logs "data store never ever initialized" and rebuilds itself from the gallery. Every wallpaper got a new identity, and anything whose content lives only in the store — every custom wallpaper — disappeared. The snapshot is still self-contained: its pages are checkpointed into the main file and the `-wal`/`-shm` the restore carries stay zero-byte companions.
- Preserve native PosterBoard snapshots and manifest metadata when applying wallpaper changes.
- Deliver each wallpaper once, as the installed configuration the device's own store holds. A second copy under `Extensions/com.apple.Posters.CollectionsPosterApp/descriptors/` gave the store a duplicate identity it could not reconcile, and rebuilding the database is how it settled that — every wallpaper gone.
- Import only the applied wallpaper's own manifest rows and those of its parent directories. Directory records are instructions to place a directory, so re-importing the whole container's tree told the device to recreate directories whose files the restore never carried.
- Improve handling of damaged or invalid `.tendies` ZIP archives with readable import errors.

## UI

- Replace the phone's burger menu with the platform's tab bar: Home, Tweaks, Wallpapers, Media and a grouped **More** list for the remaining pages. The iPad keeps its sidebar, where both columns fit.
- Merge the Daemons page into Tweaks behind a Tweaks / Daemons switch, so one selection, one autosave and one Apply cover both halves.
- Trim the home page to the run: one line under Apply, a single folded row for pairing and the tunnel, a compact media card, and a one-sentence reset. The diagnostics dump and its share rows moved to Settings → Logs.
- Browse tweaks and daemon groups in collapsible categories using the native SwiftUI interface.
- Show experimental warnings, hardware requirements, and conflicting-tweak restrictions before applying changes.
- Ask for a cellular signal override when status-bar modifications are first enabled.

## Fixes

- Preserve loaded preset selections after restart when autosave is enabled, including explicit experimental rollback values.
- Apply iOS 26 compatibility preferences consistently when browsing, importing presets, previewing, and compiling tweaks.
- Improve daemon configuration, reject unknown daemon labels, and match desktop OTA preference cleanup during reset.
- Refuse Siri AI delivery through forced Partial Restore or an encrypted protective backup.
- Retain the mobile AirLift availability restriction from iOS 27.2 beta 3 onward.
- Bound the Rust diagnostic log and reclaim oversized ones at launch. A two-hour backup could write 18.7 GB into `minimuxer.log`, which left too little free space on the volume the device checks before uploading, so later backups offered zero files.
- Scan the diagnostic logs for leftover pairing secrets without the byte-by-byte walk that could not finish inside the launch allowance. A 54 MB `minimuxer.log` took 58 s in a Debug build, so iOS killed the app with a scene-create watchdog on every launch; the same scan is now 0.1 s and still finds a dump at the end of the file.
- Answer the device's disk-purge request instead of replying "not supported", and report the device's own refusal code. Free-space refusals now name the volume's free space rather than blaming the keep-filter.
- Make Stop work during a PosterBoard database fetch. That upload ran outside the stall watcher, which is the only thing that polls the stop flag, so the button reported "stop requested" and nothing happened.

Siri AI activation and restore have not yet been verified on a physical device with the mobile app. Reset Siri AI Overrides clears all eligibility overrides, including those installed by other tools; turning the enable switch off does not undo an applied override.
