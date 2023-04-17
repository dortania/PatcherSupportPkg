/*  Copyright (c) 2014 Apple, Inc. All rights reserved.
 *
 *  This header defines float matrix types that are also defined on the host.
 *  Though the implementations are different, the host and device will have the
 *  same size, alignment, and storage formats. These matrices
 *  are stored in column-major order, and implemented as arrays of column
 *  vectors. You should think of matrices as abstract mathematical
 *  objects that you use to perform arithmetic without worrying about the
 *  details of the underlying representation.
 *
 *  WARNING: vectors of length three are internally represented as length four
 *  vectors with one element of padding (for alignment purposes).  This means
 *  that when a floatNx3 or doubleNx3 is viewed as a vector, it appears to
 *  have 4*N elements instead of the expected 3*N (with one padding element
 *  at the end of each column). The matrix elements are laid out in the
 *  elements field as follows:
 *
 *      { 0, 1, 2, x, 3, 4, 5, x, ... }
 *
 *  (where the scalar indices used above indicate the conceptual column-
 *  major storage order). If you aren't monkeying around with the internal
 *  storage details of matrices, you don't need to worry about this at all.
 *  Consider this yet another good reason to avoid doing so.
 */

#ifndef __SIMD_MATRIX_TYPES_HEADER__
#define __SIMD_MATRIX_TYPES_HEADER__

#include <metal_matrix>

using matrix_half2x2 = metal::half2x2;
using matrix_half3x2 = metal::half3x2;
using matrix_half4x2 = metal::half4x2;

using matrix_half2x3 = metal::half2x3;
using matrix_half3x3 = metal::half3x3;
using matrix_half4x3 = metal::half4x3;

using matrix_half2x4 = metal::half2x4;
using matrix_half3x4 = metal::half3x4;
using matrix_half4x4 = metal::half4x4;

using matrix_float2x2 = metal::float2x2;
using matrix_float3x2 = metal::float3x2;
using matrix_float4x2 = metal::float4x2;

using matrix_float2x3 = metal::float2x3;
using matrix_float3x3 = metal::float3x3;
using matrix_float4x3 = metal::float4x3;

using matrix_float2x4 = metal::float2x4;
using matrix_float3x4 = metal::float3x4;
using matrix_float4x4 = metal::float4x4;

#if defined(__HAVE_NATIVE_DOUBLE__)
using matrix_double2x2 = metal::double2x2;
using matrix_double3x2 = metal::double3x2;
using matrix_double4x2 = metal::double4x2;

using matrix_double2x3 = metal::double2x3;
using matrix_double3x3 = metal::double3x3;
using matrix_double4x3 = metal::double4x3;

using matrix_double2x4 = metal::double2x4;
using matrix_double3x4 = metal::double3x4;
using matrix_double4x4 = metal::double4x4;
#endif

#if defined(__HAVE_SIMD_TYPES_PREFIX__)
using simd_half2x2 = metal::half2x2;
using simd_half3x2 = metal::half3x2;
using simd_half4x2 = metal::half4x2;

using simd_half2x3 = metal::half2x3;
using simd_half3x3 = metal::half3x3;
using simd_half4x3 = metal::half4x3;

using simd_half2x4 = metal::half2x4;
using simd_half3x4 = metal::half3x4;
using simd_half4x4 = metal::half4x4;

using simd_float2x2 = metal::float2x2;
using simd_float3x2 = metal::float3x2;
using simd_float4x2 = metal::float4x2;

using simd_float2x3 = metal::float2x3;
using simd_float3x3 = metal::float3x3;
using simd_float4x3 = metal::float4x3;

using simd_float2x4 = metal::float2x4;
using simd_float3x4 = metal::float3x4;
using simd_float4x4 = metal::float4x4;

#if defined(__HAVE_NATIVE_DOUBLE__)
using simd_double2x2 = metal::double2x2;
using simd_double3x2 = metal::double3x2;
using simd_double4x2 = metal::double4x2;

using simd_double2x3 = metal::double2x3;
using simd_double3x3 = metal::double3x3;
using simd_double4x3 = metal::double4x3;

using simd_double2x4 = metal::double2x4;
using simd_double3x4 = metal::double3x4;
using simd_double4x4 = metal::double4x4;
#endif
#endif

// We just need to export the metal namespace as simd here.
namespace simd = metal;

#endif /* __SIMD_MATRIX_TYPES_HEADER__ */
