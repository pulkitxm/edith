cask "edith" do
  version "0.0.350"
  sha256 "5f3e560948b00d75f6afbc32b9b4e04e8452c26d80312c5a50f6466b102c41e7"

  url "https://github.com/pulkitxm/edith/releases/download/v#{version}/Edith.dmg",
      verified: "github.com/pulkitxm/edith/"
  name "Edith"
  desc "Menu bar control center for coding agents, clipboard, music, and disk tools"
  homepage "https://edith.pulkit.page/"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "Edith.app"
  binary "#{appdir}/Edith.app/Contents/MacOS/ed"
  binary "#{appdir}/Edith.app/Contents/MacOS/ed", target: "edith"

  uninstall quit: [
    "com.pulkit.edith",
    "com.pulkit.edith.files",
    "com.pulkit.edith.helper.v2",
    "com.pulkit.edith.helper",
    "com.pulkit.edith.statusbar",
  ]

  zap trash: [
    "~/Library/Application Support/Edith",
    "~/Library/Caches/com.pulkit.edith",
    "~/Library/Caches/Edith",
    "~/Library/HTTPStorages/com.pulkit.edith",
    "~/Library/Preferences/com.pulkit.edith.plist",
    "~/Library/Preferences/com.pulkit.edith.shared.plist",
    "~/Library/Preferences/com.pulkit.edith.helper.v2.plist",
    "~/Library/Preferences/com.pulkit.edith.helper.plist",
    "~/Library/Preferences/com.pulkit.edith.statusbar.plist",
    "~/Library/Saved Application State/com.pulkit.edith.savedState",
  ]
end
