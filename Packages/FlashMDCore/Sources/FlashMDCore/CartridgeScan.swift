import Foundation

/// Bounded evidence from a failed read-only scan; never used to repair ROM data.
public struct ROMScanMismatch: LocalizedError, Codable, Sendable {
    public let blockOffset: Int
    public let bytes: Int
    public let firstSHA256: String
    public let secondSHA256: String
    public let differences: [ReadDifference]
    init(first: Data, second: Data, offset: Int) {
        blockOffset = offset; bytes = first.count
        firstSHA256 = hash(first); secondSHA256 = hash(second)
        differences = first.indices.lazy.filter { first[$0] != second[$0] }.prefix(16).map {
            ReadDifference(memory:"ROM",offset:offset+$0,expected:first[$0],actual:second[$0])
        }
    }
    public var errorDescription: String? {
        FlashMDError.mismatch(differences.first?.offset ?? blockOffset).localizedDescription
    }
}

public struct ScanAttemptFailure: Codable, Sendable {
    public let attempt: Int
    public let reader: String
    public let phase: String
    public let message: String
    public let mismatch: ROMScanMismatch?
    public var diagnosticText: String {
        var text = "\(reader) · scan \(attempt) · \(phase): \(message)"
        if let mismatch {
            text += "\nBlock 0x\(String(mismatch.blockOffset,radix:16).uppercased()), \(mismatch.bytes) bytes"
            text += "\nFirst SHA256: \(mismatch.firstSHA256)\nSecond SHA256: \(mismatch.secondSHA256)"
            for byte in mismatch.differences {
                text += String(format:"\n0x%X: %02X / %02X",byte.offset,byte.expected,byte.actual)
            }
        }
        return text
    }
}

public struct CartridgeScanResult: Sendable {
    public let cartridge: CartridgeSnapshot
    public let analysis: ROMContentAnalysis?
    public let failures: [ScanAttemptFailure]
}

public struct CartridgeScanFailure: LocalizedError, Sendable {
    public let failures: [ScanAttemptFailure]
    public let underlying: any Error
    public var errorDescription: String? {
        if failures.count == 3, underlying is ROMScanMismatch {
            return "The cartridge could not be read reliably after three scans. Restart the reader, then scan again."
        }
        return underlying.localizedDescription
    }
}
