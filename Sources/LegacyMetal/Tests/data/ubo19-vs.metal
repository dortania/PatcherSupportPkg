// languageVersion 0x30001 fastMath 1


#include <metal_stdlib>

#define ANGLE_ALWAYS_INLINE __attribute__((always_inline))

ANGLE_ALWAYS_INLINE int ANGLE_int_clamp(int value, int minValue, int maxValue)
{
    return ((value < minValue) ?  minValue : ((value > maxValue) ? maxValue : value));
};

#if TRANSFORM_FEEDBACK_ENABLED
    #define __VERTEX_OUT(args) void
#else
    #define __VERTEX_OUT(args) args
#endif

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

#define ANGLE_ALPHA0

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

struct _bBlockD
{
  metal::bool3 _uf;
};

struct _bBlockC
{
  metal::int2 _ue;
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
  constant _bBlockC * _ublockC[[id(1)]];
  constant _bBlockD * ANGLE__1[[id(2)]];
};

struct ANGLE_VertexOut
{
  float _uv_vtxResult;
  metal::float4 gl_Position [[position]];
  float gl_PointSize [[point_size]];
};

struct ANGLE_VertexIn
{
  metal::float4 _ua_position[[attribute(0)]];
};

metal::float4 ANGLE_sbf6(float ANGLE_sbf7, float ANGLE_sbf8, float ANGLE_sbf9, float ANGLE_sbfa)
{
  metal::float4 ANGLE_sbfb = metal::float4(ANGLE_sbf7, ANGLE_sbf8, ANGLE_sbf9, ANGLE_sbfa);
  return ANGLE_sbfb;;
}

float _ucompare_float(float _ua, float _ub)
{
  float ANGLE_sbfc = (_ua - _ub);
  float ANGLE_sbfd = metal::abs(ANGLE_sbfc);
  float ANGLE_sbff;
  if (ANGLE_sbfd < 0.0500000007f)
  {
    ANGLE_sbff = 1.0f;
  }
  else
  {
    ANGLE_sbff = 0.0f;
  }
  return ANGLE_sbff;;
}

float _ucompare_ivec2(metal::int2 _ua, metal::int2 _ub)
{
  float ANGLE_sc01;
  if (ANGLE_equal(_ua, _ub))
  {
    ANGLE_sc01 = 1.0f;
  }
  else
  {
    ANGLE_sc01 = 0.0f;
  }
  return ANGLE_sc01;;
}

float _ucompare_uint(uint32_t _ua, uint32_t _ub)
{
  float ANGLE_sc03;
  if (_ua == _ub)
  {
    ANGLE_sc03 = 1.0f;
  }
  else
  {
    ANGLE_sc03 = 0.0f;
  }
  return ANGLE_sc03;;
}

float _ucompare_bvec3(metal::bool3 _ua, metal::bool3 _ub)
{
  float ANGLE_sc05;
  if (ANGLE_equal(_ua, _ub))
  {
    ANGLE_sc05 = 1.0f;
  }
  else
  {
    ANGLE_sc05 = 0.0f;
  }
  return ANGLE_sc05;;
}

void ANGLE__0_main(constant ANGLE_UniformBuffer & ANGLE_uniformBuffer, thread ANGLE_VertexOut & ANGLE_vertexOut, thread ANGLE_VertexIn & ANGLE_vertexIn)
{
  ANGLE_vertexOut.gl_Position = metal::float4(0.0f, 0.0f, 0.0f, 0.0f);
  ANGLE_vertexOut._uv_vtxResult = 0.0f;
  ANGLE_vertexOut.gl_Position = ANGLE_vertexIn._ua_position;
  float _uresult = 1.0f;
  float ANGLE_sc06 = _ucompare_uint((*ANGLE_uniformBuffer._ublockB)._ub, 4u);
  _uresult *= ANGLE_sc06;
  float ANGLE_sc07 = _ucompare_float((*ANGLE_uniformBuffer._ublockB)._uc, -4.0f);
  _uresult *= ANGLE_sc07;
  float ANGLE_sc08 = _ucompare_ivec2((*ANGLE_uniformBuffer._ublockC)._ue, metal::int2(-1, 9));
  _uresult *= ANGLE_sc08;
  float ANGLE_sc09 = _ucompare_bvec3((*ANGLE_uniformBuffer.ANGLE__1)._uf, metal::bool3(false, true, true));
  _uresult *= ANGLE_sc09;
  ANGLE_vertexOut._uv_vtxResult = _uresult;
}

vertex __VERTEX_OUT(ANGLE_VertexOut)  main0(constant ANGLE_UniformBuffer & ANGLE_uniformBuffer [[buffer(24)]], ANGLE_VertexIn ANGLE_vertexIn [[stage_in]], constant ANGLEUniformBlock & ANGLE_angleUniforms [[buffer(17)]], uint32_t ANGLE_instanceIdMod [[instance_id]], uint32_t ANGLE_baseInstance [[base_instance]], uint32_t ANGLE_vertexIDMetal [[vertex_id]]  )
{
  ANGLE_VertexOut ANGLE_vertexOut;
  {
    ANGLE_vertexOut.gl_PointSize = 1.0f;
    ANGLE__0_main(ANGLE_uniformBuffer, ANGLE_vertexOut, ANGLE_vertexIn);
    
    float ANGLE_sc0b;
    if (ANGLE_angleUniforms.ANGLE_depthRange.y < ANGLE_angleUniforms.ANGLE_depthRange.x)
    {
      ANGLE_sc0b = -1.0f;
    }
    else
    {
      ANGLE_sc0b = 1.0f;
    }
    ANGLE_vertexOut.gl_Position.z = (ANGLE_vertexOut.gl_Position.z * ANGLE_sc0b);
    uint32_t ANGLE_sc0d = ANGLE_rshift(ANGLE_angleUniforms.ANGLE_misc, 20u);
    uint32_t ANGLE_sc0e = (ANGLE_sc0d & 1u);
    bool ANGLE_sc0f = bool(ANGLE_sc0e);
    if (ANGLE_sc0f)
    {
      float ANGLE_sc10 = (ANGLE_vertexOut.gl_Position.z + ANGLE_vertexOut.gl_Position.w);
      ANGLE_vertexOut.gl_Position.z = (ANGLE_sc10 * 0.5f);
    } else {}
    metal::float4 ANGLE_sc12 = metal::unpack_snorm4x8_to_float(ANGLE_angleUniforms.ANGLE_flipXY);
    ANGLE_vertexOut.gl_Position.y = (ANGLE_vertexOut.gl_Position.y * ANGLE_sc12.w);
    if (ANGLERasterizerDisabled)
    {
      ANGLE_vertexOut.gl_Position = ANGLE_sbf6(-3.0f, -3.0f, -3.0f, 1.0f);
    } else {}
  }
  #if TRANSFORM_FEEDBACK_ENABLED
  return;
  #else
  return ANGLE_vertexOut;
  #endif

}

