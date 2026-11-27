import ArgumentParser
import Foundation
import OpenCloudKit
import Parser

enum ActionError: Error {
    case unsupported
}

extension ActionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "Unsupported action"
        }
    }
}

enum ArgumentError: Error {
    case noAuth
}

extension ArgumentError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .noAuth:
            return "No authentication method is provided"
        }
    }
}

@main
struct UploaderApp: AsyncParsableCommand {
    static let containerID = "iCloud.space.celestia.Celestia"
    static let environment = CKEnvironment.production

    @Argument
    var oldPath: String
    @Argument
    var newPath: String
    @Argument
    var mainKey: String
    @Argument
    var dataKey: String?

    @Option(help: "The key file path for CloudKit.")
    var keyFilePath: String?

    @Option(help: "The key ID for CloudKit.")
    var keyID: String?

    @Option(help: "The API token for CloudKit.")
    var apiToken: String?

    @Option
    var englishKey: String?

    @Option
    var keywordsKey: String?

    @Option(help: "JSON asset removal policies keyed by guide ID; applies to changed existing HTML records.")
    var assetRemovalPoliciesPath: String?

    func run() async throws {
        let parser = Parser()

        let config: CKContainerConfig
        if let keyID, let keyFilePath {
            let serverKeyAuth = try CKServerToServerKeyAuth(keyID: keyID, privateKeyFile: keyFilePath)
            config = CKContainerConfig(containerIdentifier: Self.containerID, environment: Self.environment, serverToServerKeyAuth: serverKeyAuth)
        } else if let apiToken {
            config = CKContainerConfig(containerIdentifier: Self.containerID, environment: Self.environment, apiTokenAuth: apiToken)
        } else {
            throw ArgumentError.noAuth
        }

        CloudKitHandler.configure(config)
        let handler = CloudKitHandler()

        try await withHTTPClient { httpClient in
            if let dataKey {
                let oldDataCollection = try parser.parseDataDirectory(at: oldPath)
                let newDataCollection = try parser.parseDataDirectory(at: newPath)
                let assetRemovalPolicies: [String: AssetRemovalPolicy]
                if let assetRemovalPoliciesPath {
                    let policyData = try Data(contentsOf: URL(fileURLWithPath: assetRemovalPoliciesPath))
                    assetRemovalPolicies = try JSONDecoder().decode([String: AssetRemovalPolicy].self, from: policyData)
                    for (guide, policy) in assetRemovalPolicies {
                        guard newDataCollection[guide] != nil else {
                            throw ActionError.unsupported
                        }
                        try policy.validate()
                    }
                } else {
                    assetRemovalPolicies = [:]
                }
                var dataById = [String: Data]()
                var policiesById = [String: AssetRemovalPolicy]()
                var dataToDuplicate = [(data: Data, targetId: String, language: String, reference: String, id: String)]()
                for (id, newData) in newDataCollection {
                    guard newData.new.isEmpty else {
                        throw ActionError.unsupported
                    }
                    guard let oldData = oldDataCollection[id] else {
                        throw ActionError.unsupported
                    }
                    guard oldData.new.isEmpty else {
                        throw ActionError.unsupported
                    }
                    for (language, dataWithId) in newData.existing {
                        if let oldDataWithId = oldData.existing[language] {
                            guard oldDataWithId.id == dataWithId.id else {
                                throw ActionError.unsupported
                            }
                            if dataWithId.data != oldDataWithId.data {
                                dataById[dataWithId.id] = dataWithId.data
                                if let policy = assetRemovalPolicies[id] {
                                    policiesById[dataWithId.id] = policy
                                }
                            }
                        } else {
                            dataToDuplicate.append((dataWithId.data, dataWithId.id, language, newData.reference, id))
                        }
                    }
                }
                if !dataById.isEmpty {
                    let ordinaryUpdates = dataById.filter { policiesById[$0.key] == nil }
                    if !ordinaryUpdates.isEmpty {
                        try await handler.uploadDataChanges(dataById: ordinaryUpdates, dataKey: dataKey)
                    }
                    let assetUpdates = dataById.filter { policiesById[$0.key] != nil }
                    if !assetUpdates.isEmpty {
                        try await handler.uploadDataChangesRemovingAssets(
                            dataById: assetUpdates, policiesById: policiesById,
                            dataKey: dataKey, httpClient: httpClient
                        )
                    }
                }
                if !dataToDuplicate.isEmpty {
                    try await handler.duplicateData(dataInformations: dataToDuplicate, mainKey: mainKey, dataKey: dataKey, httpClient: httpClient)
                }
            } else {
                guard assetRemovalPoliciesPath == nil else {
                    throw ActionError.unsupported
                }
                let oldStringsByLocales = try parser.parseDirectory(at: oldPath)
                let newStringsByLocales = try parser.parseDirectory(at: newPath)
                let oldStringsByKeys = try parser.convertToStringsByKeys(oldStringsByLocales)
                let newStringsByKeys = try parser.convertToStringsByKeys(newStringsByLocales)

                let addedOnes = newStringsByKeys.filter({ oldStringsByKeys[$0.key] == nil })
                let removedOnes = oldStringsByKeys.filter({ newStringsByKeys[$0.key] == nil })
                let changedOnes = newStringsByKeys.filter({ oldStringsByKeys[$0.key] != nil && oldStringsByKeys[$0.key] != $0.value })

                try await handler.uploadChanges(addedStrings: addedOnes, removedStrings: removedOnes, changedStrings: changedOnes, mainKey: mainKey, englishKey: englishKey, keywordsKey: keywordsKey)
            }
        }
    }
}
