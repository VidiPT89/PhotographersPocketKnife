import Foundation
import SwiftData

enum PhotoFlag: Int, CaseIterable, Sendable {
    case reject = -1, none = 0, pick = 1
}

enum ColorLabel: Int, CaseIterable, Identifiable, Sendable {
    case none = 0, red, yellow, green, blue, purple
    var id: Int { rawValue }
    var labelKey: String { "color.\(self)" }
}

@Model
final class Photo {
    @Attribute(.unique) var id: UUID
    var path: String
    var fileName: String
    var sessionName: String
    var captureDate: Date?
    var camera: String?
    var lens: String?
    var iso: Int?
    var aperture: Double?
    var focalLength: Double?
    var pixelWidth: Int
    var pixelHeight: Int
    var fileSize: Int64
    var rating: Int
    var flagRaw: Int
    var colorLabelRaw: Int
    var perceptualHash: Int64?
    var recipeData: Data?
    var historyData: Data?
    var importedAt: Date

    init(info: ImportedPhotoInfo, sessionName: String) {
        id = UUID()
        path = info.url.path
        fileName = info.url.lastPathComponent
        self.sessionName = sessionName
        captureDate = info.captureDate
        camera = info.camera
        lens = info.lens
        iso = info.iso
        aperture = info.aperture
        focalLength = info.focalLength
        pixelWidth = info.width
        pixelHeight = info.height
        fileSize = info.fileSize
        rating = 0
        flagRaw = 0
        colorLabelRaw = 0
        importedAt = Date()
    }

    var url: URL { URL(fileURLWithPath: path) }

    var flag: PhotoFlag {
        get { PhotoFlag(rawValue: flagRaw) ?? .none }
        set { flagRaw = newValue.rawValue }
    }

    var colorLabel: ColorLabel {
        get { ColorLabel(rawValue: colorLabelRaw) ?? .none }
        set { colorLabelRaw = newValue.rawValue }
    }
}

enum TransferProtocol: String, CaseIterable, Identifiable, Sendable, Codable {
    case ftp, ftps, sftp, s3
    var id: String { rawValue }

    var displayName: String { rawValue.uppercased() }

    var defaultPort: Int {
        switch self {
        case .ftp, .ftps: 21
        case .sftp: 22
        case .s3: 443
        }
    }
}

@Model
final class UploadDestination {
    @Attribute(.unique) var id: UUID
    var name: String
    var protocolRaw: String
    var host: String
    var port: Int
    var username: String
    /// Pasta remota com tokens, ex. `/fotos/{date}/{event}`.
    var remoteFolderTemplate: String
    var bucket: String
    var region: String
    var trustUnknownHostKey: Bool
    var createdAt: Date

    init(name: String = "", transferProtocol: TransferProtocol = .sftp) {
        id = UUID()
        self.name = name
        protocolRaw = transferProtocol.rawValue
        host = ""
        port = transferProtocol.defaultPort
        username = ""
        remoteFolderTemplate = "/{date}/{event}"
        bucket = ""
        region = "us-east-1"
        trustUnknownHostKey = false
        createdAt = Date()
    }

    var transferProtocol: TransferProtocol {
        get { TransferProtocol(rawValue: protocolRaw) ?? .sftp }
        set { protocolRaw = newValue.rawValue }
    }
}

@Model
final class UploadRecord {
    var id: UUID
    var fileName: String
    var destinationName: String
    var remotePath: String
    var date: Date
    var success: Bool
    var errorMessage: String?
    var bytes: Int64

    init(fileName: String, destinationName: String, remotePath: String, success: Bool, errorMessage: String?, bytes: Int64) {
        id = UUID()
        self.fileName = fileName
        self.destinationName = destinationName
        self.remotePath = remotePath
        date = Date()
        self.success = success
        self.errorMessage = errorMessage
        self.bytes = bytes
    }
}

@Model
final class EditPreset {
    var id: UUID
    var name: String
    var recipeData: Data
    var createdAt: Date

    init(name: String, recipeData: Data) {
        id = UUID()
        self.name = name
        self.recipeData = recipeData
        createdAt = Date()
    }
}
