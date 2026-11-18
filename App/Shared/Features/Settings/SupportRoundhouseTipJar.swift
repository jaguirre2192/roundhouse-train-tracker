import StoreKit
import SwiftUI

struct SupportRoundhouseTipRow: View {
  @State private var showingJar = false

  var body: some View {
    Button {
      RoundhouseTipStore.shared.openJar()
      showingJar = true
    } label: {
      Label("Support Roundhouse", systemImage: "heart")
    }
    .accessibilityIdentifier("settings.supportRoundhouse")
    .sheet(isPresented: $showingJar) {
      SupportRoundhouseTipJar()
    }
  }
}

private struct SupportRoundhouseTipJar: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.purchase) private var purchase
  @State private var store = RoundhouseTipStore.shared

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Image(systemName: store.status == .thanked ? "heart.fill" : "heart")
            .font(.system(size: 30, weight: .regular))
            .foregroundStyle(Color.ttActionTint)
            .accessibilityHidden(true)
          Text(store.status == .thanked ? "Thank you for the tip." : "Help keep Roundhouse free.")
            .font(.title2.bold())
            .fixedSize(horizontal: false, vertical: true)
          Text(store.status == .thanked
            ? "Your support helps pay the hosting bills for everyone who follows a train."
            : "A one-time tip helps cover our hosting costs. Every rider gets the same free features.")
            .foregroundStyle(Color.ttTextSecondary)
          action
        }
        .frame(maxWidth: 380, alignment: .leading)
        .padding(24)
        .frame(maxWidth: .infinity)
      }
      .background(Color.ttBackgroundCanvas)
      .navigationTitle("Support Roundhouse")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .task {
        store.startObserving()
        await store.load()
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }

  @ViewBuilder private var action: some View {
    if store.status == .thanked {
      EmptyView()
    } else if store.status == .pending {
      Label("Your tip is waiting for approval from Apple.", systemImage: "clock")
        .font(.subheadline)
    } else if store.loading || !store.didCheckStore {
      ProgressView("Getting the price…")
    } else if let product = store.product {
      if store.status == .purchaseFailed || store.status == .unverified {
        Text(store.status == .unverified
          ? "The App Store couldn’t verify the tip. Check your purchase history before trying again."
          : "The App Store couldn’t complete your tip. You can try again.")
          .font(.subheadline)
      }
      Button {
        Task { await store.sendTip { try await purchase($0) } }
      } label: {
        if store.status == .buying {
          ProgressView().tint(.white)
        } else {
          Text("Leave a tip · \(product.displayPrice)")
        }
      }
      .trainTrackerPrimaryAction()
      .controlSize(.large)
      .disabled(store.status == .buying)
      .accessibilityIdentifier("roundhouse.tip.purchase")
    } else {
      Text("The tip is currently unavailable in the App Store.")
        .font(.subheadline)
        .foregroundStyle(Color.ttTextSecondary)
      Button("Try Again") { Task { await store.load() } }
    }
  }
}
