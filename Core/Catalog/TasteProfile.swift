import Foundation
import Vision

/// O gosto de um fotógrafo na seleção, aprendido com as escolhas dele.
struct TasteProfile: StoredProfile {
    static let folderName = "Taste"
    var id = UUID()
    var name: String
    /// Regressão logística: `weights[0]` é o termo independente.
    var weights: [Double]
    var means: [Double]
    var scales: [Double]
    /// Impressões digitais de fotos que escolheu e que rejeitou (semelhança visual ao que costuma ficar).
    var keeperPrints: [Data]
    var rejectPrints: [Data]
    var keepers: Int
    var rejects: Int
}

struct TasteExample: Sendable {
    let candidate: CullCandidate
    let keeper: Bool
}

/// Aprende e aplica o gosto do fotógrafo, no próprio Mac.
enum TasteLearner {
    static let minimumPerClass = 8
    static let featureCount = 12

    /// Características de cada foto dentro da sessão: a nitidez e a posição no momento são relativas às outras.
    static func features(for candidates: [CullCandidate], report: CullReport) -> [UUID: [Double]] {
        guard !candidates.isEmpty else { return [:] }
        let logs = candidates.map { log1p(max($0.assessment.sharpness, 0)) }.sorted()
        let median = max(logs[logs.count / 2], 1e-6)
        var rank: [UUID: Double] = [:], size: [UUID: Double] = [:]
        for group in Dictionary(grouping: candidates, by: { report.moments[$0.id] ?? 0 }).values {
            let sorted = group.sorted { $0.assessment.sharpness > $1.assessment.sharpness }
            for (index, candidate) in sorted.enumerated() {
                rank[candidate.id] = group.count > 1 ? Double(index) / Double(group.count - 1) : 0
                size[candidate.id] = log(Double(group.count))
            }
        }
        var result: [UUID: [Double]] = [:]
        for candidate in candidates {
            let a = candidate.assessment
            result[candidate.id] = [
                log1p(max(a.sharpness, 0)) / median,
                a.faces > 0 ? 1 : 0,
                a.faces > 0 ? Double(a.closedEyes) / Double(a.faces) : 0,
                a.faceQuality ?? 0.5,
                a.aesthetics ?? 0,
                a.brightness,
                abs(a.brightness - 0.45),
                a.clippedHighlights,
                a.clippedShadows,
                a.isUtility ? 1 : 0,
                rank[candidate.id] ?? 0,
                size[candidate.id] ?? 0,
            ]
        }
        return result
    }

    static func train(name: String, examples: [TasteExample], report: CullReport) -> TasteProfile? {
        let keepers = examples.filter(\.keeper), rejects = examples.filter { !$0.keeper }
        guard keepers.count >= minimumPerClass, rejects.count >= minimumPerClass else { return nil }
        let table = features(for: examples.map(\.candidate), report: report)
        let rows = examples.compactMap { example in table[example.candidate.id].map { ($0, example.keeper ? 1.0 : 0.0) } }
        let n = featureCount

        var means = [Double](repeating: 0, count: n), scales = [Double](repeating: 1, count: n)
        for j in 0..<n {
            let column = rows.map { $0.0[j] }
            let mean = column.reduce(0, +) / Double(column.count)
            let deviation = (column.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(column.count)).squareRoot()
            means[j] = mean
            scales[j] = deviation > 1e-6 ? deviation : 1
        }
        let x = rows.map { row in (0..<n).map { (row.0[$0] - means[$0]) / scales[$0] } }
        let y = rows.map(\.1)
        // Classes equilibradas: rejeitar muito não pode ensinar a rejeitar tudo.
        let keeperWeight = Double(rows.count) / (2 * Double(keepers.count))
        let rejectWeight = Double(rows.count) / (2 * Double(rejects.count))

        var w = [Double](repeating: 0, count: n + 1)
        for _ in 0..<600 {
            var gradient = [Double](repeating: 0, count: n + 1)
            for (i, row) in x.enumerated() {
                var z = w[0]
                for j in 0..<n { z += w[j + 1] * row[j] }
                let error = (sigmoid(z) - y[i]) * (y[i] == 1 ? keeperWeight : rejectWeight)
                gradient[0] += error
                for j in 0..<n { gradient[j + 1] += error * row[j] }
            }
            for j in 0...n {
                w[j] -= 0.5 * (gradient[j] / Double(x.count) + (j > 0 ? 0.01 * w[j] : 0))
            }
        }
        func prints(_ list: [TasteExample]) -> [Data] {
            Array(list.compactMap(\.candidate.assessment.featurePrint).prefix(150))
        }
        return TasteProfile(name: name, weights: w, means: means, scales: scales,
                            keeperPrints: prints(keepers), rejectPrints: prints(rejects), keepers: keepers.count, rejects: rejects.count)
    }

    /// Probabilidade (0…1) de o fotógrafo ficar com cada foto.
    static func probabilities(_ profile: TasteProfile, candidates: [CullCandidate], report: CullReport) -> [UUID: Double] {
        let table = features(for: candidates, report: report)
        let keeperPrints = profile.keeperPrints.compactMap(decode), rejectPrints = profile.rejectPrints.compactMap(decode)
        var result: [UUID: Double] = [:]
        for candidate in candidates {
            guard let row = table[candidate.id], profile.weights.count == row.count + 1,
                  profile.means.count == row.count, profile.scales.count == row.count else { continue }
            var z = profile.weights[0]
            for j in row.indices { z += profile.weights[j + 1] * (row[j] - profile.means[j]) / profile.scales[j] }
            var probability = sigmoid(z)
            if let print = candidate.assessment.featurePrint.flatMap(decode), !keeperPrints.isEmpty, !rejectPrints.isEmpty {
                let closeness = nearest(print, rejectPrints) - nearest(print, keeperPrints)
                probability = 0.6 * probability + 0.4 * sigmoid(closeness * 8)
            }
            result[candidate.id] = probability
        }
        return result
    }

    /// `DSC_1234.NEF` corresponde a `DSC_1234.jpg`, `DSC_1234-Edit.jpg` ou `DSC_1234 (2).jpg`, mas não a `DSC_12345.jpg`.
    static func isMatch(original fileName: String, deliveredBase: String) -> Bool {
        let base = (fileName as NSString).deletingPathExtension.lowercased()
        let delivered = deliveredBase.lowercased()
        guard delivered.hasPrefix(base) else { return false }
        guard let next = delivered.dropFirst(base.count).first else { return true }
        return [" ", "-", "_", "(", "."].contains(next)
    }

    static func matches(_ fileName: String, delivered: [String]) -> Bool {
        delivered.contains { isMatch(original: fileName, deliveredBase: $0) }
    }

    private static func sigmoid(_ z: Double) -> Double {
        1 / (1 + exp(-max(min(z, 30), -30)))
    }

    private static func nearest(_ print: VNFeaturePrintObservation, _ others: [VNFeaturePrintObservation]) -> Double {
        let distances = others.compactMap { other -> Double? in
            var value: Float = 0
            return (try? print.computeDistance(&value, to: other)) != nil ? Double(value) : nil
        }.sorted()
        let closest = distances.prefix(5)
        return closest.isEmpty ? 1 : closest.reduce(0, +) / Double(closest.count)
    }

    private static func decode(_ data: Data) -> VNFeaturePrintObservation? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
    }
}
