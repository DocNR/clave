import SwiftUI

/// Expandable raw-JSON disclosure used at the bottom of
/// `PendingRequestDetailView` and `ActivityDetailView`. Presents the
/// caller-provided JSON in a monospaced, selectable, copyable form
/// behind a `DisclosureGroup`. The view is intentionally bare — no
/// pretty-printing — so what the user sees is exactly what was on the
/// wire / on the relay. Power users can copy and pipe through `jq`.
///
/// Disclosure-group state lives on the parent so the section can
/// remember the user's choice across re-renders if the parent provides
/// a Binding; the convenience init uses an internal `@State` for
/// fire-and-forget usage.
struct RawEventDisclosure: View {
    let title: String
    let json: String
    @Binding var isExpanded: Bool

    /// Convenience init with internal expansion state — use when the
    /// detail view doesn't need to remember disclosure state across
    /// data refreshes.
    init(title: String = "View raw event", json: String) {
        self.title = title
        self.json = json
        self._isExpanded = .constant(false)
        self._internalExpansion = State(initialValue: false)
        self.usesInternalState = true
    }

    init(title: String = "View raw event", json: String, isExpanded: Binding<Bool>) {
        self.title = title
        self.json = json
        self._isExpanded = isExpanded
        self._internalExpansion = State(initialValue: false)
        self.usesInternalState = false
    }

    @State private var internalExpansion: Bool
    private let usesInternalState: Bool

    var body: some View {
        DisclosureGroup(
            title,
            isExpanded: usesInternalState ? $internalExpansion : $isExpanded
        ) {
            Text(json)
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
