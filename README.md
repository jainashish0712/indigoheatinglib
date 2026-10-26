# IndigoThermalFix

**IndigoThermalFix** is a lightweight, non-invasive runtime tweak (`.dylib`) designed to fix severe overheating on iPhone 16 Pro (`iPhone17,1` / `iPhone17,2`) and ProMotion devices running Adobe Bonsai ("Indigo") Camera App.

---

## The Problem

In Adobe Bonsai (`com.adobelabs.bonsai`), [`MetalView.swift`](file:///D:/apps/indigo/com.adobelabs.bonsai-1.1.3-eeveedecrypter/Payload/Indigo.app/Indigo) configures its underlying `MTKView` with:
- `isPaused = false`
- `enableSetNeedsDisplay = false`

However, **it completely omits `preferredFramesPerSecond` and `preferredFrameRateRange`**.

On 120Hz ProMotion displays (iPhone 13 Pro – iPhone 16 Pro), Apple's `MTKView` defaults its internal `CADisplayLink` to run at full **120 FPS**. Combined with continuous Zero Shutter Lag (`ZSL`) raw Bayer compute streaming (`updateZslFrameRgbaFromRaw`), the GPU and memory bus are driven at maximum power while merely idling on the viewfinder, triggering `ThermalWarningView` and heavy thermal throttling within 60–90 seconds.

---

## How IndigoThermalFix Solves It (Phase 1)

This tweak injects into the process and uses Objective-C runtime swizzling on `MTKView`:
1. **Hooks Key Invocations**:
   - `-[MTKView setDelegate:]`
   - `-[MTKView setPaused:]`
   - `-[MTKView initWithFrame:device:]` & `-[MTKView init]`
   - `-[MTKView didMoveToWindow]`
   - `-[MTKView setPreferredFramesPerSecond:]` & `-[MTKView setPreferredFrameRateRange:]`
2. **Enforces Viewfinder Frame Rate Cap**:
   - Sets `view.preferredFramesPerSecond = 30` (or custom value).
   - Configures `view.preferredFrameRateRange = CAFrameRateRangeMake(30, 30, 30)` on iOS 15+ ProMotion displays.
   - Configures backing `view.layer.preferredFrameRateRange` on `CAMetalLayer`.
   - Clamps any attempt by external code to exceed the target frame rate.
3. **Zero Invasive App Changes**:
   - The application binary is not modified.
   - The tweak runs on both jailed (sideloaded / TrollStore) and jailbroken devices.

---

## Download via GitHub Actions / Releases

The GitHub Actions workflow (`.github/workflows/build.yml`) builds and signs `IndigoThermalFix.dylib` on macOS runners:
- **GitHub Releases**: Grab the latest compiled `IndigoThermalFix.dylib` directly from the [Releases](../../releases) tab.
- **Workflow Artifacts**: Every commit and manual workflow run produces an artifact under the Actions run summary.

---

## Injection Instructions

You can inject `IndigoThermalFix.dylib` into `Indigo.app` using any standard iOS injection tool:

### Method A: Using `insert_dylib`
```bash
# 1. Unzip the decrypted IPA
unzip com.adobelabs.bonsai-1.1.3-eeveedecrypter.ipa -d Unpacked

# 2. Copy the dylib into Frameworks
mkdir -p Unpacked/Payload/Indigo.app/Frameworks
cp IndigoThermalFix.dylib Unpacked/Payload/Indigo.app/Frameworks/

# 3. Insert LC_LOAD_DYLIB command
insert_dylib --all-yes @rpath/IndigoThermalFix.dylib Unpacked/Payload/Indigo.app/Indigo Unpacked/Payload/Indigo.app/Indigo

# 4. Re-pack IPA
cd Unpacked && zip -qr ../Indigo_Fixed.ipa Payload
```

### Method B: Using `Azule`
```bash
azule -i com.adobelabs.bonsai-1.1.3-eeveedecrypter.ipa -o Indigo_Fixed.ipa -f IndigoThermalFix.dylib
```

### Method C: Sideloadly / TrollStore / Esign
1. Open Sideloadly or Esign.
2. Select `com.adobelabs.bonsai-1.1.3-eeveedecrypter.ipa`.
3. In Advanced / Tweak Injection settings, add `IndigoThermalFix.dylib`.
4. Install and launch on device.

---

## Verifying the Fix

Connect the iPhone and check logs via Console.app or `idevicesyslog`:

```bash
idevicesyslog | grep IndigoThermalFix
```

Expected log output:
```text
[IndigoThermalFix] Initialized in process <PID> (com.adobelabs.bonsai)
[IndigoThermalFix] Configured target viewfinder frame rate: 30 FPS
[IndigoThermalFix] Successfully hooked MTKView methods. Viewfinder frame rate capped at 30 FPS.
[IndigoThermalFix] Set preferredFramesPerSecond = 30 on MTKView 0x...
[IndigoThermalFix] Set MTKView.preferredFrameRateRange = (min: 30.0, max: 30.0, pref: 30.0) on 0x...
```

### Customizing Target FPS
If you want to test 60 FPS instead of 30 FPS without recompiling, run via device terminal / SSH / defaults:
```bash
defaults write com.adobelabs.bonsai IndigoTargetFPS -int 60
```
