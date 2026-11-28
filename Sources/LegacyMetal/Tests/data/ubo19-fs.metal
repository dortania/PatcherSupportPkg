// languageVersion 0x30001 fastMath 1


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

struct _bBlockF
{
  metal::float2x2 _uk;
  metal::float3x3 _ul;
  metal::uint2 _um;
  metal::int2 _un;
};

struct _bBlockE
{
  metal::float2x3 _ug;
  metal::uint3 _uh;
  metal::float3x4 _ui;
  metal::bool4 _uj;
};

struct _bBlockB
{
  metal::float3 _ua;
  uint32_t _ub;
  float _uc;
  metal::float2 _ud;
};

struct ANGLE_UniformBuffer
{
  constant _bBlockB * _ublockB[[id(0)]];
  constant _bBlockE * _ublockE[[id(1)]];
  constant _bBlockF * ANGLE__1[[id(2)]];
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

metal::float2 ANGLE_sc08(float ANGLE_sc09, float ANGLE_sc0a)
{
  metal::float2 ANGLE_sc0b = metal::float2(ANGLE_sc09, ANGLE_sc0a);
  return ANGLE_sc0b;;
}

metal::float2 ANGLE_sc05(float ANGLE_sc06, float ANGLE_sc07)
{
  metal::float2 ANGLE_sc0c = metal::float2(ANGLE_sc06, ANGLE_sc07);
  return ANGLE_sc0c;;
}

metal::float4 ANGLE_sc00(float ANGLE_sc01, float ANGLE_sc02, float ANGLE_sc03, float ANGLE_sc04)
{
  metal::float4 ANGLE_sc0d = metal::float4(ANGLE_sc01, ANGLE_sc02, ANGLE_sc03, ANGLE_sc04);
  return ANGLE_sc0d;;
}

float _ucompare_float(float _ua, float _ub)
{
  float ANGLE_sc0e = (_ua - _ub);
  float ANGLE_sc0f = metal::abs(ANGLE_sc0e);
  float ANGLE_sc11;
  if (ANGLE_sc0f < 0.0500000007f)
  {
    ANGLE_sc11 = 1.0f;
  }
  else
  {
    ANGLE_sc11 = 0.0f;
  }
  return ANGLE_sc11;;
}

float _ucompare_vec2(metal::float2 _ua, metal::float2 _ub)
{
  float ANGLE_sc12 = _ucompare_float(_ua.x, _ub.x);
  float ANGLE_sc13 = _ucompare_float(_ua.y, _ub.y);
  float ANGLE_sc14 = (ANGLE_sc12 * ANGLE_sc13);
  return ANGLE_sc14;;
}

float _ucompare_vec3(metal::float3 _ua, metal::float3 _ub)
{
  float ANGLE_sc15 = _ucompare_float(_ua.x, _ub.x);
  float ANGLE_sc16 = _ucompare_float(_ua.y, _ub.y);
  float ANGLE_sc17 = (ANGLE_sc15 * ANGLE_sc16);
  float ANGLE_sc18 = _ucompare_float(_ua.z, _ub.z);
  float ANGLE_sc19 = (ANGLE_sc17 * ANGLE_sc18);
  return ANGLE_sc19;;
}

float _ucompare_vec4(metal::float4 _ua, metal::float4 _ub)
{
  float ANGLE_sc1a = _ucompare_float(_ua.x, _ub.x);
  float ANGLE_sc1b = _ucompare_float(_ua.y, _ub.y);
  float ANGLE_sc1c = (ANGLE_sc1a * ANGLE_sc1b);
  float ANGLE_sc1d = _ucompare_float(_ua.z, _ub.z);
  float ANGLE_sc1e = (ANGLE_sc1c * ANGLE_sc1d);
  float ANGLE_sc1f = _ucompare_float(_ua.w, _ub.w);
  float ANGLE_sc20 = (ANGLE_sc1e * ANGLE_sc1f);
  return ANGLE_sc20;;
}

float _ucompare_mat2(metal::float2x2 _ua, metal::float2x2 _ub)
{
  float ANGLE_sc21 = _ucompare_vec2(_ua[0], _ub[0]);
  float ANGLE_sc22 = _ucompare_vec2(_ua[1], _ub[1]);
  float ANGLE_sc23 = (ANGLE_sc21 * ANGLE_sc22);
  return ANGLE_sc23;;
}

float _ucompare_mat2x3(metal::float2x3 _ua, metal::float2x3 _ub)
{
  float ANGLE_sc24 = _ucompare_vec3(_ua[0], _ub[0]);
  float ANGLE_sc25 = _ucompare_vec3(_ua[1], _ub[1]);
  float ANGLE_sc26 = (ANGLE_sc24 * ANGLE_sc25);
  return ANGLE_sc26;;
}

float _ucompare_mat3(metal::float3x3 _ua, metal::float3x3 _ub)
{
  float ANGLE_sc27 = _ucompare_vec3(_ua[0], _ub[0]);
  float ANGLE_sc28 = _ucompare_vec3(_ua[1], _ub[1]);
  float ANGLE_sc29 = (ANGLE_sc27 * ANGLE_sc28);
  float ANGLE_sc2a = _ucompare_vec3(_ua[2], _ub[2]);
  float ANGLE_sc2b = (ANGLE_sc29 * ANGLE_sc2a);
  return ANGLE_sc2b;;
}

float _ucompare_mat3x4(metal::float3x4 _ua, metal::float3x4 _ub)
{
  float ANGLE_sc2c = _ucompare_vec4(_ua[0], _ub[0]);
  float ANGLE_sc2d = _ucompare_vec4(_ua[1], _ub[1]);
  float ANGLE_sc2e = (ANGLE_sc2c * ANGLE_sc2d);
  float ANGLE_sc2f = _ucompare_vec4(_ua[2], _ub[2]);
  float ANGLE_sc30 = (ANGLE_sc2e * ANGLE_sc2f);
  return ANGLE_sc30;;
}

float _ucompare_ivec2(metal::int2 _ua, metal::int2 _ub)
{
  float ANGLE_sc32;
  if (ANGLE_equal(_ua, _ub))
  {
    ANGLE_sc32 = 1.0f;
  }
  else
  {
    ANGLE_sc32 = 0.0f;
  }
  return ANGLE_sc32;;
}

float _ucompare_uint(uint32_t _ua, uint32_t _ub)
{
  float ANGLE_sc34;
  if (_ua == _ub)
  {
    ANGLE_sc34 = 1.0f;
  }
  else
  {
    ANGLE_sc34 = 0.0f;
  }
  return ANGLE_sc34;;
}

float _ucompare_uvec2(metal::uint2 _ua, metal::uint2 _ub)
{
  float ANGLE_sc36;
  if (ANGLE_equal(_ua, _ub))
  {
    ANGLE_sc36 = 1.0f;
  }
  else
  {
    ANGLE_sc36 = 0.0f;
  }
  return ANGLE_sc36;;
}

float _ucompare_uvec3(metal::uint3 _ua, metal::uint3 _ub)
{
  float ANGLE_sc38;
  if (ANGLE_equal(_ua, _ub))
  {
    ANGLE_sc38 = 1.0f;
  }
  else
  {
    ANGLE_sc38 = 0.0f;
  }
  return ANGLE_sc38;;
}

float _ucompare_bvec4(metal::bool4 _ua, metal::bool4 _ub)
{
  float ANGLE_sc3a;
  if (ANGLE_equal(_ua, _ub))
  {
    ANGLE_sc3a = 1.0f;
  }
  else
  {
    ANGLE_sc3a = 0.0f;
  }
  return ANGLE_sc3a;;
}

void ANGLE__0_main(constant ANGLE_UniformBuffer & ANGLE_uniformBuffer, thread ANGLE_FragmentOut & ANGLE_fragmentOut, thread ANGLE_FragmentIn & ANGLE_fragmentIn)
{
  ANGLE_fragmentOut._udEQP_FragColor = metal::float4(0.0f, 0.0f, 0.0f, 0.0f);
  float _uresult = 1.0f;
  float ANGLE_sc3b = _ucompare_vec3((*ANGLE_uniformBuffer._ublockB)._ua, metal::float3(-1.0f, 7.0f, -1.0f));
  _uresult *= ANGLE_sc3b;
  float ANGLE_sc3c = _ucompare_uint((*ANGLE_uniformBuffer._ublockB)._ub, 4u);
  _uresult *= ANGLE_sc3c;
  float ANGLE_sc3d = _ucompare_float((*ANGLE_uniformBuffer._ublockB)._uc, -4.0f);
  _uresult *= ANGLE_sc3d;
  float ANGLE_sc3e = _ucompare_vec2((*ANGLE_uniformBuffer._ublockB)._ud, metal::float2(8.0f, 4.0f));
  _uresult *= ANGLE_sc3e;
  float ANGLE_sc3f = _ucompare_mat2x3((*ANGLE_uniformBuffer._ublockE)._ug, metal::float2x3(-7.0f, 2.0f, 2.0f, -6.0f, -2.0f, 9.0f));
  _uresult *= ANGLE_sc3f;
  float ANGLE_sc40 = _ucompare_uvec3((*ANGLE_uniformBuffer._ublockE)._uh, metal::uint3(1u, 4u, 9u));
  _uresult *= ANGLE_sc40;
  float ANGLE_sc41 = _ucompare_mat3x4((*ANGLE_uniformBuffer._ublockE)._ui, metal::float3x4(-5.0f, -6.0f, 2.0f, -5.0f, 4.0f, 7.0f, 7.0f, -1.0f, -1.0f, 3.0f, 0.0f, 8.0f));
  _uresult *= ANGLE_sc41;
  float ANGLE_sc42 = _ucompare_bvec4((*ANGLE_uniformBuffer._ublockE)._uj, metal::bool4(true, true, true, true));
  _uresult *= ANGLE_sc42;
  float ANGLE_sc43 = _ucompare_mat2((*ANGLE_uniformBuffer.ANGLE__1)._uk, metal::float2x2(6.0f, 5.0f, 9.0f, 0.0f));
  _uresult *= ANGLE_sc43;
  float ANGLE_sc44 = _ucompare_mat3((*ANGLE_uniformBuffer.ANGLE__1)._ul, metal::float3x3(-3.0f, -7.0f, 7.0f, 0.0f, 4.0f, 3.0f, -6.0f, 4.0f, -3.0f));
  _uresult *= ANGLE_sc44;
  float ANGLE_sc45 = _ucompare_uvec2((*ANGLE_uniformBuffer.ANGLE__1)._um, metal::uint2(9u, 8u));
  _uresult *= ANGLE_sc45;
  float ANGLE_sc46 = _ucompare_ivec2((*ANGLE_uniformBuffer.ANGLE__1)._un, metal::int2(3, -4));
  _uresult *= ANGLE_sc46;
  ANGLE_fragmentOut._udEQP_FragColor = ANGLE_sc00(1.0f, ANGLE_fragmentIn._uv_vtxResult, _uresult, 1.0f);
}

fragment ANGLE_FragmentOut main0(constant ANGLE_UniformBuffer & ANGLE_uniformBuffer [[buffer(24)]], ANGLE_FragmentIn ANGLE_fragmentIn [[stage_in]], constant ANGLEUniformBlock & ANGLE_angleUniforms [[buffer(17)]], metal::float4 gl_FragCoord [[position]])
{
  ANGLE_InvocationFragmentGlobals ANGLE_invocationFragmentGlobals;
  ANGLE_invocationFragmentGlobals.gl_FragCoord = gl_FragCoord;
  {
    ANGLE_FragmentOut ANGLE_fragmentOut;
    {
      ANGLE_NonConstGlobals ANGLE_nonConstGlobals;
      {
        ANGLE_nonConstGlobals.ANGLE_flippedFragCoord = ANGLE_invocationFragmentGlobals.gl_FragCoord;
        uint32_t ANGLE_sc48 = (ANGLE_angleUniforms.ANGLE_renderArea & 65535u);
        float ANGLE_sc49 = float(ANGLE_sc48);
        uint32_t ANGLE_sc4a = ANGLE_rshift(ANGLE_angleUniforms.ANGLE_renderArea, 16u);
        float ANGLE_sc4b = float(ANGLE_sc4a);
        metal::float2 ANGLE_sc4c = ANGLE_sc05(ANGLE_sc49, ANGLE_sc4b);
        metal::float2 ANGLE_sc4d = (ANGLE_sc4c * 0.5f);
        metal::float2 ANGLE_sc4e = (ANGLE_invocationFragmentGlobals.gl_FragCoord.xy - ANGLE_sc4d);
        metal::float4 ANGLE_sc4f = metal::unpack_snorm4x8_to_float(ANGLE_angleUniforms.ANGLE_flipXY);
        metal::float2 ANGLE_sc50 = (ANGLE_sc4e * ANGLE_sc4f.xy);
        uint32_t ANGLE_sc51 = (ANGLE_angleUniforms.ANGLE_renderArea & 65535u);
        float ANGLE_sc52 = float(ANGLE_sc51);
        uint32_t ANGLE_sc53 = ANGLE_rshift(ANGLE_angleUniforms.ANGLE_renderArea, 16u);
        float ANGLE_sc54 = float(ANGLE_sc53);
        metal::float2 ANGLE_sc55 = ANGLE_sc08(ANGLE_sc52, ANGLE_sc54);
        metal::float2 ANGLE_sc56 = (ANGLE_sc55 * 0.5f);
        ANGLE_nonConstGlobals.ANGLE_flippedFragCoord.xy = (ANGLE_sc50 + ANGLE_sc56);
        ANGLE__0_main(ANGLE_uniformBuffer, ANGLE_fragmentOut, ANGLE_fragmentIn);
        if (ANGLEMultisampledRendering)
        {
          ANGLE_fragmentOut.ANGLE_metal_SampleMask = ANGLE_angleUniforms.ANGLE_coverageMask;
          if (ANGLEEmulateAlphaToCoverage)
          {
            uint32_t ANGLE_sc58 = ANGLE_rshift(ANGLE_angleUniforms.ANGLE_misc, 21u);
            uint32_t ANGLE_sc59 = (ANGLE_sc58 & 1u);
            bool ANGLE_sc5a = bool(ANGLE_sc59);
            if (ANGLE_sc5a)
            {
              int ANGLE_sbf9 = gl_FragCoord.x;
              int ANGLE_sbfa = gl_FragCoord.y;
              ANGLE_sbf9 = ANGLE_ilshift(ANGLE_sbf9, 1);
              ANGLE_sbfa &= 1;
              ANGLE_sbf9 = ANGLE_subInt(ANGLE_sbf9, ANGLE_sbfa);
              ANGLE_sbf9 &= 3;
              float ANGLE_sbfc = metal::saturate(ANGLE_ALPHA0);
              ANGLE_sbfc *= 510.0f;
              int ANGLE_sbfd = ANGLE_ftoi<int>(ANGLE_sbfc);
              uint32_t ANGLE_sc5d = metal::get_num_samples();
              switch (ANGLE_sc5d)
              {
                case 2:
                  ANGLE_sbf9 = ANGLE_ilshift(ANGLE_sbf9, 6);
                  ANGLE_sbfd = ANGLE_addInt(ANGLE_sbfd, 225);
                  ANGLE_sbfd = ANGLE_subInt(ANGLE_sbfd, ANGLE_sbf9);
                  ANGLE_sbfd = ANGLE_rshift(ANGLE_sbfd, 8);
                  ANGLE_sbfd = ANGLE_imul(ANGLE_sbfd, 3);
                  ANGLE_sbfd = ANGLE_rshift(ANGLE_sbfd, 1);
                  break;
                case 4:
                  ANGLE_sbf9 = ANGLE_ilshift(ANGLE_sbf9, 5);
                  ANGLE_sbfd = ANGLE_addInt(ANGLE_sbfd, 113);
                  ANGLE_sbfd = ANGLE_subInt(ANGLE_sbfd, ANGLE_sbf9);
                  ANGLE_sbfd = ANGLE_rshift(ANGLE_sbfd, 7);
                  ANGLE_sbfd = ANGLE_ilshift(ANGLE_sbfd, 2);
                  ANGLE_sbfd = ANGLE_rshift(1030416, ANGLE_sbfd);
                  break;
                case 8:
                  ANGLE_sbf9 = ANGLE_ilshift(ANGLE_sbf9, 4);
                  ANGLE_sbfd = ANGLE_addInt(ANGLE_sbfd, 57);
                  ANGLE_sbfd = ANGLE_subInt(ANGLE_sbfd, ANGLE_sbf9);
                  ANGLE_sbfd = ANGLE_rshift(ANGLE_sbfd, 6);
                  ANGLE_sbfd = ANGLE_ulshift(4294967295u, ANGLE_sbfd);
                  ANGLE_sbfd = (~ANGLE_sbfd);
                  break;
              }
              ANGLE_fragmentOut.ANGLE_metal_SampleMask &= ANGLE_sbfd;
            } else {}
          } else {}
        } else {}
      }
    }
    return ANGLE_fragmentOut;;
  }
}

