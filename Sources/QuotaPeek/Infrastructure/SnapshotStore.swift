import Foundation

enum SnapshotStore {
    private static var fileURL: URL? {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return root.appendingPathComponent("QuotaPeek", isDirectory: true)
            .appendingPathComponent("snapshots.json")
    }

    static func load() -> [ProviderSnapshot] {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let snapshots = try? JSONDecoder().decode([ProviderSnapshot].self, from: data) else {
            return []
        }
        return snapshots
    }

    static func save(_ snapshots: [ProviderSnapshot]) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(snapshots) else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            // A cache failure must never prevent a live quota refresh.
        }
    }
}
