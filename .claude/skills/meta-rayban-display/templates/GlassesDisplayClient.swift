import Foundation

/// Abstraction over the glasses HUD output channel. Implementations:
///   - `MockGlassesDisplayClient` for DEBUG / simulator
///   - `DATGlassesDisplayClient` for real Meta Ray-Ban Display via DAT 0.7+
///
/// Keep app code talking only to this protocol so the SDK can be swapped
/// or stubbed without touching feature logic.
public protocol GlassesDisplayClient: Sendable {
    func show(payload: DisplayPayload) async throws
    func clear() async throws
}
