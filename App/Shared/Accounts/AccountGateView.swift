import AuthenticationServices
import SwiftUI

struct AccountGateView: View {
  @Environment(AccountStore.self) private var account
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.dismiss) private var dismiss
  @State private var googleSignIn = GoogleSignInSession()
  @ScaledMetric(relativeTo: .body) private var providerButtonHeight: CGFloat = 50
  @ScaledMetric(relativeTo: .body) private var googleMarkSide: CGFloat = 20

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [
          Color.ttBackgroundCanvas,
          Color.ttBackgroundBrandSubtle.opacity(0.7),
          Color.ttBackgroundCanvas,
        ],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()

      GeometryReader { proxy in
        ScrollView {
          VStack(spacing: 28) {
            Spacer(minLength: 24)
            mark
            VStack(spacing: 10) {
              Text("Sign in to stay connected")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(Color.ttTextPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
              Text(
                "Manage your Roundhouse account while keeping core train tracking available in guest mode."
              )
              .font(.body)
              .foregroundStyle(Color.ttTextSecondary)
              .multilineTextAlignment(.center)
              .frame(maxWidth: 420)
              .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: TrainTrackerSpacing.space12) {
              SignInWithAppleButton(.continue) { request in
                account.prepareAppleRequest(request)
              } onCompletion: { result in
                Task { await account.completeAppleAuthorization(result) }
              }
              .signInWithAppleButtonStyle(
                colorScheme == .dark ? .white : .black
              )
              .id(colorScheme)
              .frame(height: providerButtonHeight)
              .clipShape(Capsule())

              Button {
                Task { await googleSignIn.begin(using: account) }
              } label: {
                HStack(spacing: TrainTrackerSpacing.space12) {
                  Image("GoogleG")
                    .resizable()
                    .scaledToFit()
                    .frame(width: googleMarkSide, height: googleMarkSide)
                    .accessibilityHidden(true)
                  Text("Continue with Google")
                    .font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Color.ttTextPrimary)
                .frame(maxWidth: .infinity, minHeight: providerButtonHeight)
                .background(Color.ttBackgroundElevated, in: Capsule())
                .overlay {
                  Capsule().stroke(Color.ttTextSecondary.opacity(0.35), lineWidth: TrainTrackerStroke.subtle)
                }
                .contentShape(Capsule())
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Continue with Google")

              // Guest is the quiet way out, so it reads as a text action beneath the two providers.
              Button {
                dismiss()
              } label: {
                Text("Continue as Guest")
                  .font(.body.weight(.semibold))
                  .multilineTextAlignment(.center)
                  .fixedSize(horizontal: false, vertical: true)
                  .frame(maxWidth: .infinity, minHeight: 44)
              }
              .buttonStyle(.borderless)
              .accessibilityHint("Returns to Roundhouse without signing in")
            }
            .frame(maxWidth: 360)
            .disabled(account.isWorking || googleSignIn.isPresenting)

            Text("Sign-in is optional. Guest trips stay available on this device.")
              .font(.footnote)
              .foregroundStyle(Color.ttTextSecondary)
              .multilineTextAlignment(.center)
              .frame(maxWidth: 380)
              .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 24)
          }
          .frame(maxWidth: .infinity, minHeight: proxy.size.height)
          .padding(32)
        }
        .scrollBounceBehavior(.basedOnSize)
      }
    }
    .tint(Color.ttActionTint)
    .alert("Account", isPresented: errorBinding) {
      Button("OK") { account.dismissError() }
    } message: {
      Text(account.errorMessage ?? "")
    }
    .onChange(of: account.currentUser?.id) { _, userID in
      if userID != nil { dismiss() }
    }
  }

  private var mark: some View {
    ZStack {
      RoundedRectangle(cornerRadius: TrainTrackerRadius.hero, style: .continuous)
        .fill(Color.ttBackgroundBrand)
      Image(TrainTrackerSymbol.train)
        .font(.system(size: 38, weight: .semibold))
        .foregroundStyle(Color.ttTextOnBrand)
    }
    .frame(width: TrainTrackerSpacing.space84, height: TrainTrackerSpacing.space84)
    .shadow(color: Color.ttBackgroundBrand.opacity(0.18), radius: 22, y: 12)
    .accessibilityHidden(true)
  }

  private var errorBinding: Binding<Bool> {
    Binding(
      get: { account.errorMessage != nil },
      set: { if !$0 { account.dismissError() } }
    )
  }
}
