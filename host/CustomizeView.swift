import SwiftUI
import PhotosUI

struct CustomizeView: View {
    @Environment(Appearance.self) private var look
    @Environment(\.colorScheme) private var scheme
    @State private var pick: PhotosPickerItem?
    private let swatches = [GridItem(.adaptive(minimum: 88, maximum: 120), spacing: 14)]

    var body: some View {
        @Bindable var look = look
        let accent = look.customPalette.accent, tint = Color(hue: look.customPalette.bgHue, saturation: 0.7, brightness: 0.9)
        let title = look.picture == nil ? "Choose a picture" : "Change picture"
        Form {
            Section("Theme") {
                LazyVGrid(columns: swatches, spacing: 14) {
                    swatch(Appearance.system, nil)
                    ForEach(Appearance.presets, id: \.name) { swatch($0.name, $0.palette) }
                    swatch(Appearance.custom, look.customPalette)
                }
                .padding(.vertical, 6)
            }
            Section {
                slider("Hue", \.accentHue, accent); slider("Saturation", \.accentSat, accent); slider("Brightness", \.accentBri, accent)
            } header: { Text("Custom accent") } footer: { Text("Buttons and links. Moving a slider switches to Custom.") }
            Section("Custom background") {
                slider("Hue", \.bgHue, tint); slider("Tint", \.bgSat, tint)
            }
            Section {
                PhotosPicker(selection: $pick, matching: .images) {
                    Label(title, systemImage: "photo")
                }
                if let picture = look.picture {
                    Image(uiImage: picture).resizable().scaledToFill().frame(height: 120).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    LabeledContent("Dimming") { Slider(value: $look.dim, in: 0...0.85) }
                    Button("Remove picture", role: .destructive) { look.removePicture() }
                }
            } header: { Text("Local Games background") } footer: {
                Text("Shown behind your games in Local Games. Dimming keeps their names readable.")
            }
        }
        .themed()
        .navigationTitle("Customization")
        .onChange(of: pick) { _, item in
            Task {
                if let data = try? await item?.loadTransferable(type: Data.self) { look.setPicture(data) }
                pick = nil
            }
        }
    }

    // A tile previewing the look, ringed when it is the current theme.
    private func swatch(_ name: String, _ palette: Palette?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let colors: [Color] = palette?.background(dark: scheme == .dark) ?? [Color(.secondarySystemBackground)]
        let ring: Color = look.choice == name ? .primary : .clear
        return Button { look.select(name) } label: {
            VStack(spacing: 6) {
                shape.fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
                    .frame(height: 64)
                    .overlay { Circle().fill(palette?.accent ?? Color(.systemBlue)).frame(width: 22, height: 22) }
                    .overlay { shape.strokeBorder(ring, lineWidth: 3) }
                Text(name).font(.caption).foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
    }

    private func slider(_ label: String, _ key: WritableKeyPath<Palette, Double>, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.subheadline)
            Slider(value: Binding(get: { look.customPalette[keyPath: key] },
                                  set: { look.customPalette[keyPath: key] = $0; look.choice = Appearance.custom })).tint(tint)
        }
    }
}
