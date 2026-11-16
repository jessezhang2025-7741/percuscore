import XCTest
@testable import PercuscoreCore

final class PerformanceTests: XCTestCase {
    func testPerformanceControlsAndIdlePolicy() {
        var state = PerformanceSession()
        XCTAssertFalse(state.keepAwake(preference: false, appActive: true))
        state.enter()
        XCTAssertTrue(state.isActive)
        XCTAssertFalse(state.exitVisible)
        XCTAssertTrue(state.keepAwake(preference: false, appActive: true))
        XCTAssertFalse(state.keepAwake(preference: true, appActive: false))
        state.tapCenter()
        XCTAssertTrue(state.exitVisible)
        state.pageTurned()
        XCTAssertFalse(state.exitVisible)
        state.exit()
        XCTAssertFalse(state.isActive)
        XCTAssertFalse(state.keepAwake(preference: false, appActive: true))
        XCTAssertTrue(state.keepAwake(preference: true, appActive: true))
    }
}
