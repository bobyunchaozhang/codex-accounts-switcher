import XCTest
@testable import AccountCore

final class ServiceTests: XCTestCase {
    func testRefreshedTokenIsPersistedEvenIfUsageFailsAndTempIsRemoved() throws {
        let helper = AccountCoreTests()
        try helper.temp { root in
            let c = try helper.credential()
            let cli = root.appendingPathComponent("fake-codex")
            let script = #"""
            #!/usr/bin/ruby
            require 'json'
            STDOUT.sync=true
            STDIN.each_line do |line|
              m=JSON.parse(line)
              next unless m['id']
              r={}
              case m['method']
              when 'account/read'
                r={'account'=>{'type'=>'chatgpt','email'=>'alice@example.com'}}
              when 'account/rateLimits/read'
                path=File.join(ENV.fetch('CODEX_HOME'),'auth.json')
                obj=JSON.parse(File.read(path)); obj['tokens']['refresh_token']='rotated-secret'
                File.write(path,JSON.generate(obj))
                puts JSON.generate({'id'=>m['id'],'error'=>{'code'=>-32000,'message'=>'offline'}})
                next
              end
              puts JSON.generate({'id'=>m['id'],'result'=>r})
            end
            """#
            try script.write(to: cli, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
            let service = try AccountService(cli: cli, runtime: root.appendingPathComponent("runtime"))
            var persisted: Credential?
            XCTAssertThrowsError(try service.query(c, active: false) { persisted = $0 })
            XCTAssertTrue(String(decoding: persisted!.data, as: UTF8.self).contains("rotated-secret"))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: service.runtime.path), [])
        }
    }
}
