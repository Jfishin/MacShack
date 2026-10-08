#import <Foundation/Foundation.h>

// This process's address space and memory limit, as text (MacShack Play reports it before a Windows program).
// reserve = NO only walks the map, safe beside a running guest; YES also reserves PROT_NONE (freed at once) to measure
// the largest single and the cumulative mmap capacity, which would starve a running guest while it lasts.
NSString *ShackVAReport(BOOL reserve);
