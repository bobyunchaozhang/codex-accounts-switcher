import XCTest
@testable import AccountCore

final class AccountCoreTests: XCTestCase {
    func credential(_ user: String = "alice", workspace: String = "personal", email: String? = nil, token: String = "fresh") throws -> Credential {
        let claims: [String: Any] = ["sub": user, "email": email ?? "\(user)@example.com", "https://api.openai.com/auth": ["chatgpt_plan_type": "plus", "chatgpt_user_id": "chatgpt-\(user)"]]
        let body = try JSONSerialization.data(withJSONObject: claims).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return try Credential(JSONSerialization.data(withJSONObject: ["tokens": ["id_token": "header.\(body).signature", "access_token": token, "refresh_token": "refresh-secret", "account_id": workspace]]))
    }
    func temp(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("account-tests-\(UUID())")
        try PrivateFiles.directory(dir); defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }
    func usage(_ json: String) throws -> Usage { try JSONDecoder().decode(Usage.self, from: Data(json.utf8)) }
    func testFiveHourTakesPriorityEvenWhenWeekHasLess() throws {
        let u = try usage(#"{"rateLimits":{"primary":{"usedPercent":85,"windowDurationMins":10080},"secondary":{"usedPercent":20,"windowDurationMins":300}}}"#)
        XCTAssertEqual(u.bucket?.selected?.remaining, 0.8)
        XCTAssertEqual(u.bucket?.selected?.label, "5H")
    }
    func testFiveHourZeroDoesNotShowAvailableWeeklyQuota() throws {
        let u = try usage(#"{"rateLimits":{"primary":{"usedPercent":100,"windowDurationMins":300},"secondary":{"usedPercent":15,"windowDurationMins":10080}}}"#)
        XCTAssertEqual(u.bucket?.selected?.remaining, 0)
    }
    func testWeekExhaustionDoesNotReplaceFiveHourBar() throws {
        let u = try usage(#"{"rateLimits":{"primary":{"usedPercent":20,"windowDurationMins":300},"secondary":{"usedPercent":100,"windowDurationMins":10080}}}"#)
        XCTAssertEqual(u.bucket?.selected?.remaining, 0.8)
        XCTAssertEqual(u.note, "周额度已用完")
    }
    func testUnknownDurationAndOtherBucketNotInvented() throws {
        XCTAssertNil(try usage(#"{"rateLimits":{"primary":{"usedPercent":1}}}"#).bucket?.selected)
        XCTAssertNil(try usage(#"{"rateLimits":{},"rateLimitsByLimitId":{"review":{"primary":{"usedPercent":1,"windowDurationMins":300}}}}"#).bucket)
    }
    func testCardsMissingExpiryIsNotNonExpiring() throws {
        let u = try usage(#"{"rateLimits":{},"rateLimitResetCredits":{"availableCount":1,"credits":[{"id":"1","status":"available","resetType":"codexRateLimits"}]}}"#)
        XCTAssertEqual(u.rateLimitResetCredits?.expiryLabel, "到期待确认")
    }
    func testCardsTruncatedListCannotClaimNearestExpiry() throws {
        let u = try usage(#"{"rateLimits":{},"rateLimitResetCredits":{"availableCount":2,"credits":[{"id":"1","status":"available","resetType":"codexRateLimits","expiresAt":12345}]}}"#)
        XCTAssertEqual(u.rateLimitResetCredits?.availableCount, 2)
        XCTAssertEqual(u.rateLimitResetCredits?.expiryLabel, "到期待确认")
    }
    func testExplicitNullExpiryAndDuplicateCardDetails() throws {
        let u = try usage(#"{"rateLimits":{},"rateLimitResetCredits":{"availableCount":1,"credits":[{"id":"1","status":"available","resetType":"codexRateLimits","expiresAt":null}]}}"#)
        XCTAssertEqual(u.rateLimitResetCredits?.expiryLabel, "无到期日")
        let d = try usage(#"{"rateLimits":{},"rateLimitResetCredits":{"availableCount":2,"credits":[{"id":"1","status":"available","resetType":"codexRateLimits","expiresAt":null},{"id":"1","status":"available","resetType":"codexRateLimits","expiresAt":null}]}}"#)
        XCTAssertEqual(d.rateLimitResetCredits?.expiryLabel, "到期待确认")
    }
    func testSameEmailDifferentWorkspaceIsDistinct() throws {
        let a = try credential(workspace: "personal"), b = try credential(workspace: "org")
        XCTAssertFalse(a.identity.matches(b.identity)); XCTAssertNotEqual(a.identity.key, b.identity.key)
    }
    func testRefreshlessSnapshotDoesNotMutateOriginal() throws {
        let c = try credential()
        let scrubbed = try JSONSerialization.jsonObject(with: c.withoutRefreshToken()) as! [String: Any]
        XCTAssertEqual((scrubbed["tokens"] as! [String: Any])["refresh_token"] as? String, "")
        XCTAssertTrue(String(decoding: c.data, as: UTF8.self).contains("refresh-secret"))
    }
    func testDuplicateUpdatesInPlaceAndRemoveLeavesActiveUntouched() throws {
        try temp { root in
            let store = try ProfileStore(root: root.appendingPathComponent("store"))
            let active = root.appendingPathComponent("auth.json")
            let a = try credential(), b = try credential("bob")
            try PrivateFiles.write(a.data, to: active)
            let first = try store.save(a); _ = try store.save(b)
            let new = try credential(token: "new-token")
            try store.save(new)
            XCTAssertEqual(try store.profiles.map(\.id), [a.identity.key, b.identity.key])
            XCTAssertEqual(try store.credential(first).data, new.data)
            try store.remove(first)
            XCTAssertEqual(try PrivateFiles.read(active), a.data)
            XCTAssertEqual(try store.profiles.count, 1)
        }
    }
    func testAtomicFilePermissionsAndSymlinkRefusal() throws {
        try temp { root in
            let file = root.appendingPathComponent("auth.json")
            try PrivateFiles.write(Data("secret".utf8), to: file)
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            let link = root.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
            XCTAssertThrowsError(try PrivateFiles.read(link))
        }
    }
    func testTransactionRoundTripTouchesOnlyAuth() throws {
        try temp { root in
            let a = try credential(), b = try credential("bob")
            let active = root.appendingPathComponent("auth.json")
            let history = root.appendingPathComponent("history.jsonl")
            try PrivateFiles.write(a.data, to: active); try PrivateFiles.write(Data("untouched".utf8), to: history)
            let tx = try AuthTransaction(active: active, folder: root.appendingPathComponent("transaction"))
            try tx.prepare(target: b, expectedCurrent: a.data); try tx.commit()
            XCTAssertEqual(try Credential(PrivateFiles.read(active)).identity, b.identity)
            try tx.rollback()
            XCTAssertEqual(try PrivateFiles.read(active), a.data)
            XCTAssertEqual(try PrivateFiles.read(history), Data("untouched".utf8))
            XCTAssertNil(try tx.journal)
        }
    }
    func testConcurrentExternalChangeStopsCommit() throws {
        try temp { root in
            let a = try credential(), b = try credential("bob"), c = try credential("carol")
            let active = root.appendingPathComponent("auth.json")
            try PrivateFiles.write(a.data, to: active)
            let tx = try AuthTransaction(active: active, folder: root.appendingPathComponent("transaction"))
            try tx.prepare(target: b, expectedCurrent: a.data)
            try PrivateFiles.write(c.data, to: active)
            XCTAssertThrowsError(try tx.commit())
            XCTAssertEqual(try PrivateFiles.read(active), c.data)
        }
    }
    func testConcurrentRefreshStopsRollback() throws {
        try temp { root in
            let a = try credential(), b = try credential("bob"), refreshed = try credential("bob", token: "rotated")
            let active = root.appendingPathComponent("auth.json")
            try PrivateFiles.write(a.data, to: active)
            let tx = try AuthTransaction(active: active, folder: root.appendingPathComponent("transaction"))
            try tx.prepare(target: b, expectedCurrent: a.data); try tx.commit()
            try PrivateFiles.write(refreshed.data, to: active)
            XCTAssertThrowsError(try tx.rollback())
            XCTAssertEqual(try PrivateFiles.read(active), refreshed.data)
        }
    }
    func testCrashRecoveryKeepsWrittenBWithoutReopeningAnything() throws {
        try temp { root in
            let a = try credential(), b = try credential("bob")
            let active = root.appendingPathComponent("auth.json"), folder = root.appendingPathComponent("tx")
            try PrivateFiles.write(a.data, to: active)
            let tx = try AuthTransaction(active: active, folder: folder)
            try tx.prepare(target: b, expectedCurrent: a.data); try tx.commit()
            let restarted = try AuthTransaction(active: active, folder: folder)
            XCTAssertNotNil(try restarted.inspectRecovery())
            XCTAssertEqual(try PrivateFiles.read(active), b.data)
            XCTAssertNil(try restarted.journal)
        }
    }
    func testCrashRecoveryUnknownIdentityRetainsEvidence() throws {
        try temp { root in
            let a = try credential(), b = try credential("bob"), c = try credential("carol")
            let active = root.appendingPathComponent("auth.json"), folder = root.appendingPathComponent("tx")
            try PrivateFiles.write(a.data, to: active)
            let tx = try AuthTransaction(active: active, folder: folder)
            try tx.prepare(target: b, expectedCurrent: a.data); try tx.commit()
            try PrivateFiles.write(c.data, to: active)
            XCTAssertNotNil(try tx.inspectRecovery()); XCTAssertNotNil(try tx.journal)
            XCTAssertEqual(try PrivateFiles.read(active), c.data)
        }
    }
}
