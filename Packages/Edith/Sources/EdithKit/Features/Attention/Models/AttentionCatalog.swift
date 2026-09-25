import Foundation

public enum AttentionCatalog {
    public static let unclassified = "unclassified"

    public static let categories: [AttentionCategory] = [
        AttentionCategory(
            id: "focus", name: "Focused work", productivity: .productive, sphere: .work),
        AttentionCategory(
            id: "coding", name: "Coding", productivity: .veryProductive, sphere: .work),
        AttentionCategory(
            id: "review", name: "Code review", productivity: .veryProductive, sphere: .work),
        AttentionCategory(
            id: "agents", name: "Agents", productivity: .veryProductive, sphere: .work),
        AttentionCategory(
            id: "ai", name: "AI assistants", productivity: .productive, sphere: .work),
        AttentionCategory(
            id: "design", name: "Design", productivity: .veryProductive, sphere: .work),
        AttentionCategory(
            id: "writing", name: "Writing and docs", productivity: .veryProductive, sphere: .work),
        AttentionCategory(
            id: "research", name: "Research", productivity: .productive, sphere: .work),
        AttentionCategory(
            id: "learning", name: "Learning", productivity: .productive, sphere: .both),
        AttentionCategory(
            id: "data", name: "Data and analytics", productivity: .productive, sphere: .work),
        AttentionCategory(
            id: "planning", name: "Planning", productivity: .productive, sphere: .work),
        AttentionCategory(
            id: "meetings", name: "Meetings", productivity: .neutral, sphere: .work),
        AttentionCategory(
            id: "email", name: "Email", productivity: .neutral, sphere: .work),
        AttentionCategory(
            id: "workchat", name: "Work chat", productivity: .neutral, sphere: .work),
        AttentionCategory(
            id: "communication", name: "Chat", productivity: .neutral, sphere: .both),
        AttentionCategory(
            id: "personalchat", name: "Personal chat", productivity: .neutral, sphere: .personal),
        AttentionCategory(
            id: "network", name: "Professional network", productivity: .neutral, sphere: .work),
        AttentionCategory(
            id: "social", name: "Social", productivity: .distracting, sphere: .personal),
        AttentionCategory(
            id: "technews", name: "Tech news", productivity: .neutral, sphere: .both),
        AttentionCategory(
            id: "news", name: "News", productivity: .distracting, sphere: .personal),
        AttentionCategory(
            id: "reading", name: "Reading", productivity: .neutral, sphere: .personal),
        AttentionCategory(
            id: "entertainment", name: "Video", productivity: .veryDistracting, sphere: .personal),
        AttentionCategory(
            id: "shortvideo", name: "Short video", productivity: .veryDistracting, sphere: .personal
        ),
        AttentionCategory(
            id: "music", name: "Music", productivity: .neutral, sphere: .personal),
        AttentionCategory(
            id: "podcasts", name: "Podcasts", productivity: .neutral, sphere: .personal),
        AttentionCategory(
            id: "games", name: "Games", productivity: .veryDistracting, sphere: .personal),
        AttentionCategory(
            id: "shopping", name: "Shopping", productivity: .distracting, sphere: .personal),
        AttentionCategory(
            id: "food", name: "Food and delivery", productivity: .distracting, sphere: .personal),
        AttentionCategory(
            id: "finance", name: "Finance", productivity: .neutral, sphere: .personal),
        AttentionCategory(
            id: "travel", name: "Travel", productivity: .neutral, sphere: .personal),
        AttentionCategory(
            id: "health", name: "Health and fitness", productivity: .neutral, sphere: .personal),
        AttentionCategory(
            id: "search", name: "Search and browsing", productivity: .neutral, sphere: .both),
        AttentionCategory(
            id: "neutral", name: "Utilities", productivity: .neutral, sphere: .both),
        AttentionCategory(
            id: unclassified, name: "Unclassified", productivity: .neutral, sphere: .both),
    ]

    public static let descriptions: [String: String] = [
        "focus":
            "deep work that does not fit a more specific category, such as solving a hard problem in any tool",
        "coding":
            "writing, building, debugging or running software: code editors, IDEs, terminals, git clients, local dev servers, API consoles, cloud dashboards, package registries",
        "review":
            "reading and commenting on pull requests, diffs and code reviews, for example GitHub pull requests or Edith's review page",
        "agents":
            "starting, steering, watching or reviewing AI coding agents such as Claude Code, Codex or OpenCode, including Edith's sessions and usage pages",
        "ai":
            "chatting with general AI assistants such as ChatGPT, Claude, Gemini or Perplexity to think, draft or ask questions",
        "design":
            "visual, product, interface or brand design in tools like Figma, Sketch, Framer, Excalidraw or Photoshop",
        "writing":
            "writing or editing documents, specs, notes, spreadsheets and slides, for example Notion, Google Docs, Obsidian or Word",
        "research":
            "investigating a question for work: papers, benchmarks, competitor sites, market or technical research",
        "learning":
            "deliberately learning a skill: documentation, tutorials, technical talks, courses and how-to videos",
        "data":
            "dashboards, analytics, metrics, logs and SQL tools such as PostHog, Grafana, Metabase or a database client",
        "planning":
            "calendars, task lists, issue trackers, roadmaps and project management, for example Linear, Jira, Things or Google Calendar",
        "meetings":
            "live video or voice calls and meetings, for example Google Meet, Zoom, FaceTime or Teams calls",
        "email":
            "reading, triaging or writing email in Mail, Gmail, Superhuman or Outlook",
        "workchat":
            "team chat about work, such as Slack or Microsoft Teams channels and direct messages with colleagues",
        "communication":
            "messaging that mixes work and personal conversations",
        "personalchat":
            "messaging friends and family, such as WhatsApp, iMessage, Telegram or Signal",
        "network":
            "professional networking and hiring, such as LinkedIn, job boards and recruiting tools",
        "social":
            "scrolling social feeds and forums such as X, Reddit, Instagram, Threads or Facebook",
        "technews":
            "following technology, startup and AI news, for example Hacker News, The Verge or TechCrunch",
        "news":
            "general news, politics, sport and current affairs",
        "reading":
            "long-form reading for pleasure or interest: blogs, newsletters, Medium, Substack, books and articles",
        "entertainment":
            "watching videos, streams, shows and films for fun on YouTube, Netflix, Prime Video, Twitch or similar",
        "shortvideo":
            "endless short-form video such as YouTube Shorts, Instagram Reels or TikTok",
        "music":
            "choosing or listening to music on Spotify, Apple Music, YouTube Music or Edith's player",
        "podcasts":
            "listening to podcasts and audiobooks",
        "games":
            "playing, streaming or browsing video games and game stores",
        "shopping":
            "browsing or buying products in online stores such as Amazon or Flipkart",
        "food":
            "ordering food or groceries, for example Swiggy, Zomato, Blinkit or Uber Eats",
        "finance":
            "banking, investing, payments, taxes and budgeting",
        "travel":
            "maps, rides, flights, hotels and trip planning",
        "health":
            "workouts, health records, sleep and fitness apps",
        "search":
            "web search engines and jumping between sites without a clear destination",
        "neutral":
            "system overhead: Finder, settings, file management, password managers, launchers, screenshots and updates",
    ]

    public static let mixedDomains = [
        "youtube.com", "x.com", "twitter.com", "reddit.com", "linkedin.com", "twitch.tv",
        "medium.com", "news.ycombinator.com", "substack.com", "instagram.com",
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
            "edith.review", "Edith review", "review", apps: edithBundleIDs,
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
            "whatsapp", "WhatsApp", "personalchat",
            apps: ["net.whatsapp.WhatsApp", "net.whatsapp.WhatsAppSMB"],
            sites: ["web.whatsapp.com"]),
        rule(
            "slack", "Slack", "workchat", apps: ["com.tinyspeck.slackmacgap"],
            sites: ["app.slack.com"]),
        rule(
            "discord", "Discord", "communication", apps: ["com.hnc.Discord"], sites: ["discord.com"]
        ),
        rule(
            "telegram", "Telegram", "personalchat",
            apps: ["ru.keepcoder.Telegram", "org.telegram.desktop"], sites: ["web.telegram.org"]),
        rule(
            "teams", "Microsoft Teams", "workchat",
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
        rule(
            "notion", "Notion", "writing", apps: ["notion.id"], sites: ["notion.so", "notion.site"]),
        rule("figma", "Figma", "design", apps: ["com.figma.Desktop"], sites: ["figma.com"]),
        rule("linear", "Linear", "planning", apps: ["com.linear"], sites: ["linear.app"]),
        rule(
            "superhuman", "Superhuman", "email", apps: ["com.superhuman.electron"],
            sites: ["superhuman.com"]),
        rule("x", "X", "social", sites: ["x.com", "twitter.com"]),
        rule("linkedin", "LinkedIn", "network", sites: ["linkedin.com"]),
        rule("hackernews", "Hacker News", "technews", sites: ["news.ycombinator.com"]),
        rule("reddit", "Reddit", "social", sites: ["reddit.com"]),
        rule("instagram", "Instagram", "social", sites: ["instagram.com"]),
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
                "com.docker.docker", "com.postmanlabs.mac", "com.apple.iphonesimulator",
                "com.apple.dt.Instruments", "com.apple.dt.CreateML", "io.proxyman.NSProxy",
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
            "chat.apps", "Messages", "personalchat",
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
            "podcasts.apps", "Podcasts", "podcasts",
            apps: ["com.apple.podcasts", "com.overcast.overcast-mac", "fm.pocketcasts.PocketCasts"]),
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
            "chat.web", "Messenger", "personalchat",
            sites: [
                "messenger.com"
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
                "facebook.com", "threads.net", "bsky.app", "pinterest.com", "mastodon.social",
                "quora.com",
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
                "etsy.com", "aliexpress.com", "ajio.com", "nykaa.com",
            ]),
        rule(
            "news.web", "News", "news",
            sites: [
                "nytimes.com", "bbc.com", "bbc.co.uk", "cnn.com",
                "theguardian.com", "reuters.com",
                "bloomberg.com", "hindustantimes.com", "indiatimes.com", "economist.com",
                "wsj.com", "ndtv.com", "thehindu.com", "moneycontrol.com",
            ]),
        rule(
            "review.github", "GitHub pull requests", "review", sites: ["github.com"],
            contexts: ["section=pull"]),
        rule(
            "review.gitlab", "Merge requests", "review", urls: ["gitlab.com"],
            keywords: ["merge request"]),
        rule(
            "shorts", "Short video", "shortvideo",
            sites: ["tiktok.com"], urls: ["youtube.com/shorts", "instagram.com/reels"]),
        rule(
            "shorts.youtube", "YouTube Shorts", "shortvideo", sites: ["youtube.com"],
            contexts: ["section=shorts"]),
        rule(
            "technews.web", "Tech news", "technews",
            sites: [
                "techcrunch.com", "theverge.com", "arstechnica.com", "wired.com",
                "producthunt.com", "lobste.rs", "techmeme.com", "theinformation.com",
            ]),
        rule(
            "reading.web", "Reading", "reading",
            sites: [
                "medium.com", "substack.com", "goodreads.com", "getpocket.com",
                "readwise.io", "kindle.amazon.com", "paulgraham.com",
            ]),
        rule(
            "research.web", "Research", "research",
            sites: [
                "scholar.google.com", "semanticscholar.org", "paperswithcode.com",
                "openreview.net", "ssrn.com",
            ]),
        rule(
            "data.web", "Data and analytics", "data",
            sites: [
                "posthog.com", "grafana.com", "metabase.com", "mixpanel.com", "amplitude.com",
                "lookerstudio.google.com", "analytics.google.com", "app.datadoghq.com",
            ]),
        rule(
            "data.apps", "Data tools", "data",
            apps: [
                "com.tinyapp.TablePlus", "com.sequel-ace.sequel-ace", "com.postgresapp.Postgres2",
            ]),
        rule(
            "network.web", "Hiring", "network",
            sites: [
                "wellfound.com", "ashbyhq.com", "greenhouse.io", "lever.co", "naukri.com",
                "indeed.com", "ycombinator.com",
            ]),
        rule(
            "food.web", "Food and delivery", "food",
            sites: [
                "swiggy.com", "zomato.com", "blinkit.com", "zeptonow.com", "bigbasket.com",
                "ubereats.com", "doordash.com", "instacart.com",
            ]),
        rule(
            "finance.web", "Finance", "finance",
            sites: [
                "zerodha.com", "groww.in", "paypal.com", "wise.com", "robinhood.com",
                "coinbase.com", "hdfcbank.com", "icicibank.com", "sbi.co.in", "incometax.gov.in",
            ]),
        rule(
            "travel.web", "Travel", "travel",
            sites: [
                "booking.com", "airbnb.com", "makemytrip.com", "uber.com", "olacabs.com",
                "skyscanner.com", "irctc.co.in", "expedia.com",
            ], urls: ["google.com/maps", "maps.google.com"]),
        rule(
            "health.web", "Health and fitness", "health",
            sites: ["strava.com", "fitbit.com", "myfitnesspal.com", "cult.fit"]),
        rule(
            "health.apps", "Health and fitness", "health",
            apps: ["com.apple.Health", "com.apple.Fitness"]),
        rule(
            "search.web", "Search", "search",
            sites: ["google.com", "bing.com", "duckduckgo.com", "kagi.com"]),
    ]
}
