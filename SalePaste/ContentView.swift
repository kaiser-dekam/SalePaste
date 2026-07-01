import SwiftUI
import Cocoa

extension Notification.Name {
    static let openMainWindow = Notification.Name("openMainWindow")
}

@main
struct SalePasteApp: App {
    // Bridge to AppDelegate that manages the menu bar item
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("enabled") private var enabled: Bool = true

    var body: some Scene {
        // Settings scene (macOS 12+)
        #if os(macOS)
        Settings {
            SettingsView()
        }
        #endif

        // MenuBarExtra (macOS 13+)
        if #available(macOS 13.0, *) {
            MenuBarExtra(isInserted: .constant(true)) {
                MenuContent()
            } label: {
                Image(enabled ? "MenuBarIconActive" : "MenuBarIconStopped")
                    .renderingMode(.original)
            }
            .menuBarExtraStyle(.window)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    let pb = NSPasteboard.general
    var lastChangeCount: Int = -1
    var isSelfUpdate: Bool = false
    var mainWindow: NSWindow?
    private var mainWindowObserver: Any?

    // Global enable/disable switch
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "enabled") }
    }

    // Adjust your default percent here: +7% => 0.07; -5% => -0.05
    var percent: Double {
        get { UserDefaults.standard.double(forKey: "percentDelta") }
        set { UserDefaults.standard.set(newValue, forKey: "percentDelta") }
    }

    // Rounding settings: .none disables rounding, otherwise .up or .down; step can be 1, 5, or 10
    enum RoundingMode: Int {
        case none = 0
        case up = 1
        case down = 2
    }
    var roundingMode: RoundingMode {
        get {
            let raw = UserDefaults.standard.integer(forKey: "roundingMode")
            return RoundingMode(rawValue: raw) ?? .none
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "roundingMode") }
    }
    var roundingStep: Double {
        get {
            let val = UserDefaults.standard.double(forKey: "roundingStep")
            return val == 0 ? 1.0 : val
        }
        set { UserDefaults.standard.set(newValue, forKey: "roundingStep") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if UserDefaults.standard.object(forKey: "percentDelta") == nil {
            UserDefaults.standard.set(0.07, forKey: "percentDelta") // +7% default
        }
        if UserDefaults.standard.object(forKey: "roundingMode") == nil {
            UserDefaults.standard.set(0, forKey: "roundingMode") // none
        }
        if UserDefaults.standard.object(forKey: "roundingStep") == nil {
            UserDefaults.standard.set(1.0, forKey: "roundingStep")
        }
        if UserDefaults.standard.object(forKey: "enabled") == nil {
            UserDefaults.standard.set(true, forKey: "enabled")
        }
        if #available(macOS 13.0, *) {
            // MenuBarExtra provides the menu in SwiftUI; no AppKit status item
        } else {
            setupMenu()
        }
        lastChangeCount = pb.changeCount
        timer = Timer.scheduledTimer(timeInterval: 0.3, target: self, selector: #selector(checkClipboard), userInfo: nil, repeats: true)
        RunLoop.current.add(timer!, forMode: .common)
        mainWindowObserver = NotificationCenter.default.addObserver(
            forName: .openMainWindow, object: nil, queue: .main
        ) { [weak self] _ in self?.openMainWindow() }
        DispatchQueue.main.async { self.openMainWindow() }
        print("SalePaste started. Watching clipboard… percent=", percent)
    }

    func openMainWindow() {
        if mainWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 460),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "SalePaste"
            window.contentView = NSHostingView(rootView: RootView())
            window.center()
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            mainWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openMainWindow()
        return true
    }

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(named: isEnabled ? "MenuBarIconActive" : "MenuBarIconStopped")

        let menu = NSMenu()
        let toggleItem = NSMenuItem(title: isEnabled ? "Stop" : "Start", action: #selector(toggleEnabled), keyEquivalent: " ")
        toggleItem.keyEquivalentModifierMask = []
        menu.addItem(toggleItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        statusItem.menu = menu
    }

    private func updateAppKitToggleTitle() {
        guard let items = statusItem?.menu?.items else { return }
        if let first = items.first, first.action == #selector(toggleEnabled) {
            first.title = isEnabled ? "Stop" : "Start"
        }
        statusItem?.button?.image = NSImage(named: isEnabled ? "MenuBarIconActive" : "MenuBarIconStopped")
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func checkClipboard() {
        guard isEnabled else { return }
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        if isSelfUpdate {
            // Reset the flag and skip transforming to avoid repeat calculations
            isSelfUpdate = false
            return
        }

        guard let s = pb.string(forType: .string) else { return }
        if let transformed = transformIfSingleNumber(in: s, delta: percent) {
            writeToClipboard(transformed)
        }
    }

    private func writeToClipboard(_ text: String) {
        // Mark that the next pasteboard change is ours so we don't re-transform it
        isSelfUpdate = true
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// If the clipboard holds a single number-like string, transform it; otherwise return nil.
    private func transformIfSingleNumber(in input: String, delta: Double) -> String? {
        // Trim and reject multi-line or multi-token content (keep it simple)
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip common currency and spacing, keep digits, dot, minus, and commas
        let cleaned = trimmed.replacingOccurrences(of: "[^0-9.,\\-]", with: "", options: .regularExpression)

        // Reject if cleaning removed everything or if the original had obvious multiple tokens
        if cleaned.isEmpty || trimmed.contains(" ") || trimmed.contains("\n") { return nil }

        // Normalize: drop thousands commas, keep decimal dot
        let normalized = cleaned.replacingOccurrences(of: ",", with: "")
        guard let val = Double(normalized) else { return nil }

        let newVal = val * (1.0 + delta)

        var finalVal = newVal
        if roundingMode != .none {
            let step = roundingStep
            switch roundingMode {
            case .up:
                finalVal = ceil(finalVal / step) * step
            case .down:
                finalVal = floor(finalVal / step) * step
            case .none:
                break
            }
        }

        // Format to 2 decimals if it had a decimal originally; otherwise no trailing .00
        let hadDecimal = normalized.contains(".")
        let formatter = NumberFormatter()
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = hadDecimal ? 2 : 0
        formatter.maximumFractionDigits = hadDecimal ? 2 : 0

        return formatter.string(from: NSNumber(value: finalVal))
    }

    @objc private func toggleEnabled() {
        isEnabled.toggle()
        updateAppKitToggleTitle()
    }
}

struct SettingsView: View {
    @AppStorage("percentDelta") private var percentDelta: Double = 0.07
    @AppStorage("roundingMode") private var roundingModeRaw: Int = 0
    @AppStorage("roundingStep") private var roundingStep: Double = 1

    private static let percentPointsFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        f.allowsFloats = true
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Percent section
            GroupBox(label: Text("Percent Change")) {
                HStack(spacing: 12) {
                    Text("Percent:")
                    // Bind UI (percent points) to stored fraction (percentDelta)
                    let percentBinding = Binding<Double>(
                        get: { percentDelta * 100 },
                        set: { percentDelta = $0 / 100 }
                    )
                    TextField("-10 = down 10%", value: percentBinding, formatter: Self.percentPointsFormatter)
                        .frame(width: 100)
                        .textFieldStyle(.roundedBorder)
                    Text("%")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }

            // Rounding section
            GroupBox(label: Text("Rounding")) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Mode", selection: $roundingModeRaw) {
                        Text("None").tag(0)
                        Text("Up").tag(1)
                        Text("Down").tag(2)
                    }
                    .pickerStyle(.segmented)

                    HStack(spacing: 12) {
                        Text("Step:")
                        Picker("Step", selection: $roundingStep) {
                            Text("1").tag(1.0)
                            Text("5").tag(5.0)
                            Text("10").tag(10.0)
                        }
                        .pickerStyle(.segmented)
                        Text("Applies after percent change.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }

            Divider()

            // Preview
            VStack(alignment: .leading, spacing: 6) {
                Text("Preview")
                    .font(.headline)
                PreviewRow(sample: 129.99, percentDelta: percentDelta, roundingModeRaw: roundingModeRaw, roundingStep: roundingStep)
                PreviewRow(sample: 100, percentDelta: percentDelta, roundingModeRaw: roundingModeRaw, roundingStep: roundingStep)
            }
            
            Spacer()
        }
        .padding(20)
        .frame(width: 320, height: 320)
        .background(
            WindowAccessor { win in
                // Keep Settings above other windows
                win.level = .floating
                // Show on all Spaces and coexist with full-screen apps
                win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                win.makeKeyAndOrderFront(nil)
            }
        )
    }
}

struct MenuContent: View {
    @AppStorage("enabled") private var enabled: Bool = true

    var body: some View {
        VStack {
            Button("Open Window…") {
                NotificationCenter.default.post(name: .openMainWindow, object: nil)
            }
            .padding(.top, 10)
            Divider()
            Button(enabled ? "Stop" : "Start") { enabled.toggle() }
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
                .padding(.bottom, 10)
        }
        .frame(width: 200)
    }
}

struct RootView: View {
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome: Bool = false

    var body: some View {
        if hasSeenWelcome {
            MainWindowView()
        } else {
            WelcomeView(onContinue: { hasSeenWelcome = true })
        }
    }
}

struct WelcomeView: View {
    let onContinue: () -> Void

    private struct Feature {
        let icon: String
        let title: String
        let detail: String
    }

    private let features: [Feature] = [
        Feature(icon: "doc.on.clipboard", title: "Watches your clipboard",
                detail: "SalePaste quietly checks what you copy, no setup needed."),
        Feature(icon: "percent", title: "Adjusts prices automatically",
                detail: "Copy a price and SalePaste applies your markup or discount before you paste."),
        Feature(icon: "arrow.up.arrow.down.circle", title: "Rounds however you like",
                detail: "Round up, down, or not at all to the nearest 1, 5, or 10.")
    ]

    var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .padding(.top, 12)

            VStack(spacing: 4) {
                Text("Welcome to SalePaste")
                    .font(.title2.bold())
                Text("Instantly adjust prices as you copy and paste.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 14) {
                ForEach(features, id: \.title) { feature in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: feature.icon)
                            .frame(width: 24)
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(feature.title)
                                .fontWeight(.semibold)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(feature.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 8)

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                Text("All data stays on this Mac, nothing is shared or synced online.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 8)

            Button(action: onContinue) {
                Text("Get Started")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 360, height: 460)
    }
}

struct MainWindowView: View {
    @AppStorage("enabled") private var enabled: Bool = true
    @AppStorage("percentDelta") private var percentDelta: Double = 0.07
    @AppStorage("roundingMode") private var roundingModeRaw: Int = 0
    @AppStorage("roundingStep") private var roundingStep: Double = 1

    private static let percentFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        f.allowsFloats = true
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox(label: Text("Status")) {
                HStack {
                    Image(systemName: enabled ? "checkmark.circle.fill" : "pause.circle")
                        .foregroundStyle(enabled ? .green : .secondary)
                    Text(enabled ? "Active: Adjusting clipboard prices" : "Paused: Clipboard unchanged")
                        .foregroundStyle(enabled ? .primary : .secondary)
                    Spacer()
                    Button(enabled ? "Stop" : "Start") { enabled.toggle() }
                }
                .padding(.vertical, 6)
            }

            GroupBox(label: Text("Percent Change")) {
                HStack(spacing: 12) {
                    Text("Percent:")
                    let percentBinding = Binding<Double>(
                        get: { percentDelta * 100 },
                        set: { percentDelta = $0 / 100 }
                    )
                    TextField("-10 = down 10%", value: percentBinding, formatter: Self.percentFormatter)
                        .frame(width: 100)
                        .textFieldStyle(.roundedBorder)
                    Text("%")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }

            GroupBox(label: Text("Rounding")) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Mode", selection: $roundingModeRaw) {
                        Text("None").tag(0)
                        Text("Up").tag(1)
                        Text("Down").tag(2)
                    }
                    .pickerStyle(.segmented)
                    HStack(spacing: 12) {
                        Text("Step:")
                        Picker("Step", selection: $roundingStep) {
                            Text("1").tag(1.0)
                            Text("5").tag(5.0)
                            Text("10").tag(10.0)
                        }
                        .pickerStyle(.segmented)
                        Text("Applies after percent change.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Preview")
                    .font(.headline)
                PreviewRow(sample: 129.99, percentDelta: percentDelta, roundingModeRaw: roundingModeRaw, roundingStep: roundingStep)
                PreviewRow(sample: 100, percentDelta: percentDelta, roundingModeRaw: roundingModeRaw, roundingStep: roundingStep)
            }

            Spacer()

            Divider()

            HStack {
                Spacer()
                Button("Quit SalePaste") { NSApp.terminate(nil) }
                    .foregroundStyle(.red)
            }
        }
        .padding(20)
        .frame(width: 360, height: 460)
    }
}

private struct PreviewRow: View {
    let sample: Double
    let percentDelta: Double
    let roundingModeRaw: Int
    let roundingStep: Double

    var body: some View {
        let adjusted = sample * (1 + percentDelta)
        let mode = roundingModeRaw
        let final: Double = {
            switch mode {
            case 1: return ceil(adjusted / roundingStep) * roundingStep
            case 2: return floor(adjusted / roundingStep) * roundingStep
            default: return adjusted
            }
        }()
        HStack {
            Text(String(format: "Input: %.2f", sample))
            Image(systemName: "arrow.right")
            Text(String(format: "Output: %.2f", final))
                .fontWeight(.semibold)
        }
    }
}

// MARK: - SwiftUI -> AppKit window accessor used by SettingsView
final class WindowReader: NSView {
    var onWindow: ((NSWindow) -> Void)?
    init(onWindow: @escaping (NSWindow) -> Void) {
        self.onWindow = onWindow
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let w = window { onWindow?(w) }
    }
}

struct WindowAccessor: NSViewRepresentable {
    var onResolve: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView { WindowReader(onWindow: onResolve) }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
