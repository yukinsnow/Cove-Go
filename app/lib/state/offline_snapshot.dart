import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

/// Display-only snapshots. Encryption keys stay in platform secure storage;
/// filenames contain only digests, never addresses, credentials or session ids.
class OfflineSnapshotStore {
  OfflineSnapshotStore({Future<Directory> Function()? directory, Future<SecretKey> Function()? key})
    : _directory = directory ?? _defaultDirectory,
      _keyLoader = key ?? _defaultKey;

  final Future<Directory> Function() _directory;
  final Future<SecretKey> Function() _keyLoader;
  Future<SecretKey>? _key;
  final _cipher = AesGcm.with256bits();
  Future<void> _writes = Future.value();
  final _last = <String, String>{};
  static const maxBytes = 2 * 1024 * 1024;
  static String _filename(String scope) =>
      '${scope.startsWith('dsh-identity:') ? 'identity-' : ''}${digest(scope)}.json';
  static String digest(Object value) => sha256.convert(utf8.encode(jsonEncode(value))).toString();

  static Future<Directory> _defaultDirectory() async =>
      Directory('${(await getApplicationSupportDirectory()).path}/offline-snapshots-v1');
  static Future<SecretKey>? _platformKey;
  static Future<SecretKey> _defaultKey() => _platformKey ??= _loadPlatformKey();
  static Future<SecretKey> _loadPlatformKey() async {
    const storage = FlutterSecureStorage();
    final encoded = await storage.read(key: 'offline.snapshot.key.v1');
    if (encoded != null) return SecretKey(base64Decode(encoded));
    final key = await AesGcm.with256bits().newSecretKey();
    await storage.write(key: 'offline.snapshot.key.v1', value: base64Encode(await key.extractBytes()));
    return key;
  }

  Map<String, dynamic>? peek(String scope) {
    final encoded = _last[scope];
    return encoded == null ? null : Map<String, dynamic>.from((jsonDecode(encoded) as Map)['snapshot'] as Map);
  }

  Future<Map<String, dynamic>?> read(String scope) async {
    try {
      final file = File('${(await _directory()).path}/${_filename(scope)}');
      if (!await file.exists() || await file.length() > maxBytes + 1024) return null;
      final box = jsonDecode(await file.readAsString()) as Map;
      final clear = await _cipher.decrypt(
        SecretBox(
          base64Decode(box['data'] as String),
          nonce: base64Decode(box['nonce'] as String),
          mac: Mac(base64Decode(box['mac'] as String)),
        ),
        secretKey: await (_key ??= _keyLoader()),
        aad: utf8.encode(scope),
      );
      final value = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
      if (value['version'] != 1) return null;
      return Map<String, dynamic>.from(value['snapshot'] as Map);
    } on Object {
      // Missing, corrupt, evicted or inaccessible caches never block connecting.
      return null;
    }
  }

  Future<void> write(String scope, Map<String, dynamic> snapshot) {
    final encoded = jsonEncode({'version': 1, 'snapshot': snapshot});
    if (utf8.encode(encoded).length > maxBytes || _last[scope] == encoded) return _writes;
    _last[scope] = encoded;
    while (_last.length > 24) {
      _last.remove(_last.keys.first);
    }
    return _writes = _writes.then((_) async {
      try {
        final dir = await _directory();
        await dir.create(recursive: true);
        final box = await _cipher.encrypt(
          utf8.encode(encoded),
          secretKey: await (_key ??= _keyLoader()),
          aad: utf8.encode(scope),
        );
        final file = File('${dir.path}/${_filename(scope)}');
        final temp = File('${file.path}.tmp');
        await temp.writeAsString(
          jsonEncode({
            'data': base64Encode(box.cipherText),
            'nonce': base64Encode(box.nonce),
            'mac': base64Encode(box.mac.bytes),
          }),
          flush: true,
        );
        await temp.rename(file.path);
        final identityFile = scope.startsWith('dsh-identity:');
        final files = await dir
            .list()
            .where(
              (e) =>
                  e is File &&
                  e.path.endsWith('.json') &&
                  e.uri.pathSegments.last.startsWith('identity-') == identityFile,
            )
            .cast<File>()
            .toList();
        final dated = await Future.wait(files.map((f) async => (f, await f.lastModified())));
        dated.sort((a, b) => a.$2.compareTo(b.$2));
        final limit = identityFile ? 8 : 24;
        for (final entry in dated.take((dated.length - limit).clamp(0, dated.length))) {
          await entry.$1.delete();
        }
      } on Object {
        _last.remove(scope); // Permit retry on the next authoritative update.
      }
    });
  }
}

final offlineSnapshotStoreProvider = Provider((ref) => OfflineSnapshotStore());
final offlineSnapshotProvider = FutureProvider.family<Map<String, dynamic>?, String>(
  (ref, scope) => ref.watch(offlineSnapshotStoreProvider).read(scope),
);
