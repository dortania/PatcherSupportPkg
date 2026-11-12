// i11 input: ANGLE's Metal translation (WebKit's ANGLE, macOS 15.8) of the fragment shader of dEQP
// ubo.single_struct_array.single_buffer.std140_instance_array_fragment, with ANGLE_ALPHA0 filled in as ANGLE does.


#include <metal_stdlib>

#define ANGLE_ALWAYS_INLINE __attribute__((always_inline))

ANGLE_ALWAYS_INLINE int ANGLE_int_clamp(int value, int minValue, int maxValue)
{
    return ((value < minValue) ?  minValue : ((value > maxValue) ? maxValue : value));
};

#define ANGLE_SAMPLE_COMPARE_GRADIENT_INDEX   0
#define ANGLE_RASTERIZATION_DISCARD_INDEX     1
#define ANGLE_MULTISAMPLED_RENDERING_INDEX    2
#define ANGLE_DEPTH_WRITE_ENABLED_INDEX       3
#define ANGLE_EMULATE_ALPHA_TO_COVERAGE_INDEX 4
#define ANGLE_WRITE_HELPER_SAMPLE_MASK_INDEX  5

constant bool ANGLEUseSampleCompareGradient [[function_constant(ANGLE_SAMPLE_COMPARE_GRADIENT_INDEX)]];
constant bool ANGLERasterizerDisabled       [[function_constant(ANGLE_RASTERIZATION_DISCARD_INDEX)]];
constant bool ANGLEMultisampledRendering    [[function_constant(ANGLE_MULTISAMPLED_RENDERING_INDEX)]];
constant bool ANGLEDepthWriteEnabled        [[function_constant(ANGLE_DEPTH_WRITE_ENABLED_INDEX)]];
constant bool ANGLEEmulateAlphaToCoverage   [[function_constant(ANGLE_EMULATE_ALPHA_TO_COVERAGE_INDEX)]];
constant bool ANGLEWriteHelperSampleMask    [[function_constant(ANGLE_WRITE_HELPER_SAMPLE_MASK_INDEX)]];

#define ANGLE_ALPHA0 ANGLE_fragmentOut._udEQP_FragColor.a

constant bool ANGLESampleMaskWriteEnabled = ANGLEMultisampledRendering;
#pragma clang diagnostic ignored "-Wunused-value"
template <typename X, typename Y>
ANGLE_ALWAYS_INLINE X ANGLE_rshift(X x, Y y)
{
    return x >> (y & Y(31));
}

template <typename X, typename Y>
ANGLE_ALWAYS_INLINE X ANGLE_ilshift(X x, Y y)
{
    using UX = metal::make_unsigned_t<X>;
    return as_type<X>(UX(x) << (y & Y(31)));
}

template <typename X, typename Y, typename Z = metal::conditional_t<metal::is_scalar_v<Y>, X, Y>>
ANGLE_ALWAYS_INLINE Z ANGLE_subInt(X x, Y y)
{
    using U = metal::make_unsigned_t<Z>;
    return as_type<Z>(U(Z(x)) - U(Z(y)));
}

template <typename X, typename Y>
ANGLE_ALWAYS_INLINE X ANGLE_ftoi(Y y)
{
    Y min = Y(metal::numeric_limits<X>::min());
    Y max = Y(metal::numeric_limits<X>::max()) * Y(1.0f - 0x1.0p-24f);
    return X(metal::clamp(y, min, max));
}

template <typename X, typename Y, typename Z = metal::conditional_t<metal::is_scalar_v<Y>, X, Y>>
ANGLE_ALWAYS_INLINE Z ANGLE_addInt(X x, Y y)
{
    using U = metal::make_unsigned_t<Z>;
    return as_type<Z>(U(Z(x)) + U(Z(y)));
}

template <typename X, typename Y, typename Z = metal::conditional_t<metal::is_scalar_v<Y>, X, Y>>
ANGLE_ALWAYS_INLINE Z ANGLE_imul(X x, Y y)
{
    using U = metal::make_unsigned_t<Z>;
    return as_type<Z>(U(Z(x)) * U(Z(y)));
}

template <typename X, typename Y>
ANGLE_ALWAYS_INLINE X ANGLE_ulshift(X x, Y y)
{
    return x << (y & Y(31));
}

struct ANGLE_InvocationFragmentGlobals
{
  metal::float4 gl_FragCoord [[position]];
};

struct ANGLEDepthRangeParams
{
  float ANGLE_near;
  float ANGLE_far;
  float ANGLE_diff;
};

struct ANGLEUniformBlock
{
  metal::float2 ANGLE_depthRange;
  uint32_t ANGLE_renderArea;
  uint32_t ANGLE_flipXY;
  uint32_t ANGLE_misc;
  int ANGLE_baseInstance;
  metal::uint2 ANGLE_acbBufferOffsets;
  metal::int4 ANGLE_xfbBufferOffsets;
  int ANGLE_xfbVerticesPerInstance;
  uint32_t ANGLE_coverageMask;
  metal::uint2 ANGLE_unused;
};

struct ANGLE_NonConstGlobals
{
  metal::float4 ANGLE_flippedFragCoord;
};

struct _uS_0
{
  metal::int3 _ua;
  metal::array<metal::float3x3, 4> _ub;
  metal::float4 _uc;
};

struct _bBlock
{
  uint32_t _uu;
  metal::array<_uS_0, 3> _us;
  metal::float4 _uv;
};

struct ANGLE_UniformBuffer
{
  metal::array<constant _bBlock *, 3> _ublock[[id(0)]];
};

struct ANGLE_FragmentOut
{
  metal::float4 _udEQP_FragColor [[color(0)]];
  uint32_t ANGLE_metal_SampleMask [[sample_mask, function_constant(ANGLESampleMaskWriteEnabled)]];
};

struct ANGLE_FragmentIn
{
  float _uv_vtxResult;
};

metal::float2 ANGLE_sbea(float ANGLE_sbeb, float ANGLE_sbec)
{
  metal::float2 ANGLE_sbed = metal::float2(ANGLE_sbeb, ANGLE_sbec);
  return ANGLE_sbed;;
}

metal::float2 ANGLE_sbe7(float ANGLE_sbe8, float ANGLE_sbe9)
{
  metal::float2 ANGLE_sbee = metal::float2(ANGLE_sbe8, ANGLE_sbe9);
  return ANGLE_sbee;;
}

metal::float4 ANGLE_sbe2(float ANGLE_sbe3, float ANGLE_sbe4, float ANGLE_sbe5, float ANGLE_sbe6)
{
  metal::float4 ANGLE_sbef = metal::float4(ANGLE_sbe3, ANGLE_sbe4, ANGLE_sbe5, ANGLE_sbe6);
  return ANGLE_sbef;;
}

float _ucompare_float(float _ua, float _ub)
{
  float ANGLE_sbf0 = (_ua - _ub);
  float ANGLE_sbf1 = metal::abs(ANGLE_sbf0);
  float ANGLE_sbf3;
  if (ANGLE_sbf1 < 0.0500000007f)
  {
    ANGLE_sbf3 = 1.0f;
  }
  else
  {
    ANGLE_sbf3 = 0.0f;
  }
  return ANGLE_sbf3;;
}

float _ucompare_vec3(metal::float3 _ua, metal::float3 _ub)
{
  float ANGLE_sbf4 = _ucompare_float(_ua.x, _ub.x);
  float ANGLE_sbf5 = _ucompare_float(_ua.y, _ub.y);
  float ANGLE_sbf6 = (ANGLE_sbf4 * ANGLE_sbf5);
  float ANGLE_sbf7 = _ucompare_float(_ua.z, _ub.z);
  float ANGLE_sbf8 = (ANGLE_sbf6 * ANGLE_sbf7);
  return ANGLE_sbf8;;
}

float _ucompare_vec4(metal::float4 _ua, metal::float4 _ub)
{
  float ANGLE_sbf9 = _ucompare_float(_ua.x, _ub.x);
  float ANGLE_sbfa = _ucompare_float(_ua.y, _ub.y);
  float ANGLE_sbfb = (ANGLE_sbf9 * ANGLE_sbfa);
  float ANGLE_sbfc = _ucompare_float(_ua.z, _ub.z);
  float ANGLE_sbfd = (ANGLE_sbfb * ANGLE_sbfc);
  float ANGLE_sbfe = _ucompare_float(_ua.w, _ub.w);
  float ANGLE_sbff = (ANGLE_sbfd * ANGLE_sbfe);
  return ANGLE_sbff;;
}

float _ucompare_mat3(metal::float3x3 _ua, metal::float3x3 _ub)
{
  float ANGLE_sc00 = _ucompare_vec3(_ua[0], _ub[0]);
  float ANGLE_sc01 = _ucompare_vec3(_ua[1], _ub[1]);
  float ANGLE_sc02 = (ANGLE_sc00 * ANGLE_sc01);
  float ANGLE_sc03 = _ucompare_vec3(_ua[2], _ub[2]);
  float ANGLE_sc04 = (ANGLE_sc02 * ANGLE_sc03);
  return ANGLE_sc04;;
}

float _ucompare_uint(uint32_t _ua, uint32_t _ub)
{
  float ANGLE_sc06;
  if (_ua == _ub)
  {
    ANGLE_sc06 = 1.0f;
  }
  else
  {
    ANGLE_sc06 = 0.0f;
  }
  return ANGLE_sc06;;
}

void ANGLE__0_main(constant ANGLE_UniformBuffer & ANGLE_uniformBuffer, thread ANGLE_FragmentOut & ANGLE_fragmentOut, thread ANGLE_FragmentIn & ANGLE_fragmentIn)
{
  float _uresult = 1.0f;
  float ANGLE_sc07 = _ucompare_uint((*ANGLE_uniformBuffer._ublock[0])._uu, 0u);
  _uresult *= ANGLE_sc07;
  float ANGLE_sc08 = _ucompare_mat3((*ANGLE_uniformBuffer._ublock[0])._us[0]._ub[0], metal::float3x3(-4.0f, 8.0f, 4.0f, -1.0f, 9.0f, 5.0f, 4.0f, -5.0f, -7.0f));
  _uresult *= ANGLE_sc08;
  float ANGLE_sc09 = _ucompare_mat3((*ANGLE_uniformBuffer._ublock[0])._us[0]._ub[1], metal::float3x3(2.0f, 2.0f, -6.0f, -2.0f, 9.0f, -5.0f, -4.0f, 8.0f, -5.0f));
  _uresult *= ANGLE_sc09;
  float ANGLE_sc0a = _ucompare_mat3((*ANGLE_uniformBuffer._ublock[0])._us[0]._ub[2], metal::float3x3(-6.0f, 2.0f, -5.0f, 4.0f, 7.0f, 7.0f, -1.0f, -1.0f, 3.0f));
  _uresult *= ANGLE_sc0a;
  float ANGLE_sc0b = _ucompare_mat3((*ANGLE_uniformBuffer._ublock[0])._us[0]._ub[3], metal::float3x3(0.0f, 8.0f, -3.0f, 9.0f, 0.0f, -5.0f, 6.0f, 5.0f, 9.0f));
  _uresult *= ANGLE_sc0b;
  float ANGLE_sc0c = _ucompare_vec4((*ANGLE_uniformBuffer._ublock[0])._us[0]._uc, metal::float4(0.0f, -3.0f, -7.0f, 7.0f));
  _uresult *= ANGLE_sc0c;
  float ANGLE_sc0d = _ucompare_mat3((*ANGLE_uniformBuffer._ublock[0])._us[1]._ub[0], metal::float3x3(-6.0f, 4.0f, -3.0f, -1.0f, 4.0f, 3.0f, -4.0f, 0.0f, 5.0f));
  _uresult *= ANGLE_sc0d;
  float ANGLE_sc0e = _ucompare_mat3((*ANGLE_uniformBuffer._ublock[0])._us[1]._ub[1], metal::float3x3(8.0f, 9.0f, -9.0f, 8.0f, 7.0f, -7.0f, 4.0f, -2.0f, 6.0f));
  _uresult *= ANGLE_sc0e;
  float ANGLE_sc0f = _ucompare_mat3((*ANGLE_uniformBuffer._ublock[0])._us[1]._ub[2], metal::float3x3(-3.0f, -7.0f, -6.0f, 5.0f, 2.0f, -9.0f, 2.0f, 4.0f, 6.0f));
  _uresult *= ANGLE_sc0f;
  float ANGLE_sc10 = _ucompare_mat3((*ANGLE_uniformBuffer._ublock[0])._us[1]._ub[3], metal::float3x3(2.0f, 5.0f, -7.0f, -1.0f, 5.0f, 8.0f, -6.0f, -4.0f, 8.0f));
  _uresult *= ANGLE_sc10;
  float ANGLE_sc11 = _ucompare_vec4((*ANGLE_uniformBuffer._ublock[0])._us[1]._uc, metal::float4(6.0f, -1.0f, 5.0f, 0.0f));
  _uresult *= ANGLE_sc11;
  float ANGLE_sc12 = _ucompare_mat3((*ANGLE_uniformBuffer._ublock[0])._us[2]._ub[0], metal::float3x3(-4.0f, 9.0f, -3.0f, -5.0f, -2.0f, -1.0f, -6.0f, 2.0f, -8.0f));
  _uresult *= ANGLE_sc12;
  float ANGLE_sc13 = _ucompare_mat3((*ANGLE_uniformBuffer._ublock[0])._us[2]._ub[1], metal::float3x3(-6.0f, 0.0f, 1.0f, 3.0f, -8.0f, -4.0f, 5.0f, -2.0f, 0.0f));
  _uresult *= ANGLE_sc13;
  float ANGLE_sc14 = _ucompare_mat3((*ANGLE_uniformBuffer._ublock[0])._us[2]._ub[2], metal::float3x3(-2.0f, -8.0f, 2.0f, 4.0f, 4.0f, 6.0f, -7.0f, 0.0f, -3.0f));
  _uresult *= ANGLE_sc14;
  float ANGLE_sc15 = _ucompare_mat3((*ANGLE_uniformBuffer._ublock[0])._us[2]._ub[3], metal::float3x3(7.0f, -1.0f, 8.0f, 9.0f, 8.0f, 9.0f, 0.0f, 5.0f, 3.0f));
  _uresult *= ANGLE_sc15;
  float ANGLE_sc16 = _ucompare_vec4((*ANGLE_uniformBuffer._ublock[0])._us[2]._uc, metal::float4(1.0f, -4.0f, 1.0f, -8.0f));
  _uresult *= ANGLE_sc16;
  float ANGLE_sc17 = _ucompare_vec4((*ANGLE_uniformBuffer._ublock[0])._uv, metal::float4(-6.0f, 0.0f, 2.0f, -1.0f));
  _uresult *= ANGLE_sc17;
  float ANGLE_sc18 = _ucompare_uint((*ANGLE_uniformBuffer._ublock[1])._uu, 6u);
  _uresult *= ANGLE_sc18;
  float ANGLE_sc19 = _ucompare_mat3((*ANGLE_uniformBuffer._ublock[1])._us[0]._ub[0], metal::float3x3(5.0f, 7.0f, 8.0f, -8.0f, 8.0f, -4.0f, 8.0f, -1.0f, 0.0f));
  _uresult *= ANGLE_sc19;
  float ANGLE_sc1a = _ucompare_mat3((*ANGLE_uniformBuffer._ublock[1])._us[0]._ub[1], metal::float3x3(-9.0f, 4.0f, 3.0f, 3.0f, -3.0f, 3.0f, 4.0f, 7.0f, 4.0f));
  _uresult *= ANGLE_sc1a;
  float ANGLE_sc1b = _ucompare_mat3((*ANGLE_uniformBuffer._ublock[1])._us[0]._ub[2], metal::float3x3(-1.0f, 4.0f, -5.0f, -8.0f, -1.0f, 9.0f, -4.0f, -1.0f, -5.0f));
  _uresult *= ANGLE_sc1b;
  float ANGLE_sc1c = _ucompare_mat3((*ANGLE_uniformBuffer._ublock[1])._us[0]._ub[3], metal::float3x3(3.0f, -8.0f, 2.0f, -9.0f, -2.0f, 2.0f, 7.0f, -7.0f, 8.0f));
  _uresult *= ANGLE_sc1c;
  float ANGLE_sc1d = _ucompare_vec4((*ANGLE_uniformBuffer._ublock[1])._us[0]._uc, metal::float4(4.0f, 0.0f, 7.0f, 7.0f));
  _uresult *= ANGLE_sc1d;
  float ANGLE_sc1e = _ucompare_mat3((*ANGLE_uniformBuffer._ublock[1])._us[1]._ub[0], metal::float3x3(-7.0f, 9.0f, 5.0f, 0.0f, -9.0f, 8.0f, 0.0f, 2.0f, 2.0f));
  _uresult *= ANGLE_sc1e;
  float ANGLE_sc1f = _ucompare_mat3((*ANGLE_uniformBuffer._ublock[1])._us[1]._ub[1], metal::float3x3(-3.0f, -7.0f, 8.0f, -3.0f, 5.0f, -7.0f, -6.0f, -9.0f, 3.0f));
  _uresult *= ANGLE_sc1f;
  float ANGLE_sc20 = _ucompare_mat3((*ANGLE_uniformBuffer._ublock[1])._us[1]._ub[2], metal::float3x3(-5.0f, -8.0f, 3.0f, 0.0f, -2.0f, -4.0f, -4.0f, 5.0f, -6.0f));
  _uresult *= ANGLE_sc20;
  float ANGLE_sc21 = _ucompare_mat3((*ANGLE_uniformBuffer._ublock[1])._us[1]._ub[3], metal::float3x3(1.0f, 1.0f, 6.0f, -3.0f, 2.0f, -1.0f, 8.0f, -7.0f, -3.0f));
  _uresult *= ANGLE_sc21;
  float ANGLE_sc22 = _ucompare_vec4((*ANGLE_uniformBuffer._ublock[1])._us[1]._uc, metal::float4(8.0f, -7.0f, -9.0f, 7.0f));
  _uresult *= ANGLE_sc22;
  float ANGLE_sc23 = _ucompare_mat3((*ANGLE_uniformBuffer._ublock[1])._us[2]._ub[0], metal::float3x3(9.0f, -5.0f, -1.0f, 0.0f, 7.0f, 7.0f, 3.0f, -2.0f, 9.0f));
  _uresult *= ANGLE_sc23;
  float ANGLE_sc24 = _ucompare_mat3((*ANGLE_uniformBuffer._ublock[1])._us[2]._ub[1], metal::float3x3(-7.0f, 0.0f, 6.0f, -3.0f, -2.0f, 6.0f, 7.0f, 6.0f, 1.0f));
  _uresult *= ANGLE_sc24;
  float ANGLE_sc25 = _ucompare_mat3((*ANGLE_uniformBuffer._ublock[1])._us[2]._ub[2], metal::float3x3(2.0f, 6.0f, 0.0f, 7.0f, 0.0f, 9.0f, 8.0f, 2.0f, 5.0f));
  _uresult *= ANGLE_sc25;
  float ANGLE_sc26 = _ucompare_mat3((*ANGLE_uniformBuffer._ublock[1])._us[2]._ub[3], metal::float3x3(1.0f, 3.0f, 1.0f, -1.0f, -6.0f, 5.0f, 7.0f, -5.0f, 0.0f));
  _uresult *= ANGLE_sc26;
  float ANGLE_sc27 = _ucompare_vec4((*ANGLE_uniformBuffer._ublock[1])._us[2]._uc, metal::float4(4.0f, -5.0f, 8.0f, 7.0f));
  _uresult *= ANGLE_sc27;
  float ANGLE_sc28 = _ucompare_vec4((*ANGLE_uniformBuffer._ublock[1])._uv, metal::float4(-2.0f, -8.0f, -1.0f, -3.0f));
  _uresult *= ANGLE_sc28;
  float ANGLE_sc29 = _ucompare_uint((*ANGLE_uniformBuffer._ublock[2])._uu, 0u);
  _uresult *= ANGLE_sc29;
  float ANGLE_sc2a = _ucompare_mat3((*ANGLE_uniformBuffer._ublock[2])._us[0]._ub[0], metal::float3x3(1.0f, -7.0f, 7.0f, 1.0f, -7.0f, -1.0f, 7.0f, 0.0f, -9.0f));
  _uresult *= ANGLE_sc2a;
  float ANGLE_sc2b = _ucompare_mat3((*ANGLE_uniformBuffer._ublock[2])._us[0]._ub[1], metal::float3x3(-2.0f, -5.0f, -1.0f, -4.0f, -4.0f, -8.0f, 0.0f, 4.0f, -6.0f));
  _uresult *= ANGLE_sc2b;
  float ANGLE_sc2c = _ucompare_mat3((*ANGLE_uniformBuffer._ublock[2])._us[0]._ub[2], metal::float3x3(2.0f, -3.0f, 9.0f, 8.0f, 8.0f, -5.0f, 7.0f, 1.0f, -1.0f));
  _uresult *= ANGLE_sc2c;
  float ANGLE_sc2d = _ucompare_mat3((*ANGLE_uniformBuffer._ublock[2])._us[0]._ub[3], metal::float3x3(2.0f, -5.0f, -5.0f, 7.0f, 1.0f, -6.0f, -4.0f, 8.0f, 3.0f));
  _uresult *= ANGLE_sc2d;
  float ANGLE_sc2e = _ucompare_vec4((*ANGLE_uniformBuffer._ublock[2])._us[0]._uc, metal::float4(-3.0f, 4.0f, -9.0f, 4.0f));
  _uresult *= ANGLE_sc2e;
  float ANGLE_sc2f = _ucompare_mat3((*ANGLE_uniformBuffer._ublock[2])._us[1]._ub[0], metal::float3x3(5.0f, 6.0f, -2.0f, 3.0f, -4.0f, -9.0f, -6.0f, 9.0f, -1.0f));
  _uresult *= ANGLE_sc2f;
  float ANGLE_sc30 = _ucompare_mat3((*ANGLE_uniformBuffer._ublock[2])._us[1]._ub[1], metal::float3x3(8.0f, 1.0f, -2.0f, 4.0f, 4.0f, 8.0f, -4.0f, -2.0f, -4.0f));
  _uresult *= ANGLE_sc30;
  float ANGLE_sc31 = _ucompare_mat3((*ANGLE_uniformBuffer._ublock[2])._us[1]._ub[2], metal::float3x3(-1.0f, -4.0f, 4.0f, 0.0f, 2.0f, 5.0f, -4.0f, -8.0f, -3.0f));
  _uresult *= ANGLE_sc31;
  float ANGLE_sc32 = _ucompare_mat3((*ANGLE_uniformBuffer._ublock[2])._us[1]._ub[3], metal::float3x3(8.0f, 7.0f, -3.0f, 0.0f, 4.0f, -2.0f, -9.0f, 7.0f, 6.0f));
  _uresult *= ANGLE_sc32;
  float ANGLE_sc33 = _ucompare_vec4((*ANGLE_uniformBuffer._ublock[2])._us[1]._uc, metal::float4(-7.0f, -2.0f, 0.0f, 8.0f));
  _uresult *= ANGLE_sc33;
  float ANGLE_sc34 = _ucompare_mat3((*ANGLE_uniformBuffer._ublock[2])._us[2]._ub[0], metal::float3x3(7.0f, 3.0f, 3.0f, 8.0f, 8.0f, 6.0f, 8.0f, 8.0f, 5.0f));
  _uresult *= ANGLE_sc34;
  float ANGLE_sc35 = _ucompare_mat3((*ANGLE_uniformBuffer._ublock[2])._us[2]._ub[1], metal::float3x3(3.0f, 5.0f, -1.0f, -9.0f, -1.0f, 0.0f, 5.0f, 9.0f, 3.0f));
  _uresult *= ANGLE_sc35;
  float ANGLE_sc36 = _ucompare_mat3((*ANGLE_uniformBuffer._ublock[2])._us[2]._ub[2], metal::float3x3(3.0f, -1.0f, 1.0f, -1.0f, 3.0f, 9.0f, -5.0f, 1.0f, -8.0f));
  _uresult *= ANGLE_sc36;
  float ANGLE_sc37 = _ucompare_mat3((*ANGLE_uniformBuffer._ublock[2])._us[2]._ub[3], metal::float3x3(0.0f, 6.0f, -9.0f, -5.0f, 0.0f, 0.0f, -3.0f, -8.0f, -2.0f));
  _uresult *= ANGLE_sc37;
  float ANGLE_sc38 = _ucompare_vec4((*ANGLE_uniformBuffer._ublock[2])._us[2]._uc, metal::float4(3.0f, -9.0f, 6.0f, -1.0f));
  _uresult *= ANGLE_sc38;
  float ANGLE_sc39 = _ucompare_vec4((*ANGLE_uniformBuffer._ublock[2])._uv, metal::float4(3.0f, 0.0f, 0.0f, -2.0f));
  _uresult *= ANGLE_sc39;
  ANGLE_fragmentOut._udEQP_FragColor = ANGLE_sbe2(1.0f, ANGLE_fragmentIn._uv_vtxResult, _uresult, 1.0f);
}

fragment ANGLE_FragmentOut main0(constant ANGLE_UniformBuffer & ANGLE_uniformBuffer [[buffer(25)]], ANGLE_FragmentIn ANGLE_fragmentIn [[stage_in]], constant ANGLEUniformBlock & ANGLE_angleUniforms [[buffer(17)]], metal::float4 gl_FragCoord [[position]])
{
  ANGLE_InvocationFragmentGlobals ANGLE_invocationFragmentGlobals;
  ANGLE_invocationFragmentGlobals.gl_FragCoord = gl_FragCoord;
  {
    ANGLE_FragmentOut ANGLE_fragmentOut;
    {
      ANGLE_NonConstGlobals ANGLE_nonConstGlobals;
      {
        ANGLE_nonConstGlobals.ANGLE_flippedFragCoord = ANGLE_invocationFragmentGlobals.gl_FragCoord;
        uint32_t ANGLE_sc3b = (ANGLE_angleUniforms.ANGLE_renderArea & 65535u);
        float ANGLE_sc3c = float(ANGLE_sc3b);
        uint32_t ANGLE_sc3d = ANGLE_rshift(ANGLE_angleUniforms.ANGLE_renderArea, 16u);
        float ANGLE_sc3e = float(ANGLE_sc3d);
        metal::float2 ANGLE_sc3f = ANGLE_sbe7(ANGLE_sc3c, ANGLE_sc3e);
        metal::float2 ANGLE_sc40 = (ANGLE_sc3f * 0.5f);
        metal::float2 ANGLE_sc41 = (ANGLE_invocationFragmentGlobals.gl_FragCoord.xy - ANGLE_sc40);
        metal::float4 ANGLE_sc42 = metal::unpack_snorm4x8_to_float(ANGLE_angleUniforms.ANGLE_flipXY);
        metal::float2 ANGLE_sc43 = (ANGLE_sc41 * ANGLE_sc42.xy);
        uint32_t ANGLE_sc44 = (ANGLE_angleUniforms.ANGLE_renderArea & 65535u);
        float ANGLE_sc45 = float(ANGLE_sc44);
        uint32_t ANGLE_sc46 = ANGLE_rshift(ANGLE_angleUniforms.ANGLE_renderArea, 16u);
        float ANGLE_sc47 = float(ANGLE_sc46);
        metal::float2 ANGLE_sc48 = ANGLE_sbea(ANGLE_sc45, ANGLE_sc47);
        metal::float2 ANGLE_sc49 = (ANGLE_sc48 * 0.5f);
        ANGLE_nonConstGlobals.ANGLE_flippedFragCoord.xy = (ANGLE_sc43 + ANGLE_sc49);
        ANGLE__0_main(ANGLE_uniformBuffer, ANGLE_fragmentOut, ANGLE_fragmentIn);
        if (ANGLEMultisampledRendering)
        {
          ANGLE_fragmentOut.ANGLE_metal_SampleMask = ANGLE_angleUniforms.ANGLE_coverageMask;
          if (ANGLEEmulateAlphaToCoverage)
          {
            uint32_t ANGLE_sc4b = ANGLE_rshift(ANGLE_angleUniforms.ANGLE_misc, 21u);
            uint32_t ANGLE_sc4c = (ANGLE_sc4b & 1u);
            bool ANGLE_sc4d = bool(ANGLE_sc4c);
            if (ANGLE_sc4d)
            {
              int ANGLE_sbdb = gl_FragCoord.x;
              int ANGLE_sbdc = gl_FragCoord.y;
              ANGLE_sbdb = ANGLE_ilshift(ANGLE_sbdb, 1);
              ANGLE_sbdc &= 1;
              ANGLE_sbdb = ANGLE_subInt(ANGLE_sbdb, ANGLE_sbdc);
              ANGLE_sbdb &= 3;
              float ANGLE_sbde = metal::saturate(ANGLE_ALPHA0);
              ANGLE_sbde *= 510.0f;
              int ANGLE_sbdf = ANGLE_ftoi<int>(ANGLE_sbde);
              uint32_t ANGLE_sc50 = metal::get_num_samples();
              switch (ANGLE_sc50)
              {
                case 2:
                  ANGLE_sbdb = ANGLE_ilshift(ANGLE_sbdb, 6);
                  ANGLE_sbdf = ANGLE_addInt(ANGLE_sbdf, 225);
                  ANGLE_sbdf = ANGLE_subInt(ANGLE_sbdf, ANGLE_sbdb);
                  ANGLE_sbdf = ANGLE_rshift(ANGLE_sbdf, 8);
                  ANGLE_sbdf = ANGLE_imul(ANGLE_sbdf, 3);
                  ANGLE_sbdf = ANGLE_rshift(ANGLE_sbdf, 1);
                  break;
                case 4:
                  ANGLE_sbdb = ANGLE_ilshift(ANGLE_sbdb, 5);
                  ANGLE_sbdf = ANGLE_addInt(ANGLE_sbdf, 113);
                  ANGLE_sbdf = ANGLE_subInt(ANGLE_sbdf, ANGLE_sbdb);
                  ANGLE_sbdf = ANGLE_rshift(ANGLE_sbdf, 7);
                  ANGLE_sbdf = ANGLE_ilshift(ANGLE_sbdf, 2);
                  ANGLE_sbdf = ANGLE_rshift(1030416, ANGLE_sbdf);
                  break;
                case 8:
                  ANGLE_sbdb = ANGLE_ilshift(ANGLE_sbdb, 4);
                  ANGLE_sbdf = ANGLE_addInt(ANGLE_sbdf, 57);
                  ANGLE_sbdf = ANGLE_subInt(ANGLE_sbdf, ANGLE_sbdb);
                  ANGLE_sbdf = ANGLE_rshift(ANGLE_sbdf, 6);
                  ANGLE_sbdf = ANGLE_ulshift(4294967295u, ANGLE_sbdf);
                  ANGLE_sbdf = (~ANGLE_sbdf);
                  break;
              }
              ANGLE_fragmentOut.ANGLE_metal_SampleMask &= ANGLE_sbdf;
            } else {}
          } else {}
        } else {}
      }
    }
    return ANGLE_fragmentOut;;
  }
}

