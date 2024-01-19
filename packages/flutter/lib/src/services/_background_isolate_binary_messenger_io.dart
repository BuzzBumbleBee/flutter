// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async' show Completer;
import 'dart:isolate' show ReceivePort;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'binary_messenger.dart';
import 'binding.dart';

/// A [BinaryMessenger] for use on background (non-root) isolates.
class BackgroundIsolateBinaryMessenger extends BinaryMessenger {
  BackgroundIsolateBinaryMessenger._();

  final ReceivePort _receivePort = ReceivePort();
  final ReceivePort _listenPort = ReceivePort();
  final Map<int, Completer<ByteData?>> _completers =
      <int, Completer<ByteData?>>{};
  int _messageCount = 0;

  /// The existing instance of this class, if any.
  ///
  /// Throws if [ensureInitialized] has not been called at least once.
  static BinaryMessenger get instance {
    if (_instance == null) {
      throw StateError(
          'The BackgroundIsolateBinaryMessenger.instance value is invalid '
          'until BackgroundIsolateBinaryMessenger.ensureInitialized is '
          'executed.');
    }
    return _instance!;
  }

  static BinaryMessenger? _instance;

  /// Ensures that [BackgroundIsolateBinaryMessenger.instance] has been initialized.
  ///
  /// The argument should be the value obtained from [ServicesBinding.rootIsolateToken]
  /// on the root isolate.
  ///
  /// This function is idempotent (calling it multiple times is harmless but has no effect).
  static void ensureInitialized(ui.RootIsolateToken token) {
    if (_instance == null) {
      ui.PlatformDispatcher.instance.registerBackgroundIsolate(token);
      final BackgroundIsolateBinaryMessenger portBinaryMessenger =
          BackgroundIsolateBinaryMessenger._();
      _instance = portBinaryMessenger;

      // Setup the ReceivePort that will persistently listen to incoming
      // platfrom messages
      portBinaryMessenger._listenPort.listen((dynamic message) {
        // Handle messages sent from the platform isolate to the current
        // background isolate
        final List<dynamic> args = message as List<dynamic>;
        final int responseId = args[0] as int; // 1st element is always the response id
        final String channel = args[1] as String; // 2nd element is the channel name
        final Uint8List bytes = args[2] as Uint8List;
        final ByteData byteData = ByteData.sublistView(bytes);

        ui.PlatformDispatcher.instance.dispachPlatformMessageFromIsolate(
            channel,
            byteData,
            responseId);
      });
      portBinaryMessenger._receivePort.listen((dynamic message) {
        try {
          final List<dynamic> args = message as List<dynamic>;
          final int identifier = args[0] as int;
          final Uint8List bytes = args[1] as Uint8List;
          final ByteData byteData = ByteData.sublistView(bytes);
          portBinaryMessenger._completers
              .remove(identifier)!
              .complete(byteData);
        } catch (exception, stack) {
          FlutterError.reportError(FlutterErrorDetails(
            exception: exception,
            stack: stack,
            library: 'services library',
            context:
                ErrorDescription('during a platform message response callback'),
          ));
        }
      });
    }
  }

  void registerIsolateCallback(String channnel) {
    ui.PlatformDispatcher.instance.addPlatformPortCallback(channnel, _listenPort.sendPort);
  }

  void removeIsolateCallback(String channel) {
    ui.PlatformDispatcher.instance.removePlatformPortCallback(channel);
  }

  @override
  Future<void> handlePlatformMessage(String channel, ByteData? data,
      ui.PlatformMessageResponseCallback? callback) {
    throw UnimplementedError('handlePlatformMessage is deprecated.');
  }

  @override
  Future<ByteData?>? send(String channel, ByteData? message) {
    final Completer<ByteData?> completer = Completer<ByteData?>();
    _messageCount += 1;
    final int messageIdentifier = _messageCount;
    _completers[messageIdentifier] = completer;
    ui.PlatformDispatcher.instance.sendPortPlatformMessage(
      channel,
      message,
      messageIdentifier,
      _receivePort.sendPort,
    );
    return completer.future;
  }

  @override
  void setMessageHandler(String channel, MessageHandler? handler) {

    if (ui.channelBuffers == null) {
      throw Error("ui.channelBuffers is null");
    }
    try {
      if (handler == null) {
        ui.channelBuffers.clearListener(channel);
      } else {
        ui.channelBuffers.setListener(channel, (ByteData? data,
            ui.PlatformMessageResponseCallback callback) async {
          ByteData? response;
          try {
            response = await handler(data);
          } catch (exception, stack) {
            FlutterError.reportError(FlutterErrorDetails(
              exception: exception,
              stack: stack,
              library: 'services library',
              context: ErrorDescription('during a platform message callback'),
            ));
          } finally {
            callback(response);
          }
        });
      }
    } catch (exception, stack) {
      FlutterError.reportError(FlutterErrorDetails(
        exception: exception,
        stack: stack,
        library: 'services library',
        context: ErrorDescription('during a platform message callback'),
      ));
    }
  }
}
