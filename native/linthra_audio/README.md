# linthra_audio (C++)

`linthra_audio` is Linthra's realtime DSP core. It gives C++/audio contributors a real part of the project to own while keeping the existing player stable until the mobile binding is ready.

## Current DSP

- fixed-size, allocation-free processing state
- mono/stereo float PCM
- preamp
- up to 8 parametric peaking-EQ bands
- stereo-linked peak limiter with immediate attack and smooth release
- transparent bypass when processing is disabled
- C ABI for a future Android/JNI or Dart FFI boundary
- 48 kHz stereo realtime regression benchmark

The processing callback does not allocate memory and does not take locks. Configuration computes coefficients outside the callback.

## Build and test

```bash
cmake -S native/linthra_audio -B build/linthra_audio -DCMAKE_BUILD_TYPE=Release
cmake --build build/linthra_audio --parallel
ctest --test-dir build/linthra_audio --output-on-failure
```

## Important boundary

This PR does not replace `just_audio` or silently alter playback. Linthra currently uses `just_audio`/the platform decoder pipeline, so inserting native PCM DSP safely requires a dedicated Android audio-processor binding. The C++ core is intentionally validated first; the binding can then be reviewed for audio focus, buffering, F-Droid reproducibility, and bypass correctness without also reviewing the DSP math.

## Good contribution areas

C++ contributors can work on response tests, limiter behaviour, SIMD implementations, filter types, channel-layout support, loudness/peak analysis, and the future Android audio-processor bridge without needing Flutter UI knowledge.
