import Testing
@testable import FlashMDCore

@Test("Disconnected inspection reports unavailable transport")
func disconnectedInspection() async {
    let service = DisconnectedCartridgeService()
    await #expect(throws: CartridgeServiceError.transportUnavailable) {
        try await service.inspect()
    }
}

@Test("Demo measurements remain explicitly identified as samples")
func demoInspection() async throws {
    let cartridge = try await DemoCartridgeService().inspect()
    #expect(cartridge.isDemo)
    #expect(cartridge.flashCapacity?.source == .sample)
    #expect(cartridge.romSize?.source == .sample)
    #expect(cartridge.rawSaveWindow?.source == .sample)
}
