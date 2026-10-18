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
   optional emoji or initials badge and profile email address.
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
**Side by side** at the right of the tab bar to choose another account or merge
an existing tab. Accounts can belong to different
platforms and different profiles. The account cards also have an **Open side by side** button when a
workspace tab is open.

The tabs, drag coordinator, live drop previews, snap-layout chooser, layout picker
and divider interaction are shared with Agent Sessions. Drag an account from the
account rail, a tab or a pane header to an edge to split, or to a pane's center
to swap places. A new account dropped in the center keeps the displaced account
in its own tab. Drag to the outside edge to span the whole side. Drag over the
**Layouts** pill to choose a template and a slot. Hold over another tab to switch
to it while dragging, or drop onto its center to combine the tabs. Drop between
tabs to reorder or detach a pane into its own tab. Escape cancels a drag.

Drag a divider to resize panes. Use **Layout** for arrangement thumbnails,
rotation, horizontal or vertical flips, equal sizes, maximize, saved custom
layouts or **Separate**. **Gather All Tabs** combines every open tab. The
**Animate Changes** toggle controls the same layout motion as Agent Sessions.
Each pane shows its profile, account and platform, with
controls to focus, maximize, restore or close it. Closing a tab releases its
browser views and keeps the login session. Navigating to Profiles or another
Edith page retains the open workspace while the window remains open.

Website popups open as website tabs inside their account pane and share that
account's store. Uploads use the native file picker and downloads use a save
dialog. Links remain inside the isolated browser instead of moving the login
flow into a different browser profile.

Right-click profiles, accounts, workspace tabs or pane headers for their controls.
Profiles can open all connected accounts in tabs or side by side. Drag profiles,
account-rail rows or workspace tabs to reorder them. Switch profiles using the
rail's profile menu to bring another profile's accounts into the workspace.
The sidebar button shows the account rail, or its compact-window sheet.
Drag a pane or single-account tab outside the workspace to open a separate
window. Closing that window or choosing **Return to workspace** brings the same
browser session back. Use **Position beside**
for an exact right or bottom placement, or **Move to tab** to combine workspaces.
Tab menus include closing other tabs, closing tabs to the right and reopening a
closed workspace. Pane menus include website zoom and new website tabs.

Keyboard controls work while a website or its text field has focus:

| Shortcut | Action |
| --- | --- |
| Control+Tab / Control+Shift+Tab | Next / previous workspace tab, including Profiles |
| Command+Option+Arrow | Focus the pane in that direction, matching Agent Sessions |
| Option+Backtick / Option+Shift+Backtick | Focus next / previous pane, matching Agent Sessions |
| Command+Shift+Return | Maximize / restore the focused pane |
| Command+Control+Right / Left | Focus next / previous pane |
| Command+1 through Command+9 | Select a workspace tab |
| Command+T or Command+0 | Show the profile library |
| Command+Shift+T | Reopen the last closed workspace |
| Command+W | Close the focused website popup tab, or the workspace tab |
| Command+L | Edit the focused pane's website address |
| Command+R | Reload the focused website |

## Profile email and account pictures

Set **Profile email** in the profile editor. The **Email** menu is available on
the profile and while operating any of its account panes. Open Gmail in a tab,
on the right or below the current account. Each profile has its own persistent
Gmail session, separate from its social accounts and other profiles. Sign in to
the matching Google account on the website; entering a profile email is a label
and does not sign in automatically.

Choose a profile or account picture in its editor or right-click menu. Profile
pictures appear on the profile cards and above their connected accounts. Account
pictures appear on account cards and pane headers. Replace or remove them using
the same controls. Profile and account pictures are independent, including the
profile's Gmail account. Edith saves a local PNG thumbnail up to 256 pixels in
`social-manager/avatars/`; the original file is not modified. Renaming or moving
an account between profiles keeps its picture and session. Removing an account
or profile also removes its saved pictures.

## Account data

Profiles, email labels, connected account names, badges, picture filenames and platform URLs are stored locally in
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
