/*  Copyright (c) 2014-2017 Apple, Inc. All rights reserved.
 *
 * This is a version of simd/vector_types.h suitatable to be used with the Metal
 * compiler.
 *
 */

#ifndef __SIMD_VECTOR_TYPES_HEADER__
#define __SIMD_VECTOR_TYPES_HEADER__

// Metal vector types are always defined, we just need to export the metal
// namespace as simd here.
namespace simd = metal;

#endif /* __SIMD_VECTOR_TYPES_HEADER__ */
