import StoreKit
import StoreKitTest
import XCTest
@testable import TrainTracker

@MainActor
final class SupportRoundhouseTipJarTests: XCTestCase {
  func testCatalogAndRepeatableGuestPurchase() async throws {
    let session = try session()
    let store = RoundhouseTipStore()
    await store.load()
    let product = try XCTUnwrap(store.product)
    XCTAssertEqual(product.type, .consumable)
    XCTAssertEqual(product.price, Decimal(string: "0.99"))
    for _ in 0..<2 {
      let transaction = try await session.buyProduct(identifier: product.id)
      await store.sendTip { _ in .success(.verified(transaction)) }
      XCTAssertEqual(store.status, .thanked)
      store.openJar()
      XCTAssertEqual(store.status, .idle)
    }
    XCTAssertEqual(session.allTransactions().filter { $0.productIdentifier == product.id }.count, 2)
  }

  func testCancelledPendingAndFailedTipsHaveNoPurchase() async throws {
    let session = try session()
    let store = RoundhouseTipStore()
    await store.load()
    XCTAssertNotNil(store.product)
    await store.sendTip { _ in .userCancelled }
    XCTAssertEqual(store.status, .idle)
    await store.sendTip { _ in .pending }
    XCTAssertEqual(store.status, .pending)
    await store.sendTip { _ in throw URLError(.notConnectedToInternet) }
    XCTAssertEqual(store.status, .purchaseFailed)
    XCTAssertTrue(session.allTransactions().isEmpty)
  }

  private func session() throws -> SKTestSession {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "RoundhouseTips", withExtension: "storekit"))
    let session = try SKTestSession(contentsOf: url)
    session.resetToDefaultState()
    session.storefront = "USA"
    session.disableDialogs = true
    session.clearTransactions()
    addTeardownBlock { session.clearTransactions(); session.resetToDefaultState() }
    return session
  }
}
