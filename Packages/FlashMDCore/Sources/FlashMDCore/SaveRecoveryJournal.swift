import Foundation

/// Durable recovery data for saves promised to survive a ROM write.
/// Kept on interruption; removed only after ROM and preserved SRAM are verified.
public enum SaveRecoveryJournal {
    public static var directory: URL {
        FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("FlashMD/Save Recovery",isDirectory:true)
    }
    public static func pendingFolders(in directory: URL = Self.directory) -> [URL] {
        let folders = (try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.isDirectoryKey])) ?? []
        return folders.filter { FileManager.default.fileExists(atPath:$0.appendingPathComponent("recovery.json").path) }.sorted { $0.path < $1.path }
    }
    struct Record: Codable {
        let schemaVersion: Int
        let date: Date
        let cartridgeTitle: String
        let device: String
        let fingerprint: String
        let layout: SRAMLayout
        let saveFormat: SaveFormat
        let saveSHA256: String
        let inputROMSHA256: String?
        let instructions: String
    }
    static func create(raw: Data, layout: SRAMLayout, target: CartridgeSnapshot, rom: Data?,
                       directory: URL = Self.directory) throws -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        do {
            let packed = try layout.pack(raw)
            let saveURL = folder.appendingPathComponent("Preserved Saves.srm")
            try packed.write(to:saveURL,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:saveURL.path)
            let file = try FileHandle(forWritingTo:saveURL)
            defer { try? file.close() }
            try file.synchronize()
            let record = Record(schemaVersion:1,date:Date(),cartridgeTitle:target.title,device:target.identity,
                fingerprint:target.fingerprint,layout:layout,saveFormat:.packed,saveSHA256:hash(packed),inputROMSHA256:rom.map(hash),
                instructions:"A write or SRAM write check may have been interrupted. Keep these files. Scan the correct cartridge before restoring Preserved Saves.srm as Save bytes only. ROM recovery requires the original ROM file.")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            let recordURL = folder.appendingPathComponent("recovery.json")
            try encoder.encode(record).write(to:recordURL,options:.atomic)
            let recordFile = try FileHandle(forWritingTo:recordURL)
            defer { try? recordFile.close() }
            try recordFile.synchronize()
            return folder
        } catch { try? FileManager.default.removeItem(at:folder); throw error }
    }
}
