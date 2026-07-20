import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:latch/core/incoming_file_service.dart';

GoRouter _testRouter() {
  return GoRouter(
    initialLocation: '/home',
    routes: [
      GoRoute(
        path: '/home',
        builder: (_, _) => const Scaffold(body: Text('home')),
      ),
      GoRoute(
        path: '/decrypt/passphrase',
        builder: (ctx, state) => const Scaffold(body: Text('passphrase')),
      ),
    ],
  );
}

List<SharedMediaFile> _latchFile(String path) => [
  SharedMediaFile(
    path: path,
    type: SharedMediaType.file,
    mimeType: 'application/octet-stream',
  ),
];

List<SharedMediaFile> _nonLatch() => [
  SharedMediaFile(
    path: 'photo.jpg',
    type: SharedMediaType.image,
    mimeType: 'image/jpeg',
  ),
];

void main() {
  group('IncomingFileService', () {
    testWidgets('routes .latch files from initial media to decrypt passphrase', (
      tester,
    ) async {
      final router = _testRouter();
      final controller = StreamController<List<SharedMediaFile>>();

      ReceiveSharingIntent.setMockValues(
        initialMedia: _latchFile('/downloads/report.latch'),
        mediaStream: controller.stream,
      );

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));

      final svc = IncomingFileService(router: router);
      await svc.handleInitialMedia();
      await tester.pumpAndSettle();

      // The router should have navigated to the passphrase screen with the file.
      expect(find.text('passphrase'), findsOneWidget);
    });

    testWidgets('ignores non-latch files from initial media', (tester) async {
      final router = _testRouter();
      final controller = StreamController<List<SharedMediaFile>>();

      ReceiveSharingIntent.setMockValues(
        initialMedia: _nonLatch(),
        mediaStream: controller.stream,
      );

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));

      final svc = IncomingFileService(router: router);
      await svc.handleInitialMedia();
      await tester.pumpAndSettle();

      expect(find.text('home'), findsOneWidget);
    });

    testWidgets('routes from media stream (warm-start)', (tester) async {
      final router = _testRouter();
      final controller = StreamController<List<SharedMediaFile>>();

      ReceiveSharingIntent.setMockValues(
        initialMedia: _nonLatch(),
        mediaStream: controller.stream,
      );

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));

      final svc = IncomingFileService(router: router);
      await svc.handleInitialMedia();
      svc.startListening();
      await tester.pumpAndSettle();
      expect(find.text('home'), findsOneWidget);

      controller.add(_latchFile('/downloads/invoice.latch'));
      await tester.pumpAndSettle();

      expect(find.text('passphrase'), findsOneWidget);
    });

    testWidgets('ignores generic octet-stream files that are not .latch', (
      tester,
    ) async {
      final router = _testRouter();
      final controller = StreamController<List<SharedMediaFile>>();

      ReceiveSharingIntent.setMockValues(
        initialMedia: [
          SharedMediaFile(
            path: '/downloads/firmware.bin',
            type: SharedMediaType.file,
            mimeType: 'application/octet-stream',
          ),
        ],
        mediaStream: controller.stream,
      );

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));

      final svc = IncomingFileService(router: router);
      await svc.handleInitialMedia();
      await tester.pumpAndSettle();

      expect(find.text('home'), findsOneWidget);
    });

    testWidgets('ignores non-latch files from the media stream', (
      tester,
    ) async {
      final router = _testRouter();
      final controller = StreamController<List<SharedMediaFile>>();

      ReceiveSharingIntent.setMockValues(
        initialMedia: _nonLatch(),
        mediaStream: controller.stream,
      );

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));

      final svc = IncomingFileService(router: router);
      await svc.handleInitialMedia();
      svc.startListening();
      await tester.pumpAndSettle();

      controller.add(_nonLatch());
      await tester.pumpAndSettle();

      expect(find.text('home'), findsOneWidget);
    });
  });
}
