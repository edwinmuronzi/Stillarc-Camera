# StillarcCamera development

Open `StillarcCamera.xcodeproj` and use scheme `StillarcCamera`. The Swift source and assets are in `StillarcCamera/`.

After changes, build in Xcode, install on the connected iPhone, and leave the app open for device testing. Commit the complete source changes and push to https://github.com/edwinmuronzi/Stillarc-Camera after verification. Exclude build products, local Xcode state and credentials.

## Device regression checks

- Open LUT → Save Preset, save a named setup, change it, and restore it from the same panel. The selected preset is yellow; automatic exposure/focus readings preserve selection, while changing the setup clears it. Test rename/delete through Presets.
- Change mode, lens/zoom, look/LUT, manual controls and framing. Background/foreground repeatedly, then force-quit/relaunch. Verify the same setup is restored with Preserve Settings enabled.
- Record successive Dual Shot clips in Standard and with styles/LUTs, including grain/glow. Move the phone. Inspect both previews and the left edge of both saved files. Each recording must create exactly two playable files.
- Toggle waveform, zebra, peaking and false color from the eye panel, repeatedly and while recording. Each switch should react on its first tap.
- Switch 8× ↔ 0.5× while recording, then stop and record again. Both previews should remain live.
- Check microphone selection, headphones, audio/video sync and capture interruption recovery on real hardware.

DEBUG-only launch arguments `--verify-live-zoom`, `--verify-advanced-preview`, `--verify-focus-pull` and `--verify-styled-recording`, `--verify-efficiency` and `--verify-interruption` run bounded device checks. The styled-recording check uses temporary files and does not save to Photos. Use a normal launch afterwards.

`--verify-efficiency` records a private 60-second styled Dual Shot pair and logs thermal state, both preview counts, final frame counts and dimensions. `--verify-interruption` injects capture-session interruption notifications and checks finalization/resume. Diagnostic movie events are intercepted so they do not save to Photos. Keep the phone unlocked for sustained capture checks. Real call/lock interruption scenarios still need device testing.

Efficiency changes preserve recording resolution, frame rate, bitrate and grading. Motion/storage polling and capture metering stop in the background, unused audio monitoring is lazy, and preview/writer format descriptions are reused. Report thermal state and measured battery/power separately; thermal status alone does not measure energy consumption.

## Photo pipeline and onboarding

`--verify-photo-pipeline` exercises reordered callbacks, isolated grading contexts, both saved framings, thumbnail bounds and chronological ordering. `--verify-photo-burst` submits five HEIF shutter requests 140 ms apart, then repeats with a style; it checks completion and main-actor progress and cleans its local files without writing test images to Photos. Device verification passed all ten captures; completion including processing was 4.42 seconds plain and 2.75 seconds styled. This is a bounded regression check, not a guarantee of identical throughput on every device or format.

Test first-launch onboarding and Settings → feature tour, including interactive look comparisons, large text and Reduce Motion. Preview stores must never activate the camera or overwrite preserved shooting preferences. Use `--show-tour --tour-page N` for Debug visual checks (zero-based page).

Run `scripts/export-marketing.sh` to refresh ten native interface images and marketing compositions, then rebuild to include the compressed onboarding previews. Review the output before release. Minimum deployment is iOS 26; RAW, codecs and lens availability remain hardware-dependent. Simulator compilation does not replace testing on the oldest supported hardware.

## 1.2 feature validation

The app now embeds `LockCapture` (ExtensionKit secure capture) and `CameraControlWidget` (WidgetKit control), sharing the camera intent with the main app. All three targets must use the same signing team and matching bundle-ID prefixes. Locked capture has a separate photo-only camera and cannot browse the main gallery. Session content imports only after the main gallery index loads and is invalidated only after the index writes successfully. Test actual Lock Screen customization, authentication, extension termination during capture and import on hardware; compilation/signing alone does not prove those system flows.

New Debug diagnostics:

- `--verify-upgrade`: four batches of five independent shots, then available Native RAW/Live/depth modes, full-resolution RAW edit checks, non-destructive editing and a 250-record archive roundtrip. Does not write to Photos. Wait for `UPGRADE_VERIFY COMPLETE`.
- `--verify-library`: 250 records restored through a new archive instance, edit recipes retained, deletion persisted, 30 preview edits, bounded thumbnails and unchanged original bytes.
- `--verify-viewfinder`: A/B autofocus measurements, exposure preservation, forward/reverse pulls and repeated cancellation.
- `--verify-direct-grade`: compares the optimized working-resolution grading path against full-source rendering for three styled scenes, both output crops and the left edge. The retained writer resolves the grade once before cropping; the experiment that graded both full-source crops independently was not retained.
- `--verify-styled-recording --verify-throughput`: ten-second paired-file and preview check. `--verify-efficiency` extends it to 60 seconds and logs thermal state. Inspect actual frame counts and duration; valid files alone do not demonstrate a sustained requested frame rate.

Use an optimized **Release** build on the user's phone for final review. For optimized diagnostic builds only, use Release with `SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG`; install a clean Release without that override afterwards. Debug-build timing is not representative of shipped performance.

Thermal stress testing exposed reduced throughput on a phone already in the serious thermal state. Do not describe this as zero heat, zero dropped frames, or guaranteed 30 fps across hardware. Output dimensions, codec, bitrate and requested rate are preserved. Final UI checks: first-launch/replayed fifteen-page tour, Reduce Motion/large text, three custom shortcuts, focus-strip/LUT/A–B overlap, Photo/Rangefinder manual AUTO versus bracketing, persistent original/edited sharing, paired Live Photo playback in Photos, and depth edge quality.

## 1.2.1 implementation notes

`InteractivePhotoPreview` caches the source image and draws only when adjustments change; full-resolution encoding stays in the explicit save path. Keep editing off the camera session. `LookLibraryManagement` persists visibility/order/trash and bounded undo snapshots; archive deleted custom recipes so old edits remain reproducible.

Do not probe recording codecs from Photo/Rangefinder mode: changing the active video format can silently disable depth delivery. Configure depth-compatible formats before capture and preserve the restored camera configuration on foreground resume. Shared CameraCaptureIntent membership belongs to the app, WidgetKit control and secure capture extension; the extension must handle hardware capture events. Test actual Lock Screen routing on hardware, not solely build metadata.

Use native NV12 output for 8-bit styled recordings and preserve explicit transfer/matrix attachments. The color diagnostic compares mean linear RGB error, not an sRGB-encoded error statistic. Keep the longer efficiency test and inspect both frame counts and thermal state; successful file creation alone does not prove smooth sustained recording. See VALIDATION.md for measured results and COMPETITOR_REVIEW.md for remaining product priorities.

## 1.2.2 photo lab and capture buffers

PhotoEdit uses optional crop/straighten/export/depth fields so older recipes decode unchanged. PhotoGeometry shares crop transforms between the GPU preview and final export, trims rotation corners and snaps crop boundaries to integer pixels to avoid transparent JPEG fringes. Export resizing uses clamped Lanczos sampling and never upscales. Keep the preview above the scrollable controls.

New depth captures store an oriented, normalized float32 mask in depth-mask.json. The main library records its relative path; deleting a capture deletes the mask too. Save a private full source when a depth capture requested only a framed export. Existing images without a mask keep their prior editor behavior; never synthesize depth or advertise Apple editable Portrait assets.

Analysis output explicitly opts out of automatic/preview buffer dimensions before supplying exact dimensions, and requests native 8-bit 4:2:0 where supported. Use even-pixel multiples of the source’s reduced aspect ratio so stricter camera implementations accept the size request. For Dual Shot, size the short edge to at least 1920 pixels so the landscape crop keeps 1080p detail. Do not shrink to a 1920-pixel long edge; that would require upscaling the landscape output. Retain the existing scaling-crash fallback.

`--verify-editor-preview` includes PhotoLabVerification: crop/rotation/position cases, empty-corner detection, output sizes, no upscaling, legacy recipes and lossless depth-mask roundtrip. `--show-photo-editor --expand-editor` previews the real editor with isolated sample files. These routes are Debug-only.

## 1.2.3 gallery lifecycle and adaptive HDR

Keep CaptureButtonModifier structurally stable when review state changes. Its handler checks whether capture is allowed; conditionally replacing its wrapped view recreated the preview while the session was stopping. Gallery review uses the sheet's onDismiss to clear review state and flush stale display queues, rather than a nested navigation page's onDisappear. Native mirroring reads connection-port metadata, not the live session's input collection on the UI thread.

Do not stop/restart the capture session just for gallery presentation: stress testing exposed an intermittent stopped-camera/UI stall in that cycle. Keep the session warm, suppress custom preview/scopes while covered, and resume the same display layers on dismissal. Normal app-background stopping is retained. During recording, encoded outputs and tracking continue while hidden preview/scopes are suppressed.

GalleryThumbnails bounds photo/video decoding to two background jobs and caches up to 24 MiB of decoded thumbnails. Photo thumbnails use ImageIO URL sources; video generator work is cancellable. Detail viewing requests HDR decoding separately, and duplicate full/frame URLs are decoded once. Bulk deletion updates the collection/index once and removes files off the main thread only after the index saves and previously enqueued Photos imports finish. Failed index saves restore the items and leave files intact.

HDRPhoto expands compatible HDR originals, applies the same recipe/crop/resize to SDR and HDR images, and writes a new adaptive JPEG gain map. Never copy an old gain map onto a newly edited image. Preserve HDR highlights is optional; the live editor preview remains SDR. RAW and already-flattened SDR sources are not promoted to HDR. The viewer requests HDR decoding and high dynamic range on supported displays.

Debug checks: --verify-gallery exercises quick/long dismissals in Photo and Dual Shot, preview mount count, fresh-frame recovery, main-actor heartbeat, selected/all deletion and failed-index rollback using isolated files. --verify-editor-preview also checks actual HDR pixel values, crop size, the SDR opt-out and HDR-aware viewer decoding. --show-gallery --select-gallery previews selection controls without user media.

## 1.2.4 recording pipeline

MovieRenderResources owns one lazily created Metal queue/Core Image context for the camera session. Preview and recordings reuse compiled GPU programs instead of creating a cold context at every Record. LiveMovieWriter keeps at most two GPU frames in flight; it retains each camera sample, resolved pixel buffer and output samples until dependent work completes. A completion barrier returns to the serial writer queue before appending both outputs. Stop waits for admitted GPU frames before finishing either file. The non-Metal/synchronous fallback remains.

The capture-to-writer bridge uses a two-sample bounded FIFO and user-initiated queues to absorb short scheduling spikes, clearing stale samples across stream boundaries. Scopes and loupe rendering have bounded utility work off the camera delivery queue. RGB scope buffers are pooled, and scope readbacks use a separate low-priority context. Scope callbacks hop to MainActor once.

Date stamps cache the formatter and a bounded set of rendered sizes instead of rebuilding the label when preview and recording sizes alternate. Storage polling only publishes changed values. Finishing a writer returns preview rendering to the live camera immediately rather than waiting for file finalization.

The grading functions, spatial effects, output dimensions, codecs and bitrate remain unchanged. Direct per-crop grading and cached color-cube approximations were tested and rejected for performance or fidelity reasons. RenderOrderVerification compares the retained grade/crop path across three looks, LUT/intensity blends, date stamps and both crop edges at the existing 8-bit resolve precision. Flatten alpha before difference-blend comparisons: Porter-Duff compositing otherwise reports a false error on identical partially transparent edges.

Use --verify-render-order for image comparisons; --verify-efficiency --long-soak records three minutes and reports sorted-PTS cadence and five-second frame counts as well as thermal state. Diagnostic arguments and timing arrays are Debug-only. Ship a normal Release build after testing.

Dual Shot orientation invariant: analysis frames are portrait (connection angle 90); never apply deviceAngle/lastAngle a second time to idle dual crops or the analysis-backed live writer. Front analysis is mirrored once. The fallback writer connection is also portrait and uses exact native-aspect even dimensions. Device-angle rotation is retained for single-output captures. `--verify-styled-recording --rotate-dual` exercises four starts and finalization cycles without saving to Photos. Keep the two-frame GPU limit and cacheIntermediates=false; caching/deeper-queue trials did not establish a sustained-rate benefit.

## 1.2.7 lossless grading intermediate

LiveMovieWriter requests lossless BGRA for its full-resolution resolved grade; source capture, style math, dimensions, LUTs, spatial effects, final NV12 outputs and encoding are unchanged. CameraFrameRenderer verifies the first compressed render before publishing it. Pool creation/allocation or render failure retries the same graph using ordinary BGRA, then keeps that fallback for the renderer. Other renderer owners retain uncompressed defaults. No changes to the warm-session gallery path or portrait Dual Shot orientation.

`--verify-render-order` compares actual compressed and uncompressed buffers across all built-in looks, extreme exposures, LUT/strength/stamp variants, both crops and edges. It asserts exact equality, checks injected unsupported-format allocation and resize fallback, then runs a 64-render alternating benchmark with the first eight excluded. Instrumentation and injection are DEBUG-only.

## 1.2.8 single video cadence

Full-frame Standard single recordings use the native movie output. A small analysis stream is prepared for scopes during recording and removed at stop when unused. Grading, a baked desqueeze or a custom crop still uses the live GPU writer. For a full-frame single clip with identical recording and monitor grades, the viewfinder shares the already graded frame. Portrait frames need no extra render; other angles use only an orientation pass. Preview-only LUTs, comparison, custom framing and changed monitor grades keep their independent preview. Match results are cached per writer and monitor revision, so large LUTs are not compared every frame. Native bi-planar input is preferred when offered without changing the source bit depth.

Apply and verify actual min/max frame durations when reusing the same camera format across FPS changes. Update in an order that keeps min <= max. The codec discovery fast path also checks actual resolution before reusing a format. `--verify-single-recording` runs short 4K VHS and Standard 60→30 HEVC clips with high bitrate, reports actual cadence, and checks HIST during Standard recording. Add `--verify-native-only` for just the Standard pair. Test movies are intercepted and removed without saving to Photos. The test stops starting new clips at serious/critical thermal state.

## 1.3.2 camera maintenance and companion handoff

Photo submission rechecks the output maximum against the active lens format and bounds per-shot quality to the output limit. Keep the small Objective-C exception boundary around AVCapturePhotoOutput submission: invalid-argument exceptions cannot be caught by Swift, and rejected requests must release their delegate and finish their pending photo context. Do not convert a rejection into a successful saved capture.

`--verify-preset-capture` tests saved photo presets, photo/RAW/depth/Live/natural setups and all lens stops, without saving test images to Photos. `--use-preset-fixtures` additionally reads and immediately deletes a temporary Documents/preset-regression-fixtures.json; never commit user preset fixtures. The report is Documents/preset-capture-verification.json. `--verify-reel-geometry` checks shared 9:16 preview/export math and persistence. `--verify-reel-export` creates private synthetic movies to check both portrait/landscape fallback export and the actual graded live writer; it does not activate a camera or publish to Photos.

Stillarc Studio remains at the verified 0.5.0 LUT-import release. Resume its accepted next sequence after this camera fix: explicit camera Log conversion, then LUT stacking, then compatible LUT export. Studio is a separate project at ../StillarcStudio and must not be bundled into the Camera changes.

## 1.3.3 — leaving Log for a photo preset

Non-video modes and photo presets normalize Log to Standard, including legacy preset metadata. Preset matching ignores video-only Log on photo/rangefinder setups. On the capture queue, setPreview detects the video-to-photo transition, restores .photo and sRGB on the existing input connection, and synchronizes photo dimensions; repeated photo updates do not reconfigure the session. `--verify-log-photo-preset` exercises actual supported Log hardware, legacy Log/Log 2 metadata, physical focus-lens selection and shutter delivery without publishing photos. Unsupported hardware profiles are explicitly marked in its Documents/log-photo-preset-verification.json report.

Storage destinations are snapshotted per shutter press/recording. Photos-save tasks return success. Photos-only captures remain indexed/protected until import succeeds; failed or interrupted saves retain a persisted recovery flag. Automatic cleanup uses capture age, skips recovery/editing items and waits until gallery review ends. It reuses atomic index-first deletion and the Photos-save barrier, with background file removal. Never delete Photos assets for this preference. `--verify-capture-storage` uses private fixtures and mocked Photos results, not the real library.

Develop uses one explicit extended-sRGB working space for its camera-calibrated look operations in both preview and save. Brightness crosses to linear light, and HDR previews render to an EDR float surface. RAW preview pixels are cached once in a 1600-pixel float image; do not insert an SDR JPEG between RAW decode and preview adjustments. The larger preview uses 56% of available height, capped at 480 points. `--verify-editor-preview` now includes camera-look swatches, export matching, HDR and a 1600-pixel bounded interaction sweep; reports distinguish render completion from display latency.


## 1.3.4 — approved identity refresh

The flat graphite aperture and rounded yellow S replace the prior luminous multi-ring artwork in all Home Screen variants, the tour BrandIcon, marketing headers and Desktop master PNGs. scripts/render-icon.swift derives app/brand/tinted assets from Marketing/Icons masters. The production bundle identifiers, capture pipeline and settings remain unchanged. Version/build are synchronized across Camera and its embedded extensions.


## 1.3.5 — S/lens identity

Approved large yellow S, silver split lens ring and small red A replace the aperture identity across light/dark/tinted app assets, tour branding, marketing headers and Desktop PNGs. The light master preserves geometry with a graphite ring. The A is static artwork. Bundle identities, capture behavior and settings are preserved.


## 1.3.6 — final icon proportions

One approved dark master serves default/light and dark appearances. The S has more clearance from the lens ring and the red A is dot-like at small sizes. BrandIcon, marketing and Desktop copies match. Capture behavior, preferences and installation identity remain unchanged.
