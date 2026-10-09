import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Darwin
import Foundation

// 全屏纯黑遮罩。会话保持解锁，进程继续跑。
// 事件回调必须很快返回，否则系统会关掉事件钩子，按键会漏进底下的 App。

private let hotKeySignature: OSType = {
    var value: OSType = 0
    for byte in "BLK1".utf8 {
        value = (value << 8) | OSType(byte)
    }
    return value
}()

private let hotKeyIDNumber: UInt32 = 1
private let deleteKey: Int64 = 51
private let forwardDeleteKey: Int64 = 117
private let returnKey: Int64 = 36
private let keypadEnterKey: Int64 = 76

private func err(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
}

private func exePath() -> String {
    if let url = Bundle.main.executableURL {
        return url.path
    }
    return CommandLine.arguments[0]
}

private func homeDirectory() -> String {
    if let env = getenv("HOME"), let value = String(validatingUTF8: env), !value.isEmpty {
        return value
    }
    return NSHomeDirectory()
}

/// 把 `~/.local/bin/blackout` 指到当前这份 App。从安装盘里直接运行时不写，免得指到会消失的路径。
private func installCommandLink() {
    let exe = exePath()
    guard exe.contains("/Blackout.app/Contents/MacOS/") else { return }
    if exe.hasPrefix("/Volumes/") { return }
    let binDir = URL(fileURLWithPath: homeDirectory(), isDirectory: true)
        .appendingPathComponent(".local/bin", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
    } catch {
        return
    }
    let quoted = "'" + exe.replacingOccurrences(of: "'", with: "'\\''") + "'"
    let script = "#!/bin/sh\nexec \(quoted) \"$@\"\n"
    let link = binDir.appendingPathComponent("blackout")
    if let existing = try? String(contentsOf: link, encoding: .utf8),
       existing.lowercased() == script.lowercased() {
        return
    }
    do {
        try script.write(to: link, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: link.path)
    } catch {
        return
    }
}

private func commandOnPath() -> Bool {
    let bin = URL(fileURLWithPath: homeDirectory(), isDirectory: true)
        .appendingPathComponent(".local/bin").path
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    return path.split(separator: ":").contains { String($0) == bin }
}

private func promptSetPhraseInTerminal() {
    let source = """
    on run argv
        try
            display dialog "还没有解锁口令。" & return & "打开终端设一次，输入时不会显示。" buttons {"稍后", "打开终端"} default button "打开终端" with title "blackout"
        on error
            return
        end try
        if button returned of result is "打开终端" then
            set exe to item 1 of argv
            tell application "Terminal"
                activate
                do script quoted form of exe & " set-phrase"
            end tell
        end if
    end run
    """
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", source, exePath()]
    try? task.run()
    task.waitUntilExit()
}

private enum Paths {
    static var dir: URL {
        let home: String
        if let env = getenv("HOME"), let value = String(validatingUTF8: env), !value.isEmpty {
            home = value
        } else {
            home = NSHomeDirectory()
        }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".config/blackout", isDirectory: true)
    }
    static var phrase: URL { dir.appendingPathComponent("phrase") }
    static var pid: URL { dir.appendingPathComponent("blackout.pid") }
    static var lock: URL { dir.appendingPathComponent("blackout.lock") }
    static var state: URL { dir.appendingPathComponent("state") }
    static var previousInput: URL { dir.appendingPathComponent("previous-input-source") }

    static func ensure() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }
}

private func phraseProblem(_ text: String) -> String? {
    if text.count < 5 { return "至少 5 个字符" }
    if text.count > 128 { return "最多 128 个字符" }
    if text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) {
        return "不能包含控制字符"
    }
    return nil
}

private func readPhrase() -> String? {
    guard let raw = try? String(contentsOf: Paths.phrase, encoding: .utf8) else { return nil }
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if phraseProblem(text) != nil { return nil }
    return text
}

private func writePhrase(_ text: String) throws {
    try Paths.ensure()
    try (text + "\n").write(to: Paths.phrase, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.phrase.path)
}

private func readState() -> String {
    let raw = (try? String(contentsOf: Paths.state, encoding: .utf8)) ?? ""
    return raw.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func writeState(_ value: String) {
    try? Paths.ensure()
    try? value.write(to: Paths.state, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.state.path)
}

private func runningPID() -> pid_t? {
    guard let raw = try? String(contentsOf: Paths.pid, encoding: .utf8) else { return nil }
    guard let pid = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return nil }
    if kill(pid, 0) == 0 { return pid }
    return nil
}

private func writePID() {
    try? Paths.ensure()
    let text = "\(getpid())\n"
    try? text.write(to: Paths.pid, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.pid.path)
}

private func removePIDIfOurs() {
    guard runningPID() == getpid() else { return }
    try? FileManager.default.removeItem(at: Paths.pid)
    try? FileManager.default.removeItem(at: Paths.state)
}

private var lockFD: Int32 = -1

private func acquireLock() -> Bool {
    if lockFD >= 0 { return true }
    do { try Paths.ensure() } catch { return false }
    let fd = open(Paths.lock.path, O_CREAT | O_RDWR, 0o600)
    if fd < 0 { return false }
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
        close(fd)
        return false
    }
    lockFD = fd
    return true
}

private struct PhraseMatcher {
    private let phrase: String
    private var buffer: [Character] = []
    // 一次回车只看最近这一段，避免有人一直按键把缓冲撑得太大。
    private let maxBuffer = 8192

    init(phrase: String) {
        self.phrase = phrase
    }

    mutating func feed(_ text: String) {
        guard !phrase.isEmpty, !text.isEmpty else { return }
        buffer.append(contentsOf: text)
        if buffer.count > maxBuffer {
            buffer.removeFirst(buffer.count - maxBuffer)
        }
    }

    mutating func backspace() {
        if !buffer.isEmpty { buffer.removeLast() }
    }

    /// 回车才检查。口令出现在任意位置即可，前后的其他字符忽略。失败后清空，下次重打。
    mutating func confirm() -> Bool {
        guard !phrase.isEmpty else { return false }
        let matched = String(buffer).contains(phrase)
        buffer.removeAll()
        return matched
    }

    static func runTests() -> Bool {
        var failures = 0
        func check(_ name: String, _ condition: Bool) {
            if !condition {
                failures += 1
                err("FAIL \(name)\n")
            }
        }

        var matcher = PhraseMatcher(phrase: "secret")
        matcher.feed("secret")
        check("needs enter", matcher.confirm() == true)

        matcher = PhraseMatcher(phrase: "secret")
        matcher.feed("xxsecret")
        check("prefix", matcher.confirm() == true)

        matcher = PhraseMatcher(phrase: "secret")
        matcher.feed("secretYY")
        check("suffix", matcher.confirm() == true)

        matcher = PhraseMatcher(phrase: "secret")
        matcher.feed("hello secret world")
        check("both sides", matcher.confirm() == true)

        matcher = PhraseMatcher(phrase: "secret")
        matcher.feed("secrXet")
        check("broken", matcher.confirm() == false)
        matcher.feed("xxsecret")
        check("retry after fail", matcher.confirm() == true)

        matcher = PhraseMatcher(phrase: "ab")
        matcher.feed("a")
        matcher.backspace()
        matcher.feed("zzabby")
        check("backspace", matcher.confirm() == true)

        matcher = PhraseMatcher(phrase: "你好呀")
        matcher.feed("啊你好呀哦")
        check("unicode", matcher.confirm() == true)

        check("short phrase", phraseProblem("tiny") != nil)
        check("ok phrase", phraseProblem("longenough") == nil)
        check("control", phraseProblem("ok\u{1}phrase") != nil)

        if failures == 0 {
            print("self-test ok")
            return true
        }
        err("self-test failed: \(failures)\n")
        return false
    }
}

private func isTypable(_ text: String) -> Bool {
    !text.isEmpty && text.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 }
}

private func unicodeString(_ event: CGEvent) -> String {
    var length = 0
    var buffer = [UniChar](repeating: 0, count: 8)
    event.keyboardGetUnicodeString(
        maxStringLength: 8,
        actualStringLength: &length,
        unicodeString: &buffer
    )
    guard length > 0 else { return "" }
    return String(utf16CodeUnits: buffer, count: length)
}

private func eventMask() -> CGEventMask {
    // 不含 mouseMoved。移动事件太密，回调一慢系统就会拆掉钩子，按键会漏下去。
    let bits = [1, 2, 3, 4, 6, 7, 10, 11, 12, 22, 25, 26, 27, 28, 29, 30, 31, 32]
    return bits.reduce(CGEventMask(0)) { mask, bit in
        mask | (CGEventMask(1) << CGEventMask(bit))
    }
}

private func eachDisplay(_ body: (CGDirectDisplayID) -> Void) {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    if CGGetActiveDisplayList(16, &ids, &count) == .success, count > 0 {
        for index in 0..<Int(count) {
            body(ids[index])
        }
    } else {
        body(CGMainDisplayID())
    }
}

private var cursorHides = 0

private func hideCursor() {
    eachDisplay { CGDisplayHideCursor($0) }
    cursorHides += 1
}

private func showCursorAll() {
    while cursorHides > 0 {
        eachDisplay { CGDisplayShowCursor($0) }
        cursorHides -= 1
    }
}

private func inputSourceID(_ source: TISInputSource) -> String? {
    guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
    return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
}

private func enabledInputSources(includeAll: Bool) -> [TISInputSource] {
    guard let list = TISCreateInputSourceList(nil, includeAll)?.takeRetainedValue() else { return [] }
    let array = list as NSArray
    var sources: [TISInputSource] = []
    for case let source as TISInputSource in array {
        sources.append(source)
    }
    return sources
}

private func selectInputSource(id: String) -> Bool {
    let sources = enabledInputSources(includeAll: false) + enabledInputSources(includeAll: true)
    for source in sources where inputSourceID(source) == id {
        return TISSelectInputSource(source) == noErr
    }
    return false
}

private func currentInputSourceID() -> String? {
    guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
    return inputSourceID(source)
}

private func rememberAndSwitchToASCII(phrase: String) {
    guard phrase.allSatisfy(\.isASCII) else { return }
    let current = currentInputSourceID() ?? ""
    if current == "com.apple.keylayout.ABC" || current == "com.apple.keylayout.US" {
        return
    }
    guard selectInputSource(id: "com.apple.keylayout.ABC") || selectInputSource(id: "com.apple.keylayout.US") else {
        return
    }
    if !current.isEmpty {
        try? Paths.ensure()
        try? current.write(to: Paths.previousInput, atomically: true, encoding: .utf8)
    }
}

private func restoreInputSource() {
    guard let raw = try? String(contentsOf: Paths.previousInput, encoding: .utf8) else { return }
    let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if !id.isEmpty {
        _ = selectInputSource(id: id)
    }
    try? FileManager.default.removeItem(at: Paths.previousInput)
}

private func recoverInputSourceIfOrphaned() {
    guard FileManager.default.fileExists(atPath: Paths.previousInput.path) else { return }
    guard runningPID() == nil else { return }
    let saved = currentInputSourceID()
    restoreInputSource()
    if currentInputSourceID() != saved {
        err("上次黑屏没有正常退出，已把输入法切回去。\n")
    }
}

private func processExitHook() {
    showCursorAll()
    removePIDIfOurs()
}

private final class ShieldPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private func makeShield(for screen: NSScreen) -> NSWindow {
    let panel = ShieldPanel(
        contentRect: screen.frame,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.isOpaque = true
    panel.hasShadow = false
    panel.backgroundColor = .black
    panel.isMovable = false
    panel.hidesOnDeactivate = false
    panel.ignoresMouseEvents = false
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .none
    panel.becomesKeyOnlyIfNeeded = true
    let view = NSView(frame: screen.frame)
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor.black.cgColor
    panel.contentView = view
    panel.setFrame(screen.frame, display: false)
    return panel
}

private enum Mode {
    case engage
    case watch
    case demo
}

private final class Engine {
    static var shared: Engine?

    let mode: Mode
    let visualOnly: Bool
    private var matcher = PhraseMatcher(phrase: "")
    private var covered = false
    private var windows: [NSWindow] = []
    private var tapPort: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var localMonitor: Any?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var signalSources: [DispatchSourceSignal] = []
    private var reassertTimer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var savedPresentation: NSApplication.PresentationOptions?
    private var exiting = false
    private var unlocking = false
    private var explainedPermission = false

    init(mode: Mode, visualOnly: Bool) {
        self.mode = mode
        self.visualOnly = visualOnly
    }

    func start() {
        installSignals()
        writePID()
        observeScreens()
        switch mode {
        case .watch:
            writeState("watching")
            registerHotKey()
            err("blackout 在等待。按 Control+Option+Command+B 黑屏。结束请运行 blackout quit。\n")
        case .engage, .demo:
            engage()
        }
    }

    func engage() {
        guard !covered, !exiting else { return }
        guard let phrase = readPhrase() else {
            missingPhrase()
            return
        }
        matcher = PhraseMatcher(phrase: phrase)
        unlocking = false
        if visualOnly {
            err("警告：没有拦住全局快捷键。聚焦、切换应用、调度中心可能露出底下的窗口。\n")
        } else if !installTap() {
            explainPermission()
            return
        }
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            removeTap()
            err("没有可用显示器，没有黑屏。\n")
            if mode != .watch { shutdown(code: 1) }
            return
        }
        windows = screens.map(makeShield(for:))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            for window in windows {
                window.orderFrontRegardless()
            }
        }
        if visualOnly {
            applyCoverFocus(takeKeysLocally: true, blockForceQuit: false)
        } else if IsSecureEventInputEnabled() {
            // 密码框会独占键盘，事件钩子看不到口令。先拿走焦点，钩子才能收到解锁按键。
            applyCoverFocus(takeKeysLocally: false, blockForceQuit: true)
        }
        hideCursor()
        rememberAndSwitchToASCII(phrase: phrase)
        covered = true
        writeState("covered")
        unregisterHotKey()
        startReassert()
        if mode == .demo {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.release(quit: true)
            }
        }
    }

    func release(quit: Bool) {
        let wasCovered = covered
        if covered {
            teardownCover()
        }
        let shouldExit = quit || mode != .watch
        if shouldExit {
            if wasCovered && mode == .demo {
                err("demo 结束，画面已恢复。\n")
            } else if wasCovered && mode == .engage {
                err("已解除黑屏。\n")
            }
            shutdown(code: 0)
            return
        }
        if wasCovered {
            err("已解除黑屏，继续等待快捷键。\n")
        }
        writeState("watching")
        registerHotKey()
    }

    func hotKeyPressed() {
        engage()
    }

    func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tapPort {
                CGEvent.tapEnable(tap: tapPort, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        guard covered, type == .keyDown else { return nil }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let command = event.flags.contains(.maskCommand)
        let control = event.flags.contains(.maskControl)
        if acceptKey(keyCode: keyCode, text: unicodeString(event), command: command, control: control) {
            scheduleUnlock()
        }
        return nil
    }

    private func feedLocal(_ event: NSEvent) {
        let keyCode = Int64(event.keyCode)
        let command = event.modifierFlags.contains(.command)
        let control = event.modifierFlags.contains(.control)
        if acceptKey(keyCode: keyCode, text: event.characters ?? "", command: command, control: control) {
            scheduleUnlock()
        }
    }

    private func acceptKey(keyCode: Int64, text: String, command: Bool, control: Bool) -> Bool {
        if keyCode == returnKey || keyCode == keypadEnterKey {
            if command || control || unlocking { return false }
            return matcher.confirm()
        }
        if keyCode == deleteKey || keyCode == forwardDeleteKey {
            matcher.backspace()
            return false
        }
        if command || control || !isTypable(text) { return false }
        matcher.feed(text)
        return false
    }

    private func scheduleUnlock() {
        guard !unlocking else { return }
        unlocking = true
        DispatchQueue.main.async { [weak self] in
            self?.release(quit: false)
        }
    }

    private func teardownCover() {
        covered = false
        reassertTimer?.invalidate()
        reassertTimer = nil
        removeTap()
        removeLocalMonitor()
        restorePresentation()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            for window in windows {
                window.orderOut(nil)
                window.close()
            }
            windows.removeAll()
        }
        showCursorAll()
        restoreInputSource()
    }

    private func shutdown(code: Int32) {
        if exiting { return }
        exiting = true
        if covered { teardownCover() }
        removePIDIfOurs()
        Darwin.exit(code)
    }

    private func missingPhrase() {
        err("还没有解锁口令。请先运行：blackout set-phrase\n")
        if mode != .watch { shutdown(code: 1) }
    }

    private func explainPermission() {
        let path = exePath()
        if explainedPermission {
            err("还是没有输入监控权限，没有黑屏。\n")
            if mode != .watch { shutdown(code: 1) }
            return
        }
        explainedPermission = true
        err(
            """
            无法拦截键盘，这次没有黑屏。
            请到「系统设置 → 隐私与安全性 → 输入监控」允许 blackout。
            如果那里没有，再到「辅助功能」里允许。允许后重新运行。
            程序路径：\(path)
            只想先遮住画面、可以接受快捷键穿透：blackout --visual-only

            """
        )
        NSApp.activate(ignoringOtherApps: true)
        promptForTrust()
        openPrivacySettings()
        if isatty(STDERR_FILENO) == 0 {
            let alert = NSAlert()
            alert.messageText = "需要输入监控权限"
            alert.informativeText = "blackout 要拦住键盘，否则快捷键会露出底下的窗口，口令也会打进当前文档。请在系统设置里允许后重新运行。\n\(path)"
            alert.runModal()
        }
        if mode != .watch { shutdown(code: 1) }
    }

    private func installTap() -> Bool {
        if tapPort != nil { return true }
        let callback: CGEventTapCallBack = { _, type, event, _ in
            guard let engine = Engine.shared else {
                return Unmanaged.passUnretained(event)
            }
            return engine.handleTap(type: type, event: event)
        }
        let locations: [CGEventTapLocation] = [.cghidEventTap, .cgSessionEventTap]
        for location in locations {
            guard let port = CGEvent.tapCreate(
                tap: location,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: eventMask(),
                callback: callback,
                userInfo: nil
            ) else { continue }
            guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else { continue }
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            tapPort = port
            tapSource = source
            return true
        }
        return false
    }

    private func removeTap() {
        if let tapPort {
            CGEvent.tapEnable(tap: tapPort, enable: false)
        }
        if let tapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes)
        }
        tapPort = nil
        tapSource = nil
    }

    private func applyCoverFocus(takeKeysLocally: Bool, blockForceQuit: Bool) {
        savedPresentation = NSApp.presentationOptions
        var options: NSApplication.PresentationOptions = [
            .hideDock,
            .hideMenuBar,
            .disableProcessSwitching,
            .disableHideApplication,
            .disableAppleMenu
        ]
        if blockForceQuit {
            options.insert(.disableForceQuit)
        }
        NSApp.presentationOptions = options
        NSApp.activate(ignoringOtherApps: true)
        guard takeKeysLocally else { return }
        windows.first?.makeKey()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            Engine.shared?.feedLocal(event)
            return nil
        }
    }

    private func restorePresentation() {
        if let savedPresentation {
            NSApp.presentationOptions = savedPresentation
            self.savedPresentation = nil
        }
    }

    private func removeLocalMonitor() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    private func startReassert() {
        reassertTimer?.invalidate()
        reassertTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.reassert()
        }
    }

    private func reassert() {
        guard covered else { return }
        for window in windows where !window.isVisible {
            window.orderFrontRegardless()
        }
        for window in windows {
            window.orderFrontRegardless()
        }
    }

    private func observeScreens() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.relayout()
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.covered else { return }
            hideCursor()
            self.relayout()
        }
    }

    private func relayout() {
        guard covered else { return }
        let fresh = NSScreen.screens.map(makeShield(for:))
        guard !fresh.isEmpty else { return }
        let old = windows
        windows = fresh
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            for window in fresh {
                window.orderFrontRegardless()
            }
            for window in old {
                window.orderOut(nil)
                window.close()
            }
        }
    }

    private func installSignals() {
        signal(SIGUSR1, SIG_IGN)
        signal(SIGUSR2, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        func make(_ sig: Int32, _ body: @escaping () -> Void) {
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler(handler: body)
            source.resume()
            signalSources.append(source)
        }
        make(SIGUSR1) { [weak self] in self?.release(quit: false) }
        make(SIGUSR2) { [weak self] in self?.engage() }
        make(SIGTERM) { [weak self] in self?.release(quit: true) }
    }

    private func registerHotKey() {
        unregisterHotKey()
        if hotKeyHandler == nil {
            var spec = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
            let status = InstallEventHandler(
                GetApplicationEventTarget(),
                hotKeyCallback,
                1,
                &spec,
                nil,
                &hotKeyHandler
            )
            if status != noErr {
                err("快捷键装不上（\(status)）。仍可用另一终端运行 blackout 来黑屏。\n")
                return
            }
        }
        let identity = EventHotKeyID(signature: hotKeySignature, id: hotKeyIDNumber)
        let modifiers = UInt32(cmdKey | optionKey | controlKey)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_B),
            modifiers,
            identity,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status != noErr {
            err("Control+Option+Command+B 注册失败（\(status)）。仍可用 blackout 命令黑屏。\n")
            return
        }
        hotKeyRef = ref
    }

    private func unregisterHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }
}

private func hotKeyCallback(
    _: EventHandlerCallRef?,
    event: EventRef?,
    _: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return noErr }
    var identity = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identity
    )
    if status == noErr, identity.id == hotKeyIDNumber {
        DispatchQueue.main.async {
            Engine.shared?.hotKeyPressed()
        }
    }
    return noErr
}

private func promptForTrust() {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let options = [key: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
}

private func openPrivacySettings() {
    let urls = [
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
    ]
    for text in urls {
        guard let url = URL(string: text) else { continue }
        if NSWorkspace.shared.open(url) { return }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine: Engine
    init(engine: Engine) { self.engine = engine }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine.start()
    }
}

private func launch(mode: Mode, visualOnly: Bool) {
    guard readPhrase() != nil else {
        err("还没有解锁口令。请先运行：blackout set-phrase\n")
        if isatty(STDIN_FILENO) == 0 && isatty(STDERR_FILENO) == 0 {
            promptSetPhraseInTerminal()
        }
        exit(1)
    }
    if mode == .watch {
        guard acquireLock() else {
            err("blackout 已经在运行。用 blackout status 查看。\n")
            exit(1)
        }
    } else if !acquireLock() {
        usleep(200_000)
        if runningPID() != nil {
            _ = relayToRunning(SIGUSR2)
        } else {
            err("blackout 正在启动，请稍后再试。\n")
        }
        exit(0)
    }
    atexit(processExitHook)
    let engine = Engine(mode: mode, visualOnly: visualOnly)
    Engine.shared = engine
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate(engine: engine)
    app.delegate = delegate
    app.run()
}

private func relayToRunning(_ signal: Int32) -> Bool {
    guard let pid = runningPID() else { return false }
    return kill(pid, signal) == 0
}

private func waitUntilStopped(_ pid: pid_t) -> Bool {
    for _ in 0..<30 {
        if kill(pid, 0) != 0 { return true }
        usleep(50_000)
    }
    return kill(pid, 0) != 0
}

private func commandOff() {
    guard let pid = runningPID() else {
        err("blackout 没在运行。\n")
        exit(1)
    }
    if readState() != "covered" {
        err("当前没有黑屏。常驻进程还在（pid \(pid)）。\n")
        exit(0)
    }
    if kill(pid, SIGUSR1) != 0 {
        err("解除失败。\n")
        exit(1)
    }
    err("已发送解除信号。\n")
}

private func commandQuit() {
    guard let pid = runningPID() else {
        err("blackout 没在运行。\n")
        exit(0)
    }
    _ = kill(pid, SIGTERM)
    if waitUntilStopped(pid) {
        err("已退出。\n")
        return
    }
    _ = kill(pid, SIGKILL)
    if waitUntilStopped(pid) {
        err("已强制退出。\n")
        return
    }
    err("进程还在（pid \(pid)）。可以在另一终端运行 kill -9 \(pid)\n")
    exit(1)
}

private func commandStatus() {
    let phrase = readPhrase() == nil ? "未设置" : "已设置"
    guard let pid = runningPID() else {
        print("未运行")
        print("口令：\(phrase)")
        print("配置：\(Paths.dir.path)")
        return
    }
    let label: String
    switch readState() {
    case "watching": label = "等待快捷键 Control+Option+Command+B"
    case "covered": label = "黑屏中"
    case let other where other.isEmpty: label = "运行中"
    case let other: label = other
    }
    print("运行中（pid \(pid)）：\(label)")
    print("口令：\(phrase)")
    print("配置：\(Paths.dir.path)")
    print("程序：\(exePath())")
}

private func readSecret(_ prompt: String) -> String? {
    err(prompt)
    guard isatty(STDIN_FILENO) == 1 else {
        return readLine(strippingNewline: true)
    }
    var old = termios()
    guard tcgetattr(STDIN_FILENO, &old) == 0 else { return nil }
    savedEcho = old
    var hidden = old
    hidden.c_lflag &= ~tcflag_t(Darwin.ECHO)
    echoHidden = true
    tcsetattr(STDIN_FILENO, TCSANOW, &hidden)
    defer {
        tcsetattr(STDIN_FILENO, TCSANOW, &savedEcho)
        echoHidden = false
        err("\n")
    }
    return readLine(strippingNewline: true)
}

private var savedEcho = termios()
private var echoHidden = false

private func sigintDuringPhrase(_: Int32) {
    if echoHidden {
        tcsetattr(STDIN_FILENO, TCSANOW, &savedEcho)
    }
    _exit(130)
}

private func hideEchoForSetup() {
    signal(SIGINT, sigintDuringPhrase)
}

private func commandSetPhrase() {
    hideEchoForSetup()
    for _ in 0..<3 {
        guard let first = readSecret("解锁口令（输入时不显示，至少 5 位）：") else {
            err("没有读到口令。\n")
            exit(1)
        }
        let phrase = first.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = phraseProblem(phrase) {
            err("\(problem)。请重设。\n")
            continue
        }
        guard let second = readSecret("再输入一次：") else {
            err("没有读到口令。\n")
            exit(1)
        }
        if phrase != second.trimmingCharacters(in: .whitespacesAndNewlines) {
            err("两次不一致。\n")
            continue
        }
        do {
            try writePhrase(phrase)
        } catch {
            err("保存失败：\(error.localizedDescription)\n")
            exit(1)
        }
        err("已保存到 \(Paths.phrase.path)\n")
        err("黑屏后没有提示。口令前后可以夹别的字，打完按回车才退出。区分大小写。\n")
        if !commandOnPath() {
            err("当前终端如果找不到 blackout，先执行：export PATH=\"$HOME/.local/bin:$PATH\"\n")
        }
        if phrase.allSatisfy(\.isASCII) == false {
            err("口令含非英文字符。黑屏时不会切到英文输入法，输入法候选条可能露出来。\n")
        }
        if Set(phrase).count == 1 {
            err("这个口令只有一种字符，有人一直按同一个键时有机会撞上。\n")
        }
        if runningPID() != nil {
            err("正在运行的 blackout 仍使用启动时的口令。这次黑屏结束后，下次才用新口令。\n")
        }
        err("可以先运行 blackout demo，看 5 秒效果。\n")
        return
    }
    err("没有保存。\n")
    exit(1)
}

private func showCursorCommand() {
    for _ in 0..<8 {
        eachDisplay { CGDisplayShowCursor($0) }
    }
    for _ in 0..<8 {
        NSCursor.unhide()
    }
    err("已尝试恢复光标。\n")
}

private let helpText = """
blackout — 把所有显示器盖成纯黑。程序继续跑，会话也不锁定。这不是锁屏。

用法
  blackout set-phrase      设置盲打解锁口令（至少 5 位，不会写进口令参数）
  blackout                 立刻黑屏，解锁后退出
  blackout engage          同上，适合做成快捷指令
  blackout watch           常驻。按 Control+Option+Command+B 黑屏，解锁后继续等待
  blackout demo            黑屏 5 秒后自己恢复，用来看遮住了哪几块屏
  blackout off             解除黑屏。SSH 或其他终端里可以跑
  blackout quit            结束常驻进程
  blackout status          查看是否在运行
  blackout --show-cursor   光标如果还藏着，用这个恢复
  blackout --visual-only   不拦键盘，只盖一层黑。快捷键可能穿透
  blackout --self-test     跑口令匹配自测，不会黑屏
  blackout help            显示这段说明

安装
  打开 Blackout.dmg，把应用拖到「应用程序」文件夹，再打开一次。
  还没有口令时，会问要不要打开终端。输入时不显示，要输入两遍。
  命令放在 ~/.local/bin/blackout。这个目录不在 PATH 里时，用上面的提示把它加进去。

解锁
  黑屏后打一串字，里面含有口令即可，前后可以是别的字符。按回车才检查。
  没有输入框，也没有对错提示。回车时这段字里有口令，画面才回来。
  没有口令就保持黑屏，刚才打的内容作废，可以再打一次。
  纯英文口令会临时切到 ABC 输入法，退出后切回去。
  平常不抢走当前应用的焦点，下载和播放会继续。
  如果焦点当时在密码框里，会先拿走焦点，否则系统不让别的程序看到这些按键。
  忘了口令，或人在另一台电脑上：~/.local/bin/blackout off
  常驻进程没关终端也没关系，关掉终端不会退出。结束用 blackout quit

权限
  第一次黑屏会失败，并打开系统设置。允许「输入监控」里的 blackout。
  列表里没有的话，再看「辅助功能」。允许后重新运行这条命令。
  允许之后不要移动 Blackout.app。blackout status 会打印实际程序路径。
  重新编译后如果权限失效，把列表里的旧项删掉再允许一次。

从访达打开 Blackout.app、或放进登录项时，进入等待快捷键，不会立刻黑屏。
终端里直接运行 blackout 会立刻黑屏。

"""

private enum Command {
    case engage
    case watch
    case demo
    case off
    case quit
    case status
    case setPhrase
    case help
    case selfTest
    case showCursor
}

private func parseCommand() -> (Command, Bool) {
    var args = Array(CommandLine.arguments.dropFirst())
    var visualOnly = false
    if let index = args.firstIndex(of: "--visual-only") {
        visualOnly = true
        args.remove(at: index)
    }
    let name = args.first ?? ""
    if args.count > 1 {
        err("不能识别的参数：\(args.dropFirst().joined(separator: " "))\n")
        err("运行 blackout help 查看用法。\n")
        exit(2)
    }
    let command: Command
    switch name {
    case "", "engage":
        if name.isEmpty && isatty(STDIN_FILENO) == 0 {
            command = .watch
        } else {
            command = .engage
        }
    case "watch": command = .watch
    case "demo": command = .demo
    case "off", "unlock": command = .off
    case "quit", "stop": command = .quit
    case "status": command = .status
    case "set-phrase": command = .setPhrase
    case "help", "--help", "-h": command = .help
    case "--self-test": command = .selfTest
    case "--show-cursor": command = .showCursor
    default:
        err("不能识别的命令：\(name)\n运行 blackout help 查看用法。\n")
        exit(2)
    }
    return (command, visualOnly)
}

private func engageExistingOrLaunch(mode: Mode, visualOnly: Bool) {
    if let pid = runningPID() {
        let state = readState()
        if state == "covered" {
            err("已经是黑屏。\n")
            exit(0)
        }
        if kill(pid, SIGUSR2) == 0 {
            err("已让正在运行的 blackout 黑屏。\n")
            exit(0)
        }
    }
    launch(mode: mode, visualOnly: visualOnly)
}

recoverInputSourceIfOrphaned()
private let parsed = parseCommand()
if parsed.0 != .help && parsed.0 != .selfTest {
    installCommandLink()
}
switch parsed.0 {
case .help:
    print(helpText)
case .selfTest:
    exit(PhraseMatcher.runTests() ? 0 : 1)
case .showCursor:
    showCursorCommand()
case .setPhrase:
    commandSetPhrase()
case .status:
    commandStatus()
case .off:
    commandOff()
case .quit:
    commandQuit()
case .watch:
    launch(mode: .watch, visualOnly: parsed.1)
case .engage:
    engageExistingOrLaunch(mode: .engage, visualOnly: parsed.1)
case .demo:
    if runningPID() != nil {
        err("blackout 已经在运行。先 blackout quit，或直接 blackout 让它黑屏。\n")
        exit(1)
    }
    launch(mode: .demo, visualOnly: parsed.1)
}
