/// Self-contained MD5 (RFC 1321) for the danmaku file fingerprint.
///
/// The `danmu_api` match endpoint expects the MD5 of the file's first
/// 16 MiB (`fileHash`). `pubspec.yaml` is frozen for this task, and the
/// transitive `crypto` package is not a declared dependency, so the hash
/// is computed here in pure Dart. MD5 is fine for this purpose — it is a
/// content *fingerprint for lookup*, not a security primitive.
///
/// Streaming API: feed chunks with [Md5.addBytes] / [Md5.addIntList],
/// then close with [Md5.digest]. Correct for any total length (the
/// internal counter is 64-bit).
library;

import 'dart:typed_data';

const int _a0 = 0x67452301;
const int _b0 = 0xefcdab89;
const int _c0 = 0x98badcfe;
const int _d0 = 0x10325476;

// Per-round shift amounts (RFC 1321 section 3.4).
const List<int> _shifts = [
  7,
  12,
  17,
  22,
  7,
  12,
  17,
  22,
  7,
  12,
  17,
  22,
  7,
  12,
  17,
  22,
  5,
  9,
  14,
  20,
  5,
  9,
  14,
  20,
  5,
  9,
  14,
  20,
  5,
  9,
  14,
  20,
  4,
  11,
  16,
  23,
  4,
  11,
  16,
  23,
  4,
  11,
  16,
  23,
  4,
  11,
  16,
  23,
  6,
  10,
  15,
  21,
  6,
  10,
  15,
  21,
  6,
  10,
  15,
  21,
  6,
  10,
  15,
  21,
];

// K[i] = floor(abs(sin(i + 1)) * 2^32).
const List<int> _k = [
  0xd76aa478,
  0xe8c7b756,
  0x242070db,
  0xc1bdceee,
  0xf57c0faf,
  0x4787c62a,
  0xa8304613,
  0xfd469501,
  0x698098d8,
  0x8b44f7af,
  0xffff5bb1,
  0x895cd7be,
  0x6b901122,
  0xfd987193,
  0xa679438e,
  0x49b40821,
  0xf61e2562,
  0xc040b340,
  0x265e5a51,
  0xe9b6c7aa,
  0xd62f105d,
  0x02441453,
  0xd8a1e681,
  0xe7d3fbc8,
  0x21e1cde6,
  0xc33707d6,
  0xf4d50d87,
  0x455a14ed,
  0xa9e3e905,
  0xfcefa3f8,
  0x676f02d9,
  0x8d2a4c8a,
  0xfffa3942,
  0x8771f681,
  0x6d9d6122,
  0xfde5380c,
  0xa4beea44,
  0x4bdecfa9,
  0xf6bb4b60,
  0xbebfbc70,
  0x289b7ec6,
  0xeaa127fa,
  0xd4ef3085,
  0x04881d05,
  0xd9d4d039,
  0xe6db99e5,
  0x1fa27cf8,
  0xc4ac5665,
  0xf4292244,
  0x432aff97,
  0xab9423a7,
  0xfc93a039,
  0x655b59c3,
  0x8f0ccc92,
  0xffeff47d,
  0x85845dd1,
  0x6fa87e4f,
  0xfe2ce6e0,
  0xa3014314,
  0x4e0811a1,
  0xf7537e82,
  0xbd3af235,
  0x2ad7d2bb,
  0xeb86d391,
];

final Uint32List _kTable = Uint32List.fromList(_k);

/// Incremental MD5 hasher.
class Md5 {
  Md5() : _state = Uint32List.fromList([_a0, _b0, _c0, _d0]);

  final Uint32List _state;
  final Uint8List _buffer = Uint8List(64);
  int _bufferLen = 0;
  int _byteLength = 0; // low 64 bits of message length (mod 2^64)

  /// Feeds a byte chunk.
  void addBytes(List<int> bytes, [int start = 0, int? end]) {
    end ??= bytes.length;
    _byteLength += end - start;
    var i = start;
    while (i < end) {
      if (_bufferLen == 0 && end - i >= 64) {
        _block(bytes, i);
        i += 64;
        continue;
      }
      final take = 64 - _bufferLen < end - i ? 64 - _bufferLen : end - i;
      _buffer.setRange(_bufferLen, _bufferLen + take, bytes, i);
      _bufferLen += take;
      i += take;
      if (_bufferLen == 64) {
        _block(_buffer, 0);
        _bufferLen = 0;
      }
    }
  }

  /// Feeds an integer list (e.g. a `Uint8List` view over file bytes).
  void addIntList(List<int> bytes) => addBytes(bytes);

  /// Finishes the hash and returns the 16 digest bytes.
  Uint8List digest() {
    // MD5's length field is the message length in BITS (mod 2^64).
    final lengthBits = (_byteLength << 3) & 0xFFFFFFFFFFFFFFFF;
    var paddingLen = 64 - _bufferLen - 9;
    if (paddingLen < 0) paddingLen += 64;
    // The tail holds ONLY the padding + length: the pending bytes stay in
    // [_buffer] and are absorbed first by addBytes(tail) below. Appending a
    // copy of the buffered bytes into the tail (the original bug) duplicated
    // them; padding must be computed around _bufferLen.
    final tail = Uint8List(1 + paddingLen + 8);
    tail[0] = 0x80;
    final tailLen = 1 + paddingLen;
    tail[tailLen] = lengthBits & 0xFF;
    tail[tailLen + 1] = (lengthBits >> 8) & 0xFF;
    tail[tailLen + 2] = (lengthBits >> 16) & 0xFF;
    tail[tailLen + 3] = (lengthBits >> 24) & 0xFF;
    tail[tailLen + 4] = (lengthBits >> 32) & 0xFF;
    tail[tailLen + 5] = (lengthBits >> 40) & 0xFF;
    tail[tailLen + 6] = (lengthBits >> 48) & 0xFF;
    tail[tailLen + 7] = (lengthBits >> 56) & 0xFF;

    // Flush the pending bytes (may be a partial block; addBytes copies into
    // the buffer and only fires _block at 64).
    addBytes(tail);

    final out = Uint8List(16);
    final b = ByteData.sublistView(out);
    for (var i = 0; i < 4; i++) {
      b.setUint32(i * 4, _state[i], Endian.little);
    }
    return out;
  }

  /// Hex digest (lowercase, 32 chars).
  String digestHex() =>
      digest().map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  void _block(List<int> bytes, int offset) {
    final m = _mScratch;
    final bd = _mBytes;
    for (var i = 0; i < 16; i++) {
      bd[i] =
          bytes[offset + i * 4] |
          (bytes[offset + i * 4 + 1] << 8) |
          (bytes[offset + i * 4 + 2] << 16) |
          (bytes[offset + i * 4 + 3] << 24);
    }
    for (var i = 0; i < 16; i++) {
      m[i] = bd[i];
    }

    var a = _state[0];
    var b = _state[1];
    var c = _state[2];
    var d = _state[3];

    for (var i = 0; i < 64; i++) {
      int f;
      int g;
      final round = i >> 4;
      switch (round) {
        case 0:
          f = (b & c) | ((~b & _mask) & d);
          g = i;
        case 1:
          f = (d & b) | ((~d & _mask) & c);
          g = (5 * i + 1) & 15;
        case 2:
          f = b ^ c ^ d;
          g = (3 * i + 5) & 15;
        default:
          f = c ^ (b | (~d & _mask));
          g = (7 * i) & 15;
      }
      final tmp = d;
      d = c;
      c = b;
      final sum = (a + f + _kTable[i] + m[g]) & _mask;
      final rot = ((sum << _shifts[i]) & _mask) | (sum >> (32 - _shifts[i]));
      b = (b + rot) & _mask;
      a = tmp;
    }

    _state[0] = (_state[0] + a) & _mask;
    _state[1] = (_state[1] + b) & _mask;
    _state[2] = (_state[2] + c) & _mask;
    _state[3] = (_state[3] + d) & _mask;
  }
}

const int _mask = 0xFFFFFFFF;

final Int32List _mBytes = Int32List(16);
final Uint32List _mScratch = Uint32List(16);

/// One-shot MD5 hex of [bytes].
String md5Hex(List<int> bytes) {
  final h = Md5()..addBytes(bytes);
  return h.digestHex();
}
