// Copyright 2016 The Fuchsia Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "topaz/runtime/dart_runner/dart_application_runner.h"

#include <dlfcn.h>
#include <fcntl.h>
#include <zircon/dlfcn.h>
#include <zircon/status.h>
#include <zx/process.h>

#include <thread>
#include <utility>

#include "topaz/runtime/dart_runner/dart_application_controller.h"
#include "topaz/runtime/dart_runner/embedder/snapshot.h"
#include "third_party/dart/runtime/bin/embedded_dart_io.h"
#include "lib/fxl/arraysize.h"
#include "lib/fsl/tasks/message_loop.h"
#include "lib/fsl/vmo/file.h"
#include "lib/fsl/vmo/sized_vmo.h"
#include "lib/fsl/vmo/vector.h"
#include "lib/tonic/dart_microtask_queue.h"
#include "lib/tonic/dart_state.h"

namespace dart_content_handler {
namespace {

const char* kDartVMArgs[] = {
// clang-format off
#if defined(AOT_RUNTIME)
    "--precompilation",
#else
    "--enable_mirrors=false",
    "--await_is_keyword",
#endif
    // clang-format on
};

constexpr char kServiceRootPath[] = "/svc";

void IsolateShutdownCallback(void* callback_data) {
  fsl::MessageLoop::GetCurrent()->SetAfterTaskCallback(nullptr);
  tonic::DartMicrotaskQueue::GetForCurrentThread()->Destroy();
  fsl::MessageLoop::GetCurrent()->QuitNow();
}

void IsolateCleanupCallback(void* callback_data) {
  tonic::DartState* dart_state = static_cast<tonic::DartState*>(callback_data);
  delete dart_state;
}

fdio_ns_t* SetupNamespace(app::FlatNamespacePtr* flat_namespace) {
  app::FlatNamespacePtr& flat = *flat_namespace;
  fdio_ns_t* fdio_namespc = nullptr;
  zx_status_t status = fdio_ns_create(&fdio_namespc);
  if (status != ZX_OK) {
    FXL_LOG(ERROR) << "Failed to create namespace";
    return nullptr;
  }
  for (size_t i = 0; i < flat->paths.size(); ++i) {
    if (flat->paths[i] == kServiceRootPath) {
      // Ownership of /svc goes to the ApplicationContext created below.
      continue;
    }
    zx::channel dir = std::move(flat->directories[i]);
    zx_handle_t dir_handle = dir.release();
    const char* path = flat->paths[i].data();
    status = fdio_ns_bind(fdio_namespc, path, dir_handle);
    if (status != ZX_OK) {
      FXL_LOG(ERROR) << "Failed to bind " << flat->paths[i] << " to namespace";
      zx_handle_close(dir_handle);
      fdio_ns_destroy(fdio_namespc);
      return nullptr;
    }
  }
  return fdio_namespc;
}

#if defined(AOT_RUNTIME)

bool ExtractSnapshots(fdio_ns_t* namespc,
                      const fsl::SizedVmoTransportPtr& bundle,
                      const uint8_t*& isolate_snapshot_data,
                      const uint8_t*& isolate_snapshot_instructions,
                      const uint8_t*& script_snapshot,
                      intptr_t* script_snapshot_len) {
  fxl::UniqueFD root_dir(fdio_ns_opendir(namespc));
  if (!root_dir.is_valid()) {
    FXL_LOG(ERROR) << "Failed to open namespace";
    return false;
  }

  fxl::UniqueFD dylib_file(openat(root_dir.get(), "pkg/data/libapp.so", O_RDONLY));
  if (!dylib_file.is_valid()) {
    FXL_LOG(ERROR) << "Failed to open dylib at pkg/data/libapp.so";
    return false;
  }

  fsl::SizedVmo dylib;
  if (!fsl::VmoFromFd(std::move(dylib_file), &dylib)) {
    FXL_LOG(ERROR) << "Failed to map dylib from pkg/data/libapp.so";
    return false;
  }

  dlerror();
  void* lib = dlopen_vmo(dylib.vmo().get(), RTLD_LAZY);
  // TODO(rmacnak): It is currently not safe to unload this library when the
  // isolate shuts down because it may be backing part of the vm isolate's heap.
  if (lib == NULL) {
    FXL_LOG(ERROR) << "dlopen failed: " << dlerror();
    return false;
  }

  isolate_snapshot_data =
      reinterpret_cast<const uint8_t*>(dlsym(lib, "_kDartIsolateSnapshotData"));
  if (isolate_snapshot_data == NULL) {
    FXL_LOG(ERROR) << "dlsym(_kDartIsolateSnapshotData) failed: " << dlerror();
    return false;
  }
  isolate_snapshot_instructions = reinterpret_cast<const uint8_t*>(
      dlsym(lib, "_kDartIsolateSnapshotInstructions"));
  if (isolate_snapshot_instructions == NULL) {
    FXL_LOG(ERROR) << "dlsym(_kDartIsolateSnapshotInstructions) failed: "
                   << dlerror();
    return false;
  }

  return true;
}

#elif defined(SCRIPT_RUNTIME)

bool ExtractSnapshots(fdio_ns_t* namespc,
                      const fsl::SizedVmoTransportPtr& bundle,
                      const uint8_t*& isolate_snapshot_data,
                      const uint8_t*& isolate_snapshot_instructions,
                      const uint8_t*& script_snapshot,
                      intptr_t* script_snapshot_len) {
  if (!fsl::SizedVmo::IsSizeValid(bundle->vmo, bundle->size)) {
    FXL_LOG(ERROR) << "bundle size is not valid.";
    return false;
  }

  isolate_snapshot_data = dart_content_handler::isolate_snapshot_buffer;
  isolate_snapshot_instructions = NULL;

  uintptr_t addr;
  zx_status_t status = zx::vmar::root_self().map(
      0, bundle->vmo, 0, bundle->size, ZX_VM_FLAG_PERM_READ, &addr);
  if (status != ZX_OK) {
    FXL_LOG(ERROR) << "bundle map failed: " << zx_status_get_string(status);
    return false;
  }

  script_snapshot = reinterpret_cast<uint8_t*>(addr);
  *script_snapshot_len = bundle->size;
  return true;
}

#else  // !defined(AOT_RUNTIME)

bool ExtractSnapshots(fdio_ns_t* namespc,
                      const fsl::SizedVmoTransportPtr& bundle,
                      const uint8_t*& isolate_snapshot_data,
                      const uint8_t*& isolate_snapshot_instructions,
                      const uint8_t*& script_snapshot,
                      intptr_t* script_snapshot_len) {
  fxl::UniqueFD root_dir(fdio_ns_opendir(namespc));
  if (!root_dir.is_valid()) {
    FXL_LOG(ERROR) << "Failed to open namespace";
    return false;
  }

  fxl::UniqueFD snapshot_file(openat(root_dir.get(), "pkg/data/snapshot_blob.bin", O_RDONLY));
  if (!snapshot_file.is_valid()) {
    FXL_LOG(ERROR) << "Failed to open snapshot at pkg/data/snapshot_blob.bin";
    return false;
  }

  fsl::SizedVmo snapshot;
  if (!fsl::VmoFromFd(std::move(snapshot_file), &snapshot)) {
    FXL_LOG(ERROR) << "Failed to map snapshot from pkg/data/snapshot_blob.bin";
    return false;
  }

  isolate_snapshot_data = dart_content_handler::isolate_snapshot_buffer;
  isolate_snapshot_instructions = NULL;

  uintptr_t addr;
  zx_status_t status = zx::vmar::root_self().map(
      0, snapshot.vmo(), 0, snapshot.size(), ZX_VM_FLAG_PERM_READ, &addr);
  if (status != ZX_OK) {
    FXL_LOG(ERROR) << "bundle map failed: " << zx_status_get_string(status);
    return false;
  }

  script_snapshot = reinterpret_cast<uint8_t*>(addr);
  *script_snapshot_len = snapshot.size();
  return true;
}

#endif  // !defined(AOT_RUNTIME)

std::string GetLabelFromURL(const std::string& url) {
  size_t last_slash = url.rfind('/');
  if (last_slash == std::string::npos || last_slash + 1 == url.length())
    return url;
  return url.substr(last_slash + 1);
}

void RunApplication(
    app::ApplicationPackagePtr application,
    app::ApplicationStartupInfoPtr startup_info,
    ::fidl::InterfaceRequest<app::ApplicationController> controller) {
  std::string url = std::move(application->resolved_url);

  // Name the process and bundle after the url of the application being
  // launched. Name the bundle before extract snapshot for the name to carry to
  // the mappings.
  std::string label = "dart:" + GetLabelFromURL(url);
  zx::process::self().set_property(ZX_PROP_NAME, label.c_str(), label.size());
  if (application->data)
    application->data->vmo.set_property(ZX_PROP_NAME, label.c_str(), label.size());

  fdio_ns_t* namespc = SetupNamespace(&startup_info->flat_namespace);
  if (!namespc)
      return;

  const uint8_t* isolate_snapshot_data = NULL;
  const uint8_t* isolate_snapshot_instructions = NULL;
  const uint8_t* script_snapshot = NULL;
  intptr_t script_snapshot_len = 0;
  if (!ExtractSnapshots(namespc,
                        application->data,
                        isolate_snapshot_data,
                        isolate_snapshot_instructions,
                        script_snapshot,
                        &script_snapshot_len)) {
    return;
  }

  fsl::MessageLoop loop;

  DartApplicationController app(
      namespc, isolate_snapshot_data, isolate_snapshot_instructions,
#if !defined(AOT_RUNTIME)
      script_snapshot, script_snapshot_len,
#endif  // !defined(AOT_RUNTIME)
      std::move(startup_info), std::move(url), std::move(controller));

  if (app.CreateIsolate()) {
    loop.task_runner()->PostTask([&loop, &app] {
      if (!app.Main())
        loop.PostQuitTask();
    });

    loop.Run();
    app.SendReturnCode();
  }
}

}  // namespace

DartApplicationRunner::DartApplicationRunner(
    fidl::InterfaceRequest<app::ApplicationRunner> app_runner)
    : binding_(this, std::move(app_runner)) {
  dart::bin::BootstrapDartIo();

  // TODO(abarth): Make checked mode configurable.
  FXL_CHECK(Dart_SetVMFlags(arraysize(kDartVMArgs), kDartVMArgs));

  Dart_InitializeParams params = {};
  params.version = DART_INITIALIZE_PARAMS_CURRENT_VERSION;
#if defined(AOT_RUNTIME)
  params.vm_snapshot_data = ::_kDartVmSnapshotData;
  params.vm_snapshot_instructions = ::_kDartVmSnapshotInstructions;
#else
  params.vm_snapshot_data = dart_content_handler::vm_isolate_snapshot_buffer;
  params.vm_snapshot_instructions = NULL;
#endif
  params.shutdown = IsolateShutdownCallback;
  params.cleanup = IsolateCleanupCallback;
  char* error = Dart_Initialize(&params);
  if (error)
    FXL_LOG(FATAL) << "Dart_Initialize failed: " << error;
}

DartApplicationRunner::~DartApplicationRunner() {
  char* error = Dart_Cleanup();
  if (error)
    FXL_LOG(FATAL) << "Dart_Cleanup failed: " << error;
}

void DartApplicationRunner::StartApplication(
    app::ApplicationPackagePtr application,
    app::ApplicationStartupInfoPtr startup_info,
    ::fidl::InterfaceRequest<app::ApplicationController> controller) {
  std::thread thread(RunApplication, std::move(application),
                     std::move(startup_info), std::move(controller));
  thread.detach();
}

}  // namespace dart_content_handler