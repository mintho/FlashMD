import Foundation

/// Content evidence, not proof of a game's required size. Never trims a backup by itself.
public struct ROMContentAnalysis: Sendable, Codable, Equatable {
    public let scannedBytes: Int
    public let headerBytes: Int?
    public let lastNonErasedByte: Int?
    public let trailingErasedBytes: Int
    public let nonErasedBytesBeyondHeader: Int?
    public let possibleMirrorBytes: Int?
    public let suggestedBytes: Int?
    public let sha256: String

    public var explanation: String {
        guard suggestedBytes != nil else { return "Only FF bytes were read. No game size can be suggested." }
        if possibleMirrorBytes != nil {
            return "Repeated ROM blocks were found. They may be intentional or mirrored by the board; the suggestion keeps them."
        }
        if let count = nonErasedBytesBeyondHeader, count > 0 {
            return "Data exists beyond the header's ROM size. It may belong to this game or an earlier flash; the suggestion keeps it."
        }
        if trailingErasedBytes > 0 {
            return "The end of the ROM contains FF bytes. The suggestion keeps the header range and rounds additional data up to 128 KiB."
        }
        return "No erased end area was found. The suggestion keeps the complete accessible ROM range."
    }

    public static func analyze(_ input: Data, headerBytes: Int?) throws -> ROMContentAnalysis {
        let data = Data(input)
        guard data.count >= 512, data.count <= 0x400000 else {
            throw FlashMDError.invalid("Content analysis requires a ROM range between 512 bytes and 4 MiB.")
        }
        let last = data.lastIndex { $0 != 0xFF }
        let usedEnd = last.map { $0 + 1 } ?? 0
        let validHeader = headerBytes.flatMap { (512...data.count).contains($0) && $0.isMultiple(of:2) ? $0 : nil }
        let beyond = validHeader.map { size in data[size...].reduce(0) { $0 + ($1 == 0xFF ? 0 : 1) } }
        var mirror: Int?
        var period = data.count
        while period.isMultiple(of:2), period / 2 >= 0x20000 {
            let half = period / 2
            guard data.prefix(half).elementsEqual(data[half..<period]) else { break }
            mirror = half; period = half
        }
        let suggestion: Int?
        if last == nil { suggestion = nil }
        else if let validHeader, usedEnd <= validHeader { suggestion = validHeader }
        else { suggestion = min(data.count, max(512, ((usedEnd + 0x1FFFF) / 0x20000) * 0x20000)) }
        return .init(scannedBytes:data.count,headerBytes:headerBytes,lastNonErasedByte:last,
            trailingErasedBytes:data.count-usedEnd,nonErasedBytesBeyondHeader:beyond,
            possibleMirrorBytes:mirror,suggestedBytes:suggestion,sha256:hash(data))
    }

    public static func read(device: any CartridgeDevice, cartridge: CartridgeSnapshot,
                            progress: ProgressHandler) throws -> ROMContentAnalysis {
        let fresh = try device.inspect(profile:cartridge.profile).applying(cartridge.configurationOverride)
        guard fresh == cartridge else { throw FlashMDError.invalid("The cartridge changed before content analysis. Scan again.") }
        var data = Data()
        for offset in stride(from:0,to:cartridge.romReadLimit,by:32768) {
            try Task.checkCancellation()
            let length = min(32768,cartridge.romReadLimit-offset)
            let block = try device.readROM(offset:offset,count:length)
            guard block.count == length else { throw FlashMDError.invalid("The programmer returned a short read during content analysis.") }
            data.append(block)
            progress(.init(.readingROM,offset+length,cartridge.romReadLimit,detail:"Analyzing ROM contents"))
        }
        let after = try device.inspect(profile:cartridge.profile).applying(cartridge.configurationOverride)
        guard after == cartridge, hash(Data(data.prefix(512))) == cartridge.fingerprint else {
            throw FlashMDError.invalid("The cartridge changed during content analysis. Scan again.")
        }
        return try analyze(data,headerBytes:cartridge.romSize?.bytes)
    }
}
