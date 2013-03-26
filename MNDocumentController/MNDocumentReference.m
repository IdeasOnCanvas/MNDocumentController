//
//  MNDocumentReference.m
//  MindNodeTouch
//
//  Created by Markus Müller on 23.09.10.
//  Copyright 2010 IdeasOnCanvas GmbH. All rights reserved.
//

#import "MNDocumentReference.h"
#import "MNDocumentController.h"
#import "MNDocument.h"
#import "MNMindMap.h"
#import "MNMindMapMetadata.h"

#import "MNImageExporter.h"

#import "MNDateFormatter.h"

#import "NSString+UUID.h"
#import "MNError.h"
#import "UIImage+Size.h"

// Attributes Keys
NSString *MNDocumentReferenceDisplayNameKey = @"displayName";
NSString *MNDocumentReferenceModificationDateKey = @"modificationDate";
NSString *MNDocumentReferencePreviewKey = @"preview";
NSString *MNDocumentReferenceStatusUpdatedKey = @"statusUpdate";

CGFloat MNDocumentReferencePreviewWidthPhone = 120;
CGFloat MNDocumentReferencePreviewWidthPad = 210;

@interface MNDocumentReference ()

// attributes
@property (readwrite,strong) NSString *displayName;
@property (readwrite,strong) NSString *displayModificationDate;
@property (readwrite,strong) NSURL *fileURL;
@property (readwrite,strong) NSDate *modificationDate;
@property (atomic,readwrite,strong) UIImage* preview;

@property (readwrite,strong)  NSOperationQueue *fileItemOperationQueue;

// iCloud
@property (readwrite) BOOL isUbiquitous;
@property (readwrite) BOOL hasUnresolvedConflicts;
@property (readwrite) BOOL isDownloaded;
@property (readwrite) BOOL isDownloading;
@property (readwrite) BOOL isUploaded;
@property (readwrite) BOOL isUploading;
@property (readwrite) CGFloat percentDownloaded;
@property (readwrite) CGFloat percentUploaded;
@property (readwrite) BOOL startedDownload;


@end


@implementation MNDocumentReference



#pragma mark - Init

+ (void)createNewDocumentWithFileURL:(NSURL *)fileURL completionHandler:(void (^)(MNDocument *document, MNDocumentReference *reference))completionHandler
{
    MNDocumentReference *reference = [[[self class] alloc] initWithFileURL:fileURL modificationDate:[NSDate date]];
    if (!reference) {
        completionHandler(nil,nil);
        return;
    }
    
    // create and initialize an empty document
    MNDocument *document = [[MNDocument alloc] initNewDocumentWithFileURL:fileURL];
    
    [document updateChangeCount: UIDocumentChangeDone];

    [document saveToURL:fileURL forSaveOperation:UIDocumentSaveForCreating completionHandler:^(BOOL success){
        completionHandler(document,reference);
    }];
}

// we don't have a init methode without modification date because we don't want to do a coordinating read in an initilizer
- (id)initWithFileURL:(NSURL *)fileURL modificationDate:(NSDate *)modificationDate
{
	self = [super init];
	if (self == nil) return self;
    
	self.fileURL = fileURL;
	self.displayName = [[fileURL lastPathComponent] stringByDeletingPathExtension];
    
    [self _refreshModificationDate:modificationDate];
        
    self.fileItemOperationQueue = [[NSOperationQueue alloc] init];
    self.fileItemOperationQueue.name = @"MNDocumentReference";
    [self.fileItemOperationQueue setMaxConcurrentOperationCount:1];
    
    // iCloud
    NSNumber* numberValue;
    if ([fileURL getResourceValue:&numberValue forKey:NSURLIsUbiquitousItemKey error:nil]) {
        self.isUbiquitous = [numberValue boolValue];
    }

    self.hasUnresolvedConflicts = NO;
    self.isDownloaded = YES;
    self.isDownloading = NO;
    self.isUploaded = YES;
    self.isUploading = NO;
    self.percentDownloaded = 0;
    self.percentUploaded = 100;
    self.startedDownload = NO;

	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didReceiveMemoryWarning:) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
    
    return self;
}

- (void)enableFilePresenter
{
    [NSFileCoordinator addFilePresenter:self];
}


- (void)disableFilePresenter
{
    [NSFileCoordinator removeFilePresenter:self];
}

- (void) dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (NSString *)description;
{
    return [NSString stringWithFormat:@"Name: '%@' Date: '%@'",self.displayName, self.modificationDate];
}


#pragma mark - Document Representation

- (void)loadDocumentWithCompletionHandler:(void (^)(MNDocument *document))completionHandler
{
    if (!self.isDownloaded || self.hasUnresolvedConflicts) {
        if (completionHandler) completionHandler(nil);
        return;
    }

    MNDocument *document = [[MNDocument alloc] initWithFileURL:self.fileURL];
    [document openWithCompletionHandler:^(BOOL success) {
        if (!success) {
            if (completionHandler) completionHandler(nil);
            return;
        }
        NSString *mindMapTitle = self.displayName;
        if (mindMapTitle && [mindMapTitle length] != 0) {
            document.mindMap.metadata.title = mindMapTitle;
        }
        if (completionHandler) completionHandler(document);
    }];
}


- (void)_refreshModificationDate:(NSDate *)date
{
    self.displayModificationDate = [[MNDateFormatter modificationDateFormatter] stringFromDate:date];
	self.modificationDate = date;
}


#pragma mark - Preview Image

static dispatch_queue_t _MNDocumentReferencePreviewGenerationQueue = NULL;

static dispatch_queue_t MNDocumentReferenceSharedPreviewGenerationQueue(void)
{
    static dispatch_once_t queueCreationPredicate = 0;
    dispatch_once(&queueCreationPredicate, ^{
        _MNDocumentReferencePreviewGenerationQueue = dispatch_queue_create("com.mindnode.documentReferences.sharedPreviewGenerationQueue", 0);
    });
    return _MNDocumentReferencePreviewGenerationQueue;
}


- (void)didReceiveMemoryWarning:(NSNotification*)n
{
	self.preview = nil;
}


- (void)previewImageWithCallbackBlock:(void(^)(UIImage *image))callbackBlock
{
    if (self.preview) {
        if (callbackBlock) callbackBlock(self.preview);
        return;
    }

    __weak id blockSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [blockSelf _reloadPreviewImageWithCallbackBlock:^(UIImage *image) {
            if (callbackBlock) callbackBlock(image);
        }];
    });
}

- (void)previewImageWithWidth:(CGFloat)width withCallbackBlock:(void(^)(UIImage *image))callbackBlock
{
    if (!self.isDownloaded) {
        return;
    }

    dispatch_async(MNDocumentReferenceSharedPreviewGenerationQueue(), ^{
        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:self];
        NSError *readError = nil;
        __block UIImage *image;
        [coordinator coordinateReadingItemAtURL:self.fileURL options:NSFileCoordinatorReadingWithoutChanges error:&readError byAccessor: ^(NSURL *readURL){
            NSURL *imageURL = [[readURL URLByAppendingPathComponent:MNDocumentQuickLookFolderName isDirectory:YES] URLByAppendingPathComponent:MNDocumentQuickLookPreviewFileName isDirectory:NO];

            image = [UIImage mn_thumbnailImageAtURL:imageURL withMaxSize:width];
        }];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (callbackBlock) {
                callbackBlock(image);
            }
        });
    });
}

- (void)_reloadPreviewImageWithCallbackBlock:(void(^)(UIImage *image))callbackBlock
{
    if (!self.isDownloaded) {
        return;
    }
    dispatch_async(MNDocumentReferenceSharedPreviewGenerationQueue(), ^{
        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:self];
        NSError *readError = nil;
        __block UIImage *image;
        [coordinator coordinateReadingItemAtURL:self.fileURL options:NSFileCoordinatorReadingWithoutChanges error:&readError byAccessor: ^(NSURL *readURL){
            NSURL *imageURL = [[readURL URLByAppendingPathComponent:MNDocumentQuickLookFolderName isDirectory:YES] URLByAppendingPathComponent:MNDocumentQuickLookPreviewFileName isDirectory:NO];
            image = [UIImage mn_thumbnailImageAtURL:imageURL withMaxSize:(UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad ? MNDocumentReferencePreviewWidthPad : MNDocumentReferencePreviewWidthPhone)];
        }];
        
        if (!image) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self willChangeValueForKey:MNDocumentReferencePreviewKey];
            self.preview = image;
            [self didChangeValueForKey:MNDocumentReferencePreviewKey];
            if (callbackBlock) {
                callbackBlock(image);
            }
        });
    });
}


+ (UIImage *)animationImageForDocument:(MNDocument *)document withSize:(CGSize)size
{
    id viewState = document.viewState;
    if (!viewState) return nil;
    
    id zoomLevelNumber = viewState[MNDocumentViewStateZoomScaleKey];
    if (![zoomLevelNumber isKindOfClass:[NSNumber class]]) return nil;
    CGFloat zoomLevel = [zoomLevelNumber doubleValue];
    if (zoomLevel == 0) zoomLevel = 1;
    
	
	// scroll point
	id offsetString = viewState[MNDocumentViewStateScrollCenterPointKey];
	if (![offsetString isKindOfClass:[NSString class]]) return nil;
    CGPoint centerPoint = CGPointFromString(offsetString);
    
    CGRect drawRect = CGRectMake(centerPoint.x, centerPoint.y, 0, 0);
    drawRect = CGRectInset(drawRect, -size.width/zoomLevel/2, -size.height/zoomLevel/2);
    
    
    MNImageExporter *exporter = [MNImageExporter exporterWithDocument:document];
    return [exporter imageRepresentationFromRect:drawRect];
}

+ (UIImage *)previewImageForDocumenAtURL:(NSURL *)url withMaxSize:(CGFloat)size
{
    NSURL *imageURL = [[url URLByAppendingPathComponent:MNDocumentQuickLookFolderName isDirectory:YES] URLByAppendingPathComponent:MNDocumentQuickLookPreviewFileName isDirectory:NO];
    UIImage *image = [UIImage mn_thumbnailImageAtURL:imageURL withMaxSize:size];
    
    if (!image) {
        imageURL = [[NSBundle mainBundle] URLForResource:@"MNTempDocumentPreview" withExtension:@"png"];
        image = [UIImage mn_thumbnailImageAtURL:imageURL withMaxSize:size];
    }
    
    return image;
}

#pragma mark - iCloud

- (void)startDownloading
{
    NSFileManager *fm = [[NSFileManager alloc] init];
    NSError *error = nil;
    if (![fm startDownloadingUbiquitousItemAtURL:self.fileURL error:&error]) {
        NSLog(@"%@",error);
    }
    
    self.startedDownload = YES;
}


- (void)updateMetadataFromURL
{
    NSURL *url = self.fileURL;
    NSDictionary *attributes = [url resourceValuesForKeys:@[NSURLIsUbiquitousItemKey, NSURLUbiquitousItemHasUnresolvedConflictsKey, NSURLUbiquitousItemIsDownloadedKey, NSURLUbiquitousItemIsDownloadingKey, NSURLUbiquitousItemIsUploadedKey, NSURLUbiquitousItemIsUploadingKey, NSURLUbiquitousItemPercentDownloadedKey, NSURLUbiquitousItemPercentUploadedKey] error:NULL];
    
    NSMutableDictionary *resultAttributes = [NSMutableDictionary dictionaryWithCapacity:10];
    [attributes enumerateKeysAndObjectsUsingBlock:^(NSString *key, id obj, BOOL *stop) {
        if ([key isEqualToString:NSURLIsUbiquitousItemKey]) {
            resultAttributes[NSMetadataItemIsUbiquitousKey] = obj;
            
        } else if ([key isEqualToString:NSURLUbiquitousItemHasUnresolvedConflictsKey]) {
            resultAttributes[NSMetadataUbiquitousItemHasUnresolvedConflictsKey] = obj;
            
        } else if ([key isEqualToString:NSURLUbiquitousItemIsDownloadedKey]) {
            resultAttributes[NSMetadataUbiquitousItemIsDownloadedKey] = obj;
        } else if ([key isEqualToString:NSURLUbiquitousItemIsDownloadingKey]) {
            resultAttributes[NSMetadataUbiquitousItemIsDownloadingKey] = obj;
        } else if ([key isEqualToString:NSURLUbiquitousItemPercentDownloadedKey]) {
            resultAttributes[NSMetadataUbiquitousItemPercentDownloadedKey] = obj;

            
        } else if ([key isEqualToString:NSURLUbiquitousItemIsUploadedKey]) {
            resultAttributes[NSMetadataUbiquitousItemIsUploadedKey] = obj;
        } else if ([key isEqualToString:NSURLUbiquitousItemIsUploadingKey]) {
            resultAttributes[NSMetadataUbiquitousItemIsUploadingKey] = obj;
        } else if ([key isEqualToString:NSURLUbiquitousItemPercentUploadedKey]) {
            resultAttributes[NSMetadataUbiquitousItemPercentUploadedKey] = obj;
        }
    }];

    
    [self _updateStateFromMetadataDictionary:resultAttributes];
    
}

- (void)updateWithMetadataItem:(NSMetadataItem *)metadataItem
{
    NSDictionary *attributes = [metadataItem valuesForAttributes:@[NSMetadataItemFSContentChangeDateKey,NSMetadataUbiquitousItemHasUnresolvedConflictsKey,NSMetadataUbiquitousItemIsDownloadedKey,NSMetadataUbiquitousItemIsDownloadingKey,NSMetadataUbiquitousItemPercentDownloadedKey,NSMetadataUbiquitousItemIsUploadedKey,NSMetadataUbiquitousItemIsUploadingKey,NSMetadataUbiquitousItemPercentUploadedKey]];
    [self _updateStateFromMetadataDictionary:attributes];
    
}



- (void)_updateStateFromMetadataDictionary:(NSDictionary *)dictionary
{
    BOOL didUpdate = NO;
    
    if (!self.isUbiquitous) {
        self.isUbiquitous = YES;
        didUpdate = YES;
    }
    
    
    NSDate *date = [dictionary valueForKey:NSMetadataItemFSContentChangeDateKey];
    if ((date && ![date isEqualToDate:self.modificationDate])) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _refreshModificationDate:date];
            self.preview = nil;
        });
        didUpdate = YES;
    }
    
    NSNumber *metadataValue = [dictionary valueForKey:NSMetadataUbiquitousItemHasUnresolvedConflictsKey];
    BOOL value = [metadataValue boolValue];
    if (metadataValue && (value!=self.hasUnresolvedConflicts)) {
        self.hasUnresolvedConflicts = value;
        didUpdate = YES;
    }
    
    // Download
    metadataValue = [dictionary valueForKey:NSMetadataUbiquitousItemIsDownloadedKey];
    value = [metadataValue boolValue];
    if (metadataValue && (value!=self.isDownloaded)) {
        self.isDownloaded = value;
        if (!value) self.percentDownloaded = 0;
        didUpdate = YES;
    }
    
    if (self.isDownloaded) {
        self.isDownloading = NO;
        self.percentDownloaded = 100.f;
    } else {
        metadataValue = [dictionary valueForKey:NSMetadataUbiquitousItemIsDownloadingKey];
        value = [metadataValue boolValue];
        if (metadataValue && (value!=self.isDownloading)) {
            self.isDownloading = value;
            didUpdate = YES;
        }
        
        metadataValue = [dictionary valueForKey:NSMetadataUbiquitousItemPercentDownloadedKey];
        double doubleValue = [metadataValue doubleValue];
        if (metadataValue && (doubleValue!=self.percentDownloaded)) {
            self.percentDownloaded = doubleValue;
            if (self.percentDownloaded == 100) {
                self.isDownloading = NO;
                self.isDownloaded = YES;
            }
            didUpdate = YES;
        }
    }
    
    if (!self.isDownloaded && !self.isDownloading && !self.startedDownload) {
        [self startDownloading];
    }
    
    // Upload
    metadataValue = [dictionary valueForKey:NSMetadataUbiquitousItemIsUploadedKey];
    value = [metadataValue boolValue];
    if (metadataValue && (value!=self.isUploaded)) {
        self.isUploaded = value;
        if (!value) self.percentUploaded = 0;
        didUpdate = YES;
    }
    
    if (self.isUploaded) {
        self.isUploading = NO;
        self.percentUploaded = 100.f;
    } else {
        metadataValue = [dictionary valueForKey:NSMetadataUbiquitousItemIsUploadingKey];
        value = [metadataValue boolValue];
        if (metadataValue && (value!=self.isUploading)) {
            self.isUploading = value;
            didUpdate = YES;
        }
        
        metadataValue = [dictionary valueForKey:NSMetadataUbiquitousItemPercentUploadedKey];
        double doubleValue = [metadataValue doubleValue];
        if (metadataValue && (doubleValue!=self.percentUploaded)) {
            self.percentUploaded = doubleValue;
            if (self.percentUploaded == 100) {
                self.isUploaded = YES;
                self.isUploading = NO;
            }
            didUpdate = YES;
        }
    }
    
    if (didUpdate) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self willChangeValueForKey:MNDocumentReferenceStatusUpdatedKey];
            [self didChangeValueForKey:MNDocumentReferenceStatusUpdatedKey];
        });
    }
}


#pragma mark - NSFilePresenter Protocol

- (NSURL *)presentedItemURL;
{
    return self.fileURL;
}

- (NSOperationQueue *)presentedItemOperationQueue;
{
    return self.fileItemOperationQueue;
}

- (void)presentedItemDidMoveToURL:(NSURL *)newURL
{
    if ([self.fileURL isEqual:newURL]) return; // as we sometimes send it manually, make sure it's only evaluated once
    self.fileURL = newURL;

    // dispatch on main queue to make sure KVO notifications get send on main
    dispatch_async(dispatch_get_main_queue(), ^{
        self.displayName = [[newURL lastPathComponent] stringByDeletingPathExtension];
    });
}

- (void)presentedItemDidChange;
{
    // this call can happen on any thread, make sure we coordinate the read
    NSFileCoordinator *fileCoordinator = [[NSFileCoordinator alloc] initWithFilePresenter:self];
    [fileCoordinator coordinateReadingItemAtURL:self.fileURL options:NSFileCoordinatorReadingWithoutChanges error:NULL byAccessor:^(NSURL *newURL) {
        NSFileManager *fileManager = [[NSFileManager alloc] init];
        
        NSDate *modificationDate = nil;
        NSDictionary *attributes = [fileManager attributesOfItemAtPath:[newURL path] error:NULL];
        if (attributes) {
            modificationDate = [attributes fileModificationDate];
        }
        if (modificationDate && ![modificationDate isEqualToDate:self.modificationDate]) {
            // dispatch on main queue to make sure KVO notifications get send on main
            dispatch_async(dispatch_get_main_queue(), ^{
                [self _refreshModificationDate:modificationDate];
            });
        }
    }];
    if (self.preview) {
        // dispatch on main queue to make sure KVO notifications get send on main
        dispatch_async(dispatch_get_main_queue(), ^{
            [self willChangeValueForKey:MNDocumentReferencePreviewKey];
            self.preview = nil; // we don't want to reload all in memory image when enabling or disalbing iCloud
            [self didChangeValueForKey:MNDocumentReferencePreviewKey];
        });
    }
}

- (void)_logURLState
{
    NSURL *url = self.fileURL;
    NSDictionary *attributes = [url resourceValuesForKeys:@[NSURLIsUbiquitousItemKey, NSURLUbiquitousItemHasUnresolvedConflictsKey, NSURLUbiquitousItemIsDownloadedKey, NSURLUbiquitousItemIsDownloadingKey, NSURLUbiquitousItemIsUploadedKey, NSURLUbiquitousItemIsUploadingKey, NSURLUbiquitousItemPercentDownloadedKey, NSURLUbiquitousItemPercentUploadedKey] error:NULL];
    
    NSLog(@"--Attributes of URL:%@--",url);
    [attributes enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        NSLog(@"Key: %@ Value: %@",key,obj);
    }];
    
    
}
@end
