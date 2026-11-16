# 1.3.11 stabilization validation

The final optimized diagnostic build and normal Release archive compiled successfully. Strict deep code-signature verification passed for the normal Release archive. The signed 1.3.11 (28) release installed successfully on the iPhone 17 Pro; capture was left closed to allow cooling.

Investigation found newly attached GPU-writer outputs were not receiving the selected stabilization mode. Analysis/processed previews were excluded as well. The fix applies stabilization on the capture queue and resolves it again after format/output/lens changes. Native previews request the preview-optimized algorithm; recording Auto prefers low-latency, then cinematic and standard.

An exploratory enhanced-extended-cinematic pass confirmed active stabilization on all eight native and styled clips at 0.5×/1×/4×/8×, but that algorithm introduced substantial startup buffering and the styled 4K60 clip had a 168.3 ms steady timestamp gap. It was not retained as Auto. An intermediate Standard fallback had 33.3/66.7 ms maximum steady gaps at 1× for native/styled 30 fps and 18.3 ms at native 4K60. The device then reached serious thermal state. This fallback was replaced with Cinematic because stronger stabilization is the requested behavior.

The final policy passed the cooled iPhone 17 Pro run: all eight 4K30 native/graded clips at 0.5×, 1×, 4× and 8× had active Cinematic stabilization (mode 2) on their relevant video streams. All eight compressed files read successfully at the expected 4K dimensions. Maximum frame gaps after the first second were 33.3–35.0 ms. iOS thermal state remained nominal (0) across all eight snapshots. This bounded test does not establish sustained thermal behavior or measure battery consumption. See the retained JSON and filtered recording log.

Automated activation/cadence checks do not establish handheld walking quality, high-zoom stability, or parity with Apple Camera. Log and Dual Shot were not part of this cooled eight-clip run.

Run `--verify-single-recording --verify-stabilization` on a cool unlocked phone. Inspect Documents/stabilization-verification.json and all eight compressed-file/cadence log results. Then compare handheld 1×/4×/8× clips, panning and walking in daylight with Auto versus Off. Also check Log and Dual Shot, and confirm saved orientation/mirroring and Photos delivery.
