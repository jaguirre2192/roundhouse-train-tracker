import AuthenticationServices
import Foundation
import Observation

@MainActor
@Observable
final class AccountStore {
    enum RestoreState: Equatable {
        case pending
        case restoring
        case restored
        case failed(String)
    }

    private(set) var currentUser: AppUser?
    private(set) var restoreState: RestoreState
    private(set) var isWorking = false
    private(set) var errorMessage: String?

    private let client: AccountClient
    private var appleNonce: String?
    private var lifecycleGeneration: UInt = 0

    init(
        client: AccountClient = AccountClient(),
        preview: Bool = false,
        restoreState previewRestoreState: RestoreState? = nil
    ) {
        self.client = client
        currentUser = preview
            ? AppUser(id: "preview-traveler", email: "traveler@example.com", displayName: "Traveler", providers: [.apple])
            : nil
        restoreState = previewRestoreState ?? (preview ? .restored : .pending)
    }

    var isRestoring: Bool {
        restoreState == .pending || restoreState == .restoring
    }

    var restoreErrorMessage: String? {
        guard case let .failed(message) = restoreState else { return nil }
        return message
    }

    func restore() async {
        guard restoreState != .restoring, restoreState != .restored else { return }
        let restoreGeneration = lifecycleGeneration
        restoreState = .restoring
        do {
            let restoredUser = try await client.restoreUser()
            guard lifecycleGeneration == restoreGeneration else { return }
            currentUser = restoredUser
            restoreState = .restored
        } catch {
            guard lifecycleGeneration == restoreGeneration else { return }
            restoreState = .failed(error.localizedDescription)
        }
    }

    func googleAuthorizationURL() async -> URL? {
        await perform { try await client.googleAuthorizationURL() }
    }

    func handleCallback(_ url: URL) async -> Bool {
        guard AccountClient.isCallback(url) else { return false }
        await perform {
            let user = try await client.completeGoogleSignIn(from: url)
            acceptAuthenticatedUser(user)
        }
        return true
    }

    func prepareAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        do {
            let nonce = try OAuthHandoffStore.randomValue()
            appleNonce = nonce
            request.requestedScopes = [.fullName, .email]
            request.nonce = OAuthHandoffStore.digest(nonce)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func completeAppleAuthorization(_ result: Result<ASAuthorization, Error>) async {
        await perform {
            guard case let .success(authorization) = result,
                  let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let identityData = credential.identityToken,
                  let identityToken = String(data: identityData, encoding: .utf8),
                  let codeData = credential.authorizationCode,
                  let authorizationCode = String(data: codeData, encoding: .utf8),
                  let rawNonce = appleNonce else {
                if case let .failure(error) = result { throw error }
                throw AccountClient.ClientError.invalidCallback
            }
            let formatter = PersonNameComponentsFormatter()
            let fullName = credential.fullName.map { formatter.string(from: $0) }
            let user = try await client.signInWithApple(
                identityToken: identityToken,
                authorizationCode: authorizationCode,
                rawNonce: rawNonce,
                fullName: fullName?.isEmpty == false ? fullName : nil
            )
            appleNonce = nil
            acceptAuthenticatedUser(user)
        }
    }

    func signOut() async {
        guard !isWorking else { return }
        invalidateRestore()
        isWorking = true
        await client.logout()
        currentUser = nil
        errorMessage = nil
        isWorking = false
    }

    func deleteAccount() async -> Bool {
        let result: Void? = await perform {
            try await client.deleteAccount()
            invalidateRestore()
            currentUser = nil
        }
        return result != nil
    }

    func dismissError() { errorMessage = nil }

    func reportSignInFailure(_ error: any Error) {
        errorMessage = error.localizedDescription
    }

    private func acceptAuthenticatedUser(_ user: AppUser) {
        invalidateRestore()
        currentUser = user
    }

    private func invalidateRestore() {
        lifecycleGeneration &+= 1
        restoreState = .restored
    }

    private func perform<Value>(_ operation: () async throws -> Value) async -> Value? {
        guard !isWorking else { return nil }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            return try await operation()
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}
