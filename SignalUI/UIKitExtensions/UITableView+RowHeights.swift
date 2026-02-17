//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

extension UITableView {
    /// Force the table view to recompute the height of its rows.
    ///
    /// Useful for tables with rows that use AutoLayout and need to tell their
    /// owning table that their height may have changed, for example due to the
    /// contents of the cell having changed.
    public func recomputeRowHeights() {
        beginUpdates()
        endUpdates()
    }
}
