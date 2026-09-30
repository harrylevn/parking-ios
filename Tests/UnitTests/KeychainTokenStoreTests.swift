import Security
import XCTest
@testable import Parking

/// The real Keychain, under a service name of its own so the app's session is never touched.
final class KeychainTokenStoreTests: XCTestCase {

    private let store = KeychainTokenStore(service: "com.vncdc.parking.tests.\(UUID().uuidString)")

    override func tearDown() {
        try? store.clear()
        super.tearDown()
    }

    func testATokenRoundTripsAndIsReplacedNotDuplicated() throws {
        XCTAssertNil(try store.read())
        try store.save("first")
        try store.save("second")
        XCTAssertEqual(try store.read(), "second")
        try store.clear()
        XCTAssertNil(try store.read())
    }

    func testClearingAnEmptyStoreIsNotAnError() throws {
        XCTAssertNoThrow(try store.clear())
    }

    /// The accessibility class is the Guardrail: unreadable while locked, never in a backup,
    /// never migrated to another device. Read back from the Keychain, not from the code.
    func testTheTokenIsStoredWhenUnlockedAndOnThisDeviceOnly() throws {
        try store.save("token")
        var query = store.baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &item), errSecSuccess)
        let attributes = try XCTUnwrap(item as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }
}
