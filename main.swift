// LidLock keeps the Mac awake with the lid closed when enabled.
// Build: xcrun swiftc -swift-version 5 -O main.swift -o lidlock
// Check status: ./lidlock --status
// Test the privileged command and restore the initial setting: ./lidlock --once

import AppKit
import IOKit.ps

enum PmsetState: String {
    case unknown, active, inactive
}

enum SleepOperation {
    case launch(onAC: Bool)
    case refresh
    case toggle
    case quit
}

struct SleepResult {
    let state: PmsetState
    var error: String? = nil
}

final class PmsetHandle {
    private var sudoPassword: String?

    func perform(_ operation: SleepOperation) -> SleepResult {
        let state = Self.currentState()
        switch operation {
        case .launch(onAC: true) where state == .inactive:
            return change(to: .active)
        case .toggle where state == .active:
            return change(to: .inactive)
        case .toggle where state == .inactive:
            return change(to: .active)
        case .quit where state != .inactive:
            return change(to: .inactive)
        default:
            return SleepResult(state: state)
        }
    }

    static func currentState() -> PmsetState {
        let result = run("/usr/bin/pmset", ["-g"])
        guard result.success, !result.output.isEmpty else { return .unknown }
        for line in result.output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let key = fields.first?.lowercased(),
                  key == "sleepdisabled" || key == "disablesleep" else { continue }
            guard fields.count >= 2 else { return .unknown }
            switch fields[1] {
            case "1": return .active
            case "0": return .inactive
            default: return .unknown
            }
        }
        // pmset can omit the flag when disabled sleep is off.
        return .inactive
    }

    func change(to target: PmsetState, allowPasswordPrompt: Bool = true) -> SleepResult {
        let result = requestRoot(enabled: target == .active, allowPasswordPrompt: allowPasswordPrompt)
        var state = Self.currentState()
        if result.success {
            // Give powerd a short window to reflect the write.
            for _ in 0..<5 where state != target {
                Thread.sleep(forTimeInterval: 0.1)
                state = Self.currentState()
            }
            if state == target { return SleepResult(state: state) }
            return SleepResult(state: state, error: "macOS did not confirm the sleep setting")
        }
        let error = result.output.split(whereSeparator: \.isNewline).last.map(String.init)
        return SleepResult(state: state, error: error ?? "Could not update the sleep setting")
    }

    private func requestRoot(enabled: Bool, allowPasswordPrompt: Bool) -> (success: Bool, output: String) {
        let args = ["/usr/bin/pmset", "-a", "disablesleep", enabled ? "1" : "0"]
        let result = Self.run("/usr/bin/sudo", ["-n"] + args)
        let message = result.output.lowercased()
        guard !result.success, allowPasswordPrompt,
              message.contains("password") || message.contains("auth") || message.contains("sorry")
        else { return result }

        if let sudoPassword {
            let cached = Self.run("/usr/bin/sudo", ["-S"] + args, input: sudoPassword + "\n")
            if cached.success { return cached }
            self.sudoPassword = nil
        }

        let prompt = """
        tell application "System Events"
            display dialog "Enter your password for LidLock" default answer "" with hidden answer buttons {"Cancel", "OK"} default button 2
            text returned of result
        end tell
        """
        let entry = Self.run("/usr/bin/osascript", ["-e", prompt], captureStderr: false)
        guard entry.success, !entry.output.isEmpty else { return (false, "Authentication cancelled or unavailable") }

        let authenticated = Self.run("/usr/bin/sudo", ["-S"] + args, input: entry.output + "\n")
        if authenticated.success { sudoPassword = entry.output }
        return authenticated
    }

    private static func run(_ path: String, _ args: [String], input: String? = nil,
                            captureStderr: Bool = true) -> (success: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let output = Pipe()
        process.standardOutput = output
        process.standardError = captureStderr ? output : FileHandle.nullDevice

        let inputPipe = input.map { _ in Pipe() }
        if let inputPipe {
            process.standardInput = inputPipe
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        do {
            try process.run()
            if let input, let handle = inputPipe?.fileHandleForWriting {
                try? handle.write(contentsOf: Data(input.utf8))
                try? handle.close()
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            let trimSet: CharacterSet = captureStderr ? .whitespacesAndNewlines : .newlines
            return (process.terminationStatus == 0, text.trimmingCharacters(in: trimSet))
        } catch {
            return (false, error.localizedDescription)
        }
    }
}

enum PowerSource: String {
    case ac = "AC power"
    case battery = "Battery power"
    case unknown = "Power source unavailable"

    static func current() -> Self {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
        else { return .unknown }

        if source == kIOPSACPowerValue as String { return .ac }
        if source == kIOPSBatteryPowerValue as String { return .battery }
        return .unknown
    }
}

final class LidLockApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var toggleItem: NSMenuItem?
    private var infoItem: NSMenuItem?
    private var batteryWarnItem: NSMenuItem?
    private var powerNotifications: CFRunLoopSource?

    private let settings = PmsetHandle()
    private let settingsQueue = DispatchQueue(label: "lidlock.pmset", qos: .userInitiated)
    private var powerSource = PowerSource.unknown
    private var state = PmsetState.unknown
    private var lastError: String?
    private var busy = false
    private var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.alphaValue = 0.9

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        let title = NSMenuItem(title: "LidLock", action: nil, keyEquivalent: "")
        title.attributedTitle = Self.attributedTitle("LidLock", font: .boldSystemFont(ofSize: 11))
        menu.addItem(title)
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "Activate LidLock", action: #selector(toggleClicked), keyEquivalent: "")
        toggle.target = self
        toggleItem = toggle
        menu.addItem(toggle)

        let info = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        info.isEnabled = false
        infoItem = info
        menu.addItem(info)

        let warning = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        warning.isEnabled = false
        batteryWarnItem = warning
        menu.addItem(warning)

        let quit = NSMenuItem(title: "Quit LidLock", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        observePowerSource()
        powerSource = .current()
        run(.launch(onAC: powerSource == .ac))
    }

    @objc private func quitClicked() { NSApp.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !quitting {
            quitting = true
            run(.quit)
        }
        return .terminateLater
    }

    @objc private func toggleClicked() {
        guard !busy, !quitting else { return }
        run(.toggle)
    }

    func menuWillOpen(_ menu: NSMenu) {
        powerSource = .current()
        if busy || quitting {
            render()
        } else {
            run(.refresh)
        }
    }

    private func observePowerSource() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let app = Unmanaged<LidLockApp>.fromOpaque(context).takeUnretainedValue()
            app.powerSource = .current()
            app.render()
        }, context)?.takeRetainedValue() else { return }
        powerNotifications = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    private func run(_ operation: SleepOperation) {
        busy = true
        render()
        let settings = self.settings
        settingsQueue.async {
            let result = settings.perform(operation)
            // AppKit runs a modal event loop while waiting for a quit reply.
            let mainLoop = CFRunLoopGetMain()
            let modes = [RunLoop.Mode.common.rawValue, RunLoop.Mode.modalPanel.rawValue]
            CFRunLoopPerformBlock(mainLoop, modes as CFArray) { [weak self] in
                self?.finish(operation, result)
            }
            CFRunLoopWakeUp(mainLoop)
        }
    }

    private func finish(_ operation: SleepOperation, _ result: SleepResult) {
        state = result.state
        busy = false
        switch operation {
        case .refresh:
            break
        case .quit:
            quitting = false
            let canQuit = state == .inactive
            lastError = canQuit ? nil : (result.error ?? "Could not confirm that sleep was restored")
            render()
            NSApp.reply(toApplicationShouldTerminate: canQuit)
            return
        default:
            lastError = result.error
        }
        render()
    }

    private func render() {
        let dot: String
        let color: NSColor
        let description: String
        switch state {
        case .active:
            (dot, color, description) = ("●", .systemGreen, "Lid close sleep: prevented")
        case .inactive:
            (dot, color, description) = ("◌", .systemRed, "Sleep management: normal")
        case .unknown:
            (dot, color, description) = ("?", .secondaryLabelColor, "Sleep status unavailable")
        }
        statusItem?.button?.attributedTitle = Self.attributedTitle(dot,
            font: .monospacedSystemFont(ofSize: 14, weight: .medium), color: color)
        toggleItem?.title = state == .active ? "Deactivate LidLock" : "Activate LidLock"
        toggleItem?.isEnabled = !busy && !quitting && state != .unknown

        if quitting {
            infoItem?.title = "Restoring sleep before quitting…"
        } else if let lastError {
            infoItem?.title = "Error: \(lastError.prefix(100))"
        } else if busy && state == .unknown {
            infoItem?.title = "Checking sleep status…"
        } else {
            infoItem?.title = description
        }

        let onBattery = powerSource == .battery
        batteryWarnItem?.isHidden = !onBattery
        if onBattery {
            let active = state == .active
            let warning = active ? "On battery · LidLock is keeping the Mac awake" : "On battery · LidLock can drain the battery"
            batteryWarnItem?.attributedTitle = Self.attributedTitle(warning,
                font: .systemFont(ofSize: 10, weight: .medium),
                color: active ? .systemRed : .secondaryLabelColor)
        }
    }

    private static func attributedTitle(_ text: String, font: NSFont, color: NSColor = .labelColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    }
}

if CommandLine.arguments.contains("--status") {
    let state = PmsetHandle.currentState()
    print("LidLock: \(state.rawValue) · \(PowerSource.current().rawValue)")
    exit(state == .unknown ? 1 : 0)
}

if CommandLine.arguments.contains("--once") {
    let initial = PmsetHandle.currentState()
    guard initial != .unknown else {
        print("LidLock: could not read the initial sleep setting")
        exit(1)
    }
    let settings = PmsetHandle()
    let test = settings.change(to: initial == .active ? .inactive : .active, allowPasswordPrompt: false)
    print("LidLock test: \(test.error ?? test.state.rawValue)")
    if test.state != initial {
        let restored = settings.change(to: initial, allowPasswordPrompt: false)
        print("Restore: \(restored.error ?? restored.state.rawValue)")
        if restored.state != initial { exit(1) }
    }
    exit(test.error == nil ? 0 : 1)
}

let delegate = LidLockApp()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
