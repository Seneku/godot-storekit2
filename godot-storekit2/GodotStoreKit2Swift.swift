import Foundation
import StoreKit

@objcMembers
public final class GodotStoreKit2Proxy: NSObject,
@unchecked Sendable
{
	private var updates: Task<Void, Never>? = nil
	private var unfinished: Task<Void, Never>? = nil
	private var transactionCallback: (TransactionData) -> ()

	public init(transactionCallback: @Sendable @escaping (TransactionData) -> ()) {
		self.transactionCallback = transactionCallback
		super.init()
		updates = newTransactionListenerTask(transactions: Transaction.updates)
		unfinished = newTransactionListenerTask(transactions: Transaction.unfinished)
	}

	deinit {
		// Cancel the update handling task when you deinitialize the class.
		updates?.cancel()
	}

	private func newTransactionListenerTask(transactions: Transaction.Transactions) -> Task<Void, Never> {
		Task(priority: .background) { @Sendable [weak self] in
			for await verificationResult in transactions {
				self?.handle(updatedTransaction: verificationResult)
			}
		}
	}

	private func handle(updatedTransaction verificationResult: VerificationResult<Transaction>) {
		guard case .verified(let transaction) = verificationResult else {
			// Ignore unverified transactions.
			return
		}

		let transData = TransactionData()
		transData.productId = transaction.productID
		transData.transactionId = String(transaction.id)
		transData.originalTransactionId = String(transaction.originalID)
		transData.jws = verificationResult.jwsRepresentation

		if let revocationDate = transaction.revocationDate {
			// Remove access to the product identified by transaction.productID.
			// Transaction.revocationReason provides details about
			// the revoked transaction.
			transData.transactionState = TransactionState.Refunded.rawValue
			transData.revocationDate = revocationDate
		} else if let expirationDate = transaction.expirationDate,
				  expirationDate < Date() {
			// Do nothing, this subscription is expired.
			return
		} else if transaction.isUpgraded {
			// Do nothing, there is an active transaction
			// for a higher level of service.
			return
		} else {
			// Provide access to the product identified by
			// transaction.productID.
			transData.transactionState = TransactionState.Purchased.rawValue
			transData.purchaseDate = transaction.purchaseDate
		}

		self.transactionCallback(transData)
	}

	public func test() -> Bool {
		return true;
	}

	public func isProductAvailable(productId: NSString) -> Bool {
		return false;
	}

	public func isProductPurchased(productId: NSString) -> Bool {
		return false;
	}

	private func priceInfoFromProduct(product: Product) -> PriceInfo {
		let info = PriceInfo()
		info.currencyValue = product.price as NSDecimalNumber
		info.localizedDisplay = product.displayPrice
		info.currencyCode = product.priceFormatStyle.currencyCode

		// Get the currency symbol.
		let currencyCode = product.priceFormatStyle.currencyCode
		let locale = product.priceFormatStyle.locale
		let formatter = NumberFormatter()
		formatter.numberStyle = .currency
		formatter.currencyCode = currencyCode
		formatter.locale = locale
		let currencySymbol = formatter.currencySymbol
		info.currencySymbol = currencySymbol!

		return info
	}

	public func getProductInfo(productId: NSString) async throws -> ProductInfo {
		let productIdentifiers: Set<String> = [productId as String]
		let appProducts = try await Product.products(for: productIdentifiers)
		guard let product = appProducts.first else {
			throw NSError(domain: "GodotStoreKit2Proxy", code: 1, userInfo: [NSLocalizedDescriptionKey: "Product not found"])
		}

		let info = ProductInfo()
		info.productId = product.id
		info.displayName = product.displayName
		info.productDescription = product.description
		info.priceInfo = priceInfoFromProduct(product: product)

		if #available(iOS 18.4, *) {
			for await verificationResult in product.currentEntitlements {
				switch verificationResult {
				case .verified(_):
					info.isPurchased = true
				default:
					info.isPurchased = false
				}
			}
		} else {
			let entitlement = await product.currentEntitlement
			switch entitlement {
			case .verified(_):
				info.isPurchased = true
			default:
				info.isPurchased = false
			}
		}

		return info
	}

	public func getProductPrice(productId: NSString) async throws -> PriceInfo {
		let productIdentifiers: Set<String> = [productId as String]
		let appProducts = try await Product.products(for: productIdentifiers)
		guard let product = appProducts.first else {
			throw NSError(domain: "GodotStoreKit2Proxy", code: 1, userInfo: [NSLocalizedDescriptionKey: "Product not found"])
		}

		return priceInfoFromProduct(product: product)
	}

	public func purchaseProduct(productId: String, quantity: Int) async throws -> TransactionData {
		let productIdentifiers: Set<String> = [productId]
		let appProducts = try await Product.products(for: productIdentifiers)
		guard let product = appProducts.first else {
			throw NSError(domain: "GodotStoreKit2Proxy", code: 1, userInfo: [NSLocalizedDescriptionKey: "Product not found"])
		}

		let result = try await product.purchase(options: [
			.quantity(quantity)
		])

		let data = TransactionData()
		data.productId = productId
		switch result{
		case .pending:
			data.transactionState = TransactionState.Pending.rawValue
		case .userCancelled:
			data.transactionState = TransactionState.Canceled.rawValue
		case .success(let verificationResult):
			// Deliberately NOT finished here. This is the whole point of the
			// fork: the transaction stays in `Transaction.unfinished` until the
			// app has validated it server-side and calls `finishTransaction`.
			// Finishing it now would consume the purchase before anyone could
			// refuse it, and would lose it entirely if the app died mid-flight.
			data.jws = verificationResult.jwsRepresentation
			switch verificationResult {
			case .verified(let transaction):
				data.transactionId = String(transaction.id)
				data.originalTransactionId = String(transaction.originalID)
				data.purchaseDate = transaction.purchaseDate
				data.transactionState = TransactionState.Purchased.rawValue
			case .unverified(let transaction, let verificationError):
				// Signature check failed, so this must never be granted. It is
				// still left unfinished, and still named, so the app can clear
				// it deliberately rather than having it silently disappear.
				data.transactionId = String(transaction.id)
				data.originalTransactionId = String(transaction.originalID)
				data.transactionState = TransactionState.Failed.rawValue
				data.error = verificationError.errorDescription ?? "Transaction failed verification."
			}
		@unknown default:
			data.error = "unknown"
			data.transactionState = TransactionState.Failed.rawValue
		}
		return data
	}

	/// Finish a transaction the app has finished with — normally once a server
	/// has validated it. Throws when no unfinished transaction carries the id,
	/// which is the honest answer: either it was finished already, or the id is
	/// wrong, and the caller must not treat either as success.
	public func finishTransaction(transactionId: String) async throws -> Void {
		for await verificationResult in Transaction.unfinished {
			let transaction: Transaction
			switch verificationResult {
			case .verified(let value):
				transaction = value
			case .unverified(let value, _):
				transaction = value
			}
			if String(transaction.id) == transactionId {
				await transaction.finish()
				return
			}
		}
		throw NSError(
			domain: "GodotStoreKit2Proxy",
			code: 2,
			userInfo: [
				NSLocalizedDescriptionKey:
					"No unfinished transaction with id \(transactionId)."
			]
		)
	}

	public func restorePurchases() async throws -> Void {
		try await AppStore.sync()
	}
}

// Keep in sync wit C++ enum.
public enum TransactionState: Int {
	case Failed = 0
	case Refunded = 1
	case Pending = 2
	case Deferred = 3
	case Purchased = 4
	case Restored = 5
	case Expired = 6
	case Canceled = 7
};

@objcMembers
public class PriceInfo: NSObject {
	public var currencyValue: NSDecimalNumber = 0.0
	public var currencyCode = ""
	public var currencySymbol = "$"
	public var localizedDisplay = ""
}

@objcMembers
public class InitializationData: NSObject {
	var initialized: Bool = false;
	public var error = ""
}

@objcMembers
public class TransactionData: NSObject {
	public var productId = ""
	public var transactionState = TransactionState.Failed.rawValue
	public var error = ""
	public var purchaseDate: Date? = nil
	public var revocationDate: Date? = nil

	/// Stable identity for this transaction. The consuming app uses it as the
	/// idempotency key when validating, and to name the transaction it wants
	/// finished later. Upstream never surfaced it, which is why validation
	/// could not be correlated to a purchase.
	public var transactionId = ""
	/// The original purchase for a restore or a renewal. For a first purchase
	/// this equals `transactionId`.
	public var originalTransactionId = ""
	/// The signed JWS representation, which is the only thing a server can
	/// verify against Apple's public keys. Without it there is nothing to
	/// validate and the client would be trusting itself.
	public var jws = ""
}

@objcMembers
public class ProductInfo: NSObject {
	public var productId = ""
	public var displayName = ""
	public var productDescription = ""
	public var isPurchased = false
	public var priceInfo = PriceInfo()
}
