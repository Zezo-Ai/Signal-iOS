//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
public import LibSignalClient

public class AuthedAccount {

    public struct Explicit {
        public let aci: Aci
        public let phoneNumber: LocalIdentifiers.PhoneNumber
        public let deviceId: DeviceId
        public let authPassword: String

        public init(
            aci: Aci,
            phoneNumber: LocalIdentifiers.PhoneNumber,
            deviceId: DeviceId,
            authPassword: String,
        ) {
            self.aci = aci
            self.phoneNumber = phoneNumber
            self.deviceId = deviceId
            self.authPassword = authPassword
        }
    }

    public enum Info {
        case implicit
        case explicit(Explicit)
    }

    public let info: Info

    private init(_ info: Info) {
        self.info = info
    }

    /// Will use info present on TSAccountManager
    public static func implicit() -> AuthedAccount {
        return AuthedAccount(.implicit)
    }

    public static func explicit(
        aci: Aci,
        phoneNumber: LocalIdentifiers.PhoneNumber,
        deviceId: DeviceId,
        authPassword: String,
    ) -> AuthedAccount {
        return AuthedAccount(.explicit(Explicit(
            aci: aci,
            phoneNumber: phoneNumber,
            deviceId: deviceId,
            authPassword: authPassword,
        )))
    }

    public func orIfImplicitUse(_ other: AuthedAccount) -> AuthedAccount {
        switch (self.info, other.info) {
        case (.explicit, _):
            return self
        case (_, .explicit):
            return other
        case (.implicit, .implicit):
            return other
        }
    }

    public func isAddressForLocalUser(_ address: SignalServiceAddress) -> Bool {
        switch info {
        case .implicit:
            return false
        case let .explicit(info):
            return info.isAddressForLocalUser(address)
        }
    }

    public var chatServiceAuth: ChatServiceAuth {
        switch info {
        case .implicit:
            return .implicit()
        case let .explicit(info):
            return info.chatServiceAuth
        }
    }

    public func authedDevice(isPrimaryDevice: Bool) -> AuthedDevice {
        switch info {
        case .implicit:
            return .implicit
        case let .explicit(info):
            return .explicit(AuthedDevice.Explicit(
                aci: info.aci,
                phoneNumber: info.phoneNumber,
                deviceId: info.deviceId,
                authPassword: info.authPassword,
            ))
        }
    }
}

extension AuthedAccount.Explicit {

    public func isAddressForLocalUser(_ address: SignalServiceAddress) -> Bool {
        return localIdentifiers.contains(address: address)
    }

    public var localIdentifiers: LocalIdentifiers {
        return LocalIdentifiers(aci: aci, pni: phoneNumber.pni, e164: phoneNumber.e164)
    }

    public var chatServiceAuth: ChatServiceAuth {
        return .explicit(aci: aci, deviceId: deviceId, password: authPassword)
    }
}
