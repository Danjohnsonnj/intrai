//
//  ChatMessage.swift
//  intrai
//

import Foundation
import SwiftData

enum ChatRole: String, Codable, CaseIterable {
    case user
    case assistant
}

@Model
final class ChatMessage {
    var id: UUID
    var text: String
    var role: String
    var timestamp: Date

    var validatedRole: ChatRole {
        ChatRole(rawValue: role) ?? .user
    }

    init(text: String, role: String) {
        self.id = UUID()
        self.text = text
        self.role = ChatMessage.normalizeRole(role)
        self.timestamp = Date()
    }

    init(text: String, role: ChatRole) {
        self.id = UUID()
        self.text = text
        self.role = role.rawValue
        self.timestamp = Date()
    }

    private static func normalizeRole(_ rawValue: String) -> String {
        ChatRole(rawValue: rawValue.lowercased())?.rawValue ?? ChatRole.user.rawValue
    }
}
