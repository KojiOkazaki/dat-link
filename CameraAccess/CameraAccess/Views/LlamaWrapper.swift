import Foundation
import llama

actor LlamaWrapper {
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private var sampling: UnsafeMutablePointer<llama_sampler>?
    private var isLoaded = false

    func loadModel(modelPath: String) throws {
        guard !isLoaded else { return }
        llama_backend_init()
        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = 999
        guard let m = llama_model_load_from_file(modelPath, mparams) else {
            throw LlamaWrapperError.modelLoadFailed
        }
        model = m
        let nThreads = max(1, min(8, ProcessInfo.processInfo.processorCount - 2))
        var cparams = llama_context_default_params()
        cparams.n_ctx = 2048
        cparams.n_threads = Int32(nThreads)
        cparams.n_threads_batch = Int32(nThreads)
        guard let c = llama_init_from_model(m, cparams) else {
            throw LlamaWrapperError.contextCreateFailed
        }
        context = c
        vocab = llama_model_get_vocab(m)
        let sparams = llama_sampler_chain_default_params()
        let s = llama_sampler_chain_init(sparams)!
        llama_sampler_chain_add(s, llama_sampler_init_temp(0.4))
        llama_sampler_chain_add(s, llama_sampler_init_dist(1234))
        sampling = s
        isLoaded = true
        print("[Gemma4] Model loaded, threads: \(nThreads)")
    }

    func generate(prompt: String, maxTokens: Int32 = 512) throws -> String {
        guard model != nil, let context, let vocab, let sampling else {
            throw LlamaWrapperError.notLoaded
        }
        llama_memory_clear(llama_get_memory(context), true)
        let tokens = tokenize(text: prompt, addBos: true)
        var batch = llama_batch_init(Int32(tokens.count) + maxTokens, 0, 1)
        defer { llama_batch_free(batch) }
        for (i, token) in tokens.enumerated() {
            batch.token[i] = token
            batch.pos[i] = Int32(i)
            batch.n_seq_id[i] = 1
            batch.seq_id[i]![0] = 0
            batch.logits[i] = 0
        }
        batch.logits[tokens.count - 1] = 1
        batch.n_tokens = Int32(tokens.count)
        guard llama_decode(context, batch) == 0 else {
            throw LlamaWrapperError.decodeFailed
        }
        var result = ""
        var nCur = Int32(tokens.count)
        var tempCChars: [CChar] = []
        for _ in 0..<maxTokens {
            let newToken = llama_sampler_sample(sampling, context, batch.n_tokens - 1)
            if llama_vocab_is_eog(vocab, newToken) { break }
            let piece = tokenToPiece(token: newToken)
            tempCChars.append(contentsOf: piece)
            if let str = String(validatingUTF8: tempCChars + [0]) {
                result += str
                tempCChars.removeAll()
            }
            batch.n_tokens = 0
            batch.token[0] = newToken
            batch.pos[0] = nCur
            batch.n_seq_id[0] = 1
            batch.seq_id[0]![0] = 0
            batch.logits[0] = 1
            batch.n_tokens = 1
            nCur += 1
            guard llama_decode(context, batch) == 0 else { break }
        }
        if !tempCChars.isEmpty {
            result += String(cString: tempCChars + [0])
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func tokenize(text: String, addBos: Bool) -> [llama_token] {
        guard let vocab else { return [] }
        let utf8 = text.utf8.count
        let n = utf8 + (addBos ? 1 : 0) + 1
        let buf = UnsafeMutablePointer<llama_token>.allocate(capacity: n)
        defer { buf.deallocate() }
        let count = llama_tokenize(vocab, text, Int32(utf8), buf, Int32(n), addBos, false)
        return (0..<Int(count)).map { buf[$0] }
    }

    private func tokenToPiece(token: llama_token) -> [CChar] {
        guard let vocab else { return [] }
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: 32)
        defer { buf.deallocate() }
        let n = llama_token_to_piece(vocab, token, buf, 32, 0, false)
        if n < 0 {
            let buf2 = UnsafeMutablePointer<CChar>.allocate(capacity: Int(-n))
            defer { buf2.deallocate() }
            let n2 = llama_token_to_piece(vocab, token, buf2, -n, 0, false)
            return Array(UnsafeBufferPointer(start: buf2, count: Int(n2)))
        }
        return Array(UnsafeBufferPointer(start: buf, count: Int(n)))
    }
}

enum LlamaWrapperError: LocalizedError {
    case modelLoadFailed, contextCreateFailed, notLoaded, decodeFailed
    var errorDescription: String? {
        switch self {
        case .modelLoadFailed: return "モデルのロードに失敗しました"
        case .contextCreateFailed: return "コンテキストの作成に失敗しました"
        case .notLoaded: return "モデルがロードされていません"
        case .decodeFailed: return "デコードに失敗しました"
        }
    }
}
