import SwiftUI
import AIHubCore

struct ModelThinkingPicker: View {
    let group: ModelGroup
    @Binding var thinking: ModelThinking
    var labelsHidden = true

    var body: some View {
        if group.hasThinking {
            if labelsHidden { picker.labelsHidden() }
            else { picker }
        } else { Text("—").foregroundStyle(.secondary) }
    }
    private var picker: some View {
        Picker("思考", selection: $thinking) {
            ForEach(group.thinkingOptions) { level in
                Text(level.title).tag(level)
                    .disabled(group.variant(for: level)?.model.isAvailable == false)
            }
        }
        .disabled(group.thinkingOptions.count < 2)
    }
}
