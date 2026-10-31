// localcc.dylib: run Metal's GPU backend compiles inside the app instead of in MTLCompilerService, so a modified
// compiler plugin can be tested on the real GPU without installing it on the system volume:
//
//   DYLD_LIBRARY_PATH=<dir with patched libAMDIL902.dylib> DYLD_INSERT_LIBRARIES=localcc.dylib <metal app>
//
// Backend requests are the MTLCompilerService messages that carry "pluginPath"; they are answered with the same
// reply dictionary the service builds ({"error": status, "reply": data, "errorMessage": text}). Every other message
// still goes to the service. LOCALCC_LOG=1 prints one line per local compile; LOCALCC_PLUGIN=<path> loads that
// compiler plugin instead of the one the driver names.
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <xpc/xpc.h>
#include <map>
#include <mutex>
#include <string>

typedef void (^ReplyBlock)(unsigned status, const void *reply, size_t size, const char *error);
typedef void *(*CreateFn)(const std::string &client);
typedef int (*SetPluginPathFn)(void *svc, const char *path, const void *target, size_t targetLen);
typedef void (*BuildRequestFn)(void *svc, int plugin, unsigned type, const void *data, size_t size, ReplyBlock reply);

struct Compiler {
    void *service = nullptr;
    SetPluginPathFn setPlugin = nullptr;
    BuildRequestFn build = nullptr;
    std::map<std::string, int> plugins;  // pluginPath + targetData -> plugin index
};

static std::mutex lock;
static std::map<uint64_t, Compiler> compilers;  // by llvmVersion

static Compiler *compilerFor(uint64_t version) {
    Compiler &c = compilers[version];
    if (c.service) return &c;
    // OCLP's hybrid stack sends 31001 requests that its MTLCompilerService serves with the 32023 framework.
    const std::string base = "/System/Library/PrivateFrameworks/MTLCompiler.framework/Versions/";
    std::string fw;
    void *h = nullptr;
    for (std::string v : {std::to_string(version), std::string("32023"), std::string("Current")}) {
        fw = base + v + "/MTLCompiler";
        if ((h = dlopen(fw.c_str(), RTLD_NOW))) break;
    }
    if (!h) { fprintf(stderr, "[localcc] dlopen %s: %s\n", fw.c_str(), dlerror()); return nullptr; }
    if (getenv("LOCALCC_LOG")) fprintf(stderr, "[localcc] using %s for llvmVersion %llu\n", fw.c_str(), (unsigned long long)version);
    auto create = (CreateFn)dlsym(h, "MTLCodeGenServiceCreate");
    c.setPlugin = (SetPluginPathFn)dlsym(h, "MTLCodeGenServiceSetPluginPath");
    c.build = (BuildRequestFn)dlsym(h, "MTLCodeGenServiceBuildRequest");
    if (!create || !c.setPlugin || !c.build) return nullptr;
    c.service = create("localcc");
    return &c;
}

static xpc_object_t compileLocally(xpc_object_t msg) {
    const char *plugin = getenv("LOCALCC_PLUGIN") ?: xpc_dictionary_get_string(msg, "pluginPath");
    size_t size = 0, targetSize = 0;
    const void *data = xpc_dictionary_get_data(msg, "data", &size);
    const void *target = xpc_dictionary_get_data(msg, "targetData", &targetSize);
    unsigned type = (unsigned)xpc_dictionary_get_uint64(msg, "requestType");
    std::lock_guard<std::mutex> guard(lock);
    Compiler *c = compilerFor(xpc_dictionary_get_uint64(msg, "llvmVersion"));
    if (!c || !data) return nullptr;
    std::string key = std::string(plugin) + std::string((const char *)target, targetSize);
    auto it = c->plugins.find(key);
    int index = it != c->plugins.end() ? it->second : (c->plugins[key] = c->setPlugin(c->service, plugin, target, targetSize));
    xpc_object_t reply = xpc_dictionary_create_reply(msg);
    if (!reply) reply = xpc_dictionary_create(nullptr, nullptr, 0);
    __block unsigned result = ~0u;
    __block std::string lastError;
    c->build(c->service, index, type, data, size, ^(unsigned status, const void *out, size_t outSize, const char *error) {
        result = status;
        xpc_dictionary_set_uint64(reply, "error", status);
        if (out && outSize) xpc_dictionary_set_data(reply, "reply", out, outSize);
        if (error) { xpc_dictionary_set_string(reply, "errorMessage", error); lastError = error; }
    });
    if (getenv("LOCALCC_LOG")) fprintf(stderr, "[localcc] request type %u (%zu bytes) -> status %u%s%s\n", type, size, result, lastError.empty() ? "" : ": ", lastError.c_str());
    return reply;
}

static xpc_object_t localSendSync(xpc_connection_t conn, xpc_object_t msg) {
    if (xpc_get_type(msg) == XPC_TYPE_DICTIONARY && xpc_dictionary_get_string(msg, "pluginPath"))
        if (xpc_object_t reply = compileLocally(msg)) return reply;
    return xpc_connection_send_message_with_reply_sync(conn, msg);
}

__attribute__((used)) static struct { const void *replacement, *replacee; } interposers[] __attribute__((section("__DATA,__interpose"))) = {
    {(const void *)localSendSync, (const void *)xpc_connection_send_message_with_reply_sync},
};
