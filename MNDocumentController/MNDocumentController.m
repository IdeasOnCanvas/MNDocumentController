//
//  MNDocumentController.h
//  MindNodeTouch
//
//  Created by Markus Müller on 22.12.08.
//  Copyright 2008 IdeasOnCanvas GmbH. All rights reserved.
//

#import "MNDocumentController.h"
#import "MNDocumentReference.h"
#import "MNError.h"
#import "MNDefaults.h"
#import "MNDocument.h"
#import "MNDocumentController+Convenience.h"
#import "NSString+UUID.h"

// Keys
NSString *MNDocumentControllerDocumentReferencesKey = @"documentReferences";
NSString *MNDocumentControllerDidChangeStateNotification = @"MNDocumentControllerDidChangeStateNotification";
typedef void (^MNDequeueBlockForMetadataQueryDidFinish)();

@interface MNDocumentController ()

@property(readwrite) MNDocumentControllerState controllerState;
@property(readwrite, strong) NSMutableSet *documentReferences;
@property(readwrite, strong) NSOperationQueue *fileAccessWorkingQueue;
@property(readwrite, copy) MNDequeueBlockForMetadataQueryDidFinish dequeueBlockForMetadataQueryDidFinish;
@property(strong) NSMetadataQuery *iCloudMetadataQuery;

@end

@interface MNDocumentReference ()
@property (readwrite,strong) NSURL *fileURL;
@end


@implementation MNDocumentController

#pragma mark - Init

+ (MNDocumentController *)sharedDocumentController 
{
    static MNDocumentController *sharedDocumentController = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedDocumentController = [MNDocumentController alloc];
        sharedDocumentController = [sharedDocumentController init];
    });
    
    return sharedDocumentController;
}


- (id)init 
{
	self = [super init];
	if (self == nil) return self;
	
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
	[center addObserver:self selector:@selector(applicationWillTerminate:) name:UIApplicationWillTerminateNotification object:nil];
	[center addObserver:self selector:@selector(applicationDidEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [center addObserver:self selector:@selector(applicationWillEnterForeground:) name:UIApplicationWillEnterForegroundNotification object:nil];
    [center addObserver:self selector:@selector(userDefaultsDidChange:) name:NSUserDefaultsDidChangeNotification object:nil];

    NSOperationQueue *queue = [[NSOperationQueue alloc] init];
    [queue setName:@"MNDocumentController Working Queue"];
    [queue setMaxConcurrentOperationCount:1];
    self.fileAccessWorkingQueue = queue;

    self.documentReferences = [NSMutableSet setWithCapacity:10];
    [self reloadLocalDocuments];
    [self _startMetadataQuery];
    
    self.controllerState = (self.documentsInCloud) ? MNDocumentControllerStateLoading : MNDocumentControllerStateNormal;
	
	return self;
}

- (void)dealloc 
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];
    
    for (MNDocumentReference *currentReference in _documentReferences) {
        [currentReference disableFilePresenter]; // we need to do this to make sure FilePresenter get unregistered
    }
}


#pragma mark - Documents

- (BOOL)documentsInCloud
{
    return [[NSUserDefaults standardUserDefaults] boolForKey:MNDefaultsDocumentsInCloudKey] && [[self class] ubiquitousContainerURL];
}


// replaces all documents, also iCloud documents!
- (void)reloadLocalDocuments
{   
    for (MNDocumentReference *currentReference in [self.documentReferences copy]) {
        [self removeDocumentReferencesObject:currentReference];
    }
    [self.documentReferences removeAllObjects];
    
    for (MNDocumentReference *currentReference in [self _localDocumentReferences]) {
        [self addDocumentReferencesObject:currentReference];
    }
}



- (NSSet *)_localDocumentReferences
{
    NSMutableSet *results = [NSMutableSet setWithCapacity:0];
    
    NSURL *documentDirectory = [[self class] localDocumentsURL];
    if (!documentDirectory) return results;
    
    // create file coordinator to request folder read access
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    NSError *readError = nil;
    
    [coordinator coordinateReadingItemAtURL:documentDirectory options:NSFileCoordinatorReadingWithoutChanges error:&readError byAccessor: ^(NSURL *readURL) {
        
        NSFileManager *fileManager = [[NSFileManager alloc] init];
        NSError *error = nil;
        NSArray *fileURLs = [fileManager contentsOfDirectoryAtURL:readURL includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:0 error:&error];
        if (!fileURLs) {
            NSLog(@"Failed to scan documents.");
            return;
        }
        
        for (NSURL *currentFileURL in fileURLs) {
            
            if ([[currentFileURL pathExtension] isEqualToString:MNDocumentMindNodeExtension]) {
                
                // create a new reference
                NSDate *modificationDate = nil;
                NSDictionary *attributes = [fileManager attributesOfItemAtPath:[currentFileURL path] error:NULL];
                if (attributes) {
                    modificationDate = [attributes fileModificationDate];
                }
                if (!modificationDate) {
                    modificationDate = [NSDate date];
                }
                
                MNDocumentReference *reference = [[MNDocumentReference alloc] initWithFileURL:currentFileURL modificationDate:modificationDate];
                [results addObject:reference];
            } else {
                
                // this is a work around for a bug in the document migration in 2.1
                // check if folders without the MindNode extension have a content xml
                NSNumber *isDirectory = nil;
                NSError *resourceError = nil;
                if ([currentFileURL getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:&resourceError] && [isDirectory boolValue]) {
                    NSArray *folderFileURLs = [fileManager contentsOfDirectoryAtURL:currentFileURL includingPropertiesForKeys:nil options:0 error:&error];
                    BOOL isDocument = NO;
                    for (NSURL *currentFolderURL in folderFileURLs) {
                        if ([[currentFolderURL lastPathComponent] isEqualToString:@"contents.xml"]){
                            isDocument = YES;
                            break;
                        }
                    }
                    
                    if (isDocument) {
                        // don't do a coordinated write
                        NSURL *destinationURL = [currentFileURL URLByAppendingPathExtension:MNDocumentMindNodeExtension];
                        BOOL success = [fileManager moveItemAtURL:currentFileURL toURL:destinationURL error:NULL];
                        if (!success) {
                            destinationURL = [[currentFileURL URLByDeletingLastPathComponent] URLByAppendingPathComponent:[NSString mn_stringWithUUID]];
                            destinationURL = [destinationURL URLByAppendingPathExtension:MNDocumentMindNodeExtension];
                            [fileManager moveItemAtURL:currentFileURL toURL:destinationURL error:NULL];
                        }
                        
                        // create a new reference
                        NSDate *modificationDate = nil;
                        NSDictionary *attributes = [fileManager attributesOfItemAtPath:[destinationURL path] error:NULL];
                        if (attributes) {
                            modificationDate = [attributes fileModificationDate];
                        }
                        if (!modificationDate) {
                            modificationDate = [NSDate date];
                        }
                        
                        MNDocumentReference *reference = [[MNDocumentReference alloc] initWithFileURL:destinationURL modificationDate:modificationDate];
                        [results addObject:reference];

                    }
                }
            }
        }
    }];
    
    return results;
}


- (void)updateFromMetadataQuery:(NSMetadataQuery *)metadataQuery
{
    if (!metadataQuery) return;
    [metadataQuery disableUpdates];

    // don't use results proxy as it's fast this way
    NSUInteger metadataCount = [metadataQuery resultCount];
    NSMutableSet *resultDocuments = [[NSMutableSet alloc] init];
    for (NSUInteger metadataIndex = 0; metadataIndex < metadataCount; metadataIndex++) {
        NSMetadataItem *metadataItem = [metadataQuery resultAtIndex:metadataIndex];
        
        NSURL *fileURL = [metadataItem valueForAttribute:NSMetadataItemURLKey];
        
        MNDocumentReference *documentReference = nil;
        documentReference = [self documentReferenceFromFileURL:fileURL];
                
        if (!documentReference) {
            NSDate *modificationDate = [metadataItem valueForAttribute:NSMetadataItemFSContentChangeDateKey];
            if (!modificationDate) {
                modificationDate = [NSDate date];
            }
            
            documentReference = [[MNDocumentReference alloc] initWithFileURL:fileURL modificationDate:modificationDate];
        }
        
        [resultDocuments addObject:documentReference];
        [documentReference updateWithMetadataItem:metadataItem];
    
    }
        
    // create a set of new documents
    for (MNDocumentReference *currentReference in [self.documentReferences copy]) {
        if (![resultDocuments containsObject:currentReference]) {
            [self removeDocumentReferencesObject:currentReference];
        }
    }
    
    for (MNDocumentReference *currentReference in resultDocuments) {
        if (![self.documentReferences containsObject:currentReference]) {
            [self addDocumentReferencesObject:currentReference];
        }
    }
         

    [metadataQuery enableUpdates];
}


- (void)performAsynchronousFileAccessUsingBlock:(void (^)(void))block
{
    [self.fileAccessWorkingQueue addOperationWithBlock:block];
}

#pragma mark - Document Manipulation

- (void)createNewDocumentWithCompletionHandler:(void (^)(MNDocument *document, MNDocumentReference *reference))completionHandler;
{	        
    NSURL *fileURL = [[[self class] localDocumentsURL] URLByAppendingPathComponent:[self uniqueFileName]];
    
    [MNDocumentReference createNewDocumentWithFileURL:fileURL completionHandler:^(MNDocument *document, MNDocumentReference *reference) {
        if (!reference) {
            completionHandler(nil,nil);
            return;
        }
        [self addDocumentReferencesObject:reference];
        
        if (!self.documentsInCloud) {
            completionHandler(document,reference);
            return;
        }
        
        __weak id blockSelf = self;
        [self.fileAccessWorkingQueue addOperationWithBlock:^{
            if (![blockSelf _moveDocumentToCloud:reference]) {
                NSLog(@"Failed to move to iCloud!");
            };
            dispatch_async(dispatch_get_main_queue(), ^{
                completionHandler(document,reference);
            });
        }];
    }];
}


- (void)deleteDocument:(MNDocumentReference *)document completionHandler:(void (^)(NSError *errorOrNil))completionHandler
{
	if (![self.documentReferences containsObject:document]) {
        completionHandler(MNErrorWithCode(MNUnknownError));
        return;
    }
    __weak id blockSelf = self;
    [self.fileAccessWorkingQueue addOperationWithBlock:^{
        __block NSError *deleteError = nil;
        NSError *coordinatorError = nil;
        NSFileCoordinator* fileCoordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        [fileCoordinator coordinateWritingItemAtURL:document.fileURL options:NSFileCoordinatorWritingForDeleting error:&coordinatorError byAccessor:^(NSURL* writingURL) {
            NSFileManager* fileManager = [[NSFileManager alloc] init];
            [fileManager removeItemAtURL:writingURL error:&deleteError];
        }];
        dispatch_async(dispatch_get_main_queue(), ^(){
            if (coordinatorError) {
                completionHandler(coordinatorError);
                return;
            }
            if (deleteError) {
                completionHandler(deleteError);
                return;
            }
            completionHandler(nil);
            [blockSelf removeDocumentReferencesObject:document];
        });
    }];
}


- (void)duplicateDocument:(MNDocumentReference*)document completionHandler:(void (^)(NSError *errorOrNil))completionHandler;
{
	if (![self.documentReferences containsObject:document]) {
        completionHandler(MNErrorWithCode(MNUnknownError));
        return;
    }
    
    
    NSString *fileName = [self uniqueFileNameForDisplayName:document.displayName];
    NSURL *sourceURL = document.fileURL;
    NSURL *destinationURL = [[[self class] localDocumentsURL] URLByAppendingPathComponent:fileName isDirectory:NO];
    
    __weak id blockSelf = self;
    [self.fileAccessWorkingQueue addOperationWithBlock:^{
        __block NSError *copyError = nil;
        __block BOOL success = NO;
        __block NSURL *newDocumentURL = nil;
        NSError *coordinatorError = nil;
        NSFileCoordinator* fileCoordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        [fileCoordinator coordinateReadingItemAtURL:sourceURL options:NSFileCoordinatorReadingWithoutChanges writingItemAtURL:destinationURL options:NSFileCoordinatorWritingForReplacing error:&coordinatorError byAccessor:^(NSURL *newReadingURL, NSURL *newWritingURL) {
            NSFileManager* fileManager = [[NSFileManager alloc] init];
            if ([fileManager fileExistsAtPath:[newWritingURL path]]) {
                return;
            }
            [fileManager copyItemAtURL:sourceURL toURL:destinationURL error:&copyError];
            newDocumentURL = newWritingURL;
            success = YES;
        }];
        
        if (!success) {
            dispatch_async(dispatch_get_main_queue(), ^(){
                if (coordinatorError) {
                    completionHandler(coordinatorError);
                } else if (copyError) {
                    completionHandler(copyError);
                } else {
                    completionHandler(MNErrorWithCode(MNUnknownError));
                }
            });
            return;
        }
        MNDocumentReference *reference = [[MNDocumentReference alloc] initWithFileURL:newDocumentURL modificationDate:[NSDate date]];
        
        if (![blockSelf documentsInCloud]) {
            dispatch_async(dispatch_get_main_queue(), ^(){
                [blockSelf addDocumentReferencesObject:reference];
                completionHandler(nil);
            });
            return;
        }
        
        if (![blockSelf _moveDocumentToCloud:reference]) {
            NSLog(@"Failed to move to iCloud!");
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [blockSelf addDocumentReferencesObject:reference];
            completionHandler(nil);
        });
    }];
}


- (void)renameDocument:(MNDocumentReference *)document toFileName:(NSString *)fileName completionHandler:(void (^)(NSError *errorOrNil))completionHandler
{
    // check if valid filename
    if (!fileName || ([fileName length] > 200) || ([fileName length] == 0)) {
        dispatch_async(dispatch_get_main_queue(), ^(){
            if (completionHandler) completionHandler(MNErrorWithCode(MNErrorFileNameTooLong));
        });
        return;
    }
    
    if (!NSEqualRanges([fileName rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/\\?%*|\"<>"]], NSMakeRange(NSNotFound, 0))) {
        dispatch_async(dispatch_get_main_queue(), ^(){
            if (completionHandler) completionHandler(MNErrorWithCode(MNErrorFileNameNotAllowedCharacters));
        });
        return;
    }

    // check for case insensitivity
    NSMutableSet *useFileNames = [NSMutableSet setWithCapacity:[self.documentReferences count]];
    for (MNDocumentReference *currentReference in self.documentReferences) {
        [useFileNames addObject:[[currentReference.fileURL lastPathComponent] lowercaseString]];
    }
    if ([useFileNames member:[fileName lowercaseString]] != nil) {
        dispatch_async(dispatch_get_main_queue(), ^(){
            if (completionHandler) completionHandler(MNErrorWithCode(MNErrorFileNameAlreadyUsedError));
        });
        return;
    }


    [self.fileAccessWorkingQueue addOperationWithBlock:^{
        NSURL *sourceURL = document.fileURL;
        NSURL *destinationURL = [[sourceURL URLByDeletingLastPathComponent] URLByAppendingPathComponent:fileName isDirectory:NO];
        
        NSError *writeError = nil;
        __block NSError *moveError = nil;
        __block BOOL success = NO;
        __block NSURL *finalDocumentURL = destinationURL; // finalDocumentURL might be different than destinationURL when entering the coordinator block
        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        [coordinator coordinateWritingItemAtURL: sourceURL options: NSFileCoordinatorWritingForMoving writingItemAtURL: destinationURL options: NSFileCoordinatorWritingForReplacing error: &writeError byAccessor: ^(NSURL *newURL1, NSURL *newURL2) {
            NSFileManager *fileManager = [[NSFileManager alloc] init];
            success = [fileManager moveItemAtURL:newURL1 toURL:newURL2 error:&moveError];
            if (success) {
                [coordinator itemAtURL:newURL1 didMoveToURL:newURL2];
                finalDocumentURL = newURL2;
            }
        }];
        
        NSError *outError = nil;
        if (success) {
            if (!self.documentsInCloud) {
                // sometimes when renaming documents, the file presenter is not correctly informed
                // this is not a problem when using iCloud as the next metadata query will take care of this
                // we don't use the same code for iCloud as sometimes the next metadata query will return the old name and the following query the new name
                // this caused the reappearing of the old name, followed by the new name
                [document presentedItemDidMoveToURL:finalDocumentURL];
            }
            
        } else {
            if (moveError) {
                MNLogError(moveError);
            }
            if (writeError) {
                MNLogError(writeError);
            }
            outError = MNErrorWithCode(MNErrorFileNameAlreadyUsedError);
        }
        dispatch_async(dispatch_get_main_queue(), ^(){
            if (completionHandler) completionHandler(outError);
        });
    }];
}

- (BOOL)pendingDocumentTransfers
{
    for (MNDocumentReference *currentDocument in self.documentReferences) {
        if (!currentDocument.isDownloaded || !currentDocument.isUploaded) {
            return YES;
        }
    }
    return NO;
}

- (void)disableiCloudAndCopyAllCloudDocumentsToLocalWithCompletionHandler:(void (^)(NSError *errorOrNil))completionHandler;
{
    // check if we have pending changes
    if ([self pendingDocumentTransfers]) {
        return completionHandler(MNErrorWithCode(MNErrorCloudUnableToMoveAllDocumentsToCloud));
    }
    
    NSArray *documents = [self.documentReferences copy];

    __weak id blockSelf = self;
    [self.fileAccessWorkingQueue addOperationWithBlock:^{
        for (MNDocumentReference *currentDocument in documents) {
            __block NSError *copyError = nil;
            __block BOOL success = NO;
            __block NSURL *newDocumentURL = nil;
            NSURL *sourceURL = [currentDocument fileURL];
            NSURL *destinationURL = [[[blockSelf class] localDocumentsURL] URLByAppendingPathComponent:[sourceURL lastPathComponent] isDirectory:NO];
            NSError *coordinatorError = nil;
            NSFileCoordinator* fileCoordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
            [fileCoordinator coordinateReadingItemAtURL:sourceURL options:NSFileCoordinatorReadingWithoutChanges writingItemAtURL:destinationURL options:NSFileCoordinatorWritingForReplacing error:&coordinatorError byAccessor:^(NSURL *newReadingURL, NSURL *newWritingURL) {
                NSFileManager* fileManager = [[NSFileManager alloc] init];
                if ([fileManager fileExistsAtPath:[newWritingURL path]]) {
                    return;
                }
                [fileManager copyItemAtURL:sourceURL toURL:destinationURL error:&copyError];
                newDocumentURL = newWritingURL;
                success = YES;
            }];
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSUserDefaults standardUserDefaults] setBool:NO forKey:MNDefaultsDocumentsInCloudKey];
            completionHandler(nil);
        });
    }];
}




- (void)moveAllCloudDocumentsToLocalWithCompletionHandler:(void (^)(NSError *errorOrNil))completionHandler;
{
    // check if we have pending changes
    if ([self pendingDocumentTransfers]) {
        return completionHandler(MNErrorWithCode(MNErrorCloudUnableToMoveAllDocumentsToCloud));
    }
    
    
    NSArray *documents = [self.documentReferences copy];
    __weak id blockSelf = self;
    [self.fileAccessWorkingQueue addOperationWithBlock:^{
        for (MNDocumentReference *currentDocument in documents) {
            if (![blockSelf _moveDocumentToLocal:currentDocument]) {
                NSLog(@"Failed to move to iCloud!");
            };
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            completionHandler(nil);
        });
    }];
}

- (void)moveAllLocalDocumentsToCloudWithCompletionHandler:(void (^)(void))completionHandler
{
    
    NSArray *documents = [self.documentReferences copy];
    __weak id blockSelf = self;
    
    void (^moveAllBlock)(void) = ^ {
        for (MNDocumentReference *currentDocument in documents) {
            if (![blockSelf _moveDocumentToCloud:currentDocument]) {
                NSLog(@"Failed to move to iCloud!");
            };
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            completionHandler();
        });
    };
    
    if (self.iCloudMetadataQuery.isGathering) {
        self.dequeueBlockForMetadataQueryDidFinish = moveAllBlock;
    } else {
        [self.fileAccessWorkingQueue addOperationWithBlock:moveAllBlock];
    }

}


- (void)importDocumentAtURL:(NSURL *)documentURL completionHandler:(void (^)(MNDocumentReference *reference, NSError *errorOrNil))completionHandler
{
	NSString *path = [documentURL path];
	NSString *extension = [path pathExtension];
	if (!extension) {
        completionHandler(nil,MNErrorWithCode(MNFileImportError));
        return;
    }
    
    NSString *filename = [[path lastPathComponent] stringByDeletingPathExtension];
    if ([[[filename pathExtension] lowercaseString] isEqualToString:MNDocumentMindNodeExtension]) {
        // when we import a Document.mindnode.zip file, we also need to trim the .mindnode extension
        filename = [filename stringByDeletingPathExtension];
    }
    
    // When importing we use the current file extension and not the mindnode extension. It will get set during first saving by MNDocument
    NSURL *newDocumentURL = [[[self class] localDocumentsURL] URLByAppendingPathComponent:[self uniqueFileNameForDisplayName:filename]];
        
    
    // create a new document
    MNDocument *document = [[MNDocument alloc] initWithFileURL:documentURL];
    if (!document) {
        completionHandler(nil,MNErrorWithCode(MNFileImportError));
        return;
    }
    
    // initialize the new document from the file we need to import
    [document openWithCompletionHandler:^(BOOL success) {
        if (!success) {
            completionHandler(nil,MNErrorWithCode(MNFileImportError));
            return;
        }
        
        [document updateChangeCount: UIDocumentChangeDone]; // mark the document as dirty
        
        [document saveToURL:newDocumentURL forSaveOperation:UIDocumentSaveForCreating completionHandler:^(BOOL success) {
            if (!success) {
                [document closeWithCompletionHandler:nil];
                completionHandler(nil,MNErrorWithCode(MNFileImportError));
                return;
            }
            [document closeWithCompletionHandler:^(BOOL success) {
                MNDocumentReference *reference = [[MNDocumentReference alloc] initWithFileURL:newDocumentURL modificationDate:[NSDate date]];
                [self addDocumentReferencesObject:reference];
                
                if (!self.documentsInCloud) {
                    if (completionHandler) completionHandler(reference,nil);
                    return;
                }
                
                __weak id blockSelf = self;
                [self.fileAccessWorkingQueue addOperationWithBlock:^{
                    if (![blockSelf _moveDocumentToCloud:reference]) {
                        NSLog(@"Failed to move to iCloud!");
                    };
                    dispatch_async(dispatch_get_main_queue(), ^{
                        completionHandler(reference,nil);
                    });
                }];
                
            }];
        }];
    }];
}

- (void)evictAllCloudDocumentsWithCompletionHandler:(void (^)(void))completionHandler progressUpdateHandler:(void (^)(CGFloat progress))progressUpdateHandler;
{
    [self.fileAccessWorkingQueue addOperationWithBlock:^{
        
        NSUInteger count = [self.documentReferences count];
        NSUInteger currentItem = 0;
        
        NSFileManager *fm = [[NSFileManager alloc] init];
        for (MNDocumentReference *currentReference in self.documentReferences) {
            NSURL *url = currentReference.fileURL;
            [fm evictUbiquitousItemAtURL:url error:NULL];
            
            currentItem++;
            if (progressUpdateHandler) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    progressUpdateHandler(currentItem / ((CGFloat)count));
                });
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completionHandler) completionHandler();
        });
    }];
}


#pragma mark - Paths


+ (NSURL *)localDocumentsURL
{
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = paths[0];
    return [NSURL fileURLWithPath:documentsDirectory];
}

+ (NSURL *)ubiquitousContainerURL 
{
    return [[[NSFileManager alloc] init] URLForUbiquityContainerIdentifier:nil];
}

+ (NSURL *)ubiquitousDocumentsURL 
{
    NSURL *containerURL = [self ubiquitousContainerURL];
    if (!containerURL) return nil;
    
    NSURL *documentURL = [containerURL URLByAppendingPathComponent:@"Documents"];
    return documentURL;
}


- (NSString *)uniqueFileName 
{
    NSString *fileName = NSLocalizedStringFromTable(@"Mind Map", @"DocumentPicker", @"Default file name. Don't localize!");
    fileName = [self uniqueFileNameForDisplayName:fileName];
    return fileName;
}

- (NSString *)uniqueFileNameForDisplayName:(NSString *)displayName
{
    NSSet *documents = self.documentReferences;
    NSUInteger count = [documents count];
    
    // build list of filenames
    NSMutableSet *useFileNames = [NSMutableSet setWithCapacity:count];
    for (MNDocumentReference *currentReference in documents) {
        // lowercaseString: make sure our name is also unique on a case insensitive file system
        [useFileNames addObject:[[currentReference.fileURL lastPathComponent] lowercaseString]];
    }
    
    NSString *fileName = [[self class] uniqueFileNameForDisplayName:displayName extension:MNDocumentMindNodeExtension usedFileNames:useFileNames];
    return fileName;
}

+ (NSString *)uniqueFileNameForDisplayName:(NSString *)displayName extension:(NSString *)extension usedFileNames:(NSSet *)usedFileNames
{   // based on code from the OmniGroup Frameworks
    NSUInteger counter = 0; // starting counter
    displayName = [displayName stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/:"]];
    if ([displayName length] > 200) displayName = [displayName substringWithRange:NSMakeRange(0, 200)];
    
    while (YES) {
        NSString *candidateName;
        if (counter == 0) {
            candidateName = [[NSString alloc] initWithFormat:@"%@.%@", displayName, extension];
            counter = 2; // First duplicate should be "Foo 2".
        } else {
            candidateName = [[NSString alloc] initWithFormat:@"%@ %d.%@", displayName, counter, extension];
            counter++;
        }
        
        // lowercaseString: make sure our name is also unique on a case insensitive file system
        if ([usedFileNames member:[candidateName lowercaseString]] == nil) {
            return candidateName;
        }
    }
}

+ (NSString *)uniqueFileNameForDisplayName:(NSString *)displayName extension:(NSString *)extension inDirectory:(NSURL *)directionaryURL
{   
    NSUInteger counter = 0;
    displayName = [displayName stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/:"]];
    if ([displayName length] > 200) displayName = [displayName substringWithRange:NSMakeRange(0, 200)];
    
    NSArray *directoryContents = [[[NSFileManager alloc] init] contentsOfDirectoryAtPath:[directionaryURL path] error:NULL];
    if (!directoryContents) return nil;
    
    while (YES) {
        NSString *candidateName;
        if (counter == 0) {
            candidateName = [[NSString alloc] initWithFormat:@"%@.%@", displayName, extension];
            counter = 2; // First duplicate should be "Foo 2".
        } else {
            candidateName = [[NSString alloc] initWithFormat:@"%@ %d.%@", displayName, counter, extension];
            counter++;
        }
        
        // lowercaseString: make sure our name is also unique on a case insensitive file system
        NSString *lowercaseName = [candidateName lowercaseString];
        NSUInteger foundIndex = [directoryContents indexOfObjectPassingTest:^BOOL(id obj, NSUInteger idx, BOOL *stop) {
            return ([[obj lowercaseString] isEqualToString:lowercaseName]);
        }];
        if (foundIndex == NSNotFound) {
            return candidateName;
        }
    }
}



#pragma mark - Document Persistance

- (void)applicationWillTerminate:(NSNotification *)notification 
{
    [self _stopMetadataQuery];
}

- (void)applicationDidEnterBackground:(NSNotification *)notification 
{
    [self _stopMetadataQuery];
}

- (void)applicationWillEnterForeground:(NSNotification *)notification
{
    if (self.documentsInCloud) {
        [self _startMetadataQuery];
    } else {
        if ([[NSUserDefaults standardUserDefaults] boolForKey:MNDefaultsDocumentsInCloudKey]) {
            [self reloadLocalDocuments]; // iCloud was available last time, reload local docs.
        }
    }
}

- (void)userDefaultsDidChange:(NSNotification *)notification
{
    BOOL iCloudEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:MNDefaultsDocumentsInCloudKey];
    if (iCloudEnabled) {
        if (!self.iCloudMetadataQuery) {
            [self _startMetadataQuery];
        }
    } else {
        if (self.iCloudMetadataQuery) {
            [self _stopMetadataQuery];
            [self reloadLocalDocuments];
        }
    }
}

#pragma mark - KVO Compliance


- (void)addDocumentReferencesObject:(MNDocumentReference *)reference
{
    [reference enableFilePresenter];
    [_documentReferences addObject:reference];
}

- (void)removeDocumentReferencesObject:(MNDocumentReference *)reference
{
    [reference disableFilePresenter];
    [_documentReferences removeObject:reference];
}


#pragma mark - iCloud

- (void)_startMetadataQuery
{
    if (!self.documentsInCloud) return;
    if (self.iCloudMetadataQuery) return;
    if (![[self class] ubiquitousContainerURL]) return; // no iCloud
    
    NSMetadataQuery *query = [[NSMetadataQuery alloc] init];
    [query setSearchScopes:@[NSMetadataQueryUbiquitousDocumentsScope]];
    [query setPredicate:[NSPredicate predicateWithFormat:@"%K like '*'", NSMetadataItemFSNameKey]];
    NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
    [notificationCenter addObserver:self selector:@selector(metadataQueryDidStartGatheringNotifiction:) name:NSMetadataQueryDidStartGatheringNotification object:query];
    [notificationCenter addObserver:self selector:@selector(metadataQueryDidGatheringProgressNotifiction:) name:NSMetadataQueryGatheringProgressNotification object:query];
    [notificationCenter addObserver:self selector:@selector(metadataQueryDidFinishGatheringNotifiction:) name:NSMetadataQueryDidFinishGatheringNotification object:query];
    [notificationCenter addObserver:self selector:@selector(metadataQueryDidUpdateNotifiction:) name:NSMetadataQueryDidUpdateNotification object:query];

    if(![query startQuery]) {
        NSLog(@"Unable to start MetadataQuery");
    }
    self.iCloudMetadataQuery = query;
}

- (void)_stopMetadataQuery
{
    NSMetadataQuery *query = self.iCloudMetadataQuery;
    if (query == nil)
        return;
    
    [query stopQuery];
    
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center removeObserver:self name:NSMetadataQueryDidStartGatheringNotification object:query];
    [center removeObserver:self name:NSMetadataQueryGatheringProgressNotification object:query];
    [center removeObserver:self name:NSMetadataQueryDidFinishGatheringNotification object:query];
    [center removeObserver:self name:NSMetadataQueryDidUpdateNotification object:query];
    
    self.iCloudMetadataQuery = nil;
}

- (void)metadataQueryDidStartGatheringNotifiction:(NSNotification *)n;
{
    self.controllerState = MNDocumentControllerStateLoading;
    [[NSNotificationCenter defaultCenter] postNotificationName:MNDocumentControllerDidChangeStateNotification object:self];
}

- (void)metadataQueryDidGatheringProgressNotifiction:(NSNotification *)n;
{
    // we don't update the progress as we don't want to add documents incrementally during startup
    // our folder scan will take care of providing an initial set of documents
}

- (void)metadataQueryDidFinishGatheringNotifiction:(NSNotification *)n;
{
    [self updateFromMetadataQuery:self.iCloudMetadataQuery];
    self.controllerState = MNDocumentControllerStateNormal;
    [[NSNotificationCenter defaultCenter] postNotificationName:MNDocumentControllerDidChangeStateNotification object:self];
    if (self.dequeueBlockForMetadataQueryDidFinish) {
        [self.fileAccessWorkingQueue addOperationWithBlock:^{
            self.dequeueBlockForMetadataQueryDidFinish();
            self.dequeueBlockForMetadataQueryDidFinish = nil;
        }];
    } else {
        // move local documents to iCloud
        // sometimes moving documents to iCloud failes, we don't show those documents in the picker, but we try to move them to iCloud everytime we finish gathering
        // (hopefully a document won't fail to move to iCloud forever)
        __weak id blockSelf = self;
        [self.fileAccessWorkingQueue addOperationWithBlock:^{
            NSSet *references = [blockSelf _localDocumentReferences];
            for (MNDocumentReference *currentReference in references) {
                [blockSelf _moveDocumentToCloud:currentReference];
            }
        }];
    }
}

- (void)metadataQueryDidUpdateNotifiction:(NSNotification *)n;
{
    [self updateFromMetadataQuery:self.iCloudMetadataQuery];
}


// This method blocks, make sure to call it on a queue
- (BOOL)_moveDocumentToCloud:(MNDocumentReference *)documentReference
{
    NSURL *sourceURL = documentReference.fileURL;
    NSURL *targetDocumentURL = [[self class] ubiquitousDocumentsURL];
    if (!targetDocumentURL) return NO;
    NSURL *destinationURL = [targetDocumentURL URLByAppendingPathComponent:[sourceURL lastPathComponent] isDirectory:NO];
    
    NSFileManager *fileManager = [[NSFileManager alloc] init];
    if ([fileManager fileExistsAtPath:[destinationURL path]]) {
        NSString *fileName = [[self class] uniqueFileNameForDisplayName:documentReference.displayName extension:MNDocumentMindNodeExtension inDirectory:targetDocumentURL];
        destinationURL = [targetDocumentURL URLByAppendingPathComponent:fileName isDirectory:NO];
    }
    
    NSError *error = nil;
    BOOL success = [fileManager setUbiquitous:YES itemAtURL:sourceURL destinationURL:destinationURL error:&error];
    if (!success && error) NSLog(@"%@",error);

    return success;
}

// This method blocks, make sure to call it on a queue
- (BOOL)_moveDocumentToLocal:(MNDocumentReference *)documentReference
{
    NSURL *sourceURL = documentReference.fileURL;
    NSURL *targetDocumentURL = [[self class] localDocumentsURL];
    NSURL *destinationURL = [targetDocumentURL URLByAppendingPathComponent:[sourceURL lastPathComponent] isDirectory:NO];
    
    NSFileManager *fileManager = [[NSFileManager alloc] init];
    if ([fileManager fileExistsAtPath:[destinationURL path]]) {
        NSString *fileName = [[self class] uniqueFileNameForDisplayName:documentReference.displayName extension:MNDocumentMindNodeExtension inDirectory:targetDocumentURL];
        destinationURL = [targetDocumentURL URLByAppendingPathComponent:fileName isDirectory:NO];
    }

    NSError *error = nil;
    BOOL success = [fileManager setUbiquitous:NO itemAtURL:sourceURL destinationURL:destinationURL error:&error];
    if (!success && error) NSLog(@"%@",error);
    return success;
}


- (void)debugLogCloudFolder
{
    NSURL *url = [[self class] ubiquitousDocumentsURL];
    if (!url) NSLog(@"Unable to access ubiquitousContainer");
    
    NSError *error = nil;
    NSFileManager *fileManager = [[NSFileManager alloc] init];
    NSArray *fileURLs = [fileManager contentsOfDirectoryAtURL:url includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:0 error:&error];
    
    for (NSURL *currentURL in fileURLs) {
        NSDictionary *attributes = [fileManager attributesOfItemAtPath:[currentURL path] error:NULL];
        NSLog(@"%@",[currentURL lastPathComponent]);
        NSLog(@"%@",attributes);
        NSLog(@"--");
    }
    
}
@end
