import Foundation

/// CC Switch 5ae6ad3 model_pricing subset (MIT); see THIRD_PARTY_NOTICES.md.
/// V4 aliases/rates checked against https://api-docs.deepseek.com/quick_start/pricing on 2026-10-08.
enum DeepSeekReferencePricing {
    static func family(_ model: String) -> String {
        let name = (model.split(separator: "/").last.map(String.init) ?? model)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch name {
        case "deepseek-flash", "deepseek-v4.1-flash", "deepseek-v4-flash",
             "deepseek-v4-flash-0731", "deepseek-v4-flash-vision-exp":
            return "deepseek-flash"
        case "deepseek-v4-pro", "deepseek-v4-pro-0813":
            return "deepseek-v4-pro"
        default: return name
        }
    }

    static func rates(for model: String) -> [String: Any]? {
        let rates: [String]
        switch family(model) {
        case "deepseek-flash": rates = ["0.30", "1.20", "0.006", "0"]
        case "deepseek-v4-pro": rates = ["1.32", "3.96", "0.044", "0"]
        case "deepseek-v3.2": rates = ["0.28", "0.42", "0.028", "0"]
        case "deepseek-v3.1": rates = ["0.55", "1.67", "0.055", "0"]
        case "deepseek-v3": rates = ["0.28", "1.11", "0.028", "0"]
        default: return nil // Unknown versions and ambiguous chat/reasoner aliases must not silently inherit a price.
        }
        // ponytail: snapshot prices, V4 PEAK only; not historical/gateway invoices or time-of-use billing.
        return Dictionary(uniqueKeysWithValues: zip(["input", "output", "cacheRead", "cacheWrite"], rates))
    }
}
