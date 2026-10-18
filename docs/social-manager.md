# Social Manager

Social Manager organizes social accounts by profile, such as Personal, Studio or
a client. Each profile contains only the accounts you add to it: Instagram,
YouTube, X, LinkedIn, Facebook or a custom website. It opens the actual websites
inside Edith. Each connected account gets an independent persistent WebKit browser store.
Cookies, local storage and other website data belong to that account, so several
accounts on the same website can remain signed in at once.

## Get started

1. Enable **Social Manager** in Extensions, under Media.
2. Open **Media > Social Manager**, choose **Add profile** and enter its name and
   optional emoji or initials badge.
3. Select the profile, choose **Add account**, select a platform and enter an
   account label, then choose **Add and open**.
4. Sign in directly on the website, including any two-factor authentication.
5. Add other platforms to the same profile, or create another profile for a
   different person, brand or client. Clicking a profile shows only its connected
   accounts. Choose **Open account** on a platform card to return to its session.

Use **Manage profile > Add custom website** for another platform. Enter its name
and HTTPS URL to add it to that profile and open its account. Platforms are
URL-based and do not require a social-network API integration. **Manage profile**
also lets you rename a profile or remove it and clear all its connected sessions.

## Tabs and side-by-side layouts

Opening an account creates a workspace tab, or focuses its existing pane. Use
**Side by side** in the workspace header to choose another account, then open it
to the right or below the focused account. Accounts can belong to different
platforms and different profiles. The account cards also have an **Open side by side** button when a
workspace tab is open.

The layout uses the same split engine and divider interaction as Agent Sessions.
Drag a divider to resize panes. Use **Layout** for columns, rows, a grid, equal
sizes or **Separate into tabs**. Each pane shows its profile, account and platform, with
controls to focus, maximize, restore or close it. Closing a tab releases its
browser views and keeps the login session. Navigating to Profiles or another
Edith page retains the open workspace while the window remains open.

Website popups open as website tabs inside their account pane and share that
account's store. Uploads use the native file picker and downloads use a save
dialog. Links remain inside the isolated browser instead of moving the login
flow into a different browser profile.

## Account data

Profiles, connected account names, badges and platform URLs are stored locally in
`social-manager/accounts.json` under Edith's data folder. WebKit manages browser
data in a persistent store keyed by the account's UUID. Renaming an account keeps
that identifier and its session. Edith does not collect or save a separate copy
of website passwords. Websites decide when sessions expire or require sign-in.

Profile lists and browser sessions are local to this Mac and are not included in
Edith's iCloud settings backup. The extension's enablement preference is backed
up. Development builds use their own app identity and account list.

From an account card's menu, **Clear login session** closes that account and
clears its cookies and website storage. **Remove account** also removes its saved name and
badge. Both actions leave other accounts alone. Removing an account in Edith
does not delete the account on the website.

## Command line

```sh
ed extensions enable socialManager
ed extensions verify socialManager --json
ed app reveal socialManager
```

Accounts and browser layouts are managed in the Social Manager window.
