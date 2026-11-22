import Network

/// Makes iOS ask for Local Network access as soon as the app starts.
///
/// iOS blocks every connection to the local network until the user allows it, and reports the
/// block as "The Internet connection appears to be offline". The permission prompt is supposed
/// to appear on the first local connection, but a plain connection to an IP address doesn't
/// reliably trigger it (seen after a reinstall under a new bundle id: no prompt, and the app was
/// missing from Settings > Privacy & Security > Local Network). Browsing for a Bonjour service
/// declared in `NSBonjourServices` always triggers it, so do that once at launch. Nothing is
/// done with the results; the browse stops after a few seconds.
@MainActor
enum LocalNetworkPermission {
    private static var browser: NWBrowser?

    static func request() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_rosbridge._tcp", domain: nil), using: .tcp)
        browser.start(queue: .main)
        self.browser = browser
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            self.browser?.cancel()
        }
    }
}
