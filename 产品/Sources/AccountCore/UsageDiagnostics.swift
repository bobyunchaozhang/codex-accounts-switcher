import Foundation

/// Error categories only: never persist raw server text, credentials or email.
public enum UsageDiagnostics {
    public struct Entry: Codable {
        public var date: Date
        public var profileIndex: Int
        public var active: Bool
        public var category: String
    }
    public static func category(_ error: Error) -> String {
        if let error = error as? AccountError {
            switch error {
            case .authenticationRejected: return "authentication-rejected"
            case .identityMismatch: return "identity-mismatch"
            case .message(let text):
                if text.contains("超时") { return "timeout" }
                if text.contains("接口") { return "rpc-rejected" }
                if text.contains("服务已退出") { return "app-server-exited" }
                if text.contains("工作区") { return "workspace-unconfirmed" }
                return "local-service-error"
            }
        }
        if error is DecodingError { return "response-schema" }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return "network-\(ns.code)" }
        if ns.domain == NSPOSIXErrorDomain || ns.domain == NSCocoaErrorDomain { return "local-io-\(ns.code)" }
        return "other-error"
    }
    public static func record(_ error: Error, profileIndex: Int, active: Bool, url: URL) {
        let prior = (try? JSONDecoder().decode([Entry].self, from: PrivateFiles.read(url))) ?? []
        let items = Array(prior.suffix(39)) + [Entry(date: Date(), profileIndex: profileIndex, active: active, category: category(error))]
        if let data = try? JSONEncoder().encode(items) { try? PrivateFiles.write(data, to: url) }
    }
}
