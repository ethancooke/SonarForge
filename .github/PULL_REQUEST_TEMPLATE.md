## Summary

What does this PR change and why?

## Related Issue / Chunk

Which DEVELOPMENT_PLAN.md chunk (e.g. 1.1) or issue does this address?

## Audio Path Checklist (required if this touches Audio/ or DSP/)

- [ ] No allocations, locks, or ObjC messaging on the real-time render thread.
- [ ] Parameter updates use lock-free / double-buffered / atomic mechanisms.
- [ ] Bypass behavior verified (no audible difference vs. passthrough).
- [ ] Device / sample-rate change handling considered.
- [ ] Threading model and measured CPU impact noted below (per DEVELOPMENT_PLAN prioritization rules).

**Threading / CPU notes:**

## Testing

- [ ] Builds cleanly for macOS 14.2+ arm64.
- [ ] Unit tests pass.
- [ ] Manual validation performed (describe):

## Docs

- [ ] STATE.md updated if this completes or advances a chunk.
- [ ] Other docs (ARCHITECTURE.md, DECISIONS.md, etc.) kept in sync where relevant.
