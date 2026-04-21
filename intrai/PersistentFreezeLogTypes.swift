//
//  PersistentFreezeLogTypes.swift
//  intrai
//

import Foundation

struct PersistentFreezeLogEntry: Codable, Sendable {
    let id: UUID
    let timestamp: Date
    let event: String
    let level: String
    let sessionID: UUID?
    let generationStamp: UUID?
    let durationMs: Double?
    let scenePhase: String
    let memoryWarningCount: Int
    let threadID: UInt64
    let isMainThread: Bool
    let metadata: [String: String]
}

struct PersistentFreezeLogExport: Codable, Sendable {
    let metadata: [String: String]
    let entries: [PersistentFreezeLogEntry]
}
