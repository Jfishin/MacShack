#import <CoreFoundation/CoreFoundation.h>
// CFXMLParser on NSXMLParser; ShackHooks hands these to Intel guests (AArchX resolves system symbols through it).
CFTreeRef CFXMLTreeCreateFromData(CFAllocatorRef allocator, CFDataRef xmlData, CFURLRef dataSource, CFOptionFlags parseOptions, CFIndex versionOfNodes);
const void *CFXMLTreeGetNode(CFTreeRef tree);
CFStringRef CFXMLNodeGetString(const void *node);
CFIndex CFXMLNodeGetTypeCode(const void *node);
const void *CFXMLNodeGetInfoPtr(const void *node);
CFIndex CFXMLNodeGetVersion(const void *node);
