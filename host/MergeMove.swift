import Foundation

// HOME is the shared container (ShackLoader): a game's Library from its old per-game home joins it at launch
// (AppModel.launch). Mac check: header of host/probe/test_merge_move.swift.
// Moves everything in `from` into `to` without replacing anything; returns the paths left behind (clashes).
// Emptied source folders are removed.
@discardableResult
func mergeMove(from: URL, to: URL) -> [String] {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: from.path, isDirectory: &isDir), isDir.boolValue else { return [] }
    try? fm.createDirectory(at: to, withIntermediateDirectories: true)
    var kept: [String] = []
    for name in (try? fm.contentsOfDirectory(atPath: from.path)) ?? [] {
        let src = from.appendingPathComponent(name), dst = to.appendingPathComponent(name)
        var dstIsDir: ObjCBool = false
        if !fm.fileExists(atPath: dst.path, isDirectory: &dstIsDir) {
            if (try? fm.moveItem(at: src, to: dst)) == nil { kept.append(src.path) }
        } else if dstIsDir.boolValue, (try? src.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            kept += mergeMove(from: src, to: dst)
        } else {
            kept.append(src.path)
        }
    }
    if ((try? fm.contentsOfDirectory(atPath: from.path)) ?? []).isEmpty { try? fm.removeItem(at: from) }
    return kept
}
