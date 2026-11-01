import AppKit
import Carbon.HIToolbox
import IOKit.pwr_mgt
import ServiceManagement

// BlackOut — 一键黑屏菜单栏工具
// 左键点月亮图标 / ⌃⌥B / 双击 app 图标：立即熄屏（任务继续跑）
// 黑屏时：按任意键/动鼠标/再按 ⌃⌥B 均可恢复（此时热键自动转为唤醒，不会重复熄屏）
// 首次启动自动注册登录项，重启后依然可用；熄屏期间自动创建“防空闲睡眠”断言。

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var assertionID: IOPMAssertionID = 0
    private var keepingAwake = false
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var screenAsleep = false
    private var lastScreenWakeAt: Date?
    private var lastBlackoutAt: Date?

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }

        button.image = NSImage(systemSymbolName: "moon.zzz", accessibilityDescription: "一键黑屏")
        button.toolTip = "左键：立即黑屏（任务继续跑）\n右键：菜单"
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.target = self
        button.action = #selector(statusClicked(_:))

        menu = buildMenu()
        registerHotKey()

        // 监听屏幕熄灭/唤醒：用于“黑屏时按热键 = 唤醒”的判定
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(screenDidSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(screenDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)

        // 重启后免折腾：首次启动自动注册登录项（右键菜单可随时关闭）
        if #available(macOS 13.0, *) {
            var result = "ok"
            if SMAppService.mainApp.status == .notRegistered {
                do { try SMAppService.mainApp.register() } catch { result = "fail:\(error.localizedDescription)" }
            }
            try? "BlackOut autostart \(Date()): \(result)\n".write(toFile: "/tmp/blackout-autostart.log", atomically: true, encoding: .utf8)
        }
    }

    // 屏幕熄灭/唤醒回调
    @objc private func screenDidSleep() { screenAsleep = true }
    @objc private func screenDidWake() {
        screenAsleep = false
        lastScreenWakeAt = Date()
    }

    // 双击 app 图标/替身（已在运行时）= 一键黑屏
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        blackout()
        return true
    }

    func applicationWillTerminate(_ note: Notification) {
        setAwake(false)
    }

    // MARK: - 菜单

    private func buildMenu() -> NSMenu {
        let m = NSMenu()
        m.delegate = self
        m.autoenablesItems = false

        let black = NSMenuItem(title: "立即黑屏（左键点图标，或按 ⌃⌥B）", action: #selector(blackout), keyEquivalent: "")
        black.target = self; black.isEnabled = true
        m.addItem(black)
        m.addItem(.separator())

        let awake = NSMenuItem(title: "保持唤醒（熄屏期间自动开启，任务跑完可关）", action: #selector(toggleAwake), keyEquivalent: "")
        awake.target = self; awake.isEnabled = true
        m.addItem(awake)

        let login = NSMenuItem(title: "开机自动启动", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self; login.isEnabled = true
        m.addItem(login)

        m.addItem(.separator())
        let quit = NSMenuItem(title: "退出 BlackOut", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp; quit.keyEquivalentModifierMask = .command
        quit.isEnabled = true
        m.addItem(quit)
        return m
    }

    // 每次打开菜单时刷新勾选状态
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where !item.isSeparatorItem {
            if item.action == #selector(toggleAwake) {
                item.state = keepingAwake ? .on : .off
            } else if item.action == #selector(toggleLoginItem) {
                item.state = loginItemEnabled ? .on : .off
            }
        }
    }

    // 菜单关闭后解除挂载，恢复“左键直触发熄屏”
    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }

    // MARK: - 全局快捷键 ⌃⌥B（Carbon RegisterEventHotKey，无需任何系统权限）

    private static let hotKeySignature = OSType(0x424C4B54)  // 'BLKT'

    private static let hotKeyHandler: EventHandlerUPP = { _, event, userData in
        var hkID = EventHotKeyID()
        let status = GetEventParameter(event,
                                       EventParamName(kEventParamDirectObject),
                                       EventParamType(typeEventHotKeyID),
                                       nil,
                                       MemoryLayout<EventHotKeyID>.size,
                                       nil,
                                       &hkID)
        if status == noErr, hkID.signature == AppDelegate.hotKeySignature {
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData!).takeUnretainedValue()
            delegate.blackout()
        }
        return noErr
    }

    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(GetApplicationEventTarget(),
                            AppDelegate.hotKeyHandler,
                            1,
                            &spec,
                            Unmanaged.passUnretained(self).toOpaque(),
                            &eventHandler)
        let id = EventHotKeyID(signature: AppDelegate.hotKeySignature, id: 1)
        let hotKeyStatus = RegisterEventHotKey(UInt32(kVK_ANSI_B),
                            UInt32(controlKey | optionKey),
                            id,
                            GetApplicationEventTarget(),
                            0,
                            &hotKeyRef)
        let report = "install=\(installStatus) register=\(hotKeyStatus)\n"
        NSLog("BlackOut ⌃⌥B 注册: %@", report)
        try? "BlackOut hotkey \(Date()): \(report)".write(toFile: "/tmp/blackout-hotkey.log", atomically: true, encoding: .utf8)
    }

    // MARK: - 点击事件

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { blackout(); return }
        let isRight = event.type == .rightMouseUp
        let isOption = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.option)
        if isRight || isOption {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
        } else {
            blackout()
        }
    }

    @objc private func blackout() {
        // 屏幕已熄灭：此时热键/点击意图是“唤醒”，交给系统亮屏，不再熄屏
        if screenAsleep { return }
        let now = Date()
        // 刚唤醒或刚熄屏 3 秒内的再次触发，视为唤醒动作，避免屏幕刚亮又被弄黑
        if let t = lastScreenWakeAt, now.timeIntervalSince(t) < 3 { return }
        if let t = lastBlackoutAt, now.timeIntervalSince(t) < 3 { return }
        lastBlackoutAt = now

        // 电池供电下系统很快会睡眠，先把“空闲睡眠”挡住，任务才能继续跑
        setAwake(true)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["displaysleepnow"]
        do {
            try task.run()
        } catch {
            NSSound.beep()
        }
    }

    @objc private func toggleAwake() {
        setAwake(!keepingAwake)
    }

    @objc private func toggleLoginItem() {
        guard #available(macOS 13.0, *) else { NSSound.beep(); return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "设置开机自启失败"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    // MARK: - 电源断言

    private func setAwake(_ on: Bool) {
        if on && !keepingAwake {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "BlackOut: 熄屏但任务继续运行" as CFString,
                &id)
            if result == kIOReturnSuccess {
                assertionID = id
                keepingAwake = true
                updateIcon()
            }
        } else if !on && keepingAwake {
            IOPMAssertionRelease(assertionID)
            keepingAwake = false
            updateIcon()
        }
    }

    private func updateIcon() {
        // 咖啡杯 = 正在保持唤醒，任务不会被系统睡眠打断
        let name = keepingAwake ? "cup.and.saucer.fill" : "moon.zzz"
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "一键黑屏")
    }

    private var loginItemEnabled: Bool {
        guard #available(macOS 13.0, *) else { return false }
        return SMAppService.mainApp.status == .enabled
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
