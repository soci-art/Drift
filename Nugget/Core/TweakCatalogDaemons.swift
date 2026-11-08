// GENERATED FILE — do not edit by hand.
//
// Source of truth: GoldenNugget's `src/tweaks/daemons_tweak.py` and the
// group tables in `src/gui/ios/daemons.py`.  Regenerate with:
//
//     scripts/gen-daemons-from-goldennugget.py [--goldennugget <path>]
//
// Daemons are not in `registry.py` -- upstream registers them in
// `load_daemons()` as a single `AdvancedPlistTweak` over the launchd
// `disabled.plist`, and builds the per-group switches in the GUI. One
// spec per group is what lets them ride the port's Apply, autosave and
// preset paths, all of which work off the catalog.

import Foundation

/// One switch on the Daemons page: a named group of launchd labels that
/// are disabled together.
///
/// `showsSwitch` is false for interface-visible groups upstream
/// gives no switch of its own (AppleAds, CrashReports, Diagnostics,
/// Feedback, SettingsStats, Shazam). They stay in the catalog -- they are
/// part of `INTERFACE_DAEMONS` and the Recommended set turns them on --
/// but the page must not offer a per-group switch for them.
struct DaemonGroup: Sendable {
    let name: String
    let title: String
    let labels: [String]
    let section: DaemonSection
    let isRecommended: Bool
    let showsSwitch: Bool
    /// The reference's row warning line (its `Risky tweaks` rows): the
    /// sentence the desktop shows under the title, e.g. what breaking
    /// thermal monitoring or ATWAKEUP costs. nil everywhere else.
    let information: String?
}

/// The two groups of switches on the Daemons page, in the reference's order.
enum DaemonSection: String, CaseIterable, Identifiable, Sendable {
    case disable = "要禁用的守护进程"
    case analytics = "分析、数据跟踪与日志"
    var id: String { rawValue }
}

enum DaemonGroups {
    static let all: [DaemonGroup] = [
        DaemonGroup(
            name: "OTA",
            title: "禁用 OTA 更新服务",
            labels: ["com.apple.mobile.softwareupdated", "com.apple.OTATaskingAgent", "com.apple.softwareupdateservicesd", "com.apple.mobile.NRDUpdated"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "UsageTrackingAgent",
            title: "禁用应用使用报告",
            labels: ["com.apple.UsageTrackingAgent"],
            section: .disable,
            isRecommended: true,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "GameCenter",
            title: "禁用 Game Center",
            labels: ["com.apple.gamed"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "Tips",
            title: "禁用提示建议",
            labels: ["com.apple.tipsd"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "VPN",
            title: "禁用 IPsec VPN 连接",
            labels: ["com.apple.racoon"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "ChineseLAN",
            title: "禁用 WAPI Wi-Fi 连接",
            labels: ["com.apple.wapic", "com.apple.wifi.wapic"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "HealthKit",
            title: "禁用健康数据服务",
            labels: ["com.apple.healthd"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "AirPrint",
            title: "禁用隔空打印",
            labels: ["com.apple.printd"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "AssistiveTouch",
            title: "禁用辅助触控",
            labels: ["com.apple.assistivetouchd"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "iCloud",
            title: "禁用云媒体服务",
            labels: ["com.apple.itunescloudd"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "InternetTethering",
            title: "禁用个人热点",
            labels: ["com.apple.MobileInternetSharing"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "PassBook",
            title: "禁用钱包凭证服务",
            labels: ["com.apple.passd"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "Spotlight",
            title: "禁用系统搜索更新",
            labels: ["com.apple.searchd", "com.apple.corespotlightservice", "com.apple.spotlightknowledged", "com.apple.spotlightknowledged.updater", "com.apple.spotlight.IndexAgent"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "VoiceControl",
            title: "禁用 Siri 和语音助手",
            labels: ["com.apple.assistant_service", "com.apple.assistantd", "com.apple.voiced"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "AppleAds",
            title: "禁用 Apple 广告服务",
            labels: ["com.apple.promotedcontentd", "com.apple.adprivacyd", "com.apple.adservicesd"],
            section: .disable,
            isRecommended: true,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "News",
            title: "禁用 Apple 新闻更新",
            labels: ["com.apple.newsd"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "FamilySharing",
            title: "禁用家人共享更新",
            labels: ["com.apple.familycircled", "com.apple.familynotificationd"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "VideoSubscriptions",
            title: "禁用电视提供商登录助手",
            labels: ["com.apple.videosubscriptionsd"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "WebBookmarks",
            title: "禁用 Safari 书签服务",
            labels: ["com.apple.webbookmarksd"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "WifiLogging",
            title: "禁用 Wi-Fi 问题日志",
            labels: ["com.apple.wifilogd"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "Maps",
            title: "禁用地图后台服务",
            labels: ["com.apple.geod"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "SafariSuggestions",
            title: "禁用在线搜索建议",
            labels: ["com.apple.parsecd"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "Reminders",
            title: "禁用提醒事项后台服务",
            labels: ["com.apple.reminderd"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "AirPlay",
            title: "禁用隔空播放服务",
            labels: ["com.apple.airplay"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "GameKitService",
            title: "禁用游戏服务助手",
            labels: ["com.apple.gamekitservice"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "Sidecar",
            title: "禁用随航显示助手",
            labels: ["com.apple.sidecarcore"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "SpeechRecognition",
            title: "禁用语音转文字助手",
            labels: ["com.apple.speechrecognition"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "MockLocation",
            title: "禁用测试位置",
            labels: ["com.apple.mocksynclocationd"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "Feedback",
            title: "禁用反馈后台任务",
            labels: ["com.apple.feedbackd"],
            section: .disable,
            isRecommended: true,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "SettingsStats",
            title: "禁用设置使用报告",
            labels: ["com.apple.settings-statsd"],
            section: .disable,
            isRecommended: true,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "Shazam",
            title: "禁用音乐识别",
            labels: ["com.apple.shazamd"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "FollowUp",
            title: "禁用账户提醒通知",
            labels: ["com.apple.followupd"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "Location",
            title: "禁用定位服务",
            labels: ["com.apple.locationd"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "thermalmonitord",
            title: "禁用温度监控",
            labels: ["com.apple.thermalmonitord"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true,
            information: "破坏温度监控；可能导致不稳定。"
        ),
        DaemonGroup(
            name: "ATWAKEUP",
            title: "禁用 ATWAKEUP 助手",
            labels: ["com.apple.atc.atwakeup"],
            section: .disable,
            isRecommended: false,
            showsSwitch: true,
            information: "据报告，禁用后佩戴 AirPods 时可能导致界面反复重启。"
        ),
        DaemonGroup(
            name: "Diagnostics",
            title: "禁用系统问题报告",
            labels: ["com.apple.diagnosticd", "com.apple.diagnosticextensionsd", "com.apple.diagnosticservicesd", "com.apple.diagnosticspushd", "com.apple.symptomsd-diag", "com.apple.sysdiagnose", "com.apple.sysdiagnose.darwinos", "com.apple.sysdiagnose_helper"],
            section: .analytics,
            isRecommended: true,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "CrashReports",
            title: "禁用崩溃报告和系统日志",
            labels: ["com.apple.ReportCrash", "com.apple.ReportCrash.Jetsam", "com.apple.ReportMemoryException", "com.apple.OTACrashCopier", "com.apple.aslmanager", "com.apple.coresymbolicationd", "com.apple.crash_mover", "com.apple.crashreportcopymobile", "com.apple.DumpBasebandCrash", "com.apple.DumpPanic", "com.apple.logd", "com.apple.logd.admin", "com.apple.logd.events", "com.apple.logd.watchdog", "com.apple.logd_helper", "com.apple.logd_reporter", "com.apple.logd_reporter.report_statistics", "com.apple.system.logger", "com.apple.hangreporter", "com.apple.hangtracerd", "com.apple.spindump", "com.apple.tailspind", "com.apple.syslogd", "com.apple.signpost.signpost_reporter", "com.apple.pluginkit.pkreporter", "com.apple.ProxiedCrashCopier", "com.apple.ProxiedCrashCopier.ProxyingDevice", "com.apple.ReportSystemMemory"],
            section: .analytics,
            isRecommended: false,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "WifiAnalytics",
            title: "禁用 Wi-Fi 使用报告",
            labels: ["com.apple.wifianalyticsd"],
            section: .analytics,
            isRecommended: true,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "AnalyticsHelper",
            title: "禁用系统使用报告",
            labels: ["com.apple.analyticsd", "com.apple.analyticsd.admin", "com.apple.analyticsd.events"],
            section: .analytics,
            isRecommended: true,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "AudioAnalytics",
            title: "禁用音频问题报告",
            labels: ["com.apple.audioanalyticsd"],
            section: .analytics,
            isRecommended: true,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "EcosystemAnalytics",
            title: "禁用跨设备使用报告",
            labels: ["com.apple.ecosystemanalyticsd"],
            section: .analytics,
            isRecommended: true,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "CallAnalytics",
            title: "禁用通话质量报告",
            labels: ["com.apple.rtcreportingd"],
            section: .analytics,
            isRecommended: false,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "CoreDuet",
            title: "禁用基于活动的建议",
            labels: ["com.apple.coreduetd"],
            section: .analytics,
            isRecommended: false,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "Insight",
            title: "禁用 Insight 助手",
            labels: ["com.apple.insightd"],
            section: .analytics,
            isRecommended: true,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "Metrics",
            title: "禁用系统测量报告",
            labels: ["com.apple.metricsd"],
            section: .analytics,
            isRecommended: true,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "MediaExperience",
            title: "禁用播放控制服务",
            labels: ["com.apple.mediaremoted"],
            section: .analytics,
            isRecommended: false,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "Symptomsd",
            title: "禁用网络健康报告",
            labels: ["com.apple.symptomsd", "com.apple.symptomsd-app"],
            section: .analytics,
            isRecommended: false,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "StatisticalDiagnostic",
            title: "禁用统计问题报告",
            labels: ["com.apple.StatisticalDiagnosticService"],
            section: .analytics,
            isRecommended: true,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "WirelessDiagnostics",
            title: "禁用无线故障排查",
            labels: ["com.apple.wirelessdiagnostics"],
            section: .analytics,
            isRecommended: true,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "DuetHeuristic",
            title: "禁用后台调度助手",
            labels: ["com.apple.DuetHeuristic-BM", "com.apple.DuetHeuristic-BM.Baseband"],
            section: .analytics,
            isRecommended: false,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "DuetExpert",
            title: "禁用活动预测助手",
            labels: ["com.apple.duetexpertd"],
            section: .analytics,
            isRecommended: false,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "Triald",
            title: "禁用 Apple 功能试验",
            labels: ["com.apple.triald"],
            section: .analytics,
            isRecommended: false,
            showsSwitch: true,
            information: nil
        ),
        DaemonGroup(
            name: "Sociald",
            title: "禁用社交账户助手",
            labels: ["com.apple.sociald"],
            section: .analytics,
            isRecommended: false,
            showsSwitch: true,
            information: nil
        ),
    ]

    /// The one-tap "Recommended" set: pure analytics, tracking and
    /// logging, nothing boot-critical.  Upstream's comment on
    /// `RECOMMENDED_ANALYTICS` says the same.
    static let recommended: [DaemonGroup] = all.filter(\.isRecommended)

    static let byName: [String: DaemonGroup] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })

    /// Every launchd label the reference will let a preset carry.  Mirrors
    /// `INTERFACE_KEYS`: a label outside this set must never reach the
    /// plist, because disabling those daemons broke whole apps on 26.5.
    static let allowedKeys: Set<String> = [
        "com.apple.DuetHeuristic-BM",
        "com.apple.DuetHeuristic-BM.Baseband",
        "com.apple.DumpBasebandCrash",
        "com.apple.DumpPanic",
        "com.apple.MobileInternetSharing",
        "com.apple.OTACrashCopier",
        "com.apple.OTATaskingAgent",
        "com.apple.ProxiedCrashCopier",
        "com.apple.ProxiedCrashCopier.ProxyingDevice",
        "com.apple.ReportCrash",
        "com.apple.ReportCrash.Jetsam",
        "com.apple.ReportMemoryException",
        "com.apple.ReportSystemMemory",
        "com.apple.StatisticalDiagnosticService",
        "com.apple.UsageTrackingAgent",
        "com.apple.adprivacyd",
        "com.apple.adservicesd",
        "com.apple.airplay",
        "com.apple.analyticsd",
        "com.apple.analyticsd.admin",
        "com.apple.analyticsd.events",
        "com.apple.aslmanager",
        "com.apple.assistant_service",
        "com.apple.assistantd",
        "com.apple.assistivetouchd",
        "com.apple.atc.atwakeup",
        "com.apple.audioanalyticsd",
        "com.apple.coreduetd",
        "com.apple.corespotlightservice",
        "com.apple.coresymbolicationd",
        "com.apple.crash_mover",
        "com.apple.crashreportcopymobile",
        "com.apple.diagnosticd",
        "com.apple.diagnosticextensionsd",
        "com.apple.diagnosticservicesd",
        "com.apple.diagnosticspushd",
        "com.apple.duetexpertd",
        "com.apple.ecosystemanalyticsd",
        "com.apple.familycircled",
        "com.apple.familynotificationd",
        "com.apple.feedbackd",
        "com.apple.followupd",
        "com.apple.gamed",
        "com.apple.gamekitservice",
        "com.apple.geod",
        "com.apple.hangreporter",
        "com.apple.hangtracerd",
        "com.apple.healthd",
        "com.apple.insightd",
        "com.apple.itunescloudd",
        "com.apple.locationd",
        "com.apple.logd",
        "com.apple.logd.admin",
        "com.apple.logd.events",
        "com.apple.logd.watchdog",
        "com.apple.logd_helper",
        "com.apple.logd_reporter",
        "com.apple.logd_reporter.report_statistics",
        "com.apple.mediaremoted",
        "com.apple.metricsd",
        "com.apple.mobile.NRDUpdated",
        "com.apple.mobile.softwareupdated",
        "com.apple.mocksynclocationd",
        "com.apple.newsd",
        "com.apple.parsecd",
        "com.apple.passd",
        "com.apple.pluginkit.pkreporter",
        "com.apple.printd",
        "com.apple.promotedcontentd",
        "com.apple.racoon",
        "com.apple.reminderd",
        "com.apple.rtcreportingd",
        "com.apple.searchd",
        "com.apple.settings-statsd",
        "com.apple.shazamd",
        "com.apple.sidecarcore",
        "com.apple.signpost.signpost_reporter",
        "com.apple.sociald",
        "com.apple.softwareupdateservicesd",
        "com.apple.speechrecognition",
        "com.apple.spindump",
        "com.apple.spotlight.IndexAgent",
        "com.apple.spotlightknowledged",
        "com.apple.spotlightknowledged.updater",
        "com.apple.symptomsd",
        "com.apple.symptomsd-app",
        "com.apple.symptomsd-diag",
        "com.apple.sysdiagnose",
        "com.apple.sysdiagnose.darwinos",
        "com.apple.sysdiagnose_helper",
        "com.apple.syslogd",
        "com.apple.system.logger",
        "com.apple.tailspind",
        "com.apple.thermalmonitord",
        "com.apple.tipsd",
        "com.apple.triald",
        "com.apple.videosubscriptionsd",
        "com.apple.voiced",
        "com.apple.wapic",
        "com.apple.webbookmarksd",
        "com.apple.wifi.wapic",
        "com.apple.wifianalyticsd",
        "com.apple.wifilogd",
        "com.apple.wirelessdiagnostics",
    ]

    /// `DANGEROUS_KEYS` upstream, which is empty by design: entries are
    /// deleted from the reference rather than blocked at runtime.  Kept so a
    /// future upstream entry shows up as a diff instead of silently
    /// becoming writable.
    static let dangerousKeys: Set<String> = [
    ]

    /// `TweakID.ClearScreenTimeAgentPlist`: a `NullifyFileTweak`, i.e. a
    /// 0-byte file written over the plist rather than a serialised dict.
    static let screenTime = DaemonNullify(
        id: "ClearScreenTimeAgentPlist",
        title: "禁用屏幕时间代理",
        path: "/var/mobile/Library/Preferences/com.apple.ScreenTimeAgent.plist"
    )
}

/// A file the port overwrites with zero bytes rather than serialising.
struct DaemonNullify: Sendable {
    let id: String
    let title: String
    let path: String
}

extension TweakCatalog {
    /// The daemon groups as tweak specs, so Apply, autosave and preset
    /// import all work on them unchanged.
    ///
    /// `multiValues` carries the group's labels mapped to `false`: a group is
    /// "on" when the user wants it disabled, and the compiler writes the
    /// labels of every on-group into the launchd `disabled.plist`.
    static let daemonSpecs: [TweakSpec] = DaemonGroups.all.map { group in
        TweakSpec(
            id: "Daemon.\(group.name)",
            section: .daemons,
            title: group.title,
            location: .disabledDaemons,
            key: "",
            value: .bool(false),
            kind: .toggle,
            minValue: 0.0,
            maxValue: 1.0,
            step: 1.0,
            minVersion: nil,
            maxVersion: nil,
            iphoneOnly: false,
            ipadOnly: false,
            disabled: false,
            detail: group.information ?? "禁用 \(group.labels.count) 个 launchd 守护进程："
                + group.labels.joined(separator: "、") + "。",
            multiValues: Dictionary(
                uniqueKeysWithValues: group.labels.map { ($0, TweakValue.bool(false)) }
            )
        )
    }

    /// The ScreenTime nullify, which is not a daemon group and so has no
    /// `multiValues`: it truncates a file instead of writing a dict.
    static let screenTimeSpec = TweakSpec(
        id: "\(DaemonGroups.screenTime.id)",
        section: .daemons,
        title: "\(DaemonGroups.screenTime.title)",
        location: .screentime,
        key: "",
        value: .bool(false),
        kind: .toggle,
        minValue: 0.0,
        maxValue: 1.0,
        step: 1.0,
        minVersion: nil,
        maxVersion: nil,
        iphoneOnly: false,
        ipadOnly: false,
        disabled: false,
        detail: "在 \(DaemonGroups.screenTime.path) 上覆盖写入一个 0 字节文件。",
        multiValues: nil
    )
}
