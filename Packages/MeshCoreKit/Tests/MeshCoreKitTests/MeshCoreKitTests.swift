import XCTest
@testable import MeshCoreKit

final class MeshCoreKitTests: XCTestCase {
    func testBuildAppStart() {
        let frame = MeshCoreProtocol.buildAppStart()
        XCTAssertEqual(frame, Data([0x01]))
    }

    func testBuildGetDeviceInfo() {
        let frame = MeshCoreProtocol.buildGetDeviceInfo()
        XCTAssertEqual(frame, Data([0x06]))
    }

    func testPublicKeyHash() {
        let keyData = Data(repeating: 0xAB, count: 32)
        let hash = MeshCoreCrypto.publicKeyHash(from: keyData)
        XCTAssertEqual(hash.count, 6)
    }
}
