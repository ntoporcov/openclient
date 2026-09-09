import Foundation
import XCTest

final class LocalizationCatalogTests: XCTestCase {
    private let requiredLanguages = ["pt-BR", "it"]
    private let catalogPaths = [
        "OpenCodeIOSClient/Localizable.xcstrings",
        "OpenCodeIOSClient/AppShortcuts.xcstrings",
        "OpenCodeIOSClient/InfoPlist.xcstrings",
        "OpenCodeChatActivityExtension/Localizable.xcstrings",
        "OpenCodeChatActivityExtension/InfoPlist.xcstrings",
        "OpenCodeShareExtension/Localizable.xcstrings",
        "OpenCodeShareExtension/InfoPlist.xcstrings",
    ]

    func testRequiredLanguageCatalogsAreComplete() throws {
        for path in catalogPaths {
            let strings = try catalogStrings(at: path)
            XCTAssertFalse(strings.isEmpty, "Expected localization entries in \(path)")

            for (key, value) in strings {
                let entry = try XCTUnwrap(value as? [String: Any], "Invalid entry for \(key) in \(path)")
                let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], "Missing localizations for \(key) in \(path)")
                for language in requiredLanguages {
                    let localization = try XCTUnwrap(
                        localizations[language] as? [String: Any],
                        "Missing \(language) translation for \(key) in \(path)"
                    )
                    XCTAssertTrue(isTranslated(localization), "Incomplete \(language) translation for \(key) in \(path)")
                }
            }
        }
    }

    func testRequiredLanguageTranslationsPreservePlaceholders() throws {
        for path in catalogPaths {
            let strings = try catalogStrings(at: path)

            for (key, value) in strings {
                let entry = try XCTUnwrap(value as? [String: Any])
                let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
                let english = localizations["en"] as? [String: Any]
                let sourceValues = localizedValues(english, fallback: key)

                for language in requiredLanguages {
                    let localization = try XCTUnwrap(localizations[language] as? [String: Any])
                    let translatedValues = localizedValues(localization, fallback: key)

                    XCTAssertEqual(sourceValues.count, translatedValues.count, "Value count differs for \(key) in \(path) [\(language)]")
                    for (source, translation) in zip(sourceValues, translatedValues) {
                        XCTAssertEqual(
                            placeholders(in: source),
                            placeholders(in: translation),
                            "Placeholders differ for \(key) in \(path) [\(language)]"
                        )
                    }
                }
            }
        }
    }

    func testTranslationValidationHandlesVariations() {
        let translated: [String: Any] = ["stringUnit": ["state": "translated", "value": "%lld form"]]
        let incomplete: [String: Any] = ["stringUnit": ["state": "needs_review", "value": "%lld forms"]]
        XCTAssertTrue(isTranslated(translated))
        XCTAssertTrue(isTranslated(["stringSet": ["state": "translated", "values": ["A", "B"]]]))
        XCTAssertTrue(isTranslated(["variations": ["plural": ["one": translated, "other": translated]]]))
        XCTAssertFalse(isTranslated(["variations": ["plural": ["one": translated, "other": incomplete]]]))
        XCTAssertFalse(isTranslated(["variations": ["plural": ["one": translated, "other": [:]]]]))
        XCTAssertFalse(isTranslated(["variations": ["plural": [:]]]))
        XCTAssertFalse(isTranslated(["variations": [:]]))
        XCTAssertFalse(isTranslated([:]))

        let nested: [String: Any] = ["variations": ["device": ["other": [
            "variations": ["plural": [
                "one": translated,
                "other": ["stringUnit": ["state": "translated", "value": "%@ forms"]],
            ]],
        ]]]]
        XCTAssertTrue(isTranslated(nested))
        let values = localizedValues(nested, fallback: "fallback")
        XCTAssertEqual(values, ["%lld form", "%@ forms"])
        XCTAssertEqual(values.map { placeholders(in: $0) }, [["%lld"], ["%@"]])
    }

    func testPendingFormsPreservesIntegerPlurals() throws {
        let strings = try catalogStrings(at: "OpenCodeIOSClient/Localizable.xcstrings")
        let entry = try XCTUnwrap(strings["%lld pending forms"] as? [String: Any])
        let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
        for language in ["en"] + requiredLanguages {
            let localization = try XCTUnwrap(localizations[language] as? [String: Any])
            XCTAssertTrue(isTranslated(localization), "Incomplete pending forms translation for \(language)")
            let variations = try XCTUnwrap(localization["variations"] as? [String: Any])
            let plurals = try XCTUnwrap(variations["plural"] as? [String: Any])
            XCTAssertNotNil(plurals["one"], "Missing singular for \(language)")
            XCTAssertNotNil(plurals["other"], "Missing plural for \(language)")
            let values = localizedValues(localization, fallback: "")
            XCTAssertGreaterThanOrEqual(Set(values).count, 2, "Expected distinct singular and plural for \(language)")
            for value in values {
                XCTAssertEqual(placeholders(in: value), ["%lld"], "Expected integer count for \(language)")
            }
        }
    }

    func testMainAppEnablesMultipleScenes() throws {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(
            contentsOf: repositoryURL.appendingPathComponent("OpenCodeIOSClient/Generated-Info.plist")
        )
        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let sceneManifest = try XCTUnwrap(info["UIApplicationSceneManifest"] as? [String: Any])

        XCTAssertEqual(sceneManifest["UIApplicationSupportsMultipleScenes"] as? Bool, true)
    }

    private func catalogStrings(at path: String) throws -> [String: Any] {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: repositoryURL.appendingPathComponent(path))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["strings"] as? [String: Any])
    }

    private func isTranslated(_ localization: [String: Any]) -> Bool {
        if let stringUnit = localization["stringUnit"] as? [String: Any] {
            return stringUnit["state"] as? String == "translated"
        }
        if let stringSet = localization["stringSet"] as? [String: Any] {
            return stringSet["state"] as? String == "translated"
        }
        if let variations = localization["variations"] as? [String: [String: [String: Any]]], !variations.isEmpty {
            return variations.values.allSatisfy { branches in
                !branches.isEmpty && branches.values.allSatisfy { isTranslated($0) }
            }
        }
        return false
    }

    private func localizedValues(_ localization: [String: Any]?, fallback: String) -> [String] {
        if let stringUnit = localization?["stringUnit"] as? [String: Any],
           let value = stringUnit["value"] as? String {
            return [value]
        }
        if let stringSet = localization?["stringSet"] as? [String: Any],
           let values = stringSet["values"] as? [String] {
            return values
        }
        if let variations = localization?["variations"] as? [String: [String: [String: Any]]] {
            // Match source and translation branches deterministically, not by dictionary iteration order.
            return variations.keys.sorted().flatMap { dimension in
                let branches = variations[dimension] ?? [:]
                return branches.keys.sorted().flatMap { localizedValues(branches[$0], fallback: fallback) }
            }
        }
        return [fallback]
    }

    private func placeholders(in value: String) -> [String] {
        let pattern = #"%(?:\d+\$)?(?:lld|ld|lf|d|f|@|%)|\$\{applicationName\}"#
        let expression = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: value) else { return nil }
            return String(value[matchRange]).replacingOccurrences(
                of: #"^%\d+\$"#,
                with: "%",
                options: .regularExpression
            )
        }.sorted()
    }
}
