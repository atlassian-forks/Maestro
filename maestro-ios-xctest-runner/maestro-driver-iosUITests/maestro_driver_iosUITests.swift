import XCTest
import FlyingFox
import os

final class maestro_driver_iosUITests: XCTestCase {
   
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "maestro_driver_iosUITests"
    )

    private static var swizzledOutIdle = false

    override func setUpWithError() throws {
        // XCTest internals sometimes use XCTAssert* instead of exceptions.
        // Setting `continueAfterFailure` so that the xctest runner does not stop
        // when an XCTest internal error happes (eg: when using .allElementsBoundByIndex
        // on a ReactNative app)
        continueAfterFailure = true
    }

    override class func setUp() {
        logger.trace("setUp")
    }

    func testHttpServer() async throws {
        let server = XCTestHTTPServer()
        maestro_driver_iosUITests.logger.info("Will start HTTP server")
        try await server.start()
    }

    override class func tearDown() {
        logger.trace("tearDown")
    }
}

/// Pure-logic tests for `SwipeRouteHandlerV2.classify`. No app is launched, so these run on the
/// simulator's test runtime without touching a device. The XCUITest error inputs below are the
/// real domain/code/message observed in production for the DoorDash swipeV2 failures.
final class SwipeRouteHandlerV2ClassificationTests: XCTestCase {

    // Error Domain=com.apple.dt.XCTest.XCTFuture Code=1000
    // "Swipe (v2) from (201.0, 437.0) to (201.0, 786.0) with 0.4 duration: Timed out while evaluating UI query."
    func testUIQueryTimeoutIsClassifiedAsTimeout() {
        let error = NSError(
            domain: "com.apple.dt.XCTest.XCTFuture",
            code: 1000,
            userInfo: [NSLocalizedDescriptionKey:
                "Swipe (v2) from (201.0, 437.0) to (201.0, 786.0) with 0.4 duration: Timed out while evaluating UI query."]
        )
        let result = SwipeRouteHandlerV2.classify(error)
        XCTAssertEqual(result.type, .timeout)
        // Pin the end-to-end contract: .timeout must surface as HTTP 408 (non-retryable), not 500.
        XCTAssertEqual(result.httpResponse.statusCode, .requestTimeout)
    }

    func testMainThreadBusyIsClassifiedAsTimeout() {
        let error = NSError(
            domain: "com.apple.dt.xctest.automation-support.error",
            code: 6,
            userInfo: [NSLocalizedDescriptionKey:
                "Unable to perform work on main run loop, process main thread busy for 5.0s"]
        )
        XCTAssertEqual(SwipeRouteHandlerV2.classify(error).type, .timeout)
    }

    // The same message on a different domain must NOT be reclassified: we only want the specific
    // XCUITest timeouts, not any error that happens to contain the phrase.
    func testTimeoutMessageWithWrongDomainStaysInternal() {
        let error = NSError(
            domain: "com.example.other",
            code: 1000,
            userInfo: [NSLocalizedDescriptionKey: "Timed out while evaluating UI query."]
        )
        XCTAssertEqual(SwipeRouteHandlerV2.classify(error).type, .internal)
    }

    // Right domain, wrong code/message (e.g. a genuine swipe failure) keeps the default 500.
    func testUnrelatedXCTFutureErrorStaysInternal() {
        let error = NSError(
            domain: "com.apple.dt.XCTest.XCTFuture",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "Some other failure"]
        )
        let result = SwipeRouteHandlerV2.classify(error)
        XCTAssertEqual(result.type, .internal)
        // Pin the other side of the contract: a non-timeout swipe failure stays HTTP 500.
        XCTAssertEqual(result.httpResponse.statusCode, .internalServerError)
    }

    // Right domain AND code, but a message that lacks the timeout phrase must NOT be reclassified.
    // This isolates the message-substring guard: without it, every XCTFuture/1000 error (including
    // genuine swipe failures) would be misclassified as a non-retryable 408.
    func testXCTFutureCode1000WithUnrelatedMessageStaysInternal() {
        let error = NSError(
            domain: "com.apple.dt.XCTest.XCTFuture",
            code: 1000,
            userInfo: [NSLocalizedDescriptionKey: "Swipe (v2) failed for an unrelated reason."]
        )
        XCTAssertEqual(SwipeRouteHandlerV2.classify(error).type, .internal)
    }

    // A timeout must be classified as .timeout AND carry the real Apple message (this is what fixes
    // the "Unknown error" gap). Asserting the message alone is insufficient: classify() builds the
    // message identically in every branch, so it would pass even on the .internal fallthrough.
    func testClassifiedTimeoutPreservesTheRealMessage() {
        let error = NSError(
            domain: "com.apple.dt.XCTest.XCTFuture",
            code: 1000,
            userInfo: [NSLocalizedDescriptionKey: "Timed out while evaluating UI query."]
        )
        let result = SwipeRouteHandlerV2.classify(error)
        XCTAssertEqual(result.type, .timeout)
        XCTAssertTrue(result.message.contains("Timed out while evaluating UI query"))
    }
}


final class RemoteWindowCoordinateTests: XCTestCase {
    private func frame(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> [String: Double] {
        ["X": x, "Y": y, "Width": width, "Height": height]
    }

    private func offset(
        raw: [String: Double]? = nil,
        parent: [String: Double]? = nil,
        parentContext: Double? = 1,
        context: Double = 2,
        remote: Bool = true,
        parentRemote: Bool? = false,
        allowsHostFallback: Bool = true,
        hasAnchor: Bool = true,
        anchor: VisibleHostAnchor? = nil,
        visible: [String: Double]? = nil
    ) -> CGVector {
        let parentFrame = parent ?? frame(9, 501, 384, 364)
        let confirmedAnchor = hasAnchor ? (anchor ?? VisibleHostAnchor(frame: parentFrame, windowContextID: parentContext ?? 0)) : nil
        return CrossProcessWindowGeometry.offset(
            rawFrame: raw ?? frame(0, 0, 384, 364),
            parentFrame: parent ?? frame(9, 501, 384, 364),
            parentWindowContextID: parentContext, windowContextID: context,
            remoteSubtree: remote, parentIsRemote: parentRemote, visibleFrame: visible,
            allowsHostFallback: allowsHostFallback, visibleHostAnchor: confirmedAnchor
        )
    }

    func testSameWindowDoesNotReadPrivateSnapshotMetadata() {
        var reads: [String] = []
        func read<T>(_ name: String, _ value: T) -> T { reads.append(name); return value }
        XCTAssertEqual(CrossProcessWindowGeometry.offset(
            rawFrame: frame(0, 0, 384, 364), parentFrame: frame(9, 501, 384, 364),
            parentWindowContextID: 1, windowContextID: 1,
            remoteSubtree: read("remote", true), parentIsRemote: read("parent", false),
            visibleFrame: read("visible", nil), allowsHostFallback: read("null", true),
            visibleHostAnchor: read("anchor", nil)), .zero)
        XCTAssertTrue(reads.isEmpty)
    }

    func testFiniteVisibleFrameDoesNotResolveFallbackMetadata() {
        var reads: [String] = []
        func read<T>(_ name: String, _ value: T) -> T { reads.append(name); return value }
        XCTAssertEqual(CrossProcessWindowGeometry.offset(
            rawFrame: frame(0, 0, 384, 364), parentFrame: frame(9, 501, 384, 364),
            parentWindowContextID: 1, windowContextID: 2,
            remoteSubtree: read("remote", true), parentIsRemote: read("parent", false),
            visibleFrame: read("visible", frame(9, 501, 384, 364)),
            allowsHostFallback: read("null", true), visibleHostAnchor: read("anchor", nil)),
            CGVector(dx: 9, dy: 501))
        XCTAssertEqual(reads, ["remote", "visible"])
    }

    func testConfirmedVisibleAnchorDoesNotResolveEarlierAncestors() {
        var previousReads = 0
        func previous() -> VisibleHostAnchor? { previousReads += 1; return nil }
        let full = frame(9, 501, 384, 364)
        let anchor = VisibleHostAnchor.advance(previous: previous(), rawFrame: full,
            visibleFrame: full, windowContextID: 1, isRemote: false)
        XCTAssertEqual(anchor?.frame, full)
        XCTAssertEqual(previousReads, 0)
    }

    func testRemoteHostDoesNotResolveVisibleFrameOrAncestors() {
        var reads: [String] = []
        func read<T>(_ name: String, _ value: T) -> T { reads.append(name); return value }
        XCTAssertNil(VisibleHostAnchor.advance(previous: read("previous", nil),
            rawFrame: frame(9, 501, 384, 364), visibleFrame: read("visible", nil),
            windowContextID: 1, isRemote: true))
        XCTAssertTrue(reads.isEmpty)
    }

    func testObservedShareBoundaryWithoutVisibleFrameUsesHostTranslation() {
        XCTAssertEqual(offset(), CGVector(dx: 9, dy: 501))
    }

    func testExistingVisibleFramePathRetainsPriorityWithoutFallbackGeometry() {
        XCTAssertEqual(offset(raw: frame(10, 20, 200, 100), parentRemote: true,
                              visible: frame(30, 70, 180, 90)), CGVector(dx: 20, dy: 50))
    }

    func testFiniteZeroAreaVisibleFrameKeepsExistingPriority() {
        XCTAssertEqual(offset(visible: frame(17, 33, 0, 0)), CGVector(dx: 17, dy: 33))
        XCTAssertEqual(offset(visible: frame(0, 0, 0, 0)), .zero)
    }

    func testFallbackSupportsSingleAxisTranslation() {
        XCTAssertEqual(offset(parent: frame(0, 501, 384, 364)), CGVector(dx: 0, dy: 501))
        XCTAssertEqual(offset(parent: frame(9, 0, 384, 364)), CGVector(dx: 9, dy: 0))
    }

    func testContextAndRemoteSignalsRemainRequired() {
        XCTAssertEqual(offset(parentContext: nil), .zero)
        XCTAssertEqual(offset(parentContext: 0), .zero)
        XCTAssertEqual(offset(context: 0), .zero)
        XCTAssertEqual(offset(context: 1), .zero)
        XCTAssertEqual(offset(parentContext: .nan), .zero)
        XCTAssertEqual(offset(context: .infinity), .zero)
        XCTAssertEqual(offset(remote: false), .zero)
        // A visible-frame delta must not bypass the existing process/remote guards either.
        XCTAssertEqual(offset(context: 1, visible: frame(9, 501, 384, 364)), .zero)
        XCTAssertEqual(offset(remote: false, visible: frame(9, 501, 384, 364)), .zero)
    }

    func testFallbackRejectsAlreadyAbsoluteOrDifferentlySizedRemoteRoot() {
        XCTAssertEqual(offset(raw: frame(9, 501, 384, 364)), .zero)
        XCTAssertEqual(offset(raw: frame(0, 0, 383, 364)), .zero)
        XCTAssertEqual(offset(raw: frame(0, 0, 384, 363)), .zero)
        XCTAssertEqual(offset(parentRemote: true), .zero)
        XCTAssertEqual(offset(parentRemote: nil), .zero)
        XCTAssertEqual(offset(allowsHostFallback: false), .zero)
    }

    func testFallbackRejectsInvalidOrEmptyHostGeometry() {
        XCTAssertEqual(offset(parent: frame(.infinity, 501, 384, 364)), .zero)
        XCTAssertEqual(offset(parent: frame(9, .nan, 384, 364)), .zero)
        XCTAssertEqual(offset(raw: frame(0, 0, 0, 364), parent: frame(9, 501, 0, 364)), .zero)
        XCTAssertEqual(offset(raw: frame(0, 0, 384, -1), parent: frame(9, 501, 384, -1)), .zero)
        XCTAssertEqual(CrossProcessWindowGeometry.offset(rawFrame: frame(0, 0, 384, 364),
            parentFrame: nil, parentWindowContextID: 1, windowContextID: 2,
            remoteSubtree: true, parentIsRemote: false, visibleFrame: nil,
            allowsHostFallback: true, visibleHostAnchor: nil), .zero)
    }

    func testNestedTranslationAddsInheritedOffsetOnlyOnce() {
        let inherited = CGVector(dx: 100, dy: 200)
        let boundary = offset(parent: frame(9, 31, 384, 364))
        let accumulated = CGVector(dx: inherited.dx + boundary.dx, dy: inherited.dy + boundary.dy)
        XCTAssertEqual(accumulated, CGVector(dx: 109, dy: 231))
        // A later descendant in the remote window retains the accumulated translation.
        XCTAssertEqual(offset(parentContext: 2, context: 2), .zero)
        XCTAssertEqual(CGVector(dx: 19 + accumulated.dx, dy: 197 + accumulated.dy),
                       CGVector(dx: 128, dy: 428))
    }

    func testCapturedZeroProxyChainRetainsConfirmedVisibleAnchor() {
        let full = frame(9, 501, 384, 364)
        let zero = frame(9, 501, 0, 0)
        var anchor = VisibleHostAnchor.advance(previous: nil, rawFrame: full, visibleFrame: full,
                                              windowContextID: 1, isRemote: false)
        anchor = VisibleHostAnchor.advance(previous: anchor, rawFrame: zero, visibleFrame: zero,
                                           windowContextID: 1, isRemote: false)
        // Captured later host wrappers restore raw bounds while reporting zero visible area.
        for _ in 0..<8 {
            anchor = VisibleHostAnchor.advance(previous: anchor, rawFrame: full, visibleFrame: zero,
                                               windowContextID: 1, isRemote: false)
        }
        XCTAssertNotNil(anchor)
        XCTAssertEqual(offset(anchor: anchor), CGVector(dx: 9, dy: 501))
        // A parent that is still zero-size has not restored the anchor and must not shift.
        XCTAssertEqual(offset(raw: zero, parent: zero, anchor: anchor), .zero)
    }

    func testAnchorRejectsShiftedProxyMismatchedGeometryAndAbsentEvidence() {
        let full = frame(9, 501, 384, 364)
        let zero = frame(9, 501, 0, 0)
        let anchor = VisibleHostAnchor(frame: full, windowContextID: 1)
        XCTAssertNil(VisibleHostAnchor.advance(previous: anchor, rawFrame: frame(10, 501, 0, 0),
            visibleFrame: frame(10, 501, 0, 0), windowContextID: 1, isRemote: false))
        XCTAssertNil(VisibleHostAnchor.advance(previous: anchor, rawFrame: frame(9, 501, 383, 364),
            visibleFrame: zero, windowContextID: 1, isRemote: false))
        XCTAssertNil(VisibleHostAnchor.advance(previous: nil, rawFrame: full,
            visibleFrame: zero, windowContextID: 1, isRemote: false))
        XCTAssertEqual(offset(hasAnchor: false), .zero)
        XCTAssertEqual(offset(anchor: VisibleHostAnchor(frame: frame(10, 501, 384, 364), windowContextID: 1)), .zero)
    }

    func testAnchorRejectsUnknownOrChangedContextAndRemoteState() {
        let full = frame(9, 501, 384, 364)
        let zero = frame(9, 501, 0, 0)
        let anchor = VisibleHostAnchor(frame: full, windowContextID: 1)
        XCTAssertNil(VisibleHostAnchor.advance(previous: anchor, rawFrame: full,
            visibleFrame: zero, windowContextID: 2, isRemote: false))
        XCTAssertNil(VisibleHostAnchor.advance(previous: anchor, rawFrame: full,
            visibleFrame: zero, windowContextID: 0, isRemote: false))
        XCTAssertNil(VisibleHostAnchor.advance(previous: anchor, rawFrame: full,
            visibleFrame: zero, windowContextID: 1, isRemote: nil))
        XCTAssertNil(VisibleHostAnchor.advance(previous: anchor, rawFrame: full,
            visibleFrame: zero, windowContextID: 1, isRemote: true))
        XCTAssertNil(VisibleHostAnchor.advance(previous: anchor, rawFrame: full,
            visibleFrame: nil, windowContextID: 1, isRemote: false))
        XCTAssertEqual(offset(anchor: VisibleHostAnchor(frame: full, windowContextID: 2)), .zero)
    }

}
