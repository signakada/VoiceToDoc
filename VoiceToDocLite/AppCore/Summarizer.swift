//  Summarizer.swift
//  VoiceToDocLite
//
//  ★このファイルは「全文置換」してください。
//  目的: Summarizer の共通入口。UI を含めない。

import Foundation

public enum SummarizerError: Error, LocalizedError {
    case providerUnavailable(String)
    case notImplemented(String)

    public var errorDescription: String? {
        switch self {
        case .providerUnavailable(let p): return "Summarizer provider is unavailable: \(p)"
        case .notImplemented(let msg):    return "Not implemented: \(msg)"
        }
    }
}

/// プロジェクト固有の名前に変更して、他所の同名型と衝突しないようにする
public final class VTDLSummarizerService {
    public static let shared = VTDLSummarizerService()
    private init() {}

    /// 既存UI呼び出し：systemPrompt をそのまま使う
    public func summarize(_ text: String, systemPrompt: String) async throws -> String {
        // フェーズ4安定運用: 実API未接続。最低限の体裁で返す。
        let head = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.isEmpty { return text }
        return "【Prompt】\n\(head)\n\n【Text】\n\(text)"
    }
}
