import Foundation
import SwiftData
import CoreImage
import ImageIO
import UniformTypeIdentifiers

extension ImageRenderer {
    /// Cópia sem ruído ao lado do original: TIFF de 16 bits terminado em `-DN`, com os metadados do original.
    func denoiseToTIFF(url: URL, strength: Double) throws -> URL {
        let source: CIImage? = PhotoImporter.isRaw(url)
            ? decodeRAW(url, maxPixel: nil, lensCorrection: true)
            : CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
        guard let source else { throw ExportError.unreadable(url.lastPathComponent) }
        var image = WaveletDenoise.apply(source, strength: strength)
        let extent = image.extent
        image = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))

        let name = url.deletingPathExtension().lastPathComponent + "-DN"
        let target = PhotoImporter.uniqueURL(url.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension("tif"))
        guard let space = CGColorSpace(name: CGColorSpace.displayP3),
              let cgImage = context.createCGImage(image, from: image.extent.integral, format: .RGBA16, colorSpace: space),
              let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.tiff.identifier as CFString, 1, nil) else {
            throw ExportError.cannotWrite(url.lastPathComponent)
        }
        var properties = Self.metadata(from: MetadataReader.properties(for: url), rule: .all)
        properties[kCGImagePropertyOrientation] = 1
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ExportError.cannotWrite(url.lastPathComponent) }
        return target
    }
}

/// Redução de ruído em segundo plano: uma foto de cada vez, sem bloquear a seleção nem a edição.
@Observable
@MainActor
final class DenoiseQueue {
    struct Job: Sendable {
        let url: URL
        let strength: Double
    }

    private(set) var total = 0
    private(set) var completed = 0
    private(set) var failed = 0

    var isRunning: Bool { total > 0 && completed + failed < total }
    var progress: Double { total == 0 ? 0 : Double(completed + failed) / Double(total) }

    @ObservationIgnored var onFinished: ((Int, Int) -> Void)?

    func start(_ jobs: [Job], session: String, culling: CullingModel, context: ModelContext) {
        guard !jobs.isEmpty, !isRunning else { return }
        total = jobs.count
        completed = 0
        failed = 0
        Task {
            var outputs: [URL] = []
            for job in jobs {
                let output = await Task.detached(priority: .utility) {
                    try? ImageRenderer.shared.denoiseToTIFF(url: job.url, strength: job.strength)
                }.value
                if let output {
                    outputs.append(output)
                    completed += 1
                } else {
                    failed += 1
                }
            }
            if !outputs.isEmpty {
                await culling.importFiles(outputs, options: .init(copyDestination: nil), session: session, context: context)
            }
            onFinished?(completed, failed)
        }
    }
}
