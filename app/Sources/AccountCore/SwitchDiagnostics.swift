import Foundation

/// Bounded stage metadata only. Never serialize auth, command arguments or chat content.
public final class SwitchDiagnostics {
    public struct Context: Codable {
        public var stage: String
        public var desktopVersion: String
        public var stateFormat: String
    }
    public struct Attempt: Codable {
        public var started: Date
        public var stages: [String]
        public var targetWritten: Bool?
        public var credentialVerified: Bool?
        public var desktopVerified: Bool?
        public var needsReopen: Bool?
        public var desktopVersion: String
        public var toolVersion: String?
        public var failureMessage: String?
        public var reopenFailure: String?
        public var contexts: [Context]?
    }
    private let url: URL
    private var attempt: Attempt
    private var history: [Attempt]
    public init(url: URL, desktopVersion: String, toolVersion: String = "development") {
        self.url = url
        history = (try? JSONDecoder().decode([Attempt].self, from: PrivateFiles.read(url))) ?? []
        history = Array(history.suffix(19))
        attempt = Attempt(started: Date(), stages: [], desktopVersion: desktopVersion, toolVersion: toolVersion)
        save()
    }
    public func stage(_ value: String) { attempt.stages.append(value); save() }
    public func context(_ stage: String, app: URL, state: Data?) {
        let format = state.flatMap { try? DesktopState($0).format.rawValue } ?? "unknown-or-incomplete"
        let item = Context(stage: stage, desktopVersion: DesktopState.diskVersion(app), stateFormat: format)
        attempt.contexts = Array(((attempt.contexts ?? []) + [item]).suffix(12))
        save()
    }
    public func finish(_ outcome: SwitchOutcome) {
        attempt.targetWritten = outcome.targetWritten; attempt.credentialVerified = outcome.identityVerified
        attempt.failureMessage = outcome.failureMessage.map { String($0.prefix(1000)) }
        attempt.reopenFailure = outcome.reopenFailure.map { String($0.prefix(1000)) }
        attempt.desktopVerified = outcome.desktopVerified; attempt.needsReopen = outcome.needsReopen; save()
    }
    private func save() { if let data = try? JSONEncoder().encode(history + [attempt]) { try? PrivateFiles.write(data, to: url) } }
}
