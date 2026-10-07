// swiftc -parse-as-library host/GuestArguments.swift host/probe/test_guest_arguments.swift -o /tmp/t && /tmp/t
import Foundation

@main struct TestGuestArguments {
    static func main() {
        // Warm Swift's cache as the host can do before a native Swift guest starts.
        let original = CommandLine.arguments
        let wanted = ["/Crimson Probe.app/Contents/MacOS/Crimson", "Width=960", "Height=540", "한글"]
        let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: wanted.count + 1)
        for (i, value) in wanted.enumerated() { argv[i] = strdup(value) }
        argv[wanted.count] = nil
        ShackSetGuestCommandLine(Int32(wanted.count), argv)
        for i in wanted.indices { free(argv[i]) }
        argv.deallocate()
        precondition(CommandLine.arguments == wanted, "guest arguments must replace the warmed cache and own their storage")
        CommandLine.arguments = original
        print("guest arguments ok")
    }
}
