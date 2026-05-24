import Foundation

struct SharePageSettings: Codable, Equatable {
    var titleOverride: String
    var description: String
    var creatorName: String
    var callToActionLabel: String
    var callToActionURL: String
    var accentColor: CodableColor

    init(
        titleOverride: String = "",
        description: String = "",
        creatorName: String = "",
        callToActionLabel: String = "",
        callToActionURL: String = "",
        accentColor: CodableColor = CodableColor(r: 0.23, g: 0.51, b: 0.96)
    ) {
        self.titleOverride = titleOverride
        self.description = description
        self.creatorName = creatorName
        self.callToActionLabel = callToActionLabel
        self.callToActionURL = callToActionURL
        self.accentColor = accentColor
    }

    var resolvedTitleFallback: String? {
        let trimmed = titleOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var validCallToActionURL: URL? {
        let trimmed = callToActionURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            return nil
        }
        return url
    }

    func sanitizedForUse() -> SharePageSettings {
        var copy = self
        copy.titleOverride = Self.limited(titleOverride, maxLength: 140)
        copy.description = Self.limited(description, maxLength: 600)
        copy.creatorName = Self.limited(creatorName, maxLength: 120)
        copy.callToActionLabel = Self.limited(callToActionLabel, maxLength: 80)
        copy.callToActionURL = validCallToActionURL?.absoluteString ?? ""
        copy.accentColor = accentColor.sanitized()
        return copy
    }

    private static func limited(_ value: String, maxLength: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength))
    }
}
