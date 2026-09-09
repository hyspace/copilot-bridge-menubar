import AppKit
import SwiftUI
import Combine
import Darwin

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var controller: BridgeController?
    private var observer: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A second copy must not own another daemon or race on the same token cache.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil); return
        }
        guard ProcessInfo.processInfo.machineArchitecture == "arm64" else { NSApp.terminate(nil); return }
        let model = BridgeController()
        controller = model
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        item.button?.image = NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: "Copilot Bridge")
        item.button?.target = self; item.button?.action = #selector(togglePopover)
        item.button?.toolTip = "Copilot Bridge — 已停止"
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 420, height: 620)
        popover.contentViewController = NSHostingController(rootView: MenuView(controller: model))
        observer = model.$state.sink { [weak self] state in
            self?.statusItem?.button?.toolTip = "Copilot Bridge — \(state.rawValue)"
            self?.statusItem?.button?.contentTintColor = state == .running ? .systemGreen : nil
        }
    }
    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if controller?.isActive == true { controller?.quit(); return .terminateCancel }
        return .terminateNow
    }
}

extension ProcessInfo {
    var machineArchitecture: String {
        var info = utsname(); uname(&info)
        let capacity = MemoryLayout.size(ofValue: info.machine)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
    }
}

if CommandLine.arguments.contains("--version") {
    print(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0")
    exit(0)
}
MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
