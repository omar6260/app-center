import 'dart:async';

import 'package:app_center/manage/manage_model.dart';
import 'package:app_center/snapd/snapd.dart';
import 'package:app_center/snapd/snapd_cache.dart';
import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:snapd/snapd.dart';
import 'package:ubuntu_service/ubuntu_service.dart';

part 'snap_model.g.dart';

@Riverpod(keepAlive: true)
class SnapModel extends _$SnapModel {
  late final _snapd = getService<SnapdService>();

  @override
  Future<SnapData> build(String snapName) async {
    Snap? localSnap;
    try {
      localSnap = await _snapd.getSnap(snapName);
    } on SnapdException catch (e) {
      // Since the snap is just not installed when 'snap-not-found is thrown we
      // can ignore this exception.
      if (e.kind != 'snap-not-found' && e.kind != null) rethrow;
    }

    final storeSnap = await ref
        .watch(storeSnapProvider(snapName).future)
        .onError((_, __) => null, test: (_) => localSnap != null);

    final activeChangeId = (await _snapd.getChanges(name: snapName))
        .firstWhereOrNull((change) => !change.ready)
        ?.id;
    if (activeChangeId != null) {
      unawaited(_listenUntilDone(activeChangeId, snapName, ref));
    }

    if (localSnap == null && storeSnap == null) {
      throw SnapDataNotFoundException(snapName);
    }
    final hasUpdate = ref.watch(hasUpdateProvider(snapName));

    return SnapData(
      name: snapName,
      localSnap: localSnap,
      storeSnap: storeSnap,
      activeChangeId: activeChangeId,
      selectedChannel: SnapData.defaultSelectedChannel(
        localSnap,
        storeSnap,
      ),
      hasUpdate: hasUpdate,
    );
  }

  /// Installs the selected snap from the selected channel.
  Future<void> install() async {
    assert(
      state.hasStoreSnap,
      'The snap must be loaded from the store before installing it',
    );
    final model = state.value;
    final storeSnap = model?.storeSnap;
    final selectedChannel = model?.selectedChannel;

    assert(
      storeSnap?.channels[selectedChannel] != null,
      'Invalid channel or not fully loaded store snap $selectedChannel',
    );
    final changeId = await _snapd.install(
      snapName,
      channel: selectedChannel,
      classic: storeSnap!.channels[selectedChannel]!.confinement ==
          SnapConfinement.classic,
    );
    _updateChangeId(changeId);
    return _listenUntilDone(changeId, snapName, ref);
  }

  /// Cancels (aborts) the currently active operation which is tracked by
  /// the `activeChangeId`.
  Future<void> cancel() async {
    assert(
      state.hasStoreSnap,
      'The snap must be loaded from the store before aborting an action',
    );
    final changeIdToAbort = state.value?.activeChangeId;
    if (changeIdToAbort == null) {
      return;
    }
    final changeId = (await _snapd.abortChange(changeIdToAbort)).id;
    _updateChangeId(changeId);
    return _listenUntilDone(changeId, snapName, ref, invalidate: false);
  }

  /// Updates the version of the snap.
  Future<void> refresh() async {
    assert(
      state.hasStoreSnap,
      'The snap must be loaded from the store before updating it',
    );
    final snapData = state.value!;
    final storeSnap = snapData.storeSnap;
    final selectedChannel = snapData.selectedChannel;

    final changeId = await _snapd.refresh(
      snapData.name,
      channel: selectedChannel,
      classic: storeSnap!.channels[selectedChannel]!.confinement ==
          SnapConfinement.classic,
    );
    _updateChangeId(changeId);
    return _listenUntilDone(changeId, snapData.name, ref);
  }

  /// Uninstalls the snap.
  Future<void> remove() async {
    assert(state.hasValue, 'The snap must be loaded before removing it');
    final changeId = await _snapd.remove(snapName);
    _updateChangeId(changeId);
    await _listenUntilDone(changeId, snapName, ref);
    ref.invalidate(manageModelProvider);
  }

  /// Changes the selected channel.
  Future<void> selectChannel(String channel) async {
    assert(
      state.hasStoreSnap,
      'The snap must be loaded from the store before changing channel',
    );
    final data = state.value!;
    state = AsyncData(data.copyWith(selectedChannel: channel));
  }

  void _updateChangeId(String? changeId) {
    final data = state.value;
    if (data != null) {
      state = AsyncData(data.copyWith(activeChangeId: changeId));
    }
  }

  Future<void> _listenUntilDone(
    String changeId,
    String snapName,
    Ref ref, {
    bool invalidate = true,
  }) async {
    final completer = Completer();
    _snapd.watchChange(changeId).listen((event) {
      if (event.err != null) {
        completer.completeError(event.err!);
      } else if (event.ready) {
        completer.complete();
      }
    });
    await completer.future.whenComplete(() => _updateChangeId(null));
    if (invalidate) {
      ref.invalidateSelf();
    }
  }
}

/// Provides the progress of the snapd operations for the given change IDs.
final progressProvider =
    StreamProvider.family.autoDispose<double, List<String>>((ref, ids) {
  final snapd = getService<SnapdService>();

  final streamController = StreamController<double>.broadcast();
  final subProgresses = <String, double>{for (final id in ids) id: 0.0};
  final subscriptions = <String, StreamSubscription<SnapdChange>>{
    for (final id in ids)
      id: snapd.watchChange(id).listen((change) {
        subProgresses[id] = change.progress;
        streamController.add(subProgresses.values.sum / subProgresses.length);
      }),
  };
  ref.onDispose(() {
    for (final subscription in subscriptions.values) {
      subscription.cancel();
    }
    streamController.close();
  });
  return streamController.stream;
});

/// Provides the active change, if any, for a given changeId.
final activeChangeProvider =
    StateProvider.family<SnapdChange?, String?>((ref, id) {
  if (id == null) return null;
  late final StreamSubscription<SnapdChange> subscription;
  subscription = getService<SnapdService>().watchChange(id).listen((event) {
    ref.controller.state = event;
    if (event.ready) {
      subscription.cancel();
    }
  });
  ref.onDispose(subscription.cancel);
  return null;
});

extension SnapdChangeX on SnapdChange {
  double get progress {
    var done = 0.0;
    var total = 0.0;
    for (final task in tasks) {
      done += task.progress.done;
      total += task.progress.total;
    }

    return total != 0 ? done / total : 0;
  }
}

extension on AsyncValue<SnapData> {
  bool get hasStoreSnap => valueOrNull?.storeSnap != null;
}

class SnapDataNotFoundException implements Exception {
  SnapDataNotFoundException(this.message);

  final String message;

  @override
  String toString() => 'SnapDataNotFoundException: $message';
}
