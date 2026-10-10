import SwiftUI

/// Settings, opened from the More menu on the wall: how the wall's cards are ordered, and how the app reaches AI:
/// with points, or with the user's own OpenAI API key.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var key = APIKeyStore.openAIKey ?? ""
    @State private var access = AIAccess.mode
    @AppStorage(HomeView.Order.storageKey) private var order: HomeView.Order = .newest

    var body: some View {
        NavigationStack {
            Form {
                Section("Sort Cards") {
                    Picker("Sort Cards", selection: $order) {
                        ForEach(HomeView.Order.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section {
                    Picker("AI", selection: $access) {
                        Text("Points").tag(AIAccess.Mode.points)
                        Text("My OpenAI Key").tag(AIAccess.Mode.ownKey)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                } header: {
                    Text("AI")
                } footer: {
                    Text(access == .points
                         ? "Cue’s server writes, draws and answers for you, paid for with points."
                         : "This device asks OpenAI directly, billed to your own OpenAI account.")
                }
                if access == .points {
                    PointsSection()
                } else {
                    Section {
                        SecureField("sk-…", text: $key)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            // The caret in the text's own colour, as in the wall's field.
                            .tint(Color.primary)
                    } header: {
                        Text("OpenAI API Key")
                    } footer: {
                        Text("It’s kept in this device’s keychain and only sent to OpenAI.")
                    }
                    if !key.isEmpty {
                        Section {
                            Button("Remove Key", role: .destructive) { key = "" }
                        }
                    }
                }
            }
            .modifier(PointPurchases())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) { dismiss() }
                }
            }
            .onChange(of: key) { APIKeyStore.setOpenAIKey(key) }
            .onChange(of: access) { AIAccess.mode = access }
        }
    }
}
