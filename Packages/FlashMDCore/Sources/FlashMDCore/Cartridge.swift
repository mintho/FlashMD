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

/// A linear address mapping. Flash geometry is queried separately and cannot be overridden.
public struct CartridgeConfiguration: Codable, Sendable, Equatable {
    public let romCapacity: Int
    public let saveLayout: SRAMLayout?
    public static func inferredCapacity(geometry: FlashGeometry, saveLayout: SRAMLayout?) -> MemoryMeasurement {
        .init(bytes:min(geometry.capacity,0x400000,saveLayout?.base ?? 0x400000),source:.estimated)
    }
    public init(romCapacity: Int, saveLayout: SRAMLayout?) throws {
        guard (512...0x400000).contains(romCapacity) else {
            throw FlashMDError.invalid("Accessible ROM capacity must be between 512 bytes and 4 MiB. Use the mapper setting for banked games.")
        }
        self.romCapacity = romCapacity; self.saveLayout = saveLayout
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
    public let configurationOverride: CartridgeConfiguration?
    public let mapper: ROMMapper
    public let mapperSelection: ROMMapper
    public let romAccess: ROMAccess
    public let mappedROMBytes: Int?
    public let mapperMessage: String?
    public let readerKind: ProgrammerKind
    public let saveWriteSupported: Bool
    public var canBackupROM: Bool { romAccess != .unavailable }
    public var canWrite: Bool { mapper == .linear && romAccess == .linear && !isDemo && geometry?.supported == true && flashCapacity != nil }
    public var romReadLimit: Int { mappedROMBytes ?? flashCapacity?.bytes ?? min(0x400000,saveLayout?.base ?? 0x400000) }
    public var canRestoreSave: Bool { mapper == .linear && romAccess == .linear && !isDemo && saveLayout != nil && saveLayout?.lane != 0 && saveWriteSupported }

    public func applying(_ override: CartridgeConfiguration?) -> CartridgeSnapshot {
        guard let override, mapper == .linear, romAccess == .linear else { return self }
        let layout = readerKind == .mdDumper && override.saveLayout?.lane != 1 ? nil : override.saveLayout
        let configurationWarning = readerKind == .mdDumper && override.saveLayout != nil && layout == nil
            ? "This reader supports odd-lane SRAM only. Choose odd lane in Advanced Settings." : warning
        let capacity = MemoryMeasurement(bytes:min(override.romCapacity,geometry?.capacity ?? 0x400000),source:.profile)
        return .init(title:title,regions:regions,romSize:romSize,flashCapacity:capacity,
            rawSaveWindow:layout.map { .init(bytes:$0.windowBytes,source:.profile) },isDemo:isDemo,
            metadata:metadata,geometry:geometry,saveLayout:layout,identity:identity,fingerprint:fingerprint,
            warning:configurationWarning,profile:profile,rawHeader:rawHeader,configurationOverride:override,mapper:mapper,mapperSelection:mapperSelection,romAccess:romAccess,mappedROMBytes:mappedROMBytes,mapperMessage:mapperMessage,readerKind:readerKind,saveWriteSupported:readerKind == .mdDumper ? layout?.activeBytes.isMultiple(of:32) == true : saveWriteSupported)
    }

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
        rawHeader: Data? = nil,
        configurationOverride: CartridgeConfiguration? = nil,
        mapper: ROMMapper = .linear,
        mapperSelection: ROMMapper = .automatic,
        romAccess: ROMAccess = .linear,
        mappedROMBytes: Int? = nil,
        mapperMessage: String? = nil,
        readerKind: ProgrammerKind = .flashKit,
        saveWriteSupported: Bool = true
    ) {
        self.readerKind = readerKind; self.saveWriteSupported = saveWriteSupported
        self.mapper = mapper; self.mapperSelection = mapperSelection; self.romAccess = romAccess
        self.mappedROMBytes = mappedROMBytes; self.mapperMessage = mapperMessage
        self.configurationOverride = configurationOverride
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
