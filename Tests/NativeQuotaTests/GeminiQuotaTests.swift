import XCTest
@testable import AntigravityQuotaDock

final class GeminiQuotaTests: XCTestCase {
    private func decode(_ buckets: String) throws -> GeminiQuota {
        try GeminiQuota.decode(Data("{\"response\":{\"groups\":[{\"buckets\":[\(buckets)]}]}}".utf8))
    }
    func testExactSharedPoolSelectionAndZero() throws {
        let quota = try decode("""
        {"bucketId":"gemini-image-5h","remainingFraction":0.9},
        {"bucketId":"3p-5h","remainingFraction":1},
        {"bucketId":"gemini-weekly","remainingFraction":0.8659},
        {"bucketId":"gemini-5h","remainingFraction":0}
        """)
        XCTAssertEqual(quota.fiveHour.percent, 0)
        XCTAssertEqual(quota.weekly?.percent, 87)
    }
    func testActualFractionAndReset() throws {
        let quota = try decode("""
        {"bucketId":"gemini-5h","remainingFraction":0.9290858,"resetTime":"2026-09-07T12:01:21Z"}
        """)
        XCTAssertEqual(quota.fiveHour.percent, 93)
        XCTAssertEqual(quota.fiveHour.resetTime, "2026-09-07T12:01:21Z")
        XCTAssertNil(quota.weekly)
    }
    func testInvalidInputFails() {
        for fraction in ["null", "true", "\"0.5\"", "-0.01", "1.01"] {
            XCTAssertThrowsError(try decode("{\"bucketId\":\"gemini-5h\",\"remainingFraction\":\(fraction)}"))
        }
        XCTAssertThrowsError(try decode(""))
        XCTAssertThrowsError(try decode("{\"bucketId\":\"gemini-5h\"}"))
        XCTAssertThrowsError(try decode("{\"bucketId\":\"gemini-5h\",\"remainingFraction\":1,\"resetTime\":\"bad\"}"))
        let bucket = "{\"bucketId\":\"gemini-5h\",\"remainingFraction\":1}"
        XCTAssertThrowsError(try decode(bucket + "," + bucket))
    }
}
