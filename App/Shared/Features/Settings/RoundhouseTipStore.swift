import Observation
import StoreKit

/// Tips are consumable thank-yous. A purchase never changes a rider's access.
@Observable @MainActor
final class RoundhouseTipStore {
  static let productID = "com.jorgeaguirre.TrainTracker.tip.hosting"
  static let shared = RoundhouseTipStore()

  enum Status: Equatable {
    case idle, buying, pending, thanked, purchaseFailed, unverified
  }

  private(set) var product: Product?
  private(set) var loading = false
  private(set) var didCheckStore = false
  private(set) var status = Status.idle
  @ObservationIgnored private var updatesTask: Task<Void, Never>?

  func startObserving() {
    guard updatesTask == nil else { return }
    updatesTask = Task {
      for await result in Transaction.updates {
        _ = await accept(result)
      }
    }
    Task {
      for await result in Transaction.unfinished {
        _ = await accept(result)
      }
    }
  }

  func load() async {
    guard product == nil, !loading else { return }
    loading = true
    defer {
      loading = false
      didCheckStore = true
    }
    product = try? await Product.products(for: [Self.productID]).first {
      $0.id == Self.productID && $0.type == .consumable
    }
  }

  func sendTip(using purchase: (Product) async throws -> Product.PurchaseResult) async {
    guard let product, status != .buying else { return }
    status = .buying
    do {
      switch try await purchase(product) {
      case .success(let result):
        if !(await accept(result)) { status = .unverified }
      case .pending:
        status = .pending
      case .userCancelled:
        status = .idle
      @unknown default:
        status = .purchaseFailed
      }
    } catch {
      status = .purchaseFailed
    }
  }

  func openJar() {
    if status != .buying {
      status = .idle
    }
  }

  @discardableResult
  func accept(_ result: VerificationResult<Transaction>) async -> Bool {
    guard case .verified(let transaction) = result,
          transaction.productID == Self.productID, transaction.productType == .consumable
    else { return false }
    await transaction.finish()
    if transaction.revocationDate == nil { status = .thanked }
    return true
  }
}
