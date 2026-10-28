import SunbayCheckout

// Cross-package integration smoke test.
//
// This file references a representative slice of the SunbayCheckout public API so that
// resolution is load-bearing: if the `.package(path: "..")` dependency were wrong, or any
// referenced public symbol were missing or renamed, this file would fail to compile.
//
// It uses only cross-platform public types (no UIKit/PassKit UI), so it links on the macOS
// host exactly like the SDK's own host build.

/// Describes a CheckoutOutcome without exposing any sensitive data.
func describe(_ outcome: CheckoutOutcome) -> String {
    switch outcome {
    case .succeeded(let txnId):
        return "succeeded(\(txnId))"
    case .failed(_, let error):
        return "failed(\(error.code))"
    case .canceled:
        return "canceled"
    case .pending:
        return "pending"
    case .unknown(let sessionId):
        return "unknown(\(sessionId))"
    }
}

@main
struct SmokeMain {
    static func main() {
        // Public symbol #1: CheckoutConfiguration (with its Environment enum and locale).
        let config = CheckoutConfiguration(environment: .test, locale: "en-US")

        // Public symbol #2: SunbayCheckout entry point.
        let sdk = SunbayCheckout(configuration: config)
        _ = sdk

        // Public symbol #3: CheckoutError (constructed via its public initializer).
        let error = CheckoutError(
            code: "SMOKE_OK",
            message: "integration smoke test",
            category: .runtime,
            traceId: nil
        )

        // Public symbol #4: CheckoutOutcome (exercised through describe()).
        let outcome: CheckoutOutcome = .failed(txnId: nil, error: error)
        _ = describe(outcome)
    }
}
