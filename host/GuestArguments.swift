// Native Swift executables read this cached array instead of the argc/argv supplied to their main function.
// Publish through Swift's setter as well as crt_externs before loading the guest's static initializers.
@_cdecl("ShackSetGuestCommandLine")
func ShackSetGuestCommandLine(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) {
    CommandLine.arguments = (0..<Int(argc)).compactMap { argv[$0].map { String(cString: $0) } }
}
