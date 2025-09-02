import SwiftUI

/// フローティング録音パレット（色で状態表示）
struct FloatingRecorderPalette: View {
    @State private var recording = false
    @State private var phase: Phase = .idle
    @State private var greenUntil: Date?

    enum Phase: String {
        case idle
        case recording   // 赤
        case transcribing// 青
        case summarizing // 紫
        case done        // 緑（10秒）
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                NotificationCenter.default.post(name: .init("ui.toggleRecord"), object: nil)
            } label: {
                Label(recording ? "停止" : "録音", systemImage: recording ? "stop.circle.fill" : "record.circle")
                    .font(.title3)
            }

            // 簡易インジケータ
            Text(labelText)
                .font(.subheadline)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.thinMaterial)
                .cornerRadius(6)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(backgroundColor)
        .cornerRadius(12)
        .shadow(radius: 8)
        .onReceive(NotificationCenter.default.publisher(for: .init("audioCapture.state"))) { note in
            if let rec = (note.userInfo as? [String: Any])?["recording"] as? Bool {
                recording = rec
                phase = rec ? .recording : .idle
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("job.phase"))) { note in
            if let p = (note.userInfo as? [String: Any])?["phase"] as? String {
                switch p {
                case "transcribing": phase = .transcribing
                case "summarizing":  phase = .summarizing
                case "done":
                    phase = .done
                    greenUntil = Date().addingTimeInterval(10)
                    // 10秒後に idle へ自動復帰
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                        if let until = greenUntil, Date() >= until {
                            phase = recording ? .recording : .idle
                            greenUntil = nil
                        }
                    }
                default:
                    phase = recording ? .recording : .idle
                }
            }
        }
    }

    private var labelText: String {
        switch phase {
        case .idle:         return "待機中"
        case .recording:    return "録音中…"
        case .transcribing: return "文字起こし中…"
        case .summarizing:  return "要約中…"
        case .done:         return "完了"
        }
    }

    private var backgroundColor: Color {
        switch phase {
        case .idle:         return Color(NSColor.windowBackgroundColor)
        case .recording:    return .red.opacity(0.35)
        case .transcribing: return .blue.opacity(0.35)
        case .summarizing:  return .purple.opacity(0.35)
        case .done:         return .green.opacity(0.35)
        }
    }
}
