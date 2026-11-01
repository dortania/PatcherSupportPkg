/*  Copyright (c) 2016-2017 Apple, Inc. All rights reserved.
 *
 * This is a version of simd/packed.h suitatable to be used with the Metal
 * compiler. The main differences are:
 *
 *     - Support for 3 elements packed vectors.
 *     - Depending on the Metal language standard, access to array elements via
 *       component name -- e.g. .x, .y, ... -- might be enabled.
 */

#ifndef __SIMD_PACKED_HEADER__
#define __SIMD_PACKED_HEADER__

// Metal packed vector types are always defined, we just need to export the
// metal namespace as simd here.
namespace simd = metal;

#endif /* __SIMD_PACKED_HEADER__ */
