import SwiftUI
import Combine

struct AnalysisOverlayView: View {
    @StateObject private var speechService = SpeechService.shared
    @StateObject private var visionManager = VisionServiceManager.shared
    @StateObject private var downloader = ModelDownloader.shared
    @EnvironmentObject private var glassesEnv: GlassesPipelineEnvironment
    @State private var selectedMode: AnalysisMode = .general
    @State private var analysisResult: String = ""
    @State private var isAnalyzing: Bool = false
    @State private var showSettings: Bool = false
    @State private var showResult: Bool = false
    let currentFrame: UIImage?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            if glassesEnv.currentPayload != nil {
                GlassesPreviewView(payload: glassesEnv.currentPayload)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
            if showResult && !analysisResult.isEmpty { resultView }
            controlPanel
        }
        .sheet(isPresented: $showSettings) { settingsSheet }
    }

    private var resultView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "brain.head.profile").foregroundColor(.cyan)
                Text("Gemma4 E4B").font(.caption).foregroundColor(.cyan)
                Spacer()
                Button { speechService.toggle(analysisResult) } label: {
                    Image(systemName: speechService.isSpeaking ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundColor(.white).padding(8)
                        .background(speechService.isSpeaking ? Color.red.opacity(0.7) : Color.blue.opacity(0.7))
                        .clipShape(Circle())
                }
                Button { showResult = false; speechService.stop() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.gray)
                }
            }
            ScrollView {
                Text(analysisResult).font(.body).foregroundColor(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 150)
        }
        .padding().background(Color.black.opacity(0.85)).cornerRadius(16).padding(.horizontal)
    }

    private var controlPanel: some View {
        VStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AnalysisMode.allCases) { mode in
                        Button { selectedMode = mode } label: {
                            HStack(spacing: 4) {
                                Image(systemName: mode.icon).font(.caption)
                                Text(mode.rawValue).font(.caption)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(selectedMode == mode ? Color.cyan : Color.gray.opacity(0.5))
                            .foregroundColor(.white).cornerRadius(16)
                        }
                    }
                }.padding(.horizontal)
            }
            HStack(spacing: 12) {
                Button { speechService.autoSpeak.toggle() } label: {
                    Image(systemName: speechService.autoSpeak ? "speaker.wave.2" : "speaker.slash")
                        .font(.caption).padding(8)
                        .background(speechService.autoSpeak ? Color.green.opacity(0.7) : Color.gray.opacity(0.5))
                        .foregroundColor(.white).clipShape(Circle())
                }
                Spacer()
                Button { analyzeCurrentFrame() } label: {
                    HStack(spacing: 6) {
                        if isAnalyzing { ProgressView().tint(.white).scaleEffect(0.8) }
                        else { Image(systemName: "brain") }
                        Text(isAnalyzing ? "分析中..." : "AI分析").fontWeight(.semibold)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(isAnalyzing ? Color.gray : Color.cyan)
                    .foregroundColor(.white).cornerRadius(20)
                }
                .disabled(isAnalyzing || currentFrame == nil)
                Button { sendToGlasses() } label: {
                    HStack(spacing: 6) {
                        if glassesEnv.isProcessing { ProgressView().tint(.white).scaleEffect(0.8) }
                        else { Image(systemName: "eyeglasses") }
                        Text("Glasses").fontWeight(.semibold)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(glassesEnv.isProcessing ? Color.gray : Color.purple)
                    .foregroundColor(.white).cornerRadius(20)
                }
                .disabled(glassesEnv.isProcessing || currentFrame == nil)
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape.fill").padding(8)
                        .background(Color.gray.opacity(0.5))
                        .foregroundColor(.white).clipShape(Circle())
                }
            }.padding(.horizontal)
        }
        .padding(.vertical, 12).background(Color.black.opacity(0.6))
    }

    private var settingsSheet: some View {
        NavigationView {
            Form {
                Section("Gemma4 E4B モデル") {
                    if downloader.modelExists {
                        HStack {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                            Text("モデルダウンロード済み")
                        }
                    } else if downloader.isDownloading {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(downloader.statusMessage).font(.caption)
                            ProgressView(value: downloader.progress)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Gemma 4 E4B (Q4_K_M, 約2.5GB) をダウンロードします。Wi-Fi推奨。")
                                .font(.caption).foregroundColor(.secondary)
                            Button("モデルをダウンロード") {
                                Task { await downloader.downloadModels() }
                            }.buttonStyle(.borderedProminent)
                        }
                    }
                }
                Section("音声") { Toggle("自動読み上げ", isOn: $speechService.autoSpeak) }
            }
            .navigationTitle("Gemma4 設定").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { showSettings = false } } }
        }
    }

    private func analyzeCurrentFrame() {
        guard let image = currentFrame, !isAnalyzing else { return }
        if !downloader.modelExists {
            showSettings = true
            return
        }
        isAnalyzing = true
        analysisResult = "Gemma4で分析中..."
        showResult = true
        Task {
            do {
                let result = try await visionManager.analyzeImage(image, mode: selectedMode)
                analysisResult = result
                if speechService.autoSpeak { speechService.speak(result) }
            } catch {
                analysisResult = "エラー: \(error.localizedDescription)"
            }
            isAnalyzing = false
        }
    }

    private func sendToGlasses() {
        guard let image = currentFrame, !glassesEnv.isProcessing else { return }
        if !downloader.modelExists {
            showSettings = true
            return
        }
        Task { await glassesEnv.describeAndShow(image: image) }
    }
}
