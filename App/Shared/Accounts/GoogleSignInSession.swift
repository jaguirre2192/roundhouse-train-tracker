import AuthenticationServices
import Observation
import UIKit

/// Owns the system web-authentication sheet used for Google sign-in.
///
/// Keeping the session alive here prevents it from being deallocated while the
/// user is in Google's flow. `ASWebAuthenticationSession` keeps authentication
/// inside the app and returns only the registered Train Tracker callback.
@MainActor
@Observable
final class GoogleSignInSession: NSObject {
    private(set) var isPresenting = false
    private var session: ASWebAuthenticationSession?

    func begin(using account: AccountStore) async {
        guard session == nil,
              let authorizationURL = await account.googleAuthorizationURL() else { return }

        let sink = WebAuthenticationResultSink { [weak self, weak account] result in
            guard let self, let account else { return }
            await self.complete(result, using: account)
        }
        let session = ASWebAuthenticationSession(
            url: authorizationURL,
            callback: .customScheme("traintracker"),
            completionHandler: GoogleWebAuthenticationCallbackAdapter.callback(sink: sink)
        )
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        isPresenting = true

        guard session.start() else {
            self.session = nil
            isPresenting = false
            account.reportSignInFailure(GoogleSignInSessionError.couldNotStart)
            return
        }
    }

    private func complete(
        _ result: GoogleWebAuthenticationResult,
        using account: AccountStore
    ) async {
        session = nil
        isPresenting = false
        switch result {
        case .callback(let url):
            _ = await account.handleCallback(url)
        case .failure(let error):
            if let sessionError = error as? ASWebAuthenticationSessionError,
               sessionError.code == .canceledLogin {
                return
            }
            account.reportSignInFailure(error)
        }
    }
}

extension GoogleSignInSession: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
            ?? ASPresentationAnchor()
    }
}

enum GoogleWebAuthenticationResult: @unchecked Sendable {
    case callback(URL)
    case failure(any Error)
}

/// The system may invoke its completion handler away from the main actor. The
/// callback is deliberately created by a nonisolated factory, then hops to the
/// main actor before it touches the observable session or account state.
enum GoogleWebAuthenticationCallbackAdapter {
    nonisolated static func callback(
        sink: WebAuthenticationResultSink
    ) -> ASWebAuthenticationSession.CompletionHandler {
        { callbackURL, error in
            if let callbackURL {
                sink.receive(.callback(callbackURL))
            } else if let error {
                sink.receive(.failure(error))
            } else {
                sink.receive(.failure(GoogleSignInSessionError.invalidCompletion))
            }
        }
    }
}

final class WebAuthenticationResultSink: @unchecked Sendable {
    private let handler: @MainActor (GoogleWebAuthenticationResult) async -> Void

    @MainActor
    init(handler: @escaping @MainActor (GoogleWebAuthenticationResult) async -> Void) {
        self.handler = handler
    }

    nonisolated func receive(_ result: GoogleWebAuthenticationResult) {
        Task { @MainActor in await handler(result) }
    }
}

enum GoogleSignInSessionError: LocalizedError, Sendable {
    case couldNotStart
    case invalidCompletion

    var errorDescription: String? {
        switch self {
        case .couldNotStart:
            "Google sign-in could not open securely. Please try again."
        case .invalidCompletion:
            "Google sign-in did not return a valid result. Please try again."
        }
    }
}
