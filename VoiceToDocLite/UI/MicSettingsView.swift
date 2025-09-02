import SwiftUI
import AVFoundation

/// マイク選択の設定パネル：選んだマイクの uniqueID を UserDefaults に保存
struct MicSettingsView: View {
    @State private var devices: [AVCaptureDevice] = []
    @State private var selectedID: String = UserDefaults.standard.string(forKey: "selected_microphone_unique_id") ?? ""
    @State private var lastRefresh: Date = .now

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("使用するマイク")
                    .font(.headline)
                Spacer()
                Button("再読み込み") {
                    refreshDevices()
                }
            }

            Picker("マイク", selection: $selectedID) {
                Text("（システム既定を使用）").tag("")
                ForEach(devices, id: \.uniqueID) { dev in
                    Text("\(dev.localizedName)")
                        .tag(dev.uniqueID)
                }
            }
            .onChange(of: selectedID) { newValue in
                // 選択を保存（AudioCapture.start() が次回このIDを見て自動で切り替え）
                let ud = UserDefaults.standard
                ud.set(newValue, forKey: "selected_microphone_unique_id")
                if let dev = devices.first(where: { $0.uniqueID == newValue }) {
                    ud.set(dev.localizedName, forKey: "selected_microphone_name")
                } else {
                    ud.removeObject(forKey: "selected_microphone_name")
                }
            }

            // 現在の状態表示
            VStack(alignment: .leading, spacing: 4) {
                let name = UserDefaults.standard.string(forKey: "selected_microphone_name") ?? "（システム既定）"
                Label("現在の選択: \(name)", systemImage: "mic.fill")
                Text("再起動後もこの選択が保持されます。録音開始時に自動で適用されます。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider().padding(.vertical, 6)

            VStack(alignment: .leading, spacing: 4) {
                Text("ヒント")
                    .font(.subheadline).bold()
                Text("""
                ・選んだマイクが見つからない場合は自動的にシステム既定へフォールバックします。
                ・Zoom等で占有されているデバイスは利用できないことがあります。再読み込みで更新してください。
                """)
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer(minLength: 0)

            Text("最終更新: \(lastRefresh.formatted(date: .numeric, time: .standard))")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding()
        .onAppear {
            refreshDevices()
        }
    }

    private func refreshDevices() {
        // macOS: オーディオデバイス列挙
        devices = AVCaptureDevice.devices(for: .audio)
        lastRefresh = .now

        // すでに保存済みIDが存在しない or デバイスから消えている場合は空に戻す
        let saved = UserDefaults.standard.string(forKey: "selected_microphone_unique_id") ?? ""
        if !saved.isEmpty, devices.first(where: { $0.uniqueID == saved }) == nil {
            selectedID = ""
            UserDefaults.standard.removeObject(forKey: "selected_microphone_unique_id")
            UserDefaults.standard.removeObject(forKey: "selected_microphone_name")
        } else {
            // 表示上も保存値に合わせる
            selectedID = saved
        }
    }
}
