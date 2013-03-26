//
//  MNDocumentController+Convenience.m
//  MindNodeTouch
//
//  Created by Markus Müller on 03.04.12.
//  Copyright (c) 2012 IdeasOnCanvas GmbH. All rights reserved.
//

#import "MNDocumentController+Convenience.h"
#import "MNDocumentReference.h"
#import "MNDocument.h"

@implementation MNDocumentController (Convenience)


- (MNDocumentReference *)documentReferenceFromFileURL:(NSURL *)fileURL
{
    if (!fileURL) return nil;
    id fileURLID;
    [fileURL getResourceValue:&fileURLID forKey:NSURLFileResourceIdentifierKey error:NULL];
    
    for (MNDocumentReference *currentReference in [MNDocumentController sharedDocumentController].documentReferences) {
        NSURL *currentURL = currentReference.fileURL;
        id currentFileURLID;
        [currentURL getResourceValue:&currentFileURLID forKey:NSURLFileResourceIdentifierKey error:NULL];

        if ([currentFileURLID isEqual:fileURLID]) {
            return currentReference;
        }

        if ([currentURL isEqual:fileURL]) {
            return currentReference;
        }
    }
    return nil;
}


- (MNDocumentReference *)documentReferenceFromFilename:(NSString *)filename
{
    if (!filename) return nil;
    if (![filename hasSuffix:MNDocumentMindNodeExtension]) {
        filename = [filename stringByAppendingPathExtension:MNDocumentMindNodeExtension];
    }
    
    for (MNDocumentReference *currentReference in [MNDocumentController sharedDocumentController].documentReferences) {
        NSURL *currentURL = currentReference.fileURL;
        
        if ([[[currentURL lastPathComponent] lowercaseString] isEqualToString:filename]) {
            return currentReference;
        }
    }
    return nil;
}


@end
