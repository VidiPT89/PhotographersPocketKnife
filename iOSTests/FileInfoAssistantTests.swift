import XCTest
import FoundationModels
@testable import PhotographersPocketKnife

final class FileInfoAssistantTests: XCTestCase {
    func testEntriesFollowFormOrderAndSkipEmptyValues() {
        let proposal = FileInfoProposal(headline: "Benfica beat Porto", caption: "", event: "Liga Portugal",
                                        city: " Lisbon ", people: ["Vangelis Pavlidis", ""], keywords: ["football", "Football"])
        XCTAssertEqual(proposal.entries.map(\.spec.name), ["headline", "keywords", "event", "personShown", "city"])
        XCTAssertEqual(proposal.entries.first { $0.spec.name == "city" }?.value, "Lisbon")
        XCTAssertEqual(proposal.entries.first { $0.spec.name == "keywords" }?.value, "football")
        XCTAssertTrue(FileInfoProposal(caption: "  ").isEmpty)
    }

    func testApplyMergesListsAndOnlyMarksRealChanges() {
        var fields = IPTCFields()
        fields.keywords = "sport, Benfica"
        fields.city = "Lisbon"
        fields.creator = "David Martins"
        let proposal = FileInfoProposal(caption: "Pavlidis scores.", city: "Lisbon", people: ["Pavlidis"], keywords: ["benfica", "goal"])
        let result = proposal.applied(to: fields)
        XCTAssertEqual(result.fields.keywords, "sport, Benfica, goal")
        XCTAssertEqual(result.fields.caption, "Pavlidis scores.")
        XCTAssertEqual(result.fields.personShown, "Pavlidis")
        XCTAssertEqual(result.fields.creator, "David Martins")
        XCTAssertEqual(result.changed, ["caption", "keywords", "personShown"])
    }

    func testPromptCarriesNotesAndKnownDetailsAndInstructionsForbidInvention() {
        var fields = IPTCFields()
        fields.event = "Benfica v Porto"
        let prompt = FileInfoProposal.prompt(notes: " golo do Pavlidis aos 23 minutos ", date: Date(timeIntervalSince1970: 0),
                                             camera: "Nikon Z9", fields: fields, sceneKeywords: ["stadium"])
        XCTAssertTrue(prompt.contains("golo do Pavlidis aos 23 minutos\n"))
        XCTAssertTrue(prompt.contains("Camera: Nikon Z9"))
        XCTAssertTrue(prompt.contains("Event: Benfica v Porto"))
        XCTAssertTrue(prompt.contains("Detected in the image: stadium"))
        XCTAssertTrue(FileInfoProposal.instructions(portuguese: true).contains("Never invent"))
        XCTAssertTrue(FileInfoProposal.instructions(portuguese: true).contains("Portugal"))
        XCTAssertTrue(FileInfoProposal.prompt(notes: "x", date: nil, camera: nil, fields: IPTCFields(), sceneKeywords: []).contains("none"))
    }

    /// Corre o modelo da Apple Intelligence a sério, num iPhone que o tenha; no simulador e sem ele o teste é ignorado.
    @available(iOS 26, *)
    func testOnDeviceModelFillsFieldsFromPortugueseNotesWithoutInventing() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("The simulator reports the model as available but cannot load its safety assets")
        #else
        let model = SystemLanguageModel.default
        try XCTSkipUnless(FileInfoAI.isAvailable(portuguese: true),
                          "Apple Intelligence is not available: \(model.availability), pt-PT \(model.supportsLocale(Locale(identifier: "pt-PT")))")
        let proposal = try await FileInfoAI.propose(
            notes: "Benfica contra o Porto no Estádio da Luz, em Lisboa. Golo do Pavlidis aos 23 minutos, festeja com os adeptos.",
            date: nil, camera: nil, fields: IPTCFields(), sceneKeywords: [], portuguese: true)
        print("AI proposal:", proposal)
        XCTAssertFalse(proposal.caption.isEmpty)
        XCTAssertTrue(proposal.caption.contains("Pavlidis"))
        XCTAssertTrue((proposal.city + proposal.sublocation + proposal.caption).contains("Lisboa") || proposal.city.contains("Lisbo"))
        XCTAssertTrue(proposal.people.contains { $0.contains("Pavlidis") })
        let invented = ["Vangelis", "Evangelos", "2-", "1-0", "2-1"].filter { (proposal.caption + proposal.headline).contains($0) }
        XCTAssertEqual(invented, [], "The model added facts that are not in the notes")
        #endif
    }
}
