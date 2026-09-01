cask "edith" do
  version "0.0.212"
  sha256 "6e85ee5b5cd8377e52c620785d7198aa096d171cf4d93ca8329e0d60488b3da5"

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
    "~/Library/Preferences/com.pulkit.edith.helper.plist",
    "~/Library/Preferences/com.pulkit.edith.statusbar.plist",
    "~/Library/Saved Application State/com.pulkit.edith.savedState",
  ]
end
