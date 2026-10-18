import SwiftUI
import SwiftData
import CoreImage
import ImageIO
import UniformTypeIdentifiers

@main
struct MobileApp: App {
    @State private var app: AppState
    private let storage: Result<ModelContainer, Error>
    init() {
        #if DEBUG
        let testing = ProcessInfo.processInfo.arguments.contains("-ppk-ui-testing")
        let defaults = testing ? UserDefaults(suiteName: "PPK-Mobile-UI-Tests")! : .standard
        if testing { defaults.removePersistentDomain(forName: "PPK-Mobile-UI-Tests") }
        if testing && ProcessInfo.processInfo.arguments.contains("-ppk-light-testing") {
            defaults.set("light", forKey: "app.theme")
        }
        #else
        let testing = false
        let defaults = UserDefaults.standard
        #endif
        _app = State(initialValue: AppState(defaults: defaults))
        storage = Result {
            let url = CatalogStore.url
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let schema = Schema([Photo.self, UploadDestination.self, UploadRecord.self, EditPreset.self])
            let config = testing ? ModelConfiguration(schema: schema, isStoredInMemoryOnly: true) : ModelConfiguration(schema: schema, url: url)
            let container = try ModelContainer(for: schema, configurations: config)
            #if DEBUG
            if testing { try Self.seed(container) }
            #endif
            return container
        }
    }
    #if DEBUG
    @MainActor private static func seed(_ container: ModelContainer) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PPK-UI-Fixtures")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 1...4 {
            let url = directory.appendingPathComponent("Shoot-0\(index).jpg")
            let filter = CIFilter(name: "CICheckerboardGenerator", parameters: ["inputColor0": CIColor(red: 0.2, green: Double(index) * 0.15, blue: 0.4), "inputColor1": CIColor(red: 0.85, green: 0.6, blue: Double(index) * 0.1), "inputWidth": 90])!
            let image = filter.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 800, height: 600))
            let cg = ImageRenderer.shared.context.createCGImage(image, from: image.extent)!
            let writer = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(writer, cg, nil); CGImageDestinationFinalize(writer)
            let photo = Photo(info: MetadataReader.basicInfo(for: url), sessionName: "Test shoot")
            photo.rating = index
            container.mainContext.insert(photo)
        }
        let destination = UploadDestination(name: "Custom port fixture", transferProtocol: .ftp)
        destination.host = "127.0.0.1"; destination.port = 12121; destination.username = "fixture"
        container.mainContext.insert(destination)
        try container.mainContext.save()
    }
    #endif
    var body: some Scene {
        WindowGroup {
            switch storage {
            case .success(let container):
                MobileRoot().environment(app).modelContainer(container)
                    .preferredColorScheme(app.theme.colorScheme).tint(Brand.orange)
            case .failure(let error):
                ContentUnavailableView("Cannot open catalog", systemImage: "externaldrive.badge.exclamationmark", description: Text(error.localizedDescription))
            }
        }
    }
}
