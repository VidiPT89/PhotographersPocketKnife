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
        // Capturas para a App Store: fotos reais de uma pasta em vez dos padrões de teste.
        if let folder = ProcessInfo.processInfo.environment["PPK_DEMO_PHOTOS"] {
            for (index, url) in PhotoImporter.imageFiles(in: URL(fileURLWithPath: folder)).enumerated() {
                let photo = Photo(info: MetadataReader.basicInfo(for: url), sessionName: "Estoril Open")
                photo.rating = [5, 4, 3, 5, 2, 4, 0, 3][index % 8]
                if index % 4 == 0 { photo.flag = .pick }
                if index % 5 == 2 { photo.colorLabel = .green }
                container.mainContext.insert(photo)
            }
            let desk = UploadDestination(name: "Newsdesk", transferProtocol: .sftp)
            desk.host = "ftp.newsdesk.example"; desk.username = "photographer"; desk.remoteFolderTemplate = "/{date}/{event}"
            container.mainContext.insert(desk)
            let agency = UploadDestination(name: "Agency archive", transferProtocol: .s3)
            agency.host = "s3.eu-west-1.amazonaws.com"; agency.bucket = "agency-archive"; agency.region = "eu-west-1"
            container.mainContext.insert(agency)
            try container.mainContext.save()
            return
        }
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
                ZStack {
                    if app.isSplashVisible {
                        SplashScreenView {
                            withAnimation(.easeOut(duration: 0.5)) { app.isSplashVisible = false }
                        }
                        .statusBarHidden()
                        .transition(.opacity)
                    } else {
                        MobileRoot().transition(.opacity)
                    }
                }
                .environment(app).modelContainer(container)
                .preferredColorScheme(app.theme.colorScheme).tint(Brand.orange)
            case .failure(let error):
                ContentUnavailableView("Cannot open catalog", systemImage: "externaldrive.badge.exclamationmark", description: Text(error.localizedDescription))
            }
        }
    }
}
