//
//  ChatExport.swift
//  intrai
//

import Foundation

struct ChatExport {
    static func markdown(for session: ChatSession) -> String {
        let createdText = session.createdAt.formatted(date: .abbreviated, time: .shortened)
        let orderedMessages = session.orderedMessages

        var lines: [String] = []
        lines.append("# \(session.title)")
        lines.append("")
        lines.append("Date: \(createdText)")
        lines.append("")
        lines.append("## Conversation")
        lines.append("")

        if orderedMessages.isEmpty {
            lines.append("_No messages yet._")
        } else {
            for message in orderedMessages {
                let roleLabel = message.validatedRole == .user ? "User" : "Assistant"
                lines.append("### \(roleLabel)")
                lines.append(message.text)
                lines.append("")
            }
        }

        return lines.joined(separator: "\n")
    }

    static func markdown(for message: ChatMessage) -> String {
        switch message.validatedRole {
        case .user:
            return message.text
        case .assistant:
            return message.text
        }
    }
}
