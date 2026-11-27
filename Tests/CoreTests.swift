import Foundation
import Testing
@testable import ZCodeRemote

struct RemoteLinkTests {
    private let sample = "https://zcode.z.ai/remote/v4?sid=example-sid&mid=00000000-0000-0000-0000-000000000000&name=Test-Mac&app_version=3.19.0"

    @Test func parsesFullLink() throws {
        let fields = try #require(RemoteLink.parse(sample))
        #expect(fields.sid == "example-sid")
        #expect(fields.mid == "00000000-0000-0000-0000-000000000000")
        #expect(fields.name == "Test-Mac")
        #expect(fields.appVersion == "3.19.0")
    }

    @Test func parsesWithoutSchemeAndDecodesName() throws {
        let fields = try #require(
            RemoteLink.parse("zcode.z.ai/remote/v4?sid=s1&mid=m1&name=MacBook%20Pro&app_version=3.20.0")
        )
        #expect(fields.sid == "s1")
        #expect(fields.name == "MacBook Pro")
        #expect(fields.appVersion == "3.20.0")
    }

    @Test func fillsDefaultsForMissingFields() throws {
        let fields = try #require(RemoteLink.parse("https://zcode.z.ai/remote/v4?sid=s&mid=m"))
        #expect(fields.name == "Mac")
        #expect(fields.appVersion == "3.19.0")
    }

    @Test func rejectsInvalidLinks() {
        #expect(RemoteLink.parse("https://example.com/remote/v4?sid=s&mid=m") == nil)
        #expect(RemoteLink.parse("https://zcode.z.ai/other?sid=s&mid=m") == nil)
        #expect(RemoteLink.parse("https://zcode.z.ai/remote/v4?mid=m") == nil)
        #expect(RemoteLink.parse("") == nil)
    }

    @Test func roundTripsThroughSessionURL() throws {
        let fields = try #require(RemoteLink.parse(sample))
        let session = RemoteSession(
            accountID: UUID(),
            sid: fields.sid,
            mid: fields.mid,
            name: fields.name,
            appVersion: fields.appVersion
        )
        let reparsed = try #require(RemoteLink.parse(session.url.absoluteString))
        #expect(reparsed == fields)
    }
}

struct BackoffTests {
    @Test func doublesUntilCap() {
        var backoff = Backoff(base: 1, cap: 4)
        #expect(backoff.nextDelay() == 1)
        #expect(backoff.nextDelay() == 2)
        #expect(backoff.nextDelay() == 4)
        #expect(backoff.nextDelay() == 4)
    }

    @Test func resetStartsOver() {
        var backoff = Backoff(base: 0.5, cap: 30)
        _ = backoff.nextDelay()
        _ = backoff.nextDelay()
        backoff.reset()
        #expect(backoff.nextDelay() == 0.5)
    }
}

struct VersionCheckerTests {
    private let html = #"""
    {\"version\":\"3.18.2\",\"platforms\":{}},{\"version\":\"3.19.1\",\"platforms\":{}},{\"version\":\"4.0.0\",\"platforms\":{}}
    """#

    @Test func findsNewestVersionInEmbeddedReleases() throws {
        let latest = try #require(VersionChecker.latestVersion(in: html))
        #expect(latest == "4.0.0")
    }

    @Test func comparesVersionsNumerically() throws {
        let v391 = try #require(VersionChecker.parse("3.9.1"))
        let v3100 = try #require(VersionChecker.parse("3.10.0"))
        #expect(VersionChecker.isNewer(v3100, than: v391))
        #expect(!VersionChecker.isNewer(v391, than: v3100))
    }
}
