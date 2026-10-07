// Mac check: swiftc -parse-as-library host/MergeMove.swift host/probe/test_merge_move.swift -o /tmp/t && /tmp/t
import Foundation

@main struct TestMergeMove {
    static func main() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("merge-move-\(UUID().uuidString)")
        func touch(_ url: URL, _ text: String) {
            try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! text.write(to: url, atomically: true, encoding: .utf8)
        }
        func check(_ ok: Bool, _ what: String) { if !ok { print("FAIL: \(what)"); exit(1) } }
        // One-time move of an old per-game home: nothing already in the shared home is replaced.
        let old = root.appendingPathComponent("Homes/G/Library"), shared = root.appendingPathComponent("home/Library")
        let clash = "Application Support/Studio/Game/slot1.sav"
        touch(shared.appendingPathComponent(clash), "x")
        touch(old.appendingPathComponent("Application Support/Godot/new.cfg"), "new")
        touch(old.appendingPathComponent(clash), "old copy")
        let kept = mergeMove(from: old, to: shared)
        check(fm.fileExists(atPath: shared.appendingPathComponent("Application Support/Godot/new.cfg").path), "moved")
        check(kept == [old.appendingPathComponent(clash).path], "clash kept \(kept)")
        check((try? String(contentsOf: shared.appendingPathComponent(clash), encoding: .utf8)) == "x", "clash not overwritten")
        check(!fm.fileExists(atPath: old.appendingPathComponent("Application Support/Godot").path), "moved folder gone")
        check(mergeMove(from: root.appendingPathComponent("nothing"), to: shared).isEmpty, "missing source is a no-op")
        try? fm.removeItem(at: root)
        print("merge move ok")
    }
}
