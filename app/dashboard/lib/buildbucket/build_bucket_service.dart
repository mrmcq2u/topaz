// Copyright 2017 The Fuchsia Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:buildbucket/buildbucket.dart';
import 'package:http/http.dart' as http;

import 'package:dashboard/service/build_info.dart';
import 'package:dashboard/service/build_service.dart';

/// A [BuildService] implementation that fetches info from the build_bucket api.
class BuildBucketService implements BuildService {
  static const List<String> _allBuckets = const <String>[
    'luci.fuchsia.continuous',
  ];

  final BuildbucketApi _api;

  /// Initializing constructor.
  BuildBucketService([BuildbucketApi api])
      : _api = api ?? new BuildbucketApi(new http.Client());

  @override
  Stream<BuildInfo> getBuildByName(String buildName) async* {
    final ApiSearchResponseMessage response = await _api.search(
      bucket: _allBuckets,
      tag: <String>['builder:$buildName'],
      status: 'COMPLETED',
    );

    if (response.error != null) {
      throw new BuildServiceException(response.error.toJson().toString());
    }

    yield _createBuildInfo(response.builds.first);
  }

  /// Fetch builds with names from [buildNames].
  ///
  /// On buildbucket, this given build name corresponds to the name of the
  /// builder which is derived from the build response's tags.
  @override
  Stream<List<BuildInfo>> getBuildsByName(List<String> buildNames) async* {
    yield await Future
        .wait(buildNames.map((String name) => getBuildByName(name).first));
  }

  /// Returns the "name" of the build if it is present. Otherwise, null.
  String _getBuildName(ApiCommonBuildMessage build) {
    return build.tags?.isNotEmpty == true
        ? build.tags.first.split(':')[1]
        : null;
  }

  String _getBuildType(ApiCommonBuildMessage build) {
    return _getBuildName(build).split('-').first;
  }

  BuildInfo _createBuildInfo(ApiCommonBuildMessage build) => new BuildInfo(
        bucket: build.bucket,
        name: _getBuildName(build),
        result: build.result,
        status: build.status,
        type: _getBuildType(build),
        url: build.url,
      );
}