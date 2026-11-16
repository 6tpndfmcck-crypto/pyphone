import Foundation
import SwiftUI
import UniformTypeIdentifiers
import llama

private struct AsterError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A first local, read-only coding assistant. Qwen's chat template is applied
/// here; no Python scripts or files are sent to an external API.
actor AsterEngine {
    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer

    init(path: String) throws {
        llama_backend_init()
        var params = llama_model_default_params()
        // Start with CPU inference on low-memory iPhones. Metal can be enabled
        // after device benchmarks; this also works without simulator GPU support.
        params.n_gpu_layers = 0
        guard let loadedModel = llama_model_load_from_file(path, params) else {
            throw AsterError(message: "Couldn't load this GGUF. Check the file and available memory.")
        }
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = 1024
        contextParams.n_batch = 256
        let threads = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount - 1))
        contextParams.n_threads = Int32(threads)
        contextParams.n_threads_batch = Int32(threads)
        guard let loadedContext = llama_init_from_model(loadedModel, contextParams) else {
            llama_model_free(loadedModel)
            throw AsterError(message: "Couldn't allocate the model context. Close other apps and retry.")
        }
        model = loadedModel
        context = loadedContext
        vocab = llama_model_get_vocab(loadedModel)
    }

    deinit {
        llama_free(context)
        llama_model_free(model)
    }

    private func tokens(for prompt: String) throws -> [llama_token] {
        var tokens = [llama_token](repeating: 0, count: prompt.utf8.count + 8)
        let count = prompt.withCString { chars in
            tokens.withUnsafeMutableBufferPointer { buffer in
                llama_tokenize(vocab, chars, Int32(prompt.utf8.count),
                               buffer.baseAddress, Int32(buffer.count), true, true)
            }
        }
        guard count > 0 else { throw AsterError(message: "Could not tokenize the prompt.") }
        return Array(tokens.prefix(Int(count)))
    }

    private func piece(for token: llama_token) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 256)
        var length = buffer.withUnsafeMutableBufferPointer {
            llama_token_to_piece(vocab, token, $0.baseAddress, Int32($0.count), 0, false)
        }
        if length < 0 {
            buffer = [CChar](repeating: 0, count: Int(-length))
            length = buffer.withUnsafeMutableBufferPointer {
                llama_token_to_piece(vocab, token, $0.baseAddress, Int32($0.count), 0, false)
            }
        }
        guard length > 0 else { return [] }
        return buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
    }

    func generate(_ instruction: String) throws -> String {
        let prompt = "<|im_start|>system\nYou are GPT-0.6 Aster, a concise Python coding assistant.\n<|im_end|>\n<|im_start|>user\n" +
                     instruction + "<|im_end|>\n<|im_start|>assistant\n"
        let input = try tokens(for: prompt)
        let limit = 128
        guard input.count <= 512 else {
            throw AsterError(message: "Prompt too long for Aster's initial 1024-token context.")
        }
        llama_kv_self_clear(context)
        var batch = llama_batch_init(256, 0, 1)
        defer { llama_batch_free(batch) }
        let sampler = llama_sampler_init_greedy()
        defer { llama_sampler_free(sampler) }

        // Feed the prompt in bounded batches so long prompts cannot overwrite
        // llama_batch's fixed 256-token buffers.
        var offset = 0
        while offset < input.count {
            try Task.checkCancellation()
            batch.n_tokens = 0
            let end = min(offset + 256, input.count)
            for i in offset..<end {
                let slot = Int(batch.n_tokens)
                batch.token[slot] = input[i]
                batch.pos[slot] = Int32(i)
                batch.n_seq_id[slot] = 1
                batch.seq_id[slot]![0] = 0
                batch.logits[slot] = (i == input.count - 1) ? 1 : 0
                batch.n_tokens += 1
            }
            guard llama_decode(context, batch) == 0 else {
                throw AsterError(message: "Aster couldn't process the prompt.")
            }
            offset = end
        }

        var output = [UInt8]()
        for step in 0..<limit {
            try Task.checkCancellation()
            let token = llama_sampler_sample(sampler, context, batch.n_tokens - 1)
            if llama_vocab_is_eog(vocab, token) { break }
            output.append(contentsOf: piece(for: token))
            batch.n_tokens = 1
            batch.token[0] = token
            batch.pos[0] = Int32(input.count + step)
            batch.n_seq_id[0] = 1
            batch.seq_id[0]![0] = 0
            batch.logits[0] = 1
            guard llama_decode(context, batch) == 0 else {
                throw AsterError(message: "Aster stopped while generating.")
            }
        }
        return String(decoding: output, as: UTF8.self)
    }
}

@MainActor final class AsterSession: ObservableObject {
    @Published var status = "Choose your Qwen GGUF from Files."
    @Published var prompt = ""
    @Published var response = ""
    @Published var busy = false
    @Published var loaded = false

    private var engine: AsterEngine?
    private var selectedURL: URL?
    private var securityScope = false
    private var activeTask: Task<Void, Never>?

    func importModel(_ result: Result<URL, Error>) {
        guard !busy else { return }
        do {
            let url = try result.get()
            guard url.pathExtension.lowercased() == "gguf" else {
                throw AsterError(message: "Choose a .gguf model file.")
            }
            let scope = url.startAccessingSecurityScopedResource()
            let path = url.path
            busy = true
            status = "Loading model locally…"
            activeTask = Task {
                do {
                    let newEngine = try await Task.detached(priority: .userInitiated) {
                        try AsterEngine(path: path)
                    }.value
                    engine = newEngine
                    if securityScope { selectedURL?.stopAccessingSecurityScopedResource() }
                    selectedURL = url
                    securityScope = scope
                    loaded = true
                    status = "Aster ready — " + url.lastPathComponent
                } catch {
                    if scope { url.stopAccessingSecurityScopedResource() }
                    status = "Load failed: " + error.localizedDescription
                }
                busy = false
            }
        } catch {
            status = error.localizedDescription
        }
    }

    func send() {
        guard !busy, let engine, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        busy = true
        response = ""
        status = "Generating locally…"
        let instruction = prompt
        activeTask = Task {
            do {
                let text = try await engine.generate(instruction)
                response = text.isEmpty ? "(No text generated)" : text
                status = "Aster ready"
            } catch is CancellationError {
                status = "Generation stopped"
            } catch {
                status = "Generation failed: " + error.localizedDescription
            }
            busy = false
        }
    }

    func stop() { activeTask?.cancel() }
}

struct AsterPane: View {
    @ObservedObject var session: AsterSession
    @State private var showImporter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GPT-0.6 Aster").font(.title2.bold())
            Text("Local Qwen coding assistant · No API key required")
                .font(.caption).foregroundStyle(.secondary)
            Button("Choose GGUF from Files") { showImporter = true }
                .disabled(session.busy)
            Text(session.status).font(.caption).foregroundStyle(.secondary)
            TextField("Ask Aster to write Python…", text: $session.prompt, axis: .vertical)
                .lineLimit(2...5).textFieldStyle(.roundedBorder)
                .disabled(!session.loaded || session.busy)
            HStack {
                Button("Generate") { session.send() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!session.loaded || session.busy || session.prompt.isEmpty)
                if session.busy {
                    ProgressView()
                    Button("Stop") { session.stop() }
                }
            }
            ScrollView {
                Text(session.response.isEmpty ? "Aster's reply will appear here." : session.response)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data],
                      onCompletion: session.importModel)
    }
}
