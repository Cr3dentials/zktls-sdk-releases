import SwiftUI
import ZktlsSDK

@main
struct ZktlsSampleApp: App {
    init() {
        // Your app's key, once, at launch: here the ZKTLS_APP_KEY build setting (README.md).
        if let key = Bundle.main.object(forInfoDictionaryKey: "ZKTLS_APP_KEY") as? String, !key.isEmpty {
            Zktls.configure(appKey: key)
        }
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
