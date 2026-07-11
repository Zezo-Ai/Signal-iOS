//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import AuthenticationServices
import SignalServiceKit

/// Responsible for interactions with the system password manager, via
/// `AuthenticationServices`.
///
/// - Note
/// An `NSObject` subclass because of `@objc` protocols.
class PasswordManagerManager:
    NSObject,
    ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding
{
    private struct State {
        var continuations: [ObjectIdentifier: CheckedContinuation<DisplayableAccountEntropyPool, Error>] = [:]
    }

    private var window: UIWindow {
        CurrentAppContext().mainWindow.owsFailUnwrap("Missing window!")
    }

    private let state: AtomicValue<State> = AtomicValue(State(), lock: .init())

    override init() {
        super.init()
    }

    // MARK: -

    @available(iOS 26.2, *)
    func saveDisplayableAEP(_ displayableAEP: DisplayableAccountEntropyPool) async throws {
        let credentialDataManager = ASCredentialDataManager()
        let credentialName = OWSLocalizedString(
            "BACKUP_RECORD_KEY_PASSWORD_MANAGER_CREDENTIAL_NAME",
            comment: "Name used as both the username and title for the user's 'Recovery Key' credential when saving it to a password manager.",
        )
        let password = ASPasswordCredential(
            user: credentialName,
            password: displayableAEP.displayString,
        )
        let scope = ASAutoFillURLScope(host: "signal.org")

        do {
            try await credentialDataManager.save(
                password: password,
                for: scope,
                title: credentialName,
                anchor: window,
            )
        } catch {
            Logger.warn("Failed to save to password manager! \(error)")
            throw error
        }
    }

    // MARK: -

    func requestDisplayableAEP() async throws -> DisplayableAccountEntropyPool {
        try await withCheckedThrowingContinuation { continutation in
            let request = ASAuthorizationPasswordProvider().createRequest()
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self

            state.update {
                $0.continuations[ObjectIdentifier(controller)] = continutation
                controller.performRequests()
            }
        }
    }

    // MARK: - ASAuthorizationControllerDelegate

    @objc(authorizationController:didCompleteWithAuthorization:)
    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization,
    ) {
        guard
            let continuation = state.update(block: {
                $0.continuations.removeValue(forKey: ObjectIdentifier(controller))
            })
        else {
            owsFailDebug("Missing continuation for controller for which we are the delegate?")
            return
        }

        guard
            let credential = authorization.credential as? ASPasswordCredential
        else {
            Logger.warn("Missing password credential")
            continuation.resume(throwing: OWSGenericError("Missing password credential!"))
            return
        }

        do {
            let displayableAEP = try DisplayableAccountEntropyPool(displayString: credential.password)
            return continuation.resume(returning: displayableAEP)
        } catch let error {
            Logger.warn("Password was not valid DisplayableAEP! \(error)")
            continuation.resume(throwing: error)
            return
        }
    }

    @objc(authorizationController:didCompleteWithError:)
    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error,
    ) {
        guard
            let continuation = state.update(block: {
                $0.continuations.removeValue(forKey: ObjectIdentifier(controller))
            })
        else {
            owsFailDebug("Missing continuation for controller for which we are the delegate?")
            return
        }

        Logger.warn("ASAuthorizationController failure: \(error)")
        continuation.resume(throwing: error)
    }

    // MARK: - ASAuthorizationControllerPresentationContextProviding

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        return window
    }
}
