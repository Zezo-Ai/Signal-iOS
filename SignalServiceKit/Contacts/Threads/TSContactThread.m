//
// Copyright 2018 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

#import "TSContactThread.h"
#import <SignalServiceKit/SignalServiceKit-Swift.h>

NS_ASSUME_NONNULL_BEGIN

NSString *const TSContactThreadLegacyPrefix = @"c";
NSUInteger const TSContactThreadSchemaVersion = 1;

@interface TSContactThread ()

@property (nonatomic, readonly) NSUInteger contactThreadSchemaVersion;

@end

#pragma mark -

@implementation TSContactThread

#pragma mark - Dependencies

+ (ContactThreadFinder *)threadFinder
{
    return [ContactThreadFinder new];
}

#pragma mark -

// --- CODE GENERATION MARKER

// This snippet is generated by /Scripts/sds_codegen/sds_generate.py. Do not manually edit it, instead run
// `sds_codegen.sh`.

// clang-format off

- (instancetype)initWithGrdbId:(int64_t)grdbId
                      uniqueId:(NSString *)uniqueId
   conversationColorNameObsolete:(NSString *)conversationColorNameObsolete
                    creationDate:(nullable NSDate *)creationDate
             editTargetTimestamp:(nullable NSNumber *)editTargetTimestamp
              isArchivedObsolete:(BOOL)isArchivedObsolete
          isMarkedUnreadObsolete:(BOOL)isMarkedUnreadObsolete
       lastDraftInteractionRowId:(uint64_t)lastDraftInteractionRowId
        lastDraftUpdateTimestamp:(uint64_t)lastDraftUpdateTimestamp
            lastInteractionRowId:(uint64_t)lastInteractionRowId
          lastSentStoryTimestamp:(nullable NSNumber *)lastSentStoryTimestamp
       lastVisibleSortIdObsolete:(uint64_t)lastVisibleSortIdObsolete
lastVisibleSortIdOnScreenPercentageObsolete:(double)lastVisibleSortIdOnScreenPercentageObsolete
         mentionNotificationMode:(TSThreadMentionNotificationMode)mentionNotificationMode
                    messageDraft:(nullable NSString *)messageDraft
          messageDraftBodyRanges:(nullable MessageBodyRanges *)messageDraftBodyRanges
          mutedUntilDateObsolete:(nullable NSDate *)mutedUntilDateObsolete
     mutedUntilTimestampObsolete:(uint64_t)mutedUntilTimestampObsolete
           shouldThreadBeVisible:(BOOL)shouldThreadBeVisible
                   storyViewMode:(TSThreadStoryViewMode)storyViewMode
              contactPhoneNumber:(nullable NSString *)contactPhoneNumber
                     contactUUID:(nullable NSString *)contactUUID
              hasDismissedOffers:(BOOL)hasDismissedOffers
{
    self = [super initWithGrdbId:grdbId
                        uniqueId:uniqueId
     conversationColorNameObsolete:conversationColorNameObsolete
                      creationDate:creationDate
               editTargetTimestamp:editTargetTimestamp
                isArchivedObsolete:isArchivedObsolete
            isMarkedUnreadObsolete:isMarkedUnreadObsolete
         lastDraftInteractionRowId:lastDraftInteractionRowId
          lastDraftUpdateTimestamp:lastDraftUpdateTimestamp
              lastInteractionRowId:lastInteractionRowId
            lastSentStoryTimestamp:lastSentStoryTimestamp
         lastVisibleSortIdObsolete:lastVisibleSortIdObsolete
lastVisibleSortIdOnScreenPercentageObsolete:lastVisibleSortIdOnScreenPercentageObsolete
           mentionNotificationMode:mentionNotificationMode
                      messageDraft:messageDraft
            messageDraftBodyRanges:messageDraftBodyRanges
            mutedUntilDateObsolete:mutedUntilDateObsolete
       mutedUntilTimestampObsolete:mutedUntilTimestampObsolete
             shouldThreadBeVisible:shouldThreadBeVisible
                     storyViewMode:storyViewMode];

    if (!self) {
        return self;
    }

    _contactPhoneNumber = contactPhoneNumber;
    _contactUUID = contactUUID;
    _hasDismissedOffers = hasDismissedOffers;

    return self;
}

// clang-format on

// --- CODE GENERATION MARKER

- (nullable instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (self) {
        // Migrate legacy threads to store phone number and UUID
        if (_contactThreadSchemaVersion < 1) {
            _contactPhoneNumber = [[self class] legacyContactPhoneNumberFromThreadId:self.uniqueId];
        }

        _contactThreadSchemaVersion = TSContactThreadSchemaVersion;
    }
    return self;
}

- (instancetype)initWithContactUUID:(nullable NSString *)contactUUID
                 contactPhoneNumber:(nullable NSString *)contactPhoneNumber
{
    NSString *uniqueId = [[self class] generateUniqueId];

    if (self = [super initWithUniqueId:uniqueId]) {
        _contactUUID = [contactUUID copy];
        _contactPhoneNumber = [contactPhoneNumber copy];
        _contactThreadSchemaVersion = TSContactThreadSchemaVersion;
    }

    return self;
}

+ (instancetype)getOrCreateThreadWithContactAddress:(SignalServiceAddress *)contactAddress
                                        transaction:(DBWriteTransaction *)transaction
{
    OWSAssertDebug(contactAddress.isValid);

    TSContactThread *thread = [self.threadFinder contactThreadForAddress:contactAddress transaction:transaction];

    if (!thread) {
        thread = [[TSContactThread alloc] initWithContactAddress:contactAddress];
        [thread anyInsertWithTransaction:transaction];
    }

    return thread;
}

+ (instancetype)getOrCreateThreadWithContactAddress:(SignalServiceAddress *)contactAddress
{
    OWSAssertDebug(contactAddress.isValid);

    __block TSContactThread *thread;
    [SSKEnvironment.shared.databaseStorageRef readWithBlock:^(DBReadTransaction *transaction) {
        thread = [self getThreadWithContactAddress:contactAddress transaction:transaction];
    }];

    if (thread == nil) {
        // Only open a write transaction if necessary
        DatabaseStorageWrite(SSKEnvironment.shared.databaseStorageRef, ^(DBWriteTransaction *transaction) {
            thread = [self getOrCreateThreadWithContactAddress:contactAddress transaction:transaction];
        });
    }

    return thread;
}

+ (nullable instancetype)getThreadWithContactAddress:(SignalServiceAddress *)contactAddress
                                         transaction:(DBReadTransaction *)transaction
{
    return [self.threadFinder contactThreadForAddress:contactAddress transaction:transaction];
}

- (SignalServiceAddress *)contactAddress
{
    return [[SignalServiceAddress alloc] initWithServiceIdString:self.contactUUID phoneNumber:self.contactPhoneNumber];
}

- (NSArray<SignalServiceAddress *> *)recipientAddressesWithTransaction:(DBReadTransaction *)transaction
{
    return @[ self.contactAddress ];
}

- (BOOL)isNoteToSelf
{
    return self.contactAddress.isLocalAddress;
}

- (NSString *)colorSeed
{
    NSString *_Nullable phoneNumber = self.contactAddress.phoneNumber;
    if (!phoneNumber) {
        phoneNumber = [[self class] legacyContactPhoneNumberFromThreadId:self.uniqueId];
    }

    return phoneNumber ?: self.uniqueId;
}

- (BOOL)hasSafetyNumbers
{
    return [OWSIdentityManagerObjCBridge identityKeyForAddress:self.contactAddress] != nil;
}

+ (nullable SignalServiceAddress *)contactAddressFromThreadId:(NSString *)threadId
                                                  transaction:(DBReadTransaction *)transaction
{
    return [TSContactThread anyFetchContactThreadWithUniqueId:threadId transaction:transaction].contactAddress;
}

+ (nullable NSString *)legacyContactPhoneNumberFromThreadId:(NSString *)threadId
{
    if (![threadId hasPrefix:TSContactThreadLegacyPrefix]) {
        return nil;
    }

    return [threadId substringWithRange:NSMakeRange(1, threadId.length - 1)];
}

- (void)anyDidInsertWithTransaction:(DBWriteTransaction *)transaction
{
    [super anyDidInsertWithTransaction:transaction];

    OWSLogInfo(@"Inserted contact thread: %@", self.contactAddress);
}

@end

NS_ASSUME_NONNULL_END
