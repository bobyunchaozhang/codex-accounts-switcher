import Foundation

public enum DesktopIdentity {
    /// Renderer ownership is desktop-local evidence, not a successful model request.
    public static func matches(_ expected: Credential, auth: Data?, state: Data?) -> Bool {
        guard let auth, let current = try? Credential(auth), current.identity.matches(expected.identity),
              let state, let renderer = try? DesktopState(state),
              let key = ProjectView.rendererKey(expected) else { return false }
        return renderer.owner == key
    }
}
