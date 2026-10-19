import Foundation

struct RosterEntry: Identifiable, Equatable, Sendable {
    var id = UUID()
    var team: String
    var manager: String

    var isComplete: Bool {
        !team.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !manager.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
