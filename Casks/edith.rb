cask "edith" do
  version "0.0.127"
  sha256 "8b5b4d7e83adee3aea679f88ae6ecc92b92db083c292d9e152b8a3946fa0f8b6"

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
