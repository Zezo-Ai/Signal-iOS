//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import CryptoKit
import Foundation
import MultipeerConnectivity
import SignalServiceKit

struct DeviceTransferPeerID: Equatable {

    fileprivate let mcPeerID: MCPeerID

    fileprivate init(mcPeerID: MCPeerID) {
        self.mcPeerID = mcPeerID
    }

    init(displayName: String) {
        self.mcPeerID = MCPeerID(displayName: displayName)
    }

    init?(with peerIdData: Data) {
        guard let peerId = try? NSKeyedUnarchiver.unarchivedObject(ofClass: MCPeerID.self, from: peerIdData) else {
            return nil
        }
        self.mcPeerID = peerId
    }

    func encoded() throws -> Data {
        return try NSKeyedArchiver.archivedData(withRootObject: mcPeerID, requiringSecureCoding: true)
    }
}

protocol DeviceTransferSession {

    var identity: SecIdentity { get }
    var delegate: DeviceTransferSessionDelegate? { get set }
    var peerId: DeviceTransferPeerID { get }

    func disconnect()

    func send(
        _ data: Data,
        toPeers peerIDs: [DeviceTransferPeerID],
        with mode: TransferSessionSendDataMode,
    ) throws

    func sendResource(
        at resourceURL: URL,
        withName resourceName: String,
        toPeer peerID: DeviceTransferPeerID,
        withCompletionHandler: (((any Error)?) -> Void)?,
    ) -> Progress?
}

protocol DeviceTransferServiceBrowser {
    func invitePeer(
        _ peer: DeviceTransferPeerID,
    ) throws -> DeviceTransferSession

    func startBrowsing()

    func stopBrowsing()
}

protocol DeviceTransferServiceAdvertiser {
    func startAdvertising() throws -> DeviceTransferSession

    func stopAdvertising()
}

private enum DeviceTransferConstants {
    // This must also be updated in the info.plist
    fileprivate static let newDeviceServiceIdentifier = "sgnl-new-device"
}

enum TransferSessionState: String {
    case notConnected
    case connecting
    case connected
}

enum TransferSessionSendDataMode {
    case reliable
    case unreliable
}

protocol DeviceTransferSessionDelegate: AnyObject {
    func session(
        _ session: DeviceTransferSession,
        peer peerId: DeviceTransferPeerID,
        didChange state: TransferSessionState,
    )

    func session(
        _ session: DeviceTransferSession,
        didReceive data: Data,
        fromPeer peerId: DeviceTransferPeerID,
    )

    func session(
        _ session: DeviceTransferSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerId: DeviceTransferPeerID,
        with fileProgress: Progress,
    )

    func session(
        _ session: DeviceTransferSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerId: DeviceTransferPeerID,
        at localURL: URL?,
        withError error: Swift.Error?,
    )

    func session(
        _ session: DeviceTransferSession,
        didReceiveCertificate certificates: [Any]?,
        fromPeer peerId: DeviceTransferPeerID,
        certificateHandler: @escaping (Bool) -> Void,
    )
}

private extension MCSessionState {
    var asTransferSessionState: TransferSessionState {
        switch self {
        case .notConnected: .notConnected
        case .connecting: .connecting
        case .connected: .connected
        @unknown default: .notConnected
        }
    }
}

enum TransferSessionDirection {
    case incoming
    case outgoing
}

private extension TransferSessionDirection {
    var identityName: String {
        switch self {
        case .incoming: "IncomingDeviceTransfer"
        case .outgoing: "OutgoingDeviceTransfer"
        }
    }
}

private extension TransferSessionSendDataMode {
    var asMCSessionSendDataMode: MCSessionSendDataMode {
        switch self {
        case .reliable: .reliable
        case .unreliable: .unreliable
        }
    }
}

protocol DeviceTransferServiceBrowserDelegate: AnyObject {
    func deviceTransferServiceDiscoveredNewDevice(peerId: DeviceTransferPeerID)
}

enum MPCDeviceTransfer {

    class Browser: NSObject, DeviceTransferServiceBrowser, MCNearbyServiceBrowserDelegate {

        let browser: MCNearbyServiceBrowser
        weak var delegate: DeviceTransferServiceBrowserDelegate?
        let peerId: DeviceTransferPeerID

        init(peerId: DeviceTransferPeerID) {
            browser = MCNearbyServiceBrowser(
                peer: peerId.mcPeerID,
                serviceType: DeviceTransferConstants.newDeviceServiceIdentifier,
            )
            self.peerId = peerId
            super.init()
            browser.delegate = self
        }

        func invitePeer(_ peer: DeviceTransferPeerID) throws -> DeviceTransferSession {
            let session = try Session(direction: .outgoing, peerID: self.peerId.mcPeerID)
            browser.invitePeer(
                peer.mcPeerID,
                to: session.session,
                withContext: nil,
                timeout: 30,
            )
            return session
        }

        func startBrowsing() {
            browser.startBrowsingForPeers()
        }

        func stopBrowsing() {
            browser.stopBrowsingForPeers()
        }

        func browser(
            _ browser: MCNearbyServiceBrowser,
            foundPeer newDevicePeerID: MCPeerID,
            withDiscoveryInfo info: [String: String]?,
        ) {
            Logger.info("Notifying of discovered new device \(newDevicePeerID)")
            let peerIDWrapper = DeviceTransferPeerID(mcPeerID: newDevicePeerID)
            delegate?.deviceTransferServiceDiscoveredNewDevice(peerId: peerIDWrapper)
        }

        func browser(
            _ browser: MCNearbyServiceBrowser,
            didNotStartBrowsingForPeers error: Swift.Error,
        ) {
            Logger.warn("Failed to start browsing for peers \(error)")
        }

        func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerId: MCPeerID) {
            Logger.warn("Lost peer \(peerId)")
        }
    }

    class Advertiser: NSObject, DeviceTransferServiceAdvertiser, MCNearbyServiceAdvertiserDelegate {
        let peerId: DeviceTransferPeerID
        var session: Session!
        let advertiser: MCNearbyServiceAdvertiser

        init(peerId: DeviceTransferPeerID) {
            self.peerId = peerId
            advertiser = MCNearbyServiceAdvertiser(
                peer: peerId.mcPeerID,
                discoveryInfo: nil,
                serviceType: DeviceTransferConstants.newDeviceServiceIdentifier,
            )
            super.init()
            advertiser.delegate = self
        }

        func startAdvertising() throws -> DeviceTransferSession {
            self.session = try Session(direction: .incoming, peerID: peerId.mcPeerID)
            advertiser.startAdvertisingPeer()
            return session
        }

        func stopAdvertising() {
            advertiser.stopAdvertisingPeer()
        }

        func advertiser(
            _ advertiser: MCNearbyServiceAdvertiser,
            didReceiveInvitationFromPeer peerId: MCPeerID,
            withContext context: Data?,
            invitationHandler: @escaping (Bool, MCSession?) -> Void,
        ) {
            Logger.info("Accepting invitation from old device \(peerId)")
            invitationHandler(true, session.session)
        }

        func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Swift.Error) {
            Logger.warn("Failed to start advertising for peers \(error)")
        }
    }

    class Session: NSObject, DeviceTransferSession, MCSessionDelegate {

        // Create an identity to use for our TLS sessions, the old device
        // will verify this identity via the QR code
        // We don't actually need to generate an identity for the old device, the new device
        // doesn't verify this information. We do it anyway, for consistency.
        let identity: SecIdentity
        var peerId: DeviceTransferPeerID { DeviceTransferPeerID(mcPeerID: session.myPeerID) }

        fileprivate let session: MCSession
        weak var delegate: DeviceTransferSessionDelegate?

        fileprivate init(direction: TransferSessionDirection, peerID: MCPeerID) throws {
            self.identity = try SelfSignedIdentity.create(name: direction.identityName, validForDays: 1)
            let session = MCSession(peer: peerID, securityIdentity: [identity], encryptionPreference: .required)
            self.session = session
            super.init()
            session.delegate = self
        }

        func disconnect() {
            self.session.disconnect()
        }

        func send(
            _ data: Data,
            toPeers peerIDs: [DeviceTransferPeerID],
            with mode: TransferSessionSendDataMode,
        ) throws {
            try session.send(
                data,
                toPeers: peerIDs.map(\.mcPeerID),
                with: mode.asMCSessionSendDataMode,
            )
        }

        func sendResource(
            at resourceURL: URL,
            withName resourceName: String,
            toPeer peerID: DeviceTransferPeerID,
            withCompletionHandler: (((any Error)?) -> Void)?,
        ) -> Progress? {
            return session.sendResource(at: resourceURL, withName: resourceName, toPeer: peerID.mcPeerID) { error in
                withCompletionHandler?(error)
            }
        }

        // MARK: - MCSessionDelegate

        func session(
            _ session: MCSession,
            peer peerId: MCPeerID,
            didChange state: MCSessionState,
        ) {
            delegate?.session(
                self,
                peer: DeviceTransferPeerID(mcPeerID: peerId),
                didChange: state.asTransferSessionState,
            )
        }

        func session(
            _ session: MCSession,
            didReceive data: Data,
            fromPeer peerId: MCPeerID,
        ) {
            delegate?.session(
                self,
                didReceive: data,
                fromPeer: DeviceTransferPeerID(mcPeerID: peerId),
            )
        }

        func session(
            _ session: MCSession,
            didReceive stream: InputStream,
            withName streamName: String,
            fromPeer peerId: MCPeerID,
        ) { }

        func session(
            _ session: MCSession,
            didStartReceivingResourceWithName resourceName: String,
            fromPeer peerId: MCPeerID,
            with fileProgress: Progress,
        ) {
            delegate?.session(
                self,
                didStartReceivingResourceWithName: resourceName,
                fromPeer: DeviceTransferPeerID(mcPeerID: peerId),
                with: fileProgress,
            )
        }

        func session(
            _ session: MCSession,
            didFinishReceivingResourceWithName resourceName: String,
            fromPeer peerId: MCPeerID,
            at localURL: URL?,
            withError error: Swift.Error?,
        ) {
            delegate?.session(
                self,
                didFinishReceivingResourceWithName: resourceName,
                fromPeer: DeviceTransferPeerID(mcPeerID: peerId),
                at: localURL,
                withError: error,
            )
        }

        func session(
            _ session: MCSession,
            didReceiveCertificate certificates: [Any]?,
            fromPeer peerId: MCPeerID,
            certificateHandler: @escaping (Bool) -> Void,
        ) {
            delegate?.session(
                self,
                didReceiveCertificate: certificates,
                fromPeer: DeviceTransferPeerID(mcPeerID: peerId),
                certificateHandler: certificateHandler,
            )
        }
    }
}
