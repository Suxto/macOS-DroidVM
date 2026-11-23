// CPU scanout for crosvm's Android display FFI. The receiving Surface belongs to DroidVM.
#include <android/binder_ibinder.h>
#include <android/binder_parcel.h>
#include <android/log.h>
#include <android/native_window.h>
#include <android/native_window_aidl.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>

#include <array>
#include <cerrno>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

struct AndroidDisplayContext;

struct AndroidDisplaySurface {
    int32_t width = 0, height = 0;
    ANativeWindow* target = nullptr;
    ANativeWindow* locked = nullptr;
    AndroidDisplayContext* buffer_owner = nullptr;
    ANativeWindow_Buffer buffer{};
    bool geometry_dirty = true;
    int display_error = 0;
    unsigned frames = 0;
    std::vector<uint32_t> latest_frame;
    ~AndroidDisplaySurface() {
        if (locked) {
            ANativeWindow_unlockAndPost(locked);
            ANativeWindow_release(locked);
        }
        if (target) ANativeWindow_release(target);
    }
};

struct DisplayState {
    std::mutex mutex;
    std::array<AndroidDisplaySurface, 2> surfaces;
    int cursor = -1;
    std::chrono::steady_clock::time_point last_gpu_frame{};
    bool drawing_fallback = true;
    ~DisplayState() { if (cursor >= 0) close(cursor); }
};

struct AndroidDisplayContext {
    std::shared_ptr<DisplayState> state;
    bool boot = false;
    AIBinder* service = nullptr;
    ~AndroidDisplayContext() { if (service) AIBinder_decStrong(service); }
};

static bool configure_window(AndroidDisplaySurface& surface) {
    if (!surface.geometry_dirty) return true;
    const int result = ANativeWindow_setBuffersGeometry(surface.target, surface.width,
        surface.height, WINDOW_FORMAT_RGBA_8888);
    if (result != 0) {
        if (surface.display_error != result)
            __android_log_print(ANDROID_LOG_WARN, "K27NativeDisplay", "setBuffersGeometry: %d", result);
        surface.display_error = result;
        return false;
    }
    surface.geometry_dirty = false;
    return true;
}

// Called with the state mutex held. A new consumer needs a frame even if the
// guest has no damage to flush while its desktop is idle.
static void draw_latest_frame(AndroidDisplaySurface& surface) {
    if (!surface.target || surface.target == surface.locked || surface.latest_frame.empty() ||
        !configure_window(surface)) return;
    ANativeWindow_Buffer buffer{};
    const int result = ANativeWindow_lock(surface.target, &buffer, nullptr);
    if (result != 0) {
        __android_log_print(ANDROID_LOG_WARN, "K27NativeDisplay", "replay lock: %d", result);
        return;
    }
    if (buffer.width == surface.width && buffer.height == surface.height &&
        buffer.format == WINDOW_FORMAT_RGBA_8888) {
        auto* pixels = static_cast<uint32_t*>(buffer.bits);
        for (int y = 0; y < buffer.height; ++y)
            std::memcpy(pixels + y * buffer.stride, surface.latest_frame.data() + y * buffer.width,
                static_cast<size_t>(buffer.width) * sizeof(uint32_t));
        __android_log_print(ANDROID_LOG_INFO, "K27NativeDisplay", "replayed frame %u", surface.frames);
    }
    const int posted = ANativeWindow_unlockAndPost(surface.target);
    if (posted != 0)
        __android_log_print(ANDROID_LOG_WARN, "K27NativeDisplay", "replay post: %d", posted);
}

static binder_status_t transact(AIBinder* binder, transaction_code_t code,
                                const AParcel* in, AParcel* out) {
    auto& state = **static_cast<std::shared_ptr<DisplayState>*>(AIBinder_getUserData(binder));
    std::lock_guard lock(state.mutex);
    auto read_cursor = [&](bool& cursor) { return AParcel_readBool(in, &cursor); };
    std::unique_ptr<AStatus, decltype(&AStatus_delete)> ok(AStatus_newOk(), AStatus_delete);
    switch (code) {
    case FIRST_CALL_TRANSACTION: {  // setSurface(Surface, boolean)
        ANativeWindow* window = nullptr;
        int32_t present = 0;
        auto result = AParcel_readInt32(in, &present);
        if (result != STATUS_OK || !present) return STATUS_BAD_VALUE;
        result = ANativeWindow_readFromParcel(in, &window);
        if (result != STATUS_OK || !window) return STATUS_BAD_VALUE;
        bool cursor = false;
        result = read_cursor(cursor);
        if (result != STATUS_OK) {
            ANativeWindow_release(window);
            return result;
        }
        auto& surface = state.surfaces[cursor];
        if (surface.target) ANativeWindow_release(surface.target);
        surface.target = window;
        surface.geometry_dirty = true;
        surface.display_error = 0;
        if (!cursor)
            __android_log_print(ANDROID_LOG_INFO, "K27NativeDisplay", "screen attached at frame %u", surface.frames);
        draw_latest_frame(surface);
        break;
    }
    case FIRST_CALL_TRANSACTION + 1: {  // setCursorStream
        int fd = -1;
        auto result = AParcel_readParcelFileDescriptor(in, &fd);
        if (result != STATUS_OK || fd < 0) return STATUS_BAD_VALUE;
        const int flags = fcntl(fd, F_GETFL);
        if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
            close(fd);
            return STATUS_BAD_VALUE;
        }
        if (state.cursor >= 0) close(state.cursor);
        state.cursor = fd;
        break;
    }
    case FIRST_CALL_TRANSACTION + 2: {  // removeSurface
        bool cursor = false;
        auto result = read_cursor(cursor);
        if (result != STATUS_OK) return result;
        auto& surface = state.surfaces[cursor];
        if (surface.target) ANativeWindow_release(surface.target);
        surface.target = nullptr;
        break;
    }
    case FIRST_CALL_TRANSACTION + 3:  // saveFrameForSurface: frame is retained on post
    case FIRST_CALL_TRANSACTION + 4: {  // drawSavedFrameForSurface
        bool cursor = false;
        const auto result = read_cursor(cursor);
        if (result != STATUS_OK) return result;
        if (code == FIRST_CALL_TRANSACTION + 4) draw_latest_frame(state.surfaces[cursor]);
        break;
    }
    case FIRST_CALL_TRANSACTION + 5: {  // getDisplayConfig
        auto result = AParcel_writeStatusHeader(out, ok.get());
        if (result != STATUS_OK) return result;
        const auto& screen = state.surfaces[0];
        if (screen.width == 0 || screen.height == 0) return AParcel_writeInt32(out, 0);
        for (int32_t value : {1, 20, screen.width, screen.height, 160, 60}) {
            result = AParcel_writeInt32(out, value);
            if (result != STATUS_OK) return result;
        }
        return STATUS_OK;
    }
    default:
        return STATUS_UNKNOWN_TRANSACTION;
    }
    return AParcel_writeStatusHeader(out, ok.get());
}

extern "C" AndroidDisplayContext* create_android_display_context(
    const char* name, void (*error)(const char*)) {
    static auto* clazz = AIBinder_Class_define("android.crosvm.ICrosvmAndroidDisplayService",
        [](void* state) -> void* { return new std::shared_ptr<DisplayState>(
            *static_cast<std::shared_ptr<DisplayState>*>(state)); },
        [](void* state) { delete static_cast<std::shared_ptr<DisplayState>*>(state); },
        transact);
    using Register = binder_status_t (*)(AIBinder*, const char*);
    using Start = void (*)();
    static const auto add_service = reinterpret_cast<Register>(dlsym(RTLD_DEFAULT, "AServiceManager_addService"));
    static const auto start_pool = reinterpret_cast<Start>(dlsym(RTLD_DEFAULT, "ABinderProcess_startThreadPool"));
    auto context = std::make_unique<AndroidDisplayContext>();
    std::string base(name);
    if (base.size() > 5 && base.compare(base.size() - 5, 5, "#boot") == 0) {
        context->boot = true;
        base.resize(base.size() - 5);
    }
    {
        static std::mutex mutex;
        static std::map<std::string, std::weak_ptr<DisplayState>> states;
        std::lock_guard lock(mutex);
        auto& slot = states[base];
        context->state = slot.lock();
        if (!context->state) {
            context->state = std::make_shared<DisplayState>();
            slot = context->state;
        }
    }
    if (context->boot) return context.release();
    if (clazz && add_service && start_pool) {
        context->service = AIBinder_new(clazz, &context->state);
        if (context->service && add_service(context->service, name) == STATUS_OK) {
            start_pool();
            return context.release();
        }
    }
    if (error) error("Could not register the Android display Binder service");
    return context.release();
}

extern "C" void destroy_android_display_context(AndroidDisplayContext* context) {
    delete context;
}

extern "C" AndroidDisplaySurface* create_android_surface(AndroidDisplayContext* context,
    uint32_t width, uint32_t height, bool cursor) {
    if (width == 0 || height == 0 || width > INT32_MAX || height > INT32_MAX) return nullptr;
    std::lock_guard lock(context->state->mutex);
    auto& surface = context->state->surfaces[cursor];
    if (context->boot && surface.width != 0) return &surface;
    if (surface.width != static_cast<int32_t>(width) || surface.height != static_cast<int32_t>(height))
        surface.latest_frame.clear();
    surface.width = static_cast<int32_t>(width);
    surface.height = static_cast<int32_t>(height);
    surface.geometry_dirty = true;
    return &surface;
}

extern "C" void destroy_android_surface(AndroidDisplayContext*, AndroidDisplaySurface*) {}

extern "C" bool get_android_surface_buffer(AndroidDisplayContext* context,
    AndroidDisplaySurface* surface, ANativeWindow_Buffer* buffer) {
    ANativeWindow* window;
    {
        std::lock_guard lock(context->state->mutex);
        if (!surface->target || surface->locked) return false;
        // The guest refreshes an idle virtio scanout once a second. If that
        // source stops delivering, simplefb carries the guest's CPU copies.
        if (context->boot && std::chrono::steady_clock::now() - context->state->last_gpu_frame <
                std::chrono::milliseconds(1500)) return false;
        window = surface->target;
        if (!configure_window(*surface)) return false;
        ANativeWindow_acquire(window);
        surface->locked = window;
        surface->buffer_owner = context;
    }
    const int result = ANativeWindow_lock(window, buffer, nullptr);
    if (result != 0) {
        std::lock_guard lock(context->state->mutex);
        if (surface->target == window && surface->display_error != result) {
            __android_log_print(ANDROID_LOG_WARN, "K27NativeDisplay", "scanout lock: %d", result);
            surface->display_error = result;
        }
        surface->locked = nullptr;
        surface->buffer_owner = nullptr;
        ANativeWindow_release(window);
        return false;
    }
    surface->buffer = *buffer;
    return true;
}

extern "C" void post_android_surface_buffer(AndroidDisplayContext* context,
    AndroidDisplaySurface* surface) {
    ANativeWindow* window;
    {
        std::lock_guard lock(context->state->mutex);
        // The boot and GPU contexts share this slot during handoff. Each may
        // only post the buffer it locked.
        if (surface->buffer_owner != context) return;
        window = surface->locked;
    }
    if (!window) return;
    const bool main = surface == &context->state->surfaces[0];
    const auto& buffer = surface->buffer;
    auto* pixels = static_cast<uint32_t*>(buffer.bits);
    unsigned colored = 0;
    if (main) {
        for (int y = 0; y < buffer.height; ++y) {
            auto* row = pixels + y * buffer.stride;
            for (int x = 0; x < buffer.width; ++x) row[x] |= 0xff000000u;
            if (y % 8 == 0)
                for (int x = 0; x < buffer.width; x += 8) colored += (row[x] & 0xffffffu) != 0;
        }
        if (++surface->frames <= 3 || surface->frames % 256 == 0)
            __android_log_print(ANDROID_LOG_INFO, "K27NativeDisplay", "%s frame=%u sampled_rgb=%u format=%d",
                                context->boot ? "boot" : "gpu", surface->frames, colored, buffer.format);
    }
    {
        std::lock_guard lock(context->state->mutex);
        if (buffer.width == surface->width && buffer.height == surface->height &&
            buffer.format == WINDOW_FORMAT_RGBA_8888) {
            const size_t width = buffer.width;
            surface->latest_frame.resize(width * static_cast<size_t>(buffer.height));
            for (int y = 0; y < buffer.height; ++y)
                std::memcpy(surface->latest_frame.data() + y * width, pixels + y * buffer.stride,
                    width * sizeof(uint32_t));
        }
    }
    const int result = ANativeWindow_unlockAndPost(window);
    {
        std::lock_guard lock(context->state->mutex);
        if (main && result == 0) {
            auto& state = *context->state;
            if (!context->boot) state.last_gpu_frame = std::chrono::steady_clock::now();
            if (state.drawing_fallback != context->boot) {
                state.drawing_fallback = context->boot;
                __android_log_print(ANDROID_LOG_INFO, "K27NativeDisplay", "scanout source: %s",
                    context->boot ? "simplefb" : "virtio-gpu");
            }
        }
        surface->locked = nullptr;
        surface->buffer_owner = nullptr;
        ANativeWindow_release(window);
    }
}

extern "C" void set_android_surface_position(AndroidDisplayContext* context, uint32_t x, uint32_t y) {
    std::lock_guard lock(context->state->mutex);
    auto& cursor = context->state->cursor;
    if (cursor < 0) return;
    const uint32_t pos[] = {x, y};
    if (write(cursor, pos, sizeof(pos)) < 0 && errno == EPIPE) {
        close(cursor);
        cursor = -1;
    }
}

extern "C" void set_android_surface_buffer_format(AndroidDisplayContext*, AndroidDisplaySurface*, uint32_t) {}
extern "C" bool android_display_has_consumer(AndroidDisplayContext* context) {
    std::lock_guard lock(context->state->mutex);
    return context->state->surfaces[0].target != nullptr;
}
extern "C" bool android_display_is_vulkan_blit_available(AndroidDisplayContext*) { return false; }
extern "C" int64_t android_display_import_dmabuf(AndroidDisplayContext*, AndroidDisplaySurface*, int,
    uint32_t, uint32_t, uint64_t, bool, uint32_t, uint32_t, uint32_t) { return -1; }
extern "C" void android_display_release_import(AndroidDisplayContext*, int64_t) {}
extern "C" bool android_display_flip_to(AndroidDisplayContext*, AndroidDisplaySurface*, int64_t,
    int* fence) {
    if (fence) *fence = -1;
    return false;
}
