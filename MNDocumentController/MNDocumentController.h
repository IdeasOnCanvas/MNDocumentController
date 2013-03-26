//
//  MNDocumentController.h
//  MindNodeTouch
//
//  Created by Markus Müller on 22.12.08.
//  Copyright 2008 IdeasOnCanvas GmbH. All rights reserved.
//

#import <Foundation/Foundation.h>
@class MNDocumentReference;
@class MNDocument;

extern NSString *MNDocumentControllerDocumentReferencesKey;
extern NSString *MNDocumentControllerDidChangeStateNotification;



enum {
    MNDocumentControllerStateNormal          = 0,
    MNDocumentControllerStateLoading          = 1 << 0
};
typedef NSInteger MNDocumentControllerState;



@interface MNDocumentController : NSObject 

+ (MNDocumentController *)sharedDocumentController;


#pragma mark - Documents

@property(readonly) MNDocumentControllerState controllerState;
@property (readonly) BOOL documentsInCloud;
@property (readonly,strong) NSMutableSet *documentReferences;
- (void)reloadLocalDocuments;


#pragma mark - Document Manipulation

- (void)createNewDocumentWithCompletionHandler:(void (^)(MNDocument *document, MNDocumentReference *reference))completionHandler;
- (void)deleteDocument:(MNDocumentReference *)document completionHandler:(void (^)(NSError *errorOrNil))completionHandler;
- (void)duplicateDocument:(MNDocumentReference *)document completionHandler:(void (^)(NSError *errorOrNil))completionHandler;
- (void)renameDocument:(MNDocumentReference *)document toFileName:(NSString *)fileName completionHandler:(void (^)(NSError *errorOrNil))completionHandler;
- (void)performAsynchronousFileAccessUsingBlock:(void (^)(void))block;
- (BOOL)pendingDocumentTransfers;
- (void)disableiCloudAndCopyAllCloudDocumentsToLocalWithCompletionHandler:(void (^)(NSError *errorOrNil))completionHandler;
- (void)moveAllCloudDocumentsToLocalWithCompletionHandler:(void (^)(NSError *errorOrNil))completionHandler;
- (void)moveAllLocalDocumentsToCloudWithCompletionHandler:(void (^)(void))completionHandler;
- (void)importDocumentAtURL:(NSURL *)url completionHandler:(void (^)(MNDocumentReference *reference, NSError *errorOrNil))completionHandler;
- (void)evictAllCloudDocumentsWithCompletionHandler:(void (^)(void))completionHandler progressUpdateHandler:(void (^)(CGFloat progress))progressUpdateHandler;

#pragma mark - Paths

+ (NSURL *)localDocumentsURL;
+ (NSURL *)ubiquitousContainerURL;
+ (NSURL *)ubiquitousDocumentsURL; 
- (NSString *)uniqueFileNameForDisplayName:(NSString *)displayName;
+ (NSString *)uniqueFileNameForDisplayName:(NSString *)displayName extension:(NSString *)extension usedFileNames:(NSSet *)usedFileNames;
+ (NSString *)uniqueFileNameForDisplayName:(NSString *)displayName extension:(NSString *)extension inDirectory:(NSURL *)directionaryURL;


@end
