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
                    "Edith moves the selected files into the folder open in Finder. Existing files are never replaced."
                )
                .settingsCaption()
                Toggle(
                    "Rename the selection with F2",
                    isOn: $rename.configured(AppStorageKeys.FinderTools.rename))
                Toggle(
                    "Paste copied images as PNG files",
                    isOn: $pasteImages.configured(AppStorageKeys.FinderTools.pasteImages))
                Text(
                    "Press ⌘V in Finder to save a copied PNG or TIFF into the open folder with a timestamped name."
                )
                .settingsCaption()
            }

            Section("Disk images") {
                Toggle(
                    "Offer one-click app installation",
                    isOn: $diskImageInstaller.configured(
                        AppStorageKeys.FinderTools.diskImageInstaller))
                Text(
                    "When a mounted DMG contains exactly one verified app, Edith can install it in Applications, eject the image, and move the unchanged download to Trash. Existing apps are never replaced."
                )
                .settingsCaption()
            }

            Section("Access") {
                LabeledContent("Accessibility", value: "Finder keyboard shortcuts")
                LabeledContent("Automation", value: "Finder selection and destination")
                Text(
                    "Finder Automation is requested by macOS on first use. Disk image installation does not need Full Disk Access."
                )
                .settingsCaption()
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}
