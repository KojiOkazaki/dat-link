import Foundation
import UIKit
import Combine
import Vision

enum AnalysisMode: String, CaseIterable, Identifiable {
    case general = "General"
    case textRecognition = "Text"
    case objectDetection = "Object"
    case navigation = "Navigation"
    case productInfo = "Product"
    var id: String { rawValue }
    var prompt: String {
        switch self {
        case .general: return "この画像に何が写っているか、日本語で簡潔に説明してください。"
        case .textRecognition: return "この画像に含まれるテキストを全て読み取り、日本語で出力してください。"
        case .objectDetection: return "この画像に写っている物体を全てリストアップし、位置関係を日本語で説明してください。"
        case .navigation: return "この画像は歩行者の視点です。道路状況、障害物、信号、標識などを確認し、安全に歩くためのガイダンスを日本語で提供してください。"
        case .productInfo: return "この画像に写っている商品やブランドを特定し、日本語で詳細情報を提供してください。"
        }
    }
    var icon: String {
        switch self {
        case .general: return "eye"
        case .textRecognition: return "doc.text.viewfinder"
        case .objectDetection: return "cube.transparent"
        case .navigation: return "location.fill"
        case .productInfo: return "cart"
        }
    }
}

protocol AIVisionEngine {
    func analyzeImage(_ image: UIImage, prompt: String) async throws -> String
    var isReady: Bool { get async }
    var engineName: String { get }
}

enum AIEngineType: String, CaseIterable, Identifiable {
    case gemma4Local = "Gemma4 (Local)"
    case geminiAPI = "Gemini API"
    var id: String { rawValue }
}

// MARK: - Gemma4 Local Engine (llama.cpp + iOS Vision)

class Gemma4LocalEngine: AIVisionEngine {
    var engineName: String { "Gemma4 E4B (On-Device)" }
    private let llama = LlamaWrapper()
    private let modelFileName = "gemma-4-E4B-it-Q4_K_M.gguf"
    private var _isReady = false

    var isReady: Bool { get async { _isReady } }

    private var documentsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }
    var modelURL: URL { documentsDir.appendingPathComponent(modelFileName) }
    var modelExists: Bool { FileManager.default.fileExists(atPath: modelURL.path) }

    func loadModel() async throws {
        guard modelExists else { throw Gemma4Error.modelNotFound }
        try await llama.loadModel(modelPath: modelURL.path)
        _isReady = true
    }

    func analyzeImage(_ image: UIImage, prompt: String) async throws -> String {
        if !_isReady { try await loadModel() }
        let visionInfo = try await extractImageInfo(image)
        let fullPrompt = "<start_of_turn>user\n以下の画像解析結果を元に、\(prompt)\n\n画像情報:\n\(visionInfo)<end_of_turn>\n<start_of_turn>model\n"
        return try await llama.generate(prompt: fullPrompt, maxTokens: 512)
    }

    private func extractImageInfo(_ image: UIImage) async throws -> String {
        guard let cgImage = image.cgImage else { return "画像なし" }
        var info: [String] = []
        let classifyReq = VNClassifyImageRequest()
        let textReq = VNRecognizeTextRequest()
        textReq.recognitionLanguages = ["ja", "en"]
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([classifyReq, textReq])
        if let results = classifyReq.results {
            let top = results.filter { $0.confidence > 0.3 }.prefix(5).map { "\($0.identifier)(\(Int($0.confidence*100))%)" }
            if !top.isEmpty { info.append("シーン: \(top.joined(separator: ", "))") }
        }
        if let results = textReq.results {
            let texts = results.compactMap { $0.topCandidates(1).first?.string }
            if !texts.isEmpty { info.append("テキスト: \(texts.joined(separator: " "))") }
        }
        return info.isEmpty ? "特定の情報なし" : info.joined(separator: "\n")
    }
}

enum Gemma4Error: LocalizedError, Equatable {
    case modelNotFound, imageConversionFailed, inferenceError(String)
    static func == (lhs: Gemma4Error, rhs: Gemma4Error) -> Bool {
        switch (lhs, rhs) {
        case (.modelNotFound, .modelNotFound), (.imageConversionFailed, .imageConversionFailed): return true
        case (.inferenceError(let a), .inferenceError(let b)): return a == b
        default: return false
        }
    }
    var errorDescription: String? {
        switch self {
        case .modelNotFound: return "Gemma4 モデルが見つかりません。設定からダウンロードしてください。"
        case .imageConversionFailed: return "画像の変換に失敗しました。"
        case .inferenceError(let m): return "推論エラー: \(m)"
        }
    }
}

// MARK: - Gemini API Engine

class GeminiAPIEngine: AIVisionEngine {
    var engineName: String { "Gemini API (Cloud)" }
    private let baseURL = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent"
    var apiKey: String = "" {
        didSet { UserDefaults.standard.set(apiKey, forKey: "gemini_api_key") }
    }
    var isReady: Bool { get async { !apiKey.isEmpty } }
    init() {
        if let s = UserDefaults.standard.string(forKey: "gemini_api_key"), !s.isEmpty { apiKey = s }
    }
    func analyzeImage(_ image: UIImage, prompt: String) async throws -> String {
        guard !apiKey.isEmpty else { throw GeminiError.noAPIKey }
        guard let data = image.jpegData(compressionQuality: 0.7) else { throw GeminiError.imageConversionFailed }
        let body: [String:Any] = [
            "contents":[["parts":[["text":prompt],["inline_data":["mime_type":"image/jpeg","data":data.base64EncodedString()]]]]],
            "generationConfig":["temperature":0.4,"topK":32,"topP":1,"maxOutputTokens":1024]
        ]
        guard let url = URL(string: "\(baseURL)?key=\(apiKey)") else { throw GeminiError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 30
        let (d, r) = try await URLSession.shared.data(for: req)
        guard let http = r as? HTTPURLResponse, http.statusCode == 200 else { throw GeminiError.invalidResponse }
        guard let j = try? JSONSerialization.jsonObject(with: d) as? [String:Any],
              let c = j["candidates"] as? [[String:Any]], let fc = c.first,
              let ct = fc["content"] as? [String:Any], let ps = ct["parts"] as? [[String:Any]],
              let fp = ps.first, let text = fp["text"] as? String else { throw GeminiError.parseError }
        return text
    }
}

enum GeminiError: LocalizedError {
    case noAPIKey, imageConversionFailed, invalidURL, invalidResponse, parseError
    case apiError(statusCode: Int, message: String)
    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "APIキーが設定されていません。"
        case .imageConversionFailed: return "画像変換失敗"
        case .invalidURL: return "無効なURL"
        case .invalidResponse: return "無効な応答"
        case .apiError(let s, let m): return "APIエラー(\(s)): \(m)"
        case .parseError: return "解析失敗"
        }
    }
}

// MARK: - Model Downloader

@MainActor
class ModelDownloader: ObservableObject {
    static let shared = ModelDownloader()
    @Published var isDownloading = false
    @Published var progress: Double = 0
    @Published var statusMessage = ""
    private let hfBase = "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/main"
    private let modelName = "gemma-4-E4B-it-Q4_K_M.gguf"
    private var documentsDir: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first! }
    var modelExists: Bool { FileManager.default.fileExists(atPath: documentsDir.appendingPathComponent(modelName).path) }
    func downloadModels() async {
        guard !isDownloading else { return }
        isDownloading = true; progress = 0
        do {
            statusMessage = "モデル (約2.5GB) ダウンロード中..."
            try await downloadFile(name: modelName)
            progress = 1.0; statusMessage = "完了！"
        } catch { statusMessage = "エラー: \(error.localizedDescription)" }
        isDownloading = false
    }
    private func downloadFile(name: String) async throws {
        let dest = documentsDir.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: dest.path) else { return }
        guard let url = URL(string: "\(hfBase)/\(name)") else { return }
        let (tmp, _) = try await URLSession.shared.download(from: url)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }
}

// MARK: - Vision Service Manager

@MainActor
class VisionServiceManager: ObservableObject {
    static let shared = VisionServiceManager()
    @Published var selectedEngineType: AIEngineType = .gemma4Local {
        didSet { UserDefaults.standard.set(selectedEngineType.rawValue, forKey: "selected_engine") }
    }
    let gemma4Engine = Gemma4LocalEngine()
    let geminiEngine = GeminiAPIEngine()
    var currentEngine: AIVisionEngine {
        switch selectedEngineType {
        case .gemma4Local: return gemma4Engine
        case .geminiAPI: return geminiEngine
        }
    }
    private init() {
        if let s = UserDefaults.standard.string(forKey: "selected_engine"),
           let e = AIEngineType(rawValue: s) { selectedEngineType = e }
    }
    func analyzeImage(_ image: UIImage, mode: AnalysisMode) async throws -> String {
        try await currentEngine.analyzeImage(image, prompt: mode.prompt)
    }
    func setGeminiAPIKey(_ key: String) { geminiEngine.apiKey = key }
    var geminiAPIKey: String { geminiEngine.apiKey }
}
