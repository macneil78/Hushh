import HushCore

// Checks that the prebuilt TDLib binary loads and runs on this Mac. Needs no API credentials.
if let version = await TDSession.probeVersion() {
    print("TDLib \(version) is working.")
} else {
    print("TDLib didn't report a version.")
}
