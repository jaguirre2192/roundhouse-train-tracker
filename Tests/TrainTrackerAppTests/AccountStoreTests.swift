import AuthenticationServices
import Foundation
import SwiftUI
import TrainTrackerCore
import UIKit
import XCTest
@testable import TrainTracker

private actor ScriptedAccountHTTPClient: HTTPClient {
    enum Step: Sendable {
        case response(HTTPResponse)
        case failure(URLError.Code)
    }

    private var steps: [Step]

    init(_ steps: [Step]) {
        self.steps = steps
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        guard !steps.isEmpty else { throw URLError(.unknown) }
        switch steps.removeFirst() {
        case let .response(response): return response
        case let .failure(code): throw URLError(code)
        }
    }
}

private actor SuspendedRestoreAccountHTTPClient: HTTPClient {
    private var restoreContinuation: CheckedContinuation<HTTPResponse, Error>?
    private var restoreStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var didStartRestore = false
    private(set) var requests: [URLRequest] = []

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        switch request.url?.path {
        case "/v1/auth/me":
            return try await withCheckedThrowingContinuation { continuation in
                restoreContinuation = continuation
                didStartRestore = true
                restoreStartedWaiters.forEach { $0.resume() }
                restoreStartedWaiters.removeAll()
            }
        case "/v1/auth/google/start":
            return HTTPResponse(
                data: Data(#"{"url":"https://accounts.example.com/auth"}"#.utf8),
                statusCode: 200
            )
        case "/v1/auth/session/exchange":
            return HTTPResponse(
                data: Data(
                    #"{"token":"new-session","user":{"id":"new-user","email":"new@example.com","displayName":"New User","providers":["google"]}}"#.utf8
                ),
                statusCode: 200
            )
        default:
            throw URLError(.unsupportedURL)
        }
    }

    func waitForRestoreRequest() async {
        if didStartRestore { return }
        await withCheckedContinuation { continuation in
            restoreStartedWaiters.append(continuation)
        }
    }

    @discardableResult
    func resumeRestore(with response: HTTPResponse) -> Bool {
        guard let continuation = restoreContinuation else { return false }
        restoreContinuation = nil
        continuation.resume(returning: response)
        return true
    }
}

@MainActor
final class AccountStoreTests: XCTestCase {
    func testAppleBackendFailuresHaveSpecificRecoveryCopy() {
        XCTAssertEqual(
            AccountClient.ClientError
                .rejected(401, "apple_identity_verification_failed")
                .localizedDescription,
            "Apple could not verify this sign-in. Please try again."
        )
        XCTAssertEqual(
            AccountClient.ClientError
                .rejected(502, "apple_code_exchange_failed")
                .localizedDescription,
            "Apple sign-in could not finish securely. Please try again."
        )
    }

    func testWebAuthenticationCallbackIsSafeFromBackgroundQueue() async throws {
        let callbackURL = try XCTUnwrap(
            URL(string: "traintracker://auth-connected?code=example&transaction=example")
        )

        let received = expectation(description: "callback delivered on main actor")
        let sink = WebAuthenticationResultSink { result in
            MainActor.preconditionIsolated()
            guard case .callback(let url) = result else {
                XCTFail("Expected a callback URL")
                return
            }
            XCTAssertEqual(url, callbackURL)
            received.fulfill()
        }
        let callback = UncheckedWebCallbackBox(
            GoogleWebAuthenticationCallbackAdapter.callback(sink: sink)
        )
        DispatchQueue.global(qos: .userInitiated).async {
            callback(callbackURL, nil)
        }

        await fulfillment(of: [received], timeout: 2)
    }

    func testRootKeepsLocalAppShellAvailableWhileAccountRestoreIsPending() throws {
        let account = AccountStore()
        let library = TripLibrary.preview()
        let planLibrary = try JourneyPlanLibrary(
            tripLibrary: library,
            archive: JourneyPlanPreviewArchive(plans: [])
        )
        let vault = LocalJourneyTicketStore(
            directory: FileManager.default.temporaryDirectory.appending(path: "AccountStoreTests-\(UUID().uuidString)")
        )
        let root = AppRootView()
            .environment(vault)
            .environment(JourneyIntakeModel(vault: vault))
            .environment(account)
            .environment(library)
            .environment(planLibrary)
            .environment(AppNavigationModel())
            .environment(TicketInbox())
            .environment(ShareImportCoordinator())
            .environment(ForwardingStore())
            .environment(TicketPurchaseStore(fileURL: nil))
        let host = UIHostingController(rootView: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()

        XCTAssertTrue(account.isRestoring)
        XCTAssertNotNil(Self.navigationController(in: host))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        host.view.layoutIfNeeded()
        // The shell is My Trips in a navigation stack; there is no tab bar.
        let stack = try XCTUnwrap(Self.navigationController(in: host))
        XCTAssertNotNil(stack.topViewController)
        print("BUILD_7_LOCAL_SHELL_AVAILABLE_DURING_RESTORE_SECONDS=1.0")

        window.isHidden = true
    }

    func testOfflineRestoreKeepsSessionAndCanRetrySuccessfully() async throws {
        try AccountSessionStore.save("saved-session")
        defer { AccountSessionStore.delete() }
        let userData = Data(
            #"{"user":{"id":"traveler-1","email":"traveler@example.com","displayName":"Traveler","providers":["apple"]}}"#.utf8
        )
        let transport = ScriptedAccountHTTPClient([
            .failure(.notConnectedToInternet),
            .response(HTTPResponse(data: userData, statusCode: 200)),
        ])
        let store = AccountStore(client: AccountClient(
            baseURL: URL(string: "https://example.com")!,
            client: transport
        ))

        await store.restore()

        XCTAssertFalse(store.isRestoring)
        XCTAssertNotNil(store.restoreErrorMessage)
        XCTAssertEqual(AccountSessionStore.load(), "saved-session")
        XCTAssertNil(store.currentUser)

        await store.restore()

        XCTAssertEqual(store.restoreState, .restored)
        XCTAssertEqual(store.currentUser?.id, "traveler-1")
        XCTAssertNil(store.restoreErrorMessage)
    }

    func testUnauthorizedRestoreBecomesVerifiedGuestAndDeletesSession() async throws {
        try AccountSessionStore.save("expired-session")
        defer { AccountSessionStore.delete() }
        let transport = ScriptedAccountHTTPClient([
            .response(HTTPResponse(data: Data(), statusCode: 401)),
        ])
        let store = AccountStore(client: AccountClient(
            baseURL: URL(string: "https://example.com")!,
            client: transport
        ))

        await store.restore()

        XCTAssertEqual(store.restoreState, .restored)
        XCTAssertNil(store.currentUser)
        XCTAssertNil(store.restoreErrorMessage)
        XCTAssertNil(AccountSessionStore.load())
    }

    func testSuccessfulSignInKeepsNewSessionWhenStaleRestoreReturnsUnauthorized() async throws {
        try await assertSuccessfulSignInWins(
            over: HTTPResponse(data: Data(), statusCode: 401)
        )
    }

    func testSuccessfulSignInKeepsNewUserWhenStaleRestoreReturnsOldUser() async throws {
        let oldUserData = Data(
            #"{"user":{"id":"old-user","email":"old@example.com","displayName":"Old User","providers":["apple"]}}"#.utf8
        )
        try await assertSuccessfulSignInWins(
            over: HTTPResponse(data: oldUserData, statusCode: 200)
        )
    }

    func testFailedAccountDeletionReportsErrorAndSignOutClearsIt() async throws {
        try AccountSessionStore.save("saved-session")
        defer { AccountSessionStore.delete() }
        let transport = ScriptedAccountHTTPClient([
            .failure(.notConnectedToInternet),
            .response(HTTPResponse(data: Data(), statusCode: 204)),
        ])
        let store = AccountStore(
            client: AccountClient(baseURL: URL(string: "https://example.com")!, client: transport),
            preview: true
        )

        let deleted = await store.deleteAccount()

        XCTAssertFalse(deleted, "Settings must be told deletion failed")
        XCTAssertNotNil(store.errorMessage)
        await store.signOut()
        XCTAssertNil(store.errorMessage, "A later sign-in sheet must not inherit an old deletion error")
    }

    func testNoSessionRestoreFinishesWithoutShowingAnError() async {
        AccountSessionStore.delete()
        let store = AccountStore()

        await store.restore()

        XCTAssertEqual(store.restoreState, .restored)
        XCTAssertNil(store.currentUser)
        XCTAssertNil(store.restoreErrorMessage)
    }

    private func assertSuccessfulSignInWins(over restoreResponse: HTTPResponse) async throws {
        try AccountSessionStore.save("old-session")
        OAuthHandoffStore.delete(for: .accountGoogle)
        defer {
            AccountSessionStore.delete()
            OAuthHandoffStore.delete(for: .accountGoogle)
        }
        let transport = SuspendedRestoreAccountHTTPClient()
        let store = AccountStore(client: AccountClient(
            baseURL: URL(string: "https://example.com")!,
            client: transport
        ))

        let restoreTask = Task { @MainActor in await store.restore() }
        await transport.waitForRestoreRequest()

        let authorizationURL = await store.googleAuthorizationURL()
        XCTAssertNotNil(authorizationURL)
        let handoff = try XCTUnwrap(OAuthHandoffStore.load(for: .accountGoogle))
        var callback = URLComponents()
        callback.scheme = "traintracker"
        callback.host = "auth-connected"
        callback.queryItems = [
            URLQueryItem(name: "code", value: "authorization-code"),
            URLQueryItem(name: "transaction", value: handoff.transactionID),
        ]
        let callbackURL = try XCTUnwrap(callback.url)
        let handledCallback = await store.handleCallback(callbackURL)
        XCTAssertTrue(handledCallback)
        XCTAssertEqual(AccountSessionStore.load(), "new-session")
        XCTAssertEqual(store.currentUser?.id, "new-user")

        let resumedRestore = await transport.resumeRestore(with: restoreResponse)
        XCTAssertTrue(resumedRestore)
        await restoreTask.value

        XCTAssertEqual(AccountSessionStore.load(), "new-session")
        XCTAssertEqual(store.currentUser?.id, "new-user")
        XCTAssertEqual(store.restoreState, .restored)
        XCTAssertNil(store.restoreErrorMessage)

        let requests = await transport.requests
        let restoreRequest = try XCTUnwrap(requests.first(where: { $0.url?.path == "/v1/auth/me" }))
        XCTAssertEqual(
            restoreRequest.value(forHTTPHeaderField: "Authorization"),
            "Bearer old-session"
        )
    }

    private static func navigationController(in root: UIViewController) -> UINavigationController? {
        if let stack = root as? UINavigationController { return stack }
        for child in root.children {
            if let stack = navigationController(in: child) { return stack }
        }
        return nil
    }
}

private final class UncheckedWebCallbackBox: @unchecked Sendable {
    private let callback: ASWebAuthenticationSession.CompletionHandler

    init(_ callback: @escaping ASWebAuthenticationSession.CompletionHandler) {
        self.callback = callback
    }

    func callAsFunction(_ url: URL?, _ error: (any Error)?) {
        callback(url, error)
    }
}
