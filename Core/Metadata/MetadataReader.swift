import Foundation
import ImageIO

struct ImportedPhotoInfo: Sendable {
    let url: URL
    let captureDate: Date?
    let camera: String?
    let lens: String?
    let width: Int
    let height: Int
    let fileSize: Int64
}

/// Um campo de metadados; `id` é a chave de tradução do rótulo.
struct MetadataField: Identifiable, Sendable, Equatable {
    let id: String
    let value: String
}

enum MetadataReader {
    nonisolated(unsafe) private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    static func properties(for url: URL) -> [String: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return [:] }
        return props
    }

    static func basicInfo(for url: URL) -> ImportedPhotoInfo {
        let props = properties(for: url)
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let aux = props[kCGImagePropertyExifAuxDictionary as String] as? [String: Any] ?? [:]
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])

        var width = props[kCGImagePropertyPixelWidth as String] as? Int ?? 0
        var height = props[kCGImagePropertyPixelHeight as String] as? Int ?? 0
        if let orientation = props[kCGImagePropertyOrientation as String] as? Int, (5...8).contains(orientation) {
            swap(&width, &height)
        }

        let exifDate = (exif[kCGImagePropertyExifDateTimeOriginal as String] as? String).flatMap(exifDateFormatter.date(from:))
        let lens = exif[kCGImagePropertyExifLensModel as String] as? String
            ?? aux[kCGImagePropertyExifAuxLensModel as String] as? String

        return ImportedPhotoInfo(
            url: url,
            captureDate: exifDate ?? values?.creationDate,
            camera: cameraName(tiff),
            lens: lens,
            width: width,
            height: height,
            fileSize: Int64(values?.fileSize ?? 0)
        )
    }

    static func cameraName(_ tiff: [String: Any]) -> String? {
        let make = (tiff[kCGImagePropertyTIFFMake as String] as? String)?.trimmingCharacters(in: .whitespaces)
        guard let model = (tiff[kCGImagePropertyTIFFModel as String] as? String)?.trimmingCharacters(in: .whitespaces) else { return make }
        guard let make, !model.lowercased().hasPrefix(make.lowercased().split(separator: " ").first.map(String.init) ?? "") else { return model }
        return "\(make) \(model)"
    }

    static func details(for url: URL) -> [MetadataField] {
        let info = basicInfo(for: url)
        let exif = properties(for: url)[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        var fields: [MetadataField] = []
        func add(_ key: String, _ value: String?) {
            if let value, !value.isEmpty { fields.append(MetadataField(id: key, value: value)) }
        }

        add("meta.file", url.lastPathComponent)
        add("meta.date", info.captureDate?.formatted(date: .abbreviated, time: .standard))
        add("meta.dimensions", info.width > 0 ? "\(info.width) × \(info.height)" : nil)
        add("meta.size", ByteCountFormatter.string(fromByteCount: info.fileSize, countStyle: .file))
        add("meta.camera", info.camera)
        add("meta.lens", info.lens)
        if let t = exif[kCGImagePropertyExifExposureTime as String] as? Double, t > 0 {
            add("meta.shutter", t < 1 ? "1/\(Int((1 / t).rounded())) s" : String(format: "%.1f s", t))
        }
        if let f = exif[kCGImagePropertyExifFNumber as String] as? Double {
            add("meta.aperture", String(format: "f/%.1f", f))
        }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int])?.first {
            add("meta.iso", "ISO \(iso)")
        }
        if let focal = exif[kCGImagePropertyExifFocalLength as String] as? Double {
            add("meta.focal", String(format: "%.0f mm", focal))
        }

        if let xmp = MetadataWriter.readMetadata(for: url) {
            add("meta.title", xmpString(xmp, "dc:title"))
            add("meta.caption", xmpString(xmp, "dc:description"))
            add("meta.creator", xmpString(xmp, "dc:creator"))
            add("meta.copyright", xmpString(xmp, "dc:rights"))
            add("meta.keywords", xmpString(xmp, "dc:subject"))
            add("meta.city", xmpString(xmp, "photoshop:City"))
            add("meta.country", xmpString(xmp, "photoshop:Country"))
        }
        return fields
    }

    static func xmpString(_ metadata: CGImageMetadata, _ path: String) -> String? {
        guard let tag = CGImageMetadataCopyTagWithPath(metadata, nil, path as CFString) else { return nil }
        return stringValue(of: tag)
    }

    private static func stringValue(of object: AnyObject) -> String? {
        if CFGetTypeID(object) == CGImageMetadataTagGetTypeID() {
            // swiftlint:disable:next force_cast
            let tag = object as! CGImageMetadataTag
            guard let value = CGImageMetadataTagCopyValue(tag) else { return nil }
            return stringValue(of: value)
        }
        if let string = object as? String { return string }
        if let array = object as? [AnyObject] {
            let parts = array.compactMap { stringValue(of: $0) }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
        if let dict = object as? [String: AnyObject] {
            return (dict["x-default"] ?? dict.values.first).flatMap { stringValue(of: $0) }
        }
        return nil
    }
}
