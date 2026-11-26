import Foundation
import Parser
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

    private func writeFile(_ contents: String, locale: String, at path: URL) throws {
        let localePath = path.appendingPathComponent("\(locale).lproj")
        try FileManager.default.createDirectory(at: localePath, withIntermediateDirectories: true)
        try contents.write(to: localePath.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
    }
}
