import Foundation
import Testing
@testable import FlashMDCore

private final class StatusTransport: ByteTransport, @unchecked Sendable {
    var time: TimeInterval = 0
    var responses: [Result<Data,FlashMDError>]
    var readTimeouts: [TimeInterval] = []
    var writes = 0
    init(_ responses: [Result<Data,FlashMDError>] = []) { self.responses = responses }
    func write(_ data: Data, timeout: TimeInterval) throws { writes += 1 }
    func read(count: Int, timeout: TimeInterval, cancellable: Bool) throws -> Data {
        #expect(count == 64 && !cancellable)
        readTimeouts.append(timeout)
        let response = responses.isEmpty ? .failure(FlashMDError.timeout) : responses.removeFirst()
        if case .failure(.timeout) = response { time += timeout }
        else { time += 0.1 }
        return try response.get()
    }
    func close() {}
}

@Test(arguments:[35,130,250]) func mdDumperWaitsThroughQuietErasePollsWithoutResendingCommands(quietSeconds: Int) throws {
    let polls = quietSeconds/5
    let transport = StatusTransport(Array(repeating:.failure(.timeout),count:polls) + [.success(Data(repeating:0xFF,count:64))])
    try MDDumperStatus.wait(transport:transport,index:0,value:0xFF,timeout:MDDumperDevice.chipEraseTimeout,uptime:{transport.time})
    #expect(transport.time > Double(quietSeconds) && transport.readTimeouts.count == polls+1)
    #expect(transport.writes == 0)
}

@Test func mdDumperSilentEraseHasAFiniteFiveMinuteDeadline() throws {
    let transport = StatusTransport()
    #expect(MDDumperDevice.chipEraseTimeout == 300)
    #expect(throws:FlashMDError.timeout) {
        try MDDumperStatus.wait(transport:transport,index:0,value:0xFF,timeout:MDDumperDevice.chipEraseTimeout,uptime:{transport.time})
    }
    #expect(transport.time == 300 && transport.readTimeouts.count == 60)
    #expect(transport.writes == 0)
}

@Test func mdDumperStatusWaitKeepsTheOverallDeadline() throws {
    let transport = StatusTransport()
    #expect(throws:FlashMDError.timeout) {
        try MDDumperStatus.wait(transport:transport,index:0,value:0xFF,timeout:12,uptime:{transport.time})
    }
    #expect(transport.time == 12 && transport.readTimeouts == [5,5,2])
    #expect(transport.writes == 0)
}

@Test func mdDumperStatusWaitDoesNotRetryDisconnectsOrIncompleteReplies() throws {
    let disconnected = StatusTransport([.failure(.disconnected)])
    #expect(throws:FlashMDError.disconnected) {
        try MDDumperStatus.wait(transport:disconnected,index:0,value:0xFF,timeout:120,uptime:{disconnected.time})
    }
    #expect(disconnected.readTimeouts.count == 1)
    let short = StatusTransport([.success(Data(repeating:0xFF,count:63))])
    #expect(throws:(any Error).self) {
        try MDDumperStatus.wait(transport:short,index:0,value:0xFF,timeout:120,uptime:{short.time})
    }
    #expect(short.readTimeouts.count == 1)
}
