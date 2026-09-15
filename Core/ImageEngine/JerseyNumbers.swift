import Foundation
import CoreGraphics
import Vision

/// Números de camisola lidos na foto (Vision, no dispositivo), do maior para o mais pequeno.
enum JerseyNumbers {
    static func detect(in image: CGImage, minimumHeight: CGFloat = 0.03, limit: Int = 3) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = Float(minimumHeight)
        let handler = VNImageRequestHandler(cgImage: image)
        guard (try? handler.perform([request])) != nil, let observations = request.results else { return [] }

        var found: [(number: String, area: CGFloat)] = []
        for observation in observations {
            guard let text = observation.topCandidates(1).first?.string else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "#.")))
            guard (1...2).contains(trimmed.count), trimmed.allSatisfy({ $0.isASCII && $0.isNumber }),
                  observation.boundingBox.height >= minimumHeight, let value = Int(trimmed) else { continue }
            found.append((String(value), observation.boundingBox.width * observation.boundingBox.height))
        }
        var seen = Set<String>()
        return found
            .sorted { $0.area > $1.area }
            .map(\.number)
            .filter { seen.insert($0).inserted }
            .prefix(limit)
            .map { $0 }
    }

    /// Nomes a partir do plantel (substituições de código: `7<TAB>Cristiano Ronaldo`).
    static func players(_ numbers: [String], roster: CodeReplacements) -> [String] {
        numbers.compactMap { roster.value(for: $0) }
    }
}
