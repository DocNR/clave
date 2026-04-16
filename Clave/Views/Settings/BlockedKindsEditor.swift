import SwiftUI

struct ProtectedKindsEditor: View {
    @State private var protectedKinds: Set<Int> = []
    @State private var newKindText = ""
    @State private var kindToRemove: Int?

    var body: some View {
        List {
            Section {
                ForEach(protectedKinds.sorted(), id: \.self) { kind in
                    VStack(alignment: .leading) {
                        Text("Kind \(kind)")
                            .font(.body.bold())
                        if let label = KnownKinds.names[kind] {
                            Text(label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { indexSet in
                    let sorted = protectedKinds.sorted()
                    for index in indexSet {
                        kindToRemove = sorted[index]
                    }
                }
            } header: {
                Text("Protected Kinds")
            } footer: {
                Text("Events of these kinds require your approval in the app before signing. Swipe left to remove.")
            }

            Section("Add Kind") {
                HStack {
                    TextField("Event kind number", text: $newKindText)
                        .keyboardType(.numberPad)

                    Button("Add") {
                        guard let kind = Int(newKindText) else { return }
                        withAnimation {
                            protectedKinds.insert(kind)
                            SharedStorage.setProtectedKinds(protectedKinds)
                        }
                        newKindText = ""
                    }
                    .disabled(Int(newKindText) == nil)
                }
            }
        }
        .navigationTitle("Protected Kinds")
        .onAppear {
            protectedKinds = SharedStorage.getProtectedKinds()
        }
        .alert("Remove Protected Kind?", isPresented: Binding(
            get: { kindToRemove != nil },
            set: { if !$0 { kindToRemove = nil } }
        )) {
            Button("Remove", role: .destructive) {
                if let kind = kindToRemove {
                    withAnimation {
                        protectedKinds.remove(kind)
                        SharedStorage.setProtectedKinds(protectedKinds)
                    }
                }
                kindToRemove = nil
            }
            Button("Cancel", role: .cancel) {
                kindToRemove = nil
            }
        } message: {
            if let kind = kindToRemove {
                let label = KnownKinds.names[kind].map { " (\($0))" } ?? ""
                Text("Kind \(kind)\(label) will be auto-signed without your approval.")
            }
        }
    }
}
