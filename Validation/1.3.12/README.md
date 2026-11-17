# 1.3.12 device validation

Optimized diagnostic and clean Release builds passed; the Release archive passed strict deep code-signature verification.

On iPhone 17 Pro, all nine Photo/Rangefinder/Video snapshots retained a running session with a single session build throughout. Native and processed Photo/Rangefinder preview connections reported preview-optimized stabilization (mode 4). Photo proxy delivery was enabled for those modes and disabled for Video. Fresh source frames arrived in every measurement interval; initial startup delivered four analysis frames in its first two-second measurement, later photo intervals delivered 30–44 frames and video intervals delivered 45 frames. Do not describe this as a zero-delay startup or uniform preview frame rate. The longest main-actor heartbeat gap in this bounded mode-switch run was 47.1 ms. iOS thermal state was fair (1), not nominal, throughout.

Five plain and five 35mm Night HEIF captures all completed, requested 140 ms apart. Completion took 2.18 seconds plain and 4.36 seconds styled, including processing. No test photos were saved to Photos. Slow Shutter and Light Trails both produced 1536×2048 results, retaining the explicit accumulation stream rather than the stabilized photo proxy.

Native HEVC 4K60 and 4K30 recordings both read successfully. Maximum timestamp gaps after the first second were 18.3 ms and 33.3 ms; histogram access passed during both. Thermal state at the start of both clips was fair. Files were private diagnostics and removed afterwards.

These checks do not establish handheld stabilization quality, identical latency on older hardware, sustained thermal/battery behavior or freedom from every possible UI stall. The remaining user checks are cold opening with their imported LUTs, switching modes/styles repeatedly, handheld Photo/Rangefinder preview and normal saved captures. Log/Dual Shot were not re-stress-tested in this pass.
