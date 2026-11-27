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

struct NativeRemoteProtocolTests {
    @Test func parsesDataEnvelope() throws {
        let json = #"""
        {"type":"data","server_ts":123,"payload":{"zcode_type":"bridge","dataBase64":"AAEC","fragmentIndex":0,"fragmentCount":1,"messageBytes":3}}
        """#
        let message = try #require(NativeRemoteProtocol.parse(json))
        #expect(message.type == "data")
        #expect(message.serverTs == 123)
        #expect(message.payload?.zcodeType == "bridge")
        #expect(message.payload?.messageBytes == 3)
    }

    @Test func parsesBootstrapResponse() throws {
        let json = #"""
        {"type":"data","payload":{"zcode_type":"bootstrap-response","requestId":"r1","success":true,"result":{"windowControlSessionId":"w1","desktopAppVersion":"4.0.0","workspaces":[{"workspacePath":"/tmp/p","label":"Project","kind":"local","connectionState":"connected"}],"activeWorkspaceKey":"/tmp/p"}}}
        """#
        let message = try #require(NativeRemoteProtocol.parse(json))
        #expect(message.payload?.zcodeType == "bootstrap-response")
        #expect(message.payload?.result?.desktopAppVersion == "4.0.0")
        #expect(message.payload?.result?.workspaces?.first?.label == "Project")
        #expect(message.payload?.result?.activeWorkspaceKey == "/tmp/p")
    }

    @Test func reassemblesFragmentsInOrder() {
        var assembler = FragmentReassembler()
        #expect(assembler.add(base64: "Aw==", index: 2, count: 3, bytes: 3) == nil)
        #expect(assembler.add(base64: "AQ==", index: 0, count: 3, bytes: 3) == nil)
        let complete = assembler.add(base64: "Ag==", index: 1, count: 3, bytes: 3)
        #expect(complete == Data([1, 2, 3]))
    }

    @Test func singleFragmentPassesThrough() {
        var assembler = FragmentReassembler()
        #expect(assembler.add(base64: "AQID", index: nil, count: nil, bytes: nil)
                == Data([1, 2, 3]))
    }
}

struct RPCBinaryCodecTests {
    @Test func roundTripsAllTags() throws {
        let values: [RPCValue] = [
            .undefined,
            .string("привет"),
            .data(Data([0, 1, 255])),
            .array([.int(300), .string("x")]),
            .object("{\"ok\":true}"),
            .int(2_000_000),
        ]
        for value in values {
            let decoded = try RPCValue.decode(RPCValue.encode(value))
            #expect(decoded == value)
        }
    }

    @Test func decodesRequestMessage() throws {
        let bytes = RPCMessage.request(
            id: 7,
            channel: "zcodeTaskService",
            method: "listTasks",
            arguments: .object("{\"workspacePath\":\"/tmp/p\"}")
        )
        let message = try RPCMessage.decode(bytes)
        #expect(message.type == 100)
        #expect(message.id == 7)
        #expect(message.channel == "zcodeTaskService")
    }

    @Test func crc32MatchesKnownVector() {
        #expect(CRC32.hex(Data("123456789".utf8)) == "cbf43926")
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
