import Foundation

public enum AttentionCatalog {
    public static let unclassified = "unclassified"

    public static let categories = [
        AttentionCategory(id: "focus", name: "Focused work", kind: .focus, color: "3987E5"),
        AttentionCategory(id: "coding", name: "Coding", kind: .focus, color: "2A78D6"),
        AttentionCategory(id: "agents", name: "Agents", kind: .focus, color: "7F72E0"),
        AttentionCategory(id: "ai", name: "AI assistants", kind: .focus, color: "6DA7EC"),
        AttentionCategory(id: "design", name: "Design", kind: .focus, color: "5598E7"),
        AttentionCategory(id: "writing", name: "Writing and docs", kind: .focus, color: "256ABF"),
        AttentionCategory(id: "learning", name: "Learning", kind: .focus, color: "86B6EF"),
        AttentionCategory(
            id: "communication", name: "Chat", kind: .communication, color: "1BAF7A"),
        AttentionCategory(id: "meetings", name: "Meetings", kind: .communication, color: "0E8A5F"),
        AttentionCategory(id: "email", name: "Email", kind: .communication, color: "5FC9A0"),
        AttentionCategory(
            id: "entertainment", name: "Video", kind: .entertainment, color: "EB6834"),
        AttentionCategory(id: "social", name: "Social", kind: .entertainment, color: "E87BA4"),
        AttentionCategory(id: "games", name: "Games", kind: .entertainment, color: "E34948"),
        AttentionCategory(id: "shopping", name: "Shopping", kind: .entertainment, color: "EDA100"),
        AttentionCategory(id: "news", name: "News", kind: .entertainment, color: "C98500"),
        AttentionCategory(id: "music", name: "Music", kind: .neutral, color: "9A8FBF"),
        AttentionCategory(id: "planning", name: "Planning", kind: .neutral, color: "8A9AA8"),
        AttentionCategory(id: "neutral", name: "Utilities", kind: .neutral, color: "898781"),
        AttentionCategory(
            id: unclassified, name: "Unclassified", kind: .unclassified, color: "5C5B57"),
    ]

    public static let descriptions: [String: String] = [
        "focus": "focused work that does not fit a more specific category",
        "coding": "writing, reviewing, building or debugging software, terminals and developer tools",
        "agents": "running, supervising or reviewing AI coding agents and their sessions",
        "ai": "chatting with AI assistants such as ChatGPT, Claude or Gemini",
        "design": "visual, product or interface design work",
        "writing": "writing or editing documents, notes, specs and spreadsheets",
        "learning": "documentation, tutorials, talks, courses, papers and technical reading",
        "communication": "chat and direct messages with people",
        "meetings": "video calls and meetings",
        "email": "reading or writing email",
        "entertainment": "videos, streaming, shows and films watched for fun",
        "social": "social media feeds and community forums",
        "games": "playing or browsing games",
        "shopping": "shopping, food delivery and browsing products",
        "news": "news and current affairs",
        "music": "listening to music or podcasts",
        "planning": "calendars, task lists, project tracking and planning",
        "neutral": "system utilities, settings, file management and web search",
    ]

    public static let mixedDomains = [
        "youtube.com", "x.com", "twitter.com", "reddit.com", "linkedin.com", "twitch.tv",
        "medium.com", "news.ycombinator.com",
    ]

    public static let awayBundleIDs: Set<String> = [
        "com.apple.loginwindow", "com.apple.ScreenSaver.Engine", "com.apple.screensaver",
    ]

    public static let edithBundleIDs = ["com.pulkit.edith", "com.pulkit.edith.*"]

    public static let identityRuleIDs: Set<String> = Set(
        (products + [edithPages[0]]).map(\.id))

    public static let rules: [AttentionIdentityRule] =
        edithPages + products + applications + websites

    private static func rule(
        _ id: String, _ name: String, _ category: String, apps: [String] = [],
        sites: [String] = [], urls: [String] = [], keywords: [String] = [],
        contexts: [String] = []
    ) -> AttentionIdentityRule {
        AttentionIdentityRule(
            id: "catalog.\(id)", name: name, categoryID: category, bundleIDs: apps,
            domains: sites, urls: urls, keywords: keywords, contexts: contexts)
    }

    private static let edithPages: [AttentionIdentityRule] = [
        rule("edith", "Edith", "agents", apps: edithBundleIDs),
        rule(
            "edith.sessions", "Edith sessions", "agents", apps: edithBundleIDs,
            contexts: ["page=herdr"]),
        rule(
            "edith.agents", "Edith agents", "agents", apps: edithBundleIDs,
            contexts: ["page=agents"]),
        rule(
            "edith.usage", "Edith usage", "agents", apps: edithBundleIDs,
            contexts: ["page=dashboard"]),
        rule(
            "edith.review", "Edith review", "coding", apps: edithBundleIDs,
            contexts: ["page=quinjet"]),
        rule(
            "edith.machines", "Edith machines", "coding", apps: edithBundleIDs,
            contexts: ["page=machines"]),
        rule(
            "edith.docs", "Edith docs", "learning", apps: edithBundleIDs,
            contexts: ["page=docs"]),
        rule(
            "edith.music", "Edith music", "music", apps: edithBundleIDs,
            contexts: ["page=music"]),
        rule(
            "edith.media", "Edith media", "entertainment", apps: edithBundleIDs,
            contexts: ["page=media"]),
        rule(
            "edith.calendar", "Edith calendar", "planning", apps: edithBundleIDs,
            contexts: ["page=calendar"]),
        rule(
            "edith.attention", "Edith attention", "planning", apps: edithBundleIDs,
            contexts: ["page=attention"]),
        rule(
            "edith.settings", "Edith settings", "neutral", apps: edithBundleIDs,
            contexts: ["page=settings"]),
    ]

    private static let products: [AttentionIdentityRule] = [
        rule("github", "GitHub", "coding", sites: ["github.com", "githubusercontent.com"]),
        rule(
            "claude", "Claude", "ai",
            apps: ["com.anthropic.claudefordesktop"], sites: ["claude.ai"]),
        rule("chatgpt", "ChatGPT", "ai", apps: ["com.openai.chat"], sites: ["chatgpt.com"]),
        rule(
            "whatsapp", "WhatsApp", "communication",
            apps: ["net.whatsapp.WhatsApp", "net.whatsapp.WhatsAppSMB"],
            sites: ["web.whatsapp.com"]),
        rule(
            "slack", "Slack", "communication", apps: ["com.tinyspeck.slackmacgap"],
            sites: ["app.slack.com"]),
        rule("discord", "Discord", "communication", apps: ["com.hnc.Discord"], sites: ["discord.com"]),
        rule(
            "telegram", "Telegram", "communication",
            apps: ["ru.keepcoder.Telegram", "org.telegram.desktop"], sites: ["web.telegram.org"]),
        rule(
            "teams", "Microsoft Teams", "meetings",
            apps: ["com.microsoft.teams2", "com.microsoft.teams"], sites: ["teams.microsoft.com"]),
        rule("zoom", "Zoom", "meetings", apps: ["us.zoom.xos"], sites: ["zoom.us"]),
        rule(
            "spotify", "Spotify", "music", apps: ["com.spotify.client"],
            sites: ["open.spotify.com"]),
        rule(
            "applemusic", "Apple Music", "music", apps: ["com.apple.Music"],
            sites: ["music.apple.com"]),
        rule("youtube", "YouTube", "entertainment", sites: ["youtube.com", "youtu.be"]),
        rule("youtubemusic", "YouTube Music", "music", sites: ["music.youtube.com"]),
        rule(
            "netflix", "Netflix", "entertainment", apps: ["com.netflix.Netflix"],
            sites: ["netflix.com"]),
        rule("notion", "Notion", "writing", apps: ["notion.id"], sites: ["notion.so", "notion.site"]),
        rule("figma", "Figma", "design", apps: ["com.figma.Desktop"], sites: ["figma.com"]),
        rule("linear", "Linear", "planning", apps: ["com.linear"], sites: ["linear.app"]),
        rule(
            "superhuman", "Superhuman", "email", apps: ["com.superhuman.electron"],
            sites: ["superhuman.com"]),
        rule("x", "X", "social", sites: ["x.com", "twitter.com"]),
        rule("xbox", "Xbox", "games", sites: ["xbox.com"]),
    ]

    private static let applications: [AttentionIdentityRule] = [
        rule("xcode", "Xcode", "coding", apps: ["com.apple.dt.Xcode"]),
        rule(
            "vscode", "Visual Studio Code", "coding",
            apps: ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]),
        rule("cursor", "Cursor", "coding", apps: ["com.todesktop.230313mzl4w4u92"]),
        rule("zed", "Zed", "coding", apps: ["dev.zed.Zed", "dev.zed.Zed-Preview"]),
        rule("sublime", "Sublime Text", "coding", apps: ["com.sublimetext.4"]),
        rule("nova", "Nova", "coding", apps: ["com.panic.Nova"]),
        rule(
            "jetbrains", "JetBrains", "coding",
            apps: ["com.jetbrains.*", "com.google.android.studio"]),
        rule(
            "terminal", "Terminal", "coding",
            apps: [
                "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
                "dev.warp.Warp-Stable", "com.cmuxterm.app", "net.kovidgoyal.kitty",
                "org.alacritty", "com.github.wez.wezterm",
            ]),
        rule(
            "git", "Git clients", "coding",
            apps: [
                "com.DanPristupov.Fork", "com.fournova.Tower3", "com.github.GitHubClient",
                "com.git-tower.Tower",
            ]),
        rule(
            "devtools", "Developer tools", "coding",
            apps: [
                "com.docker.docker", "com.postmanlabs.mac", "com.tinyapp.TablePlus",
                "com.apple.iphonesimulator", "com.apple.dt.Instruments",
                "com.apple.dt.CreateML", "io.proxyman.NSProxy", "com.sequel-ace.sequel-ace",
            ]),
        rule(
            "agents.apps", "Coding agents", "agents",
            apps: [
                "com.openai.codex", "ai.opencode.desktop", "com.superset.desktop",
                "com.conductor.app", "build.conductor.app",
            ]),
        rule(
            "design.apps", "Design tools", "design",
            apps: [
                "com.bohemiancoding.sketch3", "com.adobe.Photoshop",
                "com.pixelmatorteam.pixelmator.x", "com.seriflabs.affinitydesigner2",
                "com.electron.excalidraw",
            ]),
        rule(
            "writing.apps", "Writing apps", "writing",
            apps: [
                "md.obsidian", "com.apple.iWork.Pages", "com.microsoft.Word",
                "net.shinyfrog.bear", "com.lukilabs.lukiapp", "com.apple.Notes",
                "com.apple.TextEdit", "com.ulyssesapp.mac",
            ]),
        rule(
            "chat.apps", "Chat", "communication",
            apps: [
                "com.apple.MobileSMS", "org.whispersystems.signal-desktop",
            ]),
        rule(
            "meetings.apps", "Meetings", "meetings",
            apps: [
                "com.apple.FaceTime", "Cisco-Systems.Spark", "co.teamport.around",
            ]),
        rule(
            "email.apps", "Email", "email",
            apps: [
                "com.apple.mail", "com.readdle.smartemail-Mac",
                "com.mimestream.Mimestream", "com.microsoft.Outlook",
            ]),
        rule(
            "planning.apps", "Planning", "planning",
            apps: [
                "com.apple.iCal", "com.culturedcode.ThingsMac",
                "com.todoist.mac.Todoist", "com.apple.reminders", "com.flexibits.fantastical2.mac",
            ]),
        rule(
            "video.apps", "Video players", "entertainment",
            apps: [
                "com.apple.TV", "com.colliderli.iina", "org.videolan.vlc",
            ]),
        rule(
            "music.apps", "Music", "music",
            apps: ["com.apple.podcasts"]),
        rule(
            "games.apps", "Games", "games",
            apps: ["com.valvesoftware.steam", "com.epicgames.EpicGamesLauncher"]),
        rule(
            "browsers", "Browser", "neutral",
            apps: [
                "com.google.Chrome", "com.google.Chrome.*", "company.thebrowser.Browser",
                "company.thebrowser.dia", "com.brave.Browser", "com.microsoft.edgemac",
                "com.apple.Safari", "org.mozilla.firefox", "com.operasoftware.Opera",
                "com.vivaldi.Vivaldi", "org.chromium.Chromium",
            ]),
        rule(
            "system", "System", "neutral",
            apps: [
                "com.apple.finder", "com.apple.systempreferences", "com.apple.ActivityMonitor",
                "com.apple.AppStore", "com.apple.Preview", "com.apple.Photos",
                "com.apple.SecurityAgent", "com.apple.UserNotificationCenter",
                "com.apple.loginwindow", "com.apple.keychainaccess", "com.1password.1password",
                "com.raycast.macos", "com.runningwithcrayons.Alfred", "com.electron.wispr-flow",
                "pl.maketheweb.cleanshotx", "com.apple.screenshot.launcher",
                "com.apple.ScreenSaver.Engine", "com.apple.archiveutility",
            ]),
    ]

    private static let websites: [AttentionIdentityRule] = [
        rule("gitlab", "GitLab", "coding", sites: ["gitlab.com", "bitbucket.org"]),
        rule(
            "localhost", "Local development", "coding",
            sites: ["localhost", "127.0.0.1", "0.0.0.0"]),
        rule(
            "stackoverflow", "Stack Overflow", "coding",
            sites: ["stackoverflow.com", "stackexchange.com", "superuser.com"]),
        rule(
            "cloud", "Cloud consoles", "coding",
            sites: [
                "vercel.com", "netlify.com", "dash.cloudflare.com", "console.aws.amazon.com",
                "console.cloud.google.com", "portal.azure.com", "fly.io", "railway.app",
                "render.com", "supabase.com", "sentry.io", "app.datadoghq.com",
                "console.anthropic.com", "platform.openai.com", "appstoreconnect.apple.com",
                "developer.apple.com",
            ]),
        rule(
            "packages", "Package registries", "coding",
            sites: [
                "npmjs.com", "pypi.org", "crates.io", "docs.rs", "swiftpackageindex.com",
                "pkg.go.dev", "rubygems.org",
            ]),
        rule(
            "agents.web", "Coding agents", "agents",
            urls: ["chatgpt.com/codex", "claude.ai/code", "jules.google.com", "v0.dev"]),
        rule(
            "ai.web", "AI assistants", "ai",
            sites: [
                "gemini.google.com", "perplexity.ai", "aistudio.google.com", "grok.com",
                "chat.mistral.ai", "deepseek.com", "poe.com",
            ]),
        rule(
            "design.web", "Design", "design",
            sites: [
                "excalidraw.com", "tldraw.com", "dribbble.com", "behance.net",
                "canva.com", "framer.com",
            ]),
        rule(
            "docs.web", "Docs", "writing",
            sites: [
                "docs.google.com", "sheets.google.com",
                "slides.google.com", "coda.io", "dropbox.com", "drive.google.com",
                "quip.com", "hackmd.io",
            ]),
        rule(
            "learning.web", "Learning", "learning",
            sites: [
                "developer.mozilla.org", "wikipedia.org", "arxiv.org", "dev.to",
                "readthedocs.io", "coursera.org", "udemy.com", "khanacademy.org",
                "w3schools.com", "huggingface.co", "kaggle.com", "leetcode.com",
                "swift.org", "rust-lang.org", "python.org", "go.dev", "typescriptlang.org",
                "react.dev", "nextjs.org", "tailwindcss.com",
            ]),
        rule(
            "chat.web", "Chat", "communication",
            sites: [
                "messenger.com",
            ]),
        rule(
            "meetings.web", "Meetings", "meetings",
            sites: ["meet.google.com", "whereby.com", "gather.town", "around.co"]),
        rule(
            "email.web", "Email", "email",
            sites: [
                "mail.google.com", "outlook.live.com", "outlook.office.com",
                "mail.proton.me", "fastmail.com",
            ]),
        rule(
            "planning.web", "Planning", "planning",
            sites: [
                "calendar.google.com", "atlassian.net", "trello.com",
                "asana.com", "todoist.com", "cal.com", "calendly.com", "clickup.com",
            ]),
        rule(
            "video.web", "Video", "entertainment",
            sites: [
                "primevideo.com", "hotstar.com",
                "jiocinema.com", "disneyplus.com", "twitch.tv", "hulu.com", "max.com",
                "tv.apple.com", "vimeo.com", "crunchyroll.com", "sonyliv.com", "zee5.com",
            ]),
        rule(
            "social.web", "Social", "social",
            sites: [
                "reddit.com", "linkedin.com", "instagram.com",
                "facebook.com", "threads.net", "bsky.app", "news.ycombinator.com",
                "tiktok.com", "pinterest.com", "mastodon.social", "quora.com",
            ]),
        rule(
            "music.web", "Music", "music",
            sites: [
                "soundcloud.com",
                "gaana.com", "jiosaavn.com", "wynk.in",
            ]),
        rule(
            "games.web", "Games", "games",
            sites: [
                "store.steampowered.com", "steamcommunity.com", "chess.com",
                "lichess.org", "epicgames.com", "playstation.com", "itch.io",
            ]),
        rule(
            "shopping.web", "Shopping", "shopping",
            sites: [
                "amazon.com", "amazon.in", "flipkart.com", "myntra.com", "ebay.com",
                "etsy.com", "aliexpress.com", "ajio.com", "nykaa.com", "swiggy.com",
                "zomato.com", "blinkit.com", "zeptonow.com", "bigbasket.com",
            ]),
        rule(
            "news.web", "News", "news",
            sites: [
                "nytimes.com", "theverge.com", "bbc.com", "bbc.co.uk", "cnn.com",
                "techcrunch.com", "arstechnica.com", "theguardian.com", "reuters.com",
                "bloomberg.com", "hindustantimes.com", "indiatimes.com", "economist.com",
                "wsj.com", "ndtv.com", "thehindu.com", "moneycontrol.com", "wired.com",
            ]),
        rule(
            "search.web", "Search", "neutral",
            sites: ["google.com", "bing.com", "duckduckgo.com", "kagi.com"]),
    ]
}
