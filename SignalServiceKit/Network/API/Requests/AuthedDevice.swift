//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
public import LibSignalClient

public enum AuthedDevice {
    case implicit
    case explicit(Explicit)

    public struct Explicit {
        public let aci: Aci
        public let phoneNumber: LocalIdentifiers.PhoneNumber
        public let deviceId: DeviceId
        public var isPrimaryDevice: Bool { deviceId == .primary }
        public let authPassword: String

        public init(aci: Aci, phoneNumber: LocalIdentifiers.PhoneNumber, deviceId: DeviceId, authPassword: String) {
            self.aci = aci
            self.phoneNumber = phoneNumber
            self.deviceId = deviceId
            self.authPassword = authPassword
        }

        public var localIdentifiers: LocalIdentifiers {
            return LocalIdentifiers(aci: aci, pni: phoneNumber.pni, e164: phoneNumber.e164)
        }

        public var authedAccount: AuthedAccount.Explicit {
            return AuthedAccount.Explicit(
                aci: aci,
                phoneNumber: phoneNumber,
                deviceId: deviceId,
                authPassword: authPassword,
            )
        }
    }

    public func orIfImplicitUse(_ other: Self) -> Self {
        switch self {
        case .explicit:
            return self
        case .implicit:
            return other
        }
    }

    public var authedAccount: AuthedAccount {
        switch self {
        case .implicit:
            return .implicit()
        case .explicit(let explicit):
            return .explicit(
                aci: explicit.aci,
                phoneNumber: explicit.phoneNumber,
                deviceId: explicit.deviceId,
                authPassword: explicit.authPassword,
            )
        }
    }
}
