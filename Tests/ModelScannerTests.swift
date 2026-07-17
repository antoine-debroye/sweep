import XCTest
@testable import SweepCore

final class ModelScannerTests: XCTestCase {
    var home: URL!
    let fm = FileManager()

    override func setUpWithError() throws {
        home = fm.temporaryDirectory.appending(path: "sweep-models-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: home)
    }

    private func write(_ relative: String, bytes: Int) throws {
        let url = home.appending(path: relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xCD, count: bytes).write(to: url)
    }

    func testOllamaModelsSizedFromReferencedBlobs() throws {
        // A manifest referencing two blobs; scanner should sum their on-disk size.
        try write(".ollama/models/blobs/sha256-weightsAAA", bytes: 5_000_000)
        try write(".ollama/models/blobs/sha256-configBBB", bytes: 40_000)
        let manifest = """
        {"layers":[{"digest":"sha256:weightsAAA","size":5000000}],
         "config":{"digest":"sha256:configBBB","size":40000}}
        """
        try write(".ollama/models/manifests/registry.ollama.ai/library/llama3/latest", bytes: 0)
        try manifest.data(using: .utf8)!.write(
            to: home.appending(path: ".ollama/models/manifests/registry.ollama.ai/library/llama3/latest")
        )

        let models = ModelScanner.scanOllama(home: home)
        XCTAssertEqual(models.count, 1)
        let m = try XCTUnwrap(models.first)
        XCTAssertEqual(m.name, "llama3:latest")
        XCTAssertEqual(m.provider, .ollama)
        XCTAssertGreaterThanOrEqual(m.sizeBytes, 5_000_000)
        XCTAssertEqual(m.removal, .ollamaCommand(name: "llama3:latest"),
                       "Ollama models must be removed via `ollama rm`, never by deleting blobs")
    }

    func testLMStudioModelsAreDirectoriesTrashed() throws {
        try write(".lmstudio/models/lmstudio-community/Qwen2.5-7B/model.gguf", bytes: 8_000_000)
        let models = ModelScanner.scanLMStudio(home: home)
        XCTAssertEqual(models.count, 1)
        let m = try XCTUnwrap(models.first)
        XCTAssertEqual(m.name, "lmstudio-community/Qwen2.5-7B")
        XCTAssertGreaterThanOrEqual(m.sizeBytes, 7_900_000)
        if case .trashDirectory(let url) = m.removal {
            XCTAssertEqual(url.lastPathComponent, "Qwen2.5-7B")
        } else {
            XCTFail("LM Studio models must be trashed as a directory")
        }
    }

    func testHuggingFaceRepoNamesDecoded() throws {
        try write(".cache/huggingface/hub/models--meta-llama--Llama-3-8B/blob.bin", bytes: 3_000_000)
        let models = ModelScanner.scanHuggingFace(home: home)
        XCTAssertEqual(models.first?.name, "meta-llama/Llama-3-8B")
    }

    func testMissingProvidersYieldNothing() {
        // No model directories at all → empty, no crash.
        XCTAssertTrue(ModelScanner.scan(home: home).isEmpty)
    }
}
