// CPU regression through AMDShared's real import; no Metal device/backend pass.
#include "pinned_llvm.hpp"
#include <cassert>
#include <cstdio>
#include <mach-o/dyld.h>
#include <iterator>
#include <string>
#include <unistd.h>

extern "C" void destroyHelper(void*) asm("__ZN4llvm12amdMtlPlugin14ILPluginHelperD2Ev");

static std::string snapshot(void *node) {
    assert(node);
    unsigned kind = pinned::field<unsigned char>(node);
    if (kind == 0) {
        auto text = pinned::api().string(node);
        return "S" + std::to_string(text.size) + "=" + std::string(text.data, text.size) + ";";
    }
    if (kind == 1) {
        auto value = pinned::field<void*>(node, 0x80);
        assert(value && pinned::field<unsigned char>(value, 0x10) == 0x12);
        return "I" + std::to_string(pinned::field<unsigned>(value, 0x20)) + "=" +
            std::to_string(pinned::field<uint64_t>(value, 0x18)) + ";";
    }
    assert(kind == 4 && pinned::count(node) < 4096);
    std::string result = "[";
    for (unsigned i = 0; i < pinned::count(node); ++i)
        result += snapshot(pinned::operand(node, i));
    return result + "]";
}

static void *arguments(void *helper) {
    auto entry = pinned::api().entry(pinned::field<void*>(helper));
    assert(entry.node && pinned::count(entry.node) == 3);
    return pinned::operand(entry.node, 2);
}

int main(int argc, char **argv) {
    assert(argc == 5);
    alarm(15);
    assert(pinned::api().valid); // Guards every private ABI/address used below.
    std::ifstream input(argv[2], std::ios::binary);
    std::vector<char> bytes((std::istreambuf_iterator<char>(input)), {});
    assert(!bytes.empty());
    alignas(16) unsigned char original[24] = {}, repaired[24] = {};
    pinned::originalHelper(original, bytes.data(), bytes.size());
    auto expected = snapshot(arguments(original));
    const std::string pair = "S17=air.address_space;I32=2;";
    unsigned removed = 0;
    for (size_t pos; (pos = expected.find(pair)) != std::string::npos; ++removed)
        expected.erase(pos, pair.size());
    assert(removed == std::stoul(argv[3]));

    // "original" intentionally runs the same assertion without the repair.
    // A missing hook or a no-op adapter must fail this test, not skip it.
    if (!std::strcmp(argv[4], "original")) {
        pinned::originalHelper(repaired, bytes.data(), bytes.size());
    } else {
        assert(!std::strcmp(argv[4], "repaired"));
        auto plugin = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
        assert(plugin);
        Dl_info info{};
        auto constructor = dlsym(plugin, "_ZN4llvm12amdMtlPlugin14ILPluginHelperC1EPKvm");
        assert(constructor && dladdr(constructor, &info));
        assert(std::strstr(info.dli_fname, "/MetadataCompat.dylib"));
        // This stub address is test-only, pinned to the verified stock plugin.
        intptr_t slide = 0;
        bool found = false;
        for (unsigned i = 0; i < _dyld_image_count(); ++i)
            if (!std::strcmp(_dyld_get_image_name(i), argv[1])) {
                slide = _dyld_get_image_vmaddr_slide(i);
                found = true;
            }
        assert(found);
        auto stub = reinterpret_cast<unsigned char*>(slide + 0x4ffa1063c400ULL);
        assert(stub[0] == 0xff && stub[1] == 0x25);
        auto destination = pinned::field<void*>(stub + 6 + pinned::field<int32_t>(stub, 2));
        assert(destination == constructor);
        reinterpret_cast<void(*)(void*, const void*, size_t)>(stub)(repaired, bytes.data(), bytes.size());
    }
    auto args = arguments(repaired);
    bool exactDelta = snapshot(args) == expected;
    bool parserAccepts = true;
    intptr_t providerSlide = 0;
    for (unsigned i = 0; i < _dyld_image_count(); ++i)
        if (!std::strcmp(_dyld_get_image_name(i), pinned::library))
            providerSlide = _dyld_get_image_vmaddr_slide(i);
    auto parseArgument = reinterpret_cast<void(*)(void*, void*, unsigned)>(providerSlide + 0x4ffa0d3d27f4ULL);
    const unsigned char prefix[] = {0x55, 0x48, 0x89, 0xe5, 0x41, 0x57, 0x41, 0x56};
    assert(!std::memcmp(reinterpret_cast<void*>(parseArgument), prefix, sizeof(prefix)));
    for (unsigned i = 0; i < pinned::count(args); ++i) {
        alignas(16) unsigned char argument[0x110] = {};
        parseArgument(argument, pinned::operand(args, i), 0);
        auto wrapper = pinned::field<void*>(argument, 0x80);
        parserAccepts &= wrapper && pinned::field<void*>(wrapper);
    }
    destroyHelper(repaired);
    destroyHelper(original);
    if (!exactDelta || !parserAccepts) {
        std::fprintf(stderr, "FAIL regression: exact_delta=%d parser_wrapper=%d\n", exactDelta, parserAccepts);
        return 3;
    }
    std::printf("PASS regression: removed=%u exact_delta=1 parser_wrapper=1\n", removed);
}
