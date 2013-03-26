//
//  MNDocumentController+Convenience.h
//  MindNodeTouch
//
//  Created by Markus Müller on 03.04.12.
//  Copyright (c) 2012 IdeasOnCanvas GmbH. All rights reserved.
//
//  A collection of methodes that sit ontop of MNDocumentController and only use it's public interface

#import "MNDocumentController.h"

@interface MNDocumentController (Convenience)

- (MNDocumentReference *)documentReferenceFromFileURL:(NSURL *)fileURL;
- (MNDocumentReference *)documentReferenceFromFilename:(NSString *)filename;

@end
