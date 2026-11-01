// Counters are being captured in multiple rounds. For small draw call, data can vary pretty significantly. So we need to cap the rate.

function GPUTime()
{
    return MTLStat_nSec;
}

function GPUBusy()
{
    if (AMDStat_GPU_Engine_Busy_Ticks < AMDStat_GPU_Engine_Ticks)
        return (AMDStat_GPU_Engine_Busy_Ticks/AMDStat_GPU_Engine_Ticks * 100);
    else
        return 100;
}

function GPUStall()
{
    return 100 - GPUBusy();
}

function ShaderCoreUtilization()
{
    if (MTLStatComputeCost != 0)
        return MTLStatComputeCost;
    else
        return MTLStatShaderCost;
}

function ShaderCoreALUActive()
{
    var rate = 0;
    if (MTLStatComputeCost != 0)
        rate = (((AMDStat_Compute_SALU_Insts + AMDStat_Compute_VALU_Inst_Cycles) / NumSE) / AMDStat_GPU_Engine_Busy_Ticks) / (NumCUPerSH * NumSH) * 100;
    else
        rate = (((AMDStat_Shader_SALU_Cycles + AMDStat_Shader_VALU_Cycles) / NumSE) / AMDStat_GPU_Engine_Busy_Ticks) / (NumCUPerSH * NumSH) * 100;

    return (rate > 100 ? 100 : rate);
}

function ShaderCoreStall()
{
    var OtherActive = (((AMDStat_Shader_VMEM_Read_Cycles + AMDStat_Shader_VMEM_Write_Cycles + AMDStat_Shader_EXP_Cycles + AMDStat_Shader_GDS_Cycles) / NumSE) / AMDStat_GPU_Engine_Busy_Ticks) / (NumCUPerSH * NumSH) * 100;
    var AllActive = ShaderCoreALUActive() + OtherActive;
    if (AllActive >= MTLStatShaderCost)
        return 0;
    else
        return MTLStatShaderCost - AllActive;
}

function ShaderCoreVertexALUActive()
{
    var rate = (((AMDStat_Vertex_SALU_Insts + AMDStat_Vertex_VALU_Inst_Cycles) / NumSE) / AMDStat_GPU_Engine_Busy_Ticks) / (NumCUPerSH * NumSH) * 100;
    return (rate > 100 ? 100 : rate);
}

function ShaderCoreFragmentALUActive()
{
    var rate = (((AMDStat_Fragment_SALU_Insts + AMDStat_Fragment_VALU_Inst_Cycles) / NumSE) / AMDStat_GPU_Engine_Busy_Ticks) / (NumCUPerSH * NumSH) * 100;
    return (rate > 100 ? 100 : rate);
}

function ShaderCoreVertexStall()
{
    // Percentage of GPU time that shader core is doing real work for vertex shader.
    var Active = (((AMDStat_Vertex_VALU_Inst_Cycles + AMDStat_Vertex_SALU_Insts + AMDStat_Vertex_VMEM_Inst_Cycles + AMDStat_Vertex_SMEM_Insts + AMDStat_Vertex_EXP_Insts) / NumSE) / AMDStat_GPU_Engine_Busy_Ticks) / (NumCUPerSH * NumSH) * 100;
    // (VertexShaderBusyPercentage - Active) is the percentage of GPU time that shader core is being stalled for vertex shader workload.
    if (Active >= MTLStatVertexCost)
        return 0;
    else
        return MTLStatVertexCost - Active;
}

function ShaderCoreFragmentStall()
{
    var Active = (((AMDStat_Fragment_VALU_Inst_Cycles + AMDStat_Fragment_SALU_Insts + AMDStat_Fragment_VMEM_Inst_Cycles + AMDStat_Fragment_SMEM_Insts + AMDStat_Fragment_EXP_Insts) / NumSE) / AMDStat_GPU_Engine_Busy_Ticks) / (NumCUPerSH * NumSH) * 100;
    if (Active >= MTLStatFragmentCost)
        return 0;
    else
        return MTLStatFragmentCost - Active;
}

function MemoryStallPerWavefrontCompute()
{
    var MemWait = (AMDStat_Compute_WAIT_CNT_VMVS > AMDStat_Compute_Wait_Inst_VMEM) ? AMDStat_Compute_WAIT_CNT_VMVS : AMDStat_Compute_Wait_Inst_VMEM;
    var rate = (MemWait / AMDStat_Compute_Waves_Executed) / AverageWavefrontLatencyCompute() * 100;
    return (rate >= 99) ? 99 : rate;
}

function MemoryStallPerWavefrontVertex()
{
    var MemWait = (AMDStat_Vertex_WAIT_CNT_VMVS > AMDStat_Vertex_Wait_Inst_VMEM) ? AMDStat_Vertex_WAIT_CNT_VMVS : AMDStat_Vertex_Wait_Inst_VMEM;
    var rate = (MemWait / AMDStat_Vertex_Waves_Executed) / AverageWavefrontLatencyVertex() * 100;
    return (rate >= 99) ? 99 : rate;
}

function MemoryStallPerWavefrontFragment()
{
    var MemWait = (AMDStat_Fragment_WAIT_CNT_VMVS > AMDStat_Fragment_Wait_Inst_VMEM) ? AMDStat_Fragment_WAIT_CNT_VMVS : AMDStat_Fragment_Wait_Inst_VMEM;
    var rate = (MemWait / AMDStat_Fragment_Waves_Executed) / AverageWavefrontLatencyFragment() * 100;
    return (rate >= 99) ? 99 : rate;
}

function LdsStallPerWavefrontCompute()
{
    var LdsWait = (AMDStat_Compute_WAIT_CNT_LGKM > AMDStat_Compute_LDS_Wait) ? AMDStat_Compute_WAIT_CNT_LGKM : AMDStat_Compute_LDS_Wait;
    var rate = (LdsWait / AMDStat_Compute_Waves_Executed) / AverageWavefrontLatencyCompute() * 100;
    return (rate >= 99) ? 99 : rate;
}

function LdsStallPerWavefrontVertex()
{
    var LdsWait = (AMDStat_Vertex_WAIT_CNT_LGKM > AMDStat_Vertex_LDS_Wait) ? AMDStat_Vertex_WAIT_CNT_LGKM : AMDStat_Vertex_LDS_Wait;
    var rate = (LdsWait / AMDStat_Vertex_Waves_Executed) / AverageWavefrontLatencyVertex() * 100;
    return (rate >= 99) ? 99 : rate;
}

function LdsStallPerWavefrontFragment()
{
    var LdsWait = (AMDStat_Fragment_WAIT_CNT_LGKM > AMDStat_Fragment_LDS_Wait) ? AMDStat_Fragment_WAIT_CNT_LGKM : AMDStat_Fragment_LDS_Wait;
    var rate = (LdsWait / AMDStat_Fragment_Waves_Executed) / AverageWavefrontLatencyFragment() * 100;
    return (rate >= 99) ? 99 : rate;
}

function ExportStallPerWavefrontVertex()
{
    var rate = ((AMDStat_Vertex_WAIT_CNT_EXP + AMDStat_Vertex_Wait_Export_Alloc) / AMDStat_Vertex_Waves_Executed) / AverageWavefrontLatencyVertex() * 100;
    return (rate >= 99) ? 99 : rate;
}

function ExportStallPerWavefrontFragment()
{
    var rate = ((AMDStat_Fragment_Wait_Export_Alloc + AMDStat_Fragment_WAIT_CNT_EXP) / AMDStat_Fragment_Waves_Executed) / AverageWavefrontLatencyFragment() * 100;
    return (rate >= 99) ? 99 : rate;
}

function AverageWavefrontLatencyCompute()
{
    return (AMDStat_Compute_Accum_Prev_Cycles) / AMDStat_Compute_Waves_Executed;
}

function AverageWavefrontLatencyVertex()
{
    return (AMDStat_Vertex_Accum_Prev_Cycles) / AMDStat_Vertex_Waves_Executed;
}

function AverageWavefrontLatencyFragment()
{
    return (AMDStat_Fragment_Accum_Prev_Cycles) / AMDStat_Fragment_Waves_Executed;
}

function AverageWavesInflightCompute()
{
    return (AMDStat_Compute_Accum_Prev_Cycles) / (NumCUPerSH * NumSH) / AMDStat_Compute_Busy_Cycles;
}

function AverageWavesInflightVertex()
{
    return (AMDStat_Vertex_Accum_Prev_Cycles) / (NumCUPerSH * NumSH) / AMDStat_Vertex_Busy_Cycles;
}

function AverageWavesInflightFragment()
{
    return (AMDStat_Fragment_Accum_Prev_Cycles) / (NumCUPerSH * NumSH) / AMDStat_Fragment_Busy_Cycles;
}

function SamplerBusy()
{
    return AMDStat_Sampler_Busy;
}

function L2CacheThroughput()
{
    return (AMDStat_L2_Cache_Request / (AMDStat_L2_Busy / 100 * AMDStat_GPU_Engine_Busy_Ticks));
}

function L2CacheDramBandwidth()
{
    return ((AMDStat_L2_Write_Size + AMDStat_L2_Read_Size) / (AMDStat_L2_Busy / 100 * AMDStat_GPU_Engine_Busy_Ticks)) * SysClkFreq / 100000;
}

function VSInvocation()
{
    if (AMDStat_DS_Invocations == 0)
        return AMDStat_VS_Invocations;
    else
        return AMDStat_DS_Invocations;
}

function CSInvocation()
{
    if (AMDStat_VS_Invocations == 0 && AMDStat_PS_Invocations !=0)
        return AMDStat_PS_Invocations;
    else
        return AMDStat_CS_Invocations;
}

function PSInvocation()
{
    if (AMDStat_VS_Invocations == 0 && AMDStat_PS_Invocations !=0)
        return 0;
    else
        return AMDStat_PS_Invocations;
}

function VertexCost()
{
    return AMDStat_Vertex_Accum_Prev_Cycles / (AMDStat_Vertex_Accum_Prev_Cycles + AMDStat_Fragment_Accum_Prev_Cycles) * 100;
}

function VertexDuration()
{
    return MTLStatVertexCost / (MTLStatVertexCost + MTLStatFragmentCost) * 100;
}

function FragmentCost()
{
    return AMDStat_Fragment_Accum_Prev_Cycles / (AMDStat_Vertex_Accum_Prev_Cycles + AMDStat_Fragment_Accum_Prev_Cycles) * 100;
}

function FragmentDuration()
{
    return MTLStatFragmentCost / (MTLStatVertexCost + MTLStatFragmentCost) * 100;
}

function PixelToVertexRatio()
{
    return (PixelsRasterized() / VerticesSubmitted());
}

function PixelPerTriangle()
{
    return (PixelsRasterized() / PrimitivesSubmitted());
}

function VerticesSubmitted()
{
    if (AMDStat_HS_Invocations == 0)
        return AMDStat_GE_Vertices;
    else
        return AMDStat_VS_Vertices_In;
}

function NumberOfPatchesSubmitted()
{
    if (AMDStat_HS_Invocations > 0)
        return AMDStat_GE_Vertices;
    else
        return 0;
}

function VerticesReused()
{
    if (AMDStat_Vertices_Reuse != 0)
    {
        return (AMDStat_GE_Vertices - AMDStat_VS_Invocations);
    }
    else
        return 0;
}

function VerticesReusedPercentage()
{
    return (VerticesReused() * 100 / AMDStat_GE_Vertices);
}

function VerticesRendered()
{
    return AMDStat_VS_Vertices_In;
}

function VerticesRenderedPercentage()
{
    return (AMDStat_VS_Vertices_In * 100 / VerticesSubmitted());
}

function AverageTessFactor()
{
    if (AMDStat_HS_Invocations > 0)
        return (AMDStat_VS_Vertices_In / AMDStat_GE_Vertices);
    else
        return 0;
}

function PrimitivesSubmitted()
{
    if (AMDStat_HS_Invocations > 0)
        return AMDStat_C_Invocations;
    else
        return AMDStat_GE_Primitives;
}

function PrimitivesRendered()
{
    return AMDStat_C_Primitives;
}

function PrimitivesRenderedPercentage()
{
    return (AMDStat_C_Primitives * 100 / PrimitivesSubmitted());
}

function NumberOfCulledPrimitives()
{
    return AMDStat_Culled_Prims;
}

function NumberOfCulledPrimitivesPercentage()
{
    return (AMDStat_Culled_Prims * 100 / PrimitivesSubmitted());
}

function NumberOfClippedPrimitives()
{
    return AMDStat_Clipped_Prims;
}

function NumberOfClippedPrimitivesPercentage()
{
    return (AMDStat_Clipped_Prims * 100 / PrimitivesSubmitted());
}

function HierarchicalZTotalTilesCount()
{
    return AMDStat_HiZTiles_Total_Count;
}

function HierarchicalZFailPercentage()
{
    return (AMDStat_HiZTiles_Culled_Count * 100 / AMDStat_HiZTiles_Total_Count);
}

function PreZPassSampleCount()
{
    return AMDStat_PreZ_Samples_PassingZ;
}

function PreZFailSampleCount()
{
    return AMDStat_PreZ_Samples_FailingZ;
}

function PreZStencilFailSampleCount()
{
    return AMDStat_PreZ_Samples_FailingS;
}

function PostZPassSampleCount()
{
    return AMDStat_PostZ_Samples_PassingZ;
}

function PostZFailSampleCount()
{
    return AMDStat_PostZ_Samples_FailingZ;
}

function PostZStencilFailSampleCount()
{
    return AMDStat_PostZ_Samples_FailingS;
}

function PixelsRasterized()
{
    return AMDStat_PreHiZ_Total_Quads_Count * 4 * 2;
}

function PreZFailPercentage()
{
    if (AMDStat_FS_Quads_Count != 0)
    {
        return (AMDStat_PreZ_Quads_Count*2 - AMDStat_FS_Quads_Count*2) / (AMDStat_PreHiZ_Total_Quads_Count * 2) * 100;
    }
    else
    {
        // This is Z only rendering
        return 0;
    }
}

function PostZFailPercentage()
{
    var PostZFailRate = (AMDStat_PostZ_Samples_FailingZ + AMDStat_PostZ_Samples_FailingS) / (AMDStat_PostZ_Samples_FailingZ + AMDStat_PostZ_Samples_FailingS + AMDStat_PostZ_Samples_PassingZ);
    if (AMDStat_PostFS_Pixels == 0)
    {
        // This is Z only rendering
        return  (AMDStat_PreZ_Quads_Count * 2 * PostZFailRate) / (AMDStat_PreHiZ_Total_Quads_Count * 2) * 100;
    }
    else
    {
        return (AMDStat_PostFS_Pixels * 2 * PostZFailRate) / (AMDStat_PreHiZ_Total_Quads_Count * 2 * 4) * 100;
    }
}

function PixelsDrawn()
{
    return AMDStat_Pixels_Drawn / NumMRT();
}

function PixelsDrawnPercentage()
{
    return AMDStat_Quads_Drawn / NumMRT() / (AMDStat_PreHiZ_Total_Quads_Count*2) * 100;
}

function FragmentsDrawn()
{
    if (AMDStat_Quads_Drawn == AMDStat_Quad_Fragments_Drawn)
    {
        // No MSAA
        return PixelsDrawn();
    }
    else
    {
        return (AMDStat_Quad_Fragments_Drawn / NumMRT()) *4;
    }
}

function PixelsDiscardedPercentage()
{
    // Cannot use quad * 4 to get approximation about pixels discarded as discard is usually used when some but not all pixels in a quad need to be discarded.
    return (AMDStat_PS_Invocations - AMDStat_PostFS_Pixels) / (AMDStat_PreHiZ_Total_Quads_Count * 2 * 4) * 100;
}

function PixelRate()
{
    return (AMDStat_Pixels_Drawn / (AMDStat_CBDrawn_Busy / 100 * AMDStat_GPU_Engine_Busy_Ticks));
}

function ALUInstructionPerInvocationCompute()
{
    return ((AMDStat_Compute_SALU_Insts + AMDStat_Compute_VALU_Insts) / AMDStat_Compute_Waves_Executed);
}

function ALUInstructionPerInvocationVertex()
{
    return ((AMDStat_Vertex_SALU_Insts + AMDStat_Vertex_VALU_Insts) / AMDStat_Vertex_Waves_Executed);
}

function ALUInstructionPerInvocationFragment()
{
    return ((AMDStat_Fragment_SALU_Insts + AMDStat_Fragment_VALU_Insts) / AMDStat_Fragment_Waves_Executed);
}

function MemInstructionPerInvocationCompute()
{
    return ((AMDStat_Compute_VMEM_Write_Cycles + AMDStat_Compute_VMEM_Read_Cycles + AMDStat_Compute_SMEM_Insts) / AMDStat_Compute_Waves_Executed);
}

function MemInstructionPerInvocationVertex()
{
    return ((AMDStat_Vertex_VMEM_Write_Cycles + AMDStat_Vertex_VMEM_Read_Cycles + AMDStat_Vertex_SMEM_Insts) / AMDStat_Vertex_Waves_Executed);
}

function MemInstructionPerInvocationFragment()
{
    return ((AMDStat_Fragment_VMEM_Write_Cycles + AMDStat_Fragment_VMEM_Read_Cycles + AMDStat_Fragment_SMEM_Insts) / AMDStat_Fragment_Waves_Executed);
}

function ControlInstructionPerInvocationCompute()
{
    return (AMDStat_Compute_Branch_Insts / AMDStat_Compute_Waves_Executed);
}

function ControlInstructionPerInvocationVertex()
{
    return (AMDStat_Vertex_Branch_Insts / AMDStat_Vertex_Waves_Executed);
}

function ControlInstructionPerInvocationFragment()
{
    return (AMDStat_Fragment_Branch_Insts / AMDStat_Fragment_Waves_Executed);
}

function ALUToMemRatioCompute()
{
    return (ALUInstructionPerInvocationCompute() / MemInstructionPerInvocationCompute());
}

function ALUToMemRatioVertex()
{
    return (ALUInstructionPerInvocationVertex() / MemInstructionPerInvocationVertex());
}

function ALUToMemRatioFragment()
{
    return (ALUInstructionPerInvocationFragment() / MemInstructionPerInvocationFragment());
}

function ALUToMemRatio()
{
    return (ALUInstructionPerInvocation() / MemInstructionPerInvocation());
}

function ROPStall()
{
    return (AMDStat_ROP_Stalled_Ticks / AMDStat_GPU_Engine_Busy_Ticks) * 100;
}

function ZeroAreaCullPrims()
{
    return AMDStat_ZeroArea_Culled_Prims;
}

function ZeroAreaCullPrimsPercentage()
{
    return (AMDStat_ZeroArea_Culled_Prims * 100 / PrimitivesSubmitted());
}

function ClipperCullPrims()
{
    return AMDStat_Clipping_Culled_Prims;
}

function ClipperCullPrimsPercentage()
{
    return (AMDStat_Clipping_Culled_Prims * 100 / PrimitivesSubmitted());
}

function TextureUnitStall()
{
    return AMDStat_TexUnit_Stall;
}

function TextureUnitBusy()
{
    return AMDStat_TexUnit_Busy;
}

function TextureCacheMissRate()
{
    return (AMDStat_TextureCache_Miss / (AMDStat_TextureCache_Miss + AMDStat_TextureCache_Hit)) * 100;
}

function L0CacheHitRate()
{
    hitRate = ((AMDStat_L0_Cache_Request - AMDStat_L0_Cache_Miss) / AMDStat_L0_Cache_Request) * 100;
    return (hitRate > 100 ? 100 : hitRate);
}
               
function L0CacheHitCount()
{
    return AMDStat_L0_Cache_Request - AMDStat_L0_Cache_Miss;
}
               
function L0CacheMissCount()
{
    return AMDStat_L0_Cache_Miss;
}

function L1CacheHitRate()
{
    if( AMDStat_L1_Cache_Request != 0)
        hitRate = ((AMDStat_L1_Cache_Request - AMDStat_L1_Cache_Miss) / AMDStat_L1_Cache_Request) * 100;
    else
        hitRate = 0;
    return (hitRate > 100 ? 100 : hitRate);
}

function L1CacheHitCount()
{
    return AMDStat_L1_Cache_Request - AMDStat_L1_Cache_Miss;
}

function L1CacheMissCount()
{
    return AMDStat_L1_Cache_Miss;
}

function L2CacheHitRate()
{
    var hitRate = ((AMDStat_L2_Cache_Request - AMDStat_L2_Cache_Miss) / AMDStat_L2_Cache_Request) * 100;
    return (hitRate > 100 ? 100 : hitRate);
}

function L2CacheMissRate()
{
    var missRate = (AMDStat_L2_Cache_Miss / AMDStat_L2_Cache_Request) * 100;
    return (missRate > 100 ? 100 : missRate);
}

function L2CacheHitCount()
{
    return AMDStat_L2_Cache_Request - AMDStat_L2_Cache_Miss;
}
                    
function L2CacheMissCount()
{
    return AMDStat_L2_Cache_Miss;
}
                    
function FetchSize()
{
    return AMDStat_Tex_Fetch_Size_32B * 32 + AMDStat_Tex_Fetch_Size_64B * 64 + AMDStat_Tex_Fetch_Size_96B * 96 + AMDStat_Tex_Fetch_Size_128B * 128;
}

function WriteSize()
{
    return ((AMDStat_L2_Write_Size - AMDStat_Tex_Write_Size) * 32) + (AMDStat_Tex_Write_Size * 64);
}

function MemUnitBusy()
{
    //TODO handle CPF_PERF_SEL_CPF_STAT_BUSY
    var unitBusy = ((AMDStat_TexUnit_Busy_Ticks / AMDStat_GPU_Engine_Busy_Ticks) / NumSE) * 100;
    return (unitBusy > 100 ? 100 : unitBusy);
}
                    
function MemUnitBusyCycles()
{
    return AMDStat_TexUnit_Busy_Ticks;
}

function MemUnitStalled()
{
    //TODO handle CPF_PERF_SEL_CPF_STAT_BUSY
    var unitStall = ((AMDStat_TexUnit_Stall / AMDStat_GPU_Engine_Busy_Ticks) / NumSE) * 100;
    return (unitStall > 100 ? 100 : unitStall);
}

function MemUnitStalledCycles()
{
    return AMDStat_TexUnit_Stalled_Ticks;
}

function WriteUnitStalled()
{
    //TODO handle CPF_PERF_SEL_CPF_STAT_BUSY
    var unitStall = (AMDStat_L2_Write_Unit_Stalled / AMDStat_GPU_Engine_Busy_Ticks) * 100;
    return (unitStall > 100 ? 100 : unitStall);
}

function WriteUnitStalledCycles()
{
    return AMDStat_L2_Write_Unit_Stalled;
}
                     
function LocalVidMemBytes()
{
    return AMDStat_LocalVidMemBytes;
}
                     
function XGMIBytes()
{
    return AMDStat_XGMIBytes;
}
                     
function PcieBytes()
{
    return AMDStat_PcieBytes;
}
/* TODO
name=LocalVidMemBytes
desc=#GlobalMemory#Number of bytes read from or written to local video memory
type=gpa_float64
usage=bytes
;[DX11Gfx9]
[DX12Gfx9]
[VKGfx9]
GCEA*_PERF_SEL_SARB_DRAM_SIZED_REQUESTS[0..15]
eqn=0..15,sum16,(32),*
  
name=PcieBytes
desc=#GlobalMemory#Number of bytes sent and received over the PCIe bus
type=gpa_float64
usage=bytes
;[DX11Gfx9]
[DX12Gfx9]
[VKGfx9]
GCEA*_PERF_SEL_SARB_IO_SIZED_REQUESTS[0..15]
eqn=0..15,sum16,(32),*
*/

function VertexMemoryFetchLatency()
{
    return (AMDStat_GE_MemRead_Bin0 * 64 + AMDStat_GE_MemRead_Bin1 * (128 + 64) + AMDStat_GE_MemRead_Bin2 * (128 * 2 + 64) + AMDStat_GE_MemRead_Bin3 * (128 * 3 + 64) + AMDStat_GE_MemRead_Bin4 * (128 * 4 + 64) + AMDStat_GE_MemRead_Bin5 * (128 * 5 + 64) + AMDStat_GE_MemRead_Bin6 * (128 * 6 + 64) + AMDStat_GE_MemRead_Bin7 * (128 * 7 + 64)) / (AMDStat_GE_MemRead_Bin0 + AMDStat_GE_MemRead_Bin1 + AMDStat_GE_MemRead_Bin2 + AMDStat_GE_MemRead_Bin3 + AMDStat_GE_MemRead_Bin4 + AMDStat_GE_MemRead_Bin5 + AMDStat_GE_MemRead_Bin6 + AMDStat_GE_MemRead_Bin7);
}

function NumMRT()
{
    return AMDStat_PostFS_Exports / AMDStat_PostFS_Pixels;
}

function PrimitiveRate()
{
    return (
    AMDStat_FrontEnd_Busy_SE0PA0 + AMDStat_FrontEnd_Busy_SE0PA1 +
    AMDStat_FrontEnd_Busy_SE1PA0 + AMDStat_FrontEnd_Busy_SE1PA1 +
    AMDStat_FrontEnd_Busy_SE2PA0 + AMDStat_FrontEnd_Busy_SE2PA1 +
    AMDStat_FrontEnd_Busy_SE3PA0 + AMDStat_FrontEnd_Busy_SE3PA1 )
    /  (AMDStat_FrontEnd_Stall_SE0PA0 + AMDStat_FrontEnd_Stall_SE0PA1 +
        AMDStat_FrontEnd_Stall_SE1PA0 + AMDStat_FrontEnd_Stall_SE1PA1 +
        AMDStat_FrontEnd_Stall_SE2PA0 + AMDStat_FrontEnd_Stall_SE2PA1 +
        AMDStat_FrontEnd_Stall_SE3PA0 + AMDStat_FrontEnd_Stall_SE3PA1 ) +
      ( AMDStat_FrontEnd_StarvedBusy_SE0PA0 + AMDStat_FrontEnd_StarvedBusy_SE0PA1 +
        AMDStat_FrontEnd_StarvedBusy_SE1PA0 + AMDStat_FrontEnd_StarvedBusy_SE1PA1 +
        AMDStat_FrontEnd_StarvedBusy_SE2PA0 + AMDStat_FrontEnd_StarvedBusy_SE2PA1 +
        AMDStat_FrontEnd_StarvedBusy_SE3PA0 + AMDStat_FrontEnd_StarvedBusy_SE3PA1);
}

function VertexRate()
{
    return AMDStat_VS_Vertices_In * NumSE / (AMDStat_VS_Vertices_In + AMDStat_VS_Stalled_Ticks + AMDStat_VS_StarvedBusy_Ticks);
}

function PeakPrimitiveRate()
{
    return NumSE;
}

function PeakVertexRate()
{
    return NumSE;
}

function PeakPixelRate()
{
    return NumROP * 4;
}

function VertexRatePercentage()
{
    return VertexRate() * 100 / PeakVertexRate();
}

function PrimitiveRatePercentage()
{
    return PrimitiveRate() * 100 / PeakPrimitiveRate();
}

function PixelRatePercentage()
{
    return PixelRate() * 100 / PeakPixelRate();
}

function ParameterCacheStall()
{
    return AMDStat_ParameterCache_Stall;
}

function AAMode()
{
    return AMDStat_Quad_Fragments_Drawn / AMDStat_Quad_Drawn;
}

function TessellatorBusy()
{
    return AMDStat_Tessellator_Busy;
}

function CBDrawnBusyRate()
{
    var rate = (AMDStat_CBDrawn_Busy / AMDStat_CB_Busy) * 100;
    return (rate > 100) ? 100 : rate;
}

function ColorBlockL2Throughput()
{
    return (AMDStat_CB_Mem_Read + AMDStat_CB_Mem_Written) / AMDStat_CBDrawn_Busy;
}

function CBMemRead()
{
    return AMDStat_CB_Mem_Read * 32;
}

function CBColorAndMaskRead()
{
    return (AMDStat_CB_FC_MC_DCC_Mem_Read + AMDStat_CB_CM_Mem_Read + AMDStat_CB_FC_Mem_Read + AMDStat_CB_Mem_Read) * 32;
}

function CBMemWritten()
{
    return AMDStat_CB_Mem_Written * 32;
}

function CBColorAndMaskWritten()
{
    return (AMDStat_CB_FC_MC_DCC_Mem_Written + AMDStat_CB_CM_Mem_Written + AMDStat_CB_FC_Mem_Written + AMDStat_CB_Mem_Written) * 32;
}

function CBSlowPixelPct()
{
    var pxl = (AMDStat_Quad_Fragments_32ABGR_Drawn / AMDStat_Quad_Fragments_Drawn) * 100;
    return (pxl > 100) ? 100 : pxl;
}

function CBSlowPixelCount()
{
   return AMDStat_Quad_Fragments_32ABGR_Drawn;
}

function DepthBlockL2Throughput()
{
    return (AMDStat_DB_Tile_Read * 8 + AMDStat_DB_Quad_Read + AMDStat_DB_Tile_Write + AMDStat_DB_Quad_Write) / AMDStat_ZUnit_Busy;
}

function ZUnitStalled()
{
   //TODO handle CPF_PERF_SEL_CPF_STAT_BUSY
   var unitStalled = ((AMDStat_ZUnit_Stalled / AMDStat_GPU_Engine_Busy_Ticks) / NumSE) * 100;
   return (unitStalled > 100 ? 100 : unitStalled);
}

function ZUnitStalledCycles()
{
    return AMDStat_ZUnit_Stalled_Ticks;
}

function DBMemRead()
{
    return (AMDStat_DB_Tile_Read * 256) + (AMDStat_DB_Quad_Read * 32);
}

function DBMemWritten()
{
    return 32 * (AMDStat_DB_Tile_Write + AMDStat_DB_Quad_Write);
}
               
function TexTriFilteringPct()
{
    var pxl = (100 * AMDStat_TexUnit_TriFilteringCount) / (AMDStat_TexUnit_TriFilteringCount + AMDStat_TexUnit_NoTriFilteringCount);
    return (pxl > 100) ? 100 : pxl;
}

function TexTriFilteringCount()
{
    return AMDStat_TexUnit_TriFilteringCount;
}

function NoTexTriFilteringCount()
{
    return AMDStat_TexUnit_NoTriFilteringCount;
}

function TexVolFilteringPct()
{
   var pxl = (100 * AMDStat_TexUnit_TexVolFilteringCount) / (AMDStat_TexUnit_TexVolFilteringCount + AMDStat_TexUnit_NoTexVolFilteringCount);
   return (pxl > 100) ? 100 : pxl;
}

function TexVolFilteringCount()
{
    return AMDStat_TexUnit_TexVolFilteringCount;
}

function NoTexVolFilteringCount()
{
    return AMDStat_TexUnit_NoTexVolFilteringCount;
}

function TexAveAnisotropy()
{
    var unitCount =  AMDStat_TexUnit_Average_Anisotropy_1 +
            ( 2 * AMDStat_TexUnit_Average_Anisotropy_2) +
            ( 4 * AMDStat_TexUnit_Average_Anisotropy_4) +
            ( 6 * AMDStat_TexUnit_Average_Anisotropy_6) +
            ( 8 * AMDStat_TexUnit_Average_Anisotropy_8) +
            ( 10 * AMDStat_TexUnit_Average_Anisotropy_10) +
            ( 12 * AMDStat_TexUnit_Average_Anisotropy_12) +
            ( 14 * AMDStat_TexUnit_Average_Anisotropy_14) +
            ( 16 * AMDStat_TexUnit_Average_Anisotropy_16);
    
    var typeCount = AMDStat_TexUnit_Average_Anisotropy_1 +
                    AMDStat_TexUnit_Average_Anisotropy_2 +
                    AMDStat_TexUnit_Average_Anisotropy_4 +
                    AMDStat_TexUnit_Average_Anisotropy_6 +
                    AMDStat_TexUnit_Average_Anisotropy_8 +
                    AMDStat_TexUnit_Average_Anisotropy_10 +
                    AMDStat_TexUnit_Average_Anisotropy_12 +
                    AMDStat_TexUnit_Average_Anisotropy_14 +
                    AMDStat_TexUnit_Average_Anisotropy_16;
    
    return typeCount / unitCount;
}

function CSVFetchInsts()
{
    if (AMDStat_Compute_Waves_Executed != 0)
        return AMDStat_Compute_Tex_Load_Inst / AMDStat_Compute_Waves_Executed;
    else
        return 0;
}

function CSSFetchInsts()
{
    if (AMDStat_Compute_Waves_Executed != 0)
        return AMDStat_Compute_SMEM_Insts / AMDStat_Compute_Waves_Executed;
    else
        return 0;
}

function CSVWriteInsts()
{
    if (AMDStat_Compute_Waves_Executed != 0)
        return AMDStat_Compute_Tex_Store_Inst / AMDStat_Compute_Waves_Executed;
    else
        return 0;
}

function CSVALUBusy()
{
    //TODO handle CPF_PERF_SEL_CPF_STAT_BUSY
    return ((AMDStat_Compute_VALU_Inst_Cycles / (NumCUPerSH * NumSH)) / AMDStat_GPU_Engine_Busy_Ticks ) * 100;
}
            
function CSVALUBusyCycles()
{
    return AMDStat_Compute_VALU_Inst_Cycles / (NumCUPerSH * NumSH);
}

function CSSALUBusy()
{
    //TODO handle CPF_PERF_SEL_CPF_STAT_BUSY
    return ((AMDStat_Compute_SALU_Insts / (NumCUPerSH * NumSH)) / AMDStat_GPU_Engine_Busy_Ticks ) * 100;
}

function CSSALUBusyCycles()
{
    return AMDStat_Compute_SALU_Insts / (NumCUPerSH * NumSH);
}

function CSMemUnitBusy()
{
    //TODO handle CPF_PERF_SEL_CPF_STAT_BUSY
    var csNumOfThreadGroups = AMDStat_CSG_number_of_threadGrps + AMDStat_CSN_number_of_threadGrps;
    if ( csNumOfThreadGroups != 0)
    {
        var unitBusy = ((AMDStat_TexUnit_Busy_Ticks / AMDStat_GPU_Engine_Busy_Ticks) / NumSE) * 100;
        return (unitBusy > 100 ? 100 : unitBusy);
    }
    else
        return 0;
}

function CSMemUnitBusyCycles()
{
    var csNumOfThreadGroups = AMDStat_CSG_number_of_threadGrps + AMDStat_CSN_number_of_threadGrps;
    if ( csNumOfThreadGroups != 0)
        return AMDStat_TexUnit_Busy_Ticks;
    else
        return 0;
}

function CSMemUnitStalled()
{
    //TODO handle CPF_PERF_SEL_CPF_STAT_BUSY
    var csNumOfThreadGroups = AMDStat_CSG_number_of_threadGrps + AMDStat_CSN_number_of_threadGrps;
    if ( csNumOfThreadGroups != 0)
    {
        var unitStall = ((AMDStat_L0_Stall / AMDStat_GPU_Engine_Busy_Ticks) / NumSE) * 100;
        return (unitStall > 100 ? 100 : unitStall);
    }
    else
        return 0;
}

function CSMemUnitStalledCycles()
{
    var csNumOfThreadGroups = AMDStat_CSG_number_of_threadGrps + AMDStat_CSN_number_of_threadGrps;
    if ( csNumOfThreadGroups != 0)
        return AMDStat_L0_Stall;
    else
        return 0;
}
                         
function CSWriteUnitStalled()
{
    //TODO handle CPF_PERF_SEL_CPF_STAT_BUSY
    var csNumOfThreadGroups = AMDStat_CSG_number_of_threadGrps + AMDStat_CSN_number_of_threadGrps;
    if ( csNumOfThreadGroups != 0)
    {
        var unitStall = ((AMDStat_L2_Write_Unit_Stalled / AMDStat_GPU_Engine_Busy_Ticks) / NumSE) * 100;
        return (unitStall > 100 ? 100 : unitStall);
    }
    else
        return 0;
}
                         
function CSWriteUnitStalledCycles()
{
     var csNumOfThreadGroups = AMDStat_CSG_number_of_threadGrps + AMDStat_CSN_number_of_threadGrps;
     if ( csNumOfThreadGroups != 0)
         return AMDStat_L2_Write_Unit_Stalled;
     else
         return 0;
}

function CSGDSInsts()
{
    if (AMDStat_Compute_Waves_Executed != 0)
        return AMDStat_Compute_GDS_Insts / AMDStat_Compute_Waves_Executed;
    else
        return 0;
}
   
 function CSLDSInsts()
 {
     if (AMDStat_Compute_Waves_Executed != 0)
         return AMDStat_Compute_LDS_Insts / AMDStat_Compute_Waves_Executed;
     else
         return 0;
 }

function CSALUStalledByLDS()
{
    //TODO handle CPF_PERF_SEL_CPF_STAT_BUSY
    if (AMDStat_Compute_Waves_Executed != 0)
        return (((AMDStat_Compute_LDS_Wait / AMDStat_Compute_Waves_Executed) / AMDStat_GPU_Engine_Busy_Ticks) / NumSE ) * 100;
    else
        return 0;
}
                 
function CSLDSBankConflict()
{
    //TODO handle CPF_PERF_SEL_CPF_STAT_BUSY
    var csNumOfThreadGroups = AMDStat_CSG_number_of_threadGrps + AMDStat_CSN_number_of_threadGrps;
    if ( csNumOfThreadGroups != 0)
    {
        var conflict = ( (AMDStat_Compute_LDS_Bank_Conflict / AMDStat_GPU_Engine_Busy_Ticks) / (4 * NumCUPerSH * NumSH)) * 100;
        return (conflict > 100 ? 100 : conflict);
    }
    else
        return 0;
}
              
function CSLDSBankConflictCycles()
{
    var csNumOfThreadGroups = AMDStat_CSG_number_of_threadGrps + AMDStat_CSN_number_of_threadGrps;
    if ( csNumOfThreadGroups != 0)
    {
        return AMDStat_Compute_LDS_Bank_Conflict / (4 * NumCUPerSH * NumSH);
    }
    else
        return 0;
}
                      
function AverageThreadsPerVertexWavefront()
{
    return AMDStat_VS_Invocations / AMDStat_Vertex_Waves_Executed;
}

function AverageThreadsPerFragmentWavefront()
{
    return AMDStat_PS_Invocations / AMDStat_Fragment_Waves_Executed;
}

function AverageThreadsPerComputeWavefront()
{
    if (AMDStat_VS_Invocations == 0 && AMDStat_PS_Invocations !=0)
        return AMDStat_PS_Invocations / AMDStat_Compute_Waves_Executed;
    else
        return AMDStat_CS_Invocations / AMDStat_Compute_Waves_Executed;
}

function VSOccupancy()
{
    return (100 * DerivedVSOccupancy) / DerivedCPF;
}

function PSOccupancy()
{
    return (100 * DerivedPSOccupancy) / DerivedCPF;
}

function CSOccupancy()
{
    return (100 * (DerivedCSOccupancy + DerivedCSNOccupancy)) / DerivedCPF;
}

function LLCRead()
{
    return DerivedLLCRead * 32;
}

function LLCWrite()
{
    return DerivedLLCWrite * 32;
}
                
function ALUutilization()
{
    var util = 0;
    
    var wave_size = 0;
    if (DerivedWavesInFlight !=0)
    {
        wave_size = 64;
    }
    else
    {
        wave_size = 32;
    }
     
    util = (DerivedALUThreadCycles / (DerivedALUActiveInst * wave_size)) * 100;
    return (util > 100 ? 100 : util);
            
}
