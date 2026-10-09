import Testing
import Foundation
@testable import FlashMDCore

@Test func metadataAndChecksum() throws {
    let image = try ROMImage(data:fixtureROM())
    #expect(image.metadata.title == "TEST GAME"); #expect(image.metadata.copyrightYear == "1994")
    #expect(image.metadata.regions == ["Japan","USA","Europe"]); #expect(image.metadata.declaredROMBytes == image.data.count)
    #expect(image.checksum == image.metadata.storedChecksum); #expect(image.metadata.rawHeader.count == 256)
    #expect(image.metadata.saveLayout?.windowBytes == 16384); #expect(image.metadata.saveLayout?.activeBytes == 8192)
}
@Test func metadataRevisionRequiresARecognizableProductCode() throws {
    let cases: [(String, Int?)] = [
        ("GM 00000000-00",0), ("GM 00000000-01",1), ("GM T-574023-02",2),
        ("GM 00000000-99",99), ("GM 00000000",nil), ("GM 00000000-1",nil),
        ("GM 00000000-A1",nil), ("GM 000000-1.11",nil), ("VERSION 01",nil), ("",nil)
    ]
    for (code, expected) in cases {
        var data = fixtureROM()
        data.replaceSubrange(0x180..<0x18E,with:Data(repeating:32,count:14))
        data.replaceSubrange(0x180..<0x180+code.utf8.count,with:Data(code.utf8))
        #expect(try ROMMetadata.parse(data).revision == expected)
    }
}
@Test(arguments:[0,1,511]) func truncatedInputs(length:Int) { #expect(throws:(any Error).self) { try ROMImage(data:Data(count:length)) } }
@Test func invalidImages() {
    #expect(throws:(any Error).self) { try ROMImage(data:Data(repeating:0xFF,count:65536)) }
    #expect(throws:(any Error).self) { try ROMImage(data:Data(count:65536)) }
    var swapped = fixtureROM(); swapped.replaceSubrange(0x100..<0x104,with:Data("ESAG".utf8))
    #expect(throws:(any Error).self) { try ROMImage(data:swapped) }
    var smd = Data(count:65536); smd[0x2280] = 0x53; smd[0x280] = 0x45
    #expect(throws:(any Error).self) { try ROMImage(data:smd) }
}
@Test func malformedFieldsAndJapaneseText() throws {
    var data = fixtureROM(); data[0x1F0] = 0xFF; data.replaceSubrange(0x1A4..<0x1A8,with:Data(repeating:0xFF,count:4))
    let japanese = "ソレイユ".data(using:.shiftJIS)!
    data.replaceSubrange(0x120..<0x120+japanese.count,with:japanese)
    let metadata = try ROMMetadata.parse(data)
    #expect(metadata.domesticTitle.hasPrefix("ソレイユ")); #expect(metadata.declaredROMBytes == nil)
    #expect(metadata.productCode == "GM 00000000-00")
}
@Test func hexadecimalRegionsAndChecksumMismatch() throws {
    var data = fixtureROM(); data.replaceSubrange(0x1F0..<0x200,with:Data(repeating:32,count:16)); data[0x1F0] = 0x44; data[1000] ^= 1
    let image = try ROMImage(data:data)
    #expect(image.metadata.regions == ["Japan","USA","Europe"]); #expect(!image.warnings.isEmpty)
}
@Test func saveConversionKeepsInactiveLaneSeparate() throws {
    let layout = try SRAMLayout(start:0x200001,end:0x203FFF,lane:1)
    let packed = Data((0..<layout.activeBytes).map { UInt8(truncatingIfNeeded:$0) })
    let raw = try layout.rawRepresentation(packed,format:.packed)
    #expect(try layout.pack(raw) == packed)
    #expect(stride(from:0,to:raw.count,by:2).allSatisfy { raw[$0] == 0xFF })
    #expect(throws:(any Error).self) { try layout.rawRepresentation(Data(count:3),format:.raw) }
}
@Test func saveLayoutsRejectInvalidRangesAndEEPROM() throws {
    #expect(throws:(any Error).self) { try SRAMLayout(start:0,end:Int.max,lane:1) }
    var data = fixtureROM(); data[0x1B3] = 0x40
    let metadata = try ROMMetadata.parse(data); #expect(metadata.saveLayout == nil); #expect(metadata.saveWarning != nil)
}
@Test func topAndBottomBootGeometry() throws {
    let bottom = try fixtureGeometry(), top = try fixtureGeometry(top:true)
    #expect(bottom.sectors.first?.bytes == 8192); #expect(top.sectors.first?.bytes == 65536)
    #expect(top.sectors.last?.bytes == 8192); #expect(bottom.sectors.reduce(0) { $0+$1.bytes } == 0x400000)
    #expect(try top.programLength(65538) == 131072)
    let actual = try FlashGeometry(cfi:fixtureCFI(eightMB:true),manufacturer:1,deviceID:0x227E,extendedID:0x2210,bootID:0x2201)
    #expect(actual.supported); #expect(actual.capacity == 0x800000); #expect(actual.sectors.first?.bytes == 65536)
}
@Test func malformedGeometryAndUnknownFlash() throws {
    var data = fixtureCFI(); data[0x27] = 32
    #expect(throws:(any Error).self) { try FlashGeometry(cfi:data,manufacturer:1,deviceID:1) }
    #expect(!(try FlashGeometry(cfi:fixtureCFI(),manufacturer:0xC2,deviceID:0x2257)).supported)
}

@Test func geometryCapacityEdgesAndUnexpectedSectorLayout() throws {
    let geometry = try fixtureGeometry(top:true)
    #expect(try geometry.programLength(0x400000) == 0x400000)
    #expect(throws:(any Error).self) { try geometry.programLength(0x400001) }
    var uniform = fixtureCFI(); uniform[0x2C] = 1; uniform[0x2D] = 63; uniform[0x2F] = 0; uniform[0x30] = 1
    let unqualified = try FlashGeometry(cfi:uniform,manufacturer:0x20,deviceID:0x2256)
    #expect(!unqualified.supported)
}
@Test func boundedArbitraryHeadersAndSlicedData() throws {
    for seed in 0..<128 {
        let bytes = Data((0..<512).map { UInt8(truncatingIfNeeded:($0 * 73) ^ (seed * 31)) })
        let metadata = try ROMMetadata.parse(bytes)
        #expect(metadata.rawHeader.count == 256)
        _ = try? ROMImage(data:bytes)
    }
    let original = fixtureROM(), prefixed = Data([0xFF]) + original
    let image = try ROMImage(data:prefixed.dropFirst())
    #expect(image.data == original)
}
@Test func evenAndWordSaveConversionRoundTrips() throws {
    for layout in [try SRAMLayout(start:0x200000,end:0x20000E,lane:0),try SRAMLayout(start:0x200000,end:0x20000F,lane:nil)] {
        let packed = Data((0..<layout.activeBytes).map { UInt8($0) })
        #expect(try layout.pack(layout.rawRepresentation(packed,format:.packed)) == packed)
    }
}
