import Foundation

public enum MeasurementSource: String, Sendable, Codable {
    case header
    case hardware
    case profile
    case estimated
    case sample

    public var displayName: String {
        switch self {
        case .header: "Cartridge header"
        case .hardware: "Hardware query"
        case .profile: "Cartridge profile"
        case .estimated: "Estimate"
        case .sample: "Sample data"
        }
    }
}

public struct MemoryMeasurement: Sendable, Equatable, Codable {
    public let bytes: Int
    public let source: MeasurementSource

    public init(bytes: Int, source: MeasurementSource) {
        self.bytes = bytes
        self.source = source
    }
}

public struct CartridgeSnapshot: Sendable, Equatable {
    public let title: String
    public let regions: [String]
    public let romSize: MemoryMeasurement?
    public let flashCapacity: MemoryMeasurement?
    public let rawSaveWindow: MemoryMeasurement?
    public let isDemo: Bool
    public let metadata: ROMMetadata?
    public let rawHeader: Data?
    public let geometry: FlashGeometry?
    public let saveLayout: SRAMLayout?
    public let identity: String
    public let fingerprint: String
    public let warning: String?
    public let profile: CartridgeProfile
    public var canWrite: Bool { !isDemo && geometry?.supported == true && (profile == .krikzz4M || profile == .linearROMOnly) }

    public init(
        title: String,
        regions: [String],
        romSize: MemoryMeasurement?,
        flashCapacity: MemoryMeasurement?,
        rawSaveWindow: MemoryMeasurement?,
        isDemo: Bool = false,
        metadata: ROMMetadata? = nil,
        geometry: FlashGeometry? = nil,
        saveLayout: SRAMLayout? = nil,
        identity: String = "",
        fingerprint: String = "",
        warning: String? = nil,
        profile: CartridgeProfile = .automatic,
        rawHeader: Data? = nil
    ) {
        self.title = title
        self.regions = regions
        self.romSize = romSize
        self.flashCapacity = flashCapacity
        self.rawSaveWindow = rawSaveWindow
        self.isDemo = isDemo
        self.rawHeader = rawHeader ?? metadata?.rawHeader
        self.metadata = metadata; self.geometry = geometry; self.saveLayout = saveLayout
        self.identity = identity; self.fingerprint = fingerprint; self.warning = warning; self.profile = profile
    }
}

public enum TransferDirection: String, CaseIterable, Identifiable, Sendable {
    case backup
    case write

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .backup: "Back up"
        case .write: "Write"
        }
    }
}

public enum TransferPhase: String, Sendable, Codable {
    case inspecting
    case readingROM
    case readingSRAM
    case erasing
    case programmingROM
    case restoringSRAM
    case verifying
    case completed
    case cancelled
    case failed
}
