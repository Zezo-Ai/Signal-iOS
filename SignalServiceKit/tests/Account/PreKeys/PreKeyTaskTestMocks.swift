//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import LibSignalClient

@testable import SignalServiceKit

//
//
// MARK: - Mocks
//
//
extension PreKeyTaskManager {
    enum Mocks {
        typealias APIClient = _PreKeyTaskManager_APIClientMock
        typealias DateProvider = _PreKeyTaskManager_DateProviderMock
        typealias IdentityManager = _PreKeyTaskManager_IdentityManagerMock
        typealias IdentityKeyMismatchManager = _PreKeyTaskManager_IdentityKeyMismatchManagerMock
    }
}

//
//
// MARK: - Mock Implementations
//
//

class _PreKeyTaskManager_IdentityManagerMock: PreKeyManagerImpl.Shims.IdentityManager {

    var aciKeyPair: ECKeyPair?
    var pniKeyPair: ECKeyPair?

    func identityKeyPair(for identity: OWSIdentity, tx: SignalServiceKit.DBReadTransaction) -> ECKeyPair? {
        switch identity {
        case .aci:
            return aciKeyPair
        case .pni:
            return pniKeyPair
        }
    }

    func generateNewIdentityKeyPair() -> ECKeyPair { ECKeyPair.generateKeyPair() }

    func store(keyPair: ECKeyPair?, for identity: OWSIdentity, tx: DBWriteTransaction) {
        switch identity {
        case .aci:
            aciKeyPair = keyPair
        case .pni:
            pniKeyPair = keyPair
        }
    }
}

class _PreKeyTaskManager_IdentityKeyMismatchManagerMock: IdentityKeyMismatchManager {
    func recordSuspectedIssueWithPniIdentityKey(tx: DBWriteTransaction) {
    }

    func validateLocalPniIdentityKeyIfNecessary() async {
    }

    var validateIdentityKeyMock: ((_ identity: OWSIdentity) async -> Void)!
    func validateIdentityKey(for identity: OWSIdentity) async {
        await validateIdentityKeyMock!(identity)
    }
}

class _PreKeyTaskManager_DateProviderMock {
    var currentDate: Date = Date()
    func targetDate() -> Date { return currentDate }
}

class _PreKeyTaskManager_APIClientMock: PreKeyTaskAPIClient {
    var currentPreKeyCount: Int?
    var currentPqPreKeyCount: Int?

    var setPreKeysResult: ConsumableMockPromise<Void> = .unset
    var identity: OWSIdentity?
    var signedPreKeyRecord: LibSignalClient.SignedPreKeyRecord?
    var preKeyRecords: [LibSignalClient.PreKeyRecord]?
    var pqLastResortPreKeyRecord: LibSignalClient.KyberPreKeyRecord?
    var pqPreKeyRecords: [LibSignalClient.KyberPreKeyRecord]?
    var auth: ChatServiceAuth?

    func getAvailablePreKeys(for identity: OWSIdentity) async throws -> (ecCount: Int, pqCount: Int) {
        return (currentPreKeyCount!, currentPqPreKeyCount!)
    }

    func registerPreKeys(
        for identity: OWSIdentity,
        signedPreKeyRecord: LibSignalClient.SignedPreKeyRecord?,
        preKeyRecords: [LibSignalClient.PreKeyRecord]?,
        pqLastResortPreKeyRecord: LibSignalClient.KyberPreKeyRecord?,
        pqPreKeyRecords: [LibSignalClient.KyberPreKeyRecord]?,
        auth: ChatServiceAuth
    ) async throws {
        try await setPreKeysResult.consumeIntoPromise().awaitable()

        self.identity = identity
        self.signedPreKeyRecord = signedPreKeyRecord
        self.preKeyRecords = preKeyRecords
        self.pqLastResortPreKeyRecord = pqLastResortPreKeyRecord
        self.pqPreKeyRecords = pqPreKeyRecords
        self.auth = auth
    }
}
