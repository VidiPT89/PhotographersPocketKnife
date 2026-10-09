import Foundation

/// Com App Sandbox (versão da Mac App Store), uma pasta escolhida pelo utilizador só fica acessível até a app fechar.
/// Guarda-se um bookmark com âmbito de segurança de cada pasta ou ficheiro que o utilizador dá à app,
/// e no arranque reabre-se o acesso, para o catálogo, as pastas vigiadas e a fila de envios continuarem a funcionar.
final class FolderAccess: @unchecked Sendable {
    static let shared = FolderAccess(enabled: isSandboxed)

    static var isSandboxed: Bool { ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil }

    private let enabled: Bool
    private let storeURL: URL
    private let lock = NSLock()
    private var bookmarks: [String: Data] = [:]
    private var active: [String: URL] = [:]

    init(enabled: Bool, storeURL: URL? = nil) {
        self.enabled = enabled
        self.storeURL = storeURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotographersPocketKnife/FolderAccess.plist")
    }

    /// Caminhos com acesso guardado (ordenados), para diagnóstico e testes.
    var rememberedPaths: [String] {
        lock.withLock { bookmarks.keys.sorted() }
    }

    /// Guarda o acesso a URLs que o utilizador acabou de dar à app (painel, arrastar, Finder).
    /// Um URL já coberto por uma pasta guardada não precisa de bookmark próprio.
    func remember(_ urls: [URL]) {
        guard enabled else { return }
        var changed = false
        lock.withLock {
            for url in urls.map(\.standardizedFileURL) where !isCovered(url.path) {
                guard let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else { continue }
                bookmarks[url.path] = data
                changed = true
            }
        }
        if changed { save() }
    }

    func remember(_ url: URL) { remember([url]) }

    /// Reabre o acesso a tudo o que foi guardado. Bookmarks que já não resolvem (pasta apagada) são descartados.
    func restore() {
        guard enabled else { return }
        load()
        var changed = false
        lock.withLock {
            for (path, data) in bookmarks where active[path] == nil {
                var stale = false
                guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else {
                    bookmarks[path] = nil
                    changed = true
                    continue
                }
                guard url.startAccessingSecurityScopedResource() else { continue }
                active[path] = url
                if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                    bookmarks[path] = fresh
                    changed = true
                }
            }
        }
        if changed { save() }
    }

    private func isCovered(_ path: String) -> Bool {
        bookmarks.keys.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let stored = try? PropertyListDecoder().decode([String: Data].self, from: data) else { return }
        lock.withLock { bookmarks.merge(stored) { current, _ in current } }
    }

    private func save() {
        let snapshot = lock.withLock { bookmarks }
        guard let data = try? PropertyListEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
    }
}
