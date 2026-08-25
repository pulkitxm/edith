cask "edith" do
  version "0.0.158"
  sha256 "a7703cb7f8b1faf96bed2b7e86ee1a99bd48ed905d18b3a4b1718de8e6531e4c"

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
  binary "#{appdir}/Edith.app/Contents/MacOS/edh"

  uninstall quit: [
    "com.pulkit.edith",
    "com.pulkit.edith.statusbar",
    "com.pulkit.edith.files",
  ]

  zap trash: [
    "~/Library/Application Support/Edith",
    "~/Library/Caches/Edith",
    "~/Library/Caches/com.pulkit.edith",
    "~/Library/HTTPStorages/com.pulkit.edith",
    "~/Library/Preferences/com.pulkit.edith.plist",
    "~/Library/Preferences/com.pulkit.edith.shared.plist",
    "~/Library/Preferences/com.pulkit.edith.statusbar.plist",
    "~/Library/Saved Application State/com.pulkit.edith.savedState",
  ]
end
