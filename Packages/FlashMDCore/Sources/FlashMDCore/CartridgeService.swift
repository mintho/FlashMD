import Foundation

public protocol CartridgeService: Sendable {
    func inspect() async throws -> CartridgeSnapshot
}

public enum CartridgeServiceError: LocalizedError, Sendable, Equatable {
    case transportUnavailable

    public var errorDescription: String? {
        "Device connection is not available in this build."
    }
}

public actor DisconnectedCartridgeService: CartridgeService {
    public init() {}

    public func inspect() async throws -> CartridgeSnapshot {
        throw CartridgeServiceError.transportUnavailable
    }
}

public actor DemoCartridgeService: CartridgeService {
    public init() {}

    public func inspect() async throws -> CartridgeSnapshot {
        CartridgeSnapshot(
            title: "Ragnacenty",
            regions: ["Japan", "USA", "Europe"],
            romSize: .init(bytes: 2_097_152, source: .sample),
            flashCapacity: .init(bytes: 2_097_152, source: .sample),
            rawSaveWindow: .init(bytes: 65_536, source: .sample),
            isDemo: true
        )
    }
}
