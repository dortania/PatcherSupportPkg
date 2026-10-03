/*  Copyright (c) 2022 Apple, Inc.  All rights reserved.
 *
 *  This header provides the definition of a subset of the macros defined in
 *  the system header `TargetConditionals.h` to be used for Metal.
 *
 *  TARGET_OS_*
 *  These conditionals specify in which Operating System the generated code
 *  will run. Indention is used to show which conditionals are evolutionary
 *  subclasses.
 *
 *  The MAC/WIN32/UNIX conditionals are mutually exclusive.
 *  The IOS/TV/WATCH conditionals are mutually exclusive.
 *
 *  TARGET_OS_WIN32        - Generated code will run under 32-bit Windows
 *  TARGET_OS_UNIX         - Generated code will run under some Unix (not OSX)
 *  TARGET_OS_MAC          - Generated code will run under Mac OS X variant
 *    TARGET_OS_OSX          - Generated code will run under OS X devices
 *    TARGET_OS_IPHONE       - Generated code for firmware, devices or simulator
 *      TARGET_OS_IOS          - Generated code will run under iOS
 *      TARGET_OS_TV           - Generated code will run under Apple TV OS
 *      TARGET_OS_WATCH        - Generated code will run under Apple Watch OS
 *      TARGET_OS_MACCATALYST  - Generated code will run under MacOS
 *    TARGET_OS_SIMULATOR    - Generated code will run under a simulator
 *
 *  NOTE: This header is tailored for the Apple Metal compiler and the
 *  corresponding supported targets.
 */

#ifndef __TARGETCONDITIONALS__
#define __TARGETCONDITIONALS__

#define TARGET_OS_MAC 1
#define TARGET_OS_WIN32 0
#define TARGET_OS_UNIX 0

#if !__has_builtin(__is_target_vendor) || !__has_builtin(__is_target_os) || \
    !__has_builtin(__is_target_environment)
#error "Unsupported compiler!"
#endif

#if !__is_target_vendor(apple)
#error "Unsupported vendor!"
#endif

#if __is_target_os(macosx) || __is_target_os(macos)

#define TARGET_OS_OSX 1
#define TARGET_OS_IPHONE 0
#define TARGET_OS_IOS 0
#define TARGET_OS_TV 0
#define TARGET_OS_WATCH 0
#define TARGET_OS_SIMULATOR 0
#define TARGET_OS_MACCATALYST 0

#elif __is_target_os(ios)

#define TARGET_OS_OSX 0
#define TARGET_OS_IPHONE 1
#define TARGET_OS_IOS 1
#define TARGET_OS_TV 0
#define TARGET_OS_WATCH 0
#if __is_target_environment(simulator)
#define TARGET_OS_SIMULATOR 1
#define TARGET_OS_MACCATALYST 0
#elif __is_target_environment(macabi)
#define TARGET_OS_SIMULATOR 0
#define TARGET_OS_MACCATALYST 1
#else
#define TARGET_OS_SIMULATOR 0
#define TARGET_OS_MACCATALYST 0
#endif

#elif __is_target_os(tvos)

#define TARGET_OS_OSX 0
#define TARGET_OS_IPHONE 1
#define TARGET_OS_IOS 0
#define TARGET_OS_TV 1
#define TARGET_OS_WATCH 0
#if __is_target_environment(simulator)
#define TARGET_OS_SIMULATOR 1
#else
#define TARGET_OS_SIMULATOR 0
#endif
#define TARGET_OS_MACCATALYST 0

#elif __is_target_os(watchos)

#define TARGET_OS_OSX 0
#define TARGET_OS_IPHONE 1
#define TARGET_OS_IOS 0
#define TARGET_OS_TV 0
#define TARGET_OS_WATCH 1
#if __is_target_environment(simulator)
#define TARGET_OS_SIMULATOR 1
#else
#define TARGET_OS_SIMULATOR 0
#endif
#define TARGET_OS_MACCATALYST 0

#else
#error "Unsupported target!"
#endif

#endif /* __TARGETCONDITIONALS__ */
