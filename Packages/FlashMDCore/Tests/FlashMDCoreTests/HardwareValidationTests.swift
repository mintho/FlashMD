import Foundation
import Testing
@testable import FlashMDCore

@Test(.enabled(if:ProcessInfo.processInfo.environment["FLASHMD_SHINING_SAVE_DIAGNOSTIC"] == "1"))
func hardwareShiningForceSaveReadDiagnosis() throws {
    let environment = ProcessInfo.processInfo.environment
    let destination = URL(fileURLWithPath:try #require(environment["FLASHMD_VALIDATION_FOLDER"]),isDirectory:true)
    let inventory = Process(), pipe = Pipe()
    inventory.executableURL = URL(fileURLWithPath:"/bin/ps")
    inventory.arguments = ["-axo","comm="]; inventory.standardOutput = pipe
    try inventory.run()
    let processes = String(decoding:pipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self)
    inventory.waitUntilExit()
    try #require(inventory.terminationStatus == 0)
    try #require(!processes.split(separator:"\n").contains { $0.trimmingCharacters(in:.whitespaces).hasSuffix("/FlashMD") })
    let endpoints = ProgrammerEndpoint.discover().filter { $0.kind == .mdDumper }
    try #require(endpoints.count == 1)
    let endpoint = try #require(endpoints.first)
    let location = try #require(UInt32(endpoint.id.dropFirst(10)))
    try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
    let device = try MDDumperDevice(transport:MDDumperUSBTransport(location:location),location:endpoint.id)
    defer { device.close() }
    let header = try device.readROMForVerification(offset:0,count:512)
    let metadata = try ROMMetadata.parse(header)
    try #require(metadata.title.uppercased().contains("SHINING"))
    try header.write(to:destination.appendingPathComponent("header.bin"),options:.atomic)
    let snapshot = try device.inspect(profile:.automatic)
    var report: [String:Any] = ["title":snapshot.title,"identity":snapshot.identity,
        "saveStatus":snapshot.saveStatus.rawValue,"canBackupSave":snapshot.canBackupSave,
        "saveWarning":metadata.saveWarning ?? "", "memoryProgrammingPerformed":false,
        "saveHeaderHex":header[0x1B0..<0x1BC].map { String(format:"%02X",$0) }.joined()]
    try String(reflecting:snapshot).write(to:destination.appendingPathComponent("snapshot.txt"),atomically:true,encoding:.utf8)
    if let layout = snapshot.saveLayout {
        try #require(layout.lane == 1 && layout.windowBytes <= 65536)
        report["layout"] = try JSONSerialization.jsonObject(with:JSONEncoder().encode(layout))
        for name in ["rom-before-1","rom-before-2","save-1","save-2","rom-after"] {
            let raw = try name.hasPrefix("save") ? device.readSRAM(layout:layout,offset:0,count:layout.windowBytes) : device.readROMForVerification(offset:layout.base,count:layout.windowBytes)
            try raw.write(to:destination.appendingPathComponent(name+".bus"),options:.atomic)
            let packed = try layout.pack(raw)
            try packed.write(to:destination.appendingPathComponent(name+".srm"),options:.atomic)
            let unused = stride(from:0,to:raw.count,by:2).map { raw[$0] }
            report[name] = ["SHA256":hash(packed),"activeBytes":packed.count,"blank":SaveMemoryProbe.isBlank(packed),
                "unusedBlankBytes":unused.filter { $0 == 0 || $0 == 0xFF }.count,"unusedBytes":unused.count]
        }
    }
    try device.reset()
    try #require(device.readROMForVerification(offset:0,count:512) == header)
    report["headerUnchanged"] = true
    if let exportPath = environment["FLASHMD_SHINING_SAVE_EXPORT"] {
        try #require(snapshot.canBackupSave && !snapshot.canStartSaveWrite && snapshot.saveStatus == .readOnly)
        let request = try BackupRequest(cartridge:snapshot,romBytes:nil,saveLayout:snapshot.saveLayout,
            saveFormat:.packed,verify:true,destination:URL(fileURLWithPath:exportPath,isDirectory:true))
        let result = try OperationRunner.backup(device:device,request:request,progress:{_ in})
        let folder = try #require(result.folder), artifact = try #require(result.manifest.artifacts.first)
        let exported = try Data(contentsOf:folder.appendingPathComponent(artifact.filename))
        let captured = try Data(contentsOf:destination.appendingPathComponent("save-1.srm"))
        try #require(exported == captured && artifact.verified)
        if let expected = environment["FLASHMD_SHINING_ORIGINAL_SAVE_HASH"] {
            try #require(artifact.sha256 == expected)
        }
        report["verifiedBackupFolder"] = folder.path
        report["verifiedSaveSHA256"] = artifact.sha256
    }
    try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
        .write(to:destination.appendingPathComponent("diagnosis.json"),options:.atomic)
}

@Test(.enabled(if:ProcessInfo.processInfo.environment["FLASHMD_MD_SCAN_RECOVERY"] == "1" || ProcessInfo.processInfo.environment["FLASHMD_FLASHKIT_SCAN_RECOVERY"] == "1"))
func hardwarePierScanRecovery() async throws {
    let environment = ProcessInfo.processInfo.environment
    let flashKit = environment["FLASHMD_FLASHKIT_SCAN_RECOVERY"] == "1"
    let endpoint = flashKit ? "/dev/cu.usbserial-AE01JVAH" : "md-dumper:1114112"
    let destination = URL(fileURLWithPath:try #require(environment["FLASHMD_VALIDATION_FOLDER"]),isDirectory:true)
    try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
    let controller = ProgrammerController()
    do {
        let result = try await controller.scan(path:endpoint,profile:.automatic,progress:{ value in
            if value.total == 0 || value.completed.isMultiple(of:0x100000) {
                let observation: [String:Any] = ["detail":value.detail,"completed":value.completed,"total":value.total]
                try? JSONSerialization.data(withJSONObject:observation,options:[.sortedKeys])
                    .write(to:destination.appendingPathComponent("progress.json"),options:.atomic)
            }
        })
        var report: [String:Any] = ["outcome":"passed","memoryProgrammingPerformed":false,
            "repeatedScans":result.failures.count,"reader":result.cartridge.identity,
            "ROM_SHA256":result.analysis?.sha256 ?? "",
            "failures":try JSONSerialization.jsonObject(with:JSONEncoder().encode(result.failures))]
        try #require(result.cartridge.mapper == .pierSolar)
        if !flashKit { try #require(!result.cartridge.canBackupSave) }
        try #require(result.analysis?.sha256 == "e9257f8b886fbd6fedb22f41ace215af4bdc374fe974d966d73c24789fb0e40c")
        report["matchedKnownOriginalROM"] = true
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
            .write(to:destination.appendingPathComponent("scan-recovery.json"),options:.atomic)
        try await controller.disconnect()
    } catch {
        try? await controller.disconnect()
        var report: [String:Any] = ["outcome":"failed","error":error.localizedDescription,"memoryProgrammingPerformed":false]
        if let error = error as? CartridgeScanFailure {
            report["failures"] = try JSONSerialization.jsonObject(with:JSONEncoder().encode(error.failures))
        }
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
            .write(to:destination.appendingPathComponent("scan-recovery.json"),options:.atomic)
        throw error
    }
}

@Test(.enabled(if:ProcessInfo.processInfo.environment["FLASHMD_MD_SCAN_DIAGNOSTIC"] == "1"))
func hardwareMDDumperPierScanDiagnostics() throws {
    let environment = ProcessInfo.processInfo.environment
    let destination = URL(fileURLWithPath:try #require(environment["FLASHMD_VALIDATION_FOLDER"]),isDirectory:true)
    let reference = try Data(contentsOf:URL(fileURLWithPath:try #require(environment["FLASHMD_ORIGINAL_ROM"])))
    try #require(hash(reference) == "e9257f8b886fbd6fedb22f41ace215af4bdc374fe974d966d73c24789fb0e40c")
    try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
    var attempts: [[String:Any]] = []
    func publish() throws {
        try JSONSerialization.data(withJSONObject:["attempts":attempts,"memoryProgrammingPerformed":false],options:[.prettyPrinted,.sortedKeys])
            .write(to:destination.appendingPathComponent("scan-attempts.json"),options:.atomic)
    }
    for index in 1...3 {
        let device = try MDDumperDevice(transport:MDDumperUSBTransport(location:1114112),location:"md-dumper:1114112")
        defer { device.close() }
        try device.validatePierSolarHeader(Data(reference.prefix(512)))
        let snapshot = try device.inspect(profile:.automatic)
        try #require(snapshot.mapper == .pierSolar && snapshot.canBackupROM && !snapshot.canBackupSave)
        var observation: [String:Any] = ["attempt":index,"reader":device.identity]
        do {
            let analysis = try ROMContentAnalysis.read(device:device,cartridge:snapshot,progress:{ value in
                if value.completed.isMultiple(of:0x100000) { print("Scan \(index): \(value.completed)/\(value.total)") }
            })
            observation["outcome"] = "passed"; observation["ROM_SHA256"] = analysis.sha256
            try #require(analysis.sha256 == hash(reference))
        } catch let error as ROMScanMismatch {
            observation["outcome"] = "mismatch"
            observation["mismatch"] = try JSONSerialization.jsonObject(with:JSONEncoder().encode(error))
        }
        try device.reset()
        for offset in [0,0x80000,0x280000,0x380000,0x7FFF00] {
            let expected = Data(reference[offset..<offset+256])
            try #require(device.readROMForVerification(offset:offset,count:256) == expected)
            try #require(device.readROMForVerification(offset:offset,count:256) == expected)
        }
        observation["cleanupAndROMWitnessesPassed"] = true
        attempts.append(observation); try publish(); device.close()
    }
}

/// Deliberately separate from ordinary scanning. Requires a known original ROM,
/// a chosen reader and explicit opt-in. The first run reads only status/samples.
@Test(.enabled(if:ProcessInfo.processInfo.environment["FLASHMD_PIER_SPI_VALIDATE"] == "1"))
func hardwarePierSolarSPIReadValidation() throws {
    let environment = ProcessInfo.processInfo.environment
    let endpoint = try #require(environment["FLASHMD_VALIDATION_ENDPOINT"])
    let stage = try #require(environment["FLASHMD_PIER_SPI_STAGE"])
    try #require(stage == "probe" || stage == "full")
    try #require(endpoint == "md-dumper:1114112" || endpoint == "/dev/cu.usbserial-AE01JVAH")
    let destination = URL(fileURLWithPath:try #require(environment["FLASHMD_VALIDATION_FOLDER"]),isDirectory:true)
    let reference = try Data(contentsOf:URL(fileURLWithPath:try #require(environment["FLASHMD_ORIGINAL_ROM"])))
    try #require(reference.count == 0x800000 && hash(reference) == "e9257f8b886fbd6fedb22f41ace215af4bdc374fe974d966d73c24789fb0e40c")
    let inventory = Process(), pipe = Pipe()
    inventory.executableURL = URL(fileURLWithPath:"/bin/ps")
    inventory.arguments = ["-axo","comm="]; inventory.standardOutput = pipe
    try inventory.run()
    let processes = String(decoding:pipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self)
    inventory.waitUntilExit()
    try #require(inventory.terminationStatus == 0)
    try #require(!processes.split(separator:"\n").contains { $0.trimmingCharacters(in:.whitespaces).hasSuffix("/FlashMD") })
    try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
    let device: any CartridgeDevice
    if endpoint.hasPrefix("md-dumper:") {
        device = try MDDumperDevice(transport:MDDumperUSBTransport(location:1114112),location:endpoint)
    } else { device = try FlashKitDevice(transport:SerialTransport(path:endpoint),path:endpoint) }
    defer { device.close() }
    var report: [String:Any] = ["stage":stage,"endpoint":endpoint,"identity":device.identity,
        "ROMOrSaveProgrammingPerformed":false,"SPICommands":["READ (03)","READ STATUS (05)"],
        "SPIAccessAttempted":false,"physicalCapacityInferred":false,"serialAddressEnvelopeBytes":65536]
    var witnessObservations: [[String:Any]] = []
    func publish() throws {
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
            .write(to:destination.appendingPathComponent("spi-validation.json"),options:.atomic)
    }
    func witnessROM() throws -> [String] {
        var hashes: [String] = []
        for offset in [0,0x80000,0x280000,0x380000,0x7FFF00] {
            let first = try device.readROM(offset:offset,count:256)
            let second = try device.readROMForVerification(offset:offset,count:256)
            let expected = Data(reference[offset..<offset+256])
            let differences = (0..<min(256,first.count,second.count)).filter { first[$0] != second[$0] || first[$0] != expected[$0] }
            witnessObservations.append(["offset":offset,"firstSHA256":hash(first),"secondSHA256":hash(second),
                "expectedSHA256":hash(expected),"bytes":first.count,"twoReadsMatch":first == second,
                "matchesReference":first == expected,"differences":differences.prefix(16).map {
                    ["offset":offset+$0,"first":Int(first[$0]),"second":Int(second[$0]),"expected":Int(expected[$0])]
                }])
            report["ROMWitnessObservations"] = witnessObservations; try publish()
            guard first == second, first == expected else {
                throw FlashMDError.mismatch(offset+(differences.first ?? 0))
            }
            hashes.append(hash(first))
        }
        return hashes
    }
    try publish()
    do {
        let header = Data(reference.prefix(512))
        if let dumper = device as? MDDumperDevice { try dumper.validatePierSolarHeader(header) }
        if let flashKit = device as? FlashKitDevice { try flashKit.validatePierSolarHeader(header) }
        if let flashKit = device as? FlashKitDevice { flashKit.pierSolarSaveEnabled = false }
        let initial = try device.inspect(profile:.automatic)
        try #require(initial.mapper == .pierSolar && initial.romAccess == .banked && !initial.canBackupSave)
        report["ROMWitnessesBefore"] = try witnessROM(); try publish()
        if let dumper = device as? MDDumperDevice {
            dumper.pierSolarSaveEnabled = true
            var words: [Int] = []
            dumper.pierSolarSPIObserveWord = { word in
                if words.count < 64 {
                    words.append(Int(word)); report["SPIWordSamples"] = words
                    try? publish()
                }
            }
        }
        if let flashKit = device as? FlashKitDevice {
            flashKit.pierSolarSaveEnabled = true
            if environment["FLASHMD_PIER_SPI_UNPIPELINED"] == "1" {
                flashKit.pierSolarSPIPipelined = false
                report["pipelined"] = false
                var words: [Int] = []
                flashKit.pierSolarSPIObserveWord = { word in
                    words.append(Int(word)); report["SPIWordSamples"] = words
                    try? publish()
                }
            }
        }
        report["SPIAccessAttempted"] = true; try publish()
        let qualified = try device.inspectConfigured(profile:.automatic,override:nil,mapper:.automatic)
        report["qualificationMessage"] = qualified.warning ?? ""; try publish()
        let probe: PierSolarSaveProbe
        if let dumper = device as? MDDumperDevice { probe = try dumper.probePierSolarSave() }
        else { probe = try #require(device as? FlashKitDevice).probePierSolarSave() }
        report["probe"] = ["status":Int(probe.status),"samples":probe.samples.map {
            ["offset":$0.offset,"bytes":$0.data.count,"hex":$0.data.map { String(format:"%02X",$0) }.joined(),"sha256":hash($0.data)] as [String:Any]
        }] as [String:Any]
        report["probePassed"] = true; try publish()
        try #require(qualified.serialSave == .pierSolar && qualified.canBackupSave && !qualified.canStartSaveWrite && !qualified.canWrite)
        if stage == "full" {
            var artifacts: [[String:Any]] = []
            for _ in 0..<2 {
                let request = try BackupRequest(cartridge:qualified,romBytes:nil,saveLayout:nil,saveFormat:.packed,verify:true,destination:destination,includeSerialSave:true)
                let backupNumber = artifacts.count+1
                let result = try OperationRunner.backup(device:device,request:request,progress:{ value in
                    if value.completed.isMultiple(of:4096) {
                        print("SPI \(value.phase.rawValue): \(value.completed)/\(value.total)")
                        let progress: [String:Any] = ["backup":backupNumber,"phase":value.phase.rawValue,"completed":value.completed,"total":value.total]
                        try? JSONSerialization.data(withJSONObject:progress,options:[.sortedKeys])
                            .write(to:destination.appendingPathComponent("progress.json"),options:.atomic)
                    }
                })
                let folder = try #require(result.folder), artifact = try #require(result.manifest.artifacts.first)
                try #require(artifact.verified && artifact.bytes == 65536)
                artifacts.append(["path":folder.appendingPathComponent(artifact.filename).path,"sha256":artifact.sha256,"bytes":artifact.bytes])
                report["saveArtifacts"] = artifacts; try publish()
            }
            try #require(artifacts[0]["sha256"] as? String == artifacts[1]["sha256"] as? String)
            report["fourIndependentFullReadsMatch"] = true
        }
        try device.reset()
        report["ROMWitnessesAfter"] = try witnessROM()
        report["saveWritingEnabled"] = false
        report["outcome"] = "passed"; try publish()
    } catch {
        report["outcome"] = "failed"; report["error"] = error.localizedDescription
        do { try device.reset(); report["ROMWitnessesAfterFailure"] = try witnessROM(); report["cleanupPassed"] = true }
        catch { report["cleanupPassed"] = false; report["cleanupError"] = error.localizedDescription }
        try publish(); throw error
    }
}

/// ROM-only diagnostics for the qualified Pier Solar mapper. Captures every
/// comparison, including failures; never accesses its separate save interface.
@Test(.enabled(if:ProcessInfo.processInfo.environment["FLASHMD_BANKED_DIAGNOSTIC"] == "1"))
func hardwarePierROMReadConsistencyDiagnostic() throws {
    let environment = ProcessInfo.processInfo.environment
    let endpoint = try #require(environment["FLASHMD_VALIDATION_ENDPOINT"])
    try #require(endpoint == "md-dumper:1114112")
    let destination = URL(fileURLWithPath:try #require(environment["FLASHMD_VALIDATION_FOLDER"]),isDirectory:true)
    let reference = try Data(contentsOf:URL(fileURLWithPath:try #require(environment["FLASHMD_ORIGINAL_ROM"])))
    try #require(reference.count == 0x800000 && hash(reference) == "e9257f8b886fbd6fedb22f41ace215af4bdc374fe974d966d73c24789fb0e40c")
    try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
    let device = try MDDumperDevice(transport:MDDumperUSBTransport(location:1114112),location:endpoint)
    defer { device.close() }
    let snapshot = try device.inspect(profile:.automatic)
    try #require(snapshot.mapper == .pierSolar && snapshot.romAccess == .banked && !snapshot.canBackupSave)
    var observations: [[String:Any]] = []
    var report: [String:Any] = ["ROMOrSRAMProgrammingPerformed":false,"saveInterfaceAccessed":false]
    func publish() throws {
        report["observations"] = observations
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
            .write(to:destination.appendingPathComponent("diagnostic.json"),options:.atomic)
    }
    do {
        let samples = [(0,32768),(0,32768),(0x40000,512),(0x80000,512),(0x280000,512),(0,32768)]
        for (index,sample) in samples.enumerated() {
            let (offset,count) = sample
            let expected = Data(reference[offset..<offset+count])
            let first = try device.readROM(offset:offset,count:count)
            let second = try device.readROMForVerification(offset:offset,count:count)
            try #require(first.count == count && second.count == count)
            try first.write(to:destination.appendingPathComponent("\(index)-first.bin"),options:.atomic)
            try second.write(to:destination.appendingPathComponent("\(index)-second.bin"),options:.atomic)
            let differing = (0..<count).filter { first[$0] != second[$0] || first[$0] != expected[$0] }
            observations.append(["offset":offset,"bytes":count,"twoReadsMatch":first == second,
                "firstMatchesReference":first == expected,"secondMatchesReference":second == expected,
                "differenceCount":differing.count,"differences":differing.prefix(16).map { byte in
                    ["offset":offset+byte,"expected":Int(expected[byte]),"first":Int(first[byte]),"second":Int(second[byte])]
                }])
            try publish()
        }
        try device.reset()
        report["finalIdentificationUnchanged"] = try device.inspect(profile:.automatic) == snapshot
        try publish()
    } catch {
        report["error"] = error.localizedDescription
        do { try device.reset(); report["cleanupPassed"] = true }
        catch { report["cleanupError"] = error.localizedDescription }
        try? publish()
        throw error
    }
}

@Test(.enabled(if:ProcessInfo.processInfo.environment["FLASHMD_SRAM_DIAGNOSTIC"] == "1" && ProcessInfo.processInfo.environment["FLASHMD_READONLY_VALIDATION"] != "1"))
func hardwareReadOnlySaveSelectionEvidence() throws {
    let environment = ProcessInfo.processInfo.environment
    let endpoint = try #require(environment["FLASHMD_VALIDATION_ENDPOINT"])
    let location = try #require(UInt32(endpoint.dropFirst(10)))
    let destination = URL(fileURLWithPath:try #require(environment["FLASHMD_VALIDATION_FOLDER"]),isDirectory:true)
    try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
    let device = try MDDumperDevice(transport:MDDumperUSBTransport(location:location),location:endpoint)
    defer { device.close() }
    let snapshot = try device.inspect(profile:.automatic)
    try #require(snapshot.title == environment["FLASHMD_VALIDATION_TITLE"])
    let layout = try #require(snapshot.saveLayout)
    try #require(layout.activeBytes == environment["FLASHMD_VALIDATION_SAVE_BYTES"].flatMap(Int.init))
    try String(reflecting:snapshot).write(to:destination.appendingPathComponent("inspection-0.txt"),atomically:true,encoding:.utf8)
    for index in 1...5 {
        let next = try device.inspect(profile:.automatic)
        try String(reflecting:next).write(to:destination.appendingPathComponent("inspection-\(index).txt"),atomically:true,encoding:.utf8)
    }
    for index in 0..<10 {
        _ = try device.readROMForVerification(offset:0,count:512)
        for name in ["rom-before-1","rom-before-2","save-1","save-2","rom-after"] {
            let raw = try name.hasPrefix("save") ? device.readSRAM(layout:layout,offset:0,count:layout.windowBytes) : device.readROMForVerification(offset:layout.base,count:layout.windowBytes)
            try raw.write(to:destination.appendingPathComponent("\(index)-"+name+".bus"),options:.atomic)
            try layout.pack(raw).write(to:destination.appendingPathComponent("\(index)-"+name+".srm"),options:.atomic)
        }
    }
    try device.reset()
}

/// Explicit opt-in only. The app must be closed and the cartridge inserted with
/// power disconnected. No ROM/SRAM programming or erase calls exist in this test.
@Test(.enabled(if:ProcessInfo.processInfo.environment["FLASHMD_READONLY_VALIDATION"] == "1"))
func hardwareReadOnlyBackupKeepsROMAndSRAMConsistent() async throws {
    let environment = ProcessInfo.processInfo.environment
    let endpoint = try #require(environment["FLASHMD_VALIDATION_ENDPOINT"])
    let destination = URL(fileURLWithPath:try #require(environment["FLASHMD_VALIDATION_FOLDER"]),isDirectory:true)
    let controller = ProgrammerController()
    func stage(_ message: String) {
        let line = Data("\(Date()): \(message)\n".utf8)
        FileHandle.standardError.write(line)
        // The test runner buffers stderr. A separate log makes long hardware
        // validations observable without starting another USB client.
        let url = destination.appendingPathComponent("Validation stages.log")
        if !FileManager.default.fileExists(atPath:url.path) {
            _ = FileManager.default.createFile(atPath:url.path,contents:nil)
        }
        if let file = try? FileHandle(forWritingTo:url) {
            defer { try? file.close() }
            _ = try? file.seekToEnd(); try? file.write(contentsOf:line)
        }
    }
    do {
        try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
        try await controller.connect(path:endpoint,mdDumperStreaming:environment["FLASHMD_VALIDATION_STREAMING"] == "1")
        stage("Inspecting cartridge")
        let snapshot = try await controller.inspect(profile:.automatic)
        stage("\(snapshot.title): \(snapshot.saveStatus.rawValue)")
        if let expected = environment["FLASHMD_VALIDATION_TITLE"], snapshot.title != expected {
            throw FlashMDError.invalid("Expected \(expected), but read \(snapshot.title). No backup was started.")
        }
        if let expected = environment["FLASHMD_VALIDATION_SAVE_STATUS"] {
            try #require(snapshot.saveStatus.rawValue == expected)
            if ["none","unconfirmed","unsupported"].contains(expected) {
                try #require(!snapshot.canBackupSave && !snapshot.canRestoreSave)
            }
        }
        if let expected = environment["FLASHMD_VALIDATION_SAVE_BYTES"].flatMap(Int.init) {
            try #require(snapshot.canBackupSave && snapshot.saveLayout?.activeBytes == expected)
        }
        var originalSave: String?
        if snapshot.canBackupSave {
            stage("Capturing and verifying original save")
            let request = try BackupRequest(cartridge:snapshot,romBytes:nil,saveLayout:snapshot.saveLayout,saveFormat:.packed,verify:true,destination:destination)
            let result = try await controller.backup(request,progress:{_ in})
            originalSave = try #require(result.manifest.artifacts.first?.sha256)
            if let expected = environment["FLASHMD_VALIDATION_SAVE_SHA256"] { #expect(originalSave == expected) }
        }
        stage("Analyzing ROM")
        let analysis = try await controller.analyze(snapshot,progress:{_ in})
        let size = try #require(analysis.suggestedBytes)
        if let expected = environment["FLASHMD_VALIDATION_ROM_BYTES"].flatMap(Int.init) { #expect(size == expected) }
        let request = try BackupRequest(cartridge:snapshot,romBytes:size,saveLayout:snapshot.canBackupSave ? snapshot.saveLayout : nil,saveFormat:.packed,verify:true,destination:destination,contentAnalysis:analysis)
        stage("First verified ROM/SRAM backup")
        let first = try await controller.backup(request,progress:{_ in})
        stage("Second verified ROM/SRAM backup")
        let second = try await controller.backup(request,progress:{_ in})
        #expect(first.manifest.artifacts == second.manifest.artifacts)
        #expect(first.manifest.artifacts.allSatisfy { $0.verified })
        if !snapshot.canBackupSave {
            #expect(first.manifest.artifacts.allSatisfy { $0.isROM })
            #expect(second.manifest.artifacts.allSatisfy { $0.isROM })
        }
        let rom = try #require(first.manifest.artifacts.first(where: { $0.isROM }))
        if let expected = environment["FLASHMD_VALIDATION_ROM_SHA256"] { #expect(rom.sha256 == expected) }
        if let originalSave {
            #expect(first.manifest.artifacts.first(where:{ !$0.isROM })?.sha256 == originalSave)
            #expect(second.manifest.artifacts.first(where:{ !$0.isROM })?.sha256 == originalSave)
        }
        stage("Checking final cartridge state")
        let final = try await controller.inspect(profile:.automatic)
        #expect(final == snapshot)
        try await controller.disconnect()
        stage("Validation finished")
    } catch { try? await controller.disconnect(); throw error }
}

/// Disposable Bailey only. Originals and their hashes are supplied from the
/// independently verified, cold-retained backup; never enabled in normal tests.
@Test(.enabled(if:ProcessInfo.processInfo.environment["FLASHMD_BAILEY_WRITE_VALIDATION"] == "1"))
func hardwareBaileyWriteAndRestoreOriginals() throws {
    let environment = ProcessInfo.processInfo.environment
    let endpoint = try #require(environment["FLASHMD_VALIDATION_ENDPOINT"])
    try #require(endpoint == "/dev/cu.usbserial-AE01JVAH")
    let folder = URL(fileURLWithPath:try #require(environment["FLASHMD_VALIDATION_FOLDER"]),isDirectory:true)
    let originalROM = try Data(contentsOf:URL(fileURLWithPath:try #require(environment["FLASHMD_ORIGINAL_ROM"])))
    let originalSave = try Data(contentsOf:URL(fileURLWithPath:try #require(environment["FLASHMD_ORIGINAL_SAVE"])))
    try #require(originalROM.count == 0x200000 && hash(originalROM) == "90c1d24a6ddaa652ef2107f5b3d452eb266678d3a3d9d5bbeade544cd79c03c4")
    try #require(originalSave.count == 32768 && hash(originalSave) == "277655c6fc19fe91c8d7415f923e56aa1ef0772f6a2394dd920ac239dc364cb7")
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    let log = folder.appendingPathComponent("stages.log")
    try Data().write(to:log)
    @Sendable func stage(_ text: String) {
        if let file = try? FileHandle(forWritingTo:log) {
            defer { try? file.close() }
            _ = try? file.seekToEnd(); try? file.write(contentsOf:Data("\(Date()): \(text)\n".utf8)); try? file.synchronize()
        }
    }
    let device = try FlashKitDevice(transport:SerialTransport(path:endpoint),path:endpoint)
    defer { device.close() }
    let snapshot = try device.inspect(profile:.automatic)
    try #require(snapshot.title == "BAILEY THE BRAVE" && snapshot.canCheckSaveWriting)
    let layout = try #require(snapshot.saveLayout)
    try #require(layout.base == 0x200000 && layout.windowBytes == 65536 && layout.lane == 1)
    func rom() throws -> Data {
        var data = Data()
        for offset in stride(from:0,to:originalROM.count,by:32768) {
            data.append(try device.readROMForVerification(offset:offset,count:min(32768,originalROM.count-offset)))
        }
        return data
    }
    func save() throws -> Data {
        var raw = Data()
        for offset in stride(from:0,to:layout.windowBytes,by:32768) {
            raw.append(try device.readSRAM(layout:layout,offset:offset,count:min(32768,layout.windowBytes-offset)))
        }
        return try layout.pack(raw)
    }
    func plan(rom: Data? = nil, save: Data? = nil) throws -> WritePlan {
        try WritePlan(target:device.inspect(profile:.automatic),image:rom.map { try ROMImage(data:$0) },romName:"Original Bailey.bin",save:save,saveName:"Original Bailey.srm",format:.packed,backupDestination:nil,clearUnusedROM:true)
    }
    func write(_ plan: WritePlan, name: String) throws {
        let result = try OperationRunner.write(device:device,plan:plan,progress:{ value in
            if value.completed == 0 { stage(value.detail) }
        },recoveryDirectory:folder.appendingPathComponent("Save Recovery"))
        let reportFolder = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at:reportFolder,withIntermediateDirectories:true)
        try OperationRunner.writeManifest(result.manifest,folder:reportFolder)
        try #require(result.manifest.outcome == "completed")
        try device.reset()
    }
    stage("Checking current contents against cold-verified originals")
    let beforeROM = try rom(), beforeSave = try save()
    try #require(beforeROM == originalROM && beforeSave == originalSave)
    if environment["FLASHMD_BAILEY_WRITE_PHASE"] == "sram" {
        var testSave = originalSave
        // Keep the game's highscore table untouched by the actual save-file test.
        for index in (testSave.count-32)..<testSave.count { testSave[index] = UInt8(0xC0+(index%32)) }
        stage("Writing disposable save tail; originals journaled before the access check")
        do {
            try write(plan(save:testSave),name:"save-test")
            let testedSave = try save(), testedROM = try rom()
            try #require(testedSave == testSave && testedROM == originalROM)
        } catch {
            stage("Test failed; attempting immediate original-save restoration")
            do { try write(plan(save:originalSave),name:"save-recovery"); try #require(save() == originalSave) }
            catch { stage("RESTORATION FAILED: \(error.localizedDescription)"); throw error }
            throw error
        }
        stage("Restoring the complete original save immediately")
        try write(plan(save:originalSave),name:"save-original-restored")
    } else {
        try #require(environment["FLASHMD_BAILEY_WRITE_PHASE"] == "rom")
        stage("Rewriting original ROM only; SRAM must survive unchanged")
        try write(plan(rom:originalROM),name:"rom-only-write")
    }
    stage("Comparing the complete ROM and SRAM with the originals")
    let finalROM = try rom(), finalSave = try save()
    try finalROM.write(to:folder.appendingPathComponent("Verified Original ROM.bin"),options:.atomic)
    try finalSave.write(to:folder.appendingPathComponent("Verified Original Save.srm"),options:.atomic)
    try #require(finalROM == originalROM && finalSave == originalSave)
    stage("Original ROM and SRAM verified byte for byte")
}
