#include "godot-storekit2.h"

#include "core/object/class_db.h"

#import "godot_storekit2-Swift.h"

@import StoreKit;

static NSString *fromGodotString(const String &src) {
	return [NSString stringWithUTF8String:src.utf8().get_data()];
}

static String toGodotString(NSString *src) {
	return String::utf8(src.UTF8String);
}

// One shape for a transaction, used by both the purchase reply and the
// background listener. They disagreed before, and the listener omitted
// everything a validator needs.
static Dictionary transactionToDictionary(TransactionData *data) {
	Dictionary result;
	result["error"] = toGodotString(data.error);
	result["product_id"] = toGodotString(data.productId);
	result["transaction_state"] = (GodotStoreKit2::TransactionState)data.transactionState;
	result["id"] = toGodotString(data.transactionId);
	result["original_id"] = toGodotString(data.originalTransactionId);
	result["jws"] = toGodotString(data.jws);
	if (data.purchaseDate) {
		result["purchase_date"] = (int64_t)[data.purchaseDate timeIntervalSince1970];
	}
	if (data.revocationDate) {
		result["revocation_date"] = (int64_t)[data.revocationDate timeIntervalSince1970];
	}
	return result;
}

void GodotStoreKit2::_bind_methods() {
	ClassDB::bind_method(D_METHOD("request_product_info", "product_id"), &GodotStoreKit2::request_product_info);
	ClassDB::bind_method(D_METHOD("purchase_product", "product_id", "quantity"), &GodotStoreKit2::purchase_product, DEFVAL(1));
	ClassDB::bind_method(D_METHOD("sync"), &GodotStoreKit2::sync);
	ClassDB::bind_method(D_METHOD("finish_transaction", "transaction_id"), &GodotStoreKit2::finish_transaction);

	ADD_SIGNAL(MethodInfo("transaction_state_changed", PropertyInfo(Variant::DICTIONARY, "transaction")));
	ADD_SIGNAL(MethodInfo("product_price_received", PropertyInfo(Variant::DICTIONARY, "price")));
	ADD_SIGNAL(MethodInfo("product_info_received", PropertyInfo(Variant::DICTIONARY, "info")));
	ADD_SIGNAL(MethodInfo("synchronized", PropertyInfo(Variant::STRING, "error")));
	// Definitive: emitted once `finish()` has actually completed, so the app can
	// tell "asked to finish" from "is finished".
	ADD_SIGNAL(MethodInfo("transaction_finished",
			PropertyInfo(Variant::STRING, "transaction_id"),
			PropertyInfo(Variant::BOOL, "success"),
			PropertyInfo(Variant::STRING, "message")));

	BIND_ENUM_CONSTANT(FAILED);
	BIND_ENUM_CONSTANT(REFUNDED);
	BIND_ENUM_CONSTANT(PENDING);
	BIND_ENUM_CONSTANT(DEFERRED);
	BIND_ENUM_CONSTANT(PURCHASED);
	BIND_ENUM_CONSTANT(RESTORED);
	BIND_ENUM_CONSTANT(EXPIRED);
	BIND_ENUM_CONSTANT(CANCELED);
}

Signal GodotStoreKit2::request_product_info(String p_product_id) {
	[proxy getProductInfoWithProductId:fromGodotString(p_product_id) completionHandler:^(ProductInfo *info, NSError *error) {
		Dictionary result;
		if (error) {
			result["error"] = toGodotString(error.userInfo[NSLocalizedDescriptionKey]);
		} else {
			result["error"] = String();
			result["product_id"] = toGodotString(info.productId);
			result["display_name"] = toGodotString(info.displayName);
			result["description"] = toGodotString(info.productDescription);
			result["is_purchased"] = info.isPurchased;
			PriceInfo *priceInfo = info.priceInfo;
			result["currency_value"] = priceInfo.currencyValue;
			result["currency_code"] =  toGodotString(priceInfo.currencyCode);
			result["currency_symbol"] = toGodotString(priceInfo.currencySymbol);
			result["localized_price"] = toGodotString(priceInfo.localizedDisplay);
		}

		call_deferred("emit_signal", "product_info_received", result);
	}];

	return Signal(this, "product_info_received");
}

Signal GodotStoreKit2::purchase_product(String p_product_id, int p_quantity) {;
	[proxy purchaseProductWithProductId:fromGodotString(p_product_id) quantity:p_quantity completionHandler:^(TransactionData *data, NSError *error) {
		Dictionary result;
		if (error) {
			// Name the product even on failure, so a listener can tell which
			// purchase died rather than receiving an anonymous error.
			result["error"] = toGodotString(error.userInfo[NSLocalizedDescriptionKey]);
			result["product_id"] = p_product_id;
			result["transaction_state"] = (TransactionState)FAILED;
		} else {
			result = transactionToDictionary(data);
		}

		call_deferred("emit_signal", "transaction_state_changed", result);
	}];

	return Signal(this, "transaction_state_changed");
}

Signal GodotStoreKit2::sync() {
	[proxy restorePurchasesWithCompletionHandler:^(NSError *error) {
		String result;
		if (error) {
			result = toGodotString(error.localizedDescription);
		}

		call_deferred("emit_signal", "synchronized", result);
	}];

	return Signal(this, "synchronized");
}

Signal GodotStoreKit2::finish_transaction(String p_transaction_id) {
	[proxy finishTransactionWithTransactionId:fromGodotString(p_transaction_id) completionHandler:^(NSError *error) {
		bool success = (error == nil);
		String message;
		if (error) {
			message = toGodotString(error.localizedDescription);
		}

		call_deferred("emit_signal", "transaction_finished", p_transaction_id, success, message);
	}];

	return Signal(this, "transaction_finished");
}

GodotStoreKit2::GodotStoreKit2() {
	proxy = [[GodotStoreKit2Proxy alloc] initWithTransactionCallback:^(TransactionData *data) {
		_on_transaction_state_changed(data);
	}];
}

void GodotStoreKit2::_on_transaction_state_changed(TransactionData *data) {
	call_deferred("emit_signal", "transaction_state_changed", transactionToDictionary(data));
}
