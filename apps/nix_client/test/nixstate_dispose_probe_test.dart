import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nix_client/state/nix_state.dart';

Future<void> waitUntil(bool Function() condition) async {
  final timeout = Stopwatch()..start();
  while (!condition() && timeout.elapsed < const Duration(seconds: 2)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final resource in ['cofre', 'banco']) {
    test('dispose libera $resource inicializado', () async {
      final tempDir =
          await Directory.systemTemp.createTemp('nix_dispose_probe_');
      final state = NixState();
      var disposed = false;
      addTearDown(() async {
        if (!disposed) state.dispose();
        await state.localDatabase?.close();
        state.keyVault.lock();
        await tempDir.delete(recursive: true);
      });
      expect(
        await state.initializeEncryptedDatabase(
          passphrase: 'senha-sintetica-probe',
          customDbPath: '${tempDir.path}/local.db',
          customVaultPath: '${tempDir.path}/vault.json',
        ),
        isTrue,
      );
      final database = state.localDatabase!;
      expect(database.rawDatabase.isOpen, isTrue);
      expect(state.keyVault.isUnlocked, isTrue);

      state.dispose();
      disposed = true;
      if (resource == 'cofre') {
        await waitUntil(() => !state.keyVault.isUnlocked);
        expect(state.keyVault.isUnlocked, isFalse);
        expect(() => state.keyVault.masterKey, throwsStateError);
      } else {
        await waitUntil(() => !database.rawDatabase.isOpen);
        expect(database.rawDatabase.isOpen, isFalse);
      }
    });
  }

  test('dispose durante inicialização não reabre banco nem desbloqueia cofre',
      () async {
    final tempDir = await Directory.systemTemp.createTemp('nix_dispose_race_');
    final state = NixState();
    addTearDown(() async {
      await state.localDatabase?.close();
      state.keyVault.lock();
      await tempDir.delete(recursive: true);
    });

    final initialization = state.initializeEncryptedDatabase(
      passphrase: 'senha-sintetica-probe',
      customDbPath: '${tempDir.path}/local.db',
      customVaultPath: '${tempDir.path}/vault.json',
    );
    state.dispose();
    expect(await initialization, isFalse);
    expect(state.keyVault.isUnlocked, isFalse);
    expect(state.localDatabase?.rawDatabase.isOpen ?? false, isFalse);
    expect(state.isDatabaseReady, isFalse);
    expect(state.identityRepo, isNull);
  });

  test('dispose encerra streams Tor e mesh e desativa a malha', () async {
    final state = NixState();
    final mesh = state.bluetoothMesh;
    mesh.setMeshEnabled(true);
    final torDone = Completer<void>();
    final meshDone = Completer<void>();
    final torSubscription = state.embeddedTor.onBootstrapProgress.listen(
      (_) {},
      onDone: torDone.complete,
    );
    final meshSubscription = mesh.onPeerDiscovered.listen(
      (_) {},
      onDone: meshDone.complete,
    );
    addTearDown(() async {
      await torSubscription.cancel();
      await meshSubscription.cancel();
    });

    state.dispose();
    await waitUntil(() => torDone.isCompleted && meshDone.isCompleted);
    expect(torDone.isCompleted, isTrue);
    expect(meshDone.isCompleted, isTrue);
    expect(mesh.isMeshEnabled, isFalse);
  });
}
