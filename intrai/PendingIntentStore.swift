//
//  PendingIntentStore.swift
//  intrai
//

import Observation

/// Singleton bridge between App Intents (which run outside SwiftUI) and the
/// view layer. The intent writes a question here; ContentView observes it.
@Observable final class PendingIntentStore {
    static let shared = PendingIntentStore()
    private init() {}

    var pendingQuestion: String?
}
