# Personal recording branch

This branch includes the motion selection change submitted separately to upstream, plus personal recording controls.

- Settings → General → Automatic Follow Motion controls automatic zoom creation for new recordings. It defaults to off. Existing authored motion is unchanged.
- The game-controller button on the recorder bar starts a replay recording of a display, window, or area. Select 1, 2, 5, 10 (default), 15, or 30 minutes in its popover or in General settings. Select the source and start as usual.
- Game mode records H.264 screen video and the currently configured system-audio scope, with the cursor baked into the footage. It does not record camera or microphone and does not support pause. It uses short rolling files on disk; recordings shorter than the chosen duration are kept in full.
- Stop automatically writes an MP4 to the export directory configured in Settings, then restores the recorder bar. The game popover can reveal the latest saved video in Finder. No editor session is required.
- New Recording in the File or menu-bar menu (Command-N) restores capture without requiring an untouched project to be opened. The completion card also offers Continue Recording; its existing save barrier preserves the take first.
- Source pickers no longer dim displays/windows/devices or outline selected windows/displays. Area-selection handles remain while choosing a rectangle, and all selection overlays close when recording starts.

Replay files are assembled with AVFoundation without re-encoding. The rolling buffer retains the configured duration plus a segment boundary (normally up to 15 seconds) and any writer finishing that boundary. If saving fails, the error includes the recovery project path. An already existing export is never overwritten. The remaining segment MP4 files, if present, are inside `media/replay-segments` in that project.

Build locally with a development certificate using the upstream instructions, or use `DOGSC_SIGNING_IDENTITY=- bash build-app.sh` for an ad-hoc signed local build. The default result is `.build/local/DogSC Dev.app`, with separate settings and permissions. To build a replacement for the installed app, run `DOGSC_REPLACE_INSTALLED=1 DOGSC_SIGNING_IDENTITY=- bash build-app.sh`, quit DogSC, then copy `.build/local/DogSC.app` into Applications. The replacement retains the original bundle identifier and settings. Both variants disable official updates so they cannot overwrite these customizations. macOS may request screen/audio permissions again because the signing identity changes. Ad-hoc signing is intended for local use, not notarized distribution.

Validation includes Swift tests with actual H.264/AAC encoding, rolling retention, MP4 decoding, idle-screen rollover, Stop-boundary freezing, and failure preservation. Real-game capture performance and the native mouse UI still need a manual smoke test on the target Mac.
