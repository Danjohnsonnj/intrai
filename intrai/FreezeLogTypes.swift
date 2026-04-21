//
//  FreezeLogTypes.swift
//  intrai
//

import Foundation

enum FreezeLogLevel: String, Codable, Sendable {
    case info
    case warning
    case error
}

struct FreezeLogEntry: Codable, Sendable {
    let id: UUID
    let timestamp: Date
    let event: String
    let level: FreezeLogLevel
    let sessionID: UUID?
    let generationStamp: UUID?
    let durationMs: Double?
    let scenePhase: String
    let memoryWarningCount: Int
    let threadID: UInt64
    let isMainThread: Bool
    let metadata: [String: String]
}

struct FreezeLogExport: Codable, Sendable {
    let metadata: [String: String]
    let entries: [FreezeLogEntry]
}
