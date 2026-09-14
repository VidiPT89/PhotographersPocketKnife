import Foundation
import UniformTypeIdentifiers

/// Preset partilhável num ficheiro `.ppkpreset` (JSON), para levar looks entre Macs ou dar a outros fotógrafos.
struct PresetFile: Codable, Equatable {
    var version = 1
    var name: String
    var recipe: EditRecipe

    static let fileExtension = "ppkpreset"
    static var contentType: UTType { UTType(filenameExtension: fileExtension, conformingTo: .json) ?? .json }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> PresetFile {
        try JSONDecoder().decode(PresetFile.self, from: data)
    }
}
