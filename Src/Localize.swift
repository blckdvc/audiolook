import Foundation

/// Localisation minimale : rend la chaîne française si l'OS est en français, sinon l'anglaise.
/// (Suit la langue préférée du système.)
enum Lang {
    static let isFR: Bool = (Locale.preferredLanguages.first ?? "en").lowercased().hasPrefix("fr")
    /// `t(en, fr)` → `fr` en français, `en` sinon.
    static func t(_ en: String, _ fr: String) -> String { isFR ? fr : en }
}
