// Copyright 2017 The Fuchsia Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
import 'dart:async';

import 'package:lib.app.dart/app.dart';
import 'package:lib.logging/logging.dart';
import 'package:lib.media.fidl/problem.fidl.dart';
import 'package:lib.media.flutter/media_player_controller.dart';
import 'package:lib.ui.flutter/child_view.dart';
import 'package:lib.widgets/model.dart';
import 'package:lib.widgets/modular.dart';
import 'package:meta/meta.dart';

import '../widgets.dart';

const Duration _kOverlayAutoHideDuration = const Duration(seconds: 3);
const Duration _kLoadingDuration = const Duration(seconds: 2);
const Duration _kProgressBarUpdateInterval = const Duration(milliseconds: 100);
const String _kServiceName = 'fling';

final Asset _defaultAsset = new Asset.movie(
  uri: Uri.parse(
      'https://storage.googleapis.com/fuchsia/assets/video/656a7250025525ae5a44b43d23c51e38b466d146'),
  title: 'Discover Tahiti',
  description:
      'Take a trip and experience the ultimate island fantasy, Vahine Island in Tahiti.',
  thumbnail: 'assets/video-thumbnail.png',
  background: 'assets/video-background.png',
);

/// Typedef for function to request focus for module
typedef void RequestFocus();

/// Typedef for function to get displayMode
typedef DisplayMode DisplayModeGetter();

/// Typedef for function to set displayMode
typedef void DisplayModeSetter(DisplayMode mode);

/// Typedef for updating device info when playing remotely
typedef void PlayRemoteCallback(String deviceName);

/// Typedef for updating device info when playing locally
typedef void PlayLocalCallback();

/// The [Model] for the video player.
class PlayerModel extends Model {
  Timer _hideTimer;
  Timer _progressTimer;
  Timer _errorTimer;
  MediaPlayerController _controller;
  bool _wasPlaying = false;
  bool _locallyControlled = false;
  bool _showControlOverlay = true;
  bool _failedCast = false;
  Asset _asset = _defaultAsset;
  // The video has ended but the user has not uncast.
  // Replaying the video should still happen on remote device.
  bool _replayRemotely = false;

  /// App context passed in from starting the app
  final ApplicationContext appContext;

  /// Function that calls ModuleContext.requestFocus(), which
  /// focuses module (when cast onto remote device)
  RequestFocus requestFocus;

  /// Returns the module's displayMode
  DisplayModeGetter getDisplayMode;

  /// Sets the module's displayMode
  DisplayModeSetter setDisplayMode;

  /// Callback that updates device-specific info for remote play
  PlayRemoteCallback onPlayRemote;

  /// Callback that updates device-specific info for local play
  PlayLocalCallback onPlayLocal;

  /// Create a Player model
  PlayerModel({
    this.appContext,
    @required this.requestFocus,
    @required this.getDisplayMode,
    @required this.setDisplayMode,
    @required this.onPlayRemote,
    @required this.onPlayLocal,
  })
      : assert(requestFocus != null),
        assert(getDisplayMode != null),
        assert(setDisplayMode != null),
        assert(onPlayRemote != null),
        assert(onPlayLocal != null) {
    _controller = new MediaPlayerController(appContext.environmentServices)
      ..addListener(_handleControllerChanged)
      ..open(_asset.uri, serviceName: _kServiceName);

    notifyListeners();
  }

  /// Returns whether casting failed
  bool get failedCast => _failedCast;

  /// Returns whether media player controller is playing
  bool get playing => _controller.playing;

  /// Gets and sets whether we should show play controls and scrubber.
  /// In remote control mode, we always show the control overlay with active
  /// (i.e. actively moving, receiving timed notifications) progress bar.
  bool get showControlOverlay => _showControlOverlay;
  set showControlOverlay(bool show) {
    if (getDisplayMode() == DisplayMode.remoteControl) {
      if (!showControlOverlay) {
        _showControlOverlay = true;
        notifyListeners();
      }
      return;
    }

    assert(show != null);
    if (showControlOverlay != show) {
      _showControlOverlay = show;
      notifyListeners();
    }
  }

  /// Returns media player controller video duration
  Duration get duration => _controller.duration;

  /// Returns media player controller video progress
  Duration get progress => _controller.progress;

  /// Returns media player controller normalized video progress
  double get normalizedProgress => _controller.normalizedProgress;

  /// Seeks video to normalized position
  void normalizedSeek(double normalizedPosition) {
    _controller.normalizedSeek(normalizedPosition);
  }

  /// Returns media player controller video view connection
  ChildViewConnection get videoViewConnection =>
      _controller.videoViewConnection;

  /// Currently playing asset
  Asset get asset => _asset;

  /// Seeks to a duration in the video
  void seek(Duration duration) {
    _locallyControlled = true;
    _controller.seek(duration);
    // TODO(maryxia) SO-589 seek after video has ended
  }

  /// Plays video
  void play() {
    _progressTimer = new Timer.periodic(
        _kProgressBarUpdateInterval, (Timer timer) => _notifyTimerListeners());
    _locallyControlled = true;
    if (_asset.type == AssetType.remote) {
      Duration lastLocalTime = _controller.progress;
      _controller.connectToRemote(
        device: _asset.device,
        service: _asset.service,
      );

      if (_replayRemotely) {
        lastLocalTime = Duration.ZERO;
        _replayRemotely = false;
      }
      _controller.seek(lastLocalTime);
    } else {
      _controller.play();
      brieflyShowControlOverlay();
    }
  }

  /// Pauses video
  void pause() {
    _locallyControlled = true;
    _controller.pause();
    _progressTimer.cancel();
  }

  /// Start playing video on remote device if it is playing locally
  void playRemote(String deviceName) {
    if (_asset.device == null) {
      pause();
      log.fine('Starting remote play on $deviceName');
      _asset = new Asset.remote(
          service: _kServiceName,
          device: deviceName,
          uri: _asset.uri,
          title: _asset.title,
          description: _asset.description,
          thumbnail: _asset.thumbnail,
          background: _asset.background,
          position: _controller.progress);
      onPlayRemote(deviceName);
      play();
    }
  }

  /// Start playing video on local device if it is controlling remotely
  void playLocal() {
    _replayRemotely = false;
    if (_asset.device != null) {
      pause();
      Duration progress = _controller.progress;
      _controller.close();
      _asset = _defaultAsset;
      setDisplayMode(kDefaultDisplayMode);
      log.fine('Starting local play');
      _controller
        ..open(_asset.uri, serviceName: _kServiceName)
        ..seek(progress);

      brieflyShowControlOverlay();
      onPlayLocal();
      play();
    }
  }

  /// Handles change notifications from the controller
  void _handleControllerChanged() {
    // If unable to connect and cast to remote device, show loading screen for
    // 2 seconds and then return back to local video with error toast
    if (_controller.problem?.type == Problem.kProblemConnectionFailed) {
      setDisplayMode(DisplayMode.localLarge);
      showControlOverlay = false; // hide play controls in loading screen
      _errorTimer = new Timer(_kLoadingDuration, () {
        _errorTimer?.cancel();
        _errorTimer = new Timer(_kOverlayAutoHideDuration, () {
          _errorTimer?.cancel();
          _errorTimer = null;
          _failedCast = false;
          notifyListeners();
        });
        _failedCast = true;
        notifyListeners();
        playLocal();
      });
    } else if (_errorTimer == null && _failedCast) {
      _failedCast = false;
      notifyListeners();
    }
    if (_controller.playing &&
        !_locallyControlled &&
        getDisplayMode() != DisplayMode.immersive) {
      setDisplayMode(DisplayMode.immersive);
      if (!_wasPlaying && _controller.playing) {
        requestFocus();
      }
      _wasPlaying = _controller.playing;
      notifyListeners();
    }
    if (showControlOverlay) {
      brieflyShowControlOverlay(); // restart the timer
      notifyListeners();
    }
    if (_controller.isRemote && _controller.ended) {
      _replayRemotely = true;
    }
  }

  /// Shows the control overlay for [_kOverlayAutoHideDuration].
  void brieflyShowControlOverlay() {
    showControlOverlay = true;
    _hideTimer?.cancel();
    _hideTimer = new Timer(_kOverlayAutoHideDuration, () {
      _hideTimer = null;
      if (_controller.playing) {
        showControlOverlay = false;
      }
      notifyListeners();
    });
  }

  void _notifyTimerListeners() {
    if (_controller.playing && showControlOverlay) {
      notifyListeners();
    }
  }
}