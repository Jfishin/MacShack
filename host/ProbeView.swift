import SwiftUI

struct ProbeView: View {
    @State private var lines: [String] = []
    var body: some View {
        List(lines, id: \.self) { Text($0).font(.system(.footnote, design: .monospaced)) }
            .navigationTitle("Self-test")
            .onAppear { lines = Probe.run() }
    }
}
