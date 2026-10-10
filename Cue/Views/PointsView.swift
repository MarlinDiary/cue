import StoreKit
import SwiftUI

/// The account's points and the packs that buy more: a section of Settings, and a sheet of its own when a word or a
/// question needs more points than are left. A pack's name and price are the App Store's.
struct PointsSection: View {
    /// "Points" over the section: in Settings, not in the sheet that is titled so.
    var titled = true
    @State private var points = Points.shared

    var body: some View {
        Section {
            LabeledContent("Balance") {
                Text(points.balance.map { "\($0.formatted(.number.precision(.fractionLength(0...1)))) points" } ?? "—")
                    .monospacedDigit()
            }
            ForEach(PointStore.products, id: \.self) { id in
                ProductView(id: id)
                    .productViewStyle(.compact)
            }
        } header: {
            if titled { Text("Points") }
        } footer: {
            Text("A new word takes about 1 point, a question 0.3 to 0.5, and a word someone has already added 0.2. Points don’t expire.")
        }
        .task { await points.refresh() }
    }
}

/// Purchases made from the points packs: tied to the account (`CueAccount`), and sent to Cue's server to be credited.
struct PointPurchases: ViewModifier {
    func body(content: Content) -> some View {
        content
            .inAppPurchaseOptions { _ in [.appAccountToken(CueAccount.id)] }
            .onInAppPurchaseCompletion { _, result in
                if case .success(.success(let verification)) = result {
                    await PointStore.shared.deliver(verification)
                }
            }
    }
}

/// The points and the packs, on their own, for a word or a question that needs more points than are left.
struct PointsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form { PointsSection(titled: false) }
                .modifier(PointPurchases())
                .navigationTitle("Points")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(role: .close) { dismiss() }
                    }
                }
        }
    }
}

/// Asked once, before anything the user adds or asks goes to AI: what is sent, and to whom (App Review 5.1.2(i)).
struct AIConsentView: View {
    var onAgree: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Cue Uses AI")
                        .font(.title.bold())
                    Text("Cue writes each word’s entry and draws its picture, reads words aloud and answers your questions with OpenAI’s models.")
                    Text("To do that, what you add or ask is sent to OpenAI, with the words on your wall when you ask about them: through Cue’s server when you use points, or straight from this device with your own OpenAI key. OpenAI doesn’t use it to train its models.")
                    Text("Cue’s server keeps each word’s entry and picture, to give to the next person who adds the same word, but not who added it or what you asked.")
                        .foregroundStyle(.secondary)
                }
                .padding(24)
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    AIConsent.give()
                    dismiss()
                    onAgree()
                } label: {
                    Text("Agree and Continue")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
    }
}

/// The sheet for what stands between the user and AI (`AIGate`): agreeing to it, points, or a key.
struct AIGateSheet: View {
    var gate: AIGate
    var onAgree: () -> Void = {}

    var body: some View {
        switch gate {
        case .consent: AIConsentView(onAgree: onAgree)
        case .points: PointsSheet()
        case .key: SettingsView()
        }
    }
}
