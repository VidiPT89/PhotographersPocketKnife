import Foundation

enum CullIssue: String, Codable, CaseIterable, Identifiable, Sendable {
    case blurry, eyesClosed, underexposed, overexposed, document
    var id: String { rawValue }
    var labelKey: String { "cull.issue.\(rawValue)" }

    var icon: String {
        switch self {
        case .blurry: "circle.dotted"
        case .eyesClosed: "eye.slash.fill"
        case .underexposed: "moon.fill"
        case .overexposed: "sun.max.fill"
        case .document: "doc.text.fill"
        }
    }
}

struct CullCandidate: Sendable {
    let id: UUID
    let date: Date?
    let fileName: String
    let rating: Int
    let flag: PhotoFlag
    let assessment: PhotoAssessment
}

struct CullOptions: Sendable {
    /// Quantas fotos ficam escolhidas em cada momento.
    var keepPerMoment = 1
    var rejectProblems = true
    var assignStars = true
    /// Fotos que já têm estrelas ou marcação ficam como estão.
    var keepManualDecisions = true
    /// Fotos com mais de X segundos de intervalo são momentos diferentes.
    var momentGap: TimeInterval = 8
    /// Distância máxima entre impressões digitais para duas fotos serem do mesmo momento.
    var similarity: Float = 0.6
    /// 0 = exigente com o desfoque, 1 = tolerante.
    var blurTolerance = 0.5
}

struct CullReport: Sendable {
    var scores: [UUID: Double] = [:]
    var issues: [UUID: [CullIssue]] = [:]
    var moments: [UUID: Int] = [:]
    var best: Set<UUID> = []
    var momentCount = 0
    /// Probabilidade de o fotógrafo ficar com a foto, quando há um perfil de gosto.
    var taste: [UUID: Double] = [:]
}

struct CullDecision: Equatable, Sendable {
    var rating: Int
    var flag: PhotoFlag
}

/// O que a grelha e o painel mostram de cada foto.
struct CullBadge: Equatable, Sendable {
    let score: Double
    let issues: [CullIssue]
    let isBest: Bool
    let moment: Int
}

/// Seleção inteligente: agrupa as fotos por momento, pontua-as dentro da sessão e decide as melhores.
enum SmartCull {
    /// Problemas que impedem uma foto de ser a escolhida do momento.
    static let disqualifying: Set<CullIssue> = [.blurry, .eyesClosed, .document]

    static func evaluate(_ candidates: [CullCandidate], options: CullOptions, distance: (CullCandidate, CullCandidate) -> Float?,
                         taste: TasteProfile? = nil) -> CullReport {
        var report = CullReport()
        guard !candidates.isEmpty else { return report }

        // 1. Momentos: fotos seguidas, próximas no tempo e parecidas entre si.
        let ordered = candidates.enumerated().sorted { a, b in
            switch (a.element.date, b.element.date) {
            case let (x?, y?) where x != y: x < y
            case (nil, .some): false
            case (.some, nil): true
            default: a.offset < b.offset
            }
        }.map(\.element)
        var moment = 0
        for (index, candidate) in ordered.enumerated() {
            if index > 0 {
                let previous = ordered[index - 1]
                let gap = previous.date.flatMap { start in candidate.date.map { $0.timeIntervalSince(start) } }
                let split: Bool
                switch (gap, distance(previous, candidate)) {
                case let (gap?, difference?): split = gap > options.momentGap || difference > options.similarity
                case let (gap?, nil): split = gap > options.momentGap / 2
                case let (nil, difference?): split = difference > options.similarity
                case (nil, nil): split = true
                }
                if split { moment += 1 }
            }
            report.moments[candidate.id] = moment
        }
        report.momentCount = moment + 1

        // 2. Problemas e pontuação. A nitidez é comparada com a mediana da sessão (câmaras e lentes diferentes).
        let logs = candidates.map { log1p(max($0.assessment.sharpness, 0)) }.sorted()
        let median = logs[logs.count / 2]
        let blurLimit = 0.62 + (0.5 - options.blurTolerance) * 0.3
        let absoluteBlur = 15 * (1.5 - options.blurTolerance)
        for candidate in candidates {
            let a = candidate.assessment
            let relative = median > 0 ? log1p(max(a.sharpness, 0)) / median : 1
            var issues: [CullIssue] = []
            if a.sharpness < absoluteBlur || (candidates.count >= 3 && relative < blurLimit) { issues.append(.blurry) }
            if a.faces > 0, a.closedEyes > 0 { issues.append(.eyesClosed) }
            if a.brightness < 0.12, a.clippedShadows > 0.3 { issues.append(.underexposed) }
            if a.clippedHighlights > 0.2 || a.brightness > 0.9 { issues.append(.overexposed) }
            if a.isUtility { issues.append(.document) }

            let sharpScore = candidates.count >= 3 ? min(relative, 1.25) / 1.25 : 1 - exp(-a.sharpness / 150)
            let exposureScore = max(0, 1 - abs(a.brightness - 0.45) * 1.6 - a.clippedHighlights * 2 - max(a.clippedShadows - 0.1, 0))
            let faceScore = a.faceQuality ?? 0.5
            let aestheticScore = a.aesthetics.map { ($0 + 1) / 2 } ?? 0.5
            let closedShare = a.faces > 0 ? Double(a.closedEyes) / Double(a.faces) : 0
            var score = 0.4 * sharpScore + 0.2 * exposureScore + 0.2 * faceScore + 0.2 * aestheticScore - 0.3 * closedShare
            if issues.contains(.blurry) { score -= 0.15 }
            if issues.contains(.document) { score -= 0.3 }
            report.scores[candidate.id] = min(max(score, 0), 1)
            if !issues.isEmpty { report.issues[candidate.id] = issues }
        }

        // 3. Com um perfil de gosto, o que o fotógrafo costuma escolher pesa mais do que os critérios técnicos.
        if let taste {
            report.taste = TasteLearner.probabilities(taste, candidates: candidates, report: report)
            for (id, probability) in report.taste {
                report.scores[id] = min(max(0.35 * (report.scores[id] ?? 0) + 0.65 * probability, 0), 1)
            }
        }

        // 4. As melhores de cada momento, entre as que não têm problemas graves.
        for group in Dictionary(grouping: candidates, by: { report.moments[$0.id] ?? 0 }).values {
            let eligible = group
                .filter { Set(report.issues[$0.id] ?? []).isDisjoint(with: disqualifying) }
                .sorted { a, b in
                    let sa = report.scores[a.id] ?? 0, sb = report.scores[b.id] ?? 0
                    return sa != sb ? sa > sb : a.fileName < b.fileName
                }
            report.best.formUnion(eligible.prefix(max(options.keepPerMoment, 1)).map(\.id))
        }
        return report
    }

    /// Classificação automática: as melhores ficam escolhidas (com estrelas), as falhadas rejeitadas.
    static func decisions(for candidates: [CullCandidate], report: CullReport, options: CullOptions) -> [UUID: CullDecision] {
        var result: [UUID: CullDecision] = [:]
        for candidate in candidates {
            if options.keepManualDecisions, candidate.rating > 0 || candidate.flag != .none { continue }
            if report.best.contains(candidate.id) {
                let rating = options.assignStars ? stars(for: report.scores[candidate.id] ?? 0) : candidate.rating
                result[candidate.id] = CullDecision(rating: rating, flag: .pick)
            } else if options.rejectProblems,
                      !(report.issues[candidate.id] ?? []).isEmpty || (report.taste[candidate.id].map { $0 < 0.3 } ?? false) {
                result[candidate.id] = CullDecision(rating: candidate.rating, flag: .reject)
            }
        }
        return result
    }

    static func stars(for score: Double) -> Int {
        switch score {
        case 0.8...: 5
        case 0.65..<0.8: 4
        case 0.5..<0.65: 3
        default: 2
        }
    }
}
