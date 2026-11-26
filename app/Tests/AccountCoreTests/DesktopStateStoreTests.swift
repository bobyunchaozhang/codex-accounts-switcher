import SQLite3
import XCTest
@testable import AccountCore

final class DesktopStateStoreTests: XCTestCase {
    private func runSQL(_ sql: String, at url: URL) throws {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open(url.path, &db) == SQLITE_OK,
              sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw AccountError.message("Could not create desktop database fixture")
        }
    }

    func testMigratedStateUsesSQLiteForBothDirectionsDespiteStaleJSON() throws {
        let fixtures = AccountCoreTests()
        let a = try fixtures.credential(), b = try fixtures.credential("bob")
        let aKey = try XCTUnwrap(ProjectView.rendererKey(a))
        let bKey = try XCTUnwrap(ProjectView.rendererKey(b))
        try fixtures.temp { home in
            let store = DesktopStateStore(home: home)
            let sqlite = home.appendingPathComponent(".codex-global-state.sqlite")
            let checkpoint = home.appendingPathComponent("checkpoint.json")
            let staleJSON = try JSONSerialization.data(withJSONObject: SharedGlobalsTests().fixture(b, a))
            try PrivateFiles.write(staleJSON, to: store.jsonURL)
            XCTAssertEqual(try store.read().storage, .json)
            try runSQL("""
                PRAGMA user_version = 1;
                CREATE TABLE settings (scope TEXT NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL,
                                       PRIMARY KEY (scope, key)) WITHOUT ROWID;
                INSERT INTO settings VALUES
                  ('global', 'electron-renderer-content-owner', '"\(aKey)"'),
                  ('global', 'local-projects', '{}'),
                  ('global', 'thread-project-assignments', '{}'),
                  ('global', 'projectless-thread-ids', '["thread"]'),
                  ('global', 'electron-owner-value:thread-workspace-root-hints:\(aKey)', '{"thread":"/tmp/example"}'),
                  ('atom', 'electron-renderer-content-owner', '"\(bKey)"');
                """, at: sqlite)
            let before = try store.read()
            XCTAssertEqual(before.storage, .sqlite)
            XCTAssertTrue(DesktopIdentity.matches(a, auth: a.data, state: before.data))
            XCTAssertFalse(DesktopIdentity.matches(b, auth: b.data, state: before.data))
            let databaseBefore = try Data(contentsOf: sqlite)
            XCTAssertNil(try store.proposedSwitch(before, source: a, target: b, checkpoint: checkpoint))
            XCTAssertThrowsError(try store.proposedSwitch(before, source: b, target: a, checkpoint: checkpoint))
            XCTAssertThrowsError(try store.requireJSONStorage())
            XCTAssertEqual(try Data(contentsOf: sqlite), databaseBefore)

            // Codex persists the new owner when it reopens with the target credential.
            try runSQL("UPDATE settings SET value = '\"\(bKey)\"' WHERE scope = 'global' AND key = 'electron-renderer-content-owner';", at: sqlite)
            let after = try store.read()
            XCTAssertNotEqual(after, before)
            XCTAssertTrue(DesktopIdentity.matches(b, auth: b.data, state: after.data))
            XCTAssertNil(try store.proposedSwitch(after, source: b, target: a, checkpoint: checkpoint))
            XCTAssertEqual(try PrivateFiles.read(store.jsonURL), staleJSON)
        }
    }

    func testUnknownSQLiteSchemaDoesNotFallBackToJSON() throws {
        let fixtures = AccountCoreTests()
        let a = try fixtures.credential(), b = try fixtures.credential("bob")
        try fixtures.temp { home in
            let store = DesktopStateStore(home: home)
            let sqlite = home.appendingPathComponent(".codex-global-state.sqlite")
            try PrivateFiles.write(JSONSerialization.data(withJSONObject: SharedGlobalsTests().fixture(a, b)), to: store.jsonURL)
            try runSQL("""
                PRAGMA user_version = 2;
                CREATE TABLE settings(scope TEXT, key TEXT, value TEXT);
                INSERT INTO settings VALUES ('global', 'electron-renderer-content-owner', '"signed-out"');
                """, at: sqlite)
            XCTAssertThrowsError(try store.read())
            try runSQL("PRAGMA user_version = 1;", at: sqlite)
            XCTAssertEqual(try store.read().storage, .sqlite)
        }
    }
}
