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
ed camera reset-look [--json]
ed camera look <preset> [--json]
ed camera background none|blur|color|image [--color <hex>] [--blur <0-1>] [--image <path>] [--json]
ed camera pause [--style card|blank|freeze|stopped] [--message <text>] [--json]
ed camera resume [--json]
ed camera scene list [--json]
ed camera scene apply <scene> [--json]
ed camera scene save <name> [--replace] [--json]
ed camera scene next [--json]
ed camera scene previous [--json]
ed camera scene rename <scene> <name> [--json]
ed camera scene duplicate <scene> [--json]
ed camera scene move <scene> --by <places> [--json]
ed camera scene delete <scene> [--yes] [--json]
ed camera extension status [--json]
ed camera extension install [--yes] [--json]
ed camera extension remove [--yes] [--json]
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
the shot, scroll or pinch to zoom, and double-click to reset the framing.
`ed camera reset-look` is the inspector's Reset the look button and leaves the
framing alone. Every change
reaches the apps that are using Edith Camera straight away.

## Installing Edith Camera

macOS installs camera extensions only from an app that meets three conditions:

1. The app is in the Applications folder.
2. The app is signed with the System Extension entitlement, which needs a
   provisioning profile from a paid Apple Developer Program team.
3. You approve the extension once, in System Settings under General, Login Items
   & Extensions, Camera Extensions.

The quickest way to get the profiles is to let Xcode make them. Sign in to Xcode,
Settings, Accounts with the Apple ID of the team that signs Edith, then run:

```sh
make camera-profiles
make install
```

`make camera-profiles` builds a throwaway project with automatic signing, so Xcode
registers this Mac, creates the `com.pulkit.edith` identifier with the System
Extension capability and `com.pulkit.edith.camera` with its app group, and
downloads a development profile for each. `make install` finds them in Xcode's
profile folder on its own. You can also point the build at profiles you made on
the Apple Developer site:

```sh
EDITH_APP_PROVISIONING_PROFILE=~/Profiles/Edith.provisionprofile \
EDITH_CAMERA_PROVISIONING_PROFILE=~/Profiles/EdithCamera.provisionprofile \
./build.sh --release --install
```

`build.sh` embeds a profile only when it matches its identifier and team, grants
the entitlement, has not expired, includes this Mac and includes the certificate
Edith is signed with, because macOS refuses to open an app whose profile does
not. Only then does it sign the app with the install entitlement. It looks for
profiles on its own only for `--install` builds, so a release build never ships
a development profile. Without the profiles the build still works: the preview,
framing and scenes all run, and the Output tab explains what is missing.

Open **Output** on the Virtual Camera page and choose **Install Edith Camera**,
then approve it in System Settings. `ed camera status` reports
`extension: installed` once apps can see it. Development builds carry their own
extension identity, `com.pulkit.edith.dev.<slot>.camera`, and appear in apps as
`Edith Camera (<slot>)`.

## Without a developer account: OBS Virtual Camera

Free Apple IDs (Personal Teams) cannot get the System Extension capability, so
they cannot install Edith Camera. If OBS Studio is installed and its virtual
camera has been approved once, Edith can send its picture through the OBS
Virtual Camera instead. OBS's camera extension accepts frames from any app,
which is how OBS itself feeds it.

With the output set to **Automatic** (the default) Edith uses Edith Camera when
it is installed and the OBS Virtual Camera otherwise. Choose it on the Output
tab to force one or the other. Then:

1. Keep the OBS app closed. Edith steps aside whenever OBS is running so OBS can
   drive its own camera.
2. Pick **OBS Virtual Camera** in Zoom, Meet, FaceTime or any other app.
3. Edith turns your camera on as soon as an app opens the OBS camera, and stops
   when that app quits. It cannot tell when a call ends while the app stays
   open, because the OBS camera reports itself as in use for as long as Edith
   is feeding it. Pause with ⌃⌥⌘V, or quit the call app, to turn your camera
   off.

`ed camera status` reports `sending to: OBS Virtual Camera` and `route: obs` in
JSON.

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
resolution while you are zoomed in, when the camera offers one. It prefers
formats that support macOS background replacement so zooming keeps those
effects available.

## Looks and background

`look` applies one of `natural`, `bright`, `studio`, `warm`, `cool`, `vivid`,
`muted`, `film`, `mono` or `noir`. The page adds exposure, brightness,
contrast, saturation, warmth, tint, sharpening, softening and vignette.

`background blur` blurs everything behind you.
`background color --color #1E293B` replaces it with a color, and
`background image --image <path>` with a picture. `background none` passes through
your camera picture, including macOS video effects. Edith finds you in the
picture on this Mac with Vision, and no frame leaves the Mac.

When macOS Background is active, Edith preserves it and pauses its own background
replacement. Turn macOS Background off in the Video Effects menu to resume
Edith's saved background choice. The Background panel shows when macOS is in
control, and `status --json` reports `systemBackgroundActive`.

## Scenes

A scene stores the framing, look, background and overlays, and optionally the
camera. Edith starts with **Full frame** and **Close-up**. `scene save <name>`
stores the current setup, and `--replace` overwrites a scene with the same
name. `scene apply` takes a name, a unique name prefix, the number from
`scene list` or the scene id. When scene changes are set to **Smooth**, the
framing glides to the new scene instead of cutting. On the page, ⌘1 to ⌘9
switch to the first nine scenes. `scene next` and `scene previous` step
through that list for a hotkey or a stream deck. The page itself picks a scene
directly. `scene rename`, `scene duplicate`, `scene move --by` and
`scene delete` match the inspector's rename, duplicate, reorder and delete
actions. Delete previews first and applies with `--yes`.

## System extension

`extension status` is Check again. `extension install` and `extension remove`
are the Install Edith Camera and Remove buttons. They preview first. `--yes`
asks the open Edith app to submit the system extension request. macOS may still
ask you to approve it. A development build that is not in `/Applications`
reports that it needs to be moved there instead of installing.

## Pausing

`pause` hides the camera without leaving the call. `--style card` shows a card
with your message over a blurred copy of the last frame, `blank` sends black
and `freeze` holds the last frame. The real camera turns off while paused.
Choose **Pause > Stop completely**, or run `ed camera pause --style stopped`,
to stop capture, preview and virtual-camera output completely. This state
persists across app restarts. Opening a video app, changing scenes or pressing
the pause shortcut does not restart it. Choose **Go live** or run
`ed camera resume` to resume explicitly.

For the other pause styles, `resume` goes live again. The global shortcut
⌃⌥⌘V pauses behind a card or goes live again from any app, and you can change it
in Settings under Shortcuts.

## Output

Plain `status` prints one line per fact. `--json` reports `enabled`,
`helperRunning`, `extensionInstalled`, `extensionBuild`, `live`, `headline`,
`apps`, `framesPerSecond`, `camera`, `cameraResolution`, `output`,
`cameraAccess`, `privacy`, `privacyMessage`, `scene`, `sceneModified`,
`framing`, `look`, `background`, `systemBackgroundActive` and `message`. Every changing command prints
what it did, or the same JSON with `message` set.

Commands that change the camera need the Edith menu bar app. They exit 4 when it
is not running, when Virtual Camera is off, or when camera access is missing,
and 1 when a value is out of range or a scene or camera does not exist.

- [`ed extensions`](../extensions/README.md)
- [`ed permissions`](../permissions/README.md)
- [All command groups](../README.md)

## Meeting playback and recording

The buttons below the stage switch between Live, Away, Freeze and Stop. Choose a
camera, a local video, or a display/window. The virtual camera selected in Meet
stays the same when the source changes inside Edith.

```text
ed camera video ~/Movies/demo.mp4 [--once] [--json]
ed camera play playing|paused|stopped [--json]
ed camera freeze [--json]
ed camera screen list [--json]
ed camera screen window:123 [--json]
ed camera record start --path ~/Movies/meeting.mp4 [--json]
ed camera record stop [--json]
ed camera mirror true|false [--json]
```

Video files loop unless `--once` is set. Pause video holds its current position;
Freeze holds the composed frame and resumes from that position. Stop completely
releases the source. Selecting a camera returns to live capture. Screens and
windows require macOS screen recording permission. A window that closes must be
selected again.

Record saves the composed outgoing picture, including looks and overlays, as an
MP4. It can record without another app opening the virtual camera. Stop recording
waits for the file to finish before reporting it saved. When meeting audio is
running at the start of recording, the MP4 also includes its mixed audio track.

Meet flips its local camera preview horizontally. Use Edith's Audience preview
to check overlay text. Mirror self preview affects only Edith's preview. Flip
participant output, or `ed camera mirror`, flips the complete outgoing image,
including text, for every recipient. Leave it off for readable text in the
normal outgoing stream.

## Meeting audio

Edith installs its microphone driver through the application’s existing
privileged helper during setup and updates. Approve Edith’s background helper
through its normal setup flow. If macOS has not loaded the device yet, restart
macOS once. Select Edith Microphone in Meet or Zoom. Edith sends
one mix to that device. The video virtual camera remains a separate device.
Choose your physical microphone as Edith's input, never the same loopback device
as both input and output. Device UIDs and effect settings stay saved across
restarts, so changing clips or video sources does not require reselecting the
meeting microphone. Audio starts only after you explicitly enable it.

```sh
ed camera audio devices
ed camera audio input "MacBook Pro Microphone"
ed camera audio output "Edith Microphone"
ed camera audio on
ed camera audio record "Good morning"
ed camera audio save
ed camera audio play "Good morning"
ed camera audio import thunder --path ~/Sounds/thunder.wav --sound
ed camera audio edit thunder --start 0.2 --end 2.4 --gain 0.7
ed camera audio play thunder
ed camera audio voice deep
ed camera audio effects --pitch -200 --reverb 8 --delay 0
ed camera audio levels --mic 1 --clips 0.9 --source 0.6
ed camera audio source true
ed camera audio mute
ed camera audio stop
ed camera audio off
```

Presets are natural, deep, bright, cinematic, radio, telephone, robot, alien and
echo. Speech snippets use the live microphone's effect chain. Sound effects
bypass voice effects. Both join the same compressed mix to avoid sudden level
jumps. Microphone mute keeps sounds and clips available. Stop stops all clips.

Imports are copied into Edith's local audio library. Trimming and gain edits
preserve the original file. Removing a clip removes its library entry while
retaining the recording on disk. Save the current snippet before changing audio
devices or turning audio off. A snippet's library entry is saved when recording
starts so captured audio remains recoverable after an interrupted session.

Enable source audio to include the selected video file or screen capture in the
meeting mix. It follows playback, pause, freeze and looping. Disable source audio
to share only its picture. A selected window includes audio from its owning app;
a selected display includes system audio. Screen capture excludes Edith’s own audio to avoid
feeding the mix back into itself.

Edith Microphone is a native CoreAudio driver bundled with Edith. It requires no
separate audio application. Development builds carry a distinct device identity per
worktree and do not install system components automatically. The driver transports stereo 48 kHz audio with a bounded memory buffer
and sends silence when Edith stops producing audio. It does not become the
system output device. Voice presets, mixing, trimming and recording run locally
inside Edith.

## Local voice models

Import a ContentVec ONNX encoder and an RVC v1 or v2 ONNX voice export through
the Voice panel. Edith validates both models, copies them into its library and
runs them through its bundled native inference runtime. There is no separate
server, application or runtime installation. Models must be self-contained ONNX
files with 32, 40 or 48 kHz output. PyTorch checkpoints are not accepted.

```sh
ed camera audio model-import "My voice" --encoder ~/Models/contentvec.onnx --path ~/Models/voice.onnx
ed camera audio model "My voice"
ed camera audio model-pitch --transpose -3
ed camera audio model-off
ed camera audio model-remove "My voice"
```

The selected model converts live speech and speech snippets before the shared
voice effects. Sounds and source audio keep their original voices. Conversion
buffers 480 ms of speech and adds model processing time. A model that cannot
keep up stops conversion and displays an error. Choosing Original voice restores
unconverted speech. Muting the physical microphone still allows speech snippets
and sounds to play. Voice model selection and pitch survive app restarts.

Voice models are imported assets. Edith does not label a pitch effect as a
celebrity voice or provide a built-in celebrity model.
