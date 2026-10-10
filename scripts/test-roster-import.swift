import Foundation

@main enum RosterImportTests {
    static func main() throws {
        func line(_ text: String, _ x: Double, _ y: Double) -> RosterTextLine {
            RosterTextLine(text: text, x: x, y: y, width: 0.2, height: 0.018)
        }
        let input = [line("WEST", 0.02, 0.96), line("Team A...", 0.18, 0.85), line("Alex", 0.18, 0.83),
                     line("1-0-0", 0.58, 0.84), line("1.000", 0.72, 0.84), line("Team B", 0.18, 0.75),
                     line("Blair", 0.18, 0.73), line("0-1-0", 0.58, 0.74), line("E", 0.08, 0.74),
                     line("Share Standings", 0.7, 0.1)]
        let roster = RosterImport.parse(input.reversed())
        precondition(roster.map(\.team) == ["Team A...", "Team B"])
        precondition(roster.map(\.manager) == ["Alex", "Blair"])
        precondition(roster[0].isTruncated && !roster[1].isTruncated)
        precondition(RosterImport.parse([line("Menu", 0.2, 0.8)]).isEmpty)
        let missing = RosterImport.parse(input.filter { $0.text != "Blair" })
        precondition(missing[1].manager.isEmpty && !missing[1].isComplete)
        if CommandLine.arguments.count > 1 {
            let entries = try RosterImport.recognize(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            precondition(entries.count == 10, "Expected ten teams in supplied standings screenshot")
            precondition(entries.allSatisfy(\.isComplete))
            precondition(entries.filter(\.isTruncated).count == 3)
            print("PASS: supplied screenshot reads 10 team/manager pairs; 3 truncated names flagged")
        }
        print("PASS: row ordering, statistics exclusion, missing manager, truncation and non-roster rejection")
    }
}
