import Foundation
import Supabase

/// One shared Supabase client for the extension. The URL and publishable key are
/// the same client-safe values the web app ships in lib/supabase.ts.
enum Backend {
    static let url = URL(string: "https://uwpqafsfmtzowqlynlqf.supabase.co")!
    static let publishableKey = "sb_publishable_bzP92k3SqMMwQgJQIIkrqw_6zUuaq_Q"

    static let client = SupabaseClient(supabaseURL: url, supabaseKey: publishableKey)
}

/// Errors surfaced to the UI in plain language.
enum MarketError: LocalizedError {
    case notSignedIn
    case invalidInvite
    case message(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Sign in first."
        case .invalidInvite: return "That invite code is not valid."
        case .message(let m): return m
        }
    }
}

extension Error {
    /// Postgres raises like `insufficient cash` come back wrapped; show just the message.
    var marketMessage: String {
        let raw = (self as? LocalizedError)?.errorDescription ?? String(describing: self)
        if let range = raw.range(of: "message: \"") {
            let rest = raw[range.upperBound...]
            if let end = rest.firstIndex(of: "\"") { return String(rest[..<end]) }
        }
        return raw
    }
}
