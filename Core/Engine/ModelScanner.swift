import Foundation

// MARK: - Model inventory

public enum ModelProvider: String, Sendable, CaseIterable {
    case ollama
    case lmStudio
    case huggingFace

    public var label: String {
        switch self {
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        case .huggingFace: "Hugging Face"
        }
    }

    public var symbol: String {
        switch self {
        case .ollama: "cube.transparent"
        case .lmStudio: "cpu"
        case .huggingFace: "face.smiling"
        }
    }
}

/// How a model is removed. Ollama owns a de-duplicated blob store, so the safe,
/// correct removal is its own `ollama rm` command — deleting blob files by hand
/// would corrupt its manifest view. File-based providers are removed by
/// trashing the model directory.
public enum ModelRemoval: Sendable, Equatable {
    case ollamaCommand(name: String)
    case trashDirectory(URL)
}

public struct LocalModel: Sendable, Identifiable, Equatable {
    public let id: String
    public let provider: ModelProvider
    public let name: String
    public let detail: String
    public let sizeBytes: Int64
    public let lastUsed: Date?
    /// Primary on-disk location (for "Reveal in Finder").
    public let location: URL
    public let removal: ModelRemoval

    public init(
        provider: ModelProvider,
        name: String,
        detail: String,
        sizeBytes: Int64,
        lastUsed: Date?,
        location: URL,
        removal: ModelRemoval
    ) {
        self.id = "\(provider.rawValue)|\(name)"
        self.provider = provider
        self.name = name
        self.detail = detail
        self.sizeBytes = sizeBytes
        self.lastUsed = lastUsed
        self.location = location
        self.removal = removal
    }
}

/// Read-only inventory of local LLM/ML models across providers. Never deletes.
public enum ModelScanner {
    public static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [LocalModel] {
        var models: [LocalModel] = []
        models += scanOllama(home: home)
        models += scanLMStudio(home: home)
        models += scanHuggingFace(home: home)
        return models.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    // MARK: Ollama

    private struct OllamaManifest: Decodable {
        struct Ref: Decodable { let digest: String; let size: Int64 }
        let layers: [Ref]
        let config: Ref?
    }

    static func scanOllama(home: URL) -> [LocalModel] {
        let fm = FileManager()
        let root = home.appending(path: ".ollama/models")
        let manifests = root.appending(path: "manifests")
        let blobs = root.appending(path: "blobs")
        guard fm.fileExists(atPath: manifests.path) else { return [] }

        var models: [LocalModel] = []
        guard let enumerator = fm.enumerator(
            at: manifests,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else { return [] }

        for case let file as URL in enumerator {
            guard !Task.isCancelled else { break }
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { continue }
            guard let data = try? Data(contentsOf: file),
                  let manifest = try? JSONDecoder().decode(OllamaManifest.self, from: data) else { continue }

            // Path under manifests/: <registry>/<namespace>/<model>/<tag>
            let rel = file.pathComponents.suffix(from: manifests.pathComponents.count)
            guard rel.count >= 2 else { continue }
            let tag = rel.last!
            let model = rel[rel.index(rel.endIndex, offsetBy: -2)]
            let namespace = rel.count >= 3 ? rel[rel.index(rel.endIndex, offsetBy: -3)] : "library"
            let name = namespace == "library" ? "\(model):\(tag)" : "\(namespace)/\(model):\(tag)"

            // Sum the actual on-disk size of every referenced blob.
            var digests = manifest.layers.map(\.digest)
            if let config = manifest.config { digests.append(config.digest) }
            var size: Int64 = 0
            for digest in digests {
                let blobName = digest.replacingOccurrences(of: ":", with: "-")
                let blob = blobs.appending(path: blobName)
                if let v = try? blob.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]) {
                    size += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
                }
            }
            guard size > 0 else { continue }

            models.append(LocalModel(
                provider: .ollama,
                name: name,
                detail: "Ollama · removed with `ollama rm`",
                sizeBytes: size,
                lastUsed: values?.contentModificationDate,
                location: file,
                removal: .ollamaCommand(name: name)
            ))
        }
        // Ollama tags can share blobs; de-dupe identical names defensively.
        var seen = Set<String>()
        return models.filter { seen.insert($0.name).inserted }
    }

    // MARK: LM Studio

    static func scanLMStudio(home: URL) -> [LocalModel] {
        let fm = FileManager()
        let root = home.appending(path: ".lmstudio/models")
        guard fm.fileExists(atPath: root.path) else { return [] }
        var models: [LocalModel] = []

        let publishers = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for publisher in publishers {
            guard (try? publisher.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            guard !publisher.lastPathComponent.hasPrefix(".") else { continue }
            let repos = (try? fm.contentsOfDirectory(at: publisher, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for repo in repos {
                guard (try? repo.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                guard !repo.lastPathComponent.hasPrefix(".") else { continue }
                let stats = DirectorySizer.stats(of: repo)
                guard stats.size > 0 else { continue }
                let name = "\(publisher.lastPathComponent)/\(repo.lastPathComponent)"
                models.append(LocalModel(
                    provider: .lmStudio,
                    name: name,
                    detail: "LM Studio · moves to Trash",
                    sizeBytes: stats.size,
                    lastUsed: stats.newestModification,
                    location: repo,
                    removal: .trashDirectory(repo)
                ))
            }
        }
        return models
    }

    // MARK: Hugging Face

    static func scanHuggingFace(home: URL) -> [LocalModel] {
        let fm = FileManager()
        let root = home.appending(path: ".cache/huggingface/hub")
        guard fm.fileExists(atPath: root.path) else { return [] }
        var models: [LocalModel] = []

        let entries = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for entry in entries {
            let raw = entry.lastPathComponent
            guard raw.hasPrefix("models--") else { continue }
            let stats = DirectorySizer.stats(of: entry)
            guard stats.size > 0 else { continue }
            let name = String(raw.dropFirst("models--".count)).replacingOccurrences(of: "--", with: "/")
            models.append(LocalModel(
                provider: .huggingFace,
                name: name,
                detail: "Hugging Face cache · moves to Trash",
                sizeBytes: stats.size,
                lastUsed: stats.newestModification,
                location: entry,
                removal: .trashDirectory(entry)
            ))
        }
        return models
    }
}
