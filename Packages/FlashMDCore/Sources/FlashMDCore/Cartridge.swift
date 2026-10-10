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
    /// Conservative programming capacity; automatic reads use the separate scan range.
    public static func inferredCapacity(geometry: FlashGeometry, saveLayout: SRAMLayout?) -> MemoryMeasurement {
        let bytes = min(geometry.capacity,0x400000,saveLayout?.base ?? 0x400000)
        return .init(bytes:bytes,source:bytes == geometry.capacity ? .hardware : .estimated)
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
    public let serialSave: SerialSaveConfiguration?
    public let identity: String
    public let fingerprint: String
    public let warning: String?
    public let profile: CartridgeProfile
    public let configurationOverride: CartridgeConfiguration?
    public let mapper: ROMMapper
    public let mapperSelection: ROMMapper
    public let romAccess: ROMAccess
    public let mappedROMBytes: Int?
    /// Read-only scan range. A header's save address is not proof that ROM ends there.
    public let linearROMReadBytes: Int?
    public let mapperMessage: String?
    public let readerKind: ProgrammerKind
    public let saveWriteSupported: Bool
    public let saveStatus: SaveMemoryStatus
    /// Scan evidence survives a manual configuration that hides save controls.
    public let detectedSaveStatus: SaveMemoryStatus
    public var canBackupSave: Bool {
        if serialSave != nil { return serialSave == .pierSolar && saveLayout == nil && mapper == .pierSolar && romAccess == .banked && saveStatus == .readOnly && !isDemo }
        return saveLayout != nil && (saveStatus == .confirmed || saveStatus == .readOnly || saveStatus == .manual)
    }
    public var canBackupROM: Bool { romAccess != .unavailable }
    public var canWrite: Bool { mapper == .linear && romAccess == .linear && !isDemo && geometry?.supported == true && flashCapacity != nil }
    public var romReadLimit: Int { mappedROMBytes ?? linearROMReadBytes ?? flashCapacity?.bytes ?? 0x400000 }
    /// Programming capacity is independent of the wider read-only scan range.
    /// WritePlan also rejects erase/program ranges that overlap configured SRAM.
    public var hasExplicitROMOnlyConfiguration: Bool {
        (configurationOverride.map { $0.saveLayout == nil } ?? (profile == .linearROMOnly)) &&
        detectedSaveStatus != .confirmed && detectedSaveStatus != .readOnly && metadata?.saveWarning == nil
    }
    /// A ROM-only override explicitly describes the board, rather than the
    /// previous game's header. Ordinary automatic scans retain the save boundary.
    public var romWriteAddressLimit: Int {
        min(romReadLimit,flashCapacity?.bytes ?? 0x400000,saveLayout?.base ?? 0x400000,
            hasExplicitROMOnlyConfiguration ? 0x400000 : metadata?.saveLayout?.base ?? 0x400000)
    }
    public var romWriteLimit: Int { flashCapacity == nil ? 0 : romWriteAddressLimit }
    public var canRestoreSave: Bool { serialSave == nil && mapper == .linear && romAccess == .linear && !isDemo && saveStatus == .confirmed && saveLayout != nil && saveLayout?.lane != 0 && saveWriteSupported }
    /// Permanently mapped SRAM needs an active check inside the approved write
    /// flow. This never authorizes direct backend writes or scan-time probing.
    public var canCheckSaveWriting: Bool {
        guard readerKind == .flashKit, mapper == .linear, romAccess == .linear, !isDemo,
              saveStatus == .readOnly, geometry?.supported == true,
              let layout = saveLayout, layout == metadata?.saveLayout,
              metadata?.saveWarning == nil, layout.base == 0x200000, layout.lane == 1,
              (64...65536).contains(layout.windowBytes),
              let declared = metadata?.declaredROMBytes, declared <= layout.base else { return false }
        return true
    }
    public var canStartSaveWrite: Bool { canRestoreSave || canCheckSaveWriting }

    public var canConfirmNoSRAMForROMWriting: Bool {
        !isDemo && serialSave == nil && mapper == .linear && romAccess == .linear &&
        metadata?.saveLayout != nil && metadata?.saveWarning == nil && saveLayout != nil &&
        [.declared, .unconfirmed, .manual].contains(saveStatus) &&
        detectedSaveStatus != .confirmed && detectedSaveStatus != .readOnly
    }

    public func romOnlyConfigurationForWriting() throws -> CartridgeConfiguration {
        guard canConfirmNoSRAMForROMWriting else {
            throw FlashMDError.invalid("The SRAM configuration changed. Scan again before writing.")
        }
        return try .init(romCapacity:min(romReadLimit,geometry?.capacity ?? 0x400000,0x400000),saveLayout:nil)
    }

    /// Run before chip identification as well as when constructing the write plan.
    /// An old game's SRAM declaration must not silently disable save protection.
    public func validateROMWriteSaveProtection() throws {
        if metadata?.saveWarning != nil {
            throw FlashMDError.invalid("This cartridge declares an unsupported save type. ROM writing could erase its saves.")
        }
        if saveLayout == nil, metadata?.saveLayout != nil,
           detectedSaveStatus == .confirmed || detectedSaveStatus == .readOnly {
            throw FlashMDError.invalid("Save memory was detected. Keep SRAM enabled to preserve the cartridge’s saves.")
        }
        if saveLayout != nil, saveStatus != .confirmed, !canCheckSaveWriting {
            throw FlashMDError.invalid("The current game declares SRAM, but it could not be confirmed. If this cartridge has no SRAM, choose “4 MiB ROM only” in Advanced Settings, then scan again.")
        }
    }

    public func applying(_ override: CartridgeConfiguration?) -> CartridgeSnapshot {
        guard let override, mapper == .linear, romAccess == .linear else { return self }
        let layout = readerKind == .mdDumper && override.saveLayout?.lane != 1 ? nil : override.saveLayout
        let configurationWarning = readerKind == .mdDumper && override.saveLayout != nil && layout == nil
            ? "This reader supports odd-lane SRAM only. Choose odd lane in Advanced Settings." : warning
        let capacity = MemoryMeasurement(bytes:min(override.romCapacity,geometry?.capacity ?? 0x400000),source:.profile)
        let configuredSaveStatus: SaveMemoryStatus
        if layout == nil { configuredSaveStatus = .none }
        else if layout == saveLayout && saveStatus == .confirmed { configuredSaveStatus = .confirmed }
        else { configuredSaveStatus = .manual }
        return .init(title:title,regions:regions,romSize:romSize,flashCapacity:capacity,
            rawSaveWindow:layout.map { .init(bytes:$0.windowBytes,source:.profile) },isDemo:isDemo,
            metadata:metadata,geometry:geometry,saveLayout:layout,serialSave:serialSave,identity:identity,fingerprint:fingerprint,
            warning:configurationWarning,profile:profile,rawHeader:rawHeader,configurationOverride:override,mapper:mapper,mapperSelection:mapperSelection,romAccess:romAccess,mappedROMBytes:mappedROMBytes,mapperMessage:mapperMessage,readerKind:readerKind,saveWriteSupported:saveWriteSupported,linearROMReadBytes:capacity.bytes,saveStatus:configuredSaveStatus,detectedSaveStatus:detectedSaveStatus)
    }
    func withSaveStatus(_ status: SaveMemoryStatus) -> CartridgeSnapshot {
        .init(title:title,regions:regions,romSize:romSize,flashCapacity:flashCapacity,rawSaveWindow:rawSaveWindow,
            isDemo:isDemo,metadata:metadata,geometry:geometry,saveLayout:saveLayout,serialSave:serialSave,identity:identity,fingerprint:fingerprint,
            warning:warning,profile:profile,rawHeader:rawHeader,configurationOverride:configurationOverride,
            mapper:mapper,mapperSelection:mapperSelection,romAccess:romAccess,mappedROMBytes:mappedROMBytes,
            mapperMessage:mapperMessage,readerKind:readerKind,
            saveWriteSupported:readerKind == .mdDumper ? status == .confirmed && saveLayout?.activeBytes.isMultiple(of:32) == true : saveWriteSupported,
            linearROMReadBytes:linearROMReadBytes,saveStatus:status,detectedSaveStatus:status == .confirmed || status == .readOnly ? status : detectedSaveStatus)
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
        serialSave: SerialSaveConfiguration? = nil,
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
        saveWriteSupported: Bool = true,
        linearROMReadBytes: Int? = nil,
        saveStatus: SaveMemoryStatus? = nil,
        detectedSaveStatus: SaveMemoryStatus? = nil
    ) {
        self.readerKind = readerKind; self.saveWriteSupported = saveWriteSupported
        self.saveStatus = saveStatus ?? (metadata?.saveWarning != nil ? .unsupported : saveLayout != nil || metadata?.saveLayout != nil ? .declared : .none)
        self.detectedSaveStatus = detectedSaveStatus ?? self.saveStatus
        self.mapper = mapper; self.mapperSelection = mapperSelection; self.romAccess = romAccess
        self.mappedROMBytes = mappedROMBytes; self.mapperMessage = mapperMessage
        self.linearROMReadBytes = linearROMReadBytes
        self.configurationOverride = configurationOverride
        self.title = title
        self.regions = regions
        self.romSize = romSize
        self.flashCapacity = flashCapacity
        self.rawSaveWindow = rawSaveWindow
        self.isDemo = isDemo
        self.rawHeader = rawHeader ?? metadata?.rawHeader
        self.metadata = metadata; self.geometry = geometry; self.saveLayout = saveLayout; self.serialSave = serialSave
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
