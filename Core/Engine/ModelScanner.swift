import Foundation

// MARK: - Model inventory

public enum ModelProvider: String, Sendable, CaseIterable {
    case ollama
    case lmStudio
    case huggingFace
    /// Models bundled by other desktop apps (Whisper/TTS/LLM weights in their
    /// Application Support folder) and framework download caches.
    case otherApps

    public var label: String {
        switch self {
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        case .huggingFace: "Hugging Face"
        case .otherApps: "Other apps"
        }
    }

    public var symbol: String {
        switch self {
        case .ollama: "cube.transparent"
        case .lmStudio: "cpu"
        case .huggingFace: "face.smiling"
        case .otherApps: "app.badge"
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
        models += scanOtherApps(home: home)
        return models.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    // MARK: Other apps

    /// File extensions that identify model weights. Directory bundles
    /// (.mlmodelc, .mlpackage) are treated as one unit.
    static let modelExtensions: Set<String> = [
        "gguf", "safetensors", "bin", "pth", "pt", "ckpt", "onnx", "tflite", "npz", "ggml",
        "mlmodelc", "mlpackage", "pte",
    ]
    static let otherAppsMinBytes: Int64 = 50_000_000

    /// Folders where desktop apps keep downloaded weights, relative to the
    /// app's Application Support folder, plus framework caches under ~/.cache.
    static func otherAppModelRoots(home: URL) -> [(app: String, root: URL)] {
        let support = home.appending(path: "Library/Application Support")
        var roots: [(String, URL)] = []
        var seen = Set<String>()
        for app in DynamicPaths.directories(in: support) {
            let name = app.lastPathComponent
            if name.lowercased().hasPrefix("com.apple.") { continue }
            // APFS is case-insensitive by default: "models" and "Models" are the
            // same folder, so key the de-dupe on the lowercased path.
            for sub in ["models", "Models", "whisper-models"] where DynamicPaths.isDirectory(app.appending(path: sub)) {
                let root = app.appending(path: sub)
                guard seen.insert(root.path.lowercased()).inserted else { continue }
                roots.append((name, root))
            }
            // Coqui TTS keeps one folder per model directly under its app dir.
            for child in DynamicPaths.directories(in: app) where child.lastPathComponent.hasPrefix("tts_models") {
                roots.append((name, child))
            }
        }
        for (label, rel) in [("PyTorch", ".cache/torch"), ("Whisper", ".cache/whisper")]
        where DynamicPaths.isDirectory(home.appending(path: rel)) {
            roots.append((label, home.appending(path: rel)))
        }
        return roots
    }

    static func scanOtherApps(home: URL) -> [LocalModel] {
        var models: [LocalModel] = []
        for (app, root) in otherAppModelRoots(home: home) {
            models += modelFiles(under: root, root: root, app: app, depth: 0)
        }
        return models
    }

    private static func modelFiles(under dir: URL, root: URL, app: String, depth: Int) -> [LocalModel] {
        let fm = FileManager()
        guard depth <= 3, let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var models: [LocalModel] = []
        for entry in entries {
            guard !Task.isCancelled else { break }
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let ext = entry.pathExtension.lowercased()
            if modelExtensions.contains(ext) {
                let stats = DirectorySizer.stats(of: entry)
                guard stats.size >= otherAppsMinBytes else { continue }
                // Name = path relative to the models folder. Many apps ship
                // several "model.safetensors", so the folder is what tells them
                // apart — and `LocalModel.id` derives from the name, so it must
                // be unique per file.
                let relative = entry.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
                models.append(LocalModel(
                    provider: .otherApps,
                    name: "\(app) · \(relative)",
                    detail: "\(app) · moves to Trash · the app re-downloads it when needed",
                    sizeBytes: stats.size,
                    lastUsed: stats.newestModification,
                    location: entry,
                    removal: .trashDirectory(entry)
                ))
            } else if isDir {
                models += modelFiles(under: entry, root: root, app: app, depth: depth + 1)
            }
        }
        return models
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
