//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB
import LibSignalClient

struct GroupSendEndorsementStore {
    func saveEndorsements(
        groupThreadId: Int64,
        expiration: Date,
        combinedEndorsement: GroupSendEndorsement,
        individualEndorsements: [(recipientId: Int64, individualEndorsement: GroupSendEndorsement)],
        tx: DBWriteTransaction,
    ) {
        deleteEndorsements(groupThreadId: groupThreadId, tx: tx)
        insertCombinedEndorsement(CombinedGroupSendEndorsementRecord(
            threadId: groupThreadId,
            endorsement: combinedEndorsement.serialize(),
            expiration: expiration,
        ), tx: tx)
        for (recipientId, individualEndorsement) in individualEndorsements {
            insertIndividualEndorsement(IndividualGroupSendEndorsementRecord(
                threadId: groupThreadId,
                recipientId: recipientId,
                endorsement: individualEndorsement.serialize(),
            ), tx: tx)
        }
    }

    func fetchCombinedEndorsement(groupThreadId: Int64, tx: DBReadTransaction) -> CombinedGroupSendEndorsementRecord? {
        return failIfThrows {
            return try CombinedGroupSendEndorsementRecord.fetchOne(tx.database, key: groupThreadId)
        }
    }

    func fetchIndividualEndorsements(groupThreadId: Int64, tx: DBReadTransaction) -> [IndividualGroupSendEndorsementRecord] {
        return failIfThrows {
            return try IndividualGroupSendEndorsementRecord
                .filter(Column(IndividualGroupSendEndorsementRecord.CodingKeys.threadId) == groupThreadId)
                .fetchAll(tx.database)
        }
    }

    func fetchIndividualEndorsement(groupThreadId: Int64, recipientId: SignalRecipient.RowId, tx: DBReadTransaction) -> IndividualGroupSendEndorsementRecord? {
        return failIfThrows {
            return try IndividualGroupSendEndorsementRecord
                .filter(Column(IndividualGroupSendEndorsementRecord.CodingKeys.threadId) == groupThreadId)
                .filter(Column(IndividualGroupSendEndorsementRecord.CodingKeys.recipientId) == recipientId)
                .fetchOne(tx.database)
        }
    }

    func deleteEndorsements(groupThreadId: Int64, tx: DBWriteTransaction) {
        failIfThrows {
            try CombinedGroupSendEndorsementRecord.deleteOne(tx.database, key: groupThreadId)
        }
    }

    func insertCombinedEndorsement(_ endorsementRecord: CombinedGroupSendEndorsementRecord, tx: DBWriteTransaction) {
        failIfThrows {
            try endorsementRecord.insert(tx.database)
        }
    }

    func insertIndividualEndorsement(_ endorsementRecord: IndividualGroupSendEndorsementRecord, tx: DBWriteTransaction) {
        failIfThrows {
            try endorsementRecord.insert(tx.database)
        }
    }
}
