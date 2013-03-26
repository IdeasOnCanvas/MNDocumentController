//
//  MNDocumentReference.h
//  MindNodeTouch
//
//  Created by Markus Müller on 23.09.10.
//  Copyright 2010 IdeasOnCanvas GmbH. All rights reserved.
//

#import <Foundation/Foundation.h>
@class MNDocument;

// attributes
extern NSString *MNDocumentReferenceDisplayNameKey;
extern NSString *MNDocumentReferenceModificationDateKey;
extern NSString *MNDocumentReferencePreviewKey;

extern NSString *MNDocumentReferenceStatusUpdatedKey; // virtual

extern CGFloat MNDocumentReferencePreviewWidthPhone;
extern CGFloat MNDocumentReferencePreviewWidthPad;


@interface MNDocumentReference : NSObject  <NSFilePresenter>

#pragma mark - Init

+ (void)createNewDocumentWithFileURL:(NSURL *)fileURL completionHandler:(void (^)(MNDocument *document, MNDocumentReference *reference))completionHandler;
- (id)initWithFileURL:(NSURL *)fileURL modificationDate:(NSDate *)modificationDate;
- (void)enableFilePresenter;
- (void)disableFilePresenter;
- (void)loadDocumentWithCompletionHandler:(void (^)(MNDocument *document))completionHandler;

#pragma mark - Properties

@property (readonly,strong) NSString *displayName;
@property (readonly,strong) NSString *displayModificationDate;
@property (readonly,strong) NSURL *fileURL;
@property (readonly,strong) NSDate *modificationDate;

// iCloud state
@property (readonly) BOOL isUbiquitous;
@property (readonly) BOOL hasUnresolvedConflicts;
@property (readonly) BOOL isDownloaded;
@property (readonly) BOOL isDownloading;
@property (readonly) BOOL isUploaded;
@property (readonly) BOOL isUploading;
@property (readonly) CGFloat percentDownloaded;
@property (readonly) CGFloat percentUploaded;


#pragma mark - iCloud Support

- (void)startDownloading;
- (void)updateWithMetadataItem:(NSMetadataItem *)metaDataItem;
- (void)updateMetadataFromURL;


#pragma mark - Preview Image

@property (atomic,readonly,strong) UIImage *preview;
- (void)previewImageWithCallbackBlock:(void(^)(UIImage *image))callbackBlock;
- (void)previewImageWithWidth:(CGFloat)width withCallbackBlock:(void(^)(UIImage *image))callbackBlock;
+ (UIImage *)animationImageForDocument:(MNDocument *)document withSize:(CGSize)size;
+ (UIImage *)previewImageForDocumenAtURL:(NSURL *)url withMaxSize:(CGFloat)size;

@end
