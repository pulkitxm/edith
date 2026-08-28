import EdithKit
import SwiftUI

struct FinderToolsRows: View {
    @AppStorage(AppStorageKeys.FinderTools.enabled, store: SharedDefaults.store) private
        var enabled =
        false
    @AppStorage(AppStorageKeys.FinderTools.cutPaste, store: SharedDefaults.store) private
        var cutPaste = true
    @AppStorage(AppStorageKeys.FinderTools.rename, store: SharedDefaults.store) private
        var rename = true
    @AppStorage(AppStorageKeys.FinderTools.pasteImages, store: SharedDefaults.store) private
        var pasteImages = true
    @AppStorage(AppStorageKeys.FinderTools.diskImageInstaller, store: SharedDefaults.store) private
        var diskImageInstaller = true

    var body: some View {
        Group {
            Section("Finder shortcuts") {
                Toggle(
                    "Cut and paste files with ⌘X and ⌘V",
                    isOn: $cutPaste.configured(AppStorageKeys.FinderTools.cutPaste))
                Text(
                    "Edith moves the selected files into the folder open in Finder. Existing files are never replaced, and a failed batch is rolled back when possible."
                )
                .settingsCaption()
                Toggle(
                    "Rename the selection with F2",
                    isOn: $rename.configured(AppStorageKeys.FinderTools.rename))
                Toggle(
                    "Paste copied images as PNG files",
                    isOn: $pasteImages.configured(AppStorageKeys.FinderTools.pasteImages))
                Text(
                    "Press ⌘V in Finder to save a copied image into the open folder as a PNG with a timestamped name. Large or invalid images are rejected before decoding."
                )
                .settingsCaption()
            }

            Section("Disk images") {
                Toggle(
                    "Offer one-click app installation",
                    isOn: $diskImageInstaller.configured(
                        AppStorageKeys.FinderTools.diskImageInstaller))
                Text(
                    "When a mounted DMG contains exactly one verified app, Edith can install it in Applications, eject the image, and move the unchanged download to Trash. Edith rechecks the app before copying and never replaces an existing app."
                )
                .settingsCaption()
            }

            Section("Access") {
                LabeledContent("Accessibility", value: "Finder keyboard shortcuts")
                LabeledContent("Automation", value: "Finder selection and destination")
                Text(
                    "Accessibility is only needed for keyboard features. Finder Automation is requested on first use of selection or destination access. Disk image installation needs neither permission nor Full Disk Access."
                )
                .settingsCaption()
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}
