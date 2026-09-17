import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:cullimingo/core/native/bundled_libs.dart';
import 'package:cullimingo/core/raw/preview_extractor.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter_libraw/flutter_libraw.dart';

/// Candidate locations for the native `libraw` dynamic library — the
/// Homebrew/system paths used in development (`brew install libraw`). A packaged
/// macOS app ships its own copy and is preferred over these (see §6.1 /
/// [bundledNativeLib]).
const List<String> _candidateLibPaths = [
  '/opt/homebrew/lib/libraw.dylib', // Apple Silicon Homebrew
  '/opt/homebrew/lib/libraw_r.dylib',
  '/usr/local/lib/libraw.dylib', // Intel Homebrew
  '/usr/lib/x86_64-linux-gnu/libraw.so', // Debian/Ubuntu
  '/usr/lib/libraw.so',
];

/// LibRaw image type for an embedded JPEG preview (`LibRaw_image_formats`).
const int _librawImageJpeg = 1;

/// LibRaw image type for a decoded RGB bitmap (`LibRaw_image_formats`).
const int _librawImageBitmap = 2;

/// Offset of the flexible `data[]` member in `libraw_processed_image_t`
/// (type:4 + 4×ushort:8 + data_size:4). Stable across the LibRaw ABI.
const int _processedDataOffset = 16;

/// Extracts the **embedded full-res JPEG preview** from a RAW file via LibRaw
/// (`BUILD_PLAN.md` §6.1), then downscales it for the grid. Runs the whole FFI
/// sequence on a one-off background isolate so the UI never blocks.
class LibRawPreviewExtractor implements PreviewExtractor {
  /// Creates the extractor. [libraryPath] overrides dylib discovery (tests).
  const LibRawPreviewExtractor({this.libraryPath});

  /// Explicit path to the libraw dynamic library, or null to auto-discover.
  final String? libraryPath;

  /// Resolves the libraw dylib path, or null if none is present. Prefers the
  /// copy bundled in the packaged app, falling back to Homebrew/system paths.
  static String? resolveLibraryPath() {
    final bundled = bundledNativeLib('libraw.');
    if (bundled != null) return bundled;
    for (final path in _candidateLibPaths) {
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  @override
  Future<Uint8List?> thumbnail(
    String path, {
    int longEdge = 512,
    CancelToken? cancel,
    JobPriority priority = JobPriority.visible,
  }) async {
    final lib = libraryPath ?? resolveLibraryPath();
    if (lib == null || !File(path).existsSync()) return null;
    return Isolate.run(() => _extract(lib, path));
  }

  static Uint8List? _extract(String libPath, String path) {
    final DynamicLibrary dylib;
    try {
      dylib = DynamicLibrary.open(libPath);
    } on Object {
      return null;
    }
    return extractRawThumbnail(FlutterLibRawBindings(dylib), path);
  }
}

/// Runs the LibRaw FFI sequence using already-loaded [lr] bindings and returns
/// the **raw embedded JPEG preview bytes** — no Dart decode/resize/re-encode
/// (the pure-Dart `image` codecs are slow). The native engine codec downsamples
/// it to display size via `cacheWidth` at paint time. Exposed so the preview
/// pool can load libraw **once per worker** and reuse it across thumbnails.
Uint8List? extractRawThumbnail(FlutterLibRawBindings lr, String path) {
  return extractRawPreview(lr, path)?.bytes;
}

/// An embedded JPEG plus the dimensions needed to judge whether it is useful.
class EmbeddedRawPreview {
  /// Creates embedded preview metadata owned by Dart.
  const EmbeddedRawPreview({
    required this.bytes,
    required this.width,
    required this.height,
    required this.rawWidth,
    required this.rawHeight,
  });

  /// Encoded JPEG bytes.
  final Uint8List bytes;

  /// Embedded JPEG width.
  final int width;

  /// Embedded JPEG height.
  final int height;

  /// RAW image width reported by LibRaw.
  final int rawWidth;

  /// RAW image height reported by LibRaw.
  final int rawHeight;

  /// Whether this preview is large enough for the requested cache tier.
  bool isLargeEnough(int longEdge) {
    final previewEdge = width > height ? width : height;
    if (longEdge > 0) return previewEdge >= longEdge;

    // Full-size embedded JPEGs can differ from the sensor dimensions by a
    // small crop (for example 6048 versus 6064 pixels). A 5% tolerance keeps
    // those on the fast path while rejecting tiny 160×120 thumbnails.
    final rawEdge = rawWidth > rawHeight ? rawWidth : rawHeight;
    return rawEdge <= 0 || previewEdge >= rawEdge * 0.95;
  }
}

/// Extracts an embedded JPEG and its dimensions from [path].
EmbeddedRawPreview? extractRawPreview(FlutterLibRawBindings lr, String path) {
  final handle = lr.libraw_init(0);
  if (handle == nullptr) return null;

  final pathC = path.toNativeUtf8();
  final errc = calloc<Int>();
  Pointer<libraw_processed_image_t> processed = nullptr;
  try {
    if (lr.libraw_open_file(handle, pathC.cast<Uint8>()) != 0) return null;
    if (lr.libraw_unpack_thumb(handle) != 0) return null;

    processed = lr.libraw_dcraw_make_mem_thumb(handle, errc);
    if (processed == nullptr || errc.value != 0) return null;

    final image = processed.ref;
    if (image.type != _librawImageJpeg || image.data_size <= 0) return null;

    final dataPtr = Pointer<Uint8>.fromAddress(
      processed.address + _processedDataOffset,
    );
    return EmbeddedRawPreview(
      bytes: Uint8List.fromList(dataPtr.asTypedList(image.data_size)),
      width: image.width,
      height: image.height,
      rawWidth: handle.ref.sizes.width,
      rawHeight: handle.ref.sizes.height,
    );
  } on Object {
    return null;
  } finally {
    if (processed != nullptr) lr.libraw_dcraw_clear_mem(processed);
    calloc.free(errc);
    malloc.free(pathC);
    lr.libraw_close(handle);
  }
}

/// An 8-bit RGB image rendered from a RAW sensor mosaic.
///
/// This is the deliberately slower fallback for RAW files without a usable
/// embedded JPEG preview (for example Nikon HLG/BT.2100 NEFs). The preview
/// pool immediately downsizes these pixels with libvips and caches the JPEG,
/// so the demosaic cost is paid only once per preview tier.
class DecodedRawBitmap {
  /// Creates decoded bitmap data owned by Dart.
  const DecodedRawBitmap({
    required this.pixels,
    required this.width,
    required this.height,
    required this.channels,
  });

  /// Interleaved 8-bit pixel bytes.
  final Uint8List pixels;

  /// Pixel width after LibRaw applies the camera orientation.
  final int width;

  /// Pixel height after LibRaw applies the camera orientation.
  final int height;

  /// Number of interleaved channels (currently required to be RGB).
  final int channels;
}

/// Fully decodes [path] through LibRaw and returns an 8-bit RGB bitmap.
///
/// [halfSize] uses LibRaw's half-resolution mode: still large enough for the
/// grid and screen-resolution loupe, but around one quarter of the pixels and
/// memory. The full tier disables it for genuine 100% zoom. Camera white
/// balance is applied and output is converted to sRGB; this is a practical SDR
/// culling preview, not a colour-managed rendering of an HLG master.
DecodedRawBitmap? decodeRawBitmap(
  FlutterLibRawBindings lr,
  String path, {
  bool halfSize = true,
}) {
  final handle = lr.libraw_init(0);
  if (handle == nullptr) return null;

  final pathC = path.toNativeUtf8();
  final errc = calloc<Int>();
  Pointer<libraw_processed_image_t> processed = nullptr;
  try {
    if (lr.libraw_open_file(handle, pathC.cast<Uint8>()) != 0) return null;

    // The generated bindings expose libraw_data_t::params. Half-size keeps a
    // 24 MP fallback near 18 MB instead of 74 MB per preview worker.
    handle.ref.params
      ..half_size = halfSize ? 1 : 0
      ..use_camera_wb = 1;
    lr
      ..libraw_set_demosaic(handle, 0) // fast linear interpolation
      ..libraw_set_output_color(handle, 1) // sRGB
      ..libraw_set_output_bps(handle, 8);

    if (lr.libraw_unpack(handle) != 0) return null;
    if (lr.libraw_dcraw_process(handle) != 0) return null;

    processed = lr.libraw_dcraw_make_mem_image(handle, errc);
    if (processed == nullptr || errc.value != 0) return null;

    final image = processed.ref;
    if (image.type != _librawImageBitmap ||
        image.bits != 8 ||
        image.colors != 3 ||
        image.width <= 0 ||
        image.height <= 0 ||
        image.data_size <= 0) {
      return null;
    }

    final expected = image.width * image.height * image.colors;
    if (image.data_size < expected) return null;
    final dataPtr = Pointer<Uint8>.fromAddress(
      processed.address + _processedDataOffset,
    );
    return DecodedRawBitmap(
      pixels: Uint8List.fromList(dataPtr.asTypedList(expected)),
      width: image.width,
      height: image.height,
      channels: image.colors,
    );
  } on Object {
    return null;
  } finally {
    if (processed != nullptr) lr.libraw_dcraw_clear_mem(processed);
    calloc.free(errc);
    malloc.free(pathC);
    lr.libraw_close(handle);
  }
}
