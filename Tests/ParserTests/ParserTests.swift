import Foundation
@testable import Parser
import OpenCloudKit
import XCTest

final class ParserTests: XCTestCase {
    private let parser = Parser()
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    func testFirstUploadWithEmptyEnglishBaseline() throws {
        let oldPath = directory.appendingPathComponent("old")
        try writeFile("", locale: "en", at: oldPath)
        let oldStrings = try parser.convertToStringsByKeys(parser.parseDirectory(at: oldPath.path))
        XCTAssertTrue(oldStrings.isEmpty)

        let newPath = directory.appendingPathComponent("new")
        let expected = ["record-id": ["en": "Title", "bg": "Localized title"]]
        try parser.writeStrings(parser.convertToStringsByLocales(expected), to: newPath.path)
        let newStrings = try parser.convertToStringsByKeys(parser.parseDirectory(at: newPath.path))
        XCTAssertEqual(newStrings.filter { oldStrings[$0.key] == nil }, expected)
    }

    func testEmptySynchronizationRoundTrip() throws {
        let locales = try parser.convertToStringsByLocales([:])
        try parser.writeStrings(locales, to: directory.path)
        let parsedLocales = try parser.parseDirectory(at: directory.path)
        XCTAssertEqual(parsedLocales, ["en": [:]])
        XCTAssertTrue(try parser.convertToStringsByKeys(parsedLocales).isEmpty)
    }

    func testWhitespaceOnlyFileAndMalformedFile() throws {
        try writeFile(" \n\t", locale: "en", at: directory)
        XCTAssertTrue(try parser.parseFile(at: directory.appendingPathComponent("en.lproj").path).isEmpty)
        try writeFile("\"record-id\" = \"unterminated", locale: "en", at: directory)
        XCTAssertThrowsError(try parser.parseDirectory(at: directory.path))
    }

    func testMissingEnglishStillFails() throws {
        XCTAssertThrowsError(try parser.convertToStringsByLocales(["record-id": ["bg": "Title"]]))
        try writeFile("\"record-id\" = \"Title\";", locale: "bg", at: directory)
        XCTAssertThrowsError(try parser.parseDirectory(at: directory.path))
    }

    func testNewHTMLLocaleUsesEnglishRecordAsTemplate() throws {
        let guide = directory.appendingPathComponent("guide-id")
        for (locale, id) in [("ru", "russian-record"), ("en", "english-record"), ("ja", "japanese-record")] {
            let path = guide.appendingPathComponent(locale)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try id.write(to: path.appendingPathComponent("id.txt"), atomically: true, encoding: .utf8)
            try "<p>\(locale)</p>".write(to: path.appendingPathComponent("data.html"), atomically: true, encoding: .utf8)
        }
        let parsed = try parser.parseDataDirectory(at: directory.path)
        XCTAssertEqual(parsed["guide-id"]?.reference, "ENGLISH-RECORD")
        XCTAssertEqual(parsed["guide-id"]?.existing["ja"]?.id, "JAPANESE-RECORD")
        XCTAssertEqual(parsed["guide-id"]?.existing["ja"]?.data, Data("<p>ja</p>".utf8))
    }

    func testLocalizedHTMLCopiesEnglishAssetNamesOrderAndBytes() async throws {
        let source = CKRecord(recordType: "HTMLResource", recordID: CKRecord.ID(recordName: "english-record"))
        let urls = [
            URL(string: "https://assets.example/first.svg")!,
            URL(string: "https://assets.example/second.jpg")!,
        ]
        let bytes = [Data("<svg>first</svg>".utf8), Data([0, 1, 2, 255])]
        source["assetNames"] = ["first.svg", "second.jpg"]
        source["assets"] = urls.map { CKAsset(fileURL: $0) }
        source["cover"] = CKAsset(fileURL: urls[0])
        source["data"] = Data("English".utf8)
        source["enabled"] = true
        let localized = Data("<p>日本語</p>".utf8)
        let clone = try await CloudKitHandler().makeLocalizedRecord(
            from: source, targetId: "japanese-record", dataKey: "data",
            data: localized, assetDirectory: directory
        ) { url in
            guard let index = urls.firstIndex(of: url) else { throw URLError(.badURL) }
            return bytes[index]
        }
        XCTAssertEqual(clone.recordType, source.recordType)
        XCTAssertEqual(clone.recordID.recordName, "japanese-record")
        XCTAssertEqual(clone["assetNames"] as? [String], ["first.svg", "second.jpg"])
        XCTAssertEqual(clone["data"] as? Data, localized)
        XCTAssertEqual(clone["enabled"] as? Bool, true)
        let assets = try XCTUnwrap(clone["assets"] as? [CKAsset])
        XCTAssertEqual(assets.count, bytes.count)
        for (index, asset) in assets.enumerated() {
            XCTAssertTrue(asset.fileURL.isFileURL)
            XCTAssertEqual(try Data(contentsOf: asset.fileURL), bytes[index])
        }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(clone["cover"] as? CKAsset).fileURL), bytes[0])
        XCTAssertEqual(source["data"] as? Data, Data("English".utf8))
        XCTAssertEqual((source["assets"] as? [CKAsset])?.map(\.fileURL), urls)
    }

    func testLocalizedHTMLPreservesEmptyAssetAndStringLists() async throws {
        let source = CKRecord(recordType: "HTMLResource")
        source["assetNames"] = [String]()
        source["assets"] = [CKAsset]()
        source["data"] = Data("English".utf8)
        let clone = try await CloudKitHandler().makeLocalizedRecord(
            from: source, targetId: "localized-record", dataKey: "data",
            data: Data("Localized".utf8), assetDirectory: directory
        ) { _ in
            XCTFail("Empty asset lists must not download anything")
            throw URLError(.badURL)
        }
        XCTAssertEqual(clone["assetNames"]?.recordFieldDictionary["type"] as? String, "STRING_LIST")
        XCTAssertEqual(clone["assets"]?.recordFieldDictionary["type"] as? String, "ASSETID_LIST")
    }

    func testLocalizedHTMLPropagatesAssetDownloadFailure() async throws {
        let source = CKRecord(recordType: "HTMLResource")
        source["assets"] = [CKAsset(fileURL: URL(string: "https://assets.example/missing.jpg")!)]
        do {
            _ = try await CloudKitHandler().makeLocalizedRecord(
                from: source, targetId: "localized-record", dataKey: "data",
                data: Data("Localized".utf8), assetDirectory: directory
            ) { _ in throw URLError(.cannotLoadFromNetwork) }
            XCTFail("A failed asset download must abort record creation")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cannotLoadFromNetwork)
        }
    }

    private func writeFile(_ contents: String, locale: String, at path: URL) throws {
        let localePath = path.appendingPathComponent("\(locale).lproj")
        try FileManager.default.createDirectory(at: localePath, withIntermediateDirectories: true)
        try contents.write(to: localePath.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
    }
}
