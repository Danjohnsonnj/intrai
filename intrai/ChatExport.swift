//
//  ChatExport.swift
//  intrai
//

import Foundation

struct ChatExport {
    static func markdown(for session: ChatSession) -> String {
        let createdText = session.createdAt.formatted(date: .abbreviated, time: .shortened)
        let orderedMessages = session.messages.sorted { $0.timestamp < $1.timestamp }

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

    static func temporaryMarkdownFileURL(for session: ChatSession) throws -> URL {
        let markdown = markdown(for: session)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let filename = sanitizeFilename("\(session.title)-\(timestamp)") + ".md"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func sanitizeFilename(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "\\/:*?\"<>|")
        let pieces = raw.components(separatedBy: invalid)
        return pieces.joined(separator: "-")
    }
}
