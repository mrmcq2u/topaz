// Copyright 2017 The Fuchsia Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:config/config.dart';
import 'package:lib.app.dart/app.dart';
import 'package:lib.context.fidl/context_reader.fidl.dart';
import 'package:lib.context.fidl/metadata.fidl.dart';
import 'package:lib.context.fidl/value.fidl.dart';
import 'package:lib.context.fidl/value_type.fidl.dart';
import 'package:lib.decomposition.dart/decomposition.dart';
import 'package:lib.fidl.dart/bindings.dart';
import 'package:lib.logging/logging.dart';
import 'package:lib.suggestion.fidl/proposal.fidl.dart';
import 'package:lib.suggestion.fidl/proposal_publisher.fidl.dart';
import 'package:lib.suggestion.fidl/suggestion_display.fidl.dart';
import 'package:meta/meta.dart';
import 'package:music_api/api.dart';
import 'package:music_models/music_models.dart';

/// The Music Artist Agent subscribes to any context entities of the
/// music/artist type and proposes a Spotify suggestion if Spotify recognizes
/// the artist.

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
  final ContextListenerBinding _binding = new ContextListenerBinding();

  final Api _api;

  /// Constructor
  ContextListenerImpl({
    @required String clientId,
    @required String clientSecret,
  })
      : assert(clientId != null),
        assert(clientSecret != null),
        _api = new Api(
          clientId: clientId,
          clientSecret: clientSecret,
        );

  /// Gets the [InterfaceHandle]
  ///
  /// The returned handle should only be used once.
  InterfaceHandle<ContextListener> getHandle() => _binding.wrap(this);

  @override
  Future<Null> onContextUpdate(ContextUpdate result) async {
    for (ContextValue value in result.values[_kMusicArtistType]) {
      try {
        Map<String, dynamic> entity = JSON.decode(value.content);
        log.fine('artist update: ${entity['name']}');
        List<Artist> artists = await _api.searchArtists(
          entity['name'],
        );
        if (artists != null && artists.isNotEmpty) {
          log.fine('found artist for: ${entity['name']}');
          _createProposal(artists.first);
        } else {
          log.fine('no artist found for: ${entity['name']}');
        }
      } on Exception {
        return;
      }
    }
  }

  /// Creates a proposal for the given Spotify artist
  void _createProposal(Artist artist) {
    String headline = 'Listen to ${artist.name}';

    final Uri arg = new Uri(
      scheme: 'spotify',
      host: 'artist',
      pathSegments: <String>[artist.id],
    );

    Proposal proposal = new Proposal()
      ..id = 'Spotify Artist: ${artist.id}'
      ..display = (new SuggestionDisplay()
        ..headline = headline
        ..subheadline = 'powered by Spotify'
        ..details = ''
        ..color = 0xFFFF0080
        ..iconUrls = const <String>[]
        ..imageType = SuggestionImageType.other
        ..imageUrl = artist.defaultArtworkUrl ?? ''
        ..annoyance = AnnoyanceType.none)
      ..onSelected = <Action>[
        new Action()
          ..createStory = (new CreateStory()
            ..moduleId = 'file:///system/apps/music_artist'
            ..initialData =
                JSON.encode(<String, dynamic>{'view': decomposeUri(arg)}))
      ];

    log.fine('proposing artist suggestion');
    _proposalPublisher.propose(proposal);
  }
}

Future<Null> main(List<dynamic> args) async {
  setupLogger();

  Config config = await Config.read('/system/data/modules/config.json')
    ..validate(<String>['spotify_client_id', 'spotify_client_secret']);
  connectToService(_context.environmentServices, _contextReader.ctrl);
  connectToService(_context.environmentServices, _proposalPublisher.ctrl);
  ContextSelector selector = new ContextSelector()
    ..type = ContextValueType.entity
    ..meta = new ContextMetadata();
  selector.meta.story = new StoryMetadata();
  selector.meta.story.focused = new FocusedState();
  selector.meta.story.focused.state = FocusedStateState.focused;
  selector.meta.entity = new EntityMetadata();
  selector.meta.entity.type = <String>[_kMusicArtistType];

  ContextQuery query = new ContextQuery()
    ..selector = <String, ContextSelector>{_kMusicArtistType: selector};
  _contextListenerImpl = new ContextListenerImpl(
    clientId: config.get('spotify_client_id'),
    clientSecret: config.get('spotify_client_secret'),
  );
  _contextReader.subscribe(query, _contextListenerImpl.getHandle());
}