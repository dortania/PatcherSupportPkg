# Validation — 2 October 2026

The original [Discord report and minimal reproduction](https://discord.com/channels/417165963327176704/1554774647223091281) isolated argument-buffer pipeline failure on Radeon Pro 450. AMD direct/literal controls and Intel argument-buffer controls passed. The repair targets the legacy argument parser rather than replacing the graphics stack.

## Offline regression on the stripped adapter

We exercise AMDShared's actual constructor import and the vendor argument parser with captured, authored shader input. The [recorded results](validation.json) show:

- **Original newer input fails**: the parser wrapper is missing. This negative control prevents a no-op adapter from passing.
- **Repaired newer input passes**: exactly two `air.address_space, i32 2` pairs are removed. All remaining argument metadata matches, and the vendor parser constructs its wrapper.
- **Older compatible input passes both paths** with unchanged argument metadata.
- Only the constructor hook is defined as an export. No diagnostic switches, test interposition or logging are included.

The [payload checks](validation.json) compare against released stock AMDShared. Vendor compiler files and all original executable code/data sections match. The changes are the dependency load command, the added adapter and signature resources. This is a development-signed payload; final maintainer signing remains untested.

## Installed prototype on real hardware

**This evidence is for the earlier diagnostic prototype, not the newly stripped binary.** [Recorded binary hashes and results](validation.json) distinguish them.

- MacBookPro13,3, Radeon Pro 450 and Intel HD 530; macOS 15.8, build 24H23; OpenCore Legacy Patcher 2.5.1.
- **24/24 native cases passed**: AMD/Intel × literal/direct/argument × render-pipeline/compute-readback × first/warm repeat. Tests used the ordinary compiler service, with no debugger or compiler override.
- AMD argument-buffer compute readback returned **7.25**, matching the expected value. Installed component hashes stayed unchanged during testing.
- A passive service sample confirmed the installed adapter and original provider loaded together.
- The tester reported that **BIMx works again**. Application version, scene and duration were not recorded; this is a human report, not a complete application qualification.

## Observed issue and release gates

After reboot, the Dock was running but its bar was off-screen. Its sampled main thread was idle, with no compiler wait or new crash report. Restarting only Dock restored it while the prototype remained installed. We cannot exclude an installation-triggered regression. Repeat reboot, display and sleep/wake checks before release; keep the initial selector limited to the tested model/build.

- [ ] Repeat ordinary-service, native controls and BIMx tests with the exact stripped, maintainer-signed payload.
- [ ] Confirm Dock stability, sleep/wake and representative existing shader caches.
- [ ] Validate final signing, bundle seals and support-image packaging through maintainer CI.
- [ ] Publish that image, update OCLP's pinned support version, then run normal OCLP release validation.
