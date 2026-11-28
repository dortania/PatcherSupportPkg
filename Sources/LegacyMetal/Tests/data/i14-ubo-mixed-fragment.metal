// i14 input: ANGLE's Metal translation (WebKit's ANGLE, macOS 15.8) of the fragment shader of dEQP
// ubo.multi_nested_struct.single_buffer.std140_instance_array_mixed, with ANGLE_ALPHA0 filled in as ANGLE does.



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
template <typename T, int N>
ANGLE_ALWAYS_INLINE bool ANGLE_equal(metal::vec<T, N> u, metal::vec<T, N> v)
{
    return metal::all(u == v);
}

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
  metal::float3x3 _ua;
  metal::array<metal::int2, 4> _ub;
  metal::float4 _uc;
};

struct _uT_0
{
  uint32_t _ua;
  _uS_0 _ub;
  metal::bool4 _uc;
};

struct _bBlockB
{
  metal::float2x2 _ua;
  _uT_0 _ub;
  metal::bool4 _uc;
  bool _ud;
};

struct ANGLE_UniformBuffer
{
  metal::array<constant _bBlockB *, 3> _ublockB[[id(0)]];
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

metal::float2 ANGLE_sbfb(float ANGLE_sbfc, float ANGLE_sbfd)
{
  metal::float2 ANGLE_sbfe = metal::float2(ANGLE_sbfc, ANGLE_sbfd);
  return ANGLE_sbfe;;
}

metal::float2 ANGLE_sbf8(float ANGLE_sbf9, float ANGLE_sbfa)
{
  metal::float2 ANGLE_sbff = metal::float2(ANGLE_sbf9, ANGLE_sbfa);
  return ANGLE_sbff;;
}

metal::float4 ANGLE_sbf3(float ANGLE_sbf4, float ANGLE_sbf5, float ANGLE_sbf6, float ANGLE_sbf7)
{
  metal::float4 ANGLE_sc00 = metal::float4(ANGLE_sbf4, ANGLE_sbf5, ANGLE_sbf6, ANGLE_sbf7);
  return ANGLE_sc00;;
}

float _ucompare_float(float _ua, float _ub)
{
  float ANGLE_sc01 = (_ua - _ub);
  float ANGLE_sc02 = metal::abs(ANGLE_sc01);
  float ANGLE_sc04;
  if (ANGLE_sc02 < 0.0500000007f)
  {
    ANGLE_sc04 = 1.0f;
  }
  else
  {
    ANGLE_sc04 = 0.0f;
  }
  return ANGLE_sc04;;
}

float _ucompare_vec2(metal::float2 _ua, metal::float2 _ub)
{
  float ANGLE_sc05 = _ucompare_float(_ua.x, _ub.x);
  float ANGLE_sc06 = _ucompare_float(_ua.y, _ub.y);
  float ANGLE_sc07 = (ANGLE_sc05 * ANGLE_sc06);
  return ANGLE_sc07;;
}

float _ucompare_vec3(metal::float3 _ua, metal::float3 _ub)
{
  float ANGLE_sc08 = _ucompare_float(_ua.x, _ub.x);
  float ANGLE_sc09 = _ucompare_float(_ua.y, _ub.y);
  float ANGLE_sc0a = (ANGLE_sc08 * ANGLE_sc09);
  float ANGLE_sc0b = _ucompare_float(_ua.z, _ub.z);
  float ANGLE_sc0c = (ANGLE_sc0a * ANGLE_sc0b);
  return ANGLE_sc0c;;
}

float _ucompare_vec4(metal::float4 _ua, metal::float4 _ub)
{
  float ANGLE_sc0d = _ucompare_float(_ua.x, _ub.x);
  float ANGLE_sc0e = _ucompare_float(_ua.y, _ub.y);
  float ANGLE_sc0f = (ANGLE_sc0d * ANGLE_sc0e);
  float ANGLE_sc10 = _ucompare_float(_ua.z, _ub.z);
  float ANGLE_sc11 = (ANGLE_sc0f * ANGLE_sc10);
  float ANGLE_sc12 = _ucompare_float(_ua.w, _ub.w);
  float ANGLE_sc13 = (ANGLE_sc11 * ANGLE_sc12);
  return ANGLE_sc13;;
}

float _ucompare_mat2(metal::float2x2 _ua, metal::float2x2 _ub)
{
  float ANGLE_sc14 = _ucompare_vec2(_ua[0], _ub[0]);
  float ANGLE_sc15 = _ucompare_vec2(_ua[1], _ub[1]);
  float ANGLE_sc16 = (ANGLE_sc14 * ANGLE_sc15);
  return ANGLE_sc16;;
}

float _ucompare_mat3(metal::float3x3 _ua, metal::float3x3 _ub)
{
  float ANGLE_sc17 = _ucompare_vec3(_ua[0], _ub[0]);
  float ANGLE_sc18 = _ucompare_vec3(_ua[1], _ub[1]);
  float ANGLE_sc19 = (ANGLE_sc17 * ANGLE_sc18);
  float ANGLE_sc1a = _ucompare_vec3(_ua[2], _ub[2]);
  float ANGLE_sc1b = (ANGLE_sc19 * ANGLE_sc1a);
  return ANGLE_sc1b;;
}

float _ucompare_ivec2(metal::int2 _ua, metal::int2 _ub)
{
  float ANGLE_sc1d;
  if (ANGLE_equal(_ua, _ub))
  {
    ANGLE_sc1d = 1.0f;
  }
  else
  {
    ANGLE_sc1d = 0.0f;
  }
  return ANGLE_sc1d;;
}

float _ucompare_bool(bool _ua, bool _ub)
{
  float ANGLE_sc1f;
  if (_ua == _ub)
  {
    ANGLE_sc1f = 1.0f;
  }
  else
  {
    ANGLE_sc1f = 0.0f;
  }
  return ANGLE_sc1f;;
}

float _ucompare_bvec4(metal::bool4 _ua, metal::bool4 _ub)
{
  float ANGLE_sc21;
  if (ANGLE_equal(_ua, _ub))
  {
    ANGLE_sc21 = 1.0f;
  }
  else
  {
    ANGLE_sc21 = 0.0f;
  }
  return ANGLE_sc21;;
}

void ANGLE__0_main(constant ANGLE_UniformBuffer & ANGLE_uniformBuffer, thread ANGLE_FragmentOut & ANGLE_fragmentOut, thread ANGLE_FragmentIn & ANGLE_fragmentIn)
{
  float _uresult = 1.0f;
  float ANGLE_sc22 = _ucompare_mat2((*ANGLE_uniformBuffer._ublockB[0])._ua, metal::float2x2(5.0f, -7.0f, -1.0f, 5.0f));
  _uresult *= ANGLE_sc22;
  float ANGLE_sc23 = _ucompare_mat3((*ANGLE_uniformBuffer._ublockB[0])._ub._ub._ua, metal::float3x3(-6.0f, -4.0f, 8.0f, 6.0f, -1.0f, 5.0f, 0.0f, 6.0f, 2.0f));
  _uresult *= ANGLE_sc23;
  float ANGLE_sc24 = _ucompare_ivec2((*ANGLE_uniformBuffer._ublockB[0])._ub._ub._ub[0], metal::int2(3, -4));
  _uresult *= ANGLE_sc24;
  float ANGLE_sc25 = _ucompare_ivec2((*ANGLE_uniformBuffer._ublockB[0])._ub._ub._ub[1], metal::int2(9, -3));
  _uresult *= ANGLE_sc25;
  float ANGLE_sc26 = _ucompare_ivec2((*ANGLE_uniformBuffer._ublockB[0])._ub._ub._ub[2], metal::int2(-5, -2));
  _uresult *= ANGLE_sc26;
  float ANGLE_sc27 = _ucompare_ivec2((*ANGLE_uniformBuffer._ublockB[0])._ub._ub._ub[3], metal::int2(-1, -6));
  _uresult *= ANGLE_sc27;
  float ANGLE_sc28 = _ucompare_vec4((*ANGLE_uniformBuffer._ublockB[0])._ub._ub._uc, metal::float4(2.0f, -8.0f, -6.0f, 0.0f));
  _uresult *= ANGLE_sc28;
  float ANGLE_sc29 = _ucompare_bvec4((*ANGLE_uniformBuffer._ublockB[0])._ub._uc, metal::bool4(true, false, true, true));
  _uresult *= ANGLE_sc29;
  float ANGLE_sc2a = _ucompare_bool((*ANGLE_uniformBuffer._ublockB[0])._ud, false);
  _uresult *= ANGLE_sc2a;
  float ANGLE_sc2b = _ucompare_mat2((*ANGLE_uniformBuffer._ublockB[1])._ua, metal::float2x2(2.0f, 4.0f, 4.0f, 6.0f));
  _uresult *= ANGLE_sc2b;
  float ANGLE_sc2c = _ucompare_mat3((*ANGLE_uniformBuffer._ublockB[1])._ub._ub._ua, metal::float3x3(0.0f, -3.0f, 7.0f, -1.0f, 8.0f, 9.0f, 8.0f, 9.0f, 0.0f));
  _uresult *= ANGLE_sc2c;
  float ANGLE_sc2d = _ucompare_ivec2((*ANGLE_uniformBuffer._ublockB[1])._ub._ub._ub[0], metal::int2(5, 3));
  _uresult *= ANGLE_sc2d;
  float ANGLE_sc2e = _ucompare_ivec2((*ANGLE_uniformBuffer._ublockB[1])._ub._ub._ub[1], metal::int2(1, -4));
  _uresult *= ANGLE_sc2e;
  float ANGLE_sc2f = _ucompare_ivec2((*ANGLE_uniformBuffer._ublockB[1])._ub._ub._ub[2], metal::int2(1, -8));
  _uresult *= ANGLE_sc2f;
  float ANGLE_sc30 = _ucompare_ivec2((*ANGLE_uniformBuffer._ublockB[1])._ub._ub._ub[3], metal::int2(-6, 0));
  _uresult *= ANGLE_sc30;
  float ANGLE_sc31 = _ucompare_vec4((*ANGLE_uniformBuffer._ublockB[1])._ub._ub._uc, metal::float4(2.0f, -1.0f, -9.0f, 7.0f));
  _uresult *= ANGLE_sc31;
  float ANGLE_sc32 = _ucompare_bvec4((*ANGLE_uniformBuffer._ublockB[1])._ub._uc, metal::bool4(true, false, false, false));
  _uresult *= ANGLE_sc32;
  float ANGLE_sc33 = _ucompare_bool((*ANGLE_uniformBuffer._ublockB[1])._ud, true);
  _uresult *= ANGLE_sc33;
  float ANGLE_sc34 = _ucompare_mat2((*ANGLE_uniformBuffer._ublockB[2])._ua, metal::float2x2(-1.0f, 0.0f, -9.0f, 4.0f));
  _uresult *= ANGLE_sc34;
  float ANGLE_sc35 = _ucompare_mat3((*ANGLE_uniformBuffer._ublockB[2])._ub._ub._ua, metal::float3x3(3.0f, -3.0f, 3.0f, 4.0f, 7.0f, 4.0f, -1.0f, 4.0f, -5.0f));
  _uresult *= ANGLE_sc35;
  float ANGLE_sc36 = _ucompare_ivec2((*ANGLE_uniformBuffer._ublockB[2])._ub._ub._ub[0], metal::int2(-8, -1));
  _uresult *= ANGLE_sc36;
  float ANGLE_sc37 = _ucompare_ivec2((*ANGLE_uniformBuffer._ublockB[2])._ub._ub._ub[1], metal::int2(9, -4));
  _uresult *= ANGLE_sc37;
  float ANGLE_sc38 = _ucompare_ivec2((*ANGLE_uniformBuffer._ublockB[2])._ub._ub._ub[2], metal::int2(-1, -5));
  _uresult *= ANGLE_sc38;
  float ANGLE_sc39 = _ucompare_ivec2((*ANGLE_uniformBuffer._ublockB[2])._ub._ub._ub[3], metal::int2(3, -8));
  _uresult *= ANGLE_sc39;
  float ANGLE_sc3a = _ucompare_vec4((*ANGLE_uniformBuffer._ublockB[2])._ub._ub._uc, metal::float4(2.0f, -9.0f, -2.0f, 2.0f));
  _uresult *= ANGLE_sc3a;
  float ANGLE_sc3b = _ucompare_bvec4((*ANGLE_uniformBuffer._ublockB[2])._ub._uc, metal::bool4(false, false, false, false));
  _uresult *= ANGLE_sc3b;
  float ANGLE_sc3c = _ucompare_bool((*ANGLE_uniformBuffer._ublockB[2])._ud, true);
  _uresult *= ANGLE_sc3c;
  ANGLE_fragmentOut._udEQP_FragColor = ANGLE_sbf3(1.0f, ANGLE_fragmentIn._uv_vtxResult, _uresult, 1.0f);
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
        uint32_t ANGLE_sc3e = (ANGLE_angleUniforms.ANGLE_renderArea & 65535u);
        float ANGLE_sc3f = float(ANGLE_sc3e);
        uint32_t ANGLE_sc40 = ANGLE_rshift(ANGLE_angleUniforms.ANGLE_renderArea, 16u);
        float ANGLE_sc41 = float(ANGLE_sc40);
        metal::float2 ANGLE_sc42 = ANGLE_sbf8(ANGLE_sc3f, ANGLE_sc41);
        metal::float2 ANGLE_sc43 = (ANGLE_sc42 * 0.5f);
        metal::float2 ANGLE_sc44 = (ANGLE_invocationFragmentGlobals.gl_FragCoord.xy - ANGLE_sc43);
        metal::float4 ANGLE_sc45 = metal::unpack_snorm4x8_to_float(ANGLE_angleUniforms.ANGLE_flipXY);
        metal::float2 ANGLE_sc46 = (ANGLE_sc44 * ANGLE_sc45.xy);
        uint32_t ANGLE_sc47 = (ANGLE_angleUniforms.ANGLE_renderArea & 65535u);
        float ANGLE_sc48 = float(ANGLE_sc47);
        uint32_t ANGLE_sc49 = ANGLE_rshift(ANGLE_angleUniforms.ANGLE_renderArea, 16u);
        float ANGLE_sc4a = float(ANGLE_sc49);
        metal::float2 ANGLE_sc4b = ANGLE_sbfb(ANGLE_sc48, ANGLE_sc4a);
        metal::float2 ANGLE_sc4c = (ANGLE_sc4b * 0.5f);
        ANGLE_nonConstGlobals.ANGLE_flippedFragCoord.xy = (ANGLE_sc46 + ANGLE_sc4c);
        ANGLE__0_main(ANGLE_uniformBuffer, ANGLE_fragmentOut, ANGLE_fragmentIn);
        if (ANGLEMultisampledRendering)
        {
          ANGLE_fragmentOut.ANGLE_metal_SampleMask = ANGLE_angleUniforms.ANGLE_coverageMask;
          if (ANGLEEmulateAlphaToCoverage)
          {
            uint32_t ANGLE_sc4e = ANGLE_rshift(ANGLE_angleUniforms.ANGLE_misc, 21u);
            uint32_t ANGLE_sc4f = (ANGLE_sc4e & 1u);
            bool ANGLE_sc50 = bool(ANGLE_sc4f);
            if (ANGLE_sc50)
            {
              int ANGLE_sbec = gl_FragCoord.x;
              int ANGLE_sbed = gl_FragCoord.y;
              ANGLE_sbec = ANGLE_ilshift(ANGLE_sbec, 1);
              ANGLE_sbed &= 1;
              ANGLE_sbec = ANGLE_subInt(ANGLE_sbec, ANGLE_sbed);
              ANGLE_sbec &= 3;
              float ANGLE_sbef = metal::saturate(ANGLE_ALPHA0);
              ANGLE_sbef *= 510.0f;
              int ANGLE_sbf0 = ANGLE_ftoi<int>(ANGLE_sbef);
              uint32_t ANGLE_sc53 = metal::get_num_samples();
              switch (ANGLE_sc53)
              {
                case 2:
                  ANGLE_sbec = ANGLE_ilshift(ANGLE_sbec, 6);
                  ANGLE_sbf0 = ANGLE_addInt(ANGLE_sbf0, 225);
                  ANGLE_sbf0 = ANGLE_subInt(ANGLE_sbf0, ANGLE_sbec);
                  ANGLE_sbf0 = ANGLE_rshift(ANGLE_sbf0, 8);
                  ANGLE_sbf0 = ANGLE_imul(ANGLE_sbf0, 3);
                  ANGLE_sbf0 = ANGLE_rshift(ANGLE_sbf0, 1);
                  break;
                case 4:
                  ANGLE_sbec = ANGLE_ilshift(ANGLE_sbec, 5);
                  ANGLE_sbf0 = ANGLE_addInt(ANGLE_sbf0, 113);
                  ANGLE_sbf0 = ANGLE_subInt(ANGLE_sbf0, ANGLE_sbec);
                  ANGLE_sbf0 = ANGLE_rshift(ANGLE_sbf0, 7);
                  ANGLE_sbf0 = ANGLE_ilshift(ANGLE_sbf0, 2);
                  ANGLE_sbf0 = ANGLE_rshift(1030416, ANGLE_sbf0);
                  break;
                case 8:
                  ANGLE_sbec = ANGLE_ilshift(ANGLE_sbec, 4);
                  ANGLE_sbf0 = ANGLE_addInt(ANGLE_sbf0, 57);
                  ANGLE_sbf0 = ANGLE_subInt(ANGLE_sbf0, ANGLE_sbec);
                  ANGLE_sbf0 = ANGLE_rshift(ANGLE_sbf0, 6);
                  ANGLE_sbf0 = ANGLE_ulshift(4294967295u, ANGLE_sbf0);
                  ANGLE_sbf0 = (~ANGLE_sbf0);
                  break;
              }
              ANGLE_fragmentOut.ANGLE_metal_SampleMask &= ANGLE_sbf0;
            } else {}
          } else {}
        } else {}
      }
    }
    return ANGLE_fragmentOut;;
  }
}

