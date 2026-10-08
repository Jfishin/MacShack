import SwiftUI
import UniformTypeIdentifiers

// First run, before the launcher (README "Build" and prep/steam-onehost/README.md
// "Setup on the device"): the signing
// certificate, the JIT pairing file, then Steam, one landscape page each. Files come by AirDrop (MacShackApp's
// onOpenURL) or the Files picker, both through AppModel.receive. No Back: Settings > JIT & signing replaces either file.
// ponytail: touch only; controller presses come with the launcher.
struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    let finish: (_ bigPicture: Bool) -> Void   // to the launcher; true: then Big Picture
    @State private var page = 0
    @State private var picking = false
    @State private var settingUp = false

    private let titles = ["Certificate", "Pairing file", "Steam"]

    var body: some View {
        VStack(spacing: 20) {
            steps
            Group {
                switch page {
                case 0: certificate
                case 1: pairing
                default: steamPage
                }
            }
            .frame(maxWidth: 600, maxHeight: .infinity)
        }
        .padding(.horizontal, 48).padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LinearGradient(colors: [Color(rgb: 0x1c1c1e), Color(rgb: 0x0b0b0c)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .fileImporter(isPresented: $picking, allowedContentTypes: page == 0 ? [.pkcs12] : [.propertyList, .data]) { result in
            if case .success(let url) = result { app.receive(url) }
        }
    }

    // The three steps across the top: done ones checked, the current one in the accent color.
    private var steps: some View {
        HStack(spacing: 28) {
            ForEach(titles.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    Image(systemName: i < page ? "checkmark.circle.fill" : i == page ? "circle.inset.filled" : "circle")
                    Text(titles[i])
                }
                .font(.subheadline.weight(i == page ? .semibold : .regular))
                .foregroundStyle(i == page ? Color.accentColor : Color.secondary)
            }
        }
    }

    private var certificate: some View {
        StepPage(title: "Signing certificate", done: app.certificateReady,
                 doneText: "A signing identity for this build is in place.", status: app.signingStatus, busy: app.signingBusy,
                 text: "MacShack signs games on this device with your Apple Development identity. On your Mac: Keychain Access > My Certificates > the Apple Development identity Xcode signed MacShack with > Export as .p12 with a password. AirDrop it here, or put it in Files and tap Import .p12.",
                 action: "Import .p12", act: { picking = true }, next: { page = 1 })
    }

    private var pairing: some View {
        StepPage(title: "Pairing file", done: app.pairingReady, doneText: "Pairing file imported.", status: app.jitStatus, busy: false,
                 text: "Games that compile code while they run (Unity Mono, Intel) need JIT. On your Mac, make this device's pairing file with idevice_pair (github.com/jkcoxson/idevice_pair), RPPairing format, save its text as pairingFile.plist, then AirDrop it here. Also install LocalDevVPN from the App Store and keep it on when such a game starts.",
                 action: "Import pairing file", act: { picking = true },
                 next: { if AppModel.steamClientReady { finish(false) } else { page = 2 } })
    }

    @ViewBuilder private var steamPage: some View {
        if settingUp {
            SteamSetupView(mode: .open, done: { finish(true) }, close: { settingUp = false })
        } else {
            VStack(spacing: 14) {
                Text("Steam").font(.largeTitle.weight(.bold))
                Text("Set up Valve's macOS Steam client: about 420 MB from Valve, needs 3 GB free. Then Big Picture starts and you sign in with Steam's QR code.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button("Set up Steam") { settingUp = true }.buttonStyle(.borderedProminent)
                    Button("Not now") { finish(false) }.buttonStyle(.bordered)
                }
            }
        }
    }
}

// One onboarding step: what to do and its button; once done, a check mark and Continue.
private struct StepPage: View {
    let title: String, done: Bool, doneText: String, status: String, busy: Bool, text: String, action: String
    let act: () -> Void, next: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text(title).font(.largeTitle.weight(.bold))
                Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary)
                if done {
                    Label(doneText, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Button("Continue", action: next).buttonStyle(.borderedProminent)
                } else {
                    Button(action: act) {
                        if busy { ProgressView() } else { Text(action) }
                    }
                    .buttonStyle(.borderedProminent).disabled(busy)
                }
                if !status.isEmpty { Text(status).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center) }
            }
            .frame(maxWidth: .infinity)
        }
    }
}
