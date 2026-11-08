// ChaosPad's Background Assets downloader extension (Xcode's "Background Download Extension" template, Apple-Hosted,
// Managed): the system downloads the game's Apple-hosted asset packs (sc3disc: the trimmed disc image sc3.sparse)
// with the app, by their essential download policy. Nothing to customise.
import BackgroundAssets
import ExtensionFoundation
import StoreKit

@main
struct DownloaderExtension: StoreDownloaderExtension {
    func shouldDownload(_ assetPack: AssetPack) -> Bool {
        return true
    }
}
