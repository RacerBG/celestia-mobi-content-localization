import AsyncRequest
import Foundation
import OpenCloudKit

public struct AssetRemovalPolicy: Decodable, Sendable {
    public let assetNamesToRemove: [String]
    public let expectedRemainingAssetCount: Int

    public init(assetNamesToRemove: [String], expectedRemainingAssetCount: Int) {
        self.assetNamesToRemove = assetNamesToRemove
        self.expectedRemainingAssetCount = expectedRemainingAssetCount
    }

    public func validate() throws {
        guard !assetNamesToRemove.isEmpty,
              assetNamesToRemove.allSatisfy({ !$0.isEmpty }),
              Set(assetNamesToRemove).count == assetNamesToRemove.count,
              expectedRemainingAssetCount > 0 else {
            throw AssetRemovalError.invalidPolicy
        }
    }
}

enum AssetRemovalError: Error, LocalizedError {
    case invalidPolicy
    case assetListMismatch
    case invalidPlaceholder

    var errorDescription: String? {
        switch self {
        case .invalidPolicy:
            return "Invalid asset removal policy"
        case .assetListMismatch:
            return "Asset names or counts do not match the removal policy"
        case .invalidPlaceholder:
            return "HTML references an asset outside the remaining asset list"
        }
    }
}

extension CloudKitHandler {
    func prepareAssetRemoval(
        record: CKRecord, dataKey: String, data: Data, policy: AssetRemovalPolicy,
        assetDirectory: URL, loadAsset: (URL) async throws -> Data
    ) async throws {
        try policy.validate()
        guard let names = record["assetNames"] as? [String],
              let assets = record["assets"] as? [CKAsset],
              names.count == assets.count else {
            throw AssetRemovalError.assetListMismatch
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw CloudKitHandlerError.stringConversion
        }
        let expression = try NSRegularExpression(pattern: #"\{(\d+)\}"#)
        for match in expression.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range(at: 1), in: html),
                  let index = Int(html[range]),
                  index < policy.expectedRemainingAssetCount else {
                throw AssetRemovalError.invalidPlaceholder
            }
        }

        let removedNames = Set(policy.assetNamesToRemove)
        let removedIndices = names.indices.filter { removedNames.contains(names[$0]) }
        if removedIndices.isEmpty {
            guard assets.count == policy.expectedRemainingAssetCount else {
                throw AssetRemovalError.assetListMismatch
            }
            record[dataKey] = data
            return
        }
        guard Set(removedIndices.map { names[$0] }) == removedNames,
              removedIndices.count == removedNames.count,
              assets.count - removedIndices.count == policy.expectedRemainingAssetCount else {
            throw AssetRemovalError.assetListMismatch
        }

        try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
        var remainingAssets = [CKAsset]()
        var remainingNames = [String]()
        for index in names.indices where !removedNames.contains(names[index]) {
            let bytes = try await loadAsset(assets[index].fileURL)
            let file = assetDirectory.appendingPathComponent(UUID().uuidString)
            try bytes.write(to: file)
            remainingAssets.append(CKAsset(fileURL: file))
            remainingNames.append(names[index])
        }
        record["assets"] = remainingAssets
        record["assetNames"] = remainingNames
        record[dataKey] = data
    }

    public func uploadDataChangesRemovingAssets(
        dataById: [String: Data], policiesById: [String: AssetRemovalPolicy],
        dataKey: String, httpClient: any RequestClient
    ) async throws {
        guard Set(dataById.keys) == Set(policiesById.keys) else {
            throw AssetRemovalError.invalidPolicy
        }
        let database = CKContainer.default().publicCloudDatabase
        let identifiers = dataById.keys.map { CKRecord.ID(recordName: $0) }
        let results = try await database.records(for: identifiers, desiredKeys: [dataKey, "assets", "assetNames"])
        guard results.count == identifiers.count else {
            throw CloudKitHandlerError.dataMissing
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            if FileManager.default.fileExists(atPath: directory.path) {
                do {
                    try FileManager.default.removeItem(at: directory)
                } catch {
                    print("Failed to clean up asset removal uploads: \(error.localizedDescription)")
                }
            }
        }
        var records = [CKRecord]()
        for (identifier, result) in results {
            let record = try result.get()
            guard let data = dataById[identifier.recordName],
                  let policy = policiesById[identifier.recordName] else {
                throw CloudKitHandlerError.dataMissing
            }
            try await prepareAssetRemoval(
                record: record, dataKey: dataKey, data: data, policy: policy,
                assetDirectory: directory
            ) { url in
                try await AsyncDataRequestHandler.get(url: url.absoluteString, httpClient: httpClient)
            }
            records.append(record)
        }
        print("Saving HTML, remaining assets and asset names together...")
        let saved = try await database.modifyRecords(saving: records, deleting: [], savePolicy: .changedKeys).saveResults
        guard saved.count == records.count else {
            throw CloudKitHandlerError.dataMissing
        }
        for result in saved.values {
            _ = try result.get()
        }
    }
}
