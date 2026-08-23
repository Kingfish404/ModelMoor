import XCTest
@testable import ModelMoorCore
@testable import ModelMoorSystem

final class SoftwareUpdateTests: XCTestCase {
    func testVersionComparisonHandlesNumericComponents() throws {
        XCTAssertGreaterThan(try XCTUnwrap(AppVersion("v1.10.0")), try XCTUnwrap(AppVersion("1.9.9")))
        XCTAssertEqual(AppVersion("1.0"), AppVersion("1.0.0"))
    }

    func testStableVersionIsNewerThanPrerelease() throws {
        XCTAssertGreaterThan(try XCTUnwrap(AppVersion("2.0.0")), try XCTUnwrap(AppVersion("2.0.0-rc.2")))
        XCTAssertGreaterThan(try XCTUnwrap(AppVersion("2.0.0-rc.10")), try XCTUnwrap(AppVersion("2.0.0-rc.2")))
    }

    func testInvalidVersionTagsAreRejected() {
        XCTAssertNil(AppVersion("release-next"))
        XCTAssertNil(AppVersion("1..2"))
        XCTAssertNil(AppVersion(""))
    }
}
