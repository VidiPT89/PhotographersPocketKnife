import Foundation

/// Ficheiros iguais (mesmo conteúdo), mesmo com nomes ou pastas diferentes — ex. o mesmo cartão importado duas vezes.
enum ExactDuplicates {
    struct Item: Sendable {
        let id: UUID
        let url: URL
        let size: Int64
    }

    /// Só calcula o SHA-256 dos ficheiros que partilham o tamanho com outro. Devolve id → número do grupo.
    static func groups(_ items: [Item]) -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        var next = 0
        let buckets = Dictionary(grouping: items.filter { $0.size > 0 }, by: \.size)
            .values
            .filter { $0.count > 1 }
            .sorted { $0[0].url.path < $1[0].url.path }
        for bucket in buckets {
            let hashed = bucket.compactMap { item in (try? FileChecksum.sha256(of: item.url)).map { (item: item, hash: $0) } }
            let byHash = Dictionary(grouping: hashed, by: \.hash)
                .values
                .filter { $0.count > 1 }
                .sorted { $0[0].item.url.path < $1[0].item.url.path }
            for group in byHash {
                group.forEach { result[$0.item.id] = next }
                next += 1
            }
        }
        return result
    }
}
