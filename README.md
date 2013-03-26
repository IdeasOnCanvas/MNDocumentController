# MNDocumentController

MNDocumentController is a controller that manages on disk representations of UIDocuments. It supports either local or iCloud documents and performs all operations coordinated and asynchronous.

MNDocumentController is not a drop in replacement for your current solution and adapting it for your project will require a considerable amount of work. As several helper classes are missing it won't even compile on your system!

I'm releasing this code to help other who are struggling with adding iCloud to their own iOS apps. iCloud support in MNDocumentController is not perfect (for example folders are missing), but it's shipping code that is working reasonable well in my own app [MindNode](http://www.mindnode.com/).

# License
This code is licensed under the MT License. See LICENSE.md for more information.