# Social Manager

Social Manager opens the actual Instagram, Facebook, X and other websites inside
Edith. Each named account gets an independent persistent WebKit browser store.
Cookies, local storage and other website data belong to that account, so several
accounts on the same website can remain signed in at once.

## Get started

1. Enable **Social Manager** in Extensions, under Media.
2. Open **Media > Social Manager** and select a platform.
3. Choose **Add account**, enter a name and an optional emoji or initials badge,
   then choose **Add and open**.
4. Sign in directly on the website, including any two-factor authentication.
5. Add the other accounts the same way. Select a platform to see its account count
   and account cards, then choose **Open account** to return to a saved session.

Use **Add website** for another platform. Enter its name and HTTPS URL. Platforms
are URL-based and do not require a social-network API integration.

## Tabs and side-by-side layouts

Opening an account creates a workspace tab, or focuses its existing pane. Use
**Side by side** in the workspace header to choose another account, then open it
to the right or below the focused account. Accounts can belong to different
platforms. The account cards also have an **Open side by side** button when a
workspace tab is open.

The layout uses the same split engine and divider interaction as Agent Sessions.
Drag a divider to resize panes. Use **Layout** for columns, rows, a grid, equal
sizes or **Separate into tabs**. Each pane shows its account and platform, with
controls to focus, maximize, restore or close it. Closing a tab releases its
browser views and keeps the login session. Navigating to Accounts or another
Edith page retains the open workspace while the window remains open.

Website popups open as website tabs inside their account pane and share that
account's store. Uploads use the native file picker and downloads use a save
dialog. Links remain inside the isolated browser instead of moving the login
flow into a different browser profile.

## Account data

Account names, badges and platform URLs are stored locally in
`social-manager/accounts.json` under Edith's data folder. WebKit manages browser
data in a persistent store keyed by the account's UUID. Renaming an account keeps
that identifier and its session. Edith does not collect or save a separate copy
of website passwords. Websites decide when sessions expire or require sign-in.

Account lists and browser sessions are local to this Mac and are not included in
Edith's iCloud settings backup. The extension's enablement preference is backed
up. Development builds use their own app identity and account list.

From an account card's menu, **Clear login session** closes that account and
removes its browser store. **Remove account** also removes its saved name and
badge. Both actions leave other accounts alone. Removing an account in Edith
does not delete the account on the website.

## Command line

```sh
ed extensions enable socialManager
ed extensions verify socialManager --json
ed app reveal socialManager
```

Accounts and browser layouts are managed in the Social Manager window.
