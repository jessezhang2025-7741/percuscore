import SwiftUI
import UIKit

struct PresetEditor: View {
    @ObservedObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let index: Int
    @State private var preset: PenPreset
    @State private var color: Color
    init(store: LibraryStore, index: Int) {
        self.store = store; self.index = index
        let value = store.index.settings.presets[index]
        _preset = State(initialValue: value); _color = State(initialValue: Color(uiColor: UIColor(hex: value.hex)))
    }
    var body: some View {
        NavigationStack {
            Form {
                TextField("Preset name", text: $preset.name)
                ColorPicker("Ink color", selection: $color, supportsOpacity: false)
                Toggle("Highlighter", isOn: $preset.highlighter)
                VStack(alignment: .leading) { Text("Width · \(Int(preset.width))"); Slider(value: $preset.width, in: 1...35, step: 1).accessibilityLabel("Ink width")
                    .accessibilityValue("\(Int(preset.width)) points") }
                VStack(alignment: .leading) { Text("Opacity · \(Int(preset.opacity * 100))%"); Slider(value: $preset.opacity, in: 0.1...1, step: 0.05).accessibilityLabel("Ink opacity")
                    .accessibilityValue("\(Int(preset.opacity * 100)) percent") }
                RoundedRectangle(cornerRadius: preset.width / 2).fill(color.opacity(preset.opacity)).frame(height: preset.width).padding(.vertical, 20)
            }
            .percuscorePanel()
            .navigationTitle("Drawing preset")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                        preset.hex = String(format: "%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255))
                        if store.update({ if $0.settings.presets.indices.contains(index) { $0.settings.presets[index] = preset } }) { dismiss() }
                    }.disabled(preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }.percuscoreSheet()
    }
}
