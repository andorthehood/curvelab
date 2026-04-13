import SwiftUI

struct ChannelPickerView: View {
    @Binding var activeChannel: CurveChannel

    var body: some View {
        Picker("Channel", selection: $activeChannel) {
            ForEach(CurveChannel.allCases) { channel in
                Text(channel.label).tag(channel)
            }
        }
        .pickerStyle(.segmented)
    }
}
