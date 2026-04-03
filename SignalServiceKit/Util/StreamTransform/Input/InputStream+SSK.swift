//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

extension InputStream {
    public func read(maxLength len: Int) throws -> Data {
        if len == 0 {
            return Data()
        }
        var buffer = Data(count: len)
        let bytesRead = buffer.withUnsafeMutableBytes { self.read($0.baseAddress!, maxLength: len) }
        return buffer.prefix(bytesRead)
    }
}
