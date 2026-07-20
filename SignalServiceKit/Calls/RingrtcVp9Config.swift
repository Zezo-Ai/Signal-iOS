//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Utility for deciding whether to offer VP9
public enum RingrtcVp9Config {
    public static func enableVp9Encode(with remoteConfig: RemoteConfig) -> Bool {
        if DebugFlags.callingForceVp9On.get() {
            return true
        }
        if DebugFlags.callingForceVp9Off.get() {
            return false
        }

        guard let hwIdentifier = String(sysctlKey: "hw.machine") else {
            return false
        }

        return remoteConfig.ringrtcVp9Enabled &&
            !remoteConfig.ringrtcVp9DeviceModelEncodeDenylist.contains(hwIdentifier)
    }

    public static func enableVp9Decode(with remoteConfig: RemoteConfig) -> Bool {
        if DebugFlags.callingForceVp9On.get() {
            return true
        }
        if DebugFlags.callingForceVp9Off.get() {
            return false
        }

        guard let hwIdentifier = String(sysctlKey: "hw.machine") else {
            return false
        }

        return remoteConfig.ringrtcVp9Enabled &&
            !remoteConfig.ringrtcVp9DeviceModelDecodeDenylist.contains(hwIdentifier)
    }
}
