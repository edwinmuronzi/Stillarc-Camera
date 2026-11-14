# Stillarc Camera

<img src="Marketing/Icons/Stillarc-Light.png" width="90" alt="Stillarc light icon"> <img src="Marketing/Icons/Stillarc-Dark.png" width="90" alt="Stillarc dark icon">

**Your vision. Beautifully framed.**

A creative camera for iPhone: natural photography, expressive video, and a rangefinder way of seeing. StillarcCamera brings live looks, manual controls, exposure aids and two-format recording into one considered interface.

[Download the Xcode project](https://github.com/edwinmuronzi/Stillarc-Camera/archive/refs/heads/main.zip) · [Marketing images](Marketing/AppStore) · [Releases](https://github.com/edwinmuronzi/Stillarc-Camera/releases) · [Report an issue](https://github.com/edwinmuronzi/Stillarc-Camera/issues)

<p align="center">
  <img src="Marketing/AppStore/01-your-pocket-camera-studio.png" width="31%" alt="StillarcCamera rangefinder camera interface over a cinematic coastal scene">
  <img src="Marketing/AppStore/04-dual-shot.png" width="31%" alt="Dual Shot landscape and vertical video previews">
  <img src="Marketing/AppStore/07-manual-control.png" width="31%" alt="Manual exposure, ISO, shutter, white balance and focus controls">
</p>

## Download and install on iPhone

**Current availability: source installation with a Mac and Xcode.** There is no public App Store or TestFlight installation link yet. The project currently uses a free Apple Personal Team. A source ZIP is not an iPhone installer, and an unsigned IPA cannot be installed just by opening it in Safari.

### Install with your free Apple Account

1. Use a Mac capable of running **Xcode 27.2 or newer**. Install Xcode from Apple and open it once to finish installing its components.
2. [Download this project](https://github.com/edwinmuronzi/Stillarc-Camera/archive/refs/heads/main.zip) and unzip it, or clone it:
   ```sh
   git clone https://github.com/edwinmuronzi/Stillarc-Camera.git
   ```
3. Open **StillarcCamera.xcodeproj** in Xcode. Select the **StillarcCamera** scheme.
4. In **Xcode → Settings → Accounts**, add your own Apple Account. Keep your credentials private.
5. Select the **StillarcCamera** target, open **Signing & Capabilities**, enable automatic signing, and select **your Personal Team**. Change the bundle identifier to a unique value you control, for example `com.yourname.StillarcCamera`. Select your team for **LockCapture** and **CameraControlWidget** too; give those targets matching prefixes and unique suffixes, such as `com.yourname.StillarcCamera.LockCapture` and `com.yourname.StillarcCamera.CameraControlWidget`.
6. Connect your iPhone, unlock it, and trust the Mac if asked. The phone must run **iOS 26 or newer**.
7. Select the phone as the run destination and press **Run (⌘R)**. If iOS asks, enable **Developer Mode** under Settings → Privacy & Security, restart, and confirm. Follow any developer-trust prompt shown by iOS.
8. Open StillarcCamera, explore or skip the feature tour, then allow camera access. Microphone access is needed for sound in videos; Photos access is needed to save into your library.

Personal Team signing expires periodically. If the development app stops opening, connect the phone and run it from Xcode again. This method needs a Mac; there is currently no supported phone-only public install.

### Public beta and App Store release

Public distribution is the next publishing step, **not currently enabled**. The owner needs Apple Developer Program membership, App Store Connect access, distribution signing, a processed uploaded build and the applicable Apple review. External TestFlight testing also needs a tester group and a public invitation link.

When available, this section will contain the real TestFlight/App Store link. See [Apple’s distribution guide](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases/) and [external TestFlight instructions](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers).

## New in 1.2

### Photo capture: choose the result you want

Open **Fn → Shooting tools → Photo capture**. The available combinations depend on the active lens and camera configuration.

- **Standard:** the quickest everyday HEIF/JPEG path, with optional RAW and looks.
- **Natural RAW:** develops a single native Bayer RAW with sharpening, noise reduction and local tone mapping turned down, retaining the DNG. This gives you more control over texture. It can be grainier, and bright skies or dark scenes may be harder to recover. It uses a supported physical rear camera; it is not ProRAW-based HEIF+ and does not claim to reproduce another app’s proprietary processing. The live preview is a framing/color preview, not an exact preview of the later RAW development.
- **Live Photo:** keeps a short moment of movement with the still and saves one paired Live Photo to Photos. It preserves the original full frame and metadata; baked looks/LUTs and framing crops are excluded. In-app sharing of the motion component sends a separate movie. Microphone availability and permissions affect sound.
- **Depth portrait:** uses a supported camera’s distance map to soften the background while preserving the original. It is a rendered image, not Apple’s editable Portrait mode. Hair, glass and complex edges can be imperfect. An unsupported lens retains the original and explains what happened.

- **Keep HDR highlights:** preserves camera-delivered HDR when cropping or baking a photo look, including compatible rendered portrait copies. A RAW DNG can accompany the processed photo when the camera supports the pairing.
- **Depth companions:** Live Photo can keep depth and HDR together on supported camera setups. The motion pair uses the original still. Switch Depth and Live Photo off to keep a RAW DNG with a processed HDR still.

The format pill identifies Natural RAW, Live Photo or Depth when active. Supported RAW, Live and depth combinations depend on the actual lens, format and capture session. For the fastest repeated stills, use Standard HEIF with these extras off.

### Film texture in photos

Use the Quality dial to change grain. The photo grain is strongest in midtones and tapers toward black and white. With Glow enabled, **35mm Night** adds a warm rim around bright light sources.

### Focus pulls without leaving the viewfinder

A **focus pull** moves sharpness from one subject to another while filming—for example, from a cup in front to a person behind it.

1. In **Video**, tap the focus-target icon beside the eye button under HIST, or choose **Fn → Shooting tools → Focus pulls → Set A and B in the viewfinder**.
2. Tap the first subject to save **A**, then the second to save **B**. The app waits for autofocus to settle without changing exposure.
3. Tap A or B to move smoothly to that distance. Choose the time from the duration control, or move the slider for manual control.
4. Set marks before recording. The setup uses a fixed physical rear lens; unsupported lenses explain the limitation. Close the strip to return to autofocus.

A/B marks remember focus distances. They do **not** track a person who moves closer or farther away. Focus peaking and magnification can help you check the result.

### A gallery you can return to

With Save captures in app enabled, captures, original files and edit recipes stay in the app after closing it, subject to the cleanup policy. Open a photo and choose **Develop photo** to change the look, brightness, color strength or warmth. The full-resolution original is retained; edits are separate. The larger preview stays visible above the scrolling controls. Preview and save share the same look working space, with HDR display on supported screens. When a full-frame original and RAW are available, enable **Develop from RAW** to work from the digital negative. A bounded floating-point preview keeps editing responsive without first clipping highlights into a JPEG; saving uses the full RAW. Frame-only captures can still be edited from their original crop and their DNG shared separately. Reopen Develop photo to revise the saved recipe, or switch to Original in the viewer. Sharing sends the displayed version at its saved size. Saving an edit does not silently overwrite the copy already in Photos.

The gallery is local to this installation, not an online backup. Deleting a capture removes its app files; copies already saved to Photos remain there. Locked-screen captures transfer after unlocking and follow the same app/Photos destination settings.

### Choose where captures stay

Open **Settings → Files**:

- **Save captures in app:** keep originals, edits and video companions in the local gallery. Turning it off applies to new captures; their app copies are removed only after saving to Photos succeeds. Existing gallery items remain until you delete them or a cleanup policy applies.
- **Save to Photos:** independently save your finished output to Apple Photos. At least one destination stays enabled.
- **Automatically delete app copies:** Never (default), after 1 day, 7 days or 30 days, measured from capture time. The policy applies to existing and future app copies and runs when you open/return to the app or finish browsing the gallery. It waits while browsing/editing and never deletes Apple Photos assets.

If a Photos save fails or cannot be confirmed, a protected recovery copy stays in the app instead of being automatically removed. Manually export or delete it from the gallery. Cleanup does not run as an exact background alarm. Defaults preserve the existing gallery: in-app saving on, automatic deletion Never.

### Frame, straighten and adjust depth

In **Develop photo**, open **Frame & export**:

- **Crop:** keep the original shape, or choose Square, 4:5, 3:2 or 16:9. Move left/right or up/down to position the crop where the new shape leaves room.
- **Straighten:** level a tilted horizon by up to 10°. The edges trim automatically so empty corners do not appear.
- **Saved size:** keep full resolution or choose a longest edge of 3840, 2048 or 1080 pixels. Smaller copies are easier to send. The app never enlarges a smaller original.
- **Background blur:** on new depth captures, soften the background or slide to zero to keep the original sharpness.
- **Subject separation:** choose how much of the scene stays sharp. Check hair, transparent objects and complex edges before sharing.

New depth captures retain a lossless floating-point depth mask beside the original, so these adjustments survive closing the app. Older photos without a retained mask cannot gain real depth information retroactively. Exported portraits are ordinary edited images, not Apple Portrait assets with editable depth in Photos. A full source is kept privately for new depth shots even when only a framed Photos export was requested. Crop, straightening, depth and size edits do not alter the original or overwrite its existing Photos copy. For compatible HDR originals, **Preserve HDR highlights** saves an adaptive JPEG: compatible displays can show brighter skies and lights, while other viewers show a standard-brightness version. Turn it off for SDR-only sharing. The live editor preview is SDR; strong looks can reduce highlight brightness. RAW edits and older frame-only crops without retained HDR information cannot acquire HDR retroactively. Keep a Full/Both original when HDR matters.

### Select and delete gallery items

Tap **Select** in Gallery and choose your photos and videos. Use **Share** to send the selection together, including both videos from a Dual Shot take, or **Delete (count)** to remove the selection. **Select all / Deselect all** helps with larger batches. Tap **Done** to return to browsing, or **Close** to resume the camera.

**Delete all** clears the app gallery after confirmation. These actions remove the app’s originals, edits, RAW files, depth masks and video companions for the selected items. Copies already saved in Apple Photos remain there. This is separate from the style manager’s Restore Deleted feature: deleted gallery media has no in-app undo.

The gallery loads small cached thumbnails with bounded background decoding. Custom-preview and scope processing pauses while you browse; the camera stays warm rather than stopping and restarting during the sheet transition. Returning flushes stale display queues and keeps the existing viewfinder. Bulk deletion updates the index once, waits for any already-enqueued Photos import, then removes files off the main thread. If the index cannot be saved, the items and files are kept.

### Manage styles and presets

Open **Look Studio → Manage**, or **Fn → Shooting tools → Manage styles & presets**.

- **Add style:** copy a built-in style, start from scratch or try random settings. Tap a custom style to edit it.
- **Remove:** swipe a style or shooting preset away. Built-in styles are hidden from the picker, so they can be restored; Standard stays available.
- **Rearrange:** tap Edit and drag the handles. The camera’s style picker follows that order.
- **Shooting presets:** add the current camera setup, rename a saved setup or tap Use to load it.
- **Undo:** restores the previous library state, with up to eight saved changes retained across launches.
- **Restore deleted:** brings removed built-in/custom styles and shooting presets back.
- **Reset styles and presets:** restores the default built-ins and clears custom styles/presets after confirmation. It does not delete photos or videos; Undo can recover the previous library.

The photo editor caches a decoded preview and renders slider changes directly with Metal/Core Image. It no longer waits for you to stop sliding or encodes a JPEG for each preview. Saving still develops the original at full resolution. Expensive custom-preview processing pauses while the gallery is open; recording continues if you review while rolling. The capture session stays warm for a reliable return, and still stops normally when the app backgrounds.

### Your shortcuts, within reach

Use **Fn → Shooting tools → Viewfinder shortcuts** to choose the three buttons above the zoom ruler. Available choices include countdown, timelapse, magnifier, histogram, looks, manual controls, gallery and focus pulls. Picking a duplicate swaps its old position so the row stays clean. Use the **Photo & Rangefinder bottom row** section to arrange its five controls or leave positions empty. Each row has a reset.

### Lock Screen camera

Long-press your Lock Screen, choose **Customize**, replace a bottom control and select **Stillarc camera**. You can also add its control in Control Center. The locked camera is a separate, simple photo experience: it cannot browse your gallery or expose previous images. Tap its open-app button to authenticate and open the full app. After unlocking, new photos are imported into StillarcCamera’s gallery. Camera permission must be granted; the system controls authentication and extension availability. After updating an existing control, remove and add Stillarc camera again if iOS has cached the old registration. The capture extension includes the shared camera intent and hardware-capture event handler required by the system lifecycle. When the phone is already unlocked, the intent explicitly opens the camera in the main app.

### Plain-English camera guide

**Fn → Shooting tools → Camera guide** explains the tools without assuming camera knowledge. For quick reference:

| Control | What it does |
| --- | --- |
| EV / brightness | Makes automatic exposure lighter or darker. |
| ISO | Raises sensitivity to brighten the image, often adding noise. |
| Shutter | Changes how long each frame gathers light; slower speeds blur motion. |
| White balance | Keeps whites neutral or deliberately warmer/cooler. |
| Focus / A–B pull | Chooses which distance appears sharp. |
| LUT / Bake | A saved color transformation; Bake writes it into the output. |
| Histogram / waveform | Shows the distribution or position of brightness, helping spot clipped highlights. |
| Zebra | Stripes areas above a brightness threshold. |
| Peaking | Outlines sharp edges to help judge focus. |
| False color | Replaces the scene’s colors with a brightness guide. |
| RAW | Sensor-oriented data with room for later development; larger and slower than ordinary photos. |
| Depth portrait | Softens the background using measured distance information. |

## Three ways to make an image

### Photo — natural detail, personal color

- HEIF and JPEG capture, with **HEIF Max** and **RAW** where the selected camera supports them.
- Repeated shutter presses use independent capture requests. Grading and thumbnail creation happen away from the interface, with bounded processing to protect memory.
- Automatic exposure when you want simplicity; manual controls when you need precision.
- Live camera styles, custom look recipes, and optional LUT baking.
- Full-frame, framed crop, or both; full-resolution files remain available while retained in the gallery.
- Countdown, exposure bracketing, still timelapse, grid, level and focus magnifier.

HEIF Max, RAW, flash, low-light processing and bracketing take longer than ordinary stills. Responsive/zero-shutter-lag capture is enabled only where supported; timing remains dependent on the camera, format and light. There is no claim of unlimited full-resolution burst capture.

### Video — motion with intention

- Resolution, frame rate, bitrate and codec choices discovered from the active camera.
- **Apple Log, Apple Log 2 and ProRes** on compatible devices, lenses and formats. Unsupported combinations are not universal features.
- Exposure, white balance, shutter angle and supported focus control.
- Live styles and enabled LUT baking while recording on the live grading path.
- RGB histogram/waveform and exposure/focus aids available while recording.
- Microphone selection, audio level/clipping indication and headphone monitoring.
- Torch control on supported cameras, including during recording.
- Clean recording controls, clip counters and running timecode.
- Loading a Photo/Rangefinder preset switches to that mode and automatically returns Log/Log 2 to Standard, ready for the shutter. Saved photo presets cannot reactivate video-only Log.
- **9:16 in ordinary Video:** choose 9:16 with the aspect control, then enable **Fn → Shooting tools → Safe zones & anamorphic → Show reel safe zones**. The clear cutout marks the safer area for faces/text; shaded areas leave room for captions and interface controls. Choose Reel captions or Center action. The saved movie uses the crop; the guide itself is never recorded. These guides are approximate, not platform-exact templates.

### Slow shutter — motion blur and light trails

Open **Fn → Shooting tools → Photo capture → Slow shutter**. Choose **Motion blur** to smooth moving water or crowds, or **Light trails** to turn moving lights into streaks. Pick 1, 2, 4 or 8 seconds, steady the phone and tap the shutter. Stillarc blends camera frames into a processed still up to 2048 pixels on the longest edge. Turn Slow shutter off to resume regular still capture.

### Rangefinder — see beyond the crop

Choose frame lines using the focal-length ruler while keeping the wider scene visible. Anticipate the next subject entering the composition, then save the full image, the framed crop, or both. These are digital framing/crop controls, not a promise of a different physical lens or optical focal length.

## Dual Shot: one take, two finished videos

Record **landscape 16:9 and vertical 9:16 simultaneously from one camera source**. A movable, resizable live landscape window sits inside the main reel viewfinder so you can judge both compositions.

- Two finished files: **1920×1080 landscape** and **1080×1920 vertical**. Dual Shot offers up to 30 fps. Actual cadence depends on the device, grade and temperature.
- A camera style is baked into the pair. A selected LUT is baked only when its bake control is enabled.
- No style and no baked LUT means a plain pair.
- Optional subject tracking moves the reel crop independently; the landscape framing stays centered.
- Optional shaded reel safe-zone cutouts help leave room for captions. Guides and tracking boxes do not appear in saved videos.
- Both outputs are committed together to Photos after successful finalization. Incomplete pairs are not deliberately published.

Dual Shot is two crops of one source, not two independently pointed cameras. It does not create four copies, and it does not deliver two 4K files. Available framing is limited by what the camera can see.

In **Gallery → Develop Photo**, open **Color mix** to shift the hue, intensity or brightness of a particular color range. For example, lower the intensity of reds without dulling the blues. Saved edits can be reopened and adjusted.

## Looks, LUTs and shooting presets

**Looks** are the camera’s visual recipes: color, tone, grain, softness, glow, vignette and other supported adjustments. Use **Fn → Looks / Look Studio** to explore built-in styles, make your own, and adjust the Quality and Tone dials.

**LUTs** are imported `.cube` color transforms. Use the **LUT** pill to select a transform and adjust its mix. Preview and baking are independent: seeing a LUT in the viewfinder does not, by itself, mean it will be written into a file. The LUT pill is yellow when baking is active and white otherwise. Hold/tap A/B to compare against the original preview.

**Shooting presets** remember a setup, including format, exposure, white balance, focus, lens/zoom, style/LUT, Dual Shot, framing and audio choices. Use **LUT → Save Preset** or **Fn → Shooting tools → Shooting presets**. The selected preset is yellow. Changing its setup clears the selection; automatic exposure/focus readings do not. Photo capture modes are included in saved presets. Apply presets between recordings. In **Manage**, use **Export presets** and **Import presets** to move your setups through Files. Custom looks and LUTs referenced by name need to be available on the destination device. Touch and hold a saved preset to copy its launch link, then use that link with the **Open URLs** action in Shortcuts to open Stillarc Camera with that setup.

### What saves

- Stills without a look/baked LUT save the plain output(s) you selected.
- With a look or baked LUT, the graded selected output(s) save to Photos; originals remain available when in-app saving is enabled and until its cleanup policy applies.
- Identical full-frame/crop outputs are not intentionally duplicated.
- RAW capture also preserves a separate DNG where supported.
- Dual Shot saves the final two-video pair described above.
- Retained gallery items and edit recipes persist between launches. Previews load from files as needed; recent in-memory previews are bounded. Share uses full-resolution files. App deletion removes its local gallery, so save important work to Photos or export it; this is not a cloud backup.

## Tools that stay out of the way

| Tool | Where / purpose |
| --- | --- |
| **M** | ISO, shutter, EV, white balance and supported focus; use auto where preferred |
| **HIST** | RGB exposure histogram, including during recording |
| **Eye** | Compact waveform, zebra, peaking and false-color switches; clean feed |
| **MAG** | Focus magnifier |
| **Fn → Shooting tools** | Presets, tracking, focus pulls, safe zones, anamorphic and audio |
| **Subject tracking** | Tap a subject in Dual Shot’s reel; autofocus can follow while AF is enabled |
| **Focus pulls** | Set two marks and a duration. Fixed-lens mode uses supported rear 1×/2× framing; turn it off to return to all-lens zoom |
| **Anamorphic desqueeze** | Preview correction, or explicitly saved correction for compatible video paths; requires the matching physical attachment for an anamorphic image |
| **Audio** | Select available microphone inputs; monitor through headphones/compatible output routes and watch clipping |
| **Preserve settings** | Restore the previous shooting setup and controls across launches |
| **Feature tour** | First-launch introduction; replay it from Settings |

Lens stops, stabilization, torch, RAW, Log, ProRes, manual focus and audio routes depend on the actual hardware. A focus pull cannot be promised on every virtual camera or lens. Anamorphic preview correction alone does not alter a saved file; raw Log paths without grading may remain preview-only.

## First launch and everyday use

The fifteen-page introduction showcases photography, video, Dual Shot, live looks, rangefinder composition, manual controls, exposure aids, shooting tools, Natural RAW, Slow Shutter, Live Photo, depth portrait, re-editable originals, viewfinder focus pulls and locked capture. It is skippable and replayable, uses frosted native glass, respects reduced-motion preferences for its transitions, and keeps the live camera off until you enter the camera.

- Tap the bare viewfinder to focus; hold to lock exposure/focus.
- Drag vertically to adjust exposure.
- Use the ruler and lens selector to reframe; supported unified rear cameras provide continuous zoom transitions.
- Use the eye panel or double-tap the viewfinder for a cleaner composition.
- Open the gallery thumbnail to compare available originals/crops/graded versions and share.

## Compatibility, performance and privacy

- **Deployment target: iOS 26.0+.** This release keeps one modern interface rather than a separate reduced iOS 16/iPhone X app.
- A phone that cannot run iOS 26 cannot install this build. Running iOS 26 also does not give older hardware newer sensors, lenses, RAW/Log/ProRes support or identical throughput.
- The current development toolchain is **Xcode 27.2**. The minimum OS is a build target, not a claim that every supported iPhone has been physically tested.
- Capture, Core Image grading and subject tracking run on the device. This build has no account system, subscription flow, analytics SDK or photo-upload service.
- Camera, microphone and Photos permissions are used for their corresponding capture/save functions. If you share through another app or use iCloud Photos, that service’s behavior is separate.
- Rendering resources are reused, photo processing is bounded, and motion/storage polling pauses in the background. The zoom ruler does not run a constant display-rate redraw while idle.
- Camera hardware, screen brightness, high resolution, tracking and grading still consume power and can warm the phone. There is no zero-heat, zero-drain or zero-lag guarantee.

The marketing scenes are **AI-generated illustrative photography**, not evidence that StillarcCamera captured those images. The interfaces shown are rendered from the app’s own views. Images in the Halide reference material are not redistributed as StillarcCamera assets.

## Marketing kit

The listing kit includes ten **1320×2868 iPhone** images and three **2064×2752 iPad** images. See the [marketing overview](Marketing/Overview.jpg), [onboarding preview](Marketing/Onboarding.jpg), [iPhone set](Marketing/AppStore), and [iPad set](Marketing/AppStore-iPad).

The set is designed for the iPhone App Store screenshot slot; confirm [Apple’s current screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/) and your actual supported devices before submission. It is a prepared marketing set, not an App Store approval or a published listing. See [the marketing notes](Marketing/README.md) for source, copy and regeneration details.

See [the current comparison with Halide, No Fusion, Moment Pro Camera II and mood.camera](COMPETITOR_REVIEW.md) for remaining priorities.

On compatible devices, the full-resolution grading buffer uses lossless compression, with an uncompressed fallback. The grading, source detail and saved-video encoding remain unchanged.

Full-frame Standard video uses native recording. A matching baked look can share its graded frames with the viewfinder instead of rendering the look twice. Heavy 4K looks may still miss 60 fps: use Standard for 4K60, or choose 4K30 when keeping the VHS look.

Recording reuses GPU resources and keeps processing queues bounded so work cannot build an unlimited preview delay. Scopes run separately from camera delivery, and both videos retain the selected grading, resolution and encoding quality. Heavy looks and longer recordings can still drop frames as the phone warms; sustained 30 fps is not guaranteed.

See [validation results and remaining device checks](VALIDATION.md) for the tested scope and sustained thermal limits.

## Build and development

Open `StillarcCamera.xcodeproj`, use scheme **StillarcCamera**, and build the **StillarcCamera** target. For everyday phone use, choose **Release** in Product → Scheme → Edit Scheme → Run → Build Configuration; Debug builds prioritize debugging over speed. Swift source is in `StillarcCamera/`. Photos and saves must be checked on real devices; simulator previews do not validate camera speed, lens transitions or thermal behavior.

```sh
xcodebuild -project StillarcCamera.xcodeproj \
  -scheme StillarcCamera -configuration Release \
  -destination 'generic/platform=iOS' build
```

Choose your signing team before using the device build command. See [DEVELOPMENT.md](DEVELOPMENT.md) for regression checks and the build/install/push workflow.

Found an issue? Include the iPhone model, iOS version, mode, format/frame rate, look/LUT state and exact steps in [an issue](https://github.com/edwinmuronzi/Stillarc-Camera/issues). Please do not attach private photos or credentials unless you intend to share them publicly.


The display name, Xcode project and GitHub repository use Stillarc Camera. The installed app retains its original bundle identifier and stored preference keys so an update keeps existing captures, presets and settings. New preset links use the stillarc scheme, and previously copied links remain supported.


### Camera identity · 1.3.4

The approved flat aperture and geometric S replace the previous illuminated multi-ring icon across light, dark and tinted Home Screen appearances, the in-app feature tour and marketing artwork. [Approved masters](Marketing/Icons) · [Generation details](Marketing/GenerationPrompts.json). The installed name remains **Stillarc**.


### Camera identity · 1.3.5

The latest approved icon uses a large yellow geometric S, a lens ring with top/bottom arc gaps, and a small recording-red A. Light, dark and tinted appearances, in-app branding and Desktop master files are synchronized. The A is a static recording-inspired brand accent. [Current artwork](Marketing/Icons).


### Final Camera identity · 1.3.6

The final approved artwork has a bold yellow S, more breathing room inside the split lens ring and a tiny recording-red A. Light and dark Home Screen appearances now share this one dark design. In-app branding, marketing and Desktop copies match; iOS custom tinting uses the matching monochrome derivative.


## Colour exchange with Stillarc Studio · 1.3.7

Look studio → **Share colour with Studio** prepares a 33³ display-sRGB creative `.cube` from current style colour and the enabled monitor LUT. Save/share it through Files or AirDrop and import it in Studio → Film. Studio can export a colour LUT back into Camera’s existing LUT importer. Start from a neutral style to avoid double grading. Spatial texture, grain/halation, camera exposure/focus, HDR interpretation and complete app presets are not transferred; the LUT is a sampled SDR colour approximation. Preparing it runs once on a worker, never during camera preview or recording.

## Lens and Log responsiveness · 1.3.8

Selecting another optical lens now exits the dedicated wide-camera Focus Lens mode automatically. Supported virtual-camera lens choices stay available during Log recording. Raw Log on a physical camera still locks that physical camera during the take; its supported digital crops remain available.

Log HEVC uses a bounded live capture queue and disables encoder frame reordering. The single monitor checks display readiness before rendering, limits its output-buffer pool, and no longer inserts a delay when valid Log recording buffers replace preview buffers. Selected recording resolution, bitrate and 10-bit Log data are retained. On iOS 27 the writer explicitly preserves the source Log transfer tag.

See [native checks and limits](Validation/1.3.8/README.md).

## 1.3.9 · native colour interchange

Look studio → Share colour with Studio now produces a `.stillarclook` package. Import it in Studio’s Film tools. Camera’s LUT importer also accepts Studio `.stillarclook` files, selects the portable display-sRGB colour and Standard style. Use Standard gamma for the shared colour. Studio’s spatial effects, source-specific edits and camera exposure/focus settings do not transfer. Camera captures/lens/Log processing are unchanged by this companion update. Ordinary `.cube` import remains supported.
