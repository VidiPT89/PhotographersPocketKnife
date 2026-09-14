import Foundation
import os

/// Tempos das operações pesadas, marcados com `OSSignposter` (visíveis no Instruments) e resumidos no painel de diagnóstico (⌥⌘D).
final class Diagnostics: @unchecked Sendable {
    static let shared = Diagnostics()

    enum Operation: String, CaseIterable, Sendable {
        case thumbnail, preview, export, importFile
        var labelKey: String { "diagnostics.\(rawValue)" }
    }

    struct Stat: Sendable, Equatable {
        var count = 0
        var total = 0.0
        var last = 0.0
        var max = 0.0
        var average: Double { count == 0 ? 0 : total / Double(count) }
    }

    private let signposter = OSSignposter(subsystem: "dev.ividi.PhotographersPocketKnife", category: .pointsOfInterest)
    private let lock = NSLock()
    private var stats: [Operation: Stat] = [:]

    func measure<T>(_ operation: Operation, _ body: () throws -> T) rethrows -> T {
        let name = signpostName(operation)
        let state = signposter.beginInterval(name)
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            signposter.endInterval(name, state)
            record(operation, milliseconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        return try body()
    }

    func record(_ operation: Operation, milliseconds: Double) {
        lock.withLock {
            var stat = stats[operation] ?? Stat()
            stat.count += 1
            stat.total += milliseconds
            stat.last = milliseconds
            stat.max = Swift.max(stat.max, milliseconds)
            stats[operation] = stat
        }
    }

    func snapshot() -> [Operation: Stat] {
        lock.withLock { stats }
    }

    func reset() {
        lock.withLock { stats = [:] }
    }

    /// Memória física usada pela app (a mesma métrica do Monitor de Atividade).
    static var memoryFootprint: UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private func signpostName(_ operation: Operation) -> StaticString {
        switch operation {
        case .thumbnail: "thumbnail"
        case .preview: "preview"
        case .export: "export"
        case .importFile: "import"
        }
    }
}
