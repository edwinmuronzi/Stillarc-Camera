# 1.3.13 mode framing validation

Optimized diagnostic build and clean Release archive passed. The Release archive passed strict deep code-signature verification.

On iPhone 17 Pro all 30 actual-zoom assertions passed: Photo → Video → Photo → Rangefinder → Video → Rangefinder at each of 1×, 2×, 4×, 8× and 0.5×. Actual displayed hardware zoom matched both the engine target and selected zoom. The session remained running and its build counter stayed at one throughout. No test media was saved. The original shooting setup was restored by the diagnostic.

See mode-framing-verification.json. This verifies settled framing after each transition, not the absence of every transient frame during hardware reconfiguration. Manual handheld confirmation and other device models remain outside this pass.
