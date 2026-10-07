#include "include/flutter_pcm/flutter_pcm_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

#include <cstring>

#include "pcm_player.h"

#define FLUTTER_PCM_PLUGIN(obj)                                                \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), flutter_pcm_plugin_get_type(),            \
                              FlutterPcmPlugin))

struct _FlutterPcmPlugin {
  GObject parent_instance;

  FlMethodChannel *channel;
  flutter_pcm::PcmPlayer *pcm_player;
};

G_DEFINE_TYPE(FlutterPcmPlugin, flutter_pcm_plugin, g_object_get_type())

namespace {
using flutter_pcm::ByteVectorPtr;

// Method channel calls must be made on the GTK main thread, while samples and
// volume changes are requested from the audio threads. These structs carry an
// invocation over to the main thread through an idle source.

// Holds a ref on the plugin, so the reply can be handed to its player
struct SampleRequest {
  FlutterPcmPlugin *plugin;
  uint32_t max_frames;

  ~SampleRequest() { g_object_unref(plugin); }
};

struct VolumeNotification {
  FlMethodChannel *channel;
  double volume;

  ~VolumeNotification() { g_object_unref(channel); }
};

struct PlayingNotification {
  FlMethodChannel *channel;
  bool playing;

  ~PlayingNotification() { g_object_unref(channel); }
};

void sample_response_cb(GObject *object, GAsyncResult *result,
                        gpointer user_data) {
  std::unique_ptr<SampleRequest> request(
      static_cast<SampleRequest *>(user_data));

  g_autoptr(GError) error = nullptr;
  g_autoptr(FlMethodResponse) response = fl_method_channel_invoke_method_finish(
      FL_METHOD_CHANNEL(object), result, &error);
  FlValue *value =
      response ? fl_method_response_get_result(response, &error) : nullptr;

  ByteVectorPtr samples;
  if (value && fl_value_get_type(value) == FL_VALUE_TYPE_UINT8_LIST) {
    const uint8_t *data = fl_value_get_uint8_list(value);
    samples = std::make_unique<std::vector<uint8_t>>(
        data, data + fl_value_get_length(value));
  }

  // The player is gone if the plugin was disposed meanwhile
  if (request->plugin->pcm_player) {
    request->plugin->pcm_player->OnSamples(std::move(samples));
  }
}

gboolean send_sample_request(gpointer user_data) {
  auto request = static_cast<SampleRequest *>(user_data);
  if (!request->plugin->channel) {
    delete request;
    return G_SOURCE_REMOVE;
  }
  g_autoptr(FlValue) args = fl_value_new_int(request->max_frames);
  fl_method_channel_invoke_method(request->plugin->channel, "getSamples", args,
                                  nullptr, sample_response_cb, request);
  return G_SOURCE_REMOVE;
}

gboolean send_volume_notification(gpointer user_data) {
  std::unique_ptr<VolumeNotification> notification(
      static_cast<VolumeNotification *>(user_data));
  g_autoptr(FlValue) args = fl_value_new_float(notification->volume);
  fl_method_channel_invoke_method(notification->channel, "onVolumeChanged",
                                  args, nullptr, nullptr, nullptr);
  return G_SOURCE_REMOVE;
}

gboolean send_playing_notification(gpointer user_data) {
  std::unique_ptr<PlayingNotification> notification(
      static_cast<PlayingNotification *>(user_data));
  g_autoptr(FlValue) args = fl_value_new_bool(notification->playing);
  fl_method_channel_invoke_method(notification->channel, "onPlayingChanged",
                                  args, nullptr, nullptr, nullptr);
  return G_SOURCE_REMOVE;
}


void call_sample_callback(FlutterPcmPlugin *plugin, uint32_t max_frames) {
  auto request =
      new SampleRequest{FLUTTER_PCM_PLUGIN(g_object_ref(plugin)), max_frames};
  g_idle_add_full(G_PRIORITY_DEFAULT, send_sample_request, request, nullptr);
}

void call_volume_callback(FlMethodChannel *channel, float volume) {
  auto notification =
      new VolumeNotification{FL_METHOD_CHANNEL(g_object_ref(channel)), volume};
  g_idle_add_full(G_PRIORITY_DEFAULT, send_volume_notification, notification,
                  nullptr);
}

void call_playing_callback(FlMethodChannel *channel, bool playing) {
  auto notification = new PlayingNotification{
      FL_METHOD_CHANNEL(g_object_ref(channel)), playing};
  g_idle_add_full(G_PRIORITY_DEFAULT, send_playing_notification, notification,
                  nullptr);
}

FlMethodResponse *bad_arguments(const gchar *method) {
  g_autofree gchar *message =
      g_strdup_printf("Bad arguments for %s", method);
  return FL_METHOD_RESPONSE(
      fl_method_error_response_new("bad_arguments", message, nullptr));
}

FlMethodResponse *setup(FlutterPcmPlugin *self) {
  auto setup_res = self->pcm_player->Setup();
  if (!setup_res.has_value()) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "setup_failed", setup_res.error().c_str(), nullptr));
  }

  const auto &audio_format = setup_res.value();
  g_autoptr(FlValue) result = fl_value_new_map();
  fl_value_set_string_take(result, "frequency",
                           fl_value_new_int(audio_format.frequency));
  fl_value_set_string_take(result, "channels",
                           fl_value_new_int(audio_format.channels));
  fl_value_set_string_take(
      result, "sampleFormat",
      fl_value_new_string(
          flutter_pcm::sample_format_name(audio_format.sample_format)));
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}
} // namespace

// Called when a method call is received from Flutter.
static void flutter_pcm_plugin_handle_method_call(FlutterPcmPlugin *self,
                                                  FlMethodCall *method_call) {
  g_autoptr(FlMethodResponse) response = nullptr;

  const gchar *method = fl_method_call_get_name(method_call);
  FlValue *args = fl_method_call_get_args(method_call);

  if (strcmp(method, "setup") == 0) {
    response = setup(self);
  } else if (strcmp(method, "setPlaying") == 0) {
    if (fl_value_get_type(args) == FL_VALUE_TYPE_BOOL) {
      self->pcm_player->set_play_state(fl_value_get_bool(args)
                                           ? flutter_pcm::PcmPlayer::kPlaying
                                           : flutter_pcm::PcmPlayer::kPaused);
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    } else {
      response = bad_arguments(method);
    }
  } else if (strcmp(method, "setVolume") == 0) {
    if (fl_value_get_type(args) == FL_VALUE_TYPE_FLOAT) {
      self->pcm_player->set_volume((float)fl_value_get_float(args));
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    } else {
      response = bad_arguments(method);
    }
  } else if (strcmp(method, "getVolume") == 0) {
    g_autoptr(FlValue) result =
        fl_value_new_float(self->pcm_player->get_volume());
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
}

static void flutter_pcm_plugin_dispose(GObject *object) {
  FlutterPcmPlugin *self = FLUTTER_PCM_PLUGIN(object);

  // Stops the audio threads, so nothing uses the channel after this
  delete self->pcm_player;
  self->pcm_player = nullptr;
  g_clear_object(&self->channel);

  G_OBJECT_CLASS(flutter_pcm_plugin_parent_class)->dispose(object);
}

static void flutter_pcm_plugin_class_init(FlutterPcmPluginClass *klass) {
  G_OBJECT_CLASS(klass)->dispose = flutter_pcm_plugin_dispose;
}

static void flutter_pcm_plugin_init(FlutterPcmPlugin *self) {}

static void method_call_cb(FlMethodChannel *channel, FlMethodCall *method_call,
                           gpointer user_data) {
  FlutterPcmPlugin *plugin = FLUTTER_PCM_PLUGIN(user_data);
  flutter_pcm_plugin_handle_method_call(plugin, method_call);
}

void flutter_pcm_plugin_register_with_registrar(FlPluginRegistrar *registrar) {
  FlutterPcmPlugin *plugin = FLUTTER_PCM_PLUGIN(
      g_object_new(flutter_pcm_plugin_get_type(), nullptr));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  plugin->channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            "flutter_pcm", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      plugin->channel, method_call_cb, g_object_ref(plugin), g_object_unref);

  // Shown as the application name in the system mixer
  const gchar *app_name = g_get_application_name();
  if (!app_name) {
    app_name = "flutter_pcm";
  }

  FlMethodChannel *channel = plugin->channel;
  plugin->pcm_player = new flutter_pcm::PcmPlayer(
      app_name,
      [plugin](uint32_t n) { call_sample_callback(plugin, n); },
      [channel](float v) { call_volume_callback(channel, v); },
      [channel](bool p) { call_playing_callback(channel, p); });

  g_object_unref(plugin);
}
