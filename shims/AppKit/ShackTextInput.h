#import <Foundation/Foundation.h>
// AppKit text input for games (Unity's player view implements NSTextInputClient). Foundation only, so it has a Mac
// test (host/probe/test_textinput.m).
//
// What -[NSResponder interpretKeyEvents:] does: printable characters go to insertText:replacementRange:, the editing
// keys (delete, return, tab, escape, arrows, ...) become their standard commands via doCommandBySelector:, and
// Command-modified keys (key equivalents) insert nothing. `events` are NSEvents (anything answering -characters and
// -modifierFlags).
void ShackInterpretKeyEvents(id responder, NSArray *events);
// The Mac virtual key code for a character typed on the on-screen keyboard; 0xFFFF when no US key produces it.
unsigned short ShackKeyCodeForCharacter(unichar c);
