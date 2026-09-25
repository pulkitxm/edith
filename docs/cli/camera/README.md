# `ed camera`

Frames, styles and controls Edith Camera, the virtual camera that Zoom, Meet,
FaceTime, OBS, Chrome and every other video app can pick. You arrange the shot
once in Edith and the app you call from sees the result.

```text
ed camera status [--json]
ed camera on [--json]
ed camera off [--json]
ed camera sources [--json]
ed camera source <camera> [--json]
ed camera zoom <level> [--json]
ed camera frame [--zoom <level>] [--x <0-1>] [--y <0-1>] [--tilt <degrees>] [--turns <0-3>] [--flip <bool>] [--flip-vertical <bool>] [--auto off|close|medium|wide] [--json]
ed camera reset [--json]
ed camera look <preset> [--json]
ed camera background none|blur|color|image [--color <hex>] [--blur <0-1>] [--image <path>] [--json]
ed camera pause [--style card|blank|freeze] [--message <text>] [--json]
ed camera resume [--json]
ed camera scene list [--json]
ed camera scene apply <scene> [--json]
ed camera scene save <name> [--replace] [--json]
ed camera scene next [--json]
ed camera scene previous [--json]
```

A bare `ed camera` runs `status`, and a bare `ed camera scene` runs
`scene list`. `sources` is also `cameras`, `scene list` is also `scene ls` and
`scene previous` is also `scene prev`.

## How it works

Turn on **Virtual Camera** in Edith's Extensions screen under **Media**, or run
`ed camera on`. The **Virtual Camera** page then appears in the Media section of
the sidebar.

Edith Camera is a CoreMediaIO camera extension inside Edith. Video apps read it
like any other camera. Edith's menu bar app captures your real camera, applies
the framing, look, background and overlays, and sends each frame to the
extension. The real camera only turns on while an app is actually showing Edith
Camera, and it turns off again three seconds after the last app stops. When the
menu bar app is not sending frames, apps see a card that says so instead of a
frozen or black picture.

The Virtual Camera page shows the same picture as a live preview. Drag it to move
the shot, scroll or pinch to zoom, and double-click to reset. Every change
reaches the apps that are using Edith Camera straight away.

## Installing Edith Camera

macOS installs camera extensions only from an app that meets three conditions:

1. The app is in the Applications folder.
2. The app is signed with the System Extension entitlement, which needs a
   provisioning profile from a paid Apple Developer Program team.
3. You approve the extension once, in System Settings under General, Login Items
   & Extensions, Camera Extensions.

To build a copy that can install it, create two provisioning profiles on the
Apple Developer site for the team that signs Edith. The first is for the app
identifier `com.pulkit.edith` with the System Extension capability. The second is
for `com.pulkit.edith.camera` with the App Groups capability and the group
`<team id>.com.pulkit.edith.camera`. Then point the build at both:

```sh
EDITH_APP_PROVISIONING_PROFILE=~/Profiles/Edith.provisionprofile \
EDITH_CAMERA_PROVISIONING_PROFILE=~/Profiles/EdithCamera.provisionprofile \
./build.sh --release --install
```

`build.sh` checks that each profile matches its identifier, team, entitlement and
expiry date before it embeds them. Only then does it sign the app with the
install entitlement. Without the profiles the build still works: the preview,
framing and scenes all run, and the Output tab explains what is missing.

Open **Output** on the Virtual Camera page and choose **Install Edith Camera**,
then approve it in System Settings. `ed camera status` reports
`extension: installed` once apps can see it. Development builds carry their own
extension identity, `com.pulkit.edith.dev.<slot>.camera`, and appear in apps as
`Edith Camera (<slot>)`.

## Framing

`zoom` sets the zoom level from 1 to 8. `frame` sets any mix of zoom, the center
of the shot (`--x` from 0 at the left to 1 at the right, `--y` from 0 at the top
to 1 at the bottom), a tilt from -45 to 45 degrees, quarter turns clockwise, and
horizontal or vertical flips. Edith keeps the crop inside the camera picture, so
a center near an edge stops at that edge.

`--auto close|medium|wide` turns on auto framing. Edith finds the faces in the
picture and follows them smoothly, with a little headroom above. `--auto off`
turns it off. `reset` returns the framing to the full picture.

With sharp zoom on, the default, Edith switches the camera to a higher
resolution while you are zoomed in, when the camera offers one.

## Looks and background

`look` applies one of `natural`, `bright`, `studio`, `warm`, `cool`, `vivid`,
`muted`, `film`, `mono` or `noir`. The page adds exposure, brightness,
contrast, saturation, warmth, tint, sharpening, softening and vignette.

`background blur` blurs everything behind you.
`background color --color #1E293B` replaces it with a color, and
`background image --image <path>` with a picture. `background none` shows your real background. Edith finds you in the
picture on this Mac with Vision, and no frame leaves the Mac.

## Scenes

A scene stores the framing, look, background and overlays, and optionally the
camera. Edith starts with **Full frame** and **Close-up**. `scene save <name>`
stores the current setup, and `--replace` overwrites a scene with the same
name. `scene apply` takes a name, a unique name prefix, the number from
`scene list` or the scene id. When scene changes are set to **Smooth**, the
framing glides to the new scene instead of cutting. On the page, ⌘1 to ⌘9
switch to the first nine scenes.

## Pausing

`pause` hides the camera without leaving the call. `--style card` shows a card
with your message over a blurred copy of the last frame, `blank` sends black
and `freeze` holds the last frame. The real camera turns off while paused.
`resume` goes live again.

## Output

Plain `status` prints one line per fact. `--json` reports `enabled`,
`helperRunning`, `extensionInstalled`, `extensionBuild`, `live`, `headline`,
`apps`, `framesPerSecond`, `camera`, `cameraResolution`, `output`,
`cameraAccess`, `privacy`, `privacyMessage`, `scene`, `sceneModified`,
`framing`, `look`, `background` and `message`. Every changing command prints
what it did, or the same JSON with `message` set.

Commands that change the camera need the Edith menu bar app. They exit 4 when it
is not running, when Virtual Camera is off, or when camera access is missing,
and 1 when a value is out of range or a scene or camera does not exist.

- [`ed extensions`](../extensions/README.md)
- [`ed permissions`](../permissions/README.md)
- [All command groups](../README.md)
