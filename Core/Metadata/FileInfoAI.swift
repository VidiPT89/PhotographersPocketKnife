import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Preenche o file info com o modelo da Apple Intelligence, no próprio aparelho. Sem ele, o assistente fica só com o ditado.
enum FileInfoAI {
    enum Status { case ready, preparing, unavailable }

    static func status(portuguese: Bool) -> Status {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            let model = SystemLanguageModel.default
            guard model.supportsLocale(Locale(identifier: portuguese ? "pt-PT" : "en-US")) else { return .unavailable }
            switch model.availability {
            case .available: return .ready
            // O Apple Intelligence está ligado mas o modelo ainda se está a descarregar.
            case .unavailable(.modelNotReady): return .preparing
            default: return .unavailable
            }
        }
        #endif
        return .unavailable
    }

    static func isAvailable(portuguese: Bool) -> Bool { status(portuguese: portuguese) == .ready }

    static func propose(notes: String, date: Date?, camera: String?, fields: IPTCFields,
                        sceneKeywords: [String], portuguese: Bool) async throws -> FileInfoProposal {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            let session = LanguageModelSession(instructions: FileInfoProposal.instructions(portuguese: portuguese))
            let prompt = FileInfoProposal.prompt(notes: notes, date: date, camera: camera, fields: fields, sceneKeywords: sceneKeywords)
            let draft = try await session.respond(to: prompt, generating: FileInfoDraft.self).content
            return FileInfoProposal(headline: draft.headline, caption: draft.caption, event: draft.event,
                                    sublocation: draft.place, city: draft.city, country: draft.country,
                                    people: draft.people, keywords: draft.keywords)
        }
        #endif
        throw CocoaError(.featureUnsupported)
    }
}

#if canImport(FoundationModels)
@available(iOS 26, macOS 26, *)
@Generable
struct FileInfoDraft {
    @Guide(description: "Short headline of at most ten words, or empty")
    var headline: String
    @Guide(description: "Caption of one or two sentences: who, what, where, when. Only facts from the notes")
    var caption: String
    @Guide(description: "Name of the event, match or competition, or empty")
    var event: String
    @Guide(description: "Venue or specific place, such as a stadium or street, or empty")
    var place: String
    @Guide(description: "City, or empty")
    var city: String
    @Guide(description: "Country, or empty")
    var country: String
    @Guide(description: "Full names of the people the notes say are in the photograph", .maximumCount(10))
    var people: [String]
    @Guide(description: "Search keywords about the subject, people, place and event", .maximumCount(12))
    var keywords: [String]
}
#endif
