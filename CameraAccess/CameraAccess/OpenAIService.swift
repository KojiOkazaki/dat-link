import Foundation
import UIKit

// MARK: - OpenAI Service

actor OpenAIService {

    static let shared = OpenAIService()

    private let apiURL = URL(string: "https://api.openai.com/v1/chat/completions")!
    private let model = "gpt-4o"
    private let maxImageSize: CGFloat = 720
    private let jpegQuality: CGFloat = 0.5

    var apiKey: String {
        get { UserDefaults.standard.string(forKey: "openai_api_key") ?? "" }
    }

    func setAPIKey(_ key: String) {
        UserDefaults.standard.set(key, forKey: "openai_api_key")
    }

    func analyzeImage(_ image: UIImage, mode: AnalysisMode = .general) async throws -> String {
        let key = apiKey
        guard !key.isEmpty else {
            throw OpenAIError.missingAPIKey
        }
        let resized = resizeImage(image, maxDimension: maxImageSize)
        guard let jpegData = resized.jpegData(compressionQuality: jpegQuality) else {
            throw OpenAIError.imageEncodingFailed
        }
        let base64String = jpegData.base64EncodedString()
        let requestBody = buildRequestBody(base64Image: base64String, prompt: mode.prompt)
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.addValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            let errorMessage = parseErrorMessage(from: data)
            throw OpenAIError.apiError(statusCode: httpResponse.statusCode, message: errorMessage)
        }
        return try parseResponse(from: data)
    }

    private func resizeImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        guard size.width > maxDimension || size.height > maxDimension else { return image }
        let ratio = min(maxDimension / size.width, maxDimension / size.height)
        let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
    }

    private func buildRequestBody(base64Image: String, prompt: String) -> [String: Any] {
        [
            "model": model,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": prompt],
                        ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64Image)", "detail": "low"]]
                    ]
                ]
            ],
            "max_tokens": 500
        ]
    }

    private func parseResponse(from data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw OpenAIError.parsingFailed
        }
        return content
    }

    private func parseErrorMessage(from data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return String(data: data, encoding: .utf8) ?? "不明なエラー"
        }
        return message
    }
}

enum OpenAIError: LocalizedError {
    case missingAPIKey
    case imageEncodingFailed
    case invalidResponse
    case apiError(statusCode: Int, message: String)
    case parsingFailed

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "OpenAI APIキーが設定されていません。"
        case .imageEncodingFailed: return "画像のエンコードに失敗しました。"
        case .invalidResponse: return "サーバーからの応答が不正です。"
        case .apiError(let statusCode, let message): return "APIエラー (\(statusCode)): \(message)"
        case .parsingFailed: return "応答の解析に失敗しました。"
        }
    }
}
