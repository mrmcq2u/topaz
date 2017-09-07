// Copyright 2017 The Fuchsia Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:application.lib.app.dart/app.dart';
import 'package:apps.maxwell.services.context/context_reader.fidl.dart';
import 'package:apps.maxwell.services.context/metadata.fidl.dart';
import 'package:apps.maxwell.services.context/value_type.fidl.dart';
import 'package:apps.maxwell.services.suggestion/proposal.fidl.dart';
import 'package:apps.maxwell.services.suggestion/proposal_publisher.fidl.dart';
import 'package:apps.maxwell.services.suggestion/suggestion_display.fidl.dart';
import 'package:apps.modular.services.surface/surface.fidl.dart';
import 'package:config/config.dart';
import 'package:last_fm_api/api.dart';
import 'package:last_fm_models/last_fm_models.dart';
import 'package:lib.fidl.dart/bindings.dart';
import 'package:lib.logging/logging.dart';
import 'package:meta/meta.dart';

/// The Music Artist Agent subscribes to the 'focal_entities' topic and will
/// propose Music Artist suggestions if any of those Entities is an artist that
/// Spotify recognizes

/// The context topic for "Music Artist"
const String _kMusicArtistTopic = '/story/focused/link/music_artist';

/// The Entity type for a music artist.
const String _kMusicArtistType = 'http://types.fuchsia.io/music/artist';

/// Global scoping to prevent garbage collection
final ContextReaderProxy _contextReader = new ContextReaderProxy();
ContextListenerImpl _contextListenerImpl;
final ProposalPublisherProxy _proposalPublisher = new ProposalPublisherProxy();
final ApplicationContext _context = new ApplicationContext.fromStartupInfo();

/// Concert ContextListener that prints if the given artist has an upcoming
/// concert in the user's metro area.
class ContextListenerImpl extends ContextListener {
  final ContextListenerBinding _binding =
      new ContextListenerBinding();

  final LastFmApi _api;

  /// Constructor
  ContextListenerImpl({
    @required String apiKey,
  })
      : _api = new LastFmApi(apiKey: apiKey) {
    assert(apiKey != null);
  }

  /// Gets the [InterfaceHandle]
  ///
  /// The returned handle should only be used once.
  InterfaceHandle<ContextListener> getHandle() => _binding.wrap(this);

  @override
  Future<Null> onContextUpdate(ContextUpdate result) async {
    if (result.values[_kMusicArtistTopic].length == 0) {
      return;
    }

    // TODO(thatguy): There can be more than one value. At some point, use the
    // entity type in the ContextQuery instead of using topics as if they are
    // types, and handle multiple instances.
    dynamic data = JSON.decode(result.values[_kMusicArtistTopic][0].content);

    if (_isValidArtistContextLink(data)) {
      log.fine('artist update: ${data['name']}');
      try {
        Artist artist = await _api.getArtist(data['name']);
        if (artist != null) {
          log.fine('found artist for: ${data['name']}');
          _createProposal(artist, data);
        } else {
          log.fine('no artist found for: ${data['name']}');
        }
      } catch (_) {}
    }
  }

  /// Creates a proposal for the given Last FM artist
  void _createProposal(Artist artist, Map<String, dynamic> data) {
    String headline = 'Learn more about ${artist.name}';

    Proposal proposal = new Proposal()
      ..id = 'Last FM Artist bio: ${artist.mbid}'
      ..display = (new SuggestionDisplay()
        ..headline = headline
        ..subheadline = 'powered by Last.fm'
        ..details = ''
        ..color = 0xFFFF0080
        ..iconUrls = const <String>[]
        ..imageType = SuggestionImageType.other
        ..imageUrl = artist.imageUrl
        ..annoyance = AnnoyanceType.none)
      ..onSelected = <Action>[
        new Action()
          ..addModuleToStory = (new AddModuleToStory()
            ..linkName = data['@source']['link_name']
            ..storyId = data['@source']['story_id']
            ..moduleName = 'Last FM: ${data['name']}'
            ..modulePath = data['@source']['module_path']
            ..moduleUrl = 'file:///system/apps/last_fm_artist_bio'
            ..surfaceRelation = (new SurfaceRelation()
              ..arrangement = SurfaceArrangement.copresent
              ..emphasis = 0.5
              ..dependency = SurfaceDependency.dependent))
      ];

    log.fine('proposing artist bio suggestion');
    _proposalPublisher.propose(proposal);
  }

  /// A valid artist context link must satisfy the following criteria:
  /// * @type must be 'http://types.fuchsia.io/music/artist'.
  /// * Must have a @source field which contains the story ID, link name and
  ///   module path.
  /// * Must specify a name
  bool _isValidArtistContextLink(Map<String, dynamic> data) {
    return data != null &&
        data['@type'] is String &&
        data['@type'] == _kMusicArtistType &&
        data['@source'] is Map<String, dynamic> &&
        data['@source']['story_id'] is String &&
        data['@source']['link_name'] is String &&
        data['@source']['module_path'] is List<String> &&
        data['name'] is String;
  }
}

Future<Null> main(List<dynamic> args) async {
  setupLogger();

  Config config = await Config.read('/system/data/modules/config.json');
  config.validate(<String>['last_fm_api_key']);
  connectToService(_context.environmentServices, _contextReader.ctrl);
  connectToService(_context.environmentServices, _proposalPublisher.ctrl);
  ContextSelector selector = new ContextSelector()
    ..type = ContextValueType.entity;
  selector.meta = new ContextMetadata();
  selector.meta.entity = new EntityMetadata()..topic = _kMusicArtistTopic;
  ContextQuery query = new ContextQuery();
  query.selector = <String, ContextSelector>{_kMusicArtistTopic: selector};
  _contextListenerImpl = new ContextListenerImpl(
    apiKey: config.get('last_fm_api_key'),
  );
  _contextReader.subscribe(query, _contextListenerImpl.getHandle());
}
