import AppKit
import ApplicationServices
import Carbon
import Foundation

struct AgentConfig: Codable {
    var defaultInputSourceID: String?
    var appInputSources: [String: String]
    var logSwitches: Bool?
    var forceAsciiNumpad: Bool?
    var numpadAsciiSpeedMode: String?
    var instantCapsLockSwitch: Bool?
    var autoSwitchEnabled: Bool?

    static func fallback() -> AgentConfig {
        AgentConfig(
            defaultInputSourceID: "com.apple.keylayout.ABC",
            appInputSources: [:],
            logSwitches: false,
            forceAsciiNumpad: false,
            numpadAsciiSpeedMode: NumpadAsciiSpeedMode.fast.rawValue,
            instantCapsLockSwitch: false,
            autoSwitchEnabled: true
        )
    }
}

enum DeveloperFeatureFlags {
    private static let capsLockExperimentDefaultsKey = "InputMethodAgentShowCapsLockExperiment"
    private static let capsLockExperimentEnvironmentKey = "INPUT_METHOD_AGENT_SHOW_CAPS_LOCK_EXPERIMENT"

    static var showCapsLockExperiment: Bool {
        UserDefaults.standard.bool(forKey: capsLockExperimentDefaultsKey)
            || ProcessInfo.processInfo.environment[capsLockExperimentEnvironmentKey] == "1"
    }

    static func capsLockEnabled(in config: AgentConfig) -> Bool {
        showCapsLockExperiment && config.instantCapsLockSwitch == true
    }

    static func configWithHiddenExperimentsDisabled(_ config: AgentConfig) -> AgentConfig {
        guard !showCapsLockExperiment else {
            return config
        }

        var copy = config
        copy.instantCapsLockSwitch = false
        return copy
    }
}

struct InputSourceInfo {
    let id: String
    let name: String
}

struct AppRule {
    let bundleID: String
    var displayName: String
    var inputSourceID: String?
    var icon: NSImage?
}

struct AutoSwitchRuntimeStatus {
    let isEnabled: Bool
    let isPaused: Bool
    let pauseRemainingSeconds: TimeInterval?
}

enum CapsLockSystemSwitchPreference {
    private static let systemKey = "TISRomanSwitchState"
    private static let savedValueKey = "InputMethodAgentSavedTISRomanSwitchState"
    private static let savedHadValueKey = "InputMethodAgentSavedTISRomanSwitchStateHadValue"
    private static let managedKey = "InputMethodAgentManagesTISRomanSwitchState"

    static func applyManagedState(enabled: Bool) {
        if enabled {
            disableSystemCapsLockSwitchPreservingCurrentValue()
        } else {
            restoreSystemCapsLockSwitchIfNeeded()
        }
    }

    private static func disableSystemCapsLockSwitchPreservingCurrentValue() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: managedKey) {
            if let currentValue = currentSystemValue() {
                defaults.set(currentValue, forKey: savedValueKey)
                defaults.set(true, forKey: savedHadValueKey)
            } else {
                defaults.removeObject(forKey: savedValueKey)
                defaults.set(false, forKey: savedHadValueKey)
            }
            defaults.set(true, forKey: managedKey)
        }

        setSystemValue(0)
    }

    private static func restoreSystemCapsLockSwitchIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: managedKey) else {
            return
        }

        if defaults.bool(forKey: savedHadValueKey) {
            setSystemValue(defaults.integer(forKey: savedValueKey))
        } else {
            removeSystemValue()
        }

        defaults.removeObject(forKey: savedValueKey)
        defaults.removeObject(forKey: savedHadValueKey)
        defaults.removeObject(forKey: managedKey)
    }

    private static func currentSystemValue() -> Int? {
        guard let value = CFPreferencesCopyAppValue(systemKey as CFString, kCFPreferencesAnyApplication) else {
            return nil
        }

        if CFGetTypeID(value) == CFNumberGetTypeID() {
            return value as? Int
        }

        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((value as! CFBoolean)) ? 1 : 0
        }

        return nil
    }

    private static func setSystemValue(_ value: Int) {
        CFPreferencesSetAppValue(systemKey as CFString, value as CFPropertyList, kCFPreferencesAnyApplication)
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
    }

    private static func removeSystemValue() {
        CFPreferencesSetAppValue(systemKey as CFString, nil, kCFPreferencesAnyApplication)
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
    }
}

final class FrontmostApplicationTracker: NSObject {
    private var recentApplication: NSRunningApplication?

    override init() {
        super.init()
        recentApplication = Self.externalFrontmostApplication()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeApplicationDidChange(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func currentApplication() -> NSRunningApplication? {
        if let app = Self.externalFrontmostApplication() {
            recentApplication = app
        }
        return recentApplication
    }

    @objc private func activeApplicationDidChange(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              Self.isTrackableApplication(app) else {
            return
        }
        recentApplication = app
    }

    private static func externalFrontmostApplication() -> NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              isTrackableApplication(app) else {
            return nil
        }
        return app
    }

    private static func isTrackableApplication(_ app: NSRunningApplication) -> Bool {
        app.processIdentifier != ProcessInfo.processInfo.processIdentifier
            && app.activationPolicy == .regular
            && app.bundleIdentifier != "com.apple.systemuiserver"
    }
}

enum SystemKeyboardState {
    static var isCapsLockOn: Bool {
        CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
    }
}

struct WorkflowStatusSnapshot {
    let appName: String
    let isCapsLockOn: Bool
    let appStatus: String
    let currentInputSourceID: String?
    let currentInputSourceName: String
    let currentInputStatus: String
    let ruleDescription: String
    let targetInputSourceID: String?
    let targetInputSourceName: String?
    var numpadStatus: String = "關閉"

    var needsInputSwitch: Bool {
        guard let targetInputSourceID,
              let currentInputSourceID else {
            return false
        }
        return targetInputSourceID != currentInputSourceID
    }
}

private func inputSourceDisplayName(_ source: InputSourceInfo) -> String {
    if source.id == "com.apple.inputmethod.TCIM.Zhuyin" || source.name == "Zhuyin - Traditional" {
        return "繁體注音"
    }

    return source.name
}

private func inputSourceName(for id: String, inputSources: [InputSourceInfo]) -> String {
    if let source = inputSources.first(where: { $0.id == id }) {
        return inputSourceDisplayName(source)
    }

    return id
}

private func hasMissingWorkflowPermissions() -> Bool {
    !NumpadAsciiEnforcer.isAccessibilityTrusted(prompt: false)
        || !NumpadAsciiEnforcer.hasListenEventAccess()
        || !NumpadAsciiEnforcer.hasPostEventAccess()
}

private func workflowStatusSnapshot(
    config: AgentConfig,
    inputSources: [InputSourceInfo],
    inputSourceManager: InputSourceManager,
    appTracker: FrontmostApplicationTracker
) -> WorkflowStatusSnapshot {
    let app = appTracker.currentApplication()
    let bundleID = app?.bundleIdentifier
    let appName = app?.localizedName ?? "等待切換中"
    let appStatus = "目前 App：\(appName)"

    let currentInputSourceID = inputSourceManager.currentInputSourceID()
    let currentInputSourceName = currentInputSourceID.map { inputSourceName(for: $0, inputSources: inputSources) } ?? "尚未偵測"
    let isCapsLockOn = SystemKeyboardState.isCapsLockOn
    let currentInputStatus = isCapsLockOn
        ? "目前輸入法：\(currentInputSourceName)（Caps Lock 開啟）"
        : "目前輸入法：\(currentInputSourceName)"

    let targetInputSourceID: String?
    let ruleDescription: String
    if let bundleID {
        if let appInputSourceID = config.appInputSources[bundleID] {
            targetInputSourceID = appInputSourceID
            ruleDescription = inputSourceName(for: appInputSourceID, inputSources: inputSources)
        } else if let defaultInputSourceID = config.defaultInputSourceID {
            targetInputSourceID = defaultInputSourceID
            ruleDescription = "全域預設（\(inputSourceName(for: defaultInputSourceID, inputSources: inputSources))）"
        } else {
            targetInputSourceID = nil
            ruleDescription = "全域預設（未設定）"
        }
    } else {
        targetInputSourceID = nil
        ruleDescription = "尚未啟用"
    }

    let targetInputSourceName = targetInputSourceID.map { inputSourceName(for: $0, inputSources: inputSources) }

    return WorkflowStatusSnapshot(
        appName: appName,
        isCapsLockOn: isCapsLockOn,
        appStatus: appStatus,
        currentInputSourceID: currentInputSourceID,
        currentInputSourceName: currentInputSourceName,
        currentInputStatus: currentInputStatus,
        ruleDescription: ruleDescription,
        targetInputSourceID: targetInputSourceID,
        targetInputSourceName: targetInputSourceName
    )
}


enum NumpadAsciiSpeedMode: String, CaseIterable {
    case fast
    case stable

    static func resolved(from rawValue: String?) -> NumpadAsciiSpeedMode {
        rawValue.flatMap(NumpadAsciiSpeedMode.init(rawValue:)) ?? .fast
    }

    var title: String {
        switch self {
        case .fast:
            return "快速"
        case .stable:
            return "穩定"
        }
    }
}

extension Notification.Name {
    static let agentConfigChanged = Notification.Name("InputMethodAgentConfigChanged")
    static let numpadAsciiStatusChanged = Notification.Name("InputMethodAgentNumpadAsciiStatusChanged")
    static let agentRuntimeStatusChanged = Notification.Name("InputMethodAgentRuntimeStatusChanged")
}

enum AgentError: LocalizedError {
    case configNotFound(URL)
    case invalidConfig(URL, Error)
    case inputSourceNotFound(String)
    case switchFailed(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .configNotFound(let url):
            return "Config file not found: \(url.path)"
        case .invalidConfig(let url, let error):
            return "Could not read config at \(url.path): \(error.localizedDescription)"
        case .inputSourceNotFound(let id):
            return "Input source not found: \(id)"
        case .switchFailed(let id, let status):
            return "Could not switch to input source \(id). OSStatus: \(status)"
        }
    }
}

final class ConfigStore {
    let url: URL
    private(set) var config: AgentConfig

    init(url: URL) {
        self.url = url
        self.config = (try? Self.load(from: url)) ?? AgentConfig.fallback()
    }

    func update(_ newConfig: AgentConfig) throws {
        config = newConfig
        try save()
        NotificationCenter.default.post(name: .agentConfigChanged, object: self)
    }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(config)

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    static func load(from url: URL) throws -> AgentConfig {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AgentError.configNotFound(url)
        }

        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(AgentConfig.self, from: data)
        } catch {
            throw AgentError.invalidConfig(url, error)
        }
    }
}

final class InputSourceManager {
    func currentInputSourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }

        return stringProperty(source, key: kTISPropertyInputSourceID)
    }

    func availableInputSources() -> [InputSourceInfo] {
        let properties: [String: Any] = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceIsSelectCapable as String: true
        ]

        guard let rawSources = TISCreateInputSourceList(properties as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }

        return rawSources.compactMap { source in
            guard let id = stringProperty(source, key: kTISPropertyInputSourceID) else {
                return nil
            }

            let name = stringProperty(source, key: kTISPropertyLocalizedName) ?? "(Unnamed)"
            return InputSourceInfo(id: id, name: name)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func selectInputSource(id: String) throws {
        guard let source = inputSource(withID: id) else {
            throw AgentError.inputSourceNotFound(id)
        }

        let status = TISSelectInputSource(source)
        guard status == noErr else {
            throw AgentError.switchFailed(id, status)
        }
    }

    private func inputSource(withID id: String) -> TISInputSource? {
        let properties: [String: Any] = [
            kTISPropertyInputSourceID as String: id
        ]

        guard let sources = TISCreateInputSourceList(properties as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource] else {
            return nil
        }

        return sources.first
    }

    private func stringProperty(_ source: TISInputSource, key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else {
            return nil
        }

        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
}

final class InputMethodAgent: NSObject {
    private static let followUpApplyDelay: TimeInterval = 0.25

    private let configProvider: () -> AgentConfig
    private let inputSources: InputSourceManager
    private var pausedUntil: Date?
    private var followUpApplyWorkItem: DispatchWorkItem?

    init(configProvider: @escaping () -> AgentConfig, inputSources: InputSourceManager) {
        self.configProvider = configProvider
        self.inputSources = inputSources
        super.init()
    }

    var isPaused: Bool {
        pruneExpiredPause()
        return pausedUntil != nil
    }

    var pauseRemainingSeconds: TimeInterval? {
        pruneExpiredPause()
        guard let pausedUntil else {
            return nil
        }

        return max(0, pausedUntil.timeIntervalSinceNow)
    }

    var pauseStatusText: String {
        pruneExpiredPause()
        guard let remainingSeconds = pauseRemainingSeconds else {
            return "自動切換中"
        }

        return "已暫停，剩餘 \(Self.durationText(remainingSeconds))"
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.up)))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    func startMonitoring() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeApplicationDidChange(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        let app = NSWorkspace.shared.frontmostApplication
        applyRule(for: app)
        scheduleFollowUpApply(for: app)
    }

    func pause(for interval: TimeInterval) {
        pausedUntil = Date().addingTimeInterval(interval)
        postRuntimeStatusChanged()
    }

    func resume() {
        pausedUntil = nil
        let app = NSWorkspace.shared.frontmostApplication
        postRuntimeStatusChanged()
        applyRule(for: app)
        scheduleFollowUpApply(for: app)
    }

    func refreshAfterConfigChange() {
        if configProvider().autoSwitchEnabled == false {
            pausedUntil = nil
        }
        let app = NSWorkspace.shared.frontmostApplication
        postRuntimeStatusChanged()
        applyRule(for: app)
        scheduleFollowUpApply(for: app)
    }

    @objc private func activeApplicationDidChange(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        applyRule(for: app)
        scheduleFollowUpApply(for: app)
    }

    private func pruneExpiredPause() {
        if let pausedUntil, pausedUntil <= Date() {
            self.pausedUntil = nil
            postRuntimeStatusChanged()
        }
    }

    private func shouldSkipAutomation(config: AgentConfig) -> Bool {
        guard config.autoSwitchEnabled != false else {
            return true
        }

        pruneExpiredPause()
        return pausedUntil != nil
    }

    private func postRuntimeStatusChanged() {
        NotificationCenter.default.post(name: .agentRuntimeStatusChanged, object: self)
    }

    private func applyRule(for app: NSRunningApplication?, force: Bool = false) {
        let config = configProvider()
        guard !shouldSkipAutomation(config: config) else {
            return
        }

        guard let bundleID = app?.bundleIdentifier else {
            return
        }

        guard let desiredInputSourceID = config.appInputSources[bundleID] ?? config.defaultInputSourceID else {
            return
        }

        if !force && desiredInputSourceID == inputSources.currentInputSourceID() {
            postRuntimeStatusChanged()
            return
        }

        do {
            try inputSources.selectInputSource(id: desiredInputSourceID)
            postRuntimeStatusChanged()

            if config.logSwitches == true {
                let appName = app?.localizedName ?? bundleID
                print("[input-method-agent] \(appName) (\(bundleID)) -> \(desiredInputSourceID)")
            }
        } catch {
            fputs("[input-method-agent] \(error.localizedDescription)\n", stderr)
        }
    }

    private func scheduleFollowUpApply(for app: NSRunningApplication?) {
        followUpApplyWorkItem?.cancel()

        guard let bundleID = app?.bundleIdentifier else {
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }

            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID else {
                return
            }

            self.applyRule(for: NSWorkspace.shared.frontmostApplication, force: true)
        }

        followUpApplyWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.followUpApplyDelay, execute: workItem)
    }
}

final class NumpadAsciiEnforcer {
    private static let abcInputSourceID = "com.apple.keylayout.ABC"
    private static let syntheticEventMarker: Int64 = 0x494D414E554D5044

    private let configProvider: () -> AgentConfig
    private let inputSources: InputSourceManager
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private static let syntheticKeySpacing: TimeInterval = 0.012

    private var restoreWorkItem: DispatchWorkItem?
    private var sourceToRestore: String?
    private var suppressedOriginalKeyUps = Set<Int>()
    private var nextSyntheticKeyPostDate = Date.distantPast

    private struct Timing {
        let repostDelay: TimeInterval
        let firstRepostAfterSwitchDelay: TimeInterval
        let restoreDelay: TimeInterval
    }

    init(configProvider: @escaping () -> AgentConfig, inputSources: InputSourceManager) {
        self.configProvider = configProvider
        self.inputSources = inputSources
    }

    deinit {
        stop()
    }

    static func isAccessibilityTrusted(prompt: Bool) -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func hasListenEventAccess() -> Bool {
        CGPreflightListenEventAccess()
    }

    static func requestListenEventAccess() -> Bool {
        CGRequestListenEventAccess()
    }

    static func hasPostEventAccess() -> Bool {
        CGPreflightPostEventAccess()
    }

    static func requestPostEventAccess() -> Bool {
        CGRequestPostEventAccess()
    }

    static func requestKeyboardPermissions() {
        _ = isAccessibilityTrusted(prompt: true)
        if !hasListenEventAccess() {
            _ = requestListenEventAccess()
        }
        if !hasPostEventAccess() {
            _ = requestPostEventAccess()
        }
    }

    func refresh() {
        if configProvider().forceAsciiNumpad == true {
            start()
        } else {
            stop()
            Self.postStatus("數字鍵盤：已關閉")
        }
    }

    private func start() {
        guard eventTap == nil else {
            Self.postStatus("數字鍵盤：攔截已啟動")
            return
        }

        guard Self.isAccessibilityTrusted(prompt: false) else {
            Self.postStatus("數字鍵盤：缺少輔助使用權限")
            return
        }

        guard Self.hasListenEventAccess() else {
            Self.postStatus("數字鍵盤：缺少輸入監控權限")
            return
        }

        guard Self.hasPostEventAccess() else {
            Self.postStatus("數字鍵盤：缺少輔助使用權限")
            return
        }

        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let enforcer = Unmanaged<NumpadAsciiEnforcer>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return enforcer.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Self.postStatus("數字鍵盤：事件攔截啟動失敗")
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            Self.postStatus("數字鍵盤：事件攔截來源建立失敗")
            return
        }

        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Self.postStatus("數字鍵盤：攔截已啟動，等待右側數字鍵")
    }

    private func stop() {
        restoreWorkItem?.cancel()
        restoreWorkItem = nil
        sourceToRestore = nil
        suppressedOriginalKeyUps.removeAll()
        nextSyntheticKeyPostDate = .distantPast

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }

        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }

        eventTap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            Self.postStatus("數字鍵盤：事件攔截被系統暫停，已重新啟用")
            return Unmanaged.passUnretained(event)
        }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyUp, suppressedOriginalKeyUps.remove(keyCode) != nil {
            return nil
        }

        guard configProvider().forceAsciiNumpad == true,
              type == .keyDown,
              event.getIntegerValueField(.eventSourceUserData) != Self.syntheticEventMarker,
              shouldRewrite(event: event, keyCode: keyCode) else {
            return Unmanaged.passUnretained(event)
        }

        if sourceToRestore != nil {
            suppressedOriginalKeyUps.insert(keyCode)
            let scheduledDelay = repostNumpadKey(keyCode: keyCode)
            scheduleRestore(after: scheduledDelay + timing().restoreDelay)
            return nil
        }

        guard let currentInputSourceID = inputSources.currentInputSourceID(),
              currentInputSourceID != Self.abcInputSourceID else {
            Self.postStatus("數字鍵盤：目前已是 ABC，keyCode \(keyCode) 放行")
            return Unmanaged.passUnretained(event)
        }

        sourceToRestore = currentInputSourceID
        do {
            try inputSources.selectInputSource(id: Self.abcInputSourceID)
            suppressedOriginalKeyUps.insert(keyCode)
            let scheduledDelay = repostNumpadKey(
                keyCode: keyCode,
                minimumDelay: timing().firstRepostAfterSwitchDelay
            )
            scheduleRestore(after: scheduledDelay + timing().restoreDelay)
            return nil
        } catch {
            sourceToRestore = nil
            Self.postStatus("數字鍵盤：切到 ABC 失敗")
            fputs("[input-method-agent] Could not force ABC for numpad: \(error.localizedDescription)\n", stderr)
            return Unmanaged.passUnretained(event)
        }
    }

    private func shouldRewrite(event: CGEvent, keyCode: Int) -> Bool {
        let flags = event.flags
        guard !flags.contains(.maskCommand),
              !flags.contains(.maskControl),
              !flags.contains(.maskAlternate) else {
            return false
        }

        switch keyCode {
        case 65, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92:
            return true
        default:
            return false
        }
    }

    private func repostNumpadKey(keyCode: Int, minimumDelay: TimeInterval? = nil) -> TimeInterval {
        let source = CGEventSource(stateID: .hidSystemState)
        let virtualKey = CGKeyCode(keyCode)
        let requestedDelay = minimumDelay ?? timing().repostDelay
        let earliestPostDate = Date().addingTimeInterval(requestedDelay)
        let scheduledPostDate: Date
        if nextSyntheticKeyPostDate > Date() {
            scheduledPostDate = max(earliestPostDate, nextSyntheticKeyPostDate.addingTimeInterval(Self.syntheticKeySpacing))
        } else {
            scheduledPostDate = earliestPostDate
        }

        nextSyntheticKeyPostDate = scheduledPostDate
        let scheduledDelay = max(0, scheduledPostDate.timeIntervalSinceNow)

        DispatchQueue.main.asyncAfter(deadline: .now() + scheduledDelay) {
            for isKeyDown in [true, false] {
                guard let event = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: virtualKey,
                    keyDown: isKeyDown
                ) else {
                    continue
                }

                event.flags = []
                event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
                event.post(tap: .cghidEventTap)
            }
        }

        return scheduledDelay
    }

    private func scheduleRestore(after delay: TimeInterval) {
        restoreWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.restoreOriginalInputSource()
        }
        restoreWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func timing() -> Timing {
        switch NumpadAsciiSpeedMode.resolved(from: configProvider().numpadAsciiSpeedMode) {
        case .fast:
            return Timing(repostDelay: 0.025, firstRepostAfterSwitchDelay: 0.34, restoreDelay: 0.24)
        case .stable:
            return Timing(repostDelay: 0.070, firstRepostAfterSwitchDelay: 0.55, restoreDelay: 1.10)
        }
    }

    private func restoreOriginalInputSource() {
        guard let sourceToRestore else {
            return
        }

        self.sourceToRestore = nil
        restoreWorkItem = nil
        suppressedOriginalKeyUps.removeAll()
        nextSyntheticKeyPostDate = .distantPast

        do {
            try inputSources.selectInputSource(id: sourceToRestore)
            Self.postStatus("數字鍵盤：已還原原本輸入法")
        } catch {
            Self.postStatus("數字鍵盤：還原輸入法失敗")
            fputs("[input-method-agent] Could not restore input source after numpad: \(error.localizedDescription)\n", stderr)
        }
    }

    private static func postStatus(_ message: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .numpadAsciiStatusChanged,
                object: nil,
                userInfo: ["message": message]
            )
        }
    }
}


final class CapsLockInputSwitcher {
    private static let abcInputSourceID = "com.apple.keylayout.ABC"
    private static let capsLockKeyCode = 57
    private static let duplicateEventGuardInterval: TimeInterval = 0.045
    private static let switchSettlingInterval: TimeInterval = 0.55
    private static let reassertDelay: TimeInterval = 0.075

    private let configProvider: () -> AgentConfig
    private let inputSources: InputSourceManager
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastHandledAt: TimeInterval = 0
    private var lastSwitchRequestedAt: TimeInterval = 0
    private var lastRequestedInputSourceID: String?
    private var lastNonABCInputSourceID: String?
    private var reassertWorkItem: DispatchWorkItem?

    init(configProvider: @escaping () -> AgentConfig, inputSources: InputSourceManager) {
        self.configProvider = configProvider
        self.inputSources = inputSources
    }

    deinit {
        stop()
    }

    func refresh() {
        if configProvider().instantCapsLockSwitch == true {
            start()
        } else {
            stop()
        }
    }

    private func start() {
        guard eventTap == nil else {
            return
        }

        guard NumpadAsciiEnforcer.isAccessibilityTrusted(prompt: false),
              NumpadAsciiEnforcer.hasListenEventAccess() else {
            return
        }

        let eventMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let switcher = Unmanaged<CapsLockInputSwitcher>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return switcher.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return
        }

        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stop() {
        reassertWorkItem?.cancel()
        reassertWorkItem = nil
        lastRequestedInputSourceID = nil

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }

        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }

        eventTap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard configProvider().instantCapsLockSwitch == true,
              type == .flagsChanged,
              Int(event.getIntegerValueField(.keyboardEventKeycode)) == Self.capsLockKeyCode else {
            return Unmanaged.passUnretained(event)
        }

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastHandledAt >= Self.duplicateEventGuardInterval else {
            return nil
        }

        lastHandledAt = now
        switchInputSourceImmediately(at: now)
        return nil
    }

    private func switchInputSourceImmediately(at now: TimeInterval) {
        let config = configProvider()
        guard let observedInputSourceID = inputSources.currentInputSourceID() else {
            return
        }

        let effectiveInputSourceID = effectiveInputSourceID(observedInputSourceID: observedInputSourceID, now: now)
        let targetInputSourceID: String?
        if Self.isABCInputSource(effectiveInputSourceID) {
            targetInputSourceID = preferredNonABCInputSourceID(config: config)
        } else {
            lastNonABCInputSourceID = effectiveInputSourceID
            targetInputSourceID = Self.abcInputSourceID
        }

        guard let targetInputSourceID,
              targetInputSourceID != effectiveInputSourceID else {
            return
        }

        do {
            try inputSources.selectInputSource(id: targetInputSourceID)
            lastRequestedInputSourceID = targetInputSourceID
            lastSwitchRequestedAt = now
            if !Self.isABCInputSource(targetInputSourceID) {
                lastNonABCInputSourceID = targetInputSourceID
            }
            scheduleReassert(targetInputSourceID: targetInputSourceID, requestTime: now)
        } catch {
            fputs("[input-method-agent] Could not switch input source from Caps Lock: \(error.localizedDescription)\n", stderr)
        }
    }

    private func effectiveInputSourceID(observedInputSourceID: String, now: TimeInterval) -> String {
        guard let requestedInputSourceID = lastRequestedInputSourceID else {
            return observedInputSourceID
        }

        if observedInputSourceID == requestedInputSourceID {
            lastRequestedInputSourceID = nil
            return observedInputSourceID
        }

        if now - lastSwitchRequestedAt < Self.switchSettlingInterval {
            return requestedInputSourceID
        }

        lastRequestedInputSourceID = nil
        return observedInputSourceID
    }

    private func scheduleReassert(targetInputSourceID: String, requestTime: TimeInterval) {
        reassertWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.lastRequestedInputSourceID == targetInputSourceID,
                  self.lastSwitchRequestedAt == requestTime,
                  self.configProvider().instantCapsLockSwitch == true else {
                return
            }

            guard self.inputSources.currentInputSourceID() != targetInputSourceID else {
                self.lastRequestedInputSourceID = nil
                return
            }

            do {
                try self.inputSources.selectInputSource(id: targetInputSourceID)
            } catch {
                fputs("[input-method-agent] Could not reassert Caps Lock input source: \(error.localizedDescription)\n", stderr)
            }
        }
        reassertWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.reassertDelay, execute: workItem)
    }

    private func preferredNonABCInputSourceID(config: AgentConfig) -> String? {
        if let lastNonABCInputSourceID,
           Self.isAvailableInputSource(lastNonABCInputSourceID, in: inputSources.availableInputSources()) {
            return lastNonABCInputSourceID
        }

        if let defaultInputSourceID = config.defaultInputSourceID,
           !Self.isABCInputSource(defaultInputSourceID) {
            return defaultInputSourceID
        }

        let sources = inputSources.availableInputSources()
        if let zhuyin = sources.first(where: { Self.isZhuyinInputSource(id: $0.id, name: $0.name) }) {
            return zhuyin.id
        }

        return sources.first(where: { !Self.isABCInputSource($0.id) })?.id
    }

    private static func isAvailableInputSource(_ id: String, in sources: [InputSourceInfo]) -> Bool {
        sources.contains { $0.id == id }
    }

    private static func isABCInputSource(_ id: String?) -> Bool {
        guard let id else {
            return false
        }

        return id == abcInputSourceID || id.localizedCaseInsensitiveContains("ABC")
    }

    private static func isZhuyinInputSource(id: String, name: String) -> Bool {
        id == "com.apple.inputmethod.TCIM.Zhuyin"
            || name.localizedCaseInsensitiveContains("注音")
            || name.localizedCaseInsensitiveContains("Zhuyin")
    }
}


enum StartupLaunchAgent {
    static let label = "local.input-method-agent"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static func isEnabled() -> Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ enabled: Bool, configURL: URL) throws {
        if enabled {
            try install(configURL: configURL)
        } else {
            try uninstall()
        }
    }

    private static func install(configURL: URL) throws {
        guard let executableURL = Bundle.main.executableURL else {
            throw CocoaError(.fileNoSuchFile)
        }

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [
                executableURL.path,
                "--gui",
                "--config",
                configURL.path
            ],
            "RunAtLoad": true,
            "KeepAlive": false,
            "StandardOutPath": "/tmp/input-method-agent.log",
            "StandardErrorPath": "/tmp/input-method-agent.err"
        ]

        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )

        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: plistURL, options: .atomic)
    }

    private static func uninstall() throws {
        guard FileManager.default.fileExists(atPath: plistURL.path) else {
            return
        }

        try FileManager.default.removeItem(at: plistURL)
    }
}


final class PermissionGuideAnimationView: NSView {
    private var timer: Timer?
    private var phase: CGFloat = 0
    private lazy var appIcon: NSImage = Self.permissionGuideAppIcon()

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopAnimation()
        } else {
            startAnimation()
        }
    }

    private func startAnimation() {
        guard timer == nil else {
            return
        }

        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.phase = (self.phase + 0.012).truncatingRemainder(dividingBy: 1)
                self.needsDisplay = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopAnimation() {
        timer?.invalidate()
        timer = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let canvas = bounds.insetBy(dx: 14, dy: 12)
        let leftCard = NSRect(x: canvas.minX, y: canvas.minY + 28, width: 170, height: 96)
        let rightCard = NSRect(x: canvas.maxX - 230, y: canvas.minY + 28, width: 230, height: 96)

        drawCard(leftCard)
        drawCard(rightCard)
        drawFolder(in: leftCard)
        drawPermissionList(in: rightCard, completed: hasCompletedMove)

        drawLabel("1. 找到 App", in: NSRect(x: leftCard.minX, y: canvas.minY, width: leftCard.width, height: 20), weight: .semibold)
        drawLabel("2. 加入權限清單", in: NSRect(x: rightCard.minX, y: canvas.minY, width: rightCard.width, height: 20), weight: .semibold)
        drawArrow(from: leftCard.maxX + 14, to: rightCard.minX - 14, y: leftCard.midY)
        drawMovingAppIcon(from: leftCard, to: rightCard)
    }

    private func drawCard(_ rect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
        NSColor.separatorColor.withAlphaComponent(0.7).setStroke()
        let stroke = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        stroke.lineWidth = 1
        stroke.stroke()
    }

    private func drawFolder(in rect: NSRect) {
        let folder = NSRect(x: rect.midX - 38, y: rect.minY + 24, width: 76, height: 45)
        let tab = NSRect(x: folder.minX + 7, y: folder.minY - 9, width: 34, height: 16)
        NSColor.systemYellow.withAlphaComponent(0.88).setFill()
        NSBezierPath(roundedRect: tab, xRadius: 5, yRadius: 5).fill()
        NSColor.systemYellow.setFill()
        NSBezierPath(roundedRect: folder, xRadius: 9, yRadius: 9).fill()

        let labelRect = NSRect(x: rect.minX + 16, y: folder.maxY + 8, width: rect.width - 32, height: 16)
        drawLabel("App 所在資料夾", in: labelRect, weight: .semibold, fontSize: 11)
    }

    private var movementProgress: CGFloat {
        let travelEnd: CGFloat = 0.72
        guard phase < travelEnd else {
            return 1
        }

        let t = max(0, min(1, phase / travelEnd))
        return t * t * (3 - 2 * t)
    }

    private var hasCompletedMove: Bool {
        phase >= 0.72
    }

    private func drawPermissionList(in rect: NSRect, completed: Bool) {
        drawLabel("隱私權與安全性", in: NSRect(x: rect.minX + 18, y: rect.minY + 14, width: rect.width - 36, height: 18), weight: .semibold, fontSize: 12)
        let rows = ["輔助使用", "輸入監控"]
        for (index, title) in rows.enumerated() {
            let y = rect.minY + 42 + CGFloat(index) * 25
            let row = NSRect(x: rect.minX + 18, y: y, width: rect.width - 36, height: 20)
            NSColor.controlAccentColor.withAlphaComponent(completed ? 0.16 : 0.10).setFill()
            NSBezierPath(roundedRect: row, xRadius: 6, yRadius: 6).fill()
            if completed {
                drawPermissionCheck(in: row)
            } else {
                drawPermissionCross(in: row)
            }
            drawLabel(title, in: NSRect(x: row.minX + 28, y: row.minY + 2, width: row.width - 36, height: 16), fontSize: 11)
        }
    }

    private func drawPermissionCheck(in row: NSRect) {
        NSColor.systemGreen.setStroke()
        let check = NSBezierPath()
        check.move(to: NSPoint(x: row.minX + 8, y: row.midY))
        check.line(to: NSPoint(x: row.minX + 12, y: row.midY + 5))
        check.line(to: NSPoint(x: row.minX + 20, y: row.midY - 5))
        check.lineWidth = 2.3
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        check.stroke()
    }

    private func drawPermissionCross(in row: NSRect) {
        NSColor.systemRed.setStroke()
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: row.minX + 8.5, y: row.midY - 5.2))
        cross.line(to: NSPoint(x: row.minX + 19.5, y: row.midY + 5.2))
        cross.move(to: NSPoint(x: row.minX + 19.5, y: row.midY - 5.2))
        cross.line(to: NSPoint(x: row.minX + 8.5, y: row.midY + 5.2))
        cross.lineWidth = 2.2
        cross.lineCapStyle = .round
        cross.stroke()
    }

    private func drawArrow(from startX: CGFloat, to endX: CGFloat, y: CGFloat) {
        NSColor.secondaryLabelColor.withAlphaComponent(0.55).setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: startX, y: y))
        path.line(to: NSPoint(x: endX, y: y))
        path.lineWidth = 2
        path.stroke()

        let head = NSBezierPath()
        head.move(to: NSPoint(x: endX, y: y))
        head.line(to: NSPoint(x: endX - 8, y: y - 5))
        head.move(to: NSPoint(x: endX, y: y))
        head.line(to: NSPoint(x: endX - 8, y: y + 5))
        head.lineWidth = 2
        head.stroke()
    }

    private func drawMovingAppIcon(from leftCard: NSRect, to rightCard: NSRect) {
        let eased = movementProgress
        let start = NSPoint(x: leftCard.maxX - 58, y: leftCard.midY - 22)
        let end = NSPoint(x: rightCard.minX + 26, y: rightCard.midY - 22)
        let x = start.x + (end.x - start.x) * eased
        let lift = sin(eased * .pi) * 12
        let y = start.y + (end.y - start.y) * eased - lift
        let rect = NSRect(x: x, y: y, width: 44, height: 44)

        NSColor.black.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: rect.offsetBy(dx: 0, dy: 2), xRadius: 10, yRadius: 10).fill()
        appIcon.draw(in: rect)
    }

    private static func permissionGuideAppIcon() -> NSImage {
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            return NSWorkspace.shared.icon(forFile: bundleURL.path)
        }

        if let icon = NSImage(named: NSImage.applicationIconName) {
            return icon
        }

        return NSImage(size: NSSize(width: 44, height: 44))
    }

    private func drawLabel(_ text: String, in rect: NSRect, weight: NSFont.Weight = .regular, fontSize: CGFloat = 12) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: weight),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        text.draw(in: rect, withAttributes: attributes)
    }
}

final class PermissionGuideWindowController: NSWindowController {
    private let onRecheck: () -> Void
    private let statusLabel = NSTextField(labelWithString: "")

    init(onRecheck: @escaping () -> Void) {
        self.onRecheck = onRecheck
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "權限設定引導"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildInterface()
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func buildInterface() {
        guard let contentView = window?.contentView else {
            return
        }

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
            root.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20)
        ])

        let title = NSTextField(labelWithString: "開啟 macOS 權限")
        title.font = .systemFont(ofSize: 22, weight: .bold)
        title.alignment = .left
        title.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(title)
        title.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let intro = secondaryText("macOS 需要你手動允許權限。請依照下面 4 個步驟，把 Input Method Agent 加入「輔助使用」與「輸入監控」清單，並打開右側開關。")
        intro.alignment = .left
        intro.maximumNumberOfLines = 3
        intro.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(intro)
        intro.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let animationView = PermissionGuideAnimationView()
        animationView.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(animationView)
        NSLayoutConstraint.activate([
            animationView.widthAnchor.constraint(equalTo: root.widthAnchor),
            animationView.heightAnchor.constraint(equalToConstant: 150)
        ])

        let stepsStack = NSStackView()
        stepsStack.orientation = .vertical
        stepsStack.alignment = .width
        stepsStack.spacing = 8
        stepsStack.translatesAutoresizingMaskIntoConstraints = false
        stepsStack.addArrangedSubview(permissionStepRow(
            number: "1",
            title: "開啟 App 所在資料夾",
            detail: "確認要加入權限清單的是 Input Method Agent.app。",
            buttonTitle: "開啟資料夾",
            action: #selector(openAppFolder)
        ))
        stepsStack.addArrangedSubview(permissionStepRow(
            number: "2",
            title: "開啟輔助使用設定",
            detail: "把 Input Method Agent 加入清單，並打開右側開關。",
            buttonTitle: "開啟輔助使用",
            action: #selector(openAccessibilitySettings)
        ))
        stepsStack.addArrangedSubview(permissionStepRow(
            number: "3",
            title: "開啟輸入監控設定",
            detail: "同樣加入 Input Method Agent，並打開右側開關。",
            buttonTitle: "開啟輸入監控",
            action: #selector(openInputMonitoringSettings)
        ))
        stepsStack.addArrangedSubview(permissionStepRow(
            number: "4",
            title: "重新檢查",
            detail: "完成上面兩個權限後，回來確認 App 是否已取得權限。",
            buttonTitle: "重新檢查",
            action: #selector(recheckPermissions)
        ))
        root.addArrangedSubview(stepsStack)
        stepsStack.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.alignment = .left
        statusLabel.maximumNumberOfLines = 2
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.stringValue = "如果清單裡看不到 App，可以按系統設定中的 +，或把 App 從 Finder 拖進權限清單。"
        root.addArrangedSubview(statusLabel)
        statusLabel.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let closeRow = NSStackView()
        closeRow.orientation = .horizontal
        closeRow.alignment = .centerY
        closeRow.translatesAutoresizingMaskIntoConstraints = false
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        closeRow.addArrangedSubview(spacer)
        closeRow.addArrangedSubview(guideButton("完成", action: #selector(closeGuide), minimumWidth: 120))
        root.addArrangedSubview(closeRow)
        closeRow.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    }

    private func permissionStepRow(number: String, title: String, detail: String, buttonTitle: String, action: Selector) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.translatesAutoresizingMaskIntoConstraints = false
        box.borderWidth = 1
        box.cornerRadius = 8
        box.borderColor = .separatorColor
        box.fillColor = NSColor.controlBackgroundColor.withAlphaComponent(0.35)
        box.contentViewMargins = NSSize(width: 12, height: 10)
        box.heightAnchor.constraint(equalToConstant: 66).isActive = true

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let titleLabel = NSTextField(labelWithString: "\(number). \(title)")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .left
        titleLabel.lineBreakMode = .byTruncatingTail
        textStack.addArrangedSubview(titleLabel)

        let detailLabel = secondaryText(detail)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.alignment = .left
        detailLabel.preferredMaxLayoutWidth = 360
        detailLabel.maximumNumberOfLines = 2
        textStack.addArrangedSubview(detailLabel)

        row.addArrangedSubview(textStack)
        row.addArrangedSubview(guideButton(buttonTitle, action: action, minimumWidth: 154))

        if let contentView = box.contentView {
            contentView.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                row.topAnchor.constraint(equalTo: contentView.topAnchor),
                row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
            ])
        }

        return box
    }

    private func secondaryText(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.textColor = .secondaryLabelColor
        field.font = .systemFont(ofSize: 13)
        field.lineBreakMode = .byWordWrapping
        field.usesSingleLineMode = false
        field.alignment = .left
        field.preferredMaxLayoutWidth = 560
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func guideButton(_ title: String, action: Selector, minimumWidth: CGFloat = 154) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: minimumWidth).isActive = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    @objc private func openAppFolder() {
        let appURL = Self.applicationURLForPermissionGuide()
        NSWorkspace.shared.activateFileViewerSelecting([appURL])
        statusLabel.stringValue = "已在 Finder 顯示 App。接著開啟權限設定，把這個 App 加入清單並打開開關。"
    }

    @objc private func openAccessibilitySettings() {
        openSystemSettingsPane(
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            status: "已開啟輔助使用設定。請加入 Input Method Agent 並打開開關。"
        )
    }

    @objc private func openInputMonitoringSettings() {
        openSystemSettingsPane(
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
            status: "已開啟輸入監控設定。請加入 Input Method Agent 並打開開關。"
        )
    }

    @objc private func recheckPermissions() {
        onRecheck()
        let accessibilityGranted = NumpadAsciiEnforcer.isAccessibilityTrusted(prompt: false)
            && NumpadAsciiEnforcer.hasPostEventAccess()
        let inputMonitoringGranted = NumpadAsciiEnforcer.hasListenEventAccess()
        if accessibilityGranted && inputMonitoringGranted {
            statusLabel.stringValue = "權限已完成，可以回到設定視窗儲存並啟用。"
            statusLabel.textColor = .systemGreen
        } else {
            let missing = [
                accessibilityGranted ? nil : "輔助使用",
                inputMonitoringGranted ? nil : "輸入監控"
            ].compactMap { $0 }.joined(separator: "、")
            statusLabel.stringValue = "仍缺少：\(missing)。請確認清單中已加入 App，並且右側開關已打開。"
            statusLabel.textColor = .systemOrange
        }
    }

    @objc private func closeGuide() {
        close()
    }

    private func openSystemSettingsPane(_ target: String, status: String) {
        if let url = URL(string: target), NSWorkspace.shared.open(url) {
            statusLabel.stringValue = status
            statusLabel.textColor = .secondaryLabelColor
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
            statusLabel.stringValue = "已開啟系統設定。請前往「隱私權與安全性」找到對應權限。"
            statusLabel.textColor = .secondaryLabelColor
        }
    }

    private static func applicationURLForPermissionGuide() -> URL {
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            return bundleURL
        }

        return URL(fileURLWithPath: CommandLine.arguments.first ?? Bundle.main.bundlePath)
            .standardizedFileURL
    }
}

final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    private let store: ConfigStore
    private let inputSources: [InputSourceInfo]
    private var rules: [AppRule]

    private let tableView = NSTableView()
    private let searchField = NSSearchField()
    private let filterControl = NSSegmentedControl(labels: ["全部", "已設定", "跟隨全域", "ABC", "注音"], trackingMode: .selectOne, target: nil, action: nil)
    private let defaultInputPopup = NSPopUpButton()
    private let selectedInputPopup = NSPopUpButton()
    private let moreActionsPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let globalDefaultSummaryLabel = NSTextField(labelWithString: "")
    private let selectedAppNameLabel = NSTextField(labelWithString: "請先選擇一個 App")
    private let selectedInputPrefixLabel = NSTextField(labelWithString: "開啟時使用：")
    private let startupCheckbox = NSButton(checkboxWithTitle: "登入後自動啟動", target: nil, action: nil)
    private let capsLockInstantSwitchCheckbox = NSButton(checkboxWithTitle: "實驗功能：Caps Lock 快速切換輸入法", target: nil, action: nil)
    private let numpadAsciiCheckbox = NSButton(checkboxWithTitle: "在中文輸入法下，數字鍵盤仍輸入半形數字", target: nil, action: nil)
    private let numpadSpeedControl = NSSegmentedControl(labels: ["快速", "穩定"], trackingMode: .selectOne, target: nil, action: nil)
    private let numpadTestField = NSTextField(string: "")
    private let numpadTestStatusLabel = NSTextField(labelWithString: "輸出結果：尚未測試　｜　狀態：等待輸入")
    private let permissionSummaryLabel = NSTextField(labelWithString: "")
    private let permissionIntroLabel = NSTextField(labelWithString: "")
    private let accessibilityStatusLabel = NSTextField(labelWithString: "")
    private let listenStatusLabel = NSTextField(labelWithString: "")
    private let postStatusLabel = NSTextField(labelWithString: "")
    private let numpadRuntimeStatusLabel = NSTextField(labelWithString: "")
    private let currentAppStatusLabel = NSTextField(labelWithString: "目前 App：尚未偵測")
    private let appliedRuleStatusLabel = NSTextField(labelWithString: "套用規則：尚未啟用")
    private let currentInputStatusLabel = NSTextField(labelWithString: "目前輸入法：尚未偵測")
    private let runtimeStatusLineLabel = NSTextField(labelWithString: "目前 App：尚未偵測　｜　套用規則：尚未啟用　｜　目前輸入法：尚未偵測")
    private let emptyStateLabel = NSTextField(labelWithString: "")
    private let openAccessibilitySettingsButton = NSButton(title: "開啟輔助使用", target: nil, action: nil)
    private let openInputMonitoringSettingsButton = NSButton(title: "開啟輸入監控", target: nil, action: nil)
    private let recheckPermissionsButton = NSButton(title: "重新檢查", target: nil, action: nil)
    private let privacyInfoButton = NSButton(title: "關於隱私與權限", target: nil, action: nil)
    private let permissionGuideButton = NSButton(title: "權限設定引導", target: nil, action: nil)
    private let advancedToggleButton = NSButton(title: "▶  進階設定", target: nil, action: nil)
    private let advancedSettingsBox = NSBox()
    private let advancedStack = NSStackView()
    private let saveButton = NSButton(title: "儲存並啟用", target: nil, action: nil)
    private let saveButtonHelpLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let permissionChecklistLabel = NSTextField(labelWithString: "")
    private let permissionNextStepLabel = NSTextField(labelWithString: "")
    private let inputSourceManager = InputSourceManager()
    private let autoSwitchStatusProvider: () -> AutoSwitchRuntimeStatus
    private let appTracker: FrontmostApplicationTracker
    private var runtimeStatusTimer: Timer?
    private var bundleColumn: NSTableColumn?
    private var showsBundleIDColumn = false
    private var advancedSettingsVisible = false
    private var hasUnsavedChanges = false
    private var permissionGuideWindowController: PermissionGuideWindowController?

    private static let advancedSettingsVisibleKey = "InputMethodAgentAdvancedSettingsVisible"
    private static let advancedSettingsPreferenceInitializedKey = "InputMethodAgentAdvancedSettingsPreferenceInitialized"

    private enum SuggestedInputKind {
        case abc
        case zhuyin
    }

    private struct SuggestedRuleTemplate {
        let source: SuggestedInputKind
        let bundleIDs: [String]
        let nameKeywords: [String]
    }

    private static let suggestedRuleTemplates: [SuggestedRuleTemplate] = [
        SuggestedRuleTemplate(
            source: .abc,
            bundleIDs: [
                "com.adobe.PremierePro", "com.blackmagic-design.DaVinciResolve", "com.apple.FinalCut",
                "com.adobe.AfterEffects.application", "com.adobe.Photoshop", "com.adobe.illustrator"
            ],
            nameKeywords: ["Premiere Pro", "DaVinci Resolve", "Final Cut", "After Effects", "Photoshop", "Illustrator"]
        ),
        SuggestedRuleTemplate(
            source: .abc,
            bundleIDs: ["com.microsoft.VSCode", "com.apple.dt.Xcode", "com.apple.Terminal", "com.googlecode.iterm2"],
            nameKeywords: ["Visual Studio Code", "VS Code", "Xcode", "Terminal", "iTerm"]
        ),
        SuggestedRuleTemplate(
            source: .zhuyin,
            bundleIDs: ["jp.naver.line.mac", "com.facebook.archon", "com.apple.Notes", "com.microsoft.Word"],
            nameKeywords: ["LINE", "Messenger", "Notes", "備忘錄", "Word"]
        )
    ]

    init(
        store: ConfigStore,
        inputSources: [InputSourceInfo],
        appTracker: FrontmostApplicationTracker = FrontmostApplicationTracker(),
        autoSwitchStatusProvider: @escaping () -> AutoSwitchRuntimeStatus = { AutoSwitchRuntimeStatus(isEnabled: true, isPaused: false, pauseRemainingSeconds: nil) }
    ) {
        self.store = store
        self.inputSources = inputSources
        self.appTracker = appTracker
        self.autoSwitchStatusProvider = autoSwitchStatusProvider
        self.rules = Self.loadApplicationRules(config: store.config)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "輸入法工作流設定"
        window.minSize = NSSize(width: 880, height: 680)

        super.init(window: window)
        setupUI()
        reloadDefaultPopup()
        reloadSelectedInputPopup()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeApplicationDidChange(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(numpadAsciiStatusChanged(_:)),
            name: .numpadAsciiStatusChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(agentRuntimeStatusChanged(_:)),
            name: .agentRuntimeStatusChanged,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        startRuntimeStatusTimerIfNeeded()
        updateRuntimeStatus()
        updatePrimaryButtonState()
        showOnboardingIfNeeded()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredRules().count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let visibleRules = filteredRules()
        guard row < visibleRules.count else {
            return nil
        }

        let rule = visibleRules[row]
        let identifier = tableColumn?.identifier.rawValue ?? "cell"
        let textField = NSTextField(labelWithString: "")
        textField.lineBreakMode = .byTruncatingMiddle

        switch identifier {
        case "app":
            return appCellView(for: rule)
        case "bundle":
            textField.stringValue = rule.bundleID
            textField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        case "input":
            textField.stringValue = inputDescription(for: rule)
            if rule.inputSourceID == nil {
                textField.textColor = .secondaryLabelColor
            }
        default:
            textField.stringValue = ""
        }

        return textField
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        reloadSelectedInputPopup()
        configureMoreActionsMenu()
    }

    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSSearchField === searchField {
            searchChanged()
            return
        }

        if obj.object as? NSTextField === numpadTestField {
            updateNumpadTestStatus()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        let visibleRules = filteredRules()
        guard row >= 0, row < visibleRules.count else {
            return
        }

        let item = NSMenuItem(title: "複製 Bundle ID", action: #selector(copyBundleID(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = visibleRules[row].bundleID
        menu.addItem(item)
    }

    private func setupUI() {
        guard let contentView = window?.contentView else {
            return
        }

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .width
        root.distribution = .fill
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .width
        contentStack.distribution = .fill
        contentStack.spacing = 10
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.setContentHuggingPriority(.required, for: .vertical)
        contentStack.setContentCompressionResistancePriority(.required, for: .vertical)
        root.addArrangedSubview(contentStack)
        contentStack.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -36).isActive = true

        let headerStack = NSStackView()
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 4
        contentStack.addArrangedSubview(headerStack)

        let header = NSTextField(labelWithString: "輸入法工作流設定")
        header.font = .systemFont(ofSize: 22, weight: .semibold)
        headerStack.addArrangedSubview(header)

        let subtitle = secondaryLabel("為不同 App 自動切換輸入法，避免中文輸入法影響快捷鍵與數字輸入。")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.maximumNumberOfLines = 2
        headerStack.addArrangedSubview(subtitle)

        let stepRow = horizontalStack(spacing: 12)
        stepRow.addArrangedSubview(stepLabel("① 選擇 App　② 指定輸入法　③ 儲存並啟用"))
        headerStack.addArrangedSubview(stepRow)

        let (globalBox, globalStack) = sectionBox(title: "全域設定")
        contentStack.addArrangedSubview(globalBox)

        let globalRow = horizontalStack(spacing: 10)
        globalRow.addArrangedSubview(label("全域預設輸入法"))
        defaultInputPopup.target = self
        defaultInputPopup.action = #selector(defaultInputChanged)
        globalRow.addArrangedSubview(defaultInputPopup)

        globalDefaultSummaryLabel.textColor = .secondaryLabelColor
        globalDefaultSummaryLabel.font = .systemFont(ofSize: 12)
        globalRow.addArrangedSubview(globalDefaultSummaryLabel)

        let globalSpacer = NSView()
        globalSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        globalRow.addArrangedSubview(globalSpacer)
        globalStack.addArrangedSubview(globalRow)

        let (rulesBox, rulesStack) = sectionBox(title: "App 規則列表")
        contentStack.addArrangedSubview(rulesBox)

        let managementRow = horizontalStack(spacing: 8)
        managementRow.addArrangedSubview(button("＋ 加入 App", action: #selector(chooseApplication)))
        managementRow.addArrangedSubview(button("套用常用規則", action: #selector(applySuggestedRules)))
        configureMoreActionsMenu()
        moreActionsPopup.bezelStyle = .rounded
        managementRow.addArrangedSubview(moreActionsPopup)

        let managementSpacer = NSView()
        managementSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        managementRow.addArrangedSubview(managementSpacer)

        let selectedEditorStack = NSStackView()
        selectedEditorStack.orientation = .vertical
        selectedEditorStack.alignment = .trailing
        selectedEditorStack.spacing = 4
        selectedAppNameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        selectedAppNameLabel.textColor = .secondaryLabelColor
        selectedAppNameLabel.lineBreakMode = .byWordWrapping
        selectedAppNameLabel.usesSingleLineMode = false
        selectedAppNameLabel.maximumNumberOfLines = 2
        selectedAppNameLabel.alignment = .right
        selectedAppNameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        selectedAppNameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
        selectedEditorStack.addArrangedSubview(selectedAppNameLabel)

        let selectedInputRow = horizontalStack(spacing: 6)
        selectedInputPrefixLabel.font = .systemFont(ofSize: 12)
        selectedInputPrefixLabel.textColor = .secondaryLabelColor
        selectedInputRow.addArrangedSubview(selectedInputPrefixLabel)
        selectedInputPopup.target = self
        selectedInputPopup.action = #selector(selectedInputChanged)
        selectedInputRow.addArrangedSubview(selectedInputPopup)
        selectedInputPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
        selectedEditorStack.addArrangedSubview(selectedInputRow)
        managementRow.addArrangedSubview(selectedEditorStack)
        rulesStack.addArrangedSubview(managementRow)

        let searchRow = horizontalStack(spacing: 8)
        searchField.placeholderString = showsBundleIDColumn ? "搜尋 App 名稱或 Bundle ID" : "搜尋 App 名稱"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.widthAnchor.constraint(equalToConstant: 240).isActive = true
        searchRow.addArrangedSubview(searchField)

        filterControl.selectedSegment = 0
        filterControl.segmentStyle = .texturedRounded
        filterControl.target = self
        filterControl.action = #selector(filterChanged)
        filterControl.translatesAutoresizingMaskIntoConstraints = false
        filterControl.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        searchRow.addArrangedSubview(filterControl)

        let searchSpacer = NSView()
        searchSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchRow.addArrangedSubview(searchSpacer)
        rulesStack.addArrangedSubview(searchRow)

        let scrollView = NSScrollView()
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.documentView = tableView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true
        rulesStack.addArrangedSubview(scrollView)

        setupTable()

        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.font = .systemFont(ofSize: 12)
        emptyStateLabel.alignment = .center
        emptyStateLabel.usesSingleLineMode = false
        emptyStateLabel.maximumNumberOfLines = 3
        emptyStateLabel.isHidden = true
        rulesStack.addArrangedSubview(emptyStateLabel)

        runtimeStatusLineLabel.font = .systemFont(ofSize: 12)
        runtimeStatusLineLabel.textColor = .secondaryLabelColor
        runtimeStatusLineLabel.lineBreakMode = .byTruncatingTail
        runtimeStatusLineLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rulesStack.addArrangedSubview(runtimeStatusLineLabel)

        let (numpadBox, numpadStack) = sectionBox(title: "數字鍵盤修正")
        contentStack.addArrangedSubview(numpadBox)

        let numpadRow = horizontalStack(spacing: 10)
        numpadAsciiCheckbox.target = self
        numpadAsciiCheckbox.action = #selector(numpadAsciiCheckboxChanged)
        numpadAsciiCheckbox.state = store.config.forceAsciiNumpad == true ? .on : .off
        numpadRow.addArrangedSubview(numpadAsciiCheckbox)

        let numpadSpacer = NSView()
        numpadSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        numpadRow.addArrangedSubview(numpadSpacer)

        numpadRow.addArrangedSubview(label("速度"))
        numpadSpeedControl.target = self
        numpadSpeedControl.action = #selector(numpadSpeedChanged)
        numpadSpeedControl.segmentStyle = .texturedRounded
        numpadSpeedControl.setToolTip("反應較快，適合大多數情況。", forSegment: 0)
        numpadSpeedControl.setToolTip("相容性較高，適合輸入異常時使用。", forSegment: 1)
        let initialSpeedMode = NumpadAsciiSpeedMode.resolved(from: store.config.numpadAsciiSpeedMode)
        numpadSpeedControl.selectedSegment = initialSpeedMode == .stable ? 1 : 0
        numpadSpeedControl.isEnabled = numpadAsciiCheckbox.state == .on
        numpadRow.addArrangedSubview(numpadSpeedControl)
        numpadSpeedControl.widthAnchor.constraint(equalToConstant: 116).isActive = true
        numpadStack.addArrangedSubview(numpadRow)

        let numpadDescription = secondaryLabel("避免在注音輸入狀態下輸入 １２３ 這類全形數字。")
        numpadDescription.maximumNumberOfLines = 1
        numpadStack.addArrangedSubview(numpadDescription)

        let privacyNotice = secondaryLabel("隱私保護：只處理右側數字鍵，不記錄、不儲存、不上傳按鍵內容。")
        privacyNotice.font = .systemFont(ofSize: 12, weight: .semibold)
        privacyNotice.textColor = .labelColor
        privacyNotice.maximumNumberOfLines = 2
        numpadStack.addArrangedSubview(privacyNotice)

        let (statusBox, statusStack) = sectionBox(title: "權限狀態")
        statusStack.alignment = .leading
        contentStack.addArrangedSubview(statusBox)

        permissionSummaryLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        permissionSummaryLabel.alignment = .left
        numpadRuntimeStatusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        numpadRuntimeStatusLabel.alignment = .left
        accessibilityStatusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        listenStatusLabel.font = .systemFont(ofSize: 12, weight: .semibold)

        openAccessibilitySettingsButton.target = self
        openAccessibilitySettingsButton.action = #selector(openAccessibilitySettings)
        openAccessibilitySettingsButton.bezelStyle = .rounded
        openAccessibilitySettingsButton.controlSize = .small
        openInputMonitoringSettingsButton.target = self
        openInputMonitoringSettingsButton.action = #selector(openInputMonitoringSettings)
        openInputMonitoringSettingsButton.bezelStyle = .rounded
        openInputMonitoringSettingsButton.controlSize = .small

        let permissionRowsStack = NSStackView()
        permissionRowsStack.orientation = .vertical
        permissionRowsStack.alignment = .leading
        permissionRowsStack.spacing = 8
        permissionRowsStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        permissionRowsStack.addArrangedSubview(permissionStatusRow(
            statusLabel: permissionSummaryLabel,
            permissionLabel: accessibilityStatusLabel,
            button: openAccessibilitySettingsButton
        ))
        permissionRowsStack.addArrangedSubview(permissionStatusRow(
            statusLabel: numpadRuntimeStatusLabel,
            permissionLabel: listenStatusLabel,
            button: openInputMonitoringSettingsButton
        ))
        statusStack.addArrangedSubview(permissionRowsStack)

        let statusActionRow = horizontalStack(spacing: 8)
        permissionGuideButton.title = "開始權限設定引導"
        permissionGuideButton.target = self
        permissionGuideButton.action = #selector(showPermissionGuide)
        permissionGuideButton.bezelStyle = .rounded
        permissionGuideButton.controlSize = .regular
        permissionGuideButton.font = .systemFont(ofSize: 13, weight: .semibold)
        statusActionRow.addArrangedSubview(permissionGuideButton)
        recheckPermissionsButton.target = self
        recheckPermissionsButton.action = #selector(recheckPermissions)
        recheckPermissionsButton.bezelStyle = .rounded
        statusActionRow.addArrangedSubview(recheckPermissionsButton)
        privacyInfoButton.target = self
        privacyInfoButton.action = #selector(showPrivacyInfo)
        privacyInfoButton.bezelStyle = .rounded
        statusActionRow.addArrangedSubview(privacyInfoButton)
        statusStack.addArrangedSubview(statusActionRow)

        permissionNextStepLabel.textColor = .secondaryLabelColor
        permissionNextStepLabel.font = .systemFont(ofSize: 12)
        permissionNextStepLabel.maximumNumberOfLines = 2
        permissionNextStepLabel.isHidden = true
        statusStack.addArrangedSubview(permissionNextStepLabel)

        statusLabel.isHidden = true

        let advancedToggleRow = horizontalStack(spacing: 8)
        advancedToggleButton.target = self
        advancedToggleButton.action = #selector(toggleAdvancedSettings)
        advancedToggleButton.isBordered = false
        advancedToggleButton.alignment = .left
        advancedToggleButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        advancedToggleRow.addArrangedSubview(advancedToggleButton)
        let advancedToggleSpacer = NSView()
        advancedToggleSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        advancedToggleRow.addArrangedSubview(advancedToggleSpacer)
        contentStack.addArrangedSubview(advancedToggleRow)

        advancedSettingsBox.title = ""
        advancedSettingsBox.contentViewMargins = NSSize(width: 14, height: 12)
        advancedSettingsBox.translatesAutoresizingMaskIntoConstraints = false
        if UserDefaults.standard.bool(forKey: Self.advancedSettingsPreferenceInitializedKey) {
            advancedSettingsVisible = UserDefaults.standard.bool(forKey: Self.advancedSettingsVisibleKey)
        } else {
            advancedSettingsVisible = false
            UserDefaults.standard.set(false, forKey: Self.advancedSettingsVisibleKey)
            UserDefaults.standard.set(true, forKey: Self.advancedSettingsPreferenceInitializedKey)
        }
        advancedSettingsBox.isHidden = !advancedSettingsVisible
        updateAdvancedToggleButtonTitle()
        advancedStack.orientation = .vertical
        advancedStack.alignment = .leading
        advancedStack.spacing = 10
        advancedStack.translatesAutoresizingMaskIntoConstraints = false
        if let advancedContentView = advancedSettingsBox.contentView {
            advancedContentView.addSubview(advancedStack)
            NSLayoutConstraint.activate([
                advancedStack.leadingAnchor.constraint(equalTo: advancedContentView.leadingAnchor),
                advancedStack.trailingAnchor.constraint(equalTo: advancedContentView.trailingAnchor),
                advancedStack.topAnchor.constraint(equalTo: advancedContentView.topAnchor),
                advancedStack.bottomAnchor.constraint(equalTo: advancedContentView.bottomAnchor)
            ])
        }
        contentStack.addArrangedSubview(advancedSettingsBox)

        advancedStack.addArrangedSubview(advancedSectionTitle("啟動"))
        startupCheckbox.target = self
        startupCheckbox.action = #selector(startupCheckboxChanged)
        startupCheckbox.state = StartupLaunchAgent.isEnabled() ? .on : .off
        advancedStack.addArrangedSubview(startupCheckbox)

        if DeveloperFeatureFlags.showCapsLockExperiment {
            advancedStack.addArrangedSubview(advancedSectionTitle("實驗功能"))
            capsLockInstantSwitchCheckbox.target = self
            capsLockInstantSwitchCheckbox.action = #selector(capsLockInstantSwitchChanged)
            capsLockInstantSwitchCheckbox.state = DeveloperFeatureFlags.capsLockEnabled(in: store.config) ? .on : .off
            advancedStack.addArrangedSubview(capsLockInstantSwitchCheckbox)
            let capsLockHelp = secondaryLabel("預設關閉。開啟後會暫時接管 Caps Lock 並關閉 macOS 內建 Caps Lock 切換輸入法；取消勾選時會還原原本設定。此功能仍可能受系統切換速度影響，若手感不穩建議關閉。只偵測 Caps Lock，不記錄一般按鍵內容。")
            capsLockHelp.maximumNumberOfLines = 5
            advancedStack.addArrangedSubview(capsLockHelp)
        } else {
            capsLockInstantSwitchCheckbox.state = .off
        }

        advancedStack.addArrangedSubview(advancedSectionTitle("測試"))
        let testRow = horizontalStack(spacing: 8)
        testRow.addArrangedSubview(label("測試數字鍵盤"))
        numpadTestField.placeholderString = "在這裡按右側數字鍵"
        numpadTestField.delegate = self
        numpadTestField.translatesAutoresizingMaskIntoConstraints = false
        numpadTestField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        testRow.addArrangedSubview(numpadTestField)
        numpadTestStatusLabel.textColor = .secondaryLabelColor
        numpadTestStatusLabel.lineBreakMode = .byTruncatingTail
        testRow.addArrangedSubview(numpadTestStatusLabel)
        advancedStack.addArrangedSubview(testRow)

        advancedStack.addArrangedSubview(advancedSectionTitle("說明"))
        let advancedPermissionHelp = secondaryLabel("輔助使用權限用於偵測目前 App、切換輸入法與送出修正後的右側數字鍵。\n輸入監控權限僅用於判斷右側數字鍵盤輸入。")
        advancedPermissionHelp.maximumNumberOfLines = 2
        advancedStack.addArrangedSubview(advancedPermissionHelp)

        let footerRow = horizontalStack(spacing: 12)
        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footerRow.addArrangedSubview(footerSpacer)

        let saveColumn = NSStackView()
        saveColumn.orientation = .vertical
        saveColumn.alignment = .trailing
        saveColumn.spacing = 4
        saveButtonHelpLabel.textColor = .secondaryLabelColor
        saveButtonHelpLabel.font = .systemFont(ofSize: 11)
        saveButtonHelpLabel.alignment = .right
        saveColumn.addArrangedSubview(saveButtonHelpLabel)
        saveButton.target = self
        saveButton.action = #selector(saveConfig)
        saveButton.bezelStyle = .rounded
        saveButton.controlSize = .large
        saveButton.font = .systemFont(ofSize: 15, weight: .semibold)
        saveButton.keyEquivalent = "\r"
        saveButton.toolTip = "儲存設定並啟用目前可用的功能；數字鍵盤修正需要完成 macOS 權限才會生效。"
        saveColumn.addArrangedSubview(saveButton)
        saveButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 132).isActive = true
        saveButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true
        footerRow.addArrangedSubview(saveColumn)

        let rootFlexibleSpacer = NSView()
        rootFlexibleSpacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        rootFlexibleSpacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        root.addArrangedSubview(rootFlexibleSpacer)
        root.addArrangedSubview(footerRow)

        for view in [headerStack, globalBox, rulesBox, numpadBox, statusBox, advancedToggleRow, advancedSettingsBox] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }
        footerRow.translatesAutoresizingMaskIntoConstraints = false
        footerRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -36).isActive = true

        updatePermissionStatus()
        updateGlobalDefaultSummary()
        updateRuntimeStatus()
        updateNumpadTestStatus()
        updateEmptyState()
        if store.config.forceAsciiNumpad == true {
            updateNumpadStatusSnapshot()
        } else {
            updateStatus("已列出 \(rules.count) 個應用程式。")
        }
    }

    @objc private func activeApplicationDidChange(_ notification: Notification) {
        updateRuntimeStatus()
    }

    @objc private func numpadAsciiStatusChanged(_ notification: Notification) {
        guard let message = notification.userInfo?["message"] as? String else {
            return
        }

        if message.hasPrefix("數字鍵盤：缺少") {
            updateStatus("")
        } else {
            updateStatus(message)
        }
        updatePermissionStatus()
    }

    private func permissionStatusRow(statusLabel: NSTextField, permissionLabel: NSTextField, button: NSButton) -> NSStackView {
        let row = horizontalStack(spacing: 14)
        row.alignment = .centerY

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusLabel.widthAnchor.constraint(equalToConstant: 250).isActive = true
        row.addArrangedSubview(statusLabel)

        permissionLabel.translatesAutoresizingMaskIntoConstraints = false
        permissionLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        permissionLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        permissionLabel.widthAnchor.constraint(equalToConstant: 170).isActive = true
        row.addArrangedSubview(permissionLabel)

        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 152).isActive = true
        row.addArrangedSubview(button)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        return row
    }

    private func updateNumpadStatusSnapshot() {
        updatePermissionStatus()
        guard numpadAsciiCheckbox.state == .on else {
            updateStatus("數字鍵盤修正：未開啟")
            return
        }

        let allGranted = NumpadAsciiEnforcer.isAccessibilityTrusted(prompt: false)
            && NumpadAsciiEnforcer.hasListenEventAccess()
            && NumpadAsciiEnforcer.hasPostEventAccess()
        updateStatus(allGranted ? "數字鍵盤修正：執行中" : "")
    }

    private func updatePermissionStatus() {
        let accessibilityGranted = NumpadAsciiEnforcer.isAccessibilityTrusted(prompt: false)
            && NumpadAsciiEnforcer.hasPostEventAccess()
        let inputMonitoringGranted = NumpadAsciiEnforcer.hasListenEventAccess()
        let allGranted = accessibilityGranted && inputMonitoringGranted
        let hasMissingPermission = !allGranted
        let numpadEnabled = numpadAsciiCheckbox.state == .on

        permissionSummaryLabel.stringValue = hasMissingPermission ? "狀態：需要 macOS 權限" : "狀態：已啟用"
        permissionSummaryLabel.textColor = hasMissingPermission ? .systemOrange : .systemGreen
        let checklistTitle = hasMissingPermission ? "尚未完成" : "已完成"
        let permissionItems = [
            ("輔助使用權限", accessibilityGranted),
            ("輸入監控權限", inputMonitoringGranted)
        ]
        permissionChecklistLabel.attributedStringValue = permissionStatusSummary(
            title: checklistTitle,
            items: permissionItems
        )
        accessibilityStatusLabel.stringValue = permissionLine(title: "輔助使用權限", granted: accessibilityGranted)
        accessibilityStatusLabel.textColor = accessibilityGranted ? .systemGreen : .systemOrange
        listenStatusLabel.stringValue = permissionLine(title: "輸入監控權限", granted: inputMonitoringGranted)
        listenStatusLabel.textColor = inputMonitoringGranted ? .systemGreen : .systemOrange
        postStatusLabel.stringValue = ""

        if numpadEnabled {
            if allGranted {
                numpadRuntimeStatusLabel.stringValue = "數字鍵盤修正：開啟"
                numpadRuntimeStatusLabel.textColor = .systemGreen
            } else {
                let missing = firstMissingPermissionName(
                    accessibilityGranted: accessibilityGranted,
                    inputMonitoringGranted: inputMonitoringGranted
                )
                numpadRuntimeStatusLabel.stringValue = "數字鍵盤：缺少\(missing)"
                numpadRuntimeStatusLabel.textColor = .systemOrange
            }
        } else {
            numpadRuntimeStatusLabel.stringValue = "數字鍵盤修正：關閉"
            numpadRuntimeStatusLabel.textColor = .secondaryLabelColor
        }

        permissionNextStepLabel.stringValue = "下一步：先按「開始權限設定引導」，照著 4 個步驟完成權限設定；完成後回來按「重新檢查」。"
        permissionNextStepLabel.isHidden = !hasMissingPermission
        openAccessibilitySettingsButton.toolTip = "開啟系統設定中的輔助使用分頁"
        openInputMonitoringSettingsButton.toolTip = "開啟系統設定中的輸入監控分頁"
        saveButton.toolTip = hasMissingPermission
            ? "需要完成權限設定後才能啟用完整功能"
            : "儲存設定並啟用"
        updateNumpadTestStatus()
        updatePrimaryButtonState()
    }

    private func permissionLine(title: String, granted: Bool) -> String {
        let mark = granted ? "☑" : "☐"
        return "\(mark) \(title)"
    }

    private func permissionStatusSummary(title: String, items: [(String, Bool)]) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: "\(title)：",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.labelColor
            ]
        )

        for (index, item) in items.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(
                    string: "　",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 12),
                        .foregroundColor: NSColor.secondaryLabelColor
                    ]
                ))
            }

            let mark = item.1 ? "☑" : "☐"
            let status = item.1 ? "已完成" : "待開啟"
            result.append(NSAttributedString(
                string: "\(mark) \(item.0)：\(status)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: item.1 ? NSColor.systemGreen : NSColor.systemOrange
                ]
            ))
        }

        return result
    }

    private func permissionName(_ title: String, granted: Bool) -> String {
        let mark = granted ? "☑" : "☐"
        return "\(mark) \(title)"
    }

    private func firstMissingPermissionName(accessibilityGranted: Bool, inputMonitoringGranted: Bool) -> String {
        if !accessibilityGranted {
            return "輔助使用權限"
        }
        if !inputMonitoringGranted {
            return "輸入監控權限"
        }
        return "必要權限"
    }

    private func hasMissingPermissions() -> Bool {
        hasMissingWorkflowPermissions()
    }

    private func updateRuntimeStatus() {
        let snapshot = workflowStatusSnapshot(
            config: buildConfig(),
            inputSources: inputSources,
            inputSourceManager: inputSourceManager,
            appTracker: appTracker
        )

        currentAppStatusLabel.stringValue = snapshot.appStatus
        appliedRuleStatusLabel.stringValue = "套用規則：\(snapshot.ruleDescription)"
        currentInputStatusLabel.stringValue = snapshot.currentInputStatus

        let autoSwitchStatus = autoSwitchStatusProvider()
        let operationStatus: String
        let ruleSegment: String
        if hasMissingPermissions() {
            operationStatus = "● 需要權限"
            ruleSegment = "待啟用規則：\(snapshot.ruleDescription)"
        } else if !autoSwitchStatus.isEnabled {
            operationStatus = "● 尚未啟用"
            ruleSegment = "套用規則：尚未啟用"
        } else if autoSwitchStatus.isPaused {
            let remaining = InputMethodAgent.durationText(autoSwitchStatus.pauseRemainingSeconds ?? 0)
            operationStatus = "● 已暫停　剩餘 \(remaining)"
            ruleSegment = "規則：暫停中"
        } else if snapshot.needsInputSwitch, let targetInputSourceName = snapshot.targetInputSourceName {
            operationStatus = "● 切換中"
            ruleSegment = "目標輸入法：\(targetInputSourceName)"
        } else {
            operationStatus = "● 自動切換中"
            ruleSegment = "套用規則：\(snapshot.ruleDescription)"
        }

        if autoSwitchStatus.isPaused {
            runtimeStatusLineLabel.stringValue = "\(operationStatus)　｜　\(snapshot.appStatus)　｜　\(snapshot.currentInputStatus)"
        } else {
            runtimeStatusLineLabel.stringValue = "\(operationStatus)　\(snapshot.appStatus)　｜　\(ruleSegment)　｜　\(snapshot.currentInputStatus)"
        }

        updatePrimaryButtonState()
    }

    private func updateNumpadTestStatus() {
        guard numpadAsciiCheckbox.state == .on else {
            numpadTestField.isEnabled = false
            numpadTestField.placeholderString = "開啟數字鍵盤修正後才能測試"
            numpadTestStatusLabel.stringValue = "輸出結果：尚未測試　｜　狀態：未開啟"
            return
        }

        let hasRequiredPermissions = NumpadAsciiEnforcer.isAccessibilityTrusted(prompt: false)
            && NumpadAsciiEnforcer.hasListenEventAccess()
            && NumpadAsciiEnforcer.hasPostEventAccess()
        guard hasRequiredPermissions else {
            numpadTestField.isEnabled = false
            numpadTestField.placeholderString = "需開啟權限後才能測試"
            numpadTestStatusLabel.stringValue = "輸出結果：尚未測試　｜　狀態：等待權限"
            return
        }

        numpadTestField.isEnabled = true
        numpadTestField.placeholderString = "在這裡按右側數字鍵"
        let output = numpadTestField.stringValue
        guard !output.isEmpty else {
            numpadTestStatusLabel.stringValue = "輸出結果：尚未測試　｜　狀態：等待輸入"
            return
        }

        let allowed = CharacterSet(charactersIn: "0123456789.")
        let isHalfwidth = output.unicodeScalars.allSatisfy { allowed.contains($0) }
        numpadTestStatusLabel.stringValue = isHalfwidth
            ? "輸出結果：\(output)　｜　狀態：半形正常"
            : "輸出結果：\(output)　｜　狀態：可能仍有全形字元"
    }

    private func startRuntimeStatusTimerIfNeeded() {
        guard runtimeStatusTimer == nil else {
            return
        }

        runtimeStatusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateRuntimeStatus()
            }
        }
    }

    @objc private func agentRuntimeStatusChanged(_ notification: Notification) {
        updateRuntimeStatus()
    }

    private func updatePrimaryButtonState() {
        let runtimeStatus = autoSwitchStatusProvider()
        if hasUnsavedChanges {
            saveButton.title = runtimeStatus.isEnabled ? "儲存變更" : "儲存並啟用"
            saveButton.isEnabled = true
            saveButton.toolTip = hasMissingPermissions()
                ? "儲存設定；需要完成權限後完整功能才會生效"
                : "儲存目前設定變更"
            saveButtonHelpLabel.stringValue = hasMissingPermissions()
                ? "儲存後，部分功能需完成權限才會生效"
                : "尚未儲存的變更"
            saveButtonHelpLabel.isHidden = false
        } else if hasMissingPermissions() {
            saveButton.title = "需要權限"
            saveButton.isEnabled = false
            saveButton.toolTip = "完成權限設定後即可啟用"
            saveButtonHelpLabel.stringValue = "完成權限設定後即可啟用"
            saveButtonHelpLabel.isHidden = false
        } else if !runtimeStatus.isEnabled {
            saveButton.title = "儲存並啟用"
            saveButton.isEnabled = true
            saveButton.toolTip = "儲存設定並啟用自動切換"
            saveButtonHelpLabel.stringValue = ""
            saveButtonHelpLabel.isHidden = true
        } else if runtimeStatus.isPaused {
            saveButton.title = "已啟用"
            saveButton.isEnabled = false
            saveButton.toolTip = "自動切換目前已暫停，可從選單列恢復"
            saveButtonHelpLabel.stringValue = "自動切換已暫停，可從選單列恢復"
            saveButtonHelpLabel.isHidden = false
        } else {
            saveButton.title = "已啟用"
            saveButton.isEnabled = false
            saveButton.toolTip = "設定已啟用"
            saveButtonHelpLabel.stringValue = ""
            saveButtonHelpLabel.isHidden = true
        }
    }

    func refreshFromStore() {
        capsLockInstantSwitchCheckbox.state = DeveloperFeatureFlags.capsLockEnabled(in: store.config) ? .on : .off
        numpadAsciiCheckbox.state = store.config.forceAsciiNumpad == true ? .on : .off
        numpadSpeedControl.isEnabled = numpadAsciiCheckbox.state == .on
        numpadSpeedControl.selectedSegment = NumpadAsciiSpeedMode.resolved(from: store.config.numpadAsciiSpeedMode) == .stable ? 1 : 0
        updatePermissionStatus()
        updateRuntimeStatus()
        updateNumpadTestStatus()
    }

    private func showOnboardingIfNeeded() {
        let key = "InputMethodAgentDidShowOnboarding"
        guard !UserDefaults.standard.bool(forKey: key) else {
            return
        }

        UserDefaults.standard.set(true, forKey: key)
        let alert = NSAlert()
        alert.messageText = "歡迎使用輸入法工作流設定"
        alert.informativeText = """
        這個工具可以：
        1. 為不同 App 自動切換輸入法
        2. 避免中文輸入法影響快捷鍵
        3. 讓數字鍵盤在注音狀態下仍輸入半形數字

        所有設定皆儲存在本機。
        App 不記錄、不儲存、不上傳任何輸入內容。

        開始時請先選擇全域預設輸入法，再套用常用規則或加入 App，最後開啟必要的 macOS 權限。
        """
        alert.addButton(withTitle: "開始設定")
        alert.runModal()
    }

    private func setupTable() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.rowHeight = 30
        tableView.headerView = NSTableHeaderView()

        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        let appColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        appColumn.title = "App"
        appColumn.width = 420
        tableView.addTableColumn(appColumn)

        let bundle = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("bundle"))
        bundle.title = "Bundle ID"
        bundle.width = 280
        bundleColumn = bundle

        let inputColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("input"))
        inputColumn.title = "開啟時使用"
        inputColumn.width = 300
        tableView.addTableColumn(inputColumn)
    }

    private func reloadDefaultPopup() {
        populate(defaultInputPopup)
        selectItem(in: defaultInputPopup, representedObject: store.config.defaultInputSourceID)
        updateGlobalDefaultSummary()
    }

    private func reloadSelectedInputPopup() {
        populate(selectedInputPopup)
        let row = tableView.selectedRow
        let visibleRules = filteredRules()
        let hasSelection = row >= 0 && row < visibleRules.count
        selectedInputPopup.isEnabled = hasSelection
        selectedInputPopup.isHidden = !hasSelection
        selectedInputPrefixLabel.isHidden = !hasSelection

        if hasSelection {
            let rule = visibleRules[row]
            selectedAppNameLabel.stringValue = "已選取：\(rule.displayName)"
            selectedInputPrefixLabel.stringValue = "開啟 \(rule.displayName) 時使用："
            selectItem(in: selectedInputPopup, representedObject: rule.inputSourceID)
        } else {
            selectedAppNameLabel.stringValue = "選取 App 後可設定輸入法"
            selectedInputPopup.selectItem(at: 0)
        }

        updateEmptyState()
    }

    private func populate(_ popup: NSPopUpButton) {
        popup.removeAllItems()
        if popup === selectedInputPopup {
            popup.addItem(withTitle: globalDefaultTitle())
            popup.lastItem?.representedObject = ""
        }

        for source in inputSources {
            popup.addItem(withTitle: displayName(for: source))
            popup.lastItem?.representedObject = source.id
        }
    }

    private func selectItem(in popup: NSPopUpButton, representedObject: String?) {
        if popup === selectedInputPopup, representedObject == nil {
            popup.selectItem(at: 0)
            return
        }

        guard let representedObject,
              let item = popup.itemArray.first(where: { $0.representedObject as? String == representedObject }) else {
            popup.selectItem(at: 0)
            return
        }

        popup.select(item)
    }

    private func displayName(for source: InputSourceInfo) -> String {
        if source.id == "com.apple.inputmethod.TCIM.Zhuyin" || source.name == "Zhuyin - Traditional" {
            return "繁體注音"
        }

        return source.name
    }

    private func inputSourceName(for id: String) -> String {
        if let source = inputSources.first(where: { $0.id == id }) {
            return displayName(for: source)
        }

        return id
    }


    private func selectedDefaultInputSourceID() -> String? {
        defaultInputPopup.selectedItem?.representedObject as? String ?? store.config.defaultInputSourceID
    }

    private func defaultInputSourceName() -> String {
        guard let id = selectedDefaultInputSourceID() else {
            return "未設定"
        }

        return inputSourceName(for: id)
    }

    private func globalDefaultTitle() -> String {
        "全域預設（\(defaultInputSourceName())）"
    }

    private func updateGlobalDefaultSummary() {
        globalDefaultSummaryLabel.stringValue = "未指定 App 使用：\(defaultInputSourceName())"
    }

    private func updateEmptyState() {
        let visibleCount = filteredRules().count
        emptyStateLabel.isHidden = visibleCount > 0
        if visibleCount == 0 {
            emptyStateLabel.stringValue = rules.isEmpty
                ? "尚未設定任何 App 規則\n加入常用 App，讓剪輯、設計、開發軟體自動切換到英文輸入法。"
                : "沒有符合篩選的 App 規則"
        }
    }

    @objc private func toggleAdvancedSettings() {
        advancedSettingsVisible.toggle()
        advancedSettingsBox.isHidden = !advancedSettingsVisible
        updateAdvancedToggleButtonTitle()
        UserDefaults.standard.set(advancedSettingsVisible, forKey: Self.advancedSettingsVisibleKey)
        window?.contentView?.needsLayout = true
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    private func updateAdvancedToggleButtonTitle() {
        let symbol = advancedSettingsVisible ? "▼" : "▶"
        let title = "\(symbol)  進階設定"
        let attributedTitle = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ]
        )
        attributedTitle.addAttributes(
            [
                .font: NSFont.systemFont(ofSize: 18, weight: .bold),
                .foregroundColor: NSColor.labelColor,
                .baselineOffset: -1
            ],
            range: NSRange(location: 0, length: 1)
        )
        advancedToggleButton.attributedTitle = attributedTitle
    }

    private func inputDescription(for rule: AppRule) -> String {
        if let inputSourceID = rule.inputSourceID {
            return inputSourceName(for: inputSourceID)
        }

        return globalDefaultTitle()
    }

    private func effectiveInputSourceID(for rule: AppRule) -> String? {
        rule.inputSourceID ?? selectedDefaultInputSourceID()
    }

    private func isABCInputSource(_ id: String?) -> Bool {
        guard let id else {
            return false
        }

        return id == "com.apple.keylayout.ABC" || inputSourceName(for: id).localizedCaseInsensitiveContains("ABC")
    }

    private func isZhuyinInputSource(_ id: String?) -> Bool {
        guard let id else {
            return false
        }

        let name = inputSourceName(for: id)
        return id == "com.apple.inputmethod.TCIM.Zhuyin"
            || name.localizedCaseInsensitiveContains("注音")
            || name.localizedCaseInsensitiveContains("Zhuyin")
    }

    private func filteredRules() -> [AppRule] {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = rules

        switch filterControl.selectedSegment {
        case 1:
            result = result.filter { $0.inputSourceID != nil }
        case 2:
            result = result.filter { $0.inputSourceID == nil }
        case 3:
            result = result.filter { isABCInputSource(effectiveInputSourceID(for: $0)) }
        case 4:
            result = result.filter { isZhuyinInputSource(effectiveInputSourceID(for: $0)) }
        default:
            break
        }

        guard !query.isEmpty else {
            return result
        }

        return result.filter { rule in
            rule.displayName.localizedCaseInsensitiveContains(query)
                || (showsBundleIDColumn && rule.bundleID.localizedCaseInsensitiveContains(query))
        }
    }

    private func selectedBundleID() -> String? {
        let row = tableView.selectedRow
        let visibleRules = filteredRules()

        guard row >= 0, row < visibleRules.count else {
            return nil
        }

        return visibleRules[row].bundleID
    }

    @objc private func searchChanged() {
        tableView.reloadData()
        reloadSelectedInputPopup()
        updateEmptyState()
    }

    @objc private func filterChanged() {
        tableView.reloadData()
        reloadSelectedInputPopup()
        updateEmptyState()
    }

    @objc private func defaultInputChanged() {
        updateGlobalDefaultSummary()
        tableView.reloadData()
        reloadSelectedInputPopup()
        updateRuntimeStatus()
        saveSilently()
    }

    @objc private func startupCheckboxChanged() {
        do {
            try StartupLaunchAgent.setEnabled(startupCheckbox.state == .on, configURL: store.url)
            if startupCheckbox.state == .on {
                updateStatus("已設定登入後自動啟動")
            } else {
                updateStatus("已取消登入後自動啟動")
            }
        } catch {
            startupCheckbox.state = StartupLaunchAgent.isEnabled() ? .on : .off
            showError(error)
        }
    }

    @objc private func capsLockInstantSwitchChanged() {
        saveSilently()
        if capsLockInstantSwitchCheckbox.state == .on {
            NumpadAsciiEnforcer.requestKeyboardPermissions()
            updateStatus("實驗功能 Caps Lock 快速切換：待儲存後生效")
        } else {
            updateStatus("實驗功能 Caps Lock 快速切換：待儲存後關閉並還原系統設定")
        }
        updatePermissionStatus()
    }

    @objc private func numpadAsciiCheckboxChanged() {
        numpadSpeedControl.isEnabled = numpadAsciiCheckbox.state == .on
        saveSilently()

        if numpadAsciiCheckbox.state == .on {
            NumpadAsciiEnforcer.requestKeyboardPermissions()
            updateNumpadStatusSnapshot()
        } else {
            updatePermissionStatus()
            updateStatus("已關閉數字鍵盤修正")
        }
    }

    @objc private func numpadSpeedChanged() {
        saveSilently()
        updateStatus("數字鍵盤速度：\(selectedSpeedMode().title)")
    }

    @objc private func selectedInputChanged() {
        guard let bundleID = selectedBundleID(),
              let index = rules.firstIndex(where: { $0.bundleID == bundleID }) else {
            return
        }

        let representedObject = selectedInputPopup.selectedItem?.representedObject as? String
        rules[index].inputSourceID = representedObject?.isEmpty == true ? nil : representedObject
        tableView.reloadData()
        updateRuntimeStatus()
        saveSilently()
    }

    @objc private func addRecentApplication() {
        guard let app = appTracker.currentApplication() else {
            updateStatus("找不到最近使用的 App")
            return
        }

        guard let bundleID = app.bundleIdentifier else {
            updateStatus("目前 App 沒有 Bundle ID")
            return
        }

        addOrUpdateRule(bundleID: bundleID, displayName: app.localizedName ?? bundleID)
    }

    @objc private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "選擇應用程式"
        panel.prompt = "加入"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        guard let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier else {
            updateStatus("無法讀取這個 App 的 Bundle ID")
            return
        }

        let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        addOrUpdateRule(bundleID: bundleID, displayName: displayName, icon: Self.icon(forApplicationURL: url))
    }

    @objc private func clearSelectedRule() {
        guard let bundleID = selectedBundleID(),
              let index = rules.firstIndex(where: { $0.bundleID == bundleID }) else {
            return
        }

        rules[index].inputSourceID = nil
        tableView.reloadData()
        saveSilently()
        reloadSelectedInputPopup()
        configureMoreActionsMenu()
        updateRuntimeStatus()
    }

    @objc private func rescanApplications() {
        rules = Self.loadApplicationRules(config: buildConfig())
        tableView.reloadData()
        reloadSelectedInputPopup()
        configureMoreActionsMenu()
        updateRuntimeStatus()
        updateStatus("已重新掃描，找到 \(rules.count) 個應用程式")
    }

    @objc private func copyBundleID(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else {
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(bundleID, forType: .string)
        updateStatus("已複製 Bundle ID")
    }

    @objc private func copySelectedBundleID() {
        guard let bundleID = selectedBundleID() else {
            updateStatus("請先選擇一個 App")
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(bundleID, forType: .string)
        updateStatus("已複製 Bundle ID")
    }

    @objc private func toggleBundleIDColumn() {
        showsBundleIDColumn.toggle()
        searchField.placeholderString = showsBundleIDColumn ? "搜尋 App 名稱或 Bundle ID" : "搜尋 App 名稱"
        updateBundleIDColumnVisibility()
        configureMoreActionsMenu()
        updateEmptyState()
    }

    @objc private func recheckPermissions() {
        updatePermissionStatus()
        updateRuntimeStatus()
        updateNumpadStatusSnapshot()
    }

    @objc private func showPermissionGuide() {
        if permissionGuideWindowController == nil {
            permissionGuideWindowController = PermissionGuideWindowController { [weak self] in
                self?.recheckPermissions()
            }
        }

        permissionGuideWindowController?.showWindow(self)
        permissionGuideWindowController?.window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showPrivacyInfo() {
        let alert = NSAlert()
        alert.messageText = "關於隱私與權限"
        alert.informativeText = """
        本 App 所有設定皆儲存在本機。
        不記錄、不儲存、不上傳任何輸入內容。
        App 不會讀取一般文字輸入內容。
        輔助使用權限僅用於偵測目前正在使用的 App、執行輸入法切換，並在數字鍵盤修正時送出右側數字鍵。
        輸入監控權限僅用於判斷右側數字鍵盤輸入。
        """
        alert.addButton(withTitle: "了解")
        alert.runModal()
    }

    @objc private func openAccessibilitySettings() {
        openSystemSettingsPane(
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            status: "已開啟輔助使用設定，請允許 Input Method Agent"
        )
    }

    @objc private func openInputMonitoringSettings() {
        openSystemSettingsPane(
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
            status: "已開啟輸入監控設定，請允許 Input Method Agent"
        )
    }

    private func openSystemSettingsPane(_ target: String, status: String) {
        if let url = URL(string: target), NSWorkspace.shared.open(url) {
            updateStatus(status)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }

    @objc private func applySuggestedRules() {
        let alert = NSAlert()
        alert.messageText = "套用常用 App 規則"
        alert.informativeText = """
        將依 App 類型套用以下輸入法：

        剪輯／設計 App  →  ABC
        開發工具        →  ABC
        通訊／文字 App  →  注音

        預設只會新增缺少的規則，不會覆蓋或刪除你已設定的 App 規則。
        未安裝的 App 會自動略過。
        """
        let overwriteCheckbox = NSButton(checkboxWithTitle: "覆蓋我已設定的規則", target: nil, action: nil)
        overwriteCheckbox.state = .off
        alert.accessoryView = overwriteCheckbox
        alert.addButton(withTitle: "套用")
        alert.addButton(withTitle: "取消")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        let shouldOverwriteExistingRules = overwriteCheckbox.state == .on
        var changedBundleIDs = Set<String>()
        var addedRulesCount = 0
        var keptExistingRules = 0
        var skippedMissingApplications = 0
        for template in Self.suggestedRuleTemplates {
            guard let sourceID = sourceID(for: template.source) else {
                continue
            }

            for index in rules.indices where matchesSuggestedTemplate(template, rule: rules[index]) {
                if rules[index].inputSourceID == nil || shouldOverwriteExistingRules {
                    if rules[index].inputSourceID != sourceID {
                        rules[index].inputSourceID = sourceID
                        changedBundleIDs.insert(rules[index].bundleID)
                    }
                } else {
                    keptExistingRules += 1
                }
            }

            for bundleID in template.bundleIDs where !rules.contains(where: { $0.bundleID == bundleID }) {
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
                      let bundle = Bundle(url: url) else {
                    skippedMissingApplications += 1
                    continue
                }

                let displayName = Self.displayName(for: bundle, url: url)
                rules.append(AppRule(
                    bundleID: bundleID,
                    displayName: displayName,
                    inputSourceID: sourceID,
                    icon: Self.icon(forApplicationURL: url)
                ))
                changedBundleIDs.insert(bundleID)
                addedRulesCount += 1
            }
        }

        rules.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        tableView.reloadData()
        reloadSelectedInputPopup()
        updateEmptyState()

        do {
            try store.update(buildConfig())
            hasUnsavedChanges = false
            updateRuntimeStatus()
            let updatedRulesCount = max(0, changedBundleIDs.count - addedRulesCount)
            let summary = "已新增 \(addedRulesCount) 個 App 規則，更新 \(updatedRulesCount) 個既有規則，保留 \(keptExistingRules) 個既有規則，略過 \(skippedMissingApplications) 個未安裝 App。"
            updateStatus("已套用常用 App 規則")
            showSuggestedRulesAppliedSummary(summary)
        } catch {
            showError(error)
        }
    }

    private func showSuggestedRulesAppliedSummary(_ summary: String) {
        let alert = NSAlert()
        alert.messageText = "已套用常用 App 規則"
        alert.informativeText = summary
        alert.addButton(withTitle: "了解")
        alert.runModal()
    }

    @objc private func saveConfig() {
        do {
            var config = buildConfig()
            config.autoSwitchEnabled = true
            try store.update(config)
            hasUnsavedChanges = false
            updatePermissionStatus()
            updateRuntimeStatus()
            updateStatus("已儲存並啟用")
        } catch {
            showError(error)
        }
    }

    private func saveSilently() {
        markSettingsChanged()
    }

    private func markSettingsChanged(_ message: String = "有未儲存的設定變更") {
        hasUnsavedChanges = true
        updateStatus(message)
        updatePrimaryButtonState()
    }

    private func buildConfig() -> AgentConfig {
        var appInputSources: [String: String] = [:]
        for rule in rules {
            if let inputSourceID = rule.inputSourceID {
                appInputSources[rule.bundleID] = inputSourceID
            }
        }

        return AgentConfig(
            defaultInputSourceID: defaultInputPopup.selectedItem?.representedObject as? String,
            appInputSources: appInputSources,
            logSwitches: store.config.logSwitches,
            forceAsciiNumpad: numpadAsciiCheckbox.state == .on,
            numpadAsciiSpeedMode: selectedSpeedMode().rawValue,
            instantCapsLockSwitch: DeveloperFeatureFlags.showCapsLockExperiment && capsLockInstantSwitchCheckbox.state == .on,
            autoSwitchEnabled: store.config.autoSwitchEnabled ?? true
        )
    }

    private func selectedSpeedMode() -> NumpadAsciiSpeedMode {
        numpadSpeedControl.selectedSegment == 1 ? .stable : .fast
    }

    private func addOrUpdateRule(bundleID: String, displayName: String, icon: NSImage? = nil) {
        let selectedID = defaultInputPopup.selectedItem?.representedObject as? String
            ?? inputSources.first?.id
            ?? "com.apple.keylayout.ABC"

        if let index = rules.firstIndex(where: { $0.bundleID == bundleID }) {
            rules[index].displayName = displayName
            rules[index].icon = icon ?? rules[index].icon ?? Self.icon(forBundleID: bundleID)
            if rules[index].inputSourceID == nil {
                rules[index].inputSourceID = selectedID
            }
        } else {
            rules.append(AppRule(
                bundleID: bundleID,
                displayName: displayName,
                inputSourceID: selectedID,
                icon: icon ?? Self.icon(forBundleID: bundleID)
            ))
            rules.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        }

        tableView.reloadData()
        selectVisibleRule(bundleID: bundleID)
        reloadSelectedInputPopup()
        configureMoreActionsMenu()
        updateRuntimeStatus()
        saveSilently()
    }

    private func selectVisibleRule(bundleID: String) {
        guard let row = filteredRules().firstIndex(where: { $0.bundleID == bundleID }) else {
            return
        }

        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    private func sourceID(for kind: SuggestedInputKind) -> String? {
        switch kind {
        case .abc:
            return inputSources.first(where: { $0.id == "com.apple.keylayout.ABC" })?.id
                ?? "com.apple.keylayout.ABC"
        case .zhuyin:
            return inputSources.first(where: { isZhuyinInputSource($0.id) })?.id
        }
    }

    private func matchesSuggestedTemplate(_ template: SuggestedRuleTemplate, rule: AppRule) -> Bool {
        let bundleID = rule.bundleID.lowercased()
        let displayName = rule.displayName.lowercased()

        if template.bundleIDs.contains(where: { bundleID.contains($0.lowercased()) }) {
            return true
        }

        return template.nameKeywords.contains { keyword in
            displayName.contains(keyword.lowercased()) || bundleID.contains(keyword.lowercased())
        }
    }

    private func configureMoreActionsMenu() {
        moreActionsPopup.removeAllItems()
        moreActionsPopup.addItem(withTitle: "更多")
        guard let menu = moreActionsPopup.menu else {
            return
        }

        menu.addItem(actionMenuItem("加入最近使用 App", action: #selector(addRecentApplication)))
        menu.addItem(actionMenuItem("重新掃描 App", action: #selector(rescanApplications)))
        menu.addItem(actionMenuItem("移除選取設定", action: #selector(clearSelectedRule), enabled: selectedBundleID() != nil))
        menu.addItem(.separator())
        menu.addItem(actionMenuItem(showsBundleIDColumn ? "隱藏 Bundle ID" : "顯示 Bundle ID", action: #selector(toggleBundleIDColumn)))
        menu.addItem(actionMenuItem("複製 Bundle ID", action: #selector(copySelectedBundleID), enabled: selectedBundleID() != nil))
        moreActionsPopup.selectItem(at: 0)
    }

    private func actionMenuItem(_ title: String, action: Selector, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        return item
    }

    private func updateBundleIDColumnVisibility() {
        guard let bundleColumn else {
            return
        }

        let isVisible = tableView.tableColumns.contains { $0 === bundleColumn }
        if showsBundleIDColumn, !isVisible {
            tableView.addTableColumn(bundleColumn)
            tableView.moveColumn(tableView.numberOfColumns - 1, toColumn: min(1, tableView.numberOfColumns - 1))
        } else if !showsBundleIDColumn, isVisible {
            tableView.removeTableColumn(bundleColumn)
        }

        tableView.reloadData()
    }

    private func appCellView(for rule: AppRule) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8

        let imageView = NSImageView()
        imageView.image = rule.icon ?? Self.genericApplicationIcon()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 18),
            imageView.heightAnchor.constraint(equalToConstant: 18)
        ])

        let textField = NSTextField(labelWithString: rule.displayName)
        textField.lineBreakMode = .byTruncatingTail
        textField.toolTip = rule.bundleID
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stack.toolTip = "Bundle ID: \(rule.bundleID)"
        stack.addArrangedSubview(imageView)
        stack.addArrangedSubview(textField)
        return stack
    }

    private func updateStatus(_ message: String) {
        statusLabel.stringValue = message
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }

    private func horizontalStack(spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private func secondaryLabel(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.textColor = .secondaryLabelColor
        field.font = .systemFont(ofSize: 12)
        field.lineBreakMode = .byWordWrapping
        field.usesSingleLineMode = false
        field.maximumNumberOfLines = 3
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func stepLabel(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.textColor = .secondaryLabelColor
        field.font = .systemFont(ofSize: 12, weight: .medium)
        return field
    }

    private func advancedSectionTitle(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.textColor = .secondaryLabelColor
        field.font = .systemFont(ofSize: 12, weight: .semibold)
        field.alignment = .left
        return field
    }

    private func sectionBox(title: String) -> (NSBox, NSStackView) {
        let box = NSBox()
        box.title = title
        box.contentViewMargins = NSSize(width: 14, height: 12)
        box.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        if let contentView = box.contentView {
            contentView.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                stack.topAnchor.constraint(equalTo: contentView.topAnchor),
                stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
            ])
        }

        return (box, stack)
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private static func displayName(forBundleID bundleID: String) -> String {
        if let runningApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }),
           let localizedName = runningApp.localizedName {
            return localizedName
        }

        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let bundle = Bundle(url: url) {
            return bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
        }

        return bundleID
    }

    private static func loadApplicationRules(config: AgentConfig) -> [AppRule] {
        var appsByBundleID: [String: AppRule] = [:]

        for app in installedApplications() {
            appsByBundleID[app.bundleID] = AppRule(
                bundleID: app.bundleID,
                displayName: app.displayName,
                inputSourceID: config.appInputSources[app.bundleID],
                icon: app.icon
            )
        }

        for (bundleID, inputSourceID) in config.appInputSources {
            if appsByBundleID[bundleID] == nil {
                appsByBundleID[bundleID] = AppRule(
                    bundleID: bundleID,
                    displayName: displayName(forBundleID: bundleID),
                    inputSourceID: inputSourceID,
                    icon: icon(forBundleID: bundleID)
                )
            }
        }

        return appsByBundleID.values.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private static func installedApplications() -> [AppRule] {
        var seenBundleIDs = Set<String>()
        var apps: [AppRule] = []

        for url in applicationSearchRoots() {
            guard FileManager.default.fileExists(atPath: url.path) else {
                continue
            }

            let options: FileManager.DirectoryEnumerationOptions = [
                .skipsHiddenFiles,
                .skipsPackageDescendants
            ]

            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isApplicationKey],
                options: options
            ) else {
                continue
            }

            for case let appURL as URL in enumerator where appURL.pathExtension == "app" {
                guard let bundle = Bundle(url: appURL),
                      let bundleID = bundle.bundleIdentifier,
                      !seenBundleIDs.contains(bundleID) else {
                    continue
                }

                seenBundleIDs.insert(bundleID)
                apps.append(AppRule(
                    bundleID: bundleID,
                    displayName: displayName(for: bundle, url: appURL),
                    inputSourceID: nil,
                    icon: icon(forApplicationURL: appURL)
                ))
            }
        }

        return apps
    }

    private static func applicationSearchRoots() -> [URL] {
        let roots = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities")
        ]

        var seenPaths = Set<String>()
        return roots.filter { url in
            let path = url.standardizedFileURL.path
            guard !seenPaths.contains(path) else {
                return false
            }

            seenPaths.insert(path)
            return true
        }
    }

    private static func displayName(for bundle: Bundle, url: URL) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
    }

    private static func icon(forApplicationURL url: URL) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 18, height: 18)
        return icon
    }

    private static func icon(forBundleID bundleID: String) -> NSImage? {
        if let runningIcon = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID })?.icon {
            runningIcon.size = NSSize(width: 18, height: 18)
            return runningIcon
        }

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }

        return icon(forApplicationURL: url)
    }

    private static func genericApplicationIcon() -> NSImage? {
        if let icon = NSImage(named: NSImage.applicationIconName) {
            icon.size = NSSize(width: 18, height: 18)
            return icon
        }

        return nil
    }

    private static func externalFrontmostApplication() -> NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              isExternalApplication(app) else {
            return nil
        }

        return app
    }

    private static func isExternalApplication(_ app: NSRunningApplication) -> Bool {
        app.processIdentifier != ProcessInfo.processInfo.processIdentifier
    }
}

@MainActor
final class GUIAppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store: ConfigStore
    private let agent: InputMethodAgent
    private let numpadAsciiEnforcer: NumpadAsciiEnforcer
    private let capsLockInputSwitcher: CapsLockInputSwitcher
    private let inputSourceManager: InputSourceManager
    private let inputSources: [InputSourceInfo]
    private let appTracker = FrontmostApplicationTracker()
    private var statusItem: NSStatusItem?
    private var settingsWindowController: SettingsWindowController?

    private enum MenuBarIconState {
        case active
        case paused
        case permissionNeeded
        case disabled
    }

    init(store: ConfigStore, inputSources: InputSourceManager) {
        self.store = store
        self.inputSourceManager = inputSources
        self.inputSources = inputSources.availableInputSources()
        self.agent = InputMethodAgent(configProvider: { store.config }, inputSources: inputSources)
        self.numpadAsciiEnforcer = NumpadAsciiEnforcer(configProvider: { store.config }, inputSources: inputSources)
        self.capsLockInputSwitcher = CapsLockInputSwitcher(
            configProvider: { DeveloperFeatureFlags.configWithHiddenExperimentsDisabled(store.config) },
            inputSources: inputSources
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupApplicationMenu()
        setupStatusItem()
        agent.startMonitoring()
        numpadAsciiEnforcer.refresh()
        CapsLockSystemSwitchPreference.applyManagedState(enabled: DeveloperFeatureFlags.capsLockEnabled(in: store.config))
        capsLockInputSwitcher.refresh()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(configChanged),
            name: .agentConfigChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(statusItemStateChanged(_:)),
            name: .agentRuntimeStatusChanged,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(frontmostApplicationChangedForStatusItem(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        openSettingsOnFirstLaunchIfNeeded()
    }

    private func openSettingsOnFirstLaunchIfNeeded() {
        let defaults = UserDefaults.standard
        let onboardingKey = "InputMethodAgentDidShowOnboarding"
        let autoOpenKey = "InputMethodAgentDidAutoOpenSettingsOnFirstLaunch"

        guard !defaults.bool(forKey: autoOpenKey) else {
            return
        }

        guard !defaults.bool(forKey: onboardingKey) else {
            defaults.set(true, forKey: autoOpenKey)
            return
        }

        defaults.set(true, forKey: autoOpenKey)
        DispatchQueue.main.async { [weak self] in
            self?.showSettings()
        }
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        numpadAsciiEnforcer.refresh()
        capsLockInputSwitcher.refresh()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildStatusMenu(menu)
    }

    @objc private func configChanged() {
        agent.refreshAfterConfigChange()
        numpadAsciiEnforcer.refresh()
        CapsLockSystemSwitchPreference.applyManagedState(enabled: DeveloperFeatureFlags.capsLockEnabled(in: store.config))
        capsLockInputSwitcher.refresh()
        settingsWindowController?.refreshFromStore()
        updateStatusItemIcon()
    }

    @objc private func statusItemStateChanged(_ notification: Notification) {
        updateStatusItemIcon()
    }

    @objc private func frontmostApplicationChangedForStatusItem(_ notification: Notification) {
        updateStatusItemIcon()
    }

    private func setupApplicationMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "輸入法工作流設定")
        let aboutItem = NSMenuItem(title: "關於輸入法工作流設定…", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出輸入法工作流設定", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "檔案")
        let closeItem = NSMenuItem(title: "關閉視窗", action: #selector(closeSettingsWindow), keyEquivalent: "w")
        closeItem.target = self
        fileMenu.addItem(closeItem)
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: 28)
        item.autosaveName = "InputMethodAgentStatusItem"
        item.isVisible = true
        item.button?.title = ""
        item.button?.image = makeStatusIcon(state: .active)
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "輸入法工作流設定"

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateStatusItemIcon()
    }

    private func rebuildStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let snapshot = currentStatusSnapshot()
        let autoSwitchEnabled = store.config.autoSwitchEnabled != false
        let permissionsMissing = hasMissingWorkflowPermissions()
        updateStatusItemIcon(state: menuBarIconState(autoSwitchEnabled: autoSwitchEnabled, permissionsMissing: permissionsMissing))
        let statusText: String
        if permissionsMissing {
            statusText = "需要權限"
        } else if !autoSwitchEnabled {
            statusText = "尚未啟用"
        } else if agent.isPaused {
            statusText = "已暫停，剩餘 \(InputMethodAgent.durationText(agent.pauseRemainingSeconds ?? 0))"
        } else if snapshot.needsInputSwitch {
            statusText = "切換中"
        } else {
            statusText = "自動切換中"
        }

        let ruleLine: String
        if permissionsMissing {
            ruleLine = "目前 App：\(snapshot.appName) ｜ 待啟用規則：\(snapshot.ruleDescription)"
        } else if agent.isPaused {
            ruleLine = "目前 App：\(snapshot.appName) ｜ 規則：暫停中"
        } else if autoSwitchEnabled, snapshot.needsInputSwitch, let targetInputSourceName = snapshot.targetInputSourceName {
            ruleLine = "目前 App：\(snapshot.appName) ｜ 目標：\(targetInputSourceName)"
        } else if autoSwitchEnabled {
            ruleLine = "目前 App：\(snapshot.appName) ｜ 規則：\(snapshot.ruleDescription)"
        } else {
            ruleLine = "目前 App：\(snapshot.appName) ｜ 規則：尚未啟用"
        }

        let inputTitle = autoSwitchEnabled && snapshot.needsInputSwitch && !agent.isPaused && !permissionsMissing ? "目前輸入法" : "輸入法"
        menu.addItem(statusHeaderMenuItem(lines: [
            "狀態：\(statusText)",
            ruleLine,
            "\(inputTitle)：\(snapshot.currentInputSourceName) ｜ 數字鍵盤：\(snapshot.numpadStatus)"
        ]))
        menu.addItem(.separator())

        let autoSwitchItem = actionMenuItem("自動切換", action: #selector(toggleAutoSwitch))
        autoSwitchItem.state = autoSwitchEnabled ? .on : .off
        menu.addItem(autoSwitchItem)

        let numpadItem = actionMenuItem("數字鍵盤修正", action: #selector(toggleNumpadCorrection))
        numpadItem.state = store.config.forceAsciiNumpad == true ? .on : .off
        menu.addItem(numpadItem)
        menu.addItem(.separator())

        if autoSwitchEnabled && !permissionsMissing {
            if agent.isPaused {
                menu.addItem(actionMenuItem("恢復自動切換", action: #selector(resumeAutoSwitching)))
            } else {
                menu.addItem(actionMenuItem("暫停自動切換 10 分鐘", action: #selector(pauseAutoSwitchingTenMinutes)))
                menu.addItem(actionMenuItem("暫停自動切換 1 小時", action: #selector(pauseAutoSwitchingOneHour)))
            }
            menu.addItem(.separator())
        }

        menu.addItem(actionMenuItem("開啟設定", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(actionMenuItem("關於輸入法工作流設定…", action: #selector(showAbout)))
        menu.addItem(actionMenuItem("回報問題", action: #selector(reportIssue)))
        menu.addItem(actionMenuItem("退出", action: #selector(quit), keyEquivalent: "q"))
    }

    private func currentStatusSnapshot() -> WorkflowStatusSnapshot {
        var snapshot = workflowStatusSnapshot(
            config: store.config,
            inputSources: inputSources,
            inputSourceManager: inputSourceManager,
            appTracker: appTracker
        )
        snapshot.numpadStatus = store.config.forceAsciiNumpad == true ? "開啟" : "關閉"
        return snapshot
    }

    private func statusHeaderMenuItem(lines: [String]) -> NSMenuItem {
        let item = NSMenuItem()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: CGFloat(lines.count * 19 + 16))

        for (index, line) in lines.enumerated() {
            let field = NSTextField(labelWithString: line)
            field.font = index == 0 ? .systemFont(ofSize: 13, weight: .semibold) : .systemFont(ofSize: 12)
            field.textColor = .labelColor
            field.lineBreakMode = .byTruncatingTail
            stack.addArrangedSubview(field)
        }

        item.view = stack
        return item
    }

    private func disabledMenuItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionMenuItem(_ title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private func inputSourceName(for id: String) -> String {
        guard let source = inputSources.first(where: { $0.id == id }) else {
            return id
        }

        return displayName(for: source)
    }

    private func displayName(for source: InputSourceInfo) -> String {
        if source.id == "com.apple.inputmethod.TCIM.Zhuyin" || source.name == "Zhuyin - Traditional" {
            return "繁體注音"
        }

        return source.name
    }

    private static func externalFrontmostApplication() -> NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }

        return app
    }

    private func updateConfig(_ update: (inout AgentConfig) -> Void) {
        var config = store.config
        update(&config)
        do {
            try store.update(config)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    private func menuBarIconState(autoSwitchEnabled: Bool? = nil, permissionsMissing: Bool? = nil) -> MenuBarIconState {
        let isMissingPermissions = permissionsMissing ?? hasMissingWorkflowPermissions()
        if isMissingPermissions {
            return .permissionNeeded
        }

        let isAutoSwitchEnabled = autoSwitchEnabled ?? (store.config.autoSwitchEnabled != false)
        if !isAutoSwitchEnabled {
            return .disabled
        }

        if agent.isPaused {
            return .paused
        }

        return .active
    }

    private func updateStatusItemIcon(state: MenuBarIconState? = nil) {
        let resolvedState = state ?? menuBarIconState()
        statusItem?.button?.image = makeStatusIcon(state: resolvedState)

        switch resolvedState {
        case .active:
            statusItem?.button?.toolTip = "輸入法工作流設定：自動切換中"
        case .paused:
            statusItem?.button?.toolTip = "輸入法工作流設定：已暫停"
        case .permissionNeeded:
            statusItem?.button?.toolTip = "輸入法工作流設定：需要權限"
        case .disabled:
            statusItem?.button?.toolTip = "輸入法工作流設定：尚未啟用"
        }
    }

    private func makeStatusIcon(state: MenuBarIconState) -> NSImage {
        let image = NSImage(size: NSSize(width: 24, height: 18), flipped: false) { _ in
            NSColor.clear.setFill()
            NSRect(x: 0, y: 0, width: 24, height: 18).fill()

            let baseAlpha: CGFloat = state == .disabled ? 0.50 : 1.0
            let inkBase: NSColor = .black
            let ink = inkBase.withAlphaComponent(baseAlpha)

            let keyboardRect = NSRect(x: 2.1, y: 3.2, width: 19.8, height: 11.2)
            let keyboardPath = NSBezierPath(roundedRect: keyboardRect, xRadius: 2.7, yRadius: 2.7)
            keyboardPath.lineWidth = 1.45
            if state == .permissionNeeded {
                NSColor.white.setFill()
                keyboardPath.fill()
            } else {
                ink.setStroke()
                ink.setFill()
                keyboardPath.stroke()
            }

            let mainKeys = [
                NSRect(x: 5.2, y: 10.0, width: 2.2, height: 1.35),
                NSRect(x: 8.7, y: 10.0, width: 2.2, height: 1.35),
                NSRect(x: 12.2, y: 10.0, width: 2.2, height: 1.35),
                NSRect(x: 5.2, y: 7.55, width: 2.2, height: 1.35),
                NSRect(x: 8.7, y: 7.55, width: 2.2, height: 1.35),
                NSRect(x: 12.2, y: 7.55, width: 2.2, height: 1.35),
                NSRect(x: 5.2, y: 5.0, width: 9.4, height: 1.35)
            ]

            let numpadKeys = [
                NSRect(x: 16.3, y: 10.0, width: 1.85, height: 1.35),
                NSRect(x: 18.65, y: 10.0, width: 1.65, height: 1.35),
                NSRect(x: 16.3, y: 7.55, width: 1.85, height: 1.35),
                NSRect(x: 18.65, y: 7.55, width: 1.65, height: 1.35),
                NSRect(x: 16.3, y: 5.0, width: 4.05, height: 1.35)
            ]

            if state == .permissionNeeded {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current?.cgContext.setBlendMode(.clear)
                for rect in mainKeys + numpadKeys {
                    NSBezierPath(roundedRect: rect, xRadius: 0.65, yRadius: 0.65).fill()
                }
                NSGraphicsContext.restoreGraphicsState()
            } else {
                ink.setFill()
                for rect in mainKeys + numpadKeys {
                    NSBezierPath(roundedRect: rect, xRadius: 0.65, yRadius: 0.65).fill()
                }
            }

            let markerColor: NSColor = state == .permissionNeeded ? .systemRed : inkBase
            markerColor.setStroke()
            markerColor.setFill()
            switch state {
            case .active:
                break
            case .paused:
                for rect in [
                    NSRect(x: 18.2, y: 12.6, width: 1.25, height: 4.5),
                    NSRect(x: 20.6, y: 12.6, width: 1.25, height: 4.5)
                ] {
                    NSBezierPath(roundedRect: rect, xRadius: 0.62, yRadius: 0.62).fill()
                }
            case .permissionNeeded:
                let warningCircle = NSBezierPath(ovalIn: NSRect(x: 16.1, y: 9.1, width: 7.8, height: 7.8))
                warningCircle.lineWidth = 1.45
                warningCircle.stroke()

                let mark = NSBezierPath()
                mark.move(to: NSPoint(x: 20.0, y: 15.5))
                mark.line(to: NSPoint(x: 20.0, y: 12.4))
                mark.lineWidth = 1.85
                mark.lineCapStyle = .round
                mark.stroke()
                NSBezierPath(ovalIn: NSRect(x: 19.05, y: 10.0, width: 1.9, height: 1.9)).fill()
            case .disabled:
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: 3.2, y: 3.4))
                slash.line(to: NSPoint(x: 21.0, y: 15.0))
                slash.lineWidth = 1.75
                slash.lineCapStyle = .round
                slash.stroke()
            }

            return true
        }

        image.isTemplate = state != .permissionNeeded
        return image
    }

    @objc private func toggleAutoSwitch() {
        let willEnable = store.config.autoSwitchEnabled == false
        updateConfig { config in
            config.autoSwitchEnabled = willEnable
        }
        if willEnable {
            agent.resume()
        } else {
            agent.refreshAfterConfigChange()
        }
    }

    @objc private func toggleNumpadCorrection() {
        let willEnable = store.config.forceAsciiNumpad != true
        updateConfig { config in
            config.forceAsciiNumpad = willEnable
        }
        if willEnable {
            NumpadAsciiEnforcer.requestKeyboardPermissions()
        }
        numpadAsciiEnforcer.refresh()
    }

    @objc private func pauseAutoSwitchingTenMinutes() {
        agent.pause(for: 10 * 60)
    }

    @objc private func pauseAutoSwitchingOneHour() {
        agent.pause(for: 60 * 60)
    }

    @objc private func resumeAutoSwitching() {
        agent.resume()
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "輸入法工作流設定"
        alert.informativeText = "版本：0.1.0 Beta\n\n本 App 所有設定皆儲存在本機。\n不記錄、不儲存、不上傳任何輸入內容。"
        alert.addButton(withTitle: "了解")
        alert.runModal()
    }

    @objc private func reportIssue() {
        let body = """
        App 版本：0.1.0 Beta
        macOS 版本：\(ProcessInfo.processInfo.operatingSystemVersionString)
        問題描述：
        重現步驟：
        預期結果：
        實際結果：
        """

        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "swallowkog@gmail.com"
        components.queryItems = [
            URLQueryItem(name: "subject", value: "輸入法工作流設定 Beta 問題回報"),
            URLQueryItem(name: "body", value: body)
        ]

        if let url = components.url, NSWorkspace.shared.open(url) {
            return
        }

        let alert = NSAlert()
        alert.messageText = "無法開啟郵件 App"
        alert.informativeText = "請將問題描述寄到：\nswallowkog@gmail.com"
        alert.addButton(withTitle: "了解")
        alert.runModal()
    }

    @objc private func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                store: store,
                inputSources: inputSources,
                appTracker: appTracker,
                autoSwitchStatusProvider: { [weak self] in
                    guard let self else {
                        return AutoSwitchRuntimeStatus(isEnabled: true, isPaused: false, pauseRemainingSeconds: nil)
                    }

                    return AutoSwitchRuntimeStatus(
                        isEnabled: self.store.config.autoSwitchEnabled != false,
                        isPaused: self.agent.isPaused,
                        pauseRemainingSeconds: self.agent.pauseRemainingSeconds
                    )
                }
            )
        }

        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func closeSettingsWindow() {
        settingsWindowController?.window?.performClose(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

func defaultConfigURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/input-method-agent/config.json")
}

func writeSampleConfig(to url: URL) throws {
    let sample = """
    {
      "defaultInputSourceID": "com.apple.keylayout.ABC",
      "logSwitches": false,
      "forceAsciiNumpad": false,
      "numpadAsciiSpeedMode": "fast",
      "instantCapsLockSwitch": false,
      "autoSwitchEnabled": true,
      "appInputSources": {
        "com.apple.TextEdit": "com.apple.inputmethod.TCIM.Zhuyin",
        "com.apple.Terminal": "com.apple.keylayout.ABC",
        "com.microsoft.VSCode": "com.apple.keylayout.ABC"
      }
    }
    """

    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try sample.write(to: url, atomically: true, encoding: .utf8)
}

func printUsage() {
    let executable = CommandLine.arguments.first ?? "input-method-agent"
    print("""
    Usage:
      \(executable) --gui [--config path]
      \(executable) --list
      \(executable) --init-config [path]
      \(executable) [--config path]

    Examples:
      \(executable) --gui
      \(executable) --list
      \(executable) --init-config
      \(executable) --config ~/.config/input-method-agent/config.json
    """)
}

func expandedURL(from path: String) -> URL {
    if path.hasPrefix("~/") {
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(String(path.dropFirst(2)))
    }

    return URL(fileURLWithPath: path)
}

func launchedFromAppBundle() -> Bool {
    if Bundle.main.bundleIdentifier == "local.input-method-agent" {
        return true
    }

    return CommandLine.arguments.first?.contains(".app/Contents/MacOS/") == true
}

let arguments = Array(CommandLine.arguments.dropFirst())
let inputSourceManager = InputSourceManager()

do {
    if arguments.contains("--help") || arguments.contains("-h") {
        printUsage()
        exit(EXIT_SUCCESS)
    }

    if arguments.contains("--list") {
        print("Available input sources:")
        for source in inputSourceManager.availableInputSources() {
            print("  \(source.id)  |  \(source.name)")
        }
        exit(EXIT_SUCCESS)
    }

    if let initIndex = arguments.firstIndex(of: "--init-config") {
        let url: URL
        if arguments.indices.contains(initIndex + 1), !arguments[initIndex + 1].hasPrefix("--") {
            url = expandedURL(from: arguments[initIndex + 1])
        } else {
            url = defaultConfigURL()
        }

        try writeSampleConfig(to: url)
        print("Wrote sample config: \(url.path)")
        exit(EXIT_SUCCESS)
    }

    let configURL: URL
    if let configIndex = arguments.firstIndex(of: "--config"),
       arguments.indices.contains(configIndex + 1) {
        configURL = expandedURL(from: arguments[configIndex + 1])
    } else {
        configURL = defaultConfigURL()
    }

    let store = ConfigStore(url: configURL)

    let launchedAsAppBundle = launchedFromAppBundle()

    if arguments.contains("--gui") || launchedAsAppBundle {
        let app = NSApplication.shared
        let controller = GUIAppController(store: store, inputSources: inputSourceManager)
        app.delegate = controller

        withExtendedLifetime(controller) {
            app.run()
        }
    } else {
        let config = try ConfigStore.load(from: configURL)
        let effectiveCapsLockConfig = DeveloperFeatureFlags.configWithHiddenExperimentsDisabled(config)
        CapsLockSystemSwitchPreference.applyManagedState(enabled: DeveloperFeatureFlags.capsLockEnabled(in: config))
        let agent = InputMethodAgent(configProvider: { config }, inputSources: inputSourceManager)
        let capsLockInputSwitcher = CapsLockInputSwitcher(configProvider: { effectiveCapsLockConfig }, inputSources: inputSourceManager)
        agent.startMonitoring()
        capsLockInputSwitcher.refresh()
        RunLoop.main.run()
    }
} catch {
    fputs("[input-method-agent] \(error.localizedDescription)\n", stderr)
    printUsage()
    exit(EXIT_FAILURE)
}
