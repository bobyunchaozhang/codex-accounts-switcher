import Foundation

public enum ProcessScan {
    /// A failed identity read during exit is inconclusive, never proof of exit.
    public static func read<T>(attempts: Int = 20, pause: () -> Void = { Thread.sleep(forTimeInterval: 0.1) }, scan: () throws -> T) throws -> T {
        precondition(attempts > 0)
        for _ in 1..<attempts {
            do { return try scan() } catch { pause() }
        }
        return try scan()
    }
    public struct Row: Equatable {
        public let pid: Int32
        public let parent: Int32
        public let status: String
        public let executable: String
    }
    public static func parse(_ line: String) -> Row? {
        let parts = line.split(maxSplits: 3, whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count == 4, let pid = Int32(parts[0]), let parent = Int32(parts[1]) else { return nil }
        // maxSplits preserves the remaining alignment spaces in the last field.
        let executable = parts[3].trimmingCharacters(in: .whitespaces)
        guard !executable.isEmpty else { return nil }
        return Row(pid: pid, parent: parent, status: String(parts[2]), executable: executable)
    }
    public static func isZombie(_ status: String) -> Bool { status.contains("Z") }
}
