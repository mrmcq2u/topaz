// Copyright 2018 The Fuchsia Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:lib.app.dart/app.dart';
import 'package:lib.widgets/modular.dart';

import 'src/modular/conversation_info_module_model.dart';
import 'src/modular/conversation_info_screen.dart';

void main() {
  ModuleWidget<ConversationInfoModuleModel> moduleWidget =
      new ModuleWidget<ConversationInfoModuleModel>(
    applicationContext: new ApplicationContext.fromStartupInfo(),
    moduleModel: new ConversationInfoModuleModel(),
    child: new MaterialApp(
      home: const ConversationInfoScreen(),
    ),
  )..advertise();

  runApp(moduleWidget);
}