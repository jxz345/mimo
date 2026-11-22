import Foundation

/// A draft keeps the settings revision it loaded. Status polls cannot overwrite
/// edits or apply them on top of another account's changes.
struct MimoBypassDraft {
    var blocks: [MimoBypassBlock] = []
    var selected: UUID?
    private(set) var saved: [MimoBypassBlock] = []
    private(set) var revision: Int?
    var isDirty: Bool { blocks != saved }

    mutating func receive(_ state: DaemonState?, discard: Bool = false) {
        guard let state, state.initialized, revision == nil || discard || !isDirty else { return }
        blocks = state.settings.effectiveBypassBlocks; saved = blocks; revision = state.revision
        if !blocks.contains(where: { $0.id == selected }) { selected = blocks.first?.id }
    }
    func conflicts(with state: DaemonState?) -> Bool {
        guard isDirty, let revision, let state else { return false }
        return state.revision != revision
    }
}

