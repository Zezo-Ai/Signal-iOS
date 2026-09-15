//
// Copyright 2025 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
public import LibSignalClient

public struct LinkingProvisioningMessage {

    public enum Constants {
        public static let provisioningVersion: UInt32 = 1
        public static let userAgent: String = "OWI"
    }

    public let aep: AccountEntropyPool
    public let aci: Aci
    public let phoneNumber: String
    public let pni: Pni
    public let aciIdentityKeyPair: IdentityKeyPair
    public let pniIdentityKeyPair: IdentityKeyPair
    public let profileKey: Aes256Key
    public let mrbk: MediaRootBackupKey
    public let ephemeralBackupKey: MessageRootBackupKey?
    public let areReadReceiptsEnabled: Bool
    public let provisioningCode: String
    public let provisioningUserAgent: String?
    public let provisioningVersion: UInt32

    public init(
        aep: AccountEntropyPool,
        aci: Aci,
        phoneNumber: String,
        pni: Pni,
        aciIdentityKeyPair: IdentityKeyPair,
        pniIdentityKeyPair: IdentityKeyPair,
        profileKey: Aes256Key,
        mrbk: MediaRootBackupKey,
        ephemeralBackupKey: MessageRootBackupKey?,
        areReadReceiptsEnabled: Bool,
        provisioningCode: String,
        provisioningUserAgent: String? = Constants.userAgent,
        provisioningVersion: UInt32 = Constants.provisioningVersion,
    ) {
        self.aep = aep
        self.aci = aci
        self.phoneNumber = phoneNumber
        self.pni = pni
        self.aciIdentityKeyPair = aciIdentityKeyPair
        self.pniIdentityKeyPair = pniIdentityKeyPair
        self.profileKey = profileKey
        self.mrbk = mrbk
        self.ephemeralBackupKey = ephemeralBackupKey
        self.areReadReceiptsEnabled = areReadReceiptsEnabled
        self.provisioningCode = provisioningCode
        self.provisioningUserAgent = provisioningUserAgent
        self.provisioningVersion = provisioningVersion
    }

    public init(_ proto: ProvisioningProtos_ProvisionMessage) throws {
        self.aciIdentityKeyPair = try IdentityKeyPair(
            publicKey: PublicKey(proto.aciIdentityKeyPublic),
            privateKey: PrivateKey(proto.aciIdentityKeyPrivate),
        )

        self.pniIdentityKeyPair = try IdentityKeyPair(
            publicKey: PublicKey(proto.pniIdentityKeyPublic),
            privateKey: PrivateKey(proto.pniIdentityKeyPrivate),
        )

        guard let profileKey = Aes256Key(data: proto.profileKey) else {
            throw OWSGenericError("invalid profileKey - count: \(proto.profileKey.count)")
        }
        self.profileKey = profileKey

        self.areReadReceiptsEnabled = proto.readReceipts // defaults to false
        self.provisioningCode = proto.provisioningCode

        self.provisioningUserAgent = proto.userAgent
        let provisioningVersion = proto.provisioningVersion
        self.provisioningVersion = provisioningVersion

        guard proto.number.count > 1 else {
            throw OWSGenericError("missing number from provisioning message")
        }
        self.phoneNumber = proto.number

        self.aci = try {
            guard let aci = Aci.parseFrom(serviceIdBinary: proto.aciBinary, serviceIdString: proto.aci) else {
                throw OWSGenericError("invalid ACI from provisioning message")
            }
            return aci
        }()

        self.pni = try {
            if proto.hasPniBinary {
                guard let pniUuid = UUID(data: proto.pniBinary) else {
                    throw OWSGenericError("invalid PNI from provisioning message")
                }
                return Pni(fromUUID: pniUuid)
            }
            if proto.hasPni {
                guard let pni = Pni.parseFrom(ambiguousString: proto.pni) else {
                    throw OWSGenericError("invalid PNI from provisioning message")
                }
                return pni
            }
            throw OWSGenericError("invalid PNI from provisioning message")
        }()

        self.aep = try AccountEntropyPool(key: proto.accountEntropyPool)

        self.mrbk = MediaRootBackupKey(backupKey: try BackupKey(contents: proto.mediaRootBackupKey))

        var ephemeralBackupKey: MessageRootBackupKey?
        if proto.hasEphemeralBackupKey {
            ephemeralBackupKey = MessageRootBackupKey(
                backupKey: try BackupKey(contents: proto.ephemeralBackupKey),
                aci: self.aci,
            )
        }
        self.ephemeralBackupKey = ephemeralBackupKey
    }

    public func buildEncryptedMessageBody(theirPublicKey: PublicKey) throws -> Data {
        var message = ProvisioningProtos_ProvisionMessage()
        message.aciIdentityKeyPublic = aciIdentityKeyPair.publicKey.serialize()
        message.aciIdentityKeyPrivate = aciIdentityKeyPair.privateKey.serialize()
        message.pniIdentityKeyPublic = pniIdentityKeyPair.publicKey.serialize()
        message.pniIdentityKeyPrivate = pniIdentityKeyPair.privateKey.serialize()
        message.provisioningCode = provisioningCode
        message.profileKey = profileKey.keyData
        message.userAgent = Constants.userAgent
        message.readReceipts = areReadReceiptsEnabled
        message.provisioningVersion = Constants.provisioningVersion
        message.number = phoneNumber
        message.aciBinary = aci.rawUUID.data
        message.pniBinary = pni.rawUUID.data
        message.accountEntropyPool = aep.rawString
        message.mediaRootBackupKey = mrbk.serialize()
        if let ephemeralBackupKey {
            message.ephemeralBackupKey = ephemeralBackupKey.serialize()
        }

        let plainTextProvisionMessage = try message.serializedData()

        // Note that this is a one-time-use *cipher* public key, not our Signal *identity* public key
        let ourKeyPair = IdentityKeyPair.generate()
        let cipher = ProvisioningCipher(ourKeyPair: ourKeyPair)
        let encryptedProvisionMessage: Data
        do {
            encryptedProvisionMessage = try cipher.encrypt(
                plainTextProvisionMessage,
                theirPublicKey: theirPublicKey,
            )
        } catch {
            throw OWSAssertionError("Failed to encrypt provision message")
        }

        var envelope = ProvisioningProtos_ProvisionEnvelope()
        envelope.publicKey = ourKeyPair.publicKey.serialize()
        envelope.body = encryptedProvisionMessage
        return try envelope.serializedData()
    }
}
