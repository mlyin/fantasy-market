import Foundation
import Vision
import ImageIO

struct RosterEntry: Identifiable, Equatable, Sendable {
    var id = UUID()
    var team: String
    var manager: String

    var isTruncated: Bool { team.contains("…") || team.contains("...") }
    var isComplete: Bool {
        !team.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !manager.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Geometry is normalized to the image, with Vision's bottom-left origin.
struct RosterTextLine: Sendable {
    let text: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    var midY: Double { y + height / 2 }
}

enum RosterImport {
    /// Reads the selected image locally. No screenshot is uploaded to the backend.
    static func recognize(_ data: Data) throws -> [RosterEntry] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2200
              ] as CFDictionary) else { throw ImportError.unreadable }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).compactMap { observation -> RosterTextLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let b = observation.boundingBox
            return RosterTextLine(text: candidate.string, x: b.minX, y: b.minY, width: b.width, height: b.height)
        }
        let entries = parse(lines)
        guard entries.count >= 2 else { throw ImportError.noRoster }
        return entries
    }

    /// ESPN standings put a record beside each team and its manager. Use those
    /// records as row anchors so divisions, standings statistics and menus stay out.
    static func parse(_ lines: [RosterTextLine]) -> [RosterEntry] {
        let records = lines.filter {
            $0.text.range(of: #"^\s*\d{1,2}[-–]\d{1,2}(?:[-–]\d{1,2})?\s*$"#, options: .regularExpression) != nil
        }.sorted { $0.midY > $1.midY }
        guard records.count >= 2 else { return [] }
        let gaps = zip(records, records.dropFirst()).map { $0.midY - $1.midY }.sorted()
        let halfRow = gaps[gaps.count / 2] * 0.48
        let excluded = Set(["east", "west", "north", "south", "record", "team", "standings", "win%", "gb"])
        var entries: [RosterEntry] = []
        for record in records {
            let names = lines.filter { line in
                line.x < record.x - 0.03 && abs(line.midY - record.midY) < halfRow &&
                line.text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count >= 2 &&
                !excluded.contains(line.text.lowercased())
            }.sorted { $0.midY > $1.midY }
            guard let team = names.first else { continue }
            let manager = names.dropFirst().first?.text ?? ""
            // Never guess hidden text or manufacture an owner for an incomplete row.
            entries.append(RosterEntry(team: team.text, manager: manager))
        }
        return entries
    }

    enum ImportError: LocalizedError {
        case unreadable, noRoster
        var errorDescription: String? {
            switch self {
            case .unreadable: return "That image could not be read. Try a screenshot from Photos."
            case .noRoster: return "No standings roster found. Use a screenshot showing team names, managers and records, or add the teams manually."
            }
        }
    }
}
