import SwiftUI
import DesignSystem
import StorageKit
import AppLockKit
import AdBlockKit
import BrowserKit
import YouTubeKit

struct SettingsScreen: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var appLock: AppLockService
    @EnvironmentObject private var adBlock: AdBlockService
    @EnvironmentObject private var browser: BrowserController
    @EnvironmentObject private var youtube: YouTubePlaybackService
    @State private var passcodeInput = ""
    @State private var showPasscodeAlert = false
    @State private var lockMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section("应用锁") {
                    Toggle("启用 App Lock", isOn: Binding(
                        get: { settings.settings.appLockEnabled },
                        set: { enabled in
                            settings.update { $0.appLockEnabled = enabled }
                            if enabled {
                                if !appLock.isPasscodeSet {
                                    showPasscodeAlert = true
                                } else {
                                    appLock.lock()
                                }
                            } else {
                                // Keep passcode stored but stop locking.
                            }
                        }
                    ))
                    Toggle("切到后台后锁定", isOn: Binding(
                        get: { settings.settings.lockOnBackground },
                        set: { value in settings.update { $0.lockOnBackground = value } }
                    ))
                    Picker("锁定宽限", selection: Binding(
                        get: { settings.settings.lockGraceSeconds },
                        set: { value in settings.update { $0.lockGraceSeconds = value } }
                    )) {
                        Text("立即").tag(0)
                        Text("1 分钟").tag(60)
                        Text("5 分钟").tag(300)
                    }
                    Button(appLock.isPasscodeSet ? "更新解锁密码" : "设置解锁密码") {
                        showPasscodeAlert = true
                    }
                    if appLock.isPasscodeSet {
                        Button("清除密码并关闭锁定", role: .destructive) {
                            appLock.clearPasscode()
                            settings.update { $0.appLockEnabled = false }
                        }
                    }
                    if let lockMessage {
                        Text(lockMessage).font(.caption).foregroundStyle(ABColor.danger)
                    }
                }

                Section("广告拦截") {
                    Toggle("启用页面广告拦截", isOn: Binding(
                        get: { settings.settings.adBlockEnabled },
                        set: { value in
                            settings.update { $0.adBlockEnabled = value }
                            Task { await browser.refreshContentRules() }
                        }
                    ))
                    HStack {
                        Text("本会话拦截")
                        Spacer()
                        Text("\(adBlock.blockedThisSession)")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("规则版本")
                        Spacer()
                        Text(adBlock.pack.version)
                            .foregroundStyle(.secondary)
                    }
                    Button("恢复内置规则包") {
                        adBlock.reloadBundledRules()
                        Task { await browser.refreshContentRules() }
                    }
                }

                Section("YouTube") {
                    Toggle("增强播放", isOn: Binding(
                        get: { settings.settings.youtubeEnhancedPlayback },
                        set: { value in settings.update { $0.youtubeEnhancedPlayback = value } }
                    ))
                    HStack {
                        Text("临时缓存占用")
                        Spacer()
                        Text(ByteFormat.string(from: youtube.cacheUsageBytes))
                            .foregroundStyle(.secondary)
                    }
                    Stepper(
                        "TTL \(settings.settings.youtubeCacheTTLHours) 小时",
                        value: Binding(
                            get: { settings.settings.youtubeCacheTTLHours },
                            set: { value in settings.update { $0.youtubeCacheTTLHours = value } }
                        ),
                        in: 6...168,
                        step: 6
                    )
                    Button("清除 YouTube 临时缓存", role: .destructive) {
                        youtube.clearTemporaryCache()
                    }
                    Text("临时缓存仅用于流畅播放，不可导出或作为离线下载。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("浏览") {
                    Toggle("默认桌面版请求", isOn: Binding(
                        get: { settings.settings.desktopModeDefault },
                        set: { value in settings.update { $0.desktopModeDefault = value } }
                    ))
                    Button("清空历史记录", role: .destructive) {
                        browser.history.clear()
                    }
                }

                Section("关于") {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text("1.0.0")
                            .foregroundStyle(.secondary)
                    }
                    Text("AllBrowser — 隐私浏览与本地媒体中枢")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("我的")
            .alert("设置解锁密码", isPresented: $showPasscodeAlert) {
                SecureField("至少 4 位", text: $passcodeInput)
                    .keyboardType(.numberPad)
                Button("保存") {
                    do {
                        try appLock.setPasscode(passcodeInput)
                        settings.update { $0.appLockEnabled = true }
                        lockMessage = nil
                        passcodeInput = ""
                        appLock.lock()
                    } catch {
                        lockMessage = error.localizedDescription
                    }
                }
                Button("取消", role: .cancel) {
                    passcodeInput = ""
                    if !appLock.isPasscodeSet {
                        settings.update { $0.appLockEnabled = false }
                    }
                }
            } message: {
                Text("密码保存在本机 Keychain，用于 Face ID 不可用时解锁。")
            }
        }
    }
}
