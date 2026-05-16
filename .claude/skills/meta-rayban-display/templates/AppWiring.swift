//
// Drop-in example showing how to wire the four glasses-display pieces
// (protocol + Mock + DAT + preview) into a SwiftUI App. Adapt the
// view bodies to your app's actual feature surface.
//

import MWDATCore
import SwiftUI

@main
struct MyDisplayApp: App {
    @StateObject private var glassesEnv: GlassesPipelineEnvironment

    init() {
        do {
            try Wearables.configure()
        } catch {
            NSLog("[App] Wearables.configure failed: \(error)")
        }

        let wearables = Wearables.shared

        // Simulator can't talk to Meta AI → always use Mock there.
        #if targetEnvironment(simulator)
        let client: any GlassesDisplayClient = MockGlassesDisplayClient()
        #else
        let client: any GlassesDisplayClient = DATGlassesDisplayClient(wearables: wearables)
        #endif

        _glassesEnv = StateObject(wrappedValue: GlassesPipelineEnvironment(client: client))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(glassesEnv)
                .onOpenURL { url in
                    Task { @MainActor in
                        _ = try? await Wearables.shared.handleUrl(url)
                    }
                }
        }
    }
}

/// Holds the live `GlassesDisplayClient`, the formatter, and the most
/// recent `DisplayPayload`. Views observe `currentPayload` to render the
/// iPhone-side preview. Whatever logic produces payloads in your app
/// (camera VLM, calendar event, transit timer, etc.) calls
/// `present(_:)` here.
@MainActor
final class GlassesPipelineEnvironment: ObservableObject {
    private let client: any GlassesDisplayClient
    let formatter: DisplayFormatter

    @Published private(set) var currentPayload: DisplayPayload?
    @Published private(set) var lastError: String?

    private var clearTask: Task<Void, Never>?

    init(
        client: any GlassesDisplayClient,
        formatter: DisplayFormatter = DisplayFormatter()
    ) {
        self.client = client
        self.formatter = formatter
    }

    func present(_ payload: DisplayPayload) async {
        currentPayload = payload
        scheduleAutoClear(after: payload.durationSeconds)
        do {
            try await client.show(payload: payload)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func clear() async {
        clearTask?.cancel()
        currentPayload = nil
        try? await client.clear()
    }

    private func scheduleAutoClear(after seconds: Int) {
        clearTask?.cancel()
        clearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(1, seconds)) * 1_000_000_000)
            if Task.isCancelled { return }
            self?.currentPayload = nil
            try? await self?.client.clear()
        }
    }
}

struct RootView: View {
    @EnvironmentObject var glassesEnv: GlassesPipelineEnvironment

    var body: some View {
        VStack(spacing: 16) {
            if let payload = glassesEnv.currentPayload {
                GlassesPreviewView(payload: payload)
            }

            // Replace this with your app's actual UI.
            Button("Send test payload to glasses") {
                Task {
                    let payload = glassesEnv.formatter.format(
                        title: "Hello",
                        body: "from your app",
                        chips: ["debug"],
                        confidence: 0.9
                    )
                    await glassesEnv.present(payload)
                }
            }

            if let err = glassesEnv.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
        .padding()
    }
}
