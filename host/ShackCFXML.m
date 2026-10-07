#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import "ShackCFXML.h"

// CFXMLParser (CFXMLTreeCreateFromData and friends), which iOS's CoreFoundation dropped. Feral Interactive's engine parses
// its XML that way (BioShock Remastered's bundle). Built on NSXMLParser: a CFTree whose nodes are ShackXMLNode objects,
// as the real parser hands out a tree of CFXMLNodes. ponytail: no DTDs or entities beyond the predefined ones, and
// attributes are only reachable through CFXMLNodeGetInfoPtr's element info (attributes dictionary, order, isEmpty).
enum { kNodeDocument = 1, kNodeElement = 2, kNodeProcessingInstruction = 4, kNodeComment = 5, kNodeText = 6, kNodeCDATA = 7 };
enum { kSkipMetaData = 1 << 1, kSkipWhitespace = 1 << 3 };

typedef struct { CFDictionaryRef attributes; CFArrayRef attributeOrder; Boolean isEmpty; char reserved[3]; } ShackXMLElementInfo;

@interface ShackXMLNode : NSObject {
@public
    CFIndex type; NSString *string; ShackXMLElementInfo info;
}
@end
@implementation ShackXMLNode
- (void)dealloc { if (info.attributes) CFRelease(info.attributes); if (info.attributeOrder) CFRelease(info.attributeOrder); }
@end

static void releaseInfo(const void *info) { CFRelease(info); }
static CFTreeRef MakeTree(CFIndex type, NSString *string) {
    ShackXMLNode *n = [ShackXMLNode new]; n->type = type; n->string = [string copy];
    CFTreeContext ctx = { 0, (void *)CFBridgingRetain(n), NULL, releaseInfo, NULL };
    return CFTreeCreate(NULL, &ctx);
}
static ShackXMLNode *NodeOf(CFTreeRef tree) { CFTreeContext ctx = {0}; CFTreeGetContext(tree, &ctx); return (__bridge ShackXMLNode *)ctx.info; }

@interface ShackXMLBuilder : NSObject <NSXMLParserDelegate>
@property (nonatomic) CFTreeRef root; @property (nonatomic) CFOptionFlags options; @property (nonatomic) CFTreeRef current;
@end
@implementation ShackXMLBuilder
- (void)add:(CFIndex)type _:(NSString *)s { CFTreeRef t = MakeTree(type, s); CFTreeAppendChild(_current, t); CFRelease(t); }
- (void)parser:(NSXMLParser *)p didStartElement:(NSString *)name namespaceURI:(NSString *)ns qualifiedName:(NSString *)q attributes:(NSDictionary *)attrs {
    CFTreeRef t = MakeTree(kNodeElement, name); ShackXMLNode *n = NodeOf(t);
    n->info.attributes = CFBridgingRetain([attrs copy]); n->info.attributeOrder = CFBridgingRetain(attrs.allKeys);
    CFTreeAppendChild(_current, t); CFRelease(t); _current = CFTreeGetChildAtIndex(_current, CFTreeGetChildCount(_current) - 1);
}
- (void)parser:(NSXMLParser *)p didEndElement:(NSString *)name namespaceURI:(NSString *)ns qualifiedName:(NSString *)q {
    NodeOf(_current)->info.isEmpty = CFTreeGetChildCount(_current) == 0; _current = CFTreeGetParent(_current);
}
- (void)parser:(NSXMLParser *)p foundCharacters:(NSString *)s {
    if ((_options & kSkipWhitespace) && ![s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length) return;
    CFTreeRef last = CFTreeGetChildCount(_current) ? CFTreeGetChildAtIndex(_current, CFTreeGetChildCount(_current) - 1) : NULL;
    ShackXMLNode *n = last ? NodeOf(last) : nil;
    if (n && n->type == kNodeText) n->string = [n->string stringByAppendingString:s];   // the parser hands text over in pieces
    else [self add:kNodeText _:s];
}
- (void)parser:(NSXMLParser *)p foundCDATA:(NSData *)d { [self add:kNodeCDATA _:[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @""]; }
- (void)parser:(NSXMLParser *)p foundComment:(NSString *)c { if (!(_options & kSkipMetaData)) [self add:kNodeComment _:c]; }
- (void)parser:(NSXMLParser *)p foundProcessingInstructionWithTarget:(NSString *)t data:(NSString *)d { if (!(_options & kSkipMetaData)) [self add:kNodeProcessingInstruction _:t]; }
@end

CFTreeRef CFXMLTreeCreateFromData(CFAllocatorRef allocator, CFDataRef xmlData, CFURLRef dataSource, CFOptionFlags parseOptions, CFIndex versionOfNodes) {
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:(__bridge NSData *)xmlData];
    ShackXMLBuilder *b = [ShackXMLBuilder new];
    b.root = MakeTree(kNodeDocument, dataSource ? ((__bridge NSURL *)dataSource).absoluteString : nil);
    b.current = b.root; b.options = parseOptions; parser.delegate = b;
    if (![parser parse]) { NSLog(@"[ShackCFXML] parse failed: %@", parser.parserError); CFRelease(b.root); return NULL; }
    return b.root;   // +1, as Create promises
}
const void *CFXMLTreeGetNode(CFTreeRef tree) { return tree ? (__bridge const void *)NodeOf(tree) : NULL; }
CFStringRef CFXMLNodeGetString(const void *node) { return node ? (__bridge CFStringRef)((__bridge ShackXMLNode *)node)->string : NULL; }
CFIndex CFXMLNodeGetTypeCode(const void *node) { return node ? ((__bridge ShackXMLNode *)node)->type : 0; }
const void *CFXMLNodeGetInfoPtr(const void *node) { ShackXMLNode *n = (__bridge ShackXMLNode *)node; return n && n->type == kNodeElement ? &n->info : NULL; }
CFIndex CFXMLNodeGetVersion(const void *node) { return 0; }
