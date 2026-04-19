//
//  SiriIntents.swift
//  intrai
//

import AppIntents

// MARK: - Intent

struct AskIntraiIntent: AppIntent {
    static var title: LocalizedStringResource = "Ask Intrai"
    static var description = IntentDescription(
        "Start a new Intrai chat and ask a question.",
        categoryName: "Chat"
    )

    /// Siri prompts for this when not provided inline.
    @Parameter(
        title: "Question",
        description: "The question to ask Intrai.",
        requestValueDialog: IntentDialog("What would you like to ask Intrai?")
    )
    var question: String

    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingIntentStore.shared.pendingQuestion = question
        return .result()
    }
}

// MARK: - Shortcut phrases

/// Registers the intent with Siri. Phrases don't include the question
/// parameter because AppShortcuts only allows AppEntity/AppEnum interpolation;
/// Siri will prompt "What would you like to ask Intrai?" for free-form input.
struct IntraiShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskIntraiIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "New \(.applicationName) chat"
            ],
            shortTitle: "Ask Intrai",
            systemImageName: "bubble.left.and.bubble.right"
        )
    }
}
