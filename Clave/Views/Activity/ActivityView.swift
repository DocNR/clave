import SwiftUI

struct ActivityView: View {
    @State private var entries: [ActivityEntry] = []
    @State private var selectedFilter = "All"
    @Environment(\.scenePhase) private var scenePhase

    private let filters = ["All", "sign_event", "connect", "pending"]

    private var filteredEntries: [ActivityEntry] {
        switch selectedFilter {
        case "sign_event":
            return entries.filter { $0.method == "sign_event" }
        case "connect":
            return entries.filter { $0.method == "connect" }
        case "pending":
            return entries.filter { $0.status == "pending" || $0.status == "blocked" }
        default:
            return entries
        }
    }

    private var groupedByDay: [(String, [ActivityEntry])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filteredEntries) { entry -> String in
            let date = Date(timeIntervalSince1970: entry.timestamp)
            if calendar.isDateInToday(date) { return "Today" }
            if calendar.isDateInYesterday(date) { return "Yesterday" }
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return formatter.string(from: date)
        }
        return grouped.sorted { lhs, rhs in
            let lhsDate = lhs.value.first?.timestamp ?? 0
            let rhsDate = rhs.value.first?.timestamp ?? 0
            return lhsDate > rhsDate
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterChips
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                if filteredEntries.isEmpty {
                    emptyState
                } else {
                    activityList
                }
            }
            .navigationTitle("Activity")
            .onAppear { refreshData() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refreshData() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .signingCompleted)) { _ in
                refreshData()
            }
        }
    }

    // MARK: - Filter Chips

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(filters, id: \.self) { filter in
                    Button {
                        selectedFilter = filter
                    } label: {
                        Text(filter == "blocked" ? "Blocked" : filter == "All" ? "All" : filter)
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(selectedFilter == filter ? Color.accentColor : Color(.systemGray5))
                            .foregroundStyle(selectedFilter == filter ? .white : .primary)
                            .clipShape(Capsule())
                    }
                }
            }
        }
    }

    // MARK: - Activity List

    private var activityList: some View {
        List {
            ForEach(groupedByDay, id: \.0) { dayLabel, dayEntries in
                Section(dayLabel) {
                    ForEach(dayEntries) { entry in
                        NavigationLink {
                            ActivityDetailView(entry: entry)
                        } label: {
                            ActivityRowView(entry: entry)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No activity yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Connect a client using your bunker URI to get started.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
    }

    private func refreshData() {
        entries = SharedStorage.getActivityLog()
    }
}
