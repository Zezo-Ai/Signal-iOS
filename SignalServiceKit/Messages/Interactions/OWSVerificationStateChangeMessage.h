//
// Copyright 2018 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

#import <SignalServiceKit/OWSRecipientIdentity.h>
#import <SignalServiceKit/TSInfoMessage.h>

NS_ASSUME_NONNULL_BEGIN

@class SignalServiceAddress;
@class TSThread;

@interface OWSVerificationStateChangeMessage : TSInfoMessage

@property (nonatomic, readonly) SignalServiceAddress *recipientAddress;
@property (nonatomic, readonly) OWSVerificationState verificationState;
@property (nonatomic, readonly) BOOL isLocalChange;

/// Whether or not this message is reporting the user to be verified.
- (bool)isVerified;

- (instancetype)initWithThread:(TSThread *)thread messageType:(TSInfoMessageType)infoMessage NS_UNAVAILABLE;

- (instancetype)initWithThread:(TSThread *)thread
                   messageType:(TSInfoMessageType)messageType
           infoMessageUserInfo:(NSDictionary<InfoMessageUserInfoKey, id> *)infoMessageUserInfo NS_UNAVAILABLE;

- (instancetype)initWithThread:(TSThread *)thread
                     timestamp:(uint64_t)timestamp
                    serverGuid:(nullable NSString *)serverGuid
                   messageType:(TSInfoMessageType)infoMessage
           infoMessageUserInfo:(nullable NSDictionary<InfoMessageUserInfoKey, id> *)infoMessageUserInfo NS_UNAVAILABLE;

- (instancetype)initWithGrdbId:(int64_t)grdbId
                        uniqueId:(NSString *)uniqueId
             receivedAtTimestamp:(uint64_t)receivedAtTimestamp
                          sortId:(uint64_t)sortId
                       timestamp:(uint64_t)timestamp
                  uniqueThreadId:(NSString *)uniqueThreadId
                   attachmentIds:(NSArray<NSString *> *)attachmentIds
                            body:(nullable NSString *)body
                      bodyRanges:(nullable MessageBodyRanges *)bodyRanges
                    contactShare:(nullable OWSContact *)contactShare
                       editState:(TSEditState)editState
                 expireStartedAt:(uint64_t)expireStartedAt
              expireTimerVersion:(nullable NSNumber *)expireTimerVersion
                       expiresAt:(uint64_t)expiresAt
                expiresInSeconds:(unsigned int)expiresInSeconds
                       giftBadge:(nullable OWSGiftBadge *)giftBadge
               isGroupStoryReply:(BOOL)isGroupStoryReply
              isViewOnceComplete:(BOOL)isViewOnceComplete
               isViewOnceMessage:(BOOL)isViewOnceMessage
                     linkPreview:(nullable OWSLinkPreview *)linkPreview
                  messageSticker:(nullable MessageSticker *)messageSticker
                   quotedMessage:(nullable TSQuotedMessage *)quotedMessage
    storedShouldStartExpireTimer:(BOOL)storedShouldStartExpireTimer
           storyAuthorUuidString:(nullable NSString *)storyAuthorUuidString
              storyReactionEmoji:(nullable NSString *)storyReactionEmoji
                  storyTimestamp:(nullable NSNumber *)storyTimestamp
              wasRemotelyDeleted:(BOOL)wasRemotelyDeleted
                   customMessage:(nullable NSString *)customMessage
             infoMessageUserInfo:(nullable NSDictionary<InfoMessageUserInfoKey, id> *)infoMessageUserInfo
                     messageType:(TSInfoMessageType)messageType
                            read:(BOOL)read
                      serverGuid:(nullable NSString *)serverGuid
             unregisteredAddress:(nullable SignalServiceAddress *)unregisteredAddress NS_UNAVAILABLE;

- (instancetype)initWithThread:(TSThread *)thread
                     timestamp:(uint64_t)timestamp
              recipientAddress:(SignalServiceAddress *)recipientAddress
             verificationState:(OWSVerificationState)verificationState
                 isLocalChange:(BOOL)isLocalChange NS_DESIGNATED_INITIALIZER;

- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_DESIGNATED_INITIALIZER;

// --- CODE GENERATION MARKER

// This snippet is generated by /Scripts/sds_codegen/sds_generate.py. Do not manually edit it, instead run
// `sds_codegen.sh`.

// clang-format off

- (instancetype)initWithGrdbId:(int64_t)grdbId
                      uniqueId:(NSString *)uniqueId
             receivedAtTimestamp:(uint64_t)receivedAtTimestamp
                          sortId:(uint64_t)sortId
                       timestamp:(uint64_t)timestamp
                  uniqueThreadId:(NSString *)uniqueThreadId
                   attachmentIds:(NSArray<NSString *> *)attachmentIds
                            body:(nullable NSString *)body
                      bodyRanges:(nullable MessageBodyRanges *)bodyRanges
                    contactShare:(nullable OWSContact *)contactShare
                       editState:(TSEditState)editState
                 expireStartedAt:(uint64_t)expireStartedAt
              expireTimerVersion:(nullable NSNumber *)expireTimerVersion
                       expiresAt:(uint64_t)expiresAt
                expiresInSeconds:(unsigned int)expiresInSeconds
                       giftBadge:(nullable OWSGiftBadge *)giftBadge
               isGroupStoryReply:(BOOL)isGroupStoryReply
              isViewOnceComplete:(BOOL)isViewOnceComplete
               isViewOnceMessage:(BOOL)isViewOnceMessage
                     linkPreview:(nullable OWSLinkPreview *)linkPreview
                  messageSticker:(nullable MessageSticker *)messageSticker
                   quotedMessage:(nullable TSQuotedMessage *)quotedMessage
    storedShouldStartExpireTimer:(BOOL)storedShouldStartExpireTimer
           storyAuthorUuidString:(nullable NSString *)storyAuthorUuidString
              storyReactionEmoji:(nullable NSString *)storyReactionEmoji
                  storyTimestamp:(nullable NSNumber *)storyTimestamp
              wasRemotelyDeleted:(BOOL)wasRemotelyDeleted
                   customMessage:(nullable NSString *)customMessage
             infoMessageUserInfo:(nullable NSDictionary<InfoMessageUserInfoKey, id> *)infoMessageUserInfo
                     messageType:(TSInfoMessageType)messageType
                            read:(BOOL)read
                      serverGuid:(nullable NSString *)serverGuid
             unregisteredAddress:(nullable SignalServiceAddress *)unregisteredAddress
                   isLocalChange:(BOOL)isLocalChange
                recipientAddress:(SignalServiceAddress *)recipientAddress
               verificationState:(OWSVerificationState)verificationState
NS_DESIGNATED_INITIALIZER NS_SWIFT_NAME(init(grdbId:uniqueId:receivedAtTimestamp:sortId:timestamp:uniqueThreadId:attachmentIds:body:bodyRanges:contactShare:editState:expireStartedAt:expireTimerVersion:expiresAt:expiresInSeconds:giftBadge:isGroupStoryReply:isViewOnceComplete:isViewOnceMessage:linkPreview:messageSticker:quotedMessage:storedShouldStartExpireTimer:storyAuthorUuidString:storyReactionEmoji:storyTimestamp:wasRemotelyDeleted:customMessage:infoMessageUserInfo:messageType:read:serverGuid:unregisteredAddress:isLocalChange:recipientAddress:verificationState:));

// clang-format on

// --- CODE GENERATION MARKER

@end

NS_ASSUME_NONNULL_END
