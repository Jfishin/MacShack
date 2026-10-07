import SwiftUI
import Metal
import os

// Hardware and storage figures for Settings.
@MainActor
enum DeviceInfo {
    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        return sysctlbyname(name, &buffer, &size, nil, 0) == 0 ? String(cString: buffer) : nil
    }
    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0, size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
    }

    // The system's own answers (what Settings > General > About reads), e.g. "marketing-name" = "iPhone 17 Pro Max" (read on an
    // iPhone 17 Pro Max, iOS 27). Private, so a future iOS may refuse a key: callers fall back.
    private static let copyAnswer: (@convention(c) (CFString, CFDictionary?) -> Unmanaged<CFTypeRef>?)? = {
        guard let lib = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY), let symbol = dlsym(lib, "MGCopyAnswer") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (CFString, CFDictionary?) -> Unmanaged<CFTypeRef>?).self)
    }()
    static func gestalt(_ key: String) -> String? {
        guard let value = copyAnswer?(key as CFString, nil)?.takeRetainedValue() as? String, !value.isEmpty else { return nil }
        return value
    }

    static let identifier: String = {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "Simulator"
        #else
        return sysctl("hw.machine") ?? "Unknown"
        #endif
    }()
    static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    static var model: String { gestalt("marketing-name") ?? "\(UIDevice.current.model) (\(identifier))" }
    // Under the model name: the owner's name from Settings > General > About ("Alex's iPhone") when iOS shares it, which it
    // only does to apps with a restricted entitlement; otherwise the identifier and model number ("iPhone18,2 · MFXM4LL/A").
    static var subtitle: String {
        let name = gestalt("UserAssignedDeviceName") ?? UIDevice.current.name
        if name != UIDevice.current.model { return name }
        return [identifier, gestalt("ModelNumber").map { $0 + (gestalt("RegionInfo") ?? "") }].compactMap { $0 }.joined(separator: " · ")
    }
    // "Apple A19 Pro": Metal names the GPU after its chip. Read once at launch, before a game's Metal hooks are installed.
    static let chip: String = (MTLCreateSystemDefaultDevice()?.name ?? "Unknown").replacingOccurrences(of: " GPU", with: "")
    static var cpu: String {
        let perf = sysctlInt("hw.perflevel0.physicalcpu"), eff = sysctlInt("hw.perflevel1.physicalcpu")
        let total = ProcessInfo.processInfo.processorCount
        if let perf, let eff { return "\(total) cores (\(perf)P + \(eff)E)" }
        return "\(total) cores"
    }
    static var display: String {
        let px = UIScreen.main.nativeBounds.size
        return "\(Int(max(px.width, px.height))) × \(Int(min(px.width, px.height))) · \(displayHz) Hz"
    }

    static var memory: Int64 { Int64(ProcessInfo.processInfo.physicalMemory) }
    // What the app may still allocate before iOS kills it (the increased-memory-limit entitlement raises the ceiling).
    static var memoryAvailable: Int64 { Int64(os_proc_available_memory()) }

    // Free space is what iOS Settings calls Available: it counts space the system can purge for us.
    static func storage() -> (total: Int64, free: Int64) {
        let values = try? AppModel.documents.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return (Int64(values?.volumeTotalCapacity ?? 0), values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    static var thermal: (label: String, color: Color) {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: ("Normal", .green)
        case .fair: ("Warm", .yellow)
        case .serious: ("Hot, throttling", .orange)
        case .critical: ("Critical", .red)
        @unknown default: ("Unknown", .gray)
        }
    }
}

func bytesText(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowsNonnumericFormatting = false   // "0 bytes", not "Zero KB"
    return formatter.string(fromByteCount: bytes)
}

// The bottom of Settings: a drawing of this device with its numbers beside it, on Liquid Glass. Memory, free space and
// thermal state move while games run, so the card redraws every 2 s.
struct HardwareSection: View {
    var body: some View {
        Section {
            TimelineView(.periodic(from: .now, by: 2)) { context in HardwareCard(now: context.date) }
                .listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
        } header: {
            Text("Device")
        } footer: {
            Text("Memory is what iOS lets MacShack still allocate before it ends the app. Free space includes storage iOS can clear.")
        }
    }
}

struct HardwareCard: View {
    let now: Date
    var body: some View {
        let disk = DeviceInfo.storage(), thermal = DeviceInfo.thermal
        let memory = DeviceInfo.memory, available = DeviceInfo.memoryAvailable
        HStack(alignment: .center, spacing: 20) {
            DeviceIllustration(pad: DeviceInfo.isPad, now: now).frame(width: DeviceInfo.isPad ? 130 : 92)
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(DeviceInfo.model).font(.title3.bold()).lineLimit(2).minimumScaleFactor(0.8)
                    Text(DeviceInfo.subtitle).font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Label(DeviceInfo.chip, systemImage: "cpu").font(.subheadline.weight(.medium))
                    Text("\(DeviceInfo.cpu) · \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(DeviceInfo.display).font(.caption2).foregroundStyle(.secondary)
                }
                Meter(title: "Memory", value: "\(bytesText(available)) of \(bytesText(memory))", fraction: memory > 0 ? Double(available) / Double(memory) : 0, tint: .accentColor)
                Meter(title: "Storage", value: "\(bytesText(disk.free)) free of \(bytesText(disk.total))",
                      fraction: disk.total > 0 ? Double(disk.total - disk.free) / Double(disk.total) : 0,
                      tint: disk.free < disk.total / 10 ? .orange : .accentColor)
                HStack(spacing: 6) {
                    Circle().fill(thermal.color).frame(width: 9, height: 9)
                    Text("Thermal").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    Spacer(minLength: 4)
                    Text(thermal.label).font(.caption)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 32))
    }
}

// A labelled bar: what it measures, the numbers, and how full it is.
private struct Meter: View {
    let title: String
    let value: String
    let fraction: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                Spacer(minLength: 4)
                Text(value).font(.caption).lineLimit(1).minimumScaleFactor(0.7)
            }
            Capsule().fill(.primary.opacity(0.12)).frame(height: 6)
                .overlay(alignment: .leading) {
                    GeometryReader { geo in Capsule().fill(tint).frame(width: geo.size.width * min(max(fraction, 0), 1)) }
                }
        }
    }
}

// This device, drawn: titanium frame, buttons, and a lock screen in the theme's colors. There is no public picture of
// the user's own device, so one drawing covers every iPhone and iPad.
struct DeviceIllustration: View {
    let pad: Bool
    let now: Date
    @Environment(Appearance.self) private var look
    @Environment(\.colorScheme) private var scheme

    private var wallpaper: [Color] {
        if let p = look.palette {
            return [p.accent, Color(hue: p.bgHue, saturation: p.bgSat, brightness: 0.6), Color(hue: p.bgHue, saturation: p.bgSat, brightness: 0.32)]
        }
        return [Color(hue: 0.62, saturation: 0.7, brightness: 0.95), Color(hue: 0.75, saturation: 0.6, brightness: 0.8), Color(hue: 0.92, saturation: 0.5, brightness: 0.9)]
    }

    // "9:41" like a lock screen: 12-hour, no leading zero, no AM/PM.
    private var clock: String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: now)
        return String(format: "%d:%02d", (c.hour ?? 12) % 12 == 0 ? 12 : (c.hour ?? 12) % 12, c.minute ?? 0)
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let corner = pad ? w * 0.085 : w * 0.17
            let bezel = pad ? w * 0.045 : w * 0.038
            let frame = RoundedRectangle(cornerRadius: corner, style: .continuous)
            let screen = RoundedRectangle(cornerRadius: corner - bezel * 0.7, style: .continuous)
            ZStack {
                if !pad {   // action + volume on the left, power on the right
                    ForEach([(0.14, 0.035), (0.21, 0.07), (0.30, 0.07)], id: \.0) { y, tall in
                        Capsule().fill(Color(white: 0.55)).frame(width: w * 0.03, height: h * tall).position(x: -w * 0.005, y: h * y + h * tall / 2)
                    }
                    Capsule().fill(Color(white: 0.55)).frame(width: w * 0.03, height: h * 0.11).position(x: w * 1.005, y: h * 0.27)
                }
                frame.fill(LinearGradient(colors: [Color(white: scheme == .dark ? 0.78 : 0.9), Color(white: 0.52), Color(white: scheme == .dark ? 0.7 : 0.82)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
                screen.fill(.black).padding(bezel * 0.45)
                screen.fill(LinearGradient(colors: wallpaper, startPoint: .topLeading, endPoint: .bottomTrailing)).padding(bezel)
                    .overlay {
                        VStack(spacing: 0) {
                            if !pad { Capsule().fill(.black).frame(width: w * 0.3, height: w * 0.085).padding(.top, bezel + w * 0.04) }
                            Text(clock)
                                .font(.system(size: w * (pad ? 0.16 : 0.22), weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.92)).minimumScaleFactor(0.5).lineLimit(1)
                                .padding(.top, pad ? h * 0.2 : h * 0.09).padding(.horizontal, bezel * 2)
                            Spacer()
                        }
                    }
                    .overlay {   // the glass catching light
                        screen.fill(LinearGradient(colors: [.white.opacity(0.3), .clear], startPoint: .topLeading, endPoint: UnitPoint(x: 0.65, y: 0.45)))
                            .padding(bezel)
                    }
            }
            .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
        }
        .aspectRatio(pad ? 0.75 : 0.455, contentMode: .fit)
    }
}
